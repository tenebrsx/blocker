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
- **Exceptions Allowlist (False-Positive Guard):** Dedicated **Allowed** (exceptions) tab allows specifying allowed words (e.g. `badger`, `badge`, `password`, `compass`). If a blocked word is a prefix of an exception, deletion is intelligently deferred so you can finish typing without premature interruption.
- **Menu Bar Agent (`LSUIElement`):** Runs quietly in the macOS menu bar with zero Dock clutter.
- **Interactive Preferences Window:** Manage Blocked Words, Exceptions, and Custom Prompts with a built-in live test area.
- **Automatic Permission Recovery:** Detects when Accessibility permission is granted in macOS System Settings and automatically engages the event tap.

---

## Protection Layers (everything runs inside the app: no DNS, VPN or Network Extension)

- **Adult sites: hard block, no unlock.** Built-in domains, TLDs and keywords plus two large blocklists that download and refresh themselves (StevenBlack porn-only hosts, Blocklist Project porn list; hundreds of thousands of domains stored as a compact hash index). The tab is closed on sight. Explicit searches are blocked on every site, including disguised spellings (`p0rn`, `s3xy`, `n.u.d.e`). Unknown adult sites are caught by scoring the page text. Safe image searches (Google Images, Bing, DuckDuckGo) are left alone. Everyday sites (YouTube, Netflix, Wikipedia, shops, news and similar) are never judged by the page-text scan or the image scanner, so ordinary pages are not closed; only real adult sites and explicit searches are blocked.
- **Browser lockdown.** Browsers the app can't monitor (Tor, a Windows browser in a VM, …) are closed on sight, so there is no way around the block.
- **Math gate.** Quitting, turning protection off, or loosening any setting needs a 30-second cool-off and then 10 math problems in a row (one wrong answer starts over). Entering a social-media site needs 5, then 7, then 10 problems per day, after the same 30-second wait. The problems are quick mental math: one addition or subtraction of two numbers, nothing over two digits (`47 + 28`, `63 − 19`). Optional "auto-close tab on visit". The wait before a site unlock can be switched off in Settings → Websites; that takes the 10-problem challenge (quit, disable and loosening always keep their wait).
- **Hard to kill.** Polite quit signals (Activity Monitor "Quit", `kill`, `killall`) are ignored. A second copy of the app runs as a guardian and reopens the app within about half a second if it is force-quit, and the app does the same for the guardian. Activity Monitor is closed the moment it opens while protection is on. Turn on **Start at login, and relaunch if force-quit** in Settings to add launchd as a third layer.
- **Unkillable mode (optional, needs your Mac password).** A normal app can't stop a force-quit, so this installs a tiny helper that runs as **root**: your account can't kill it, and it reopens Word Blocker within about half a second if the app is killed. With it on, quitting needs the math challenge *and* the administrator password, and so does turning it off. Switch it on in Settings; macOS shows its own password prompt (Word Blocker never sees the password).
- **On-device image scanner (optional).** Looks at the screen with an on-device model (Core ML + Vision) and blacks it out and closes the tab when it sees explicit images. Nothing leaves your Mac. Needs Screen Recording permission and the model (see below). The image model alone is overconfident (a finger and some food in a chat video scored 100% explicit), so it only proposes: with the optional body-part detector installed, it closes something only when the detector also finds an explicit body part (exposed breast, genitals, buttocks or anus). A look the detector does not confirm is logged as "flagged, not confirmed" and nothing closes. **Settings → Setup → Close images only when a second check agrees** (on by default) turns that off, to let the image model act alone with more false alarms; turning it back on needs the math challenge. Without the detector the image model acts alone, as before.
- **Block Log window.** The menu's **Show Block Log…** opens a window of everything Word Blocker closed, and exactly why: a list grouped by day (filter by All blocks, Images, Websites or Near misses, and search by reason, page or app) beside the full explanation of the selected entry. A website block names the check and the rule that matched (the built-in site list, a keyword in the site name, an explicit word or phrase in a search, an adult Reddit community or post title). A page-text block shows its score against the limit and the main terms. An image block shows the model's score for the whole screen, each quarter and each ninth as a map with the deciding part outlined, which bar it cleared, which other parts agreed, any part that was set aside because the finer tiles did not back it up, what the optional body-part detector found in that part of the screen (`female breast (exposed) 87%, face (male) 90%`), and what Apple's general picture classifier calls it (`people 93%, boxing 41%`). The scanner's model itself only gives one number per look (how likely a picture is explicit) and cannot name what it sees; the body-part and Apple labels come from other models, run only when something is logged, and only look at the part of the screen that scored highest. The body-part detector is trained on photos, so drawn or unusual pictures are often reported as having none. Near misses are high scores that were not enough to close anything. It all stays on this Mac in `~/Library/Application Support/WordBlocker/` (`blocks.jsonl` for the window, `blocks.log` as plain text): it holds the rule that matched, never search words, page text or pictures, and addresses without their query string. The optional score trace (`defaults write com.wordblocker.app WordBlocker.ScanTrace -bool true`) goes to its own `scan-trace.log`. **Teaching the scanner.** Each image entry asks "Was this explicit?" with two buttons. Your answer is kept with a fingerprint of the flagged part of the screen (a list of numbers from macOS's built-in picture feature print: not the picture, and it cannot be turned back into one; `labels.json` and `prints.jsonl` in `~/Library/Application Support/WordBlocker/`). When a later look is very close to one you marked (96% alike or more), the scanner follows what you said: a look like one you marked *not explicit* is held, and a look like one you marked *explicit* is closed even if the body-part detector found nothing. An explicit body part found by the detector always wins over a "not explicit" memory. This is a memory, not retraining: it recognises the same picture or scene again (a video that keeps scoring high), not every picture of that kind. Marking a block as wrong, or changing an "explicit" answer to "not explicit", loosens protection, so it needs the strict math challenge; everything else is free. The **Your reviews** card shows how many entries you have marked and how many of the blocks you reviewed were right.

**What it cannot do:** without Unkillable mode, a user-level app can't stop `kill -9` from Terminal, or someone who kills the app and its guardian in the same instant; they come back within about a second, but they can be killed. With Unkillable mode, only someone with the Mac's administrator password can stop it (nothing can stop an administrator who has that password; if you want that out of reach, don't be the administrator).

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

### Optional: body-part detector for the Block Log

With it, the image scanner closes something only when an explicit body part is found, and an image block says which body parts were in the flagged area, not just how sure the model was. It is [NudeNet](https://github.com/notAI-tech/NudeNet) v3 (320n, a small YOLOv8n detector, about 12 MB of weights). It is the image scanner's second opinion (an explicit body part has to confirm a block) and it writes down what was found. NudeNet and the YOLOv8 it is trained with are AGPL-3.0: fine to run on your own Mac, but do not put the converted model in a public release. Create it once:

```bash
python3 -m venv /tmp/nudenet-venv
/tmp/nudenet-venv/bin/pip install onnx onnx2torch onnxruntime torch coremltools numpy pillow
/tmp/nudenet-venv/bin/python -I scripts/convert_nudenet_model.py
```

The script downloads the ONNX weights from the NudeNet GitHub release, refuses anything that does not match a pinned SHA-256, converts them to Core ML and checks the result against ONNX Runtime. It saves `~/Library/Application Support/WordBlocker/NudeNet.mlpackage`; restart the app afterwards. Only ONNX is used, never the `.pt` checkpoints, which are pickles that can run code when loaded.

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
