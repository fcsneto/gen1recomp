# TikTok LIVE chat bridge for Windows

This optional bridge reads TikTok LIVE comments and sends immediate commands to
the game's existing loopback receiver. It does not simulate a keyboard and it
does not open any new network port.

## First use

Start the game with remote input enabled, as described in
[remote input](remote-input.md). The simplest option is to double-click
`Play-TikTok-Live.bat` in the project root. It will:

1. ask for the TikTok `@handle` and button duration;
2. generate a new local token and launch the game with its receiver enabled;
3. wait until the receiver is ready;
4. wait for you to start the TikTok LIVE; and
5. connect the chat bridge after you confirm with a key press.

It keeps the game and the bridge in separate windows and refuses to reuse port
38101 when another game receiver is already running.

To run the bridge manually, leave the game running and use another PowerShell:

```powershell
cd C:\DEV\gen1recomp
.\scripts\run-tiktok-bridge.ps1 -UniqueId '@your_tiktok_handle' -Token 'the-same-game-token'
```

The script installs the pinned bridge dependency into the project's existing
`.venv` the first time. Stop it with `Ctrl+C`.

Test the chat mapping before exposing the game to viewers:

```powershell
.\scripts\run-tiktok-bridge.ps1 -UniqueId '@your_tiktok_handle' -Token 'the-same-game-token' -DryRun
```

`-DryRun` connects to TikTok and prints accepted commands, but never controls
the game.

## Chat commands

Commands must be the whole comment and start with `!`:

| Chat command | Game Boy action |
| --- | --- |
| `!cima`, `!up` | Up |
| `!baixo`, `!down` | Down |
| `!esquerda`, `!left` | Left |
| `!direita`, `!right` | Right |
| `!a`, `!confirmar` | A |
| `!b`, `!voltar` | B |
| `!start`, `!menu` | Start |
| `!select` | Select |

The default press is 120 ms. There is a global limit of eight commands per
second and a limit of one command every 0.8 seconds per viewer. These limits
keep commands immediate while preventing one viewer or spam from filling the
game's queue.

## Important limitation

TikTok does not provide a public official API for reading LIVE comments. This
bridge uses the separately installed, third-party TikTokLive client. It reads
TikTok's Webcast connection and may break when TikTok changes that protocol;
update the dependency if that happens. Review TikTokLive's modified AGPL
license before redistributing the bridge.
