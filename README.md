# Dosa 🥞 — Meeting Notes for macOS

Dosa is a native macOS meeting-notes app. It records meeting audio **directly from your Mac** — no bot joins your call — lets you jot sparse notes in a live markdown editor, and uses your configured LLM provider (Gemini or DeepSeek) to turn the recording + your notes into polished, structured meeting notes. Your own words stay in the primary text color; Dosa's additions render in a configurable accent color, computed by a deterministic word-level diff.

Because audio is intercepted at the OS level (not via meeting-platform APIs), it works with **any** source: Zoom, Google Meet, Microsoft Teams, Slack huddles, browser tabs, even video files.

## Features

- **OS-level recording** — microphone via `AVAudioEngine` + system audio via ScreenCaptureKit loopback, mixed to a single `.m4a`. Live waveform feedback while recording; playback with a scrub bar.
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
```

`build.sh` compiles the Swift package, regenerates the brand assets (app icon + in-app mark) from the source SVGs in `Resources/Branding/`, assembles `build/Dosa.app`, and ad-hoc signs it. For quick iteration, `swift build` alone typechecks everything (but won't refresh the branding assets or produce a runnable `.app`).

### First-run setup

1. **Permissions** — the first recording prompts for **Microphone**; system audio needs **Screen & System Audio Recording** (grant in System Settings, then relaunch Dosa). Because builds are ad-hoc signed, macOS may re-prompt after rebuilds.
2. **LLM provider API key** — Settings (bottom-left of the sidebar) → LLM Provider → paste your key. Gemini is the default ([get a key free](https://ai.google.dev/gemini-api/docs/api-key)); default model is `gemini-3.5-flash`, with an automatic fallback chain if a model errors. DeepSeek is also supported for note generation ([get a key](https://platform.deepseek.com/api_keys); default model `deepseek-v4-flash`) — but transcription always runs on Gemini, since DeepSeek doesn't accept audio, so keep a Gemini key saved either way. With keys for multiple providers saved, the **Default Provider** picker at the top of the section chooses which one generates notes.
3. **Your name** — Settings → Profile, so transcripts label your voice correctly.
4. **Notion (optional)** — Settings → Notion → Connect; approve in the browser and Dosa sets up the rest.

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘N | New note |
| ⌘W | Close note (back to welcome) |
| ⌘K | Search all notes & transcripts |
| ⌘F | Search within the open note |
| ⌘Z / ⇧⌘Z | Undo / redo in the editor |
| Tab / ⇧Tab | Indent / outdent (bullets move with the line) |

## Data locations

- Notes & folders: `~/Library/Application Support/Dosa/store.json`
- Recordings: `~/Library/Application Support/Dosa/Recordings/*.m4a`
- Settings, API key, Notion tokens: app `UserDefaults` (never in this repo)

## Architecture

See **[docs/TECHNICAL_DESIGN.md](docs/TECHNICAL_DESIGN.md)** — the full technical design doc covering every subsystem, the design decisions behind them, and a consolidated list of gotchas (start there before changing the editor, the persistence model, or the Notion parsing).

High-level map:

```
Sources/Dosa/
  DosaApp / AppSettings / Theme      app entry, settings registry, theming tokens
  Models / NotesStore                data model + debounced JSON persistence
  AudioRecorder / AudioPlayer        capture (mic + ScreenCaptureKit), mixdown, playback
  GeminiClient / DeepSeekClient      REST clients for the supported LLM providers
  GenerationManager                  transcribe→generate pipeline, provider routing
  DiffEngine / SearchService         word diff, search + reveal machinery
  Notion/                            OAuth (DCR+PKCE), minimal MCP client, export logic
  Views/                             SwiftUI + AppKit-backed markdown editor
  Branding.swift                     in-app brand mark (DosaMark), tinted per appearance

Resources/Branding/                  source SVGs for the app icon + in-app mark
Scripts/make_icon.swift              rasterizes Resources/Branding/*.svg into the shipped
                                      AppIcon.icns and dosa-mark-{light,dark}.png (run by build.sh)
```

## Known limitations

- Gemini (Cloud) transcription requires network and a Gemini API key, and uploads audio to Google's Files API. The on-device engines (Settings → Transcription) avoid both; because the mic and system-audio tracks are kept separately, they still tell your turns from everyone else's, but can't name individual remote participants. On-Device (Advanced) needs macOS 26+, On-Device (Basic) is dictation-grade.
- For Gemini (Cloud), speaker identification is inferred by the LLM from the mixed track (not channel-separated); the on-device engines split mic vs. system audio instead (see above).
- The menu-bar template icons in `Resources/Branding/` (`dosa-menubarTemplate.svg`, `dosa-menubarRecordingTemplate.svg`) aren't wired up yet — Dosa has no menu-bar-extra status item today, so they're reserved for if/when that's built.
- Ad-hoc signing means permission grants can reset on rebuild.
- Notion sync is one-way (export/update); bi-directional sync is designed but not built (see the design doc §10.4).
- Anthropic/OpenAI provider tabs in Settings are stubs; Gemini and DeepSeek are the working providers.
