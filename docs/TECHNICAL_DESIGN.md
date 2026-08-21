# Dosa — Technical Design Document

**App**: Dosa, a native macOS meeting-notes app
**Source**: `~/Desktop/DosaApp`
**Version**: 1.4 · macOS 14+ · Swift 5.9 language mode (built with Swift 6.1 toolchain)
**Audience**: This doc is the canonical reference for continuing development (human or Claude). It captures architecture, implementation details, design decisions, and gotchas discovered during development.

---

## 1. What Dosa does

Dosa records meeting audio **directly from the Mac** (no bot joins the call), lets the user take sparse manual notes in a live markdown editor, then uses the **configured LLM provider** (Gemini, Anthropic, or DeepSeek) to (1) transcribe the recording with speaker identification and (2) synthesize polished meeting notes anchored on the user's manual notes. (Only Gemini accepts audio; with Anthropic or DeepSeek selected, transcription falls to the engine chosen in Settings → Transcription.) Generated notes render with a deterministic word-level diff: the user's words in the primary text color, Dosa's additions in a configurable grey/color. Notes can be organized in nested folders, pinned, searched globally, exported to disk, exported to a **Notion database** that Dosa creates automatically via Notion's hosted MCP server, and — when Google Calendar is connected — created from upcoming meetings on a calendar homepage.

Because audio is intercepted at the OS level (ScreenCaptureKit loopback + mic), it works with any source: Zoom, Meet, Teams, Slack huddles, browser tabs, video files. Audio already captured elsewhere can be **imported** instead (§4.2) — after the import step nothing downstream distinguishes it from a recording.

---

## 2. Build system & project layout

**Swift Package (SPM), not Xcode project.** The runnable product is the `Dosa` executable (`Sources/DosaApp`); app code lives in the `DosaKit` library (`Sources/Dosa`) so the Calendar checks executable can import it. Built with `swift build`, assembled into a `.app` bundle by `build.sh`:

1. `swift build -c release`
2. Snapshots git commit + dirty state, then refuses `DOSA_RELEASE_BUILD=1` if the *source* tree is dirty. Brand regeneration used to write into tracked `Resources/`, which made every CI release look dirty and abort.
3. Regenerates the brand assets via `Scripts/make_icon.swift` into `build/branding/` (gitignored), unconditionally, every build (no longer guarded behind "if missing" — a stale icon/mark from before a source-SVG change is worse than the ~1s regeneration cost):
   - `AppIcon.icns`: rasterizes `Resources/Branding/dosa-icon-1024.svg` (brown tile, amber mark) via `NSImage(contentsOfFile:)` — verified pixel-accurate for this file's plain SVG feature set — then packages the usual resolution set with `sips` + `iconutil`.
   - `dosa-mark-{light,dark}.png`: rasterizes `Resources/Branding/dosa-mark-currentcolor.svg` (a template shape — solid black, transparent elsewhere) once, then tints it twice via `NSColor.set()` + `NSRect.fill(using: .sourceIn)` (the same alpha-preserving technique AppKit uses internally for `.isTemplate` images) — brown `#7A4512` for light appearance, amber `#E0A44E` for dark. Same brand pairing `dosa-mark-adaptive.svg` encodes via CSS, reproduced natively because that file's `@media (prefers-color-scheme:)` rules render inconsistently through `NSImage`/ImageIO (confirmed: mixed light/dark rule results within one raster) — not safe for native rendering.
4. Assembles `build/Dosa.app/Contents/{MacOS/Dosa, Info.plist, Resources/{AppIcon.icns, dosa-mark-light.png, dosa-mark-dark.png}}` from the generated branding dir plus tracked `Resources/Info.plist`.
5. **Stamps** the *copy* of Info.plist already inside the bundle (never the tracked `Resources/Info.plist`) with `DosaBuildCommit` (full SHA, or empty when git is unavailable), `DosaBuildDate`, `DosaBuildChannel` (`release` when `DOSA_RELEASE_BUILD=1`, else `dev`), and `DosaBuildDirty`. **This must precede `codesign`** — PlistBuddy after signing breaks the seal, and the in-app updater verifies the signature of what it downloads. `DOSA_BUILD_COMMIT` overrides the stamped SHA so an older commit can be claimed for end-to-end updater tests without waiting on CI.
6. **Ad-hoc codesigns** (`codesign --force --sign -`)
7. **Optionally installs** — only with `./build.sh --install`, which quits a running Dosa (replacing a live bundle leaves it half-broken), removes `/Applications/Dosa.app` rather than copying over it (so files dropped in a later version can't linger), and copies the fresh build in. Deliberately opt-in: the dev loop reruns this script constantly, and rewriting the installed bundle every time makes it ambiguous which copy is running and re-triggers the TCC prompts tied to that bundle.

`build/` is generated and gitignored. Released builds are published to GitHub Releases by `.github/workflows/release.yml` (§2d); there is nothing to gain from committing a binary that changes on every feature commit. `DOSA_RELEASE_BUILD=1 ./build.sh` refuses to run if git cannot name a commit or the tree is dirty.

**Dev loop**: `swift build` to typecheck; `./build.sh && open build/Dosa.app` to ship. Kill the running app first (`pkill -x Dosa`).

> **CALLOUT — TCC and ad-hoc signing**: every rebuild re-signs with a new ad-hoc identity, so macOS may re-prompt for Microphone, Screen & System Audio Recording, and notification authorization after rebuilds. This is expected. A real Developer ID cert would fix it.

```
Sources/DosaApp/
  DosaEntry.swift        @main trampoline that calls DosaApp.main()
Sources/Dosa/            DosaKit library (app + tests)
  DosaApp.swift          App; AppState; Window + MenuBarExtra scenes; commands
  AppSettings.swift      All UserDefaults keys, default prompts, verbosity, appearance
  Theme.swift            Preset palettes + accent override + styleFingerprint
  Models.swift           Note, Folder, TimeFormatting
  NotesStore.swift       Persistence, folders, pins, trash, stats, calendar-note links
  LoopbackHTTPServer.swift  Shared localhost OAuth callback listener
  NoteTemplates.swift    NoteTemplate model, TemplateStore, four built-in templates
  AudioRecorder.swift    Mic + system-audio capture, m4a mixdown, level/menu-icon metering
  RecordingImporter.swift  File picker, format gate, and import error mapping
  AudioPlayer.swift      Playback with pause/seek/progress
  GeminiClient.swift     Gemini REST client + DetailedError protocol
  AnthropicClient.swift  Anthropic Messages API REST client (text-only)
  DeepSeekClient.swift   DeepSeek chat/completions REST client (text-only)
  GenerationManager.swift  Transcribe→generate pipeline, cancellation, post-processing
  NotificationManager.swift  Recording-saved / notes-ready routing: toast if frontmost, macOS banner if not
  QuitGuard.swift        Busy-work detection + window-independent quit confirmation
  UpdateManager.swift    GitHub Releases check, download, verify, detached install helper
  RecordingCommand.swift Start/stop recording from ⌘R, File menu, and the menu bar
  DiffEngine.swift       Tokenizer + attributed diff + Dosa-color registry
  SearchService.swift    Match finding, snippets, SearchCoordinator (reveal bus)
  Notion/
    NotionAuth.swift     OAuth 2.1: discovery, DCR, PKCE, loopback HTTP server
    NotionMCPClient.swift  Minimal MCP client (JSON-RPC + SSE over Streamable HTTP)
    NotionManager.swift  Connection state, Dosa Notes DB, export, tolerant parsing
  GoogleCalendar/
    GoogleCalendarAuth.swift     Desktop OAuth + PKCE + Keychain tokens
    GoogleCalendarClient.swift   Calendar REST list/events pagination
    GoogleCalendarManager.swift  Connection, selection, hourly refresh, cache
    CalendarEvent.swift          Meeting filter, dedupe, 30-day window, link safety
    GoogleCalendarAPIModels.swift  Codable Google JSON + mapping
    CalendarCache.swift          Application Support snapshot
    GoogleCalendarKeychain.swift Generic-password token store
  Views/
    ContentView.swift    NavigationSplitView; selection bridging; theme tick
    SidebarView.swift    Multi-select list, pins, drag&drop, swipes, settings footer
    SidebarDeselectCatcher.swift  Empty-click deselection via NSEvent monitor
    NoteEditorView.swift Editor, floating bar, ⋯ menu, error sheet, exports
    MarkdownTextEditor.swift  PaddedTextView + Coordinator + MarkdownStyler
    TranscriptView.swift Transcript sheet (read-only MarkdownTextEditor)
    SearchViews.swift    Global search sheet, in-note popover, filter chips
    SettingsView.swift   All settings sections + export/import
    MenuBarMenu.swift    Windowless new/import/record/settings/quit actions
    QuickSettingsPanel.swift  Model + Notes Style panel inside the recording bar's pull-tab
    WelcomeView.swift    Greeting, stats, shortcut hints; HomeView router
    CalendarHomeView.swift  Connected 30-day meeting list
    CalendarEventDetailView.swift  Event popup: details, links, create/record
    DeletedNoteView.swift  Trash preview with restore/delete
    SharedViews.swift    FloatingChrome, banners, BackToWelcomeToolbar, TrailingToolbarItem, BarPedestalShape, NotesStyleSlider, RecordingWaveformView, ErrorDialogView, MultiSelectionView
  Branding.swift         DosaMark PNGs + drawn menu-bar frames + DosaWatermark
Sources/DosaCalendarChecks/  Calendar checks runnable without XCTest
Resources/Info.plist    Bundle metadata + NSMicrophoneUsageDescription + NSAudioCaptureUsageDescription
Resources/GoogleCalendarOAuth.json.example  Desktop OAuth client template (live file is gitignored)
Resources/Branding/     Source SVGs (app icon, in-app mark, menu-bar templates — see §2b)
build.sh / Scripts/make_icon.swift
.github/workflows/release.yml  publish a GitHub Release for every commit to main
```

### 2b. Branding assets (`Resources/Branding/`, `Scripts/make_icon.swift`, `Branding.swift`)

All 7 source SVGs delivered with the current logo are committed under `Resources/Branding/` as the source of truth. Two are rasterized into shipped assets, while two provide the geometry for the code-drawn menu bar icon:

- `dosa-icon-1024.svg` → the app icon (`AppIcon.icns`, generated into `build/branding/` then copied into the `.app`).
- `dosa-mark-currentcolor.svg` → the in-app brand mark (`DosaMark`), shown in the sidebar footer next to the version/model line. `WelcomeView` uses a matching vector backdrop (`DosaWatermark` in `Branding.swift`): the same rings (r = 70 / 52 / 34, dash gaps, rotations, filled core) drawn in a `Canvas` so they stay sharp at any window size, tinted from the active theme's `highlight` (not the brown/amber of `DosaMark`), and top-anchored so they sweep down over the upper half of the pane. The watermark replaced the old 112-pt hero `DosaMark` at the top of the welcome stack; the greeting now leads that stack in its place.
- `dosa-menubarTemplate.svg` / `dosa-menubarRecordingTemplate.svg` → source-of-record geometry for `MenuBarIcon`. It draws resolution-independent 18 pt AppKit template images in code because the recording state needs each ring controlled independently: 24 frames counter-rotate the two single-gap rings while the filled core stays fixed. `AudioRecorder.ringPhase` advances the frame every 0.09 seconds; Reduce Motion selects a static recording frame.

The app icon and in-app mark use `NSImage(contentsOfFile:)` to rasterize the *actual* SVG at build time rather than hand-reproducing the geometry in AppKit/SwiftUI — verified pixel-accurate against these files (plain `<rect>`/`<g transform>`/`<circle>` + `stroke-dasharray`, no CSS). The menu bar is the deliberate exception: independent ring animation is impossible from a flat raster, so its literal Core Graphics constants are kept traceable to the SVGs. `DosaMark` itself does zero SVG/asset loading at runtime beyond reading two plain PNGs baked at build time (`dosa-mark-light.png` / `dosa-mark-dark.png`) via `Bundle.main` — deliberately *not* SwiftPM's `resources:`/`Bundle.module` mechanism, since this project hand-assembles its `.app` in `build.sh` rather than letting SwiftPM produce one, and `Bundle.module`'s companion resource bundle would need its own separate copy step to land inside `build/Dosa.app/Contents/Resources/`. Reusing the exact `Resources/` → `cp` → `Bundle.main` path already proven for `Info.plist`/`AppIcon.icns` avoids that whole class of packaging bug.

The mark is brand-fixed brown/amber (`#7A4512` / `#E0A44E`) regardless of which of the 5 accent-theme presets is selected — it switches only on light/dark **appearance** (`@Environment(\.colorScheme)`, which follows `AppSettings`'s Auto/Light/Dark override same as the rest of the app), since every theme preset's `editorBackground` is a near-white/near-black neutral (see §8) — the brown/amber pair reads fine against all of them.

`dosa-mark-cream.svg` (a lighter alternate mark, e.g. for a dark solid-color hero) and `dosa-mark-adaptive.svg` (the CSS self-adapting version — kept as reference for the intended color pairing, not for rendering) remain unused.

### 2c. App scenes and menu bar

`DosaApp` has two scenes: a single-instance `Window("Dosa", id: "main")` and a persistent `MenuBarExtra`. Using `Window` rather than `WindowGroup` makes `openWindow(id:)` focus the existing main window or recreate it after the red close button, without ever spawning duplicates. Menu bar actions update `AppState` first and then open the window, so a newly mounted `ContentView` sees pending recording/import/settings state on its first render.

The menu bar's **Quit Dosa** and the replaced `.appTermination` command both call `QuitGuard`. It checks recording, transcription/generation, and file-import state. Busy quits use an AppKit `NSAlert` because the main window may be closed; this is the deliberate windowless exception to the sheet-based error presentation in §13.

The menu bar's recording item toggles: **Stop Recording** while a capture is running (same `RecordingCommand.stop` as ⌘R), **Start Recording in New Note** when idle (always a fresh note).

**Window chrome**: `.windowStyle(.hiddenTitleBar)` — no title bar; traffic lights overlay the sidebar's top-left, which is why the sidebar's icon row has `.padding(.top, 34)`. The sidebar toggle is `NavigationSplitView`'s own, left where macOS puts it; the only thing the app adds to that region is the back-to-home arrow (`BackToHomeToolbarItem`). Do not mutate the `NSWindow` to "finish" this look — see §9b.

### 2d. Releases & in-app updates

No version number is bumped per commit (`CFBundleShortVersionString` stays `1.4` across many SHAs), so freshness is the **git commit** the running app was built from versus the latest GitHub Release.

**CI** (`.github/workflows/release.yml`): on every push to `main` (and `workflow_dispatch`), a `macos-26` runner — pinned, not `macos-latest`, because the runner's SDK decides whether `#if canImport(FoundationModels)` in `SharedViews.swift` compiles Liquid Glass or the pre-26 fallback — asserts that `FoundationModels.framework` is in the SDK, builds with `DOSA_RELEASE_BUILD=1`, verifies the stamp equals `github.sha`, the channel is `release`, `codesign --verify --strict` still holds (so stamping did not run after signing), and `Resources/Info.plist` is untouched, then publishes:

- Tag: `build-<UTC yyyymmdd-HHMMSS>-<short sha>` (time-led, not `v1.4-…`, because the marketing version does not move per commit).
- Title: `Dosa 1.4 (<short sha>)`. Body: `--generate-notes`. `--latest` so `/releases/latest` is unambiguous.
- Assets: `Dosa.app.zip` (`ditto -c -k --keepParent`) and `manifest.json`.

**Why `manifest.json` rather than `target_commitish`.** GitHub documents `target_commitish` as the value that determines where the tag is created from, not as a record of what was built; once the tag exists the API may echo the branch name instead of the SHA. Resting the updater's identity check on that field is not a contract. A SHA in the tag name as the *sole* source can carry only one fact; adding a second later means changing the tag grammar and breaking old parsers. The manifest carries `schemaVersion`, the full commit, `sha256` (the only integrity check available for an unsigned download), `arch` (`lipo -archs`, comma-separated), `commitDate`, and `minimumSystemVersion`, and it is fetched from the CDN so it does not consume the 60/hr unauthenticated API budget. `--target` is still passed for the web UI; nothing in the app reads it. The short SHA in the tag is belt-and-braces: if `tag_name` ends in our own short SHA we are up to date and skip both the manifest fetch and `/compare`.

Released binaries are **arm64-only**. The updater refuses an incompatible slice rather than installing a bundle that cannot launch. Universal builds would be `swift build -c release --arch arm64 --arch x86_64` with a conditional copy from `.build/apple/Products/Release/Dosa`; out of scope.

**In-app updater** (`UpdateManager.swift`): a manual Settings button plus a throttled (4 h, once per launch) check on start. Passive surfacing only — no toast, banner, or alert on discovery; a sidebar badge and the Settings section. Steady-state "up to date" is one API request (`GET /repos/kvelury/dosa/releases/latest`); the User-Agent `Dosa/<version>` is required (GitHub rejects requests without one). `/compare/{ours}...{theirs}` runs only when an update exists. A 404 on `/releases/latest` is "no release yet" (informational, not an error). Compare `behind` / `diverged` / 404 are informational notes, not failures — a developer's unpushed commit 404s and must not look like an error.

Install sequence: preflight writability of the bundle's parent at *check* time (so the user is never asked to download 3 MB they cannot install) → stage into `url(for: .itemReplacementDirectory, appropriateFor: destination)` so the final move is an atomic `rename(2)` on the same volume → download with `URLSession.shared.bytes` → unpack with `/usr/bin/ditto -x -k` → verify (exactly one `.app`; zip SHA-256; `CFBundleIdentifier == com.dosa.meetingnotes`; executable bit; staged `DosaBuildCommit == manifest.commit`; `arch` runnable here; `codesign --verify --strict`; `minimumSystemVersion`) → one `QuitGuard.requestInstallUpdate` confirmation (busy work + ad-hoc/TCC warning + optional dev-checkout warning) → spawn a detached `/bin/sh` helper written to temp (never shipped inside the bundle being replaced — `sh` reads scripts incrementally) → dismiss Settings → terminate on the next runloop turn.

The helper waits on the parent pid (`ps`, not `kill -0`, against pid reuse), strips `com.apple.quarantine` unconditionally (`ditto` round-trips xattrs, and an ad-hoc un-notarized app that arrives quarantined is refused at launch), `mv`s the live bundle aside then `mv`s the staged app into place, and on either `mv` failure restores and `open`s something so the user is never left with no app. Failures write `~/Library/Application Support/Dosa/update-failed.txt`, which `consumePreviousFailure()` surfaces in the Settings footer on the next launch. stdout/stderr go to `update-helper.log`.

No privilege escalation. `/Applications` is `drwxrwxr-x root:admin`, so an admin account can write it; a standard account gets "Open Releases Page" instead of Install. Dev checkouts (`<repo>/build/Dosa.app`) are allowed with an explicit warning — `.git` is tested with `fileExists`, not `isDirectory`, because in a git worktree it is a file.

**Caveat:** the helper runs with Dosa as its responsible process, so if the destination lives under a TCC-protected folder (a checkout on `~/Desktop` or `~/Documents`) macOS may raise a folder-access prompt at the moment of the swap — after Dosa has quit, so the prompt appears with no app behind it. `/Applications` is not TCC-protected.

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
  calendarEventUID: String?  calendarEventInstanceStart: Date?
  calendarHTMLLink: String?  calendarID: String?      // one active note per calendar occurrence
  pinnedAt: Date?                                     // nil = unpinned; ordering key
  deletedAt: Date?                                    // nil = active; drives 30-day trash
  templateId: UUID?  templateName: String?            // templateName is stored redundantly so a rename/delete does not blank the editor legend
  templateSeed: String?                               // scaffold snapshot at apply-time; generation uses it to drop unfilled headings that rule 1 would otherwise keep
}
```

> **CALLOUT — Codable migration rule**: `NotesStore.load()` uses `try? decode` — if decoding throws, **all notes appear lost** (file isn't overwritten until next save, but the UI shows empty). Therefore every new `Note`/`Folder` field MUST be `Optional` (like `pinnedAt`, `notionPageId`) so old `store.json` files still decode. Never add a non-optional field without writing a custom `init(from:)`.

### 3.2 NotesStore

- Plain `ObservableObject` (deliberately **not** `@MainActor` — avoids Binding-closure isolation friction; all access happens on main in practice).
- Persistence: single JSON `~/Library/Application Support/Dosa/store.json` (`Snapshot { notes, folders }`, ISO-8601 dates, pretty-printed). Saves are **debounced 400 ms** (`scheduleSave()`); `persistNow()` also runs on `NSApplication.willTerminateNotification`.
- Recordings: `~/Library/Application Support/Dosa/Recordings/<noteId>-<yyyyMMdd-HHmmss-SSS>.m4a`, with `-mic`/`-system` side tracks and, while a capture is live, `-{mic,system}.caf` scratch beside them. `newRecordingFileName(for:)` mints a fresh name per recording and never reuses one (collision fallback: a UUID suffix) — that uniqueness is what makes overwriting structurally impossible rather than merely discouraged (§4.1). The note-id prefix is how `recoverInterruptedRecordings` maps an orphaned scratch file back to its note (§4.4).
- `noteBinding(id:) -> Binding<Note>?` — lookup-by-id in both get/set (index-free, safe against reordering). The editor binds `TextField`/editors through this; every keystroke goes through `update(_:)` → debounced save.
- Trash: `moveToTrash` sets `deletedAt`; `purgeExpiredDeletedNotes()` (called in `init`) permanently deletes anything older than `trashRetentionDays = 30`; `deletePermanently` also removes the recording files.
- `removeRecordingFiles(for:includingHistory:)` is the **only** path that deletes audio, and both callers are explicit user actions. `deletePermanently` passes `true`, sweeping every file with the note's id prefix so replaced-but-orphaned recordings don't leak. `discardRecording` passes `false` — discarding one recording must not quietly take the note's earlier ones with it, since those are the safety net that "Replace It" relies on.
- Pins: `togglePin(Set<UUID>)` — pins all if any target is unpinned, else unpins all. `notes(in:)` **excludes pinned notes** (they render only in the Pinned section); `pinnedNotes` sorts by `pinnedAt` desc.
- Stats for the welcome screen: `meetingsRecorded`, `totalRecordedTimeText`, `notesGeneratedCount`.

---

## 4. Audio pipeline (`AudioRecorder.swift`)

Audio reaches a note two ways — live capture (§4.1) and file import (§4.2) — converging on the same `mix` helper (§4.3) and the same `NotesStore.setRecording`. After that step nothing downstream can tell them apart.

### 4.1 Capture

Two simultaneous captures, both written to per-recording `.caf` scratch files during recording, mixed to one `.m4a` on stop:

| Stream | API | Notes |
|---|---|---|
| Microphone | `AVAudioEngine.inputNode` tap (4096 frames) | Float32 deinterleaved; written on `sampleQueue` |
| System audio | `SCStream` with `capturesAudio = true`, `excludesCurrentProcessAudio = true` | Video shrunk to 2×2 @ 0.5fps (SCStream requires a video config); audio callback converts `CMSampleBuffer` → `AVAudioPCMBuffer` via `withAudioBufferList` + `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` |

- **Permissions**: mic via `AVCaptureDevice.requestAccess(.audio)`; system audio needs Screen & System Audio Recording (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`; grant requires app relaunch — the thrown error explains this).
- **Threading**: all file writes on the serial `sampleQueue`; files are closed on that queue via a checked continuation before mixing (flush guarantee). Published props mutated on main.
- **Mixdown**: on stop, `mix` (§4.3) combines both scratch files, then runs once per source to keep `<base>-mic.m4a` / `<base>-system.m4a` beside the mixed file (see §5.1c) — roughly doubling recording storage, in exchange for on-device speaker attribution. Small start-time skew between mic/system (~100s of ms) is accepted.
- **Level metering** (drives the waveform): RMS is computed per buffer (every 8th sample) for both streams; `peakLevel` (sampleQueue-owned) keeps the max and decays ×0.5 each tick. A 0.09 s main-thread timer shifts `levelHistory: [Float]` (7 entries, scaled `min(1, rms*7)`), consumed by `RecordingWaveformView` (7 animated capsules).
- **Session claiming**: `start` claims the session synchronously (`beginSession`, `NSLock`) *before its first `await`*. `isRecording` doesn't flip until setup finishes, and setup can sit for seconds on a permission prompt — a second Record click landing in that window would otherwise run a whole second capture concurrently. `stop` and the interruption handler both go through `claimSession()`, so exactly one of them finishes the session.
- **Interruption salvage**: `SCStream`'s `didStopWithError` (display sleep, permission revocation, stream death mid-meeting) used to silently set `isRecording = false`, which flipped the UI back to a Record button with the capture still unmixed. It now finishes the session, mixes what was captured, and publishes `interruption: Interruption?`; `ContentView` observes it, calls `setRecording`, selects the note, and shows the message.

> **CALLOUT — captured audio is never destroyed to make room for new audio.** This is a hard invariant, added after a 53-minute meeting was lost by clicking Record twice. Three properties enforce it: (1) recording file names are unique and never reused, so no new recording can resolve to an existing path; (2) `mix` exports to a staging file and only replaces the destination after verifying the result (§4.3); (3) scratch files live in the app's own directory keyed per recording — not `$TMPDIR`, which macOS purges — and are deleted only after a verified mix. `start()` deletes nothing. The only deletions are `discardRecording` and `deletePermanently`, both explicit user actions (§3.2).

### 4.2 Import (`RecordingImporter.swift`, `NotesStore.importRecording`)

Attaches an audio or video file the user already has. Entry points: ⌘O, the sidebar `+` menu, the ⋯ menu, and drag & drop onto the note — all funnelling through `NoteEditorView.requestAudio(_:)` so there is one progress state, one error path, and one overwrite prompt.

- **Formats** are whatever AVFoundation decodes: `NSOpenPanel.allowedContentTypes = [.audio, .movie]`, no hand-maintained allowlist. Verified: mp3, m4a, wav, aiff, flac, aac, caf, mp4. WebM/Ogg can't be demuxed by AVFoundation and fail with `ImportError.noAudioTrack`, as does any file with no audio track.
- **Video works for free**: `mix` builds its composition from `loadTracks(withMediaType: .audio)`, so handing it one `.mp4` extracts the audio and drops the video.
- **Everything is transcoded to `.m4a`**, which is load-bearing rather than tidy-minded: `GeminiClient` hardcodes the `audio/mp4` mime type (§5.1), and `AVAudioFile` / `SFSpeechURLRecognitionRequest` **cannot open a video container at all**, so on-device transcription of an `.mp4` would fail outright without it.
- **No side tracks**, so `trackURL(for:_:)` returns nil and on-device transcription takes the unlabeled single-file path (§5.1c). Surfaced as a toast at import time when a non-Gemini engine is selected.
- Deliberately **not cancellable**, and an untitled note takes the source file's basename as its title.

> **CALLOUT — drag & drop had to be handled in AppKit, not SwiftUI.** `NSTextView` registers for file drags itself and pastes the path as text, and `PaddedTextView` sits above the SwiftUI `.onDrop` target — so a `.onDrop` on the editor never fires over the text body, which is most of the note. `PaddedTextView` overrides the dragging protocol, claims drags whose pasteboard holds a `RecordingImporter.canImport` URL, and falls through to `super` for everything else so ordinary text/PDF drags still behave.

### 4.3 `mix(inputs:to:durationCheck:)`

The one converter, shared by capture, import, and crash recovery. `AVMutableComposition` with each input's audio track inserted at `.zero` → `AVAssetExportSession(presetName: AVAssetExportPresetAppleM4A)` → `.m4a`, returning the verified duration (which is what `recordingDuration` stores — measured from the audio, never a wall clock, so the UI's length always matches what plays). `await session.export()` is deprecated on macOS 15 but functional.

Two safety properties:

- **Staging** — exports to a hidden `.dosa-export-<uuid>.m4a` sibling and only then `replaceItemAt`/`moveItem`s onto the destination. A failed export cannot destroy what was already there.
- **Duration verification** — reads the length back off the exported file and rejects a short result, so a truncated export surfaces as a loud error with the source audio intact.

> **CALLOUT — the duration check has to be looser for imports.** `DurationCheck.strict` (capture, recovery) demands within 1 s / 2%: expected duration comes from CAF files Dosa wrote, so any shortfall is real corruption. `.lenient` (import) demands only `> 0` and ≥ 50%, because container-less streams — raw ADTS `.aac`, some `.mp3`s — have no stored duration and estimate it from bitrate. A real `.aac` overshot by 17% (40.8 s claimed for 34.9 s of audio) and was rejected by the strict rule despite being perfectly good. Genuine truncation still fails under both.

### 4.4 Crash recovery (`NotesStore.recoverInterruptedRecordings`)

Scratch files outliving a session mean an interrupted capture (crash, force-quit, stream death). At launch `NotesStore` scans `Recordings/` for `*-{mic,system}.caf`, groups them by base name, recovers the note id from the name's UUID prefix, and mixes them into a real recording. It lands on the original note only when that takes nothing away — if the note already has a recording (or is gone), the salvage gets a new "… (Recovered)" note, because recovery must never itself destroy a recording.

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
- **Two-way speaker attribution without diarization**: `AudioRecorder.stop` also exports each source on its own — `<base>-mic.m4a` / `<base>-system.m4a` next to the mixed `<base>.m4a` (best-effort; a failed side export never fails the recording). `AppleTranscriber.transcribe(micURL:systemURL:…)` transcribes both, labels mic lines with the user's name (or "You") and system lines "Others", and interleaves by timestamp into the app's usual `**Speaker** [mm:ss]: …` format. Remote participants can't be told apart — they share the system track.
- **Echo suppression**: without headphones the mic also captures the other participants, so a mic line is dropped when a system line within ±3 s shares ≥50% of its words (`isEcho`, Jaccard-ish over lowercased word sets).
- Two cases have no side files — **imported files** (§4.2) and recordings made before per-track capture. `NotesStore.trackURL(for:_:)` returns nil for either, and because `GenerationManager` guards on `if let mic…, let system…`, a nil for *either* track falls through to the mixed file as unlabeled `[mm:ss] …` lines (word segments grouped on >1.2 s pauses / ~25 s spans). Gemini is unaffected — it diarizes from a single file — which is why import warns when a non-Gemini engine is selected. `deletePermanently`/`discardRecording` clean up side tracks via `removeRecordingFiles`.
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
- On success, posts `.notesReady` through `NotificationManager` (§11b) before the `defer` resets `phase`. Error paths stay on `ErrorDialogView` (§13); cancellation stays silent.
- Publishes `phase` (idle/transcribing/generating), `activeNoteId` (drives floating-bar spinner AND the sidebar row mini-spinner), `errorMessage` + `errorDetail` + `errorNoteId`.
- **Automatic mode (`enqueueAutomatic` + `queue` + `drain`)**: `RecordingCommand.stop` calls `enqueueAutomatic` on every stop; the manager owns the `AppSettings.automaticModeWillRun` gate so the rule lives in one place rather than at each future call site. A **FIFO queue** is required rather than a straight `run` call, because a recording can be started while another note is still generating (`RecordingCommand.isAvailable` deliberately does not consult `phase`) and `run`'s `guard phase == .idle` would silently drop it — the one failure mode that would make "automatic" untrustworthy. `drain` creates and `register()`s the Task itself, so the floating bar's Stop button cancels an automatic run like any other. `run`'s `defer` sets `phase = .idle` *before* `await run(…)` returns, so `drain` can recurse straight into the next note with no polling.
  > **CALLOUT — the `Task.isCancelled` check after `await run` is load-bearing.** `Task {}` is unstructured and does **not** inherit the enclosing task's cancellation, so without explicitly clearing the queue there, pressing Stop on one automatic run would immediately start the next one. `QuitGuard` needs no change: `drain` is called synchronously from `enqueueAutomatic`, so a non-empty queue always implies `phase != .idle`, which it already reports.
- **`run(automatic:)` and `errorNoteId`**: all four error exits (missing provider key, no audio file, Gemini-engine without a Gemini key, and the `catch`) funnel through one private `fail(…)` that stamps `errorNoteId` and — for automatic runs only — also posts `.notesFailed` (§11b). Automatic mode is the reason `errorNoteId` exists: the run's note may not be on screen, so an ungated `errorMessage` would raise the sheet over an unrelated note (§13). The message is **stashed as well as** announced, not replaced by the notification, so `ErrorDialogView` can still show the provider's raw response when the user opens the failed note.

### 5.3 Prompt defaults (`AppSettings.swift`)

The notes prompt implements the "bi-directional" architecture: manual notes are the anchor; rule 1 = include them **with only spelling/grammar corrected**; rule 3 = use the sections named under "Note type" (`{{template_context}}`) + omit empty sections + model may add sections for topics that don't fit; rule 4 = `{{verbosity}}`; rule 5 = factual only — no invented facts, and **no judging, rating, or editorializing**: opinions and conclusions are attributed to the people in the meeting, never added by the model; rule 6 = never repeat title/date, start at the first section heading; rule 7 = formatting contract (dash bullets, sparse bold, no italics, no bare `*`).

`{{template_context}}` is substituted **before** `{{user_name}}`, because the two interview templates embed `{{user_name}}` in their own prompt context ("a job interview that {{user_name}} is conducting" vs "in which {{user_name}} is the candidate"). Reverse that order and both ship with a raw `{{user_name}}` and start reading alike. Untemplated notes get `TemplateStore.defaultContext` (the old rule-3 section list, verbatim). If a stored custom prompt has no `{{template_context}}` placeholder, `withTemplateContext` **prepends** a `Note type:` block rather than appending — a transcript can run to tens of thousands of tokens and would bury an appended instruction. Settings shows a caption when that fallback is active.

`TemplateStore.promptContext(for:)` always appends `TemplateStore.objectivityRule` to whatever context it returns — shipped template, user-written template, or `defaultContext`. Notes are a factual record: the model may not rate, score, or conclude anything of its own, and an assessment-shaped section (strengths, concerns, signals, recommendation) may only carry assessments a participant actually made or the user wrote down, attributed, and is dropped otherwise. It lives in code rather than in the editable template text for two reasons: a template's job is structure + context, so no edit to one should be able to turn a record into a verdict; and templates persisted before the rule existed would never pick it up if it shipped only inside `builtIns`. The shipped contexts are written to match (e.g. Interview (Hiring) hands "## Strengths"/"## Concerns"/"## Recommendation" to the interviewer and forbids a model-authored hire call).

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
- **Not themeable by design**: body text (system label colors), destructive red, the floating overlays' translucent chrome (floating bar / toasts — see `FloatingChrome` in §9c), the titlebar row's glass pills (their *glyphs* can be tinted — the back arrow is — but the pills themselves are the system's), sidebar material.
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

## 9b. Window chrome & UI invariants

`.windowStyle(.hiddenTitleBar)` on the main `Window` scene is the **only** window-styling call. Traffic lights overlay the sidebar; `NavigationSplitView` still owns a window toolbar. The detail column's empty title slot otherwise shows through as a light/dark strip along the top of Welcome (the sidebar already draws under that region). The sanctioned fill is on the detail `Group` in `ContentView`:

```swift
.toolbarBackground(.hidden, for: .windowToolbar)
.background(Theme.current.editorBackgroundColor.ignoresSafeArea(edges: .top))
```

That hides the toolbar's material/separator, not the toolbar itself, so items and traffic lights stay, and the theme color paints under the now-transparent region.

**The sidebar toggle is the system's, and stays where macOS puts it.** `NavigationSplitView` supplies its own toggle in the window toolbar and manages column visibility itself. `ContentView` therefore takes no `columnVisibility` binding and adds no toggle of its own. Yes, the system toggle sits near the split rather than tucked against the traffic lights — that is standard macOS placement (Notes, Mail), and it is not a bug to be corrected.

Every attempt to relocate it has made things worse, because the traffic lights live in the window's titlebar view, which is a *sibling* of SwiftUI's content view — not inside it. Any hand-placed button is therefore positioned in the wrong coordinate space and drifts with window size, sidebar width, and macOS version:

```swift
// ❌ All of these have shipped a broken window. Do not reintroduce.
NavigationSplitView(columnVisibility: $columnVisibility) { … }   // hand-driven visibility
.toolbar(removing: .sidebarToggle)                               // strips the only real toggle
.overlay(alignment: .topLeading) { Button { … } }                // lands mid-sidebar
NSViewRepresentable { … window.standardWindowButton(.zoomButton) }  // wrong coordinate space
```

The last round of this produced a toggle floating in the vertical middle of the sidebar, a dead strip across the top, and a sidebar that no longer drew under the titlebar. The fix was deletion, not more geometry.

**Invariants that must hold after any UI change:**

1. Traffic lights visible at the top-left of the window.
2. Exactly one sidebar toggle, the system's, in the window toolbar. No second toggle, no hand-positioned one. The app contributes exactly one item of its own to that region — the back-to-Welcome arrow below — which is a *navigation* item, not a toggle; this invariant is about toggles.
2b. The back arrow is present iff the detail pane is showing something other than Welcome, in both sidebar states, and never overlaps the toggle or the traffic lights.
3. Sidebar fills the full window height and draws under the traffic lights; its `.padding(.top, 34)` clears them, with no separate blank strip above the folder/search/+ row.
4. Setup banner appears at the top of the detail pane when the user's name or the default provider's API key is missing; an empty banner must not reserve a strip (`SetupBannerInset` only insets when it has a message).
5. Welcome and the note editor both render correctly in light and dark, and across theme presets.

**Rules — do not:**

- `.toolbar(.hidden, for: .windowToolbar)` — removes the sidebar toggle. Combined with a collapsed titlebar, traffic lights vanish and the sidebar's `.padding(.top, 34)` becomes a dead strip. This shipped once.
- `.toolbar(removing: .sidebarToggle)` — leaves the window with no way to show a collapsed sidebar. This shipped once.
- Mutate `NSWindow` `styleMask` / `titleVisibility` / `titlebarAppearsTransparent`, or read `standardWindowButton(_:)` to position SwiftUI views, from an `NSViewRepresentable` (or any AppKit poke). That fights SwiftUI's window management and is what killed the traffic lights (`HiddenTitleBarChrome`) and misplaced the toggle (`TrafficLightAnchor`).
- `toolbar(removing: .title)` / `HideSplitViewTitle` as a strip-removal trick. Same class of chrome collapse.
- Add a `ToolbarItem` sidebar toggle, or drive `columnVisibility` by hand, to "reposition" the system toggle.
- Put window styling anywhere except `.windowStyle(...)` on the `Scene`.

**The back-to-Welcome arrow is the one sanctioned way to put a button up there.** `BackToWelcomeToolbar` (`SharedViews.swift`) adds a `ToolbarItem(placement: .navigation)` to the detail column, applied in `ContentView`. This is not an exception to the overlay ban above — it is the alternative to it, and the reason the ban can stay absolute:

- The arrow has to sit beside the sidebar toggle when the sidebar is collapsed and at the detail column's leading edge when it is open. Those are different x positions, and **the app cannot tell the two states apart** — the `columnVisibility` binding that would reveal it is build-blocked. The toolbar tracks the split for us, so no geometry is written by hand and nothing drifts.
- It is a visible affordance for something the app already did invisibly: `appState.selectedNoteIds = []`, the same action as ⌘W "Close Note" (`DosaApp.swift`) and a click on empty sidebar space (`SidebarDeselectCatcher`).
- **One action, two entry points, one key equivalent.** The button carries no `.keyboardShortcut` — ⌘W belongs to the `CommandGroup`, and a second responder for it in the same window would be a duplicate whose availability flickered as the button came and went.
- Visibility mirrors `body`'s branches (`isShowingDetail`), not `selectedNoteIds.isEmpty`: a selected id whose note no longer resolves falls through to Welcome, and an arrow floating over the home screen is the one wrong state reachable here.

**Do:** for edge-to-edge content in the detail pane, `.toolbarBackground(.hidden, for: .windowToolbar)` + `.background(...).ignoresSafeArea(edges: .top)` — the two lines above. If a view sits too high or too low, adjust *that view's* padding, and keep it inside normal layout flow (a top-anchored `VStack`/overlay reaching into the titlebar region is how the Welcome greeting ended up jammed against the window edge) — never touch the window.

**Enforcement:** `Scripts/check-window-chrome.sh` fails the build on every forbidden API above; `build.sh` runs it before compiling. If it fires, the fix is to delete the offending call, not to add an exception.

**Required verification for any UI-touching change:** `./build.sh`, quit any running Dosa, `open build/Dosa.app`, and confirm the invariants above against a known-good window. Collapse and reopen the sidebar, and resize the window.

---

## 9c. Floating overlay chrome (Liquid Glass, with a pre-26 fallback)

Three overlays float above the editor and share one look: the recording bar (bottom), the persistent
recording-away toast (top), and the transient event toast (top, below the persistent one when both
are up). `FloatingChrome` in `SharedViews.swift` is that look, and it is the only place the decision
is made — `.floatingChrome(in: shape)` at the recording bar in `NoteEditorView.swift` and at both
toasts in `ContentView.swift`.

(The ⋯ actions menu used to float as a pill in the top-trailing corner. It is a
`ToolbarItem(placement: .primaryAction)` now, so that it sits on the same line as the sidebar toggle
and the back arrow instead of below them — see the toolbar-glass rule further down.)

- **macOS 26+**: `.glassEffect(.regular, in: shape)` — real Liquid Glass, which brings its own edge
  highlight, shadow, and the automatic Reduce Transparency / Increase Contrast handling, so the
  glass branch adds no stroke or shadow of its own.
- **macOS 14–15**: the pre-26 recipe those overlays shipped with — `.regularMaterial` in the same
  shape, a `.quaternary` hairline, and a 10 pt/15 % shadow.

Two guards, because "no Liquid Glass" has two causes. `#if canImport(FoundationModels)` covers a
build machine on a pre-26 SDK, where `glassEffect` is not a symbol and the call has to vanish at
compile time (same SDK probe as `AppleTranscriber.advancedAvailable`). `if #available(macOS 26.0, *)`
covers a Mac on 14/15 running a binary built with the 26 SDK — the case that matters for shipping,
since `Package.swift` still targets macOS 14.

Details that are load-bearing:

- **Never `.interactive()`.** `Glass.interactive()` is for glass that is itself one button; on a
  container holding its own controls it lights the whole surface up when the pointer approaches any
  control inside it, and the surfaces left here are containers. `FloatingChrome` therefore takes no
  `interactive:` parameter — the one control that wanted it, the ⋯ pill, is a toolbar item now and
  gets the system's interactive glass for free.
- Glass is applied **last**, after padding and `clipShape`, per Apple's "apply `glassEffect` after
  other modifiers that affect appearance." In the recording bar the `clipShape` sits above the
  chrome so the transcription progress hairline is clipped as content and stays *above* the glass
  (glass renders behind the content it wraps).
- No `GlassEffectContainer`: it exists to blend and morph *adjacent* glass shapes, and the recording
  bar and the toast stack are isolated surfaces in different corners. Add one only if two glass
  shapes ever sit side by side. The two toasts share a `VStack` so they stack; they do not morph.
  The quick-settings panel (§9d) deliberately does not qualify — it is drawn as part of the bar's
  own shape, not as a second surface; the titlebar row does not either, because those are toolbar
  items and the system already groups them (see `ToolbarSpacer` below).
- Buttons inside the bar stay `.bordered` / `.borderedProminent`. Those pick up the 26 look
  automatically when recompiled, and glass-on-glass is explicitly against Apple's guidance.
- Glass refracts what is behind it, so over the editor's flat background it reads as a subtle tint
  rather than the dramatic refraction in Apple's marketing. That is correct output, not a failure.

**Recording-away toast.** ⌘R can start a capture from anywhere, and every on-screen trace of that
capture (waveform, elapsed clock, stop button) lives in `NoteEditorView`'s floating bar, which
unmounts the moment you leave the note. Whenever `AudioRecorder.isRecording` is true and the detail
pane is showing anything other than that recording's own note (`recordingNoteId !=
AppState.singleSelectedNoteId`; Welcome and multi-select both have a nil single selection, so both
show it), `ContentView` draws a persistent `RecordingAwayToast`: "Recording…" plus the live elapsed
clock. Clicking the capsule selects the recording's note. It is not dismissible. Gate on
`isRecording` first — `finish` clears that before `recordingNoteId`, so the toast leaves the instant
Stop is pressed.

It is a toast, not a banner: `.overlay(alignment: .top)` on the detail `Group`, same slot as the
transient toast, and a `Capsule()` matching that toast's shape and padding (14×8). A `safeAreaInset`
was considered and rejected — the note title is leading-aligned and the toast is centered, so they
sit side by side. Both toasts share one overlay `VStack` so they can never draw on top of each
other; the recording toast is first (on top) so a transient "recording saved" / "notes ready"
message never shoves it down. `.padding(.top, 10)` sits on that `VStack` (not on each toast) to keep
the stack clear of the hidden titlebar (§9b). The overlay stays after `.id(themeRefreshTick)` and
before `SetupBannerInset`, so a theme refresh doesn't flicker it and the setup banner pushes both
toasts down.

The red 1.5 pt border is `.overlay(shape.strokeBorder(.red, lineWidth: 1.5))` *on top of*
`floatingChrome`, not a colour on the chrome itself — chrome has no colour parameter, and the
macOS 26 glass branch draws no stroke, so only an overlay lands in both branches. The red is
SwiftUI's system `.red` (destructive red is not themeable, §8). There is no visible link; the whole
capsule is the hit target (`.contentShape` + `.onTapGesture`), so it does not introduce a second
chrome-bearing control inside the glass.

The ellipsis is not its own timer. `AudioRecorder.ringPhase` already ticks 0→23 on the 0.09 s
recording timer; `AnimatedEllipsis` derives three opacity states from `ringPhase / 8`, and Reduce
Motion pins all three dots on. All three dots stay laid out so the clock never shifts.

**The titlebar row is glass the app does not draw itself.** Three controls share that line — the system sidebar toggle, the back arrow (`.navigation`, §9b), and the ⋯ actions menu (`.primaryAction`, declared on `NoteEditorView` because it needs the open note). On macOS 26 the system wraps toolbar items in Liquid Glass; the sidebar toggle's pill *is* that treatment, not a bespoke one, and the other two get the identical pill for free.

So none of them carries `floatingChrome` or a `buttonStyle`, and none sets a font, frame, or `imageScale`. **Color is the one property worth setting**: both app-owned glyphs — the back arrow and the ⋯ — take `Theme.current.accentColor`, because `ContentView`'s `.tint` does not reach the window toolbar; it hosts its items outside the content hierarchy. (The sidebar toggle is the system's and stays system-colored; that asymmetry is unavoidable.)

They get there differently, and the difference is load-bearing. The ⋯ reads `Theme.current` inline, like the rest of `NoteEditorView`, because it sits inside the `.id(themeRefreshTick)` group and is rebuilt outright on a theme change. The back arrow's toolbar is applied *after* that `.id` on purpose — re-keying it would rip the item out of the NSToolbar and re-add it on every refresh — so it never gets that redraw, and its tint is **passed into** `BackToWelcomeToolbar` instead, making a theme change a real value change on the modifier. **The toolbar's own control metrics are what put all three on one line at one size**; overriding any of them is exactly what breaks the row. The ⋯ pill's previous incarnation is the cautionary tale — as a floating overlay it had to fight the menu's metrics with `resizable().frame(...)` on each glyph to get a usable size, and it still sat below the titlebar rather than in it. Moving it into the toolbar deleted all of that.

`FloatingChrome` is for overlays *over content* only; using it on a toolbar item is glass-on-glass, the same rule as "buttons inside the recording bar stay `.bordered`".

Spacers do two different jobs here, and both are load-bearing:

- `ToolbarSpacer(.fixed, placement: .navigation)` **breaks a glass group.** Adjacent same-placement items are wrapped in one glass container with hairline dividers, which would weld the back arrow onto the sidebar toggle as a segmented control.
- `ToolbarSpacer(.flexible, placement: .primaryAction)` **pushes the ⋯ menu to the trailing edge.** `.primaryAction` on its own does *not* mean "far right": in a `NavigationSplitView` detail column the items pack against the leading edge of the detail's toolbar section, and the ⋯ shipped for one build sitting immediately beside the back arrow because of it. `TrailingToolbarItem` in `SharedViews.swift` is that spacer plus the item.

Do not reach for `.padding` or `.offset` to reposition a toolbar item — SwiftUI exposes no trailing inset, and both of those resize or shift the *contents* of the glass pill rather than moving the pill.

> **CALLOUT — never write `if #available` inside a `@ToolbarContentBuilder` closure while the deployment target is below macOS 14.5.** `ToolbarContentBuilder.buildLimitedAvailability` has two overloads; the usable one is `@available(macOS 14.5, *)`, and `Package.swift` targets 14.0, so the compiler silently selects the other — `obsoleted: 14.5`, message "this code may crash on earlier versions of the OS" — whose body performs no type erasure at all. Hoist the check up to the `ViewBuilder` level instead (`ViewBuilder`'s equivalent is unconstrained), which is why `BackToWelcomeToolbar` is a `ViewModifier` that applies two whole different `.toolbar { }` blocks rather than one block with a branch inside. A `buildLimitedAvailability` deprecation warning in the build output means this slipped back in; hoist it, never silence it.

> **KNOWN, UNFIXED — the pointer shows an I-beam over the recording bar and both toasts.** They sit
> above `PaddedTextView`, and an `NSTextView` claims the I-beam across its whole visible area. (The
> ⋯ menu no longer has this: as a toolbar item it is not over the text view at all.) Clicks
> work; the pointer just reads as a text caret over the floating surfaces. Three layered-on-top fixes
> were tried and all three lost, because the text view re-asserts its claim from inside its own
> `resetCursorRects`: an arrow cursor rect on a view above it, an `.inVisibleRect`/`.cursorUpdate`
> tracking area above it, and `pointerStyle(.default)` (macOS 15+). A subtractive fix — markers
> registering the overlay frames, `PaddedTextView` carving them out of the rect it claims — was
> built and reverted as more machinery than the cosmetic problem warranted. Don't retry the three
> layered approaches. `.onHover` + `NSCursor.push()/pop()` is also a dead end: one dropped hover
> leaves the cursor stack unbalanced and the pointer stuck.

---

## 9d. The recording bar's quick-settings tab (`BarPedestalShape`, `QuickSettingsPanel`)

The two settings that get touched most — which model writes the notes, and how detailed they are —
are reachable from the floating bar without opening Settings. A pull-tab sits centered on the bar's
top edge; clicking it slides out a 300 pt panel holding a Model menu and the Notes Style slider.
Because `floatingBar(current:)` is one view for every bar state, the tab looks and behaves the same
idle, recording, and playing back.

**The panel is not a second surface — it is part of the bar's silhouette.** `BarPedestalShape`
(`SharedViews.swift`) is an `InsettableShape` drawing a wide plinth with a narrower box centered on
top, joined by concave fillets: collapsed the box is a 52×18 half-oval tab, open it is the panel.
`topWidth`/`topHeight` are its `animatableData`, so the tab *morphs* into the panel in one spring
rather than a card fading in above the bar.

Load-bearing details:

- **One continuous outline, not two overlapping rounded rects.** Overlapping subpaths would union
  fine under a non-zero fill, but `FloatingChrome`'s pre-26 branch calls `strokeBorder`, and a
  stroke traces the submerged edges too — a hairline seam straight across the junction. A single
  outline also gives Liquid Glass one unbroken edge to highlight, which is what sells the panel as
  part of the bar. Built corner-by-corner with `Path.addArc(tangent1End:tangent2End:radius:)`; at
  the two shoulders the interior angle is reflex, so the same call yields the concave flare.
- `topHeight` is **measured**, not hard-coded — a `GeometryReader` background on the panel + tab
  publishes `BarTopBoxHeightKey`, consumed into `@State topBoxHeight` (seeded at `tabHeight`, so
  frame one is already the collapsed state). Hard-coding it would go stale under a longer model
  name or a larger text size.
- `barShape` is therefore **computed, not a `static let`** like `pillShape` still is — it tracks
  view state now.
- `chunkingProgressStrip` hangs off the bar's *content*, not the whole container. On the container
  it would pin itself to the top of the tab, floating above the bar it reports on.
- `topWidth` is clamped so both shoulders keep a straight run of bar top edge to flare onto
  (`width - 2*(barCornerRadius + jointRadius)`); the narrowest real bar is ~430 pt against a 300 pt
  panel, so this only matters in degenerate layouts. `topHeight <= 0` degrades to a plain rounded
  rect — the bar exactly as it was before the tab existed.
- `MarkdownTextEditor`'s `bottomContentInset` went 74 → 88 for the tab's permanent 18 pt. The open
  panel is transient and reserves nothing.
- `NotesStyleSlider` is shared verbatim with Settings (§11) rather than reimplemented, so the two
  are literally the same control.

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

### 10.5 Google Calendar (REST, not MCP)

Google's hosted Calendar MCP server requires a pre-registered OAuth client and is Developer Preview. Dosa talks to the **Calendar REST API** instead, with the same browser-consent UX as Notion:

- **Auth** (`GoogleCalendarAuth`): installed-app authorization-code + PKCE, loopback ports 53690–53693, `access_type=offline` + `prompt=consent`, Keychain for access/refresh/expiry (`GoogleCalendarKeychain`, service `com.dosa.meetingnotes.google-calendar`). Scopes are `calendar.calendarlist.readonly` and `calendar.events.readonly` only. Disconnect best-effort revokes the token.
- **Credentials**: a Dosa-owned Desktop OAuth client is injected at assemble time from untracked `Resources/GoogleCalendarOAuth.json` into `Info.plist` (`DOSAGoogleCalendarClientID` / `DOSAGoogleCalendarClientSecret`). Missing file → Calendar sign-in disabled; Settings explains. End users never paste client credentials.
- **Sync** (`GoogleCalendarManager`): load `~/Library/Application Support/Dosa/calendar-cache.json`, refresh on launch/connect/calendar-selection change, every hour while running, and on wake/foreground when stale (≥1h). Paginated `events.list` per selected calendar with `singleEvents=true`, `orderBy=startTime`, `conferenceDataVersion=1`, `timeMin=now`, `timeMax=startOfDay(now)+30 calendar days`. Bounded concurrency (4). Transient/partial failures keep cached events. A 401 refreshes once; unrecoverable auth asks the user to reconnect.
- **Meetings**: timed, not cancelled, user has not declined, and (another non-resource attendee **or** an http(s) meeting link). Excludes all-day / focusTime / outOfOffice / workingLocation / birthday. Shared invites are deduped by iCal UID + occurrence start, preferring the primary calendar.
- **Home**: disconnected → existing `WelcomeView`. Connected → `CalendarHomeView` via `HomeView`, also used as the missing-note fallback in the editor and deleted-note views. Cards group the next 30 days; the popup shows a plain-text description (HTML stripped, no execution), validated http(s) links, Create Note, and Create & Start Recording Note. Template dropdowns are deferred.
- **Notes**: optional `calendarEventUID` / `calendarEventInstanceStart` / `calendarHTMLLink` / `calendarID` on `Note`. Prefill title only — calendar description/attendees never enter `manualText` or AI prompts. One active linked note per occurrence; trashing detaches the link so restore cannot collide with a replacement.
- **Banner**: first launch session that actually has Calendar credentials, disconnected home only, dismissible. Connecting, dismissing, or quitting that session sets `googleCalendarOnboardingFinished` so it never auto-returns.

---

## 11. Settings (`SettingsView.swift`)

Section order: **Profile** (Your Name → `{{user_name}}` + welcome greeting) → **Transcription** (engine dropdown Gemini (Cloud)/On-Device (Advanced)/On-Device (Basic) → `transcriptionEngine`; inline orange warnings when Gemini engine is picked without a Gemini key, or Advanced on a pre-26 macOS — the latter still saves but degrades to Basic at runtime) → **LLM Provider** (a **Default Provider** picker row at the top writes `llmProvider` and lists only providers with a saved key — `AppSettings.configuredProviders`; hidden behind a hint caption when no key is saved; self-heals on appear if the stored default lost its key. Below it, a segmented Gemini/Anthropic/OpenAI/DeepSeek control is UI-only `@State` for *editing* config — it opens on the default provider and never changes it. Gemini, Anthropic, and DeepSeek tabs = API key + link + model picker; Anthropic and DeepSeek add a shared `textOnlyProviderNote` caption pointing at the Transcription section; the OpenAI tab is a "coming soon" stub that resolves to Gemini at generation time) → **Automatic Mode** (one toggle → `automaticMode`, default off; §5.2) → **Notion** (§10) → **Google Calendar** (§10.5) → **Notes Style: \<level\>** (5-stop verbosity slider — level name lives in the section header; Dosa Notes Color swatches) → **Note Templates** (DisclosureGroup per template; built-ins Interview (Hiring) / Interview (Job Search) / 1:1 / Team Meeting plus user-created; Add Template / Restore Defaults; stored in UserDefaults `noteTemplates`. **Every template is deletable, built-ins included** — `builtInKey` only drives "Reset to Default" and lets Restore Defaults re-add a shipped one; a stored empty array therefore survives relaunch, and `TemplateStore.init` persists `builtIns` on first launch because they mint fresh UUIDs each process and a note's `templateId` would otherwise stop matching) → **Note Generation Prompt** / **Transcription Prompt** (DisclosureGroups, collapsed by default, whole label row toggles, "Reset to Default" buttons, placeholder hints) → **Notifications** (§11b) → **Theme** (preset cards with 3-dot palette previews, Accent Override swatches, Dosa color, Appearance picker) → **Backup** → **Updates**.

- **Model and Notes Style are also reachable from the recording bar's quick-settings tab** (§9d),
  which writes the same UserDefaults keys through `@AppStorage` — the two views stay in lockstep in
  both directions, and `NotesStyleSlider` is one shared view. The bar's Model menu is a **superset**
  across `configuredProviders`, so picking a model there moves `llmProvider` with it via
  `AppSettings.selectModel(_:provider:)` — a model choice that didn't also select its provider would
  be stored and never used. `AppSettings.availableModels(for:)` / `modelStorageKey(for:)` are the
  single provider-keyed lookups both views go through.
- **Automatic Mode** gates itself on more than its own toggle: `AppSettings.automaticModeWillRun` also requires the credentials a run would need, mirroring `run`'s own two key checks. Both the enqueue guard and the "Recording saved — transcribing…" toast read that single property, so the toast can never promise work that will not happen.
- **Backup**: Export/Import Settings as JSON (`SettingsSnapshot`: userName, appearance, geminiModel, llmProvider, deepseekModel, anthropicModel, transcriptionEngine, notesVerbosity, theme, accentOverride, dosaNotesColor, notesPrompt, transcriptPrompt, notificationsEnabled, automaticMode, noteTemplates). **API keys, Notion state, and Google Calendar tokens intentionally excluded**; import validates enum-ish fields and remaps retired models. `notificationsEnabled`, `automaticMode`, and `noteTemplates` are Optional so older exported JSON still decodes — nil (the old-JSON case) is skipped, but an empty `noteTemplates` array is imported as-is, since "I deleted every template" is now a real state to restore. Update-check keys (`automaticUpdateCheck`, `lastUpdateCheck`) are machine-local and also excluded.
- **Updates** (§2d): last section, after Backup — the most disruptive control, and the TCC warning reads as a closing note. Switches on `updater.state` (idle/upToDate identity row + Check; checking spinner; available commit list + Download; downloading progress; verifying; readyToInstall + prominent Install and Restart; installing). Always a "Check for updates when Dosa starts" toggle (`automaticUpdateCheck`, default true via `bool(forKey:default:)`) and a Releases link. Errors and recovered helper-failure text render in the footer like Notion connection errors. All progress stays inside the section — the Settings sheet covers ContentView's toast overlay (§14.20).
- Closing Settings bumps `themeRefreshTick` (§8).

> **CALLOUT — Form footer text on macOS 26 right-aligns wrapped lines** unless you add `.multilineTextAlignment(.leading)` (plus `.fixedSize(horizontal: false, vertical: true)` and a leading-aligned max-width frame). All footers here do this; keep the pattern for new ones. Similarly, a bare `Slider` or segmented `Picker` in a grouped Form gets shoved into the trailing "value column" (provider tabs hug the leading edge) — give it a hidden empty label + `.frame(maxWidth: .infinity)`.

---

## 11b. Notifications (`NotificationManager.swift`)

Transcription + generation can run for minutes, and a large import transcodes before it lands. `NotificationManager` announces three events: **recording saved** (in-app record or import), **notes ready** (generation success), and **couldn't generate notes** (an *automatic* run's failure — §5.2).

**Routing**: if `NSApp.isActive`, post an in-app toast (the same capsule overlay the editor used to own, now on ContentView's detail `Group` so it survives note switches and Welcome). If Dosa is in the background, post a `UNUserNotification` banner titled "Recording saved" / "Notes ready" with the note's `displayTitle` as the body. Tapping the banner activates Dosa and sets `pendingOpenNoteId`; ContentView writes that into `AppState.selectedNoteIds`. `willPresent` returns `[]` so a banner never stacks on a toast if Dosa came forward between post and delivery.

**One Settings toggle**, directly above Theme, defaults on. It gates **macOS banners only** — export toasts (Notion, recording file, markdown) and the in-app messages for these two events still fire with the toggle off. Authorization is requested lazily (`ensureAuthorized`) on first banner post and when the toggle is turned on, never at launch — same posture as mic/screen/speech (§4.1). A denied status surfaces a warning row in the section with an "Open System Settings" button.

Events are posted from app-lifetime objects, not views, wherever the work can outlive the editor: `GenerationManager.run` for notes-ready and notes-failed (the editor is rebuilt via `.id(id)` on selection change), `RecordingCommand.stop` / `NoteEditorView.beginImport` for the two user-facing saves. Do **not** hook `NotesStore.setRecording` — one of its three call sites is launch recovery and would fire on every start.

**Automatic mode (§5.2) is what makes the wording matter.** Two toast strings are written for a note that is probably *not* on screen: `.notesReady` reads "Notes ready — \<title\>" rather than a bare "Notes ready", and `.recordingSaved` reads "Recording saved — transcribing…" when `AppSettings.automaticModeWillRun`, which is the only signal at the moment of stopping that automatic mode engaged. Reading `AppSettings` from `Event.toastText` follows `.recordingImported`, which already consults `resolvedTranscriptionEngine`. `showToast` cancels the previous dismiss task, so the later "Notes ready" cleanly replaces the stop toast. **`.notesFailed` exists because the editor's error sheet is unreachable when the user is away** — the notification says *that* it failed, and `errorNoteId` keeps the sheet available to say *why* when they open the note (§13).

`UNUserNotificationCenter.current()` traps without a bundle identifier, so `NotificationManager.init` and `postBanner` no-op unless `Bundle.main.bundleIdentifier != nil`. Launch the `.app`, never `.build/release/Dosa`.

---

## 12. Keyboard shortcuts & commands (`DosaApp.swift`)

Menu-bar commands (also shown as key-cap hints at the bottom of the welcome page, `⌘ N` style with a space):

- **⌘N** New Note (replaces New Window) · **⌘R** Start / stop recording (same `CommandGroup(replacing: .newItem)`, between New Note and Import). Stops a capture from anywhere and saves it to its own note. Starts in the open note when that note has no recording or generated work; otherwise creates a new note (welcome, multi-select, deleted). **No-op** — and the menu item is disabled — when the open note already has a recording, transcript, or generated notes: a keystroke must not be able to raise the replace-audio prompt (§4.1). The Record button in the floating bar still prompts. · **⌘O** Import Audio or Video (same group; free because replacing that group removes the stock Open…) · **⌘W** Close Note = clear selection, no-op on welcome (replaces Close) · **⌘K** global search · **⌘F** in-note search (rides `noteSearchRequest: UUID?`; only acts when the open note has transcript/Dosa notes).
- Editor-local: ⌘Z/⇧⌘Z undo/redo, Tab/⇧Tab indent/outdent, Return list continuation (§6.1).

---

## 13. Error handling

- `DetailedError { errorDetail: String? }` — conformed by `GeminiError`, `AnthropicError`, `DeepSeekError`, `NotionMCPClient.ClientError`, and `UpdateError`; friendly `errorDescription` + raw payload separated.
- `ErrorDialogView` (sheet, not alert — alerts can't hold disclosure groups): warning icon, summary line, collapsed **"Show technical details"** (150 pt scrollable, selectable, monospaced raw body), OK. Presented from NoteEditorView via `errorPresented` binding that clears `localError(+Detail)` and `generator.errorMessage(+Detail, +NoteId)` on dismiss; Notion export errors are copied into the local pair. Notion *connection* errors render red in the Settings footer instead.
- **A generation error is presented only by the note it belongs to** — `errorPresented` requires `generator.errorNoteId == noteId`. Without that gate, automatic mode (§5.2) would raise the sheet over whatever note happened to be open, and with no note open at all the error would never be shown *or* cleared and would then fire on the next note opened. The bug was latent before automatic mode (⌘W mid-run, then let it fail); automatic mode makes it routine.
- Generation cancellations are silent by design.

---

## 14. Known quirks & operational notes (consolidated)

1. **TCC re-prompts after rebuild** (ad-hoc signing) — Microphone, Screen & System Audio Recording, and notification authorization. Same cause: `build.sh` re-signs with a new ad-hoc identity, so TCC treats each build as a new app — §2, §11b.
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
15. **ADTS `.aac` overstates its duration** — no container length, so it's estimated from bitrate; hence `DurationCheck.lenient` for imports — §4.3.
16. **`NSTextView` swallows file drags** and pastes the path as text — media drops are intercepted in `PaddedTextView`, not SwiftUI — §4.2.
17. Swift concurrency: Swift 5 language mode; Sendable warnings exist and are accepted. `NotesStore` non-isolated on purpose; managers `@MainActor`.
18. **Hiding the window toolbar killed traffic lights + sidebar toggle** — `.toolbar(.hidden, for: .windowToolbar)` plus an `NSWindow` `styleMask` poke (`HiddenTitleBarChrome`) collapsed the titlebar; the sidebar's traffic-light padding became a dead strip. This shipped once. Use `.toolbarBackground(.hidden, …)` instead — §9b.
19. **Relocating `NavigationSplitView`'s sidebar toggle is a trap** — it sits near the split, not by the traffic lights, and that is standard macOS placement. A `ToolbarItem` replacement duplicates it; an overlay positioned from `standardWindowButton(.zoomButton)` is measured against the titlebar view, a sibling of SwiftUI's content view, and landed mid-sidebar with a dead strip on top. Both shipped. Leave the system toggle alone — §9b, enforced by `Scripts/check-window-chrome.sh`.
20. **Recording-away toast is hidden behind sheets** — Settings, Global Search, Transcript, ErrorDialog, the confirmation dialogs. Sheets are modal and short-lived; the menu bar rings keep spinning. Do not hoist the toast above a sheet (that needs a window-level overlay or an `NSPanel`).
21. **A running app cannot replace its own bundle safely** — the swap runs in a detached `/bin/sh` helper that waits on the parent pid; the script is written to temp, never shipped inside the bundle being replaced, because `sh` reads scripts incrementally — §2d.
22. **`ditto` archives round-trip extended attributes**, so `xattr -dr com.apple.quarantine` runs in the helper before the swap — an ad-hoc-signed, un-notarized app that arrives quarantined is refused at launch — §2d.
23. **Stamping must precede `codesign`** — PlistBuddy after signing breaks the seal and makes the updater's own `codesign --verify` fail. CI asserts this — §2, §2d.
24. **Released binaries are arm64-only**; `manifest.json` carries `arch` and the updater refuses an incompatible slice — §2d.
25. **`.git` is a *file* in a git worktree**, so dev-checkout detection uses `fileExists`, not `isDirectory` — §2d.
26. **Updating re-triggers every TCC prompt** — same root cause as quirk 1, now user-facing. The install confirmation and the Updates footer both say so — §2d, §11.

## 15. Verification checklist (manual)

1. `./build.sh && open build/Dosa.app` — app launches, welcome shows stats + shortcut hints.
1b. Window chrome intact: traffic lights at top-left, exactly one (system) sidebar toggle in the toolbar, sidebar full-height with no dead strip above its header. Collapse and reopen the sidebar. Welcome watermark + greeting with no white strip at the top of the detail pane.
1c. Titlebar row: sidebar toggle, back arrow, and ⋯ menu all on one horizontal line at the same size. Back arrow absent on Welcome; present once a note (or a deleted note, or a multi-selection) is open, in both sidebar states; clicking it returns to Welcome. ⌘W still does the same thing, and File shows "Close Note" once. Every ⋯ menu item still works (exports, Notion, import, re-transcribe, discard, delete).
1d. Google Calendar: first-launch banner only while disconnected, dismissible, gone after quit. Connect in Settings (browser) → homepage becomes the 30-day meeting list with today's date. Cards open the detail popup; Create Note / Create & Start Recording Note reuse one linked note; trashing that note allows a replacement. Disconnect restores Welcome. `swift run DosaCalendarChecks` covers filter/dedupe/cache/linking.
2. Record (mic + play a video) → waveform bounces → stop → play with scrub bar.
2b. Import: drag an `.mp4` onto a note, and repeat via ⌘O / sidebar `+` / ⋯ menu → play button with the right duration → Generate produces a transcript. Import onto a note that already has audio → prompt appears; "Import into a New Note" leaves the original untouched; after "Replace It" the previous `.m4a` is still in `Recordings/` under its old timestamped name.
3. Generate Notes → sidebar row spinner → Dosa Notes tab with diff colors → Re-generate label; Stop mid-run cancels silently.
4. ⌘K / ⌘F search → results jump + yellow flash (including into the transcript sheet).
5. Themes: switch presets + Appearance in Settings, close → everything recolors at once, editors included.
6. Sidebar: multi-select, drag into/out of folders, pin (section appears/disappears), swipe left/right, delete confirmations.
7. Notion: Connect (browser) → Dosa Notes DB auto-created → Export → entry appears with Title/Date → edit + Update in Notion (no duplicate) → delete page/DB in Notion → export self-heals.
8. Settings export/import round-trip on a second machine (API key & Notion excluded by design).
9. `./build.sh` stamps `DosaBuildCommit` / `DosaBuildChannel` on the *bundle* copy of Info.plist; `codesign --verify --strict build/Dosa.app` exits 0; `git status --porcelain` is empty (proves `Resources/Info.plist` untouched and `build/` ignored). `DOSA_RELEASE_BUILD=1 ./build.sh` on a dirty tree hard-fails.
10. Settings → Updates with no GitHub Release yet: "No release has been published yet." — plain text, not error styling, no sidebar badge. Offline manual check shows a footer error; relaunch is silent (no badge, no toast).
11. After the first release: sidebar badge appears; Settings lists the commit count and subjects; Download → Install and Restart quits and relaunches; Settings shows the release's short SHA; no `.Dosa-update-*` or `.bak` left behind; `xattr -l` on the installed app shows no `com.apple.quarantine`.
12. `DOSA_BUILD_COMMIT=<older sha> ./build.sh --install` is the escape hatch to exercise the update path against a release of a newer commit.
13. Dev-checkout confirmation: launch `build/Dosa.app` directly, update → the alert names the checkout path. Busy guard: start a recording, hit Install → alert lists "recording audio"; Cancel leaves the recording running.
14. Drag the sidebar split to its 230 pt minimum with the update badge showing — the version label must not clip.
