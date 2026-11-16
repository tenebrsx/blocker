# Word Blocker for macOS 🛡️

A native, high-performance background utility written in Swift for macOS that prevents forbidden words from being typed system-wide by automatically erasing them via synthetic backspaces upon detection.

---

## Features

- **System-Wide Protection:** Intercepts keystrokes across all macOS applications (browsers, editors, chat apps, terminals) using a low-level Quartz Event Tap (`CGEventTap`).
- **Auto-Delete Enforcement:** Once a blocked word is completed, the app immediately erases the characters using synthesized hardware-level Backspace events.
- **Obfuscation & Evasion Resilient:** Catches leetspeak (`b4d`, `w0rd`), repeated character elongations (`b444aad`, `w0000000rrrrrd`), punctuation noise (`b.a.d`, `b_4_d`), Cyrillic homoglyphs (`bаd`), and transpositions/typos (`sceret` -> `secret`).
- **Exact Origin Span Tracking:** Maintains raw physical index traces so the exact count of typed characters (e.g. 7 backspaces for `b444aad`) is deleted without leaving leftover fragments.
- **Recursive Loop Prevention:** Tags synthetic backspaces with a distinct signature (`0x57424C4B`) so the interceptor never re-processes its own actions.
- **Context-Aware Sliding Buffer:** Correctly synchronizes buffer state across manual backspaces, punctuation, Return/Enter, navigation arrow keys, and keyboard shortcuts (`Cmd+C`, `Cmd+V`, `Cmd+A`).
- **Custom Pop-Up Notes:** Assign custom written reminder notes to specific blocked words (e.g. *"Stay focused on your goals!"*). When a banned word is typed, the word is auto-deleted and a floating HUD pop-up note smoothly appears at the top-right of your screen.
- **Custom Intervention Messages:** Personalize the intervention message displayed whenever you attempt to **disable protection**, and customize the intervention alert displayed whenever you attempt to **quit** the application. Enabling protection remains completely silent without pop-ups.
- **Exceptions Allowlist (False-Positive Guard):** Dedicated **Exceptions** tab allows specifying allowed words (e.g. `badger`, `badge`, `password`, `compass`). If a blocked word is a prefix of an exception, deletion is intelligently deferred so you can finish typing without premature interruption.
- **Menu Bar Agent (`LSUIElement`):** Runs quietly in the macOS menu bar with zero Dock clutter.
- **Interactive Preferences Window:** Manage Blocked Words, Exceptions, and Custom Prompts with a built-in live test area.
- **Automatic Permission Recovery:** Detects when Accessibility permission is granted in macOS System Settings and automatically engages the event tap.

---

## Protection Layers (everything runs inside the app: no DNS, VPN or Network Extension)

- **Adult sites: hard block, no unlock.** Built-in domains, TLDs and keywords plus two large blocklists that download and refresh themselves (StevenBlack porn-only hosts, Blocklist Project porn list; hundreds of thousands of domains stored as a compact hash index). The tab is closed on sight. Explicit searches are blocked on every site, including disguised spellings (`p0rn`, `s3xy`, `n.u.d.e`). Unknown adult sites are caught by scoring the page text. Safe image searches (Google Images, Bing, DuckDuckGo) are left alone.
- **Browser lockdown.** Browsers the app can't monitor (Tor, a Windows browser in a VM, …) are closed on sight, so there is no way around the block.
- **Math gate.** Quitting, turning protection off, or loosening any setting needs a 30-second cool-off and then 10 math problems in a row (one wrong answer starts over). Entering a social-media site needs 5, then 7, then 10 problems per day. Optional "auto-close tab on visit".
- **Hard to kill.** Polite quit signals (Activity Monitor "Quit", `kill`, `killall`) are ignored. A second copy of the app runs as a guardian and reopens the app within about half a second if it is force-quit, and the app does the same for the guardian. Activity Monitor is closed the moment it opens while protection is on. Turn on **Start at login, and relaunch if force-quit** in Settings to add launchd as a third layer.
- **On-device image scanner (optional).** Looks at the screen with an on-device model (Core ML + Vision) and blacks it out and closes the tab when it sees explicit images. Nothing leaves your Mac. Needs Screen Recording permission and the model (see below).

**What it cannot do:** a user-level app can't stop `kill -9` from Terminal or a determined person who kills the app and the guardian in the same instant. Those bring the app back within about a second, but the only truly unkillable setup is a root-owned service, which this project deliberately avoids.

---

## Install from a Release

1. Download `WordBlocker.zip` from the [Releases](https://github.com/tenebrsx/blocker/releases) page and unzip it.
2. Drag `WordBlocker.app` into `/Applications`.
3. The app is ad-hoc signed, not notarized, so macOS will quarantine a downloaded copy. Clear that once:
   ```bash
   xattr -dr com.apple.quarantine /Applications/WordBlocker.app
   ```
4. Open it and grant **Accessibility** (see below). That is all the word and website blocking need.

### Optional: image scanner model

The model is not in the repository or the release (it is a few hundred MB). Create it once:

```bash
python3 -m venv /tmp/nsfw-venv
/tmp/nsfw-venv/bin/pip install torch transformers coremltools pillow numpy huggingface_hub
/tmp/nsfw-venv/bin/python scripts/convert_nsfw_model.py
```

Then restart the app and grant **Screen Recording** when macOS asks. The menu's "Image scanner" line shows its status.

---

## System Requirements

- **Operating System:** macOS 14.0 (Sonoma) or newer.
- **Architecture:** Apple Silicon (arm64).
- **Permissions:** macOS Accessibility (TCC) trust under `System Settings > Privacy & Security > Accessibility`.

---

## Quick Start

### 1. Build the App Bundle
```bash
make build
```
This compiles the Swift sources and produces `build/WordBlocker.app` signed with an ad-hoc identity.

### 2. Run the App
```bash
make run
```
Or open the built app bundle directly:
```bash
open build/WordBlocker.app
```

### 3. Run Automated Engine Tests
```bash
make test
```

---

## Granting Accessibility Permissions

Because Word Blocker monitors system-wide keystrokes to detect blocked words:

1. On first launch, the app will show the **Preferences** window highlighting `⚠️ Accessibility Permission Missing`.
2. Click **Grant Permission** (or navigate to `System Settings > Privacy & Security > Accessibility`).
3. Toggle the switch for **Word Blocker** to ON.
4. Word Blocker will automatically detect the permission grant in real time and activate protection (the menu bar icon turns to 🛡️).

---

## Project Structure

```
word blocker/
├── Makefile                          # Build, run, and test shortcuts
├── build.sh                          # App compilation and bundle creation script
├── vfs.yaml                          # VFS overlay to prevent SDK modulemap collisions
├── Resources/
│   └── Info.plist                    # Bundle metadata (LSUIElement = true)
├── Sources/
│   ├── Main.swift                    # App entry point and lifecycle (@main)
│   ├── Core/
│   │   ├── PermissionsManager.swift  # TCC Accessibility verification and polling
│   │   ├── EventTapManager.swift     # Quartz CGEventTap listener and dispatcher
│   │   ├── WordBufferEngine.swift    # Sliding window buffer and suffix matcher
│   │   └── ActionDispatcher.swift    # Synthetic backspace injector
│   ├── Storage/
│   │   └── WordStore.swift           # UserDefaults persistence for blocked words
│   └── UI/
│       ├── MenuBarController.swift   # NSStatusItem and menu bar dropdown
│       └── SettingsWindowController.swift # Native AppKit preferences interface
└── Tests/
    └── EngineTests.swift             # Automated unit and integration tests
```

---

## How It Works Under the Hood

```
[Hardware Keystroke]
         │
         ▼
[macOS WindowServer]
         │
         ▼
[EventTapManager (CGEventTap)]
         │
         ├─► Synthetic Event? ──► [Pass through without processing]
         ├─► Command/Control? ──► [Reset Buffer & Pass through]
         ├─► Backspace?       ──► [Pop last character from Buffer]
         └─► Printable Key?   ──► [Append Unicode character to Buffer]
                                              │
                                              ▼
                                 [WordBufferEngine (Matcher)]
                                              │
                       ┌──────────────────────┴──────────────────────┐
                       │                                             │
                  [No Match]                                   [Match Found]
                       │                                             │
                       ▼                                             ▼
               [Pass Event along]                        [ActionDispatcher]
                                                         • Optional beep (NSSound.beep())
                                                         • Post N synthetic Backspaces
                                                         • Reset Buffer
```
