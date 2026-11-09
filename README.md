# Espresso

Espresso is a menu-bar app for running **my Steam library** on Apple Silicon — the Windows titles in the library, not a single game.

It supervises two Steam clients and keeps only one running at a time:

- **Mac** — native `/Applications/Steam.app`
- **Windows** — Steam inside one x86_64 Wine prefix, with Apple GPTK **D3DMetal** for D3D11 and D3D12 → Metal

Launch games from Steam as usual. DirectX 9 and Vulkan are outside this GPTK path.

## Layout

Runtime lives under `~/Library/Application Support/Espresso/`:

| Path | What |
|------|------|
| `Engines/` | Pinned Sikarugir Wine |
| `GPTK/current` | Game Porting Toolkit overlay |
| `Steam/` | Wine prefix (Windows Steam + library) |
| `Logs/` | Launch logs |

## Build

```sh
cd app && sh build.sh
```

Install by copying `app/Espresso.app` to `/Applications`. Version is in the cup menu (`v0.3` / build from Info.plist). Quit and reopen after replacing the app.

`--doctor` prints the GPTK/Wine checks. `--self-test` cycles Windows Steam start/stop.
