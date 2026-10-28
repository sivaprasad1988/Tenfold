# Tenfold – Project Guide for Claude Code - Version: 02 - 10 2026

Tenfold is a macOS menu-bar/notch app (Swift Package, SwiftUI + AppKit). Hovering over the notch opens a
panel with clipboard history (last 10 items), music, calendar, weather, screen time, focus timer, notes,
file tray/screenshots, camera mirror and quick controls (volume/brightness).

## Facts
- Swift tools 5.9, macOS 14+, single executable target `Sources/Tenfold`, no external dependencies.
- Bundle ID `de.woit.tenfold`; version in `Resources/Info.plist` (`CFBundleShortVersionString` + `CFBundleVersion`).
- Accessory app (`LSUIElement`). Releases: Developer ID signed (hardened runtime, `Tenfold.entitlements`) and
  notarized via `./notarize.sh`; local builds (`build.sh`, `package.sh` without `SIGN_ID`) stay ad-hoc signed.
- UI language: `L("key")` / `LF("key", args)` from `Localization.swift`; texts in `Translations.swift`
  (11 languages: en, de, fr, es, pt-BR, it, ja, nl, ko, pl, zh-Hans). Every new key needs all 11 languages.
  Permission texts per language in `Resources/<lang>.lproj/InfoPlist.strings`.

## Commands
- Build & run locally: `./build.sh` then `open build/Tenfold.app`
- Shareable zip (universal arm64+x86_64): `./package.sh` → `dist/Tenfold-<version>.zip` (+ Install-Tenfold.txt)
- Notarized release (zip + dmg, universal): `./notarize.sh` → `dist/Tenfold-<version>.zip` / `.dmg`
  (needs "Developer ID Application" cert in keychain + notarytool profile `tenfold-notary`)
- Unnotarized DMG (ad-hoc):
  ```
  rm -rf dist/dmg && mkdir -p dist/dmg && ditto build/Tenfold.app dist/dmg/Tenfold.app \
    && cp Install-Tenfold.txt dist/dmg/ && ln -s /Applications dist/dmg/Applications \
    && hdiutil create -volname Tenfold -srcfolder dist/dmg -ov -format UDZO dist/Tenfold-<version>.dmg
  ```
- Check signature: `codesign -v build/Tenfold.app` (no output = OK)
- Performance: `./perf.sh <label>` → `perf-<label>.log` (CPU/mem/threads every 5 s);
  hotspots: `sample Tenfold 8 -file sample-<label>.txt`

## Rules
- Prefer full Xcode (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, set by the scripts).
  With Command Line Tools only, SwiftUI macros are missing: do NOT use `@State`, `@Observable`, `#Preview`.
  Shared hover state uses `HoverTracker.shared`.
- Never edit files inside `build/` or `dist/` app bundles after signing (breaks the signature) – rebuild instead.
- Bump the version in `Resources/Info.plist` before sending a new build to others; share only notarized builds.
- New hardened-runtime features (e.g. microphone, contacts) need a matching entry in `Tenfold.entitlements`.
- Performance targets (measured 10 2026, M1 Pro): idle ≈ 2 % CPU, panel open with music ≈ 4–5 %.
  Keep high-frequency updates out of SwiftUI: spectrum bars render via CALayer (`SpectrumBarsNSView`),
  `AudioSpectrum.bands` is intentionally not `@Published`. TimelineViews ≥ 1 s except animated fallback bars.
- Do not add audio/meeting transcription without explicit approval (legal: §201 StGB, GDPR).
- Clipboard must keep skipping password-manager content (ConcealedType, Enpass etc.).

## Code map (Sources/Tenfold)
- `main.swift`, `AppDelegate.swift` – startup, stores, status menu, hotkey ⌃⌥V, one notch per display
- `NotchController.swift` – panel window, hover/mouse tracking, open/close morph, HUD, keyboard mode
- `NotchState.swift` – tabs, metrics, Prefs, HoverTracker, display helpers
- `NotchView.swift` – all SwiftUI views (Dashboard grid 4×2, tabs, Dock, Theme)
- `ClipboardStore.swift`, `ClipItem.swift` – clipboard history; `FileTrayStore.swift` – file tray
- `MediaController.swift` – Spotify/Music via osascript; `AudioSpectrum.swift` – real equalizer (process tap + FFT)
- `SystemHUDMonitor.swift` – volume/brightness; `CalendarStore.swift`, `WeatherStore.swift` (Open-Meteo), `ScreenTimeStore.swift`
- `Extras.swift` – focus timer, notes, screenshots, camera, global hotkey
- `SettingsWindow.swift`, `Localization.swift`, `Translations.swift`

---
Author: Siva
