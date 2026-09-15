# Remote input for Windows livestreams

The Windows build can accept immediate Game Boy button commands from a local
livestream bridge. It never simulates keyboard events: remote actions become a
separate input source, so the local player can continue using keyboard and
gamepad normally.

## Enable it

The receiver is disabled by default and binds only to `127.0.0.1`. Set all of
these before starting the game:

```powershell
$env:POKEPORT_REMOTE_INPUT = "1"
$env:POKEPORT_REMOTE_TOKEN = "replace-with-a-long-random-secret"
$env:POKEPORT_REMOTE_PORT = "38101" # optional; this is the default
.\scripts\run.ps1
```

The packaged Windows build includes `gen1remoteinput.dll`. For a source-tree
run, build it once first:

```powershell
dotnet publish native\remote_input\Gen1RemoteInput.csproj -c Release -r win-x64 -o dist\native\win-x64
```

Use at least 16 printable ASCII characters for the token. Generate one, for
example, with `[guid]::NewGuid().ToString('N')`.

## HTTP contract

Send `POST http://127.0.0.1:38101/input` with a token header and JSON body:

```powershell
Invoke-RestMethod http://127.0.0.1:38101/input `
  -Method Post `
  -Headers @{ "X-Remote-Token" = $env:POKEPORT_REMOTE_TOKEN } `
  -ContentType "application/json" `
  -Body '{"action":"right","duration_ms":100}'
```

Valid `action` values are `up`, `down`, `left`, `right`, `a`, `b`, `start`,
and `select`. `duration_ms` is optional (100 ms by default) and clamped to
1–500 ms. The request returns `202` when queued, `401` for a bad token, and
`429` when the 128-command queue is full.

Keep the TikTok client in a separate process. It should translate chat messages
such as `!right` into the request above; do not expose this local endpoint with
a public tunnel or port-forward.
