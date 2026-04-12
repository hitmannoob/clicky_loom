# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Has two operating modes:

1. **Push-to-talk companion.** Ctrl+Option captures voice, transcribes via AssemblyAI streaming, sends the transcript plus a screenshot of the user's screen to OpenAI (`gpt-5.4-mini`), narrates the response, and optionally flies a blue cursor overlay to a UI element referenced in the answer.
2. **Guided walkthroughs.** User A hits Record and narrates a walkthrough out loud while doing the actions on their screen. A background queue transcribes the audio (AssemblyAI batch), segments it by screenshot timestamps, post-processes each step via OpenAI, and uploads the assembled guide to Cloudflare R2. The result is a `clicky://guide?id=...` deep link that User B can open to play back the walkthrough step by step — with narration, cursor pointing, and auto-advance via screen matching.

Visual element grounding (the "find the X button on this screen" task, used by both modes) is handled by **MolmoWeb-4B** hosted on Modal — a specialized web-agent vision model that's significantly more accurate at ScreenSpot-style pointing than general-purpose vision APIs.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for the menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat / Vision**: OpenAI `gpt-5.4-mini` via the Cloudflare Worker proxy with SSE streaming. Originally planned for Claude; pivoted to OpenAI for user's API availability.
- **Screen Matching / Stuck Detection**: OpenAI `gpt-5.4-mini` with classification prompts — polled during guided-mode auto-advance. MolmoWeb is a spatial pointing model, not a yes/no classifier, so classification routes through OpenAI instead.
- **Element Grounding**: `allenai/MolmoWeb-4B` served via HuggingFace Transformers on Modal (scale-to-zero GPU). See `modal/molmoweb.py`.
- **Speech-to-Text**: AssemblyAI real-time streaming (`universal-3`) for push-to-talk; AssemblyAI batch (`universal-2`) for guide recording transcription (word-level timestamps power the screenshot segmentation).
- **Text-to-Speech**: macOS built-in `AVSpeechSynthesizer`. ElevenLabs was the original choice but their free tier flags all Cloudflare Worker IPs as "unusual activity" (`detected_unusual_activity` / 401). The `ElevenLabsTTSClient` class name and public API are kept for continuity — the body now speaks via the system synthesizer. Swap back to the Worker `/tts` route when upgrading to a paid ElevenLabs plan.
- **Guide Storage**: Cloudflare R2 bucket `clicky-guides`. Each guide is a single self-contained JSON blob under key `guides/{uuid}.json` with reference screenshots base64-embedded inline (no separate asset fetches at playback time).
- **Deep Links**: `clicky://guide?id={uuid}` registered via `CFBundleURLTypes`. Handled in `CompanionAppDelegate.application(_:open:)` — fetches the guide from the Worker's `/guide/:id` route and loads it into `GuidedSessionManager`.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support, cursor screen detection
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only `CGEvent` tap.
- **Element Pointing (push-to-talk)**: OpenAI emits `[TARGET:label]` tags in responses. `CompanionManager` strips the tag before narration and hands the label to `MolmoWebClient.groundElement`, which returns pixel coordinates in the live screenshot. The overlay animates the blue cursor along a bezier arc to the resolved target.
- **Element Pointing (guided mode)**: Same flow — each `GuideStep.point.label` is passed to `MolmoWebClient.groundElement` during playback so the cursor re-localizes to whatever the current user's screen actually shows (not the author's recorded pixel coordinates).
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.openai.com/v1/chat/completions` | OpenAI vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS (currently unused — `ElevenLabsTTSClient` speaks via `AVSpeechSynthesizer` locally) |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Short-lived (480s) AssemblyAI websocket token for push-to-talk streaming |
| `POST /audio/transcribe/submit` | `api.assemblyai.com/v2/upload` + `/v2/transcript` | Kicks off an AssemblyAI batch job for a recorded walkthrough. Takes raw WAV bytes in the body, returns `{ transcript_id }`. |
| `GET /audio/transcribe/status/:id` | `api.assemblyai.com/v2/transcript/:id` | Polls for batch transcription completion. The macOS client polls every ~1.2s until `status == "completed"` or `"error"`. |
| `POST /guide/upload` | — | Stores a full `ClickyGuide` JSON blob in the `clicky-guides` R2 bucket under `guides/{uuid}.json`, returns `{ guide_id, deep_link: "clicky://guide?id=...", share_url: "https://<share-base>/g/..." }`. |
| `GET /guide/:id` | — | Fetches a previously uploaded guide from R2 by id as raw JSON. Public — guide ids are random UUIDs (share-link semantics, no auth). |
| `GET /g/:id` | — | Renders a lightweight light-theme HTML share page for a previously uploaded guide: title, author, repo context (when `context.type == "repo"`), transcript preview (first 3 steps), an `Open in Clicky` deep-link button, and an install CTA fallback. This is the universal web share target — it's the URL returned as `share_url` from `/guide/upload`. |

Worker secrets: `OPENAI_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`, `SHARE_BASE_URL` (optional — base url used for `share_url` in `/guide/upload` responses and for constructing the `/g/:id` link surfaced on completed uploads; falls back to the incoming request origin when unset, so local `wrangler dev` and `*.workers.dev` hostnames both work out of the box)
Worker bindings: `GUIDE_BUCKET` → R2 bucket `clicky-guides`

### MolmoWeb visual grounding (Modal)

Element grounding runs on a separate Modal deployment at `modal/molmoweb.py` — it loads `allenai/MolmoWeb-4B` via HuggingFace Transformers (pinned to `transformers==4.57.3`, the exact version the model was saved with; any other version breaks the custom `Molmo2Processor` with `Unexpected keyword argument image_use_col_tokens`). Two HTTPS endpoints:

- `GET /health` — liveness probe, no auth, doesn't trigger a model load
- `POST /ground` — Bearer auth, takes `{ screenshot_base64, element_label }`, returns `{ raw_output }`. The Swift client (`MolmoWebClient.swift`) parses coordinates out of three possible formats in priority order:
  1. **Click-action JSON** `{"name":"click","button":"left","click_type":"single","x":52.4,"y":31.0}` — this is what MolmoWeb-4B's `pointing:` mode actually emits in practice (confirmed via end-to-end testing). x/y are **0-100 percentages** of the image dimensions.
  2. **Legacy `<point x="..." y="...">` tags** — same percentage format, original Molmo style, kept as a fallback.
  3. **Plain `\d+,\d+` pixel pair** — last-ditch fallback, treated as pixel coordinates.

Deployment: `modal deploy modal/molmoweb.py`. Scale-to-zero with a 10-minute warmup window. Model weights are cached in a persistent Modal volume (`clicky-molmoweb-hf-cache`) so subsequent cold starts reload from the volume in ~20-40s instead of re-downloading the 16 GB model from HuggingFace.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Push-to-talk doubles as guide advance**: When a guided session is in `.waitingToAdvance(_, .manual)` state, `CompanionManager.handleShortcutTransition(.pressed)` hijacks the push-to-talk press and routes it to `GuidedSessionManager.advanceManually()` instead of starting a recording. This gives User B a single, consistent "next step" gesture without introducing a new keyboard shortcut.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Why MolmoWeb only for grounding, not screen matching**: MolmoWeb-4B is a spatial pointing model — its native output modes (`pointing:`, `molmo_web_think:`) emit coordinate tags and web-agent JSON actions, neither of which translates cleanly to yes/no classification. Screen matching (`"does this screenshot satisfy condition X?"`) and stuck detection (`"did the user make progress?"`) are routed through `OpenAI.checkScreenMatch` / `OpenAI.detectStuck` instead. The tradeoff is API cost during auto-advance polling (~$0.002 per 3s poll), which is fine for the prototype.

**Why system TTS (not ElevenLabs)**: ElevenLabs' free tier flags all requests coming from Cloudflare Worker IPs as "unusual activity" (`detected_unusual_activity` / 401). Upgrading to their Starter plan fixes it, but for the prototype we swapped the body of `ElevenLabsTTSClient` to use macOS's built-in `AVSpeechSynthesizer`. The class name, file name, `init(proxyURL:)` signature, and public methods (`speakText`, `isPlaying`, `stopPlayback`) are unchanged so `CompanionManager` doesn't know or care which backend is live. When we upgrade to a paid EL plan, revert the body of `speakText` to POST to the Worker `/tts` route and everything else keeps working.

**Why direct Transformers on Modal (not vLLM)**: vLLM 0.8.5's multimodal model registry doesn't recognize MolmoWeb-4B's `Molmo2` architecture — attempting to serve it fails with `limit_mm_per_prompt is only supported for multimodal models` even with `trust_remote_code=True`. Direct HuggingFace Transformers loads the model via `AutoModelForImageTextToText` + `trust_remote_code=True`, which is the reference path from the model card. Tradeoff: no continuous batching, but we only hit the server one request at a time during a guided session anyway.

**Guide JSON is self-contained**: Reference screenshots for each step are base64-embedded inline in the `ClickyGuide` JSON (field: `ref_image_base64`), not stored as separate R2 objects. Makes each uploaded guide a single atomic object that can be fetched in one request. Increases storage size by ~33% vs. binary, but a 5-step guide with 200KB screenshots per step is still ~1.3MB — trivial for R2 and removes an entire class of "missing asset" errors from playback.

**Background upload queue (not inline)**: After User A hits Stop, the `GuideRecordingSession` is handed off to `GuideUploadQueue` which runs transcribe → segment → per-step OpenAI → R2 upload in a single Task in the background. User A can immediately start a new recording — the queue processes one entry at a time in FIFO order and publishes per-entry status (`.queued`, `.transcribing`, `.segmenting`, `.generatingSteps(current, total)`, `.uploading`, `.completed(guideID, deepLink, shareURL?)`, `.failed(error)`) that the menu bar panel renders as a live list with a Copy Link button on completed rows. The button prefers `shareURL` (the universal `https://…/g/:id` web page) over `deepLink` (the `clicky://` handoff) when both are present.

**Record-time repo context capture**: On Stop, before the recording enters the upload queue, `CompanionManager.stopGuideRecordingAndEnqueueForProcessing` shows an `NSOpenPanel` titled "Pick the file you walked through" (codebase distribution v1, spec §9). If the author picks a file inside a git repo, `CodebaseContextCaptureService.captureRepoContext` shells out to `/usr/bin/git` (`rev-parse --show-toplevel`, `remote get-url origin`, `branch --show-current`, `rev-parse HEAD`) to build a `GuideContext(type: .repo, …)` with the remote URL, branch, commit SHA, repo-relative open path, workspace name, inferred SSH/HTTPS clone preference, and the `editor_bundle_id` that was captured from `NSWorkspace.shared.frontmostApplication` at the exact moment `GuideRecorder.startRecording` was called. The captured context is threaded through `GuideUploadQueue.enqueueRecordingSession(_:withCapturedGuideContext:)` and baked into the uploaded `ClickyGuide.context`. Cancelling the picker or picking a file outside any git repo falls back to the legacy `type:.url, target:"unknown"` default — the guide still uploads, it just isn't eligible for Phase 2's workspace-restoration flow.

**AI follow-along during guided playback (Phase 3)**: Once a guided session is actively playing (any of `.speakingNarration`, `.waitingToAdvance`, `.stuckOnStep`, or `.completing`), the user can press the existing push-to-talk shortcut (Ctrl+Option) to ask the AI assistant a question about where they are in the walkthrough, what to do next, or what's on the screen (spec §14). The wiring is intentionally minimal: `CompanionManager.sendTranscriptToOpenAIWithScreenshot` detects an active guided session at the top of its pipeline by calling `GuidedSessionManager.currentGuidedFollowAlongSystemPrompt()` — non-nil swaps the generic companion system prompt for a guide-aware one built by `GuidedFollowAlongContextBuilder`, and skips the shared conversation history so guided Q&A doesn't pollute regular push-to-talk memory. The rest of the pipeline (image capture, streaming, `[TARGET:label]` parsing, MolmoWeb grounding, TTS response) is unchanged. The guide-aware prompt embeds: the guide title + author, current step narration with surrounding context (2 prior + 1 next), repo metadata (remote URL, branch, commit SHA, workspace folder) when `context.type == .repo`, and — when Phase 2 prep ran successfully — the real receiver-side repo root + opened file path pulled from `WorkspacePreparationResult`. The prompt explicitly constrains the assistant to follow-along help, never autonomous coding. Manual-advance intercept still takes priority: in `.waitingToAdvance(_, .manual)` Ctrl+Option advances the step; in every other playing state it runs the follow-along flow. The panel renders a small "⌃⌥ ask the assistant" hint under the progress bar in follow-along-eligible states only.

**Receiver-side workspace validation (Phase 2, validation-gate model)**: When a guide whose `context.type == .repo` hits `GuidedSessionManager.startPlayback`, the session detours through `WorkspacePreparationCoordinator.validateWorkspaceStateForGuide` before any narration plays (spec §6.3, §10–13, §15). **Clicky never writes to the user's git repo** — no clone, no fetch, no checkout, no stash. It only reads receiver state, compares against the author's recorded state, and if there's a mismatch it tells the user what shell commands to run in their own terminal. The user does the destructive work themselves and hits Retry. This is deliberately the opposite of the pre-refactor "auto-clone-and-checkout" design — we decided respecting the receiver's existing git workflow beat the magic-clone UX for a dev audience.

The coordinator's three phases each push a live status string through the callback into the `.preparingWorkspace(currentPhaseDescription:)` session state for the panel to render:

1. **Resolve local folder.** `RepoWorkspaceResolver.rememberedRepoFolderURL` looks up the absolute path of the user's clone by normalized remote URL (`com.clicky.workspace.repoFolderPathsByNormalizedRemoteURL` `UserDefaults` key — a `[normalizedURL: folderPath]` dict). On first run for a given repo, the coordinator shows an `NSOpenPanel(canChooseDirectories=true)` titled "Pick your local clone" with a message surfacing the guide's full remote URL. The picked folder is verified via `GitRepositoryClient.originRemoteURLString` + normalized comparison — if it's not the right repo, `WorkspaceValidationError.pickedFolderRemoteURLMismatch` is thrown and the user sees a readable error. On success the folder is persisted for next time.
2. **Read receiver state.** A `WorkspaceStateSnapshot` is built from parallel reads of `originRemoteURLString` (re-normalized), `currentBranchName`, `currentHeadCommitSHA`, and `isWorkingTreeDirty`. Each field tolerates its own read failure, so one bad read doesn't tank the whole comparison.
3. **Compare + decide.** `buildWorkspaceStateComparison` emits a `[WorkspaceMismatchFinding]` with per-field ✓/✗ status (repository, branch, commit — plus an info-only "working tree" row when dirty). If every finding matches, the coordinator launches the preferred editor via `EditorLauncher.launchPreferredEditor` and returns `.ready(preparedContext:)` with a `WorkspacePreparationResult` struct carrying the absolute repo root + opened file URL (which Phase 3 follow-along reads to surface the receiver's real state to the assistant). If any finding doesn't match, the coordinator emits `.needsUserAction(comparison:)` carrying the checklist plus a `[String]` of suggested shell commands (always `cd <repo>` preamble + `git fetch origin` + `git checkout <sha-or-branch>` in that order) for the user to copy-paste.

On `.needsUserAction`, the session transitions to `.awaitingWorkspaceMatch(comparison:)`. The panel renders a warning-styled card with: per-finding rows showing expected vs actual values, a monospaced shell-command block with a "Copy" button (copies `cd <path>\n<commands>` to the system clipboard), and an action row with **Retry** (primary, runs validation again — the remembered folder path means no re-prompting), **Watch only** (jumps into the narration loop using embedded screenshots, same as the watch-only fallback from catastrophic failures), **Pick folder…** (calls `RepoWorkspaceResolver.forgetRepoFolderURL` and re-runs validation, which re-prompts the `NSOpenPanel`), and **Cancel** (calls `stopPlayback`).

Catastrophic failures — folder picker cancelled on first run, `/usr/bin/git` missing, picked folder not a git repo or origin mismatch — throw `WorkspaceValidationError` and transition to `.workspacePreparationFailed(failureReason:warningMessages:)`, which shows the same "Play anyway (watch only)" button the old orchestrator did. `GuidedSessionManager.playbackInWatchOnlyMode()` is now reachable from both `.awaitingWorkspaceMatch` (user ignored the mismatch on purpose) and `.workspacePreparationFailed` (user can't fix the catastrophic failure).

Dirty working trees are **not** a blocking condition. `isWorkingTreeDirty` surfaces as an info-only row in the checklist (`"working tree: uncommitted changes (won't block playback)"`) and as a non-fatal warning logged after a successful `.ready`. Stashing, committing, or ignoring dirty files is explicitly the user's decision.

Private-repo auth is delegated to the receiver's existing SSH agent / keychain / git credential helpers — Clicky doesn't invoke any write operations, so auth never enters the picture on the Clicky side. If the user needs to authenticate to clone or fetch, they do it in their own terminal when they run the suggested commands.

**Word-level timestamp segmentation**: The guide recording pipeline captures one screenshot every 5 seconds with per-frame timestamps measured from recording start. AssemblyAI's batch API returns word-level timestamps, so `GuideUploadQueue.segmentTranscriptByScreenshots` builds each step's transcript chunk from the words whose `startSeconds` fell in `[screenshot_t, next_screenshot_t)`. Each `(screenshot, transcript_chunk)` pair is handed to `OpenAIAPI.generateGuideStep` which emits structured JSON (narration, point element label, advance mode, advance condition, stuck hint) via `response_format: json_object`.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~150 | Menu bar app entry point. `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. Also handles `clicky://guide?id=...` deep links via `application(_:open:)` — fetches the guide from the Worker and loads it into `GuidedSessionManager`. |
| `CompanionManager.swift` | ~380 | Central state machine (split across `+VoiceMode`, `+Permissions`, `+Onboarding` extensions). Owns dictation, shortcut monitoring, screen capture, `OpenAIAPI`, `ElevenLabsTTSClient` (system TTS under the hood), `MolmoWebClient`, and the guided-mode trio (`guidedSessionManager`, `guideRecorder`, `guideUploadQueue`). Reads runtime endpoints from the repo-root `.env` via `AppBundleConfiguration`. Coordinates the full push-to-talk → screenshot → OpenAI → TTS → MolmoWeb pointing pipeline. Intercepts Ctrl+Option as "next step" when a guided session is waiting on manual advance. On record-stop, `stopGuideRecordingAndEnqueueForProcessing` presents an `NSOpenPanel` asking the author to pick the walked-through file, then calls `CodebaseContextCaptureService` to build a repo-type `GuideContext` before handing the session to `guideUploadQueue` — cancel = upload without repo context. |
| `CompanionManager+VoiceMode.swift` | ~470 | Push-to-talk pipeline extension: shortcut transition binding, the `sendTranscriptToOpenAIWithScreenshot` AI response flow (image capture → OpenAI streaming → `[TARGET:label]` parse → MolmoWeb grounding → TTS), conversation history, transient-cursor scheduling, target-tag parser, screen coordinate mapping. Phase 3 follow-along hook: at the top of `sendTranscriptToOpenAIWithScreenshot`, reads `guidedSessionManager.currentGuidedFollowAlongSystemPrompt()` and — when non-nil — swaps the generic `companionVoiceResponseSystemPrompt` for the guide-aware one and passes an empty conversation history so guided Q&A stays stateless and doesn't leak into push-to-talk memory. Everything downstream of the prompt selection is identical between the two flows. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs the click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~1300 | SwiftUI panel content for the menu bar dropdown. Header, permissions UI, model picker, DM feedback button, and the new `GuidedModeSection` subview (Load / Fetch / Record buttons, progress bar during playback, live upload queue list with Copy Link buttons). Dark aesthetic using `DS` design system. |
| `GuidedSession.swift` | ~310 | Codable data model for `.clicky.json` guide files: `ClickyGuide`, `GuideStep`, `StepAdvance`, `GuideContext`, `GuidePoint`, `GuideVoice`, `GuideCompletion`. Includes a lenient ISO8601 date decoder and shared `jsonEncoder` / `jsonDecoder` for round-tripping through the Worker. `GuideContext` carries optional codebase-distribution fields (`commitSha`, `openLine`, `editorBundleId`, `workspaceName`, `clonePreference`) alongside the original `type/target/branch/openPath` — all additive so pre-extension guides decode unchanged. |
| `GuidedSessionManager.swift` | ~740 | Playback engine for recorded walkthroughs. `@Published` state includes Phase 2 validation-gate states: `.preparingWorkspace(currentPhaseDescription)` (brief read-state phase), `.awaitingWorkspaceMatch(comparison)` (the validator found mismatches and is waiting on the user to run shell commands + hit Retry), and `.workspacePreparationFailed(failureReason, warningMessages)` (catastrophic failure). For guides whose `context.type == .repo`, `startPlayback` detours through `WorkspacePreparationCoordinator.validateWorkspaceStateForGuide` before narrating step 0 and stashes the returned `WorkspacePreparationResult` so Phase 3 follow-along can surface the real receiver-side repo root + opened file. `retryWorkspaceValidation()` re-runs the validator from the Retry button. `pickDifferentRepoFolderAndRevalidate()` forgets the remembered folder and re-prompts via `NSOpenPanel`. `playbackInWatchOnlyMode()` is reachable from both `.awaitingWorkspaceMatch` and `.workspacePreparationFailed` — jumps straight to the existing narration loop using the guide's embedded screenshots. Drives each step: speak narration → ground via MolmoWeb → fly cursor → wait for auto/manual/timed advance → advance or complete. Auto-advance polls `OpenAIAPI.checkScreenMatch` every 3s and speaks the `stuck_hint` when `timeout_seconds` fires without a match. Phase 3 hooks: `isGuidedFollowAlongAvailable` (true in speaking / waiting / stuck / completing states) and `currentGuidedFollowAlongSystemPrompt()` (returns a fully-baked guide-aware system prompt via `GuidedFollowAlongContextBuilder` or nil when no follow-along session is active) — both read by `CompanionManager+VoiceMode.sendTranscriptToOpenAIWithScreenshot` to swap the push-to-talk system prompt mid-flight. |
| `GuideRecorder.swift` | ~370 | User A recording pipeline. Captures mic audio via `AVAudioEngine` (converted to 16 kHz PCM16 mono via `BuddyPCM16AudioConverter`) and one screenshot every 5s via `CompanionScreenCaptureUtility`. Publishes `isRecording`, live duration, frame count. At `startRecording` time also snapshots `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` (filtered to exclude Clicky itself) so the uploader can tag the guide with `editor_bundle_id` for Phase 2 editor launch. `stopRecording()` returns a `GuideRecordingSession` bundle (WAV audio + timestamped screenshots + duration + captured editor bundle id) ready for the upload queue. |
| `GuideUploadQueue.swift` | ~620 | Background processor for recorded guides. FIFO queue of `GuideUploadQueueEntry` structs with live `@Published` status. `enqueueRecordingSession(_:withCapturedGuideContext:)` accepts an optional pre-built `GuideContext` from `CodebaseContextCaptureService` — when present it's threaded into the assembled `ClickyGuide.context`, otherwise the legacy `type:.url, target:"unknown"` default ships. For each entry: submits WAV to `/audio/transcribe/submit`, polls `/status/:id` until complete, segments the transcript by screenshot timestamps using AssemblyAI word timings, calls `OpenAIAPI.generateGuideStep` per (screenshot, chunk) pair, assembles a `ClickyGuide` with inline base64 screenshots, and uploads to `/guide/upload`. Publishes the resulting `share_url` (preferred) + `deep_link` for the panel's Copy Link button. |
| `CodebaseContextCaptureService.swift` | ~220 | Builds `GuideContext(type: .repo, …)` values from a user-picked file by shelling out to `/usr/bin/git` via `Foundation.Process`. Pure + stateless — called from `CompanionManager` after the post-stop `NSOpenPanel` returns a URL. Resolves repo root via `rev-parse --show-toplevel`, fetches remote/branch/commit, computes repo-relative `open_path`, infers `clone_preference` from the remote URL shape (`git@…` → `ssh`, everything else → `https`), and pairs it with the editor bundle id captured by `GuideRecorder`. Also hosts `currentFrontmostApplicationBundleIdentifier()` — the NSWorkspace helper `GuideRecorder` uses at record-start time. |
| `GitRepositoryClient.swift` | ~170 | Read-only async wrapper over `/usr/bin/git` for the Phase 2 validation-gate flow. Methods: `originRemoteURLString`, `currentBranchName`, `currentHeadCommitSHA`, `isWorkingTreeDirty`. All go through a single private `runGitCapturingStdout` helper that dispatches the process on a detached `Task` so the main actor stays responsive. Throws `GitCommandError` on non-zero exits. **Deliberately has no write operations** — no clone, no fetch, no checkout, no stash — because the Phase 2 refactor moved all destructive git work out of Clicky and into the receiver's own terminal. Safety by construction: this file literally cannot damage the user's repo. |
| `RepoWorkspaceResolver.swift` | ~200 | Persistent `[normalizedRemoteURL: folderPath]` map that remembers where each guide's target repo lives on the receiver's machine, keyed under the `com.clicky.workspace.repoFolderPathsByNormalizedRemoteURL` `UserDefaults` key. `rememberedRepoFolderURL`, `rememberRepoFolderURL`, and `forgetRepoFolderURL` are the three lookup/write/forget operations. `normalizeRemoteURLForMatching` collapses ssh short form / ssh long form / https-with-dot-git / https-without-dot-git all to the same canonical `host/owner/repo` key so matching is robust against the author and receiver using different URL forms. No filesystem scanning, no auto-discovery — the user explicitly picks the folder once via NSOpenPanel and Clicky remembers it. |
| `EditorLauncher.swift` | ~290 | Launches the receiver's preferred editor on a prepared repo + target file. Precedence: the author's `editor_bundle_id` (if installed) → Cursor → VS Code → `NSWorkspace.open` system default handler → last-resort `NSWorkspace.open(repoRootURL)` in Finder. For Cursor and VS Code the launcher prefers the CLI shim (`Contents/Resources/app/bin/cursor`, `.../code`) because it supports `-g file:line` cursor-jump; falls back to `/usr/bin/open -b <bundle-id>` for other editors (Xcode, Zed, etc.), which loses line navigation but still opens the file. Returns a typed `LaunchOutcome` so the coordinator knows which path succeeded. |
| `WorkspacePreparationCoordinator.swift` | ~420 | `@MainActor` validator for the Phase 2 validation-gate flow. `validateWorkspaceStateForGuide(_:statusUpdateCallback:)` runs resolve folder → read receiver state → compare against guide → either launch editor + return `.ready(preparedContext:)` or return `.needsUserAction(comparison:)` with a checklist of `WorkspaceMismatchFinding` rows + suggested shell commands the user can copy into their terminal. Owns the `NSOpenPanel` that asks the user to pick their local clone on first run (and re-picks when `GuidedSessionManager.pickDifferentRepoFolderAndRevalidate` forgets the remembered one). Ref precedence for the suggested commands: `commit_sha → branch`, always preceded by `git fetch origin`. Throws typed `WorkspaceValidationError` for catastrophic cases (cancelled picker, picked folder isn't the right repo, git binary missing) so `GuidedSessionManager` can transition to `.workspacePreparationFailed` with the Play-anyway-watch-only fallback. Also exposes `WorkspacePreparationResult` (repo root + opened file URL + non-fatal warnings) for Phase 3 follow-along to reference. |
| `GuidedFollowAlongContextBuilder.swift` | ~210 | Pure-function builder for the Phase 3 follow-along system prompt. `buildFollowAlongSystemPrompt(forGuide:currentStepIndex:preparedWorkspaceResult:)` assembles a guide-aware system message embedding the walkthrough title + author, current step narration (one-based numbered out of total), up to 2 prior step narrations under "PREVIOUSLY COVERED", the next step's narration under "COMING UP NEXT", repo metadata from `GuideContext` (remote URL, branch, commit SHA, workspace name, open path with optional line) when `context.type == .repo`, and — when Phase 2 prep actually ran — the live receiver-side repo root + opened file path from the `WorkspacePreparationResult`. Closes with intent guidance ("where am i?" / "what do i do next?" / "i'm stuck" / "explain this file") and the same speech + target-tag rules as the generic push-to-talk prompt, explicitly constrained to follow-along help (not autonomous coding). Stateless — every invocation returns a fresh string. |
| `MolmoWebClient.swift` | ~300 | Client for the remote MolmoWeb-4B grounding server on Modal. `checkAvailability()` probes `/health`; `groundElement(...)` POSTs `{ screenshot_base64, element_label }` to `/ground` with Bearer auth and parses the raw output via a three-format parser (click-action JSON → legacy `<point>` → plain `x,y`). Returns `CGPoint?` in screenshot pixel space. Shared between push-to-talk pointing and guided-mode step grounding. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled JPEG data + display frame + pixel/point dimensions for each connected display. Used by push-to-talk, guided session auto-advance polling, and guide recording. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Push-to-talk streaming transcription provider. Fetches temp tokens from the Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Alternative upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. Not currently the default (AssemblyAI streaming is). |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. `BuddyPCM16AudioConverter` converts live mic buffers to PCM16 mono. `BuddyWAVFileBuilder.buildWAVData` builds WAV payloads for upload-based providers. Shared between push-to-talk and guide recording. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~150 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. Diagnostic prints on every `flagsChanged` event for debugging TCC permission issues. |
| `OpenAIAPI.swift` | ~550 | Primary vision + chat client. Streaming + non-streaming `analyzeImage(...)` for push-to-talk narration. Plus three guided-mode methods: `checkScreenMatch(live, ref?, condition) -> Bool`, `detectStuck(previous, current, expectedAction) -> Bool`, and `generateGuideStep(screenshot, transcriptChunk, index, total) -> GeneratedGuideStep?` (uses `response_format: json_object` for structured output). |
| `ElevenLabsTTSClient.swift` | ~90 | TTS client. **Class name and file are historical** — the body currently speaks via macOS `AVSpeechSynthesizer` (see the "Why system TTS" architecture note). Public interface (`speakText`, `isPlaying`, `stopPlayback`, `init(proxyURL:)`) is unchanged so `CompanionManager` doesn't know the difference. Revert the `speakText` body to POST the Worker `/tts` route when upgrading to a paid ElevenLabs plan. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~190 | PostHog analytics integration. Push-to-talk, onboarding, permission, and guided-mode events (`trackGuideStarted`, `trackGuideStepCompleted`, `trackGuideStuck`, `trackGuideCompleted`, `trackGuideRecordingStarted`, `trackGuideRecordingStopped`, `trackGuideUploaded`). |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~120 | Runtime configuration reader. Resolves values from process env, the repo-root `.env`, then the bundled `Info.plist`, so local secrets and endpoints no longer need to live in source. |
| `Info.plist` | — | App bundle configuration. Includes `LSUIElement`, permission usage strings, `VoiceTranscriptionProvider` (`assemblyai`), and `CFBundleURLTypes` registering the `clicky` URL scheme for `clicky://guide?id=...` deep links. |
| `worker/src/index.ts` | ~820 | Cloudflare Worker proxy. Eight routes: `/chat` (OpenAI), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI streaming), `/audio/transcribe/submit` + `/audio/transcribe/status/:id` (AssemblyAI batch for guide recording), `/guide/upload` + `/guide/:id` (R2 for guide JSON storage), `/g/:id` (server-rendered light-theme HTML share page — title, author, repo context, transcript preview, `Open in Clicky` button). Share base url resolves from `env.SHARE_BASE_URL` with request-host fallback. |
| `worker/wrangler.toml` | — | Wrangler config. Binds the `clicky-guides` R2 bucket as `GUIDE_BUCKET` and sets `ELEVENLABS_VOICE_ID`. |
| `modal/molmoweb.py` | ~360 | Modal deployment script for MolmoWeb-4B. Uses `AutoModelForImageTextToText` with `trust_remote_code=True`, `torch.float32`, `attn_implementation="sdpa"`. Pins `transformers==4.57.3`. Exposes `/health` (no auth) and `/ground` (Bearer auth) via FastAPI + Modal's `@asgi_app()`. GPU: A10G, scale-to-zero. |
| `modal/test_ground.py` | ~270 | Standalone smoke test for the MolmoWeb deployment. Pure stdlib (urllib). Reads the repo-root `.env` for the Modal URL and bearer key, then runs three sequential tests: `/health`, `/ground` with a 1x1 PNG, `/ground` with a real screenshot. |
| `scripts/sync-worker-dev-vars.sh` | ~30 | Mirrors `OPENAI_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`, and `ELEVENLABS_VOICE_ID` from the repo-root `.env` into `worker/.dev.vars` before local Wrangler runs. |
| `sample.clicky.json` | — | Hand-authored 3-step sample guide (Calculator walkthrough) at the repo root, used to smoke-test playback before recording a real guide. |

## Build & Run

```bash
# Copy the checked-in example and fill in your local values first
cp .env.example .env

# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run.
# For personal dev builds without an Apple Developer account, set
# Signing → Team → None and Signing Certificate → "Sign to Run Locally".

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc. Every Xcode rebuild also sometimes re-flips these permissions — if `🔑 Permissions` log shows `false` after a rebuild, re-toggle in System Settings → Privacy & Security and fully relaunch the app (Cmd+. / Cmd+R).

## Cloudflare Worker

```bash
cd worker
npm install
npm run prepare-dev-env

# One-time: authorize wrangler against your Cloudflare account
npx wrangler login

# One-time: add secrets (interactive prompt — paste each value)
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# One-time: create the R2 bucket via the Cloudflare dashboard
# (Dashboard → R2 → Create bucket → name: "clicky-guides")
# The [[r2_buckets]] binding in wrangler.toml references this by name.

# Deploy (or redeploy after edits)
npx wrangler deploy

# Local dev (writes worker/.dev.vars from the repo-root .env first)
npm run dev:local
```

## Modal deployment (MolmoWeb)

```bash
# One-time setup
pip install modal
modal setup
modal secret create clicky-molmoweb-api-key VLLM_API_KEY=<random hex>

# Deploy (or redeploy after edits)
modal deploy modal/molmoweb.py

# Stop (zero GPU billing — persistent volume keeps the model cached for fast restarts)
modal app stop clicky-molmoweb

# Stream server logs
modal app logs clicky-molmoweb

# Smoke test the running deployment end-to-end
python modal/test_ground.py
```

The historical env var name `VLLM_API_KEY` is kept for continuity with the earlier (failed) vLLM-based deployment — the Swift client reads it as `bearerAPIKey` without knowing about the rename.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
