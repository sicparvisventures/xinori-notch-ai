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

## Requirements

- MacBook with a notch, macOS 26 or later
- [Ollama](https://ollama.com) with a tool-capable model: `ollama pull qwen3:8b`
- Xcode 26 (to build)

## Install

Grab the `.zip` from [Releases](../../releases), unzip, drop `NotchAI.app` in
`/Applications`.

**First launch:** the build is ad-hoc signed, not notarized, so macOS quarantines
it. Right-click the app → **Open** → **Open** — once. Double-clicking works from
then on. (Or `xattr -dr com.apple.quarantine /Applications/NotchAI.app`.)

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
| `frontmost_app` | What app and window is in front | freely |
| `list_mail` | Inbox via Mail.app | freely |
| `list_calendar` | Upcoming events via EventKit | freely |
| `list_scheduled_jobs` | Your launchd agents | freely |
| `schedule_job` | Creates a recurring launchd job | **asks first** |
| `run_shell` | Arbitrary shell command | **asks first** |

Adding a tool means conforming to `Tool` and adding it to `ToolRegistry.tools`.
The schema and the approval behaviour follow from the type.

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

## Permissions

macOS will ask, once each: **microphone** and **speech recognition** for
dictation, **automation** for Mail, **calendars** for events. Deny any of them
and only that tool stops working.

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
