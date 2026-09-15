using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace Gen1RemoteInput;

/// <summary>
/// A deliberately small, Windows-only HTTP receiver for a local livestream
/// bridge. It binds only to 127.0.0.1; the Lua side is the only consumer of
/// the bounded command queue.
/// </summary>
public static class RemoteInputServer
{
    const int MaxBodyBytes = 512;
    const int MaxQueuedCommands = 128;
    const int DefaultDurationMs = 100;
    const int MaxDurationMs = 500;

    static readonly HashSet<string> AllowedActions = new(StringComparer.Ordinal)
    {
        "up", "down", "left", "right", "a", "b", "start", "select",
    };

    static readonly ConcurrentQueue<InputCommand> Commands = new();
    static readonly object LifecycleLock = new();
    static readonly object ErrorLock = new();
    static TcpListener? Listener;
    static byte[]? Token;
    static Thread? Worker;
    static int Running;
    static int Queued;
    static string? LastError;

    readonly record struct InputCommand(string Action, int DurationMs);

    // --------------------------------------------------------------- C ABI

    [UnmanagedCallersOnly(EntryPoint = "gen1remote_start")]
    public static int Start(int port, nint tokenPtr)
    {
        if (port is < 1024 or > 65535 || tokenPtr == 0) return -1;
        string? token = Marshal.PtrToStringUTF8(tokenPtr);
        if (!IsSafeToken(token))
            return -1;

        lock (LifecycleLock)
        {
            if (Volatile.Read(ref Running) != 0) return -2;
            try
            {
                Commands.Clear();
                Interlocked.Exchange(ref Queued, 0);
                Token = Encoding.UTF8.GetBytes(token!);
                Listener = new TcpListener(IPAddress.Loopback, port);
                Listener.Start(backlog: 16);
                ClearError();
                Volatile.Write(ref Running, 1);
                Worker = new Thread(ServerLoop)
                {
                    IsBackground = true,
                    Name = "gen1remoteinput-http",
                };
                Worker.Start();
                return 1;
            }
            catch (Exception ex)
            {
                StopUnsafe();
                SetError(Describe(ex));
                return -3;
            }
        }
    }

    [UnmanagedCallersOnly(EntryPoint = "gen1remote_next")]
    public static int Next(nint actionPtr, int actionMax, nint durationPtr)
    {
        if (actionPtr == 0 || durationPtr == 0 || actionMax < 8) return -1;
        if (!Commands.TryDequeue(out InputCommand command)) return 0;
        Interlocked.Decrement(ref Queued);
        byte[] action = Encoding.ASCII.GetBytes(command.Action);
        if (action.Length + 1 > actionMax) return -1;
        Marshal.Copy(action, 0, actionPtr, action.Length);
        Marshal.WriteByte(actionPtr, action.Length, 0);
        Marshal.WriteInt32(durationPtr, command.DurationMs);
        return 1;
    }

    [UnmanagedCallersOnly(EntryPoint = "gen1remote_clear")]
    public static void Clear()
    {
        Commands.Clear();
        Interlocked.Exchange(ref Queued, 0);
    }

    [UnmanagedCallersOnly(EntryPoint = "gen1remote_stop")]
    public static void Stop()
    {
        lock (LifecycleLock) StopUnsafe();
    }

    [UnmanagedCallersOnly(EntryPoint = "gen1remote_error")]
    public static int Error(nint bufferPtr, int max)
    {
        if (bufferPtr == 0 || max < 2) return 0;
        string? error;
        lock (ErrorLock) error = LastError;
        if (string.IsNullOrEmpty(error)) return 0;
        byte[] bytes = Encoding.UTF8.GetBytes(error);
        int length = Math.Min(bytes.Length, max - 1);
        Marshal.Copy(bytes, 0, bufferPtr, length);
        Marshal.WriteByte(bufferPtr, length, 0);
        return 1;
    }

    // ------------------------------------------------------------- listener

    static void ServerLoop()
    {
        while (Volatile.Read(ref Running) != 0)
        {
            TcpClient? client = null;
            try
            {
                client = Listener?.AcceptTcpClient();
                if (client == null) break;
                client.NoDelay = true;
                client.ReceiveTimeout = 2000;
                client.SendTimeout = 2000;
                HandleClient(client);
            }
            catch (ObjectDisposedException) { break; }
            catch (SocketException) when (Volatile.Read(ref Running) == 0) { break; }
            catch (Exception ex)
            {
                if (Volatile.Read(ref Running) != 0) SetError(Describe(ex));
            }
            finally
            {
                try { client?.Dispose(); } catch { /* shutdown path */ }
            }
        }
    }

    static void HandleClient(TcpClient client)
    {
        using NetworkStream stream = client.GetStream();
        using var reader = new StreamReader(stream, Encoding.ASCII,
            detectEncodingFromByteOrderMarks: false, bufferSize: 1024, leaveOpen: true);

        string? requestLine = ReadLineLimited(reader, 1024);
        if (requestLine == null) return;
        string[] requestParts = requestLine.Split(' ');
        if (requestParts.Length != 3 || requestParts[0] != "POST" || requestParts[1] != "/input")
        {
            WriteResponse(stream, 404, "not found");
            return;
        }

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        while (true)
        {
            string? line = ReadLineLimited(reader, 1024);
            if (line == null)
            {
                WriteResponse(stream, 400, "invalid headers");
                return;
            }
            if (line.Length == 0) break;
            int colon = line.IndexOf(':');
            if (colon > 0)
                headers[line[..colon].Trim()] = line[(colon + 1)..].Trim();
        }

        if (!headers.TryGetValue("X-Remote-Token", out string? supplied)
            || !TokenMatches(supplied))
        {
            WriteResponse(stream, 401, "unauthorized");
            return;
        }

        if (!headers.TryGetValue("Content-Length", out string? rawLength)
            || !int.TryParse(rawLength, out int length) || length is < 2 or > MaxBodyBytes)
        {
            WriteResponse(stream, 400, "invalid content length");
            return;
        }

        char[] body = new char[length];
        int read = 0;
        while (read < body.Length)
        {
            int n = reader.Read(body, read, body.Length - read);
            if (n == 0) break;
            read += n;
        }
        if (read != body.Length || !TryParseCommand(new string(body), out InputCommand command))
        {
            WriteResponse(stream, 400, "invalid input command");
            return;
        }

        if (Interlocked.Increment(ref Queued) > MaxQueuedCommands)
        {
            Interlocked.Decrement(ref Queued);
            WriteResponse(stream, 429, "input queue full");
            return;
        }
        Commands.Enqueue(command);
        WriteResponse(stream, 202, "queued");
    }

    static bool TryParseCommand(string body, out InputCommand command)
    {
        command = default;
        try
        {
            using JsonDocument doc = JsonDocument.Parse(body);
            JsonElement root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("action", out JsonElement actionElement)
                || actionElement.ValueKind != JsonValueKind.String)
                return false;
            string? action = actionElement.GetString()?.ToLowerInvariant();
            if (action == null || !AllowedActions.Contains(action)) return false;

            int duration = DefaultDurationMs;
            if (root.TryGetProperty("duration_ms", out JsonElement durationElement))
            {
                if (!durationElement.TryGetInt32(out duration)) return false;
            }
            duration = Math.Clamp(duration, 1, MaxDurationMs);
            command = new InputCommand(action, duration);
            return true;
        }
        catch (JsonException) { return false; }
    }

    // StreamReader.ReadLine has no length ceiling. Keep the entire request
    // bounded, not just its JSON body, so another local process cannot make
    // the background listener allocate an arbitrary header line.
    static string? ReadLineLimited(StreamReader reader, int maxChars)
    {
        var line = new StringBuilder();
        while (true)
        {
            int ch = reader.Read();
            if (ch < 0) return line.Length == 0 ? null : line.ToString();
            if (ch == '\n')
            {
                if (line.Length > 0 && line[^1] == '\r') line.Length--;
                return line.ToString();
            }
            if (line.Length >= maxChars) return null;
            line.Append((char)ch);
        }
    }

    static bool TokenMatches(string supplied)
    {
        byte[]? expected = Token;
        if (expected == null) return false;
        byte[] actual = Encoding.UTF8.GetBytes(supplied);
        return actual.Length == expected.Length
            && CryptographicOperations.FixedTimeEquals(actual, expected);
    }

    // HTTP header values are ASCII here. Restricting the secret to a printable
    // ASCII token also prevents control characters from ever crossing the
    // native boundary and makes copy/paste into a bridge predictable.
    static bool IsSafeToken(string? token)
    {
        if (string.IsNullOrEmpty(token) || token.Length < 16 || token.Length > 256)
            return false;
        foreach (char c in token)
        {
            if (c < '!' || c > '~') return false;
        }
        return true;
    }

    static void WriteResponse(NetworkStream stream, int status, string text)
    {
        byte[] body = Encoding.UTF8.GetBytes("{\"status\":\"" + text + "\"}");
        string header = $"HTTP/1.1 {status} {StatusText(status)}\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Connection: close\r\n"
            + $"Content-Length: {body.Length}\r\n\r\n";
        byte[] headerBytes = Encoding.ASCII.GetBytes(header);
        stream.Write(headerBytes, 0, headerBytes.Length);
        stream.Write(body, 0, body.Length);
    }

    static string StatusText(int status) => status switch
    {
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        429 => "Too Many Requests",
        _ => "Internal Server Error",
    };

    static void StopUnsafe()
    {
        Volatile.Write(ref Running, 0);
        try { Listener?.Stop(); } catch { /* already stopped */ }
        Listener = null;
        Token = null;
        Worker = null;
        Commands.Clear();
        Interlocked.Exchange(ref Queued, 0);
    }

    static void SetError(string error)
    {
        lock (ErrorLock) LastError = error;
    }

    static void ClearError()
    {
        lock (ErrorLock) LastError = null;
    }

    static string Describe(Exception ex) => ex.GetBaseException().Message;
}
