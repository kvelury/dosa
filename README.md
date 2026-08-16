# Dosa 🥞 — Meeting Notes for macOS

Dosa is a native macOS meeting-notes app. It records meeting audio **directly from your Mac** — no bot joins your call — lets you jot sparse notes in a live markdown editor, and uses your configured LLM provider (Gemini, Anthropic, or DeepSeek) to turn the recording + your notes into polished, structured meeting notes. Your own words stay in the primary text color; Dosa's additions render in a configurable accent color, computed by a deterministic word-level diff.

Because audio is intercepted at the OS level (not via meeting-platform APIs), it works with **any** source: Zoom, Google Meet, Microsoft Teams, Slack huddles, browser tabs, even video files. And if the meeting was already recorded somewhere else, drop the audio or video file onto a note and it runs through the same pipeline.

## Features

- **OS-level recording** — microphone via `AVAudioEngine` + system audio via ScreenCaptureKit loopback, mixed to a single `.m4a`. Live waveform feedback while recording; playback with a scrub bar.
- **Import audio & video** — drop a file onto a note, or use ⌘O / the sidebar `+` / the ⋯ menu. Anything AVFoundation can decode works — `.mp3`, `.m4a`, `.wav`, `.aiff`, `.flac`, `.aac`, `.caf`, and video containers like `.mp4`, `.mov`, `.m4v`, whose audio track is extracted automatically. Everything is transcoded to `.m4a`, so an imported file behaves exactly like a recording from there on: transcribe, generate, play back, export.
- **Recordings can't be clobbered** — every recording gets its own never-reused filename, so no import, re-record, or crash recovery can write over audio that already exists. Attaching new audio to a note that already has some always asks first, and offers to use a fresh note instead. A capture interrupted by a crash or a dying system-audio stream is salvaged and recovered on next launch.
- **Live markdown editor** — headings, bullets, bold/italic/code render as you type; Return continues lists, Tab/⇧Tab indent, ⌘Z undo.
- **AI notes anchored on yours** — transcription with speaker identification (it knows your name from Settings), then note synthesis that preserves your manual notes (spelling/grammar corrected) and expands around them. Adjustable succinctness (5-level slider), fully editable prompts, editable results with live diff coloring. Stop button to cancel mid-run.
- **Full transcript** — speaker-labeled, timestamped, viewable in a popup and exportable.
- **Organization** — nested folders, drag & drop (into and out of folders), multi-select (⌘/⇧-click), pinning with a dedicated Pinned section, swipe gestures (right = pin, left = delete), 30-day trash.
- **Search** — global (⌘K) across titles, notes, Dosa notes, and transcripts with filter chips; in-note search (⌘F); results jump to and flash the exact match.
- **Notion export** — connect your own Notion account in the browser (OAuth via Notion's hosted MCP server — no integration registration, no embedded secrets). Dosa creates a private **"Dosa Notes" database** (Title + Date) in your workspace; exports create entries there and re-exports update the same page in place.
- **Themes** — five preset palettes (Classic, Crepe, Masala, Chutney, Slate) with light/dark variants, plus accent and diff-color overrides and an Auto/Light/Dark appearance switch.
- **Exports & backup** — notes, transcript, and recording export to `~/Downloads`; settings export/import as JSON (API key and Notion credentials deliberately excluded).

## Building & running

Requirements: macOS 14+, Xcode Command Line Tools (Swift 5.9+). No external dependencies.

```bash
./build.sh
open build/Dosa.app

# or build and install into /Applications in one step
./build.sh --install
```

`build.sh` compiles the Swift package, regenerates the brand assets (app icon + in-app mark) from the source SVGs in `Resources/Branding/`, assembles `build/Dosa.app`, and ad-hoc signs it. For quick iteration, `swift build` alone typechecks everything (but won't refresh the branding assets or produce a runnable `.app`).

Installing is opt-in: `--install` quits any running copy, then replaces `/Applications/Dosa.app`. Plain `./build.sh` never touches `/Applications`, so the edit-build-run loop can't silently swap the app you have installed. Notes and recordings live in `~/Library/Application Support/Dosa/` either way, so both copies read the same data and upgrading never migrates anything.

### First-run setup

1. **Permissions** — the first recording prompts for **Microphone**; system audio needs **Screen & System Audio Recording** (grant in System Settings, then relaunch Dosa). Because builds are ad-hoc signed, macOS may re-prompt after rebuilds. Importing needs neither permission, so it's the quickest way to try Dosa end to end.
2. **LLM provider API key** — Settings (bottom-left of the sidebar) → LLM Provider → paste your key. Three providers generate notes, each defaulting to its cheapest/fastest model:
   - **Gemini** ([get a key free](https://ai.google.dev/gemini-api/docs/api-key)) — default `gemini-3.5-flash`, with an automatic fallback chain if a model errors. The only provider that can also transcribe; transcription always runs on `gemini-3.5-flash` regardless of the model picked here, since audio is the token-heavy step and the flash tier handles it well.
   - **Anthropic** ([get a key](https://platform.claude.com/settings/keys)) — default `claude-haiku-4-5`, or pick `claude-sonnet-5` / `claude-opus-5`.
   - **DeepSeek** ([get a key](https://platform.deepseek.com/api_keys)) — default `deepseek-v4-flash`, or `deepseek-v4-pro`.

   With keys for multiple providers saved, the **Default Provider** picker at the top of the section chooses which one generates notes. Neither Anthropic nor DeepSeek accepts audio, so transcription uses whatever is set in Settings → Transcription (a Gemini key is needed only if that's Gemini (Cloud)).
3. **Your name** — Settings → Profile, so transcripts label your voice correctly.
4. **Notion (optional)** — Settings → Notion → Connect; approve in the browser and Dosa sets up the rest.

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘N | New note |
| ⌘O | Import an audio or video file into a new note |
| ⌘W | Close note (back to welcome) |
| ⌘K | Search all notes & transcripts |
| ⌘F | Search within the open note |
| ⌘Z / ⇧⌘Z | Undo / redo in the editor |
| Tab / ⇧Tab | Indent / outdent (bullets move with the line) |

## Data locations

- Notes & folders: `~/Library/Application Support/Dosa/store.json`
- Recordings: `~/Library/Application Support/Dosa/Recordings/<note-id>-<timestamp>.m4a`, with `-mic` / `-system` side tracks beside each one. Names are never reused, so replacing a note's audio leaves the previous file on disk (unlinked from the note) rather than overwriting it — handy if you ever replace one by mistake.
- In-progress captures: `Recordings/<note-id>-<timestamp>-{mic,system}.caf`, deleted once the recording is safely mixed down. Anything left there is an interrupted session, recovered automatically on next launch.
- Settings, API key, Notion tokens: app `UserDefaults` (never in this repo)

## Architecture

See **[docs/TECHNICAL_DESIGN.md](docs/TECHNICAL_DESIGN.md)** — the full technical design doc covering every subsystem, the design decisions behind them, and a consolidated list of gotchas (start there before changing the editor, the persistence model, or the Notion parsing).

High-level map:

```
Sources/Dosa/
  DosaApp / AppSettings / Theme      app entry, settings registry, theming tokens
  Models / NotesStore                data model + debounced JSON persistence
  AudioRecorder / AudioPlayer        capture (mic + ScreenCaptureKit), mixdown, playback
  RecordingImporter                  file picker + format gate for imported audio/video
  GeminiClient / AnthropicClient /
    DeepSeekClient                   REST clients for the supported LLM providers
  GenerationManager                  transcribe→generate pipeline, provider routing
  DiffEngine / SearchService         word diff, search + reveal machinery
  Notion/                            OAuth (DCR+PKCE), minimal MCP client, export logic
  Views/                             SwiftUI + AppKit-backed markdown editor
    MenuBarMenu.swift                windowless new/import/record/settings/quit actions
  Branding.swift                     in-app mark + animated template menu-bar icons
  QuitGuard.swift                    confirms quit while work is running

Resources/Branding/                  source SVGs for app, in-app, and menu-bar marks
Scripts/make_icon.swift              rasterizes Resources/Branding/*.svg into the shipped
                                      app and in-app assets (run by build.sh)
```

## Known limitations

- Gemini (Cloud) transcription requires network and a Gemini API key, and uploads audio to Google's Files API. The on-device engines (Settings → Transcription) avoid both; because the mic and system-audio tracks are kept separately, they still tell your turns from everyone else's, but can't name individual remote participants. On-Device (Advanced) needs macOS 26+, On-Device (Basic) is dictation-grade.
- For Gemini (Cloud), speaker identification is inferred by the LLM from the mixed track (not channel-separated); the on-device engines split mic vs. system audio instead (see above).
- **Imported files get no speaker separation on the on-device engines.** That split depends on Dosa having captured your mic and the system audio as two tracks, which an imported file doesn't have — so on-device transcription of an import produces unlabeled `[mm:ss]` lines. Gemini (Cloud) diarizes fine from a single file. Dosa says so in a toast at import time when an on-device engine is selected.
- WebM and Ogg/Opus files can't be imported — AVFoundation can't demux those containers, so convert to `.m4a` or `.mp4` first. Any file with no readable audio track fails with a clear message and leaves the note untouched.
- Import isn't cancellable once started, and very large video files are transcoded in full before the note updates.
- Dosa remains a normal Dock app and also has a persistent menu-bar item. Its icon geometry comes from `dosa-menubarTemplate.svg` and `dosa-menubarRecordingTemplate.svg`; while recording, the two dashed rings counter-rotate around a fixed filled core. Menu actions can recreate the main window for new notes, imports, recording, and Settings.
- Ad-hoc signing means permission grants can reset on rebuild.
- Notion sync is one-way (export/update); bi-directional sync is designed but not built (see the design doc §10.4).
- The OpenAI provider tab in Settings is a stub; Gemini, Anthropic, and DeepSeek are the working providers.
