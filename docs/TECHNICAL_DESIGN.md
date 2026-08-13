# Dosa — Technical Design Document

**App**: Dosa, a native macOS meeting-notes app
**Source**: `~/Desktop/DosaApp`
**Version**: 1.0 · macOS 14+ · Swift 5.9 language mode (built with Swift 6.1 toolchain)
**Audience**: This doc is the canonical reference for continuing development (human or Claude). It captures architecture, implementation details, design decisions, and gotchas discovered during development.

---

## 1. What Dosa does

Dosa records meeting audio **directly from the Mac** (no bot joins the call), lets the user take sparse manual notes in a live markdown editor, then uses the **configured LLM provider** (Gemini, Anthropic, or DeepSeek) to (1) transcribe the recording with speaker identification and (2) synthesize polished meeting notes anchored on the user's manual notes. (Only Gemini accepts audio; with Anthropic or DeepSeek selected, transcription falls to the engine chosen in Settings → Transcription.) Generated notes render with a deterministic word-level diff: the user's words in the primary text color, Dosa's additions in a configurable grey/color. Notes can be organized in nested folders, pinned, searched globally, exported to disk, and exported to a **Notion database** that Dosa creates automatically via Notion's hosted MCP server.

Because audio is intercepted at the OS level (ScreenCaptureKit loopback + mic), it works with any source: Zoom, Meet, Teams, Slack huddles, browser tabs, video files.

---

## 2. Build system & project layout

**Swift Package (SPM), not Xcode project.** Built with `swift build`, assembled into a `.app` bundle by `build.sh`:

1. `swift build -c release`
2. Regenerates the brand assets via `Scripts/make_icon.swift`, unconditionally, every build (no longer guarded behind "if missing" — a stale icon/mark from before a source-SVG change is worse than the ~1s regeneration cost):
   - `Resources/AppIcon.icns`: rasterizes `Resources/Branding/dosa-icon-1024.svg` (brown tile, amber mark) via `NSImage(contentsOfFile:)` — verified pixel-accurate for this file's plain SVG feature set — then packages the usual resolution set with `sips` + `iconutil`.
   - `Resources/dosa-mark-{light,dark}.png`: rasterizes `Resources/Branding/dosa-mark-currentcolor.svg` (a template shape — solid black, transparent elsewhere) once, then tints it twice via `NSColor.set()` + `NSRect.fill(using: .sourceIn)` (the same alpha-preserving technique AppKit uses internally for `.isTemplate` images) — brown `#7A4512` for light appearance, amber `#E0A44E` for dark. Same brand pairing `dosa-mark-adaptive.svg` encodes via CSS, reproduced natively because that file's `@media (prefers-color-scheme:)` rules render inconsistently through `NSImage`/ImageIO (confirmed: mixed light/dark rule results within one raster) — not safe for native rendering.
3. Assembles `build/Dosa.app/Contents/{MacOS/Dosa, Info.plist, Resources/{AppIcon.icns, dosa-mark-light.png, dosa-mark-dark.png}}`
4. **Ad-hoc codesigns** (`codesign --force --sign -`)

**Dev loop**: `swift build` to typecheck; `./build.sh && open build/Dosa.app` to ship. Kill the running app first (`pkill -x Dosa`).

> **CALLOUT — TCC and ad-hoc signing**: every rebuild re-signs with a new ad-hoc identity, so macOS may re-prompt for Microphone and Screen & System Audio Recording permissions after rebuilds. This is expected. A real Developer ID cert would fix it.

```
Sources/Dosa/
  DosaApp.swift          @main App; AppState; menu-bar commands (⌘N/⌘W/⌘K/⌘F)
  AppSettings.swift      All UserDefaults keys, default prompts, verbosity, appearance
  Theme.swift            Preset palettes + accent override + styleFingerprint
  Models.swift           Note, Folder, TimeFormatting
  NotesStore.swift       Persistence, folders, pins, trash, stats
  AudioRecorder.swift    Mic + system-audio capture, m4a mixdown, level metering
  AudioPlayer.swift      Playback with pause/seek/progress
  GeminiClient.swift     Gemini REST client + DetailedError protocol
  AnthropicClient.swift  Anthropic Messages API REST client (text-only)
  DeepSeekClient.swift   DeepSeek chat/completions REST client (text-only)
  GenerationManager.swift  Transcribe→generate pipeline, cancellation, post-processing
  DiffEngine.swift       Tokenizer + attributed diff + Dosa-color registry
  SearchService.swift    Match finding, snippets, SearchCoordinator (reveal bus)
  Notion/
    NotionAuth.swift     OAuth 2.1: discovery, DCR, PKCE, loopback HTTP server
    NotionMCPClient.swift  Minimal MCP client (JSON-RPC + SSE over Streamable HTTP)
    NotionManager.swift  Connection state, Dosa Notes DB, export, tolerant parsing
  Views/
    ContentView.swift    NavigationSplitView; selection bridging; theme tick
    SidebarView.swift    Multi-select list, pins, drag&drop, swipes, settings footer
    SidebarDeselectCatcher.swift  Empty-click deselection via NSEvent monitor
    NoteEditorView.swift Editor, floating bar, ⋯ menu, error sheet, exports
    MarkdownTextEditor.swift  PaddedTextView + Coordinator + MarkdownStyler
    TranscriptView.swift Transcript sheet (read-only MarkdownTextEditor)
    SearchViews.swift    Global search sheet, in-note popover, filter chips
    SettingsView.swift   All settings sections + export/import
    WelcomeView.swift    Greeting, stats, shortcut hints
    DeletedNoteView.swift  Trash preview with restore/delete
    SharedViews.swift    RecordingWaveformView, ErrorDialogView, MultiSelectionView
  Branding.swift         DosaMark view — loads dosa-mark-{light,dark}.png from Bundle.main,
                         picks by @Environment(\.colorScheme)
Resources/Info.plist    Bundle metadata + NSMicrophoneUsageDescription + NSAudioCaptureUsageDescription
Resources/Branding/     Source SVGs (app icon, in-app mark, menu-bar templates — see §2b)
build.sh / Scripts/make_icon.swift
```

### 2b. Branding assets (`Resources/Branding/`, `Scripts/make_icon.swift`, `Branding.swift`)

All 7 source SVGs delivered with the current logo are committed under `Resources/Branding/` as the source of truth, but only two are wired into the app today:

- `dosa-icon-1024.svg` → the app icon (`Resources/AppIcon.icns`).
- `dosa-mark-currentcolor.svg` → the in-app brand mark (`DosaMark`), shown at `WelcomeView`'s hero size and in the sidebar footer next to the version/model line.

Both use `NSImage(contentsOfFile:)` to rasterize the *actual* SVG at build time rather than hand-reproducing the geometry in AppKit/SwiftUI — verified pixel-accurate against these files (plain `<rect>`/`<g transform>`/`<circle>` + `stroke-dasharray`, no CSS). `DosaMark` itself does zero SVG/asset loading at runtime beyond reading two plain PNGs baked at build time (`dosa-mark-light.png` / `dosa-mark-dark.png`) via `Bundle.main` — deliberately *not* SwiftPM's `resources:`/`Bundle.module` mechanism, since this project hand-assembles its `.app` in `build.sh` rather than letting SwiftPM produce one, and `Bundle.module`'s companion resource bundle would need its own separate copy step to land inside `build/Dosa.app/Contents/Resources/`. Reusing the exact `Resources/` → `cp` → `Bundle.main` path already proven for `Info.plist`/`AppIcon.icns` avoids that whole class of packaging bug.

The mark is brand-fixed brown/amber (`#7A4512` / `#E0A44E`) regardless of which of the 5 accent-theme presets is selected — it switches only on light/dark **appearance** (`@Environment(\.colorScheme)`, which follows `AppSettings`'s Auto/Light/Dark override same as the rest of the app), since every theme preset's `editorBackground` is a near-white/near-black neutral (see §8) — the brown/amber pair reads fine against all of them.

**Not yet wired up**: `dosa-menubarTemplate.svg` / `dosa-menubarRecordingTemplate.svg` — flat-black idle/recording icons sized for an `NSStatusItem`/`MenuBarExtra`, which Dosa doesn't have. `dosa-mark-cream.svg` (a lighter alternate mark, e.g. for a dark solid-color hero) and `dosa-mark-adaptive.svg` (the CSS self-adapting version — kept as reference for the intended color pairing, not for rendering) are also unused. All are preserved in `Resources/Branding/` for whenever those features exist.

**Window chrome**: `.windowStyle(.hiddenTitleBar)` — no title bar; traffic lights overlay the sidebar's top-left, which is why the sidebar's icon row has `.padding(.top, 34)`.

---

## 3. Data model & persistence

### 3.1 Models (`Models.swift`)

```swift
struct Folder { id, name, parentId: UUID? }          // nested via parentId
struct Note {
  id, title, createdAt, folderId: UUID?
  manualText: String                                  // the user's own notes (markdown)
  enhancedMarkdown: String?                           // Dosa-generated notes; nil until generated
  transcript: String?                                 // cached speaker-labeled transcript
  recordingFileName: String?  recordingDuration: TimeInterval?
  notionPageId: String?  notionPageURL: String?       // set on first Notion export
  pinnedAt: Date?                                     // nil = unpinned; ordering key
  deletedAt: Date?                                    // nil = active; drives 30-day trash
}
```

> **CALLOUT — Codable migration rule**: `NotesStore.load()` uses `try? decode` — if decoding throws, **all notes appear lost** (file isn't overwritten until next save, but the UI shows empty). Therefore every new `Note`/`Folder` field MUST be `Optional` (like `pinnedAt`, `notionPageId`) so old `store.json` files still decode. Never add a non-optional field without writing a custom `init(from:)`.

### 3.2 NotesStore

- Plain `ObservableObject` (deliberately **not** `@MainActor` — avoids Binding-closure isolation friction; all access happens on main in practice).
- Persistence: single JSON `~/Library/Application Support/Dosa/store.json` (`Snapshot { notes, folders }`, ISO-8601 dates, pretty-printed). Saves are **debounced 400 ms** (`scheduleSave()`); `persistNow()` also runs on `NSApplication.willTerminateNotification`.
- Recordings: `~/Library/Application Support/Dosa/Recordings/<noteId>.m4a`.
- `noteBinding(id:) -> Binding<Note>?` — lookup-by-id in both get/set (index-free, safe against reordering). The editor binds `TextField`/editors through this; every keystroke goes through `update(_:)` → debounced save.
- Trash: `moveToTrash` sets `deletedAt`; `purgeExpiredDeletedNotes()` (called in `init`) permanently deletes anything older than `trashRetentionDays = 30`; `deletePermanently` also removes the recording file.
- Pins: `togglePin(Set<UUID>)` — pins all if any target is unpinned, else unpins all. `notes(in:)` **excludes pinned notes** (they render only in the Pinned section); `pinnedNotes` sorts by `pinnedAt` desc.
- Stats for the welcome screen: `meetingsRecorded`, `totalRecordedTimeText`, `notesGeneratedCount`.

---

## 4. Audio pipeline (`AudioRecorder.swift`)

Two simultaneous captures, both written to temp `.caf` files during recording, mixed to one `.m4a` on stop:

| Stream | API | Notes |
|---|---|---|
| Microphone | `AVAudioEngine.inputNode` tap (4096 frames) | Float32 deinterleaved; written on `sampleQueue` |
| System audio | `SCStream` with `capturesAudio = true`, `excludesCurrentProcessAudio = true` | Video shrunk to 2×2 @ 0.5fps (SCStream requires a video config); audio callback converts `CMSampleBuffer` → `AVAudioPCMBuffer` via `withAudioBufferList` + `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` |

- **Permissions**: mic via `AVCaptureDevice.requestAccess(.audio)`; system audio needs Screen & System Audio Recording (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`; grant requires app relaunch — the thrown error explains this).
- **Threading**: all file writes on the serial `sampleQueue`; files are closed on that queue via a checked continuation before mixing (flush guarantee). Published props mutated on main.
- **Mixdown**: `AVMutableComposition` with both tracks inserted at `.zero` → `AVAssetExportSession(presetName: AVAssetExportPresetAppleM4A)` → `.m4a`. The same `mix` helper then runs once per source to keep `<id>-mic.m4a` / `<id>-system.m4a` beside it (see §5.1c) — roughly doubling recording storage, in exchange for on-device speaker attribution. `await session.export()` is deprecated on macOS 15 but functional. Small start-time skew between mic/system (~100s of ms) is accepted.
- **Level metering** (drives the waveform): RMS is computed per buffer (every 8th sample) for both streams; `peakLevel` (sampleQueue-owned) keeps the max and decays ×0.5 each tick. A 0.09 s main-thread timer shifts `levelHistory: [Float]` (7 entries, scaled `min(1, rms*7)`), consumed by `RecordingWaveformView` (7 animated capsules).
- Re-recording is only possible after **Discard Recording** (⋯ menu) — setting a new recording clears `transcript` (`setRecording`), and discarding clears recording+transcript but keeps `enhancedMarkdown`.

`AudioPlayer`: AVAudioPlayer wrapper with `play/togglePlayPause/seek/stop`, publishes `currentTime`/`duration` via a 0.25 s timer. The floating bar grows a scrub row (slider + times + ✕) whenever `playingNoteId == noteId`.

---

## 5. LLM pipeline

### 5.1 GeminiClient (`GeminiClient.swift`)

- REST, no SDK. `generateContent` at `v1beta/models/<model>:generateContent?key=`.
- **Audio upload**: Files API resumable protocol (`/upload/v1beta/files`, headers `X-Goog-Upload-*`, start→upload+finalize), then poll `files/<name>` until `state != PROCESSING`. Mime type `audio/mp4` for the `.m4a`.
- **Model fallback chain** (`generateContent(parts:)`): tries the configured model, then `AppSettings.fallbackModels` (`gemini-3.5-flash`, `gemini-3-flash-preview`, `gemini-flash-latest`) on HTTP 5xx / 404 / 429.

> **CALLOUT — model landscape (as of Aug 2026)**: `gemini-flash-latest` resolves to `gemini-3.6-flash`, which **returns 500 on any audio input** (text works). That's why the default model is pinned to `gemini-3.5-flash` (verified working with audio) and why the fallback chain exists. `AppSettings.retiredModelRemap` maps retired names (e.g. `gemini-2.5-flash`, which 404s "no longer available to new users") to living ones — applied at read time and on Settings appear.

- `DetailedError` protocol (declared here): `errorDetail: String?` carries raw response bodies (truncated 4000 chars) for the error dialog's "technical details". `GeminiError` cases all carry payloads.

### 5.1b DeepSeekClient (`DeepSeekClient.swift`)

- REST, no SDK. OpenAI-compatible `POST https://api.deepseek.com/chat/completions` with `Authorization: Bearer` — single user message, `stream: false`, first choice's `message.content` returned.
- **Text-only**: DeepSeek has no audio/files endpoint, so it can only serve the note-generation step; transcription stays on Gemini even when DeepSeek is the selected provider.
- Models: `deepseek-v4-flash` (default — fast/cheap) and `deepseek-v4-pro` (`AppSettings.availableDeepSeekModels`; lineup per api-docs.deepseek.com as of Aug 2026). `AppSettings.resolveDeepSeekModel` remaps the retired `deepseek-chat`/`deepseek-reasoner` names and any unknown stored value to a current model. No fallback chain (nothing to fall back to).
- `DeepSeekError` conforms to `DetailedError` like `GeminiError` (friendly summary + raw payload for the error dialog).

### 5.1bb AnthropicClient (`AnthropicClient.swift`)

- REST, no SDK — Anthropic ships no official Swift SDK. `POST /v1/messages` with `x-api-key` + `anthropic-version: 2023-06-01`; single user message; text blocks of the response `content` array joined.
- **Text-only**, same as DeepSeek: no audio endpoint, so it serves note generation only.
- Models (`AppSettings.availableAnthropicModels`, IDs verified against platform.claude.com Aug 2026): `claude-haiku-4-5` (default — cheapest/fastest tier, $1/$5 per MTok), `claude-sonnet-5`, `claude-opus-5`. IDs are complete as written and never take a date suffix. `resolveAnthropicModel` falls back to the default for any unknown stored value.
- **No `thinking` / `effort` parameters are sent.** Haiku 4.5 supports neither and would 400; left unset, Sonnet 5 and Opus 5 think adaptively by default while Haiku answers directly. `max_tokens` (16K) therefore has to cover thinking *plus* the reply on the thinking models — sized well above what notes need, and kept low enough that the non-streaming request can't hit an HTTP timeout.
- **`stop_reason: "refusal"` is checked before reading content.** A safety decline is a successful HTTP 200 with empty or partial content, so indexing the content blocks first would surface it as a confusing "unexpected response" rather than a refusal. `AnthropicError` conforms to `DetailedError`.
- **Only `type == "text"` blocks are joined.** Verified against the live API (Aug 2026): on a realistic notes prompt, `claude-sonnet-5` returns `["thinking", "text"]` — the thinking block is empty-texted (`display` defaults to omitted) but present, and must not reach the notes.
- **`stop_reason: "max_tokens"` with no text block → `.truncated`**, not `.malformedResponse`. Reproduced on both `claude-sonnet-5` and `claude-opus-5`: a hard prompt against a tight budget returns `["thinking"]` alone, thinking having consumed the whole allowance. A *partial* text block is returned as-is instead (same as `GeminiClient`/`DeepSeekClient` do) rather than discarding usable notes.
- **Runtime-verified end to end (Aug 2026):** all three model IDs accepted, `claude-haiku-4-5` resolving to `claude-haiku-4-5-20251001`, with a realistic notes prompt producing correct Markdown.

### 5.1c AppleTranscriber (`AppleTranscriber.swift`) — on-device transcription

- `AppSettings.TranscriptionEngine`: `.gemini` (default) / `.appleAdvanced` / `.appleBasic`, stored under `transcriptionEngine`; `resolvedTranscriptionEngine` degrades Advanced→Basic when unavailable.
- **Advanced** = macOS 26 `SpeechAnalyzer`/`SpeechTranscriber` (long-form model, asset auto-download via `AssetInventory`). Compile-gated with `#if canImport(FoundationModels)` (a 26-SDK-only framework) so the project still builds on older SDKs — on a 15.x SDK the code is simply absent and `advancedAvailable == false`. **This path is unverified until built with a macOS 26 SDK.**
- **Basic** = `SFSpeechRecognizer` file recognition: partials off, punctuation on, `requiresOnDeviceRecognition` when supported (server path caps at ~1 min). Needs `NSSpeechRecognitionUsageDescription` (in `Resources/Info.plist`) + per-user Speech Recognition permission.

> **CALLOUT — Basic needs macOS Dictation switched on.** The on-device recognizer *is* the Dictation model, so with Dictation off the daemon fails every request with `kLSRErrorDomain` 201 "Siri and Dictation are disabled" — `recognizer.isAvailable` still reports true, so it can't be pre-flighted. `AppleTranscriber.mapped(_:)` translates that into a `.dictationDisabled` error pointing at System Settings → Keyboard → Dictation. Not a fallback candidate: retrying with `requiresOnDeviceRecognition = false` would ship audio to Apple's servers and cap at ~1 min, defeating the point of the on-device engine.
- **Two-way speaker attribution without diarization**: `AudioRecorder.stop` now also exports each source on its own — `<id>-mic.m4a` / `<id>-system.m4a` next to the mixed `<id>.m4a` (best-effort; a failed side export never fails the recording). `AppleTranscriber.transcribe(micURL:systemURL:…)` transcribes both, labels mic lines with the user's name (or "You") and system lines "Others", and interleaves by timestamp into the app's usual `**Speaker** [mm:ss]: …` format. Remote participants can't be told apart — they share the system track.
- **Echo suppression**: without headphones the mic also captures the other participants, so a mic line is dropped when a system line within ±3 s shares ≥50% of its words (`isEcho`, Jaccard-ish over lowercased word sets).
- Recordings made before per-track capture have no side files: `NotesStore.trackURL(for:_:)` returns nil and transcription falls back to the mixed file as unlabeled `[mm:ss] …` lines (word segments grouped on >1.2 s pauses / ~25 s spans). `deletePermanently`/`discardRecording` clean up side tracks via `removeRecordingFiles`.
- The transcript prompt (and `{{user_name}}`) applies only to the Gemini engine.

### 5.2 GenerationManager (`GenerationManager.swift`, @MainActor)

Pipeline per note: **transcribe (if no cached transcript) → generate**.

- **Provider routing**: `AppSettings.currentProvider` (UserDefaults `llmProvider`; anything outside `supportedProviders` — e.g. the "coming soon" OpenAI tab — resolves to Gemini). Generation switches on the provider to `AnthropicClient` / `DeepSeekClient` / `GeminiClient`; the key and model come from `AppSettings.storedAPIKey(for:)` and `resolvedModel(for:)`, so adding a provider touches one switch rather than a ternary in every call site. Transcription uses `resolvedTranscriptionEngine`: `GeminiClient` for `.gemini` (requires a Gemini key — errors only when a transcription is actually needed), `AppleTranscriber` for the on-device engines (no key). Missing provider key errors up front.
- **Transcription is pinned to `AppSettings.transcriptionModel` (`gemini-3.5-flash`)**, not the user's selected Gemini model. Audio is the token-heavy input and the flash tier handles it well, so a pro-tier selection for note generation shouldn't silently bill pro rates for speech-to-text; it's also the tier verified to work with audio (see the §5.1 model-landscape callout). The Gemini settings tab says so under its model picker.
- Prompts come from UserDefaults with fallbacks to `AppSettings.defaultTranscriptPrompt` / `defaultNotesPrompt` (empty/whitespace stored value ⇒ default, via `AppSettings.string(forKey:default:)`).
- Placeholder substitution: `{{title}}`, `{{date}}`, `{{user_name}}` (from Profile settings; fallback text asks the model to infer), `{{verbosity}}` (5-level instruction from the Notes Style slider, default level 2 "Balanced"), `{{manual_notes}}`, `{{transcript}}`.
- The transcript prompt tells the model the recorder's name = mic voice (fixes wrong-name guessing). "Re-transcribe & Regenerate" (⋯ menu) clears the cached transcript first.
- Post-processing of generated markdown, in order: `stripCodeFence` → `stripLeadingTitleAndDate` (drops a leading `# Title` + date-ish line — the app header already shows both) → `normalizeBullets` (rewrites `*`/`+` list markers to `-`; see §6 callout).
- **Cancellation**: the view creates the Task and `register()`s it with the manager; the floating-bar button becomes "Stop Transcribing"/"Stop Generating" → `cancel()`. URLSession honors task cancellation; `CancellationError`/`URLError.cancelled` are swallowed (no error dialog). A completed transcription survives a cancelled generation (it's stored as soon as it finishes).
- Publishes `phase` (idle/transcribing/generating), `activeNoteId` (drives floating-bar spinner AND the sidebar row mini-spinner), `errorMessage` + `errorDetail`.

### 5.3 Prompt defaults (`AppSettings.swift`)

The notes prompt implements the "bi-directional" architecture: manual notes are the anchor; rule 1 = include them **with only spelling/grammar corrected**; rule 3 = fixed sections (Summary ≤3 sentences, Key Points, Decisions, Action Items as checkboxes) + omit empty sections + model may add sections for topics that don't fit; rule 4 = `{{verbosity}}`; rule 6 = never repeat title/date, start at `## Summary`; rule 7 = formatting contract (dash bullets, sparse bold, no italics, no bare `*`).

---

## 6. Markdown editor & diff rendering

### 6.1 MarkdownTextEditor (NSViewRepresentable)

Parameters: `text: Binding<String>`, `diffAgainst: String?` (manual-notes base for diff coloring), `isEditable`, `highlight: TextHighlight?` (one-shot scroll+flash), `bottomContentInset: CGFloat` (74 in the editor so content scrolls clear of the floating bar).

**`PaddedTextView` (custom NSTextView)** exists for two hard-won reasons:

> **CALLOUT — do not use NSScrollView.contentInsets**: setting `contentInsets` (even async after window insertion, even with re-tiling) leaves a clipped "solid strip" on first render until the user scrolls. The working solution: symmetric `textContainerInset` of `(top+bottom)/2` plus an override of `textContainerOrigin` pinning the container at `topPadding` (12) — the remainder becomes bottom padding inside the document geometry. Deterministic, correct on frame 1.

> **CALLOUT — manual scroll-view assembly loses two behaviors** that `NSTextView.scrollableTextView()` gave for free; both are restored in `syncWithClipView()` (driven by clip-view `frameDidChangeNotification`): (1) **width tracking** — text view width is pinned to the clip view so text re-wraps on window resize; (2) **min-height fill** — the view is kept at least viewport-height so clicks below short content still focus the editor.

- Undo: a per-Coordinator `UndoManager` supplied via `undoManager(for:)`, plus `performKeyEquivalent` handling ⌘Z/⇧⌘Z directly (menu routing was unreliable in this hosting setup).
- Keyboard behavior in `Coordinator.textView(_:doCommandBy:)`:
  - Return: continues `-`/`*`/`+`/`1.` lists (numbered increments); Return on an empty item deletes the marker (ends the list).
  - Tab / ⇧Tab: indents/outdents by 4 spaces at line start (multi-line selection supported; plain cursor on a non-list line just inserts spaces). Bullet markers move with the line; hanging indents follow automatically.
- `updateNSView` only resets `string` when the binding truly differs (keystroke echoes are no-ops; cursor preserved). It also re-styles when `Theme.styleFingerprint` changes (theme/dosa-color/accent), tracked per-Coordinator.

### 6.2 MarkdownStyler

Full-document restyle on every change (cheap at note scale). Per line: headings `#{1..6}` (fonts 23/19/16/14.5 bold, markers dimmed), bullets/numbered (marker tinted `Theme.current.highlight`, hanging indent via `headIndent` ≈ prefixWidth × fontSize × 0.52), quotes, ``` fences (toggle mono/secondary). Inline within the line: `` `code` `` (mono + `Theme.codeSpan`), `**bold**`, `*italic*`/`_italic_` — markers dimmed to tertiary.

> **CALLOUT — inline styling must skip the list-marker prefix** (`inlineStart`): a `*` bullet otherwise pairs with a stray mid-line `*` and fake-italicizes half the sentence. This bug shipped once; the prompt rule 7 + `normalizeBullets` are the belt-and-suspenders for model output, the `inlineStart` fix is the real cure.

- Diff coloring (`applyDiffColors`): tokenize the document (words + `\n` tokens, whitespace-insensitive — `tokenizeWithRanges` mirrors `DiffEngine.tokenize` exactly), Myers-diff (`CollectionDifference`) against `diffAgainst`; inserted-token ranges get `DiffEngine.aiNSColor`. Typing attributes also use the Dosa color in diff mode (new typing = addition by definition).
- `highlight` handling: `flashWhenVisible` polls until the view's window is actually visible/on-screen (sheets animate in!), forces layout, scrolls, then `showFindIndicator` 0.15 s later. Without the wait, the yellow flash is swallowed by sheet presentation.

### 6.3 View modes (NoteEditorView)

- `My Notes` = `manualText`, editable **until** notes are generated, then read-only with a lock banner (it's the diff base).
- `Dosa Notes` = `enhancedMarkdown`, fully editable with live diff coloring; becomes the default tab (`onAppear` + after generation).
- Legend row ("Your notes" / "Dosa additions") above the Dosa editor uses `DiffEngine.aiColor`.
- `DiffEngine.attributedDiff` (SwiftUI AttributedString version with heading sizing) still exists but is no longer used by the editor — kept for potential read-only rendering.

---

## 7. Search

- `SearchService.matches(in:query:fields:maxPerField:)` — case-insensitive `NSString.range(of:)` loops per field (`title/manual/enhanced/transcript`), NSRange (UTF-16) offsets, snippets ±36 chars snapped to composed-character boundaries. `attributedSnippet` bolds/oranges (actually `Theme.highlight`) the query.
- **Global search** (⌘K, sidebar icon): sheet over all active notes, filter chips (Title/Transcript/My Notes/Dosa Notes, all on by default, "select at least one" empty state), max 200 results.
- **In-note search** (⌘F, floating-bar icon; only when transcript or Dosa notes exist because the popover anchors to that button): same, minus Title.
- **Reveal machinery**: clicking a result sets `SearchCoordinator.pendingReveal {noteId, field, location, length}` (+ selects the note). `NoteEditorView` consumes it in `onAppear`/`onChange`: switches view mode for manual/enhanced, or opens the transcript sheet, and passes a `TextHighlight {id, range}` to the right `MarkdownTextEditor` → scroll + native yellow find indicator. ⌘F requests ride `AppState.noteSearchRequest: UUID?` (fresh UUID per press so `onChange` always fires; consumed and nilled by the editor).

---

## 8. Theming

- `Theme.swift`: `ThemePalette` tokens — `accent`, `highlight`, `highlightDeep` (welcome-glyph gradient bottom), `editorBackground`, `cardFill`, `codeSpan`, `defaultDosaColorName` — every token a dynamic `NSColor(name:nil){appearance…}` with light/dark variants. Five presets: **Classic** (blue/orange/system), **Crepe** (espresso/caramel/cream — deliberately hue-separated from Masala), **Masala** (red-orange/saffron), **Chutney** (greens/mint), **Slate** (graphite/steel).
- Overrides on top of any preset: **Accent Override** (Blue/Purple/Pink/Green/Graphite — red excluded deliberately; it means destructive/record) and **Dosa Notes Color** (Grey/Purple/Red/Dark Blue/Dark Green + "Theme Default" which follows the preset; stored value "Theme Default" or unset ⇒ preset default via `AppSettings.currentDosaColorName`).
- Application: root `.tint(Theme.current.accentColor)` in ContentView (covers selection, sliders, pickers, chips, links); explicit `Theme.current.*` reads for play button, backgrounds, stat cards, key-cap chips, markdown bullet/code colors, search-match highlight, welcome gradient.
- **Not themeable by design**: body text (system label colors), destructive red, translucent materials (floating bar/toasts), sidebar material.
- **Refresh model**: views re-render via `@AppStorage` observation of the theme keys, editors re-style via `Theme.styleFingerprint` comparison, and — the sledgehammer that guarantees "everything at once" — closing Settings bumps `AppState.themeRefreshTick`, and ContentView has `.id(appState.themeRefreshTick)` on the NavigationSplitView, rebuilding the whole tree. Side effect: sidebar disclosure state resets after Settings closes. `AppSettings.applyAppearance()` maps the Appearance picker (auto/light/dark) to `NSApp.appearance`, applied on change and at launch.

---

## 9. Sidebar

- **Selection**: `List(selection: $appState.selectedNoteIds)` with `Set<UUID>` — native ⌘-click / ⇧-click multi-select. `AppState.singleSelectedNoteId` (count == 1) drives the detail pane; ContentView bridges to single-note views via `singleSelectionBinding` (`Binding<UUID?>` that writes `[$0]` or `[]`). Multi-select shows `MultiSelectionView`.
- **Sections**: Pinned (only when non-empty) → Notes (recursive `FolderRow` DisclosureGroups + root notes) → Deleted Notes (DisclosureGroup with restore/permanent-delete, "Empty Deleted Notes…" with confirmation, 30-day footer).
- **Context menus** are multi-aware: `targetIds = selection.contains(row) ? selection : {row}`; labels pluralize ("Pin 3 Notes"). Items: Pin/Unpin (`pin`/`pin.slash` icons), Move to Folder (folder icon, submenu with depth-indented folder list + "No Folder"), Delete (trash icon) → **all deletes go through a confirmation dialog** (`pendingDeleteIds` in SidebarView).
- **Drag & drop**: rows expose `.itemProvider` with a comma-joined UUID payload (whole selection if the dragged row is selected). Drop targets: folder labels (`onDrop(of: [.plainText])`, accent highlight while targeted) and the **"Notes" section header** (`RootDropHeader`) for dragging notes *out* of folders (shows "— drop to move out of folder" hint while targeted).

> **CALLOUT — use `.itemProvider`, never `.onDrag`, on List rows (macOS)**: `.onDrag` captures mouse-down for drag detection and makes row selection flaky/inconsistent. `.itemProvider` registers with the underlying table view and coexists with clicks. This bug shipped once.

- **Swipe actions** (native macOS two-finger swipes): leading = Pin/Unpin (orange tint, full swipe commits); trailing = Delete (destructive, routes through the same confirmation dialog).
- **Empty-area click deselects** via `SidebarDeselectCatcher`: a zero-size background NSView installing a local `NSEvent` mouse-down monitor; a click that hits an `NSTableView` but no `NSTableRowView` clears the selection. (SwiftUI sidebar Lists don't do this natively. Assumption: the sidebar List is the only table view in the main window.)
- Row layout: 14 pt title; second row = 12 pt date + waveform icon (has recording) + sparkles icon (has Dosa notes) + `.mini` ProgressView while that note is transcribing/generating.
- Footer: Settings button (gear + label) with "Dosa — Version x.y" (from `CFBundleShortVersionString`) beneath.

---

## 10. Notion integration (hosted MCP — not the REST API)

**Decision**: Dosa talks to Notion's **hosted MCP server** (`https://mcp.notion.com/mcp`) as a deterministic client. Why not REST: MCP's OAuth mandates **Dynamic Client Registration**, so there is *no manual integration registration and no embedded client secret* — and the MCP tools accept/return Notion-flavored **markdown**, eliminating a markdown↔blocks converter. Trade-off: tool response formats are LLM-oriented text/JSON and may drift — all parsing is deliberately tolerant (see callouts).

### 10.1 NotionAuth — OAuth 2.1 + DCR + PKCE

Flow (`authorize()`):
1. Discovery: `/.well-known/oauth-protected-resource[/mcp]` → authorization server → its `/.well-known/oauth-authorization-server` (fallback `openid-configuration`) → `authorization/token/registration` endpoints.
2. DCR (RFC 7591): register `client_name: Dosa`, redirect URIs `http://127.0.0.1:{53682..53685}/callback`, `token_endpoint_auth_method: none`; `client_id` cached in UserDefaults.
3. `LoopbackHTTPServer` (NWListener, first free port of the four): parses the `GET /callback?code&state` request line, validates `state`, serves a tiny "you're connected" HTML page, resumes a continuation. Cancellable (Settings "Cancel" → `cancelAuthorization()`).
4. Browser bounce with PKCE S256 + `state` + `resource=<mcp endpoint>` (RFC 8707).
5. Token exchange (form-encoded, no secret); refresh via `refresh_token` grant, rotating tokens stored.

Storage: **UserDefaults** (`notionAccessToken/RefreshToken/TokenExpiry/ClientId/TokenEndpoint/Workspace…`) — consistent with the LLM provider API keys. *Keychain is the known hardening upgrade.* `validAccessToken()` auto-refreshes within 60 s of expiry.

### 10.2 NotionMCPClient — minimal MCP

- Streamable HTTP: POST JSON-RPC to `/mcp`; headers `Authorization: Bearer`, `Accept: application/json, text/event-stream`, `MCP-Protocol-Version` (after negotiation), `Mcp-Session-Id` (captured from the `initialize` response header).
- Session: `initialize` (protocolVersion "2025-06-18") → `notifications/initialized` → `tools/call`. HTTP 404/400 on a call ⇒ session expired ⇒ transparent re-init + one retry. 401/403 ⇒ `unauthorized` ⇒ manager refreshes token and retries once.
- Responses may be plain JSON **or SSE**; `parseSSE` accumulates `data:` lines per event and returns the message whose `id` matches the request (other stream events are skipped).
- `callTool(name:arguments:accessToken:) -> String` joins `result.content[].text`; `isError: true` ⇒ `ClientError.tool(text)`.

### 10.3 NotionManager — the product logic

- **Connection**: `connect()` runs auth, `notion-fetch {id: "self"}` for the workspace label, then auto-creates the database (first time). `disconnect()` wipes tokens + destination.
- **Dosa Notes database** (the simplified UX — no destination picker): `ensureDatabase()` calls `notion-create-database {title: "Dosa Notes", schema: CREATE TABLE ("Title" TITLE, "Date" DATE)}` (no parent ⇒ private workspace-level page); parses the `collection://<data_source_id>` from the returned `<data-source>` tag and the database URL; stores destination `{type: "data_source", id}` + `notionTitlePropertyKey = "Title"`. Settings shows the DB with an "Open" button, or "Create Now" if absent.
- **Export** (`export(note:store:)`): content = `*<long date>*\n\n` + (`enhancedMarkdown ?? manualText`); title goes in **properties**, never content.
  - No `notionPageId` yet → `notion-create-pages {parent: {data_source_id}, pages: [{properties, content}]}`; created page URL/ID parsed from the result; stored on the note (⋯ menu gains "Open in Notion", label flips to "Update in Notion").
  - Has `notionPageId` → `notion-update-page {command: replace_content, new_str, allow_deleting_content: true}` + best-effort `update_properties` title.
  - Self-healing: "missing page"-looking tool errors (`looksLikeMissingPage`) ⇒ page was deleted in Notion ⇒ clear ids and create fresh; same for a deleted database ⇒ recreate and retry once.
  - Property attempts ladder (schema drift tolerance): `[Title + date:Date:start/is_datetime]` → `[Title]` → `["title"]` → `["Name"]` (date property format per update-page docs: `date:{prop}:start` = `yyyy-MM-dd`).

> **CALLOUT — MCP response formats observed empirically** (verified by calling the same hosted server):
> - `notion-search` returns **JSON** `{"results":[{id,title,url,type,highlight,timestamp}]}` with `app.notion.com/p/<32hex>?pvs=204` URLs (not `www.notion.so`!). Parsers accept both domains; regex fallbacks retained for drift.
> - `notion-create-database` / `notion-fetch` of databases return markdown with `<data-source url="collection://…">` tags.
> - `notion-fetch` should be given the raw UUID, not an `app.notion.com` URL.
> When something breaks here, the fastest diagnosis is calling the hosted MCP with the same tool/args and reading the raw response.

- Notion state is **excluded from settings export** (tokens are secrets; IDs are workspace-specific).

### 10.4 Phase 2 (designed, not built): bi-directional sync

Per-note sync toggle (data-source destinations only); push = debounced `replace_content` + stored content hash; pull = `notion-fetch` page (returns markdown) on note-open/5-min timer/manual; hash-based echo-loop guard; last-writer-wins on divergence. Markdown round-trips are faithful for Dosa's subset.

---

## 11. Settings (`SettingsView.swift`)

Section order: **Profile** (Your Name → `{{user_name}}` + welcome greeting) → **Notion** (§10) → **Transcription** (engine dropdown Gemini (Cloud)/On-Device (Advanced)/On-Device (Basic) → `transcriptionEngine`; inline orange warnings when Gemini engine is picked without a Gemini key, or Advanced on a pre-26 macOS — the latter still saves but degrades to Basic at runtime) → **LLM Provider** (a **Default Provider** picker row at the top writes `llmProvider` and lists only providers with a saved key — `AppSettings.configuredProviders`; hidden behind a hint caption when no key is saved; self-heals on appear if the stored default lost its key. Below it, a segmented Gemini/Anthropic/OpenAI/DeepSeek control is UI-only `@State` for *editing* config — it opens on the default provider and never changes it. Gemini, Anthropic, and DeepSeek tabs = API key + link + model picker; Anthropic and DeepSeek add a shared `textOnlyProviderNote` caption pointing at the Transcription section; the OpenAI tab is a "coming soon" stub that resolves to Gemini at generation time) → **Notes Style: \<level\>** (5-stop verbosity slider — level name lives in the section header; Dosa Notes Color swatches) → **Note Generation Prompt** / **Transcription Prompt** (DisclosureGroups, collapsed by default, whole label row toggles, "Reset to Default" buttons, placeholder hints) → **Theme** (preset cards with 3-dot palette previews, Accent Override swatches, Dosa color, Appearance picker) → **Backup**.

- **Backup**: Export/Import Settings as JSON (`SettingsSnapshot`: userName, appearance, geminiModel, llmProvider, deepseekModel, anthropicModel, transcriptionEngine, notesVerbosity, theme, accentOverride, dosaNotesColor, notesPrompt, transcriptPrompt). **API keys & Notion state intentionally excluded**; import validates enum-ish fields and remaps retired models.
- Closing Settings bumps `themeRefreshTick` (§8).

> **CALLOUT — Form footer text on macOS 26 right-aligns wrapped lines** unless you add `.multilineTextAlignment(.leading)` (plus `.fixedSize(horizontal: false, vertical: true)` and a leading-aligned max-width frame). All footers here do this; keep the pattern for new ones. Similarly, a bare `Slider` in a grouped Form gets shoved into the trailing "value column" — give it a hidden empty label + `.frame(maxWidth: .infinity)`.

---

## 12. Keyboard shortcuts & commands (`DosaApp.swift`)

Menu-bar commands (also shown as key-cap hints at the bottom of the welcome page, `⌘ N` style with a space):

- **⌘N** New Note (replaces New Window) · **⌘W** Close Note = clear selection, no-op on welcome (replaces Close) · **⌘K** global search · **⌘F** in-note search (rides `noteSearchRequest: UUID?`; only acts when the open note has transcript/Dosa notes).
- Editor-local: ⌘Z/⇧⌘Z undo/redo, Tab/⇧Tab indent/outdent, Return list continuation (§6.1).

---

## 13. Error handling

- `DetailedError { errorDetail: String? }` — conformed by `GeminiError`, `AnthropicError`, `DeepSeekError`, and `NotionMCPClient.ClientError`; friendly `errorDescription` + raw payload separated.
- `ErrorDialogView` (sheet, not alert — alerts can't hold disclosure groups): warning icon, summary line, collapsed **"Show technical details"** (150 pt scrollable, selectable, monospaced raw body), OK. Presented from NoteEditorView via `errorPresented` binding that clears `localError(+Detail)` and `generator.errorMessage(+Detail)` on dismiss; Notion export errors are copied into the local pair. Notion *connection* errors render red in the Settings footer instead.
- Generation cancellations are silent by design.

---

## 14. Known quirks & operational notes (consolidated)

1. **TCC re-prompts after rebuild** (ad-hoc signing) — §2.
2. **`store.json` decode fragility** — new model fields must be Optional — §3.1.
3. **Gemini `gemini-3.6-flash` 500s on audio**; retired-model remaps; fallback chain — §5.1.
4. **NSScrollView contentInsets tiling bug** → `PaddedTextView.textContainerOrigin` approach — §6.1.
5. **Manual scroll-view assembly** needs explicit width-tracking + min-height (`syncWithClipView`) — §6.1.
6. **`.onDrag` breaks List selection on macOS** → `.itemProvider` — §9.
7. **`showFindIndicator` during sheet animation is lost** → `flashWhenVisible` polling — §6.2.
8. **Bullet `*` + stray `*` fake-italic** → inline styling skips list prefix; bullets normalized to `-` — §6.2.
9. **Notion MCP formats are informal** — tolerant parsers, both URL domains, raw-UUID fetches — §10.3.
10. **Settings-close = full view-tree rebuild** (`.id(themeRefreshTick)`) — resets sidebar disclosure state; acceptable trade for atomic theme application.
11. **Tokens/API keys in UserDefaults** — fine for a personal app; Keychain is the upgrade path.
12. **`AVAssetExportSession.export()` deprecation** (macOS 15) — migrate to `export(to:as:)` eventually.
13. **`fetchWorkspaceName` regex is best-effort**; falls back to "Notion".
14. Screenshot filenames on this user's Desktop contain **narrow no-break spaces** — use globs when copying (`cp Screenshot*<time>*.png`), not typed paths.
15. Swift concurrency: Swift 5 language mode; Sendable warnings exist and are accepted. `NotesStore` non-isolated on purpose; managers `@MainActor`.

## 15. Verification checklist (manual)

1. `./build.sh && open build/Dosa.app` — app launches, welcome shows stats + shortcut hints.
2. Record (mic + play a video) → waveform bounces → stop → play with scrub bar.
3. Generate Notes → sidebar row spinner → Dosa Notes tab with diff colors → Re-generate label; Stop mid-run cancels silently.
4. ⌘K / ⌘F search → results jump + yellow flash (including into the transcript sheet).
5. Themes: switch presets + Appearance in Settings, close → everything recolors at once, editors included.
6. Sidebar: multi-select, drag into/out of folders, pin (section appears/disappears), swipe left/right, delete confirmations.
7. Notion: Connect (browser) → Dosa Notes DB auto-created → Export → entry appears with Title/Date → edit + Update in Notion (no duplicate) → delete page/DB in Notion → export self-heals.
8. Settings export/import round-trip on a second machine (API key & Notion excluded by design).
