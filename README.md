Tenfold – README - Version: 0.2 - 10 2026

# Tenfold

A notch hub for the MacBook. Hover over the notch → it expands with four tabs:

| Tab | What it does |
|---|---|
| **Clipboard** | Last 10 copied items (text + images). Click = copy back to clipboard, then ⌘V. ✕ on hover removes an item. |
| **Files** | Drag files onto the notch to park them (references only, nothing is copied). Drag them out again, double-click to open, AirDrop single files or all, right-click for more. |
| **Media** | Now playing from Spotify or Apple Music with previous / play-pause / next. |
| **Calendar** | Your events for the rest of today and tomorrow. |

Plus a **volume / brightness HUD**: when the volume or the built-in display brightness changes, the notch briefly widens and shows a level bar.

## Build & run

Requires macOS 14+ (target: macOS 26 Tahoe) and Xcode or the Command Line Tools.

```bash
cd ~/Sites/Tenfold
./build.sh
open build/Tenfold.app
```

Always start the app via `build/Tenfold.app` – the Calendar and Automation prompts need the Info.plist that only the app bundle contains.

## Permissions (asked on first use)

| Permission | Needed for | Where to change |
|---|---|---|
| Paste from Other Apps | Clipboard history | Privacy & Security → Paste from Other Apps |
| Automation (Music / Spotify) | Media tab | Privacy & Security → Automation |
| Calendars (full access) | Calendar tab – click "Allow Calendar Access" | Privacy & Security → Calendars |

The app is only ad-hoc signed. After a rebuild macOS may ask for these permissions again.

## Menu bar

Clear Clipboard History · Clear File Tray · Show Volume HUD (on/off) · Show Brightness HUD (on/off) · Quit

## Known limitations

- History and file tray are kept in memory only (cleared on quit).
- Media: only Spotify and Apple Music (AppleScript). No artwork yet. Browser audio is not shown.
- HUD: the system's own volume/brightness overlay is still shown as well (hiding it is not supported by macOS).
- Brightness uses the private DisplayServices API – it may stop working with a macOS update; it is then disabled automatically. Auto-brightness changes can also trigger the HUD – switch it off in the menu bar if that bothers you.
- Not suitable for the Mac App Store (private API).

---

Author: Siva
