# Xinori Notch AI

An AI assistant that lives in the MacBook Pro notch. Click the notch, a panel
springs out, and you type or talk to a model that can actually reach into your
Mac — mail, calendar, files, scheduled jobs, the shell.

Runs against a **local model by default** (Ollama), so the everyday path never
leaves your machine. Anthropic, OpenAI and Moonshot are there when you want more
capability.

> The app's interface is Dutch. Code, comments and this README are English.

## What it does

| | |
|---|---|
| **Lives in the notch** | Hover and it grows; click or force-click and the panel opens with a haptic tick. Escape or a click elsewhere closes it. |
| **Local first** | `qwen3:8b` via Ollama, pinned in memory so there's no load stall between opening and the first token. |
| **Talks and listens** | On-device speech-to-text (`SpeechAnalyzer` / `DictationTranscriber`), spoken replies via `AVSpeechSynthesizer`. Nothing is uploaded. |
| **Reaches into your Mac** | Tool calling: it reads your inbox, checks the calendar, finds files, lists and creates scheduled jobs, runs shell commands. |
| **Asks before it acts** | Read-only tools run freely. Anything that changes state stops and shows you the exact call for approval. |
| **Sets itself up** | First launch walks you through installing Ollama and pulling a model, with a real progress bar. Settings live in the notch too — no separate preferences window. |

## Requirements

- MacBook with a notch, macOS 26 or later
- [Ollama](https://ollama.com) with a tool-capable model: `ollama pull qwen3:8b`
- Xcode 26 (to build)

## Install

```bash
curl -fsSL https://sicparvisventures.github.io/xinori-notch-ai/install.sh | bash
```

That fetches the latest release, puts it in `/Applications` and launches it.

**Why a script rather than "download the zip".** The app is ad-hoc signed — no
paid Apple Developer account — so a browser download gets quarantined and
Gatekeeper refuses to open it. Since macOS 15 the old right-click → **Open**
bypass no longer works for unsigned apps either; you have to go to System
Settings → Privacy & Security and click **Open Anyway**. A file fetched with
`curl` is never quarantined in the first place, so the script simply doesn't
create the problem. It strips the attribute explicitly anyway, in case the zip
came from a browser.

Manual install still works — grab the `.zip` from [Releases](../../releases) and
use the **Open Anyway** route above.

Or build it yourself:

```bash
git clone https://github.com/sicparvisventures/xinori-notch-ai
cd xinori-notch-ai
./scripts/run.sh
```

## Tools

| Tool | Does | Runs |
|---|---|---|
| `system_info` | Battery, disk, memory | freely |
| `search_files` | Spotlight search by name or content | freely |
| `list_directory` | Contents of a folder with sizes and dates | freely |
| `read_file` | Reads a text file | freely |
| `read_spreadsheet` | Reads .xlsx (via openpyxl) or CSV | freely |
| `frontmost_app` | What app and window is in front | freely |
| `list_apps` | Installed and running applications | freely |
| `list_mail` | Inbox via Mail's own index — needs Full Disk Access | freely |
| `search_notes` / `read_note` | Apple Notes, incl. bodies (gzip protobuf) — needs Full Disk Access | freely |
| `search_messages` | iMessage and SMS — needs Full Disk Access | freely |
| `browser_history` | Safari history — needs Full Disk Access | freely |
| `list_reminders` | Open reminders via EventKit | freely |
| `search_contacts` | Contacts by name | freely |
| `list_shortcuts` | Every Shortcut on the machine | freely |
| `clipboard_read` | What's on the clipboard | freely |
| `list_calendar` | Upcoming events via EventKit | freely |
| `compose_mail` | Opens a prefilled compose window — you send | **asks first** |
| `create_calendar_event` | Adds an event to your default calendar | **asks first** |
| `list_scheduled_jobs` | Your launchd agents | freely |
| `write_file` | Creates or overwrites a file | **asks first** |
| `move_to_trash` | Moves to the Trash — never `unlink` | **asks first** |
| `open_path` | Opens a file, folder or URL | **asks first** |
| `control_app` | Activates or quits an app | **asks first** |
| `schedule_job` | Creates a recurring launchd job | **asks first** |
| `create_note` | Writes a note to Apple Notes | **asks first** |
| `create_reminder` | Adds a reminder | **asks first** |
| `run_shortcut` | Runs any Shortcut you've built | **asks first** |
| `clipboard_write` | Puts text on the clipboard | **asks first** |
| `run_shell` | Arbitrary shell command | **asks first** |

Adding a tool means conforming to `Tool` and adding it to `ToolRegistry.tools`.
The schema and the approval behaviour follow from the type.

`run_shortcut` is worth singling out: it makes the toolset extensible **without
code**. Anything you can build in Shortcuts becomes callable, which is a better
answer to "let the AI make its own tools" than a `create_tool` that writes shell
templates — you built the Shortcut, so the boundary stays where it belongs.

### The safety model

An LLM driving your Mac is only as safe as what it can do without you. So:

- Every tool declares a `risk`. `readOnly` runs immediately; `mutating` suspends
  the turn until you approve or deny in the panel.
- The prompt shows the **exact call with its arguments**. Approving something you
  can't read isn't consent.
- `run_shell` is `mutating` even for commands that only read, because the model
  can't reliably tell `ls` from `rm -rf` in a string it composed itself.
- Read-only tools invoke executables directly with an argument array, never
  through a shell, so an argument containing `;` or backticks is data rather than
  syntax. `run_shell` is the single deliberate exception.
- Nothing is auto-approved and there is no "always allow" — by design.

## Choosing a model

Settings lists a catalogue of tool-capable local models with the one fact that
decides the choice: how much memory each needs. The app reads this machine's RAM,
subtracts a reserve for macOS and your other apps (30% or 6 GB, whichever is
larger), and marks each model **past goed** / **krap** / **te groot** against
what's left — then recommends the largest one that still sits comfortably.

On a 24 GB M5 that budget is 16.8 GB, so `qwen3:14b` (8.7 GB) is recommended,
`gpt-oss:20b` is flagged tight and `qwen3:30b-a3b` too large. Download happens
in place with a real progress bar.

Sizes are the actual layer totals from the Ollama registry, not estimates — an
"8B" model is anywhere from 4.5 to 9 GB depending on quantisation, and it's the
bytes that have to fit.

## Setup and settings

On first launch an onboarding flow runs inside the notch: it detects whether
Ollama is installed and running, offers to launch it, and pulls `qwen3:8b` with a
live progress bar (the byte counters come straight from Ollama's `/api/pull`
stream). Cloud provider keys are optional and can be skipped.

Everything is reconfigurable afterwards from the gear icon: provider, model,
tools on/off, spoken replies, API keys, and the Ollama status. Keys go to the
macOS Keychain, never to a settings file.

## Permissions

macOS will ask, once each: **microphone** and **speech recognition** for
dictation, and **calendars** for events. Deny either and only that tool stops
working.

**Full Disk Access is needed for `list_mail`** and has to be granted by hand:
System Settings → Privacy & Security → Full Disk Access. Settings has a button
that opens the pane. Without it `~/Library/Mail` isn't even listable, which is
indistinguishable from "no mail account" unless you check for it — so the tool
reports the permission explicitly rather than sending the model off to help you
set up an account you already have.

> **Don't launch the binary directly** (`./build/NotchAI.app/Contents/MacOS/NotchAI`).
> TCC attributes a privacy request to the *responsible* process, which for a
> directly-executed binary is the terminal or IDE you launched from — not the app.
> If that lacks `NSSpeechRecognitionUsageDescription`, NotchAI aborts on the first
> speech request claiming *its own* Info.plist is missing the key, which it isn't.
> The crash report gives it away: `responsible: <your IDE>`. Use `./scripts/run.sh`
> (which goes through `open`) or run from Xcode.

## Build and run

```bash
./scripts/run.sh                     # build, launch, tail the log
./scripts/run.sh --check-permissions # request mic + speech, print the outcome
./scripts/run.sh --dictate           # 8 seconds of headless dictation
./scripts/run.sh --ask "…"           # one full turn incl. tools, printed
./scripts/release.sh v0.1.0          # release build + zip in dist/
```

Stop with `pkill -f NotchAI`. Logs land in `build/NotchAI.log`.

The `--ask` mode is the quickest way to see the tool loop work:

```
$ ./scripts/run.sh --ask "Hoeveel batterij heb ik nog?"
tool: system_info(topic: battery)
assistant: Je hebt 23% batterij over.
```

## Architecture

**Notch** — geometry is measured at runtime from `screen.auxiliaryTopLeftArea` /
`auxiliaryTopRightArea` and `safeAreaInsets.top`; nothing is hardcoded. The panel
is an `NSPanel` at `CGShieldingWindowLevel()` (`.statusBar` sits *below* the
full-screen menu bar overlay). It's always sized for the largest state, so most
of it is transparent — `NotchContainerView.hitTest` clips interaction to the
visible shape, otherwise an invisible rectangle would swallow every menu bar
click. `NotchShape`'s two concave top corners are what make it read as hardware;
the radii are `animatableData` so the shape itself morphs.

**AI** — one `LLMProvider` protocol: messages and tool schemas in, a stream of
text and tool calls out. NDJSON vs. SSE and each provider's tool dialect stay
behind it.

**Tools** — `Tool` protocol, `ToolRegistry`, and the risk-based approval gate
described above.

**Mail** — read through Mail's own SQLite envelope index
(`~/Library/Mail/V*/MailData/Envelope Index`, opened `immutable=1`), not
AppleScript. Mail does not service Apple Events reliably: on the development
machine even `count of messages of inbox` returns -1712 after 40 seconds. And
`messages whose read status is false` forces a full mailbox walk over Apple
Events, which is hopeless at 30k messages. The index answers in milliseconds.
Note `line` is a reserved word in AppleScript — `set line to …` fails with
-10003, which is what the first implementation hit.

**Voice** — two speech engines, because neither covers everything.
`SpeechTranscriber` is the better one but ships only 30 locales; Dutch isn't
among them. `DictationTranscriber` covers 54 including `nl_BE` and `nl_NL`.
Note that `SpeechTranscriber.supportedLocale(equivalentTo:)` cannot be trusted to
decide — asked about `nl_BE` it returns `nl_BE`, and the asset download then fails.
Match against `supportedLocales` instead.

## Known limitations

- **Not notarized.** See the first-launch note above.
- **External displays.** Without a notch (`safeAreaInsets.top == 0`) the app
  exits. A floating-pill fallback is not built yet.
- **Default model IDs for OpenAI and Moonshot are guesses.** The picker fetches
  the real list from each provider once a key is set, and corrects itself.
- **Now Playing is not built.** `MediaRemote`'s read path does still work on
  macOS 26.5 (verified: symbols resolve and a published entry reads back with
  title, artist, duration), contrary to the post-15.4 lockdown reports. It
  remains private API, so put it behind a flag that degrades to "no now playing"
  rather than crashing.

## License

MIT — see [LICENSE](LICENSE).
