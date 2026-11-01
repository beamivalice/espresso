# Espresso install guide

How to go from a clean Apple Silicon Mac to **Windows Steam running under Espresso** (Wine 10.0 r8 + Apple GPTK 4.0 beta 3, D3D11/D3D12 → Metal). This is the exact sequence that was used to bring up the first working install; every step is checked by `Espresso --doctor`.

Espresso does not install anything itself. It supervises an existing runtime under `~/Library/Application Support/Espresso/`, so the engine, GPTK overlay, libraries and Wine prefix are assembled by hand as below.

## Requirements

- Apple Silicon Mac, macOS 13 or later (built and tested on macOS 26)
- Xcode command line tools (`swiftc`, `clang`, `lipo`, `otool`, `ditto`, `hdiutil`)
- Rosetta 2 (Wine runs as x86_64)
- Several GB free for the runtime (the engine is about 0.8 GB, Steam's client about 1.7 GB), plus space for your games
- Two Apple downloads, kept out of git:
  - `Game_Porting_Toolkit_4.0_beta_3.dmg`
  - `Evaluation_environment_for_Windows_games_4.0_beta_3.dmg` (this is the one with the D3DMetal redist)

## Runtime layout

```
~/Library/Application Support/Espresso/
  Engines/
    WS12WineSikarugir10.0_8/        Wine engine (bin/, lib/, share/, version)
    WS12WineSikarugir10.0_8.engine-tag
  GPTK/
    4.0b3/redist/                   untouched copy of the GPTK redist
    current -> 4.0b3/redist
  Steam/                            Wine prefix (Windows Steam + library)
  Helpers/hide-steam-host.dylib     installed by build.sh
  Logs/
```

The engine name is pinned in `app/main.swift` (`Layout.engineName`). The doctor fails if the tag file does not match it.

## 1. Rosetta 2

```sh
sudo softwareupdate --install-rosetta --agree-to-license
arch -x86_64 /usr/bin/true && echo rosetta-ok
```

## 2. Wine engine

Download Sikarugir's Wine 10.0 r8 engine and unpack it into a fresh, empty directory first:

```sh
WORK=$(mktemp -d)
cd "$WORK"
curl -L -O https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_8.tar.xz
mkdir x && tar -xf WS12WineSikarugir10.0_8.tar.xz -C x      # produces x/wswine.bundle
```

Install it as the pinned engine and write the tag:

```sh
BASE="$HOME/Library/Application Support/Espresso"
ENGINE="$BASE/Engines/WS12WineSikarugir10.0_8"
mkdir -p "$BASE/Engines" "$BASE/GPTK" "$BASE/Logs" "$BASE/Helpers"
cp -R x/wswine.bundle "$ENGINE"
echo "WS12WineSikarugir10.0_8" > "$BASE/Engines/WS12WineSikarugir10.0_8.engine-tag"
```

## 3. x86_64 support libraries

The pinned engine ships without the dylibs Wine needs at runtime: `libinotify` (wineserver links it), `gnutls` and `gmp` with their dependency chain (Steam's TLS), and FreeType. Homebrew has no x86_64 bottles on current macOS, so take them from Gcenx's macOS Wine build (only the libraries are used, not its Wine):

```sh
cd "$WORK"
curl -L -O https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.21/wine-devel-11.21-osx64.tar.xz
mkdir g && tar -xf wine-devel-11.21-osx64.tar.xz -C g
cd "g/Wine Devel.app/Contents/Resources/wine/lib"
for f in *.dylib; do [ -e "$ENGINE/lib/$f" ] || cp -a "$f" "$ENGINE/lib/$f"; done
```

Check: `lipo -archs "$ENGINE/lib/libgnutls.30.dylib"` prints `x86_64` (same for `libgmp.10.dylib`, `libinotify.0.dylib`).

## 4. GPTK D3DMetal overlay

Mount the evaluation-environment DMG and copy its `redist/` tree. It mirrors the engine layout (`lib/external` holds D3DMetal, `lib/wine` holds the `d3d*`/`dxgi` replacements):

```sh
hdiutil attach -readonly -nobrowse -mountpoint /tmp/gptk-eval \
  Evaluation_environment_for_Windows_games_4.0_beta_3.dmg

mkdir -p "$BASE/GPTK/4.0b3"
ditto /tmp/gptk-eval/redist "$BASE/GPTK/4.0b3/redist"
ln -sfn 4.0b3/redist "$BASE/GPTK/current"
ditto "$BASE/GPTK/current/lib" "$ENGINE/lib"          # overlay onto the engine

hdiutil detach /tmp/gptk-eval
```

Check: `lipo -archs` on `$ENGINE/lib/external/D3DMetal.framework/Versions/A/D3DMetal` and on `libd3dshared.dylib` prints `x86_64`, and `otool -L $ENGINE/lib/wine/x86_64-unix/dxgi.so` lists `@rpath/libd3dshared.dylib`.

The other DMG (Game Porting Toolkit) holds the shader converter and samples, which Espresso does not use.

## 5. Build Espresso

```sh
cd app && sh build.sh
```

Optionally install it: `cp -R app/Espresso.app /Applications/`. Quit and reopen after replacing the app.

## 6. Create the prefix and run the doctor

The first Wine command creates the 64-bit prefix. The doctor does this for you:

```sh
app/Espresso.app/Contents/MacOS/Espresso --doctor
```

Expected: every line `PASS` and `RESULT: PASS`. A fresh Wine 10 prefix reports Windows 10 (build 19043), which is what Steam wants.

## 7. Install Windows Steam into the prefix

Espresso only launches Steam; it does not install it. Wine has to be started the same way Espresso starts it (x86_64 under `arch`, with `DYLD_FALLBACK_LIBRARY_PATH` re-set after `arch` because `arch` strips `DYLD_*`). This small helper reproduces the app's environment:

```sh
cat > ~/espresso-wine.sh <<'EOF'
#!/bin/sh
B="$HOME/Library/Application Support/Espresso"; E="$B/Engines/WS12WineSikarugir10.0_8"
FB="$E/lib/external:$E/lib"
export WINEPREFIX="$B/Steam" WINEARCH=win64 WINEDLLOVERRIDES="pdh=n,b;mscoree,mshtml=" \
  DYLD_LIBRARY_PATH="$FB" \
  D3DMETAL_FRAMEWORK_PATH="$E/lib/external/D3DMetal.framework/Versions/A/D3DMetal" \
  DXMT_ENABLE=0 DXVK_ENABLE=0 ROSETTA_ADVERTISE_AVX=1 WINEMSYNC=1
exec /usr/bin/arch -x86_64 /usr/bin/env DYLD_FALLBACK_LIBRARY_PATH="$FB" "$E/bin/wine" "$@"
EOF
chmod +x ~/espresso-wine.sh
```

Download and install Steam silently:

```sh
curl -L -o SteamSetup.exe https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe
~/espresso-wine.sh SteamSetup.exe /S
```

Then start it from the Espresso cup menu (**Windows Steam**), or by hand:

```sh
~/espresso-wine.sh 'C:\Program Files (x86)\Steam\steam.exe' -no-cef-sandbox
```

The first start downloads the Steam client (about 1.7 GB) and relaunches itself once. When a 700x440 login window appears, sign in. Never pass `-cef-force-32bit`.

## 8. VC++ runtime overrides (required for many games)

Many titles run Steam's one-time `vcredist` step and then check the installed runtime. Wine prefers its own built-in `msvcp140*`/`vcruntime140*` over the real Microsoft DLLs that Steam installs, and the built-in copies carry no file version. Unreal Engine launchers then report "Microsoft Visual C++ 2015-2022 Redistributable is required" even though it is installed. Fix it once per prefix by preferring the native DLLs (the same thing `winetricks vcrun2022` does):

```sh
for d in concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait \
         msvcp140_codecvt_ids vcamp140 vcomp140 vcruntime140 vcruntime140_1; do
  ~/espresso-wine.sh reg add 'HKCU\Software\Wine\DllOverrides' /v $d /d native,builtin /f
done
```

Do this after Steam has run a game's redist step at least once (so the native DLLs exist in `system32`/`syswow64`), or the override has nothing to load and falls back to the built-in.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `arch: posix_spawnp ... Bad CPU type` | Rosetta missing (step 1). |
| Doctor: D3DMetal / `libd3dshared` / GPTK overlay FAIL | Step 4 not done, or the wrong DMG was used. The redist is in the *Evaluation environment* DMG. |
| Doctor: `libgnutls` / `libgmp` / `libinotify` FAIL | Step 3. Wine without them fails to start, or Steam's TLS breaks (manifest timeouts, cert errors `0x8`). |
| Doctor: Engine pin FAIL | The `.engine-tag` file is missing or does not match `Layout.engineName`. |
| Doctor: pdh stub FAIL | Only matters for Unreal Engine 5 titles, which crash at start (`0x80000100`) on `PdhOpenQuery`. |
| "VC++ Redistributable is required" at game start | Step 8. |
| A game starts then exits within seconds | Run its launcher by hand with `WINEDEBUG=err+all` through the helper in step 7 and read the output. A launcher stub that prints a dialog is usually a missing-DLL or version check. |
| Wine logs full of `err:hid ... not a joystick or gamepad` | Harmless. |

Logs from launches started by the app are in `~/Library/Application Support/Espresso/Logs/`.

## Notes

- The two Apple DMGs are not redistributable and are not tracked by git.
- DirectX 9 and Vulkan games are outside the GPTK path.
- The D3DMetal overlay replaces the engine's own `d3d10`, `d3d11`, `d3d12`, `d3d12core` and `dxgi`, so the engine copy is no longer a stock Wine. Re-run step 4 after replacing the engine.
