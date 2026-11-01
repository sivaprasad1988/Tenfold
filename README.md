Tenfold – README - Version: 0.8 - 11 2026

# Tenfold

A notch hub for the MacBook. Hover over the notch → it expands into a panel with these tabs:

| Tab | What it does |
|---|---|
| **Dashboard** | 4×2 grid: Up Next, Now Playing, Focus, Weather, Clipboard, Screen Time, Day Progress, Quick controls (volume / brightness). Sections can be hidden. |
| **Clipboard** | Last 10 copied items, sorted into text / code / links / files / media / colors. Click = copy back. ⌃⌥V opens it from the keyboard, keys 1–0 paste an item. Pinned items and an encrypted **Vault**. |
| **Files** | Drag files onto the notch to park them (references only, nothing is copied). Drag them out again, double-click to open, AirDrop, right-click for more. Plus a shelf with your latest screenshots. |
| **Media** | Now playing from Spotify or Apple Music with controls and a live equalizer. |
| **Calendar** | Your events for today and tomorrow; join button and countdown in the closed notch before a meeting. |
| **Weather** | Forecast from Open-Meteo for your location or a city you choose. |
| **Screen Time** | Time per app and category. |
| **Tools** | Focus timer, notes, camera mirror. |
| **Usage** | Claude Code / Codex token usage (opt-in) and the **Agent Inbox**. |

Plus a **volume / brightness HUD**: when the volume or the built-in display brightness changes, the notch briefly widens and shows a level bar.

## Agent Inbox (Claude Code + Codex)

The notch tells you when your coding agent needs you:

| Notch shows | When |
|---|---|
| **project · Waiting** (amber) | Claude Code or Codex asks for permission |
| **project · Done** (mint, 6 s) | A turn has finished |

The **Usage** tab lists all sessions (Working / Waiting / Done). Click a session to bring its terminal (or the ChatGPT app) to the front; ✕ removes it from the list.

**Setup:** Settings → General → Agent Inbox → **Install hooks** (one button each for Claude Code and Codex).

- Claude Code: hooks are added to `~/.claude/settings.json`. New sessions pick them up.
- Codex: hooks are added to `~/.codex/hooks.json`. Codex runs new hooks only after you trust them once: start `codex` in a terminal, type `/hooks` and trust the Tenfold entries. Then quit the ChatGPT app (⌘Q) and start it again.
- Your other hooks are left as they are. Before every change Tenfold saves a backup (`settings.json.tenfold-backup` / `hooks.json.tenfold-backup`). **Remove hooks** takes the Tenfold entries out again.
- After Remove + Install, Codex asks for trust again.

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
| Location | Weather (or choose a city in Settings) | Privacy & Security → Location Services |
| Camera | Camera mirror (only while you use it) | Privacy & Security → Camera |
| System Audio Recording | Live equalizer (analysed live, nothing recorded) | Privacy & Security → Screen & System Audio Recording |
| Accessibility | Paste directly with ⌃⌥V | Privacy & Security → Accessibility |
| Desktop folder | Screenshot shelf | Privacy & Security → Files & Folders |

Releases are signed with a Developer ID and notarized. Local builds (`./build.sh`) are only ad-hoc signed – after a rebuild macOS may ask for these permissions again.

## Menu bar

Clear Clipboard History · Clear File Tray · Show Volume HUD (on/off) · Show Brightness HUD (on/off) · Quit

## Privacy

- **Clipboard history** stays in memory. Pinned texts are stored in the login keychain. Copies marked as concealed (password managers) are never stored.
- **Vault** (Clipboard → Vault): secrets are encrypted with your PIN or password (PBKDF2-SHA256 + AES-GCM) in `~/Library/Application Support/Tenfold/vault.json`. It locks after 5 min, on sleep and on screen lock. Copied secrets are cleared from the clipboard after 30 s. A forgotten PIN cannot be recovered; the vault can only be erased.
- **Weather**: your approximate location (rounded to about 1 km) or the city you type is sent to [Open-Meteo.com](https://open-meteo.com) to get the forecast. Nothing else leaves the Mac.
- **Usage tab**: reads Claude Code / Codex session logs only after you enable it. Only token counts are kept.
- **Agent Inbox**: the hook script (`~/Library/Application Support/Tenfold/agent-hook.sh`) passes only the event name, session id, folder path, transcript path and terminal app to Tenfold – never prompts, messages or code. Tenfold reads each event once and deletes it; the transcript is only watched for changes, not read.
- The notch panel is excluded from screen sharing and screen recordings.

## Known limitations

- History and file tray are kept in memory only (cleared on quit); pinned clipboard texts are kept.
- Media: only Spotify and Apple Music (AppleScript). Browser audio is not shown.
- HUD: the system's own volume/brightness overlay is still shown as well (hiding it is not supported by macOS).
- Brightness uses the private DisplayServices API – it may stop working with a macOS update; it is then disabled automatically. Auto-brightness changes can also trigger the HUD – switch it off in the menu bar if that bothers you.
- Not suitable for the Mac App Store (private API).

---

Author: Siva
