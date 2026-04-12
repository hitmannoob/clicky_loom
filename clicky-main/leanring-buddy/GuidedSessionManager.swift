//
//  GuidedSessionManager.swift
//  leanring-buddy
//
//  Playback engine for guided walkthroughs. Takes a `ClickyGuide`
//  (either loaded from a local `.clicky.json` file or fetched from
//  the Cloudflare Worker's `/guide/:id` route) and runs it step by
//  step: speak narration → point at element → wait for advance →
//  next step → completion message.
//
//  Three advance modes from the spec are all implemented:
//
//    .auto   — polls the user's screen every 3s via OpenAI screen
//              matching and advances on YES. Falls back to a "stuck"
//              message after `timeout_seconds`, then keeps polling.
//    .manual — waits for the user to press Ctrl+Option (intercepted
//              by `CompanionManager.handleShortcutPressedTransition`).
//    .timed  — waits a short fixed delay after TTS finishes.
//
//  Element grounding during playback reuses the existing
//  `MolmoWebClient.groundElement` pathway — same one the push-to-talk
//  flow uses. If MolmoWeb is unavailable (Modal stopped, /health fail)
//  the cursor-fly step is silently skipped. The session still plays.
//
//  Dependencies are reached through a `weak` reference to
//  `CompanionManager` rather than dependency-injected at init time,
//  which keeps the wiring simple in exchange for a few `guard let`
//  chains. CompanionManager creates this via a `lazy var` so the
//  self-reference isn't a problem.
//

import AppKit
import Combine
import Foundation

// MARK: - State

/// Publicly-observable session state. The menu bar panel binds to
/// this via `@ObservedObject` to show the progress bar, Stop button,
/// and per-state messaging.
enum GuidedSessionState: Equatable {
    /// No guide loaded / session not running.
    case idle
    /// Fetching a guide from the network (`loadGuide(fromRemoteID:)`).
    case loadingGuide
    /// Guide loaded, awaiting `startPlayback()`.
    case ready
    /// Phase 2 workspace validation is in flight. The associated
    /// `currentPhaseDescription` is a short string like "Finding
    /// your local clone…" / "Reading repo state…" / "Opening your
    /// editor…" that `WorkspacePreparationCoordinator` pushes up
    /// through its status callback. Only reachable for guides whose
    /// `context.type == .repo`.
    case preparingWorkspace(currentPhaseDescription: String)
    /// Phase 2 validation found mismatches between the receiver's
    /// current git state and the author's recorded state. The panel
    /// surfaces the comparison as a checklist with copy-pasteable
    /// shell commands and a Retry button. The user runs the
    /// commands in their own terminal (Clicky never writes to git
    /// anymore) and hits Retry, which re-runs validation.
    case awaitingWorkspaceMatch(comparison: WorkspaceStateComparison)
    /// Phase 2 workspace prep failed for a reason the user can't
    /// fix via shell commands (folder picker cancelled, git binary
    /// missing, picked folder isn't the right repo after retrying,
    /// etc.). The panel surfaces `failureReason` plus a "Play anyway
    /// (watch only)" button that transitions directly to playback
    /// via `playbackInWatchOnlyMode()`.
    case workspacePreparationFailed(failureReason: String, warningMessages: [String])
    /// Narration is being spoken for the step at `stepIndex`.
    case speakingNarration(stepIndex: Int)
    /// Narration finished, waiting for the advance trigger (auto poll,
    /// manual press, or timed delay) for step at `stepIndex`.
    case waitingToAdvance(stepIndex: Int, mode: StepAdvance.AdvanceMode)
    /// Auto-advance timeout fired for `stepIndex` — spoken the stuck
    /// hint and still polling for the condition.
    case stuckOnStep(stepIndex: Int)
    /// All steps complete; completion narration (if any) is playing.
    case completing
    /// Completion narration finished — session is done.
    case completed
    /// Fatal error during load / playback. UI surfaces the message.
    case failed(reason: String)
}

// MARK: - Manager

@MainActor
final class GuidedSessionManager: ObservableObject {
    // MARK: Published state

    @Published private(set) var state: GuidedSessionState = .idle
    @Published private(set) var currentGuide: ClickyGuide?
    @Published private(set) var currentStepIndex: Int = 0
    /// 0.0 to 1.0 based on `currentStepIndex / steps.count`.
    @Published private(set) var progressFraction: Double = 0

    /// Result of the Phase 2 workspace preparation, stored so the
    /// Phase 3 follow-along prompt builder can reference the real
    /// receiver-side repo root and opened file URL (not just the
    /// author-time metadata baked into `currentGuide.context`).
    /// Set by `runWorkspacePreparationThenStartPlayback` on success,
    /// cleared by `stopPlayback` and the watch-only fallback. Nil
    /// for non-repo guides.
    private var preparedWorkspaceResult: WorkspacePreparationResult?

    // MARK: Private

    /// Weak back-reference so we can share the same OpenAI, MolmoWeb,
    /// and TTS client instances the rest of the app uses. Weak because
    /// CompanionManager owns this object — strong would create a cycle.
    private weak var companionManager: CompanionManager?

    /// The long-running Task that drives the current step from
    /// narration through advance. Cancelled when the user hits Stop
    /// or when a new step is played.
    private var currentStepTask: Task<Void, Never>?

    /// Continuation used to unblock `.manual` advance waits when the
    /// user presses Ctrl+Option. Resumed by `advanceManually()` (called
    /// from CompanionManager's shortcut handler) and on Stop.
    private var manualAdvanceContinuation: CheckedContinuation<Void, Never>?

    /// Screenshot captured just before the current step started polling.
    /// Used by stuck detection to compare "where the user was when they
    /// landed on this step" vs. "where they are now".
    private var lastStuckReferenceScreenshot: Data?

    // MARK: Init

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    // MARK: - Loading

    /// Loads a guide from a local `.clicky.json` file on disk. Used
    /// by the "Load Guide" button in the menu bar panel for testing
    /// without round-tripping through R2.
    func loadGuide(fromLocalFileURL localFileURL: URL) throws {
        let rawJsonData = try Data(contentsOf: localFileURL)
        let decodedGuide = try ClickyGuide.decode(from: rawJsonData)
        installLoadedGuide(decodedGuide)
        LogGuru.notice(
            "Guide loaded from local file: \(decodedGuide.title) (\(decodedGuide.steps.count) steps)",
            category: .guided,
            privacy: .private
        )
    }

    /// Fetches a guide from the Worker's `/guide/:id` route and loads
    /// it into this session. This is the path used when a
    /// `clicky://guide?id=...` deep link is opened.
    func loadGuide(fromRemoteID remoteGuideID: String) async throws {
        state = .loadingGuide

        let fetchURLString = "\(CompanionManager.workerBaseURL)/guide/\(remoteGuideID)"
        guard let fetchURL = URL(string: fetchURLString) else {
            state = .failed(reason: "invalid remote guide URL")
            throw NSError(
                domain: "GuidedSessionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "invalid remote guide URL: \(fetchURLString)"]
            )
        }

        LogGuru.info(
            "Fetching guide from \(fetchURLString)",
            category: .guided,
            privacy: .private
        )

        do {
            let (rawJsonData, httpResponse) = try await URLSession.shared.data(from: fetchURL)
            guard let httpResponseCast = httpResponse as? HTTPURLResponse,
                  (200...299).contains(httpResponseCast.statusCode) else {
                let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? -1
                let responseBodyText = String(data: rawJsonData, encoding: .utf8) ?? "<unreadable>"
                let errorMessage = "guide fetch failed — HTTP \(statusCode): \(responseBodyText.prefix(200))"
                state = .failed(reason: errorMessage)
                LogGuru.error(
                    errorMessage,
                    category: .guided,
                    privacy: .private
                )
                throw NSError(domain: "GuidedSessionManager", code: statusCode,
                              userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }

            let decodedGuide = try ClickyGuide.decode(from: rawJsonData)
            installLoadedGuide(decodedGuide)
            LogGuru.notice(
                "Guide loaded from remote: \(decodedGuide.title) (\(decodedGuide.steps.count) steps)",
                category: .guided,
                privacy: .private
            )
        } catch {
            if case .failed = state {
                // already set above, don't overwrite with a generic message
            } else {
                state = .failed(reason: error.localizedDescription)
            }
            throw error
        }
    }

    /// Shared post-decode setup for both local and remote loads.
    /// Resets step index, recomputes progress, moves state to `.ready`.
    private func installLoadedGuide(_ newGuide: ClickyGuide) {
        currentGuide = newGuide
        currentStepIndex = 0
        updateProgressFraction()
        state = .ready
    }

    // MARK: - Playback control

    /// Starts playing the loaded guide from step 0.
    ///
    /// For guides whose `context.type == .repo` (Phase 2), this first
    /// runs `WorkspacePreparationCoordinator` to resolve-or-clone the
    /// repo, check out the target revision, and open the editor on
    /// the right file. Only after prep succeeds does playback
    /// actually begin. For non-repo guides (Phase 1 and earlier),
    /// playback starts immediately — same as before.
    ///
    /// If prep fails or the user cancels at an interactive step, the
    /// session transitions to `.workspacePreparationFailed` and the
    /// panel surfaces a "Play anyway (watch only)" button which
    /// invokes `playbackInWatchOnlyMode()`.
    func startPlayback() {
        guard let guideBeingPlayed = currentGuide else {
            LogGuru.warning(
                "Guided session startPlayback was called with no guide loaded",
                category: .guided
            )
            return
        }
        guard !guideBeingPlayed.steps.isEmpty else {
            LogGuru.warning(
                "Guided session guide \"\(guideBeingPlayed.title)\" has no steps",
                category: .guided,
                privacy: .private
            )
            completeSession()
            return
        }

        if guideBeingPlayed.context.type == .repo {
            Task { [weak self] in
                await self?.runWorkspacePreparationThenStartPlayback(
                    forGuide: guideBeingPlayed
                )
            }
            return
        }

        beginNarratingFromFirstStep(forGuide: guideBeingPlayed)
    }

    /// Fallback entry point used by the "Play anyway (watch only)"
    /// button in the panel. Skips all workspace restoration and
    /// jumps straight into the existing playback flow, which still
    /// works because reference screenshots and narrations are
    /// embedded in the guide JSON — no repo access required.
    ///
    /// Callable from two states:
    ///   - `.awaitingWorkspaceMatch` — user chose to ignore the
    ///     mismatch and watch anyway
    ///   - `.workspacePreparationFailed` — catastrophic validation
    ///     failure (cancelled folder picker, git missing, etc.)
    func playbackInWatchOnlyMode() {
        let isValidFallbackState: Bool = {
            switch state {
            case .awaitingWorkspaceMatch, .workspacePreparationFailed:
                return true
            default:
                return false
            }
        }()

        guard isValidFallbackState else {
            LogGuru.warning(
                "Guided session playbackInWatchOnlyMode called from unexpected state \(String(describing: state))",
                category: .guided
            )
            return
        }
        guard let guideBeingPlayed = currentGuide else { return }
        LogGuru.notice(
            "Guided session falling back to watch-only playback for guide \(guideBeingPlayed.id)",
            category: .guided,
            privacy: .private
        )
        beginNarratingFromFirstStep(forGuide: guideBeingPlayed)
    }

    /// Runs the Phase 2 validation-gate flow. Transitions to one of
    /// three outcomes:
    ///
    ///   1. `.ready` → stashes the prepared context for Phase 3
    ///      follow-along and jumps into `beginNarratingFromFirstStep`
    ///   2. `.needsUserAction` → parks in `.awaitingWorkspaceMatch`
    ///      with the comparison, waiting for the user to run the
    ///      suggested shell commands and hit Retry
    ///   3. Throw (catastrophic) → `.workspacePreparationFailed` with
    ///      the reason text, showing the Play-anyway-watch-only button
    ///
    /// Isolated as its own async helper so the sync `startPlayback`
    /// entry point can fire it off without returning a Task.
    private func runWorkspacePreparationThenStartPlayback(
        forGuide guideBeingPrepared: ClickyGuide
    ) async {
        state = .preparingWorkspace(currentPhaseDescription: "Preparing workspace…")

        do {
            let validationOutcome = try await WorkspacePreparationCoordinator.validateWorkspaceStateForGuide(
                guideBeingPrepared,
                statusUpdateCallback: { [weak self] statusDescription in
                    self?.state = .preparingWorkspace(currentPhaseDescription: statusDescription)
                }
            )

            switch validationOutcome {
            case .ready(let preparedContext):
                for warningMessage in preparedContext.nonFatalWarningMessages {
                    LogGuru.notice(
                        "Workspace prep warning: \(warningMessage)",
                        category: .guided,
                        privacy: .private
                    )
                }
                LogGuru.notice(
                    "Workspace validation succeeded — repoRoot=\(preparedContext.repoRootURL.path), openedFile=\(preparedContext.openedFileURL?.path ?? "<none>")",
                    category: .guided,
                    privacy: .private
                )
                // Stash for Phase 3: the follow-along prompt builder
                // reads this to surface the real receiver-side repo
                // root and opened file path to the assistant.
                preparedWorkspaceResult = preparedContext
                beginNarratingFromFirstStep(forGuide: guideBeingPrepared)

            case .needsUserAction(let comparison):
                LogGuru.info(
                    "Workspace validation needs user action — \(comparison.findings.count) findings, \(comparison.suggestedShellCommands.count) suggested commands",
                    category: .guided,
                    privacy: .private
                )
                state = .awaitingWorkspaceMatch(comparison: comparison)
            }
        } catch {
            LogGuru.error(
                "Workspace validation failed: \(error.localizedDescription)",
                category: .guided,
                privacy: .private
            )
            state = .workspacePreparationFailed(
                failureReason: error.localizedDescription,
                warningMessages: []
            )
        }
    }

    /// Re-runs workspace validation from the `.awaitingWorkspaceMatch`
    /// state. Called by the panel's Retry button after the user has
    /// run the suggested shell commands in their own terminal.
    func retryWorkspaceValidation() {
        guard case .awaitingWorkspaceMatch = state else {
            LogGuru.warning(
                "retryWorkspaceValidation called from unexpected state \(String(describing: state))",
                category: .guided
            )
            return
        }
        guard let guideBeingPlayed = currentGuide else { return }
        Task { [weak self] in
            await self?.runWorkspacePreparationThenStartPlayback(
                forGuide: guideBeingPlayed
            )
        }
    }

    /// Forgets the remembered folder for the current guide's repo
    /// and re-runs validation, which re-prompts the user via
    /// NSOpenPanel. Called by the "Pick different folder" button in
    /// the mismatch UI when the user realizes they pointed Clicky
    /// at the wrong clone.
    func pickDifferentRepoFolderAndRevalidate() {
        guard case .awaitingWorkspaceMatch = state else {
            LogGuru.warning(
                "pickDifferentRepoFolderAndRevalidate called from unexpected state \(String(describing: state))",
                category: .guided
            )
            return
        }
        guard let guideBeingPlayed = currentGuide else { return }
        RepoWorkspaceResolver.forgetRepoFolderURL(forGuideContext: guideBeingPlayed.context)
        Task { [weak self] in
            await self?.runWorkspacePreparationThenStartPlayback(
                forGuide: guideBeingPlayed
            )
        }
    }

    /// Shared entry into the first-step narration loop. Used by both
    /// the "normal" startPlayback flow (after prep) and the
    /// watch-only fallback, so both paths reset the same state in
    /// the same way.
    private func beginNarratingFromFirstStep(forGuide guideBeingPlayed: ClickyGuide) {
        currentStepIndex = 0
        updateProgressFraction()

        ClickyAnalytics.trackGuideStarted(guideID: guideBeingPlayed.id)
        playStep(at: 0)
    }

    /// Cancels everything in flight and resets to `.idle` (without
    /// clearing `currentGuide`, so the user can press Play again).
    func stopPlayback() {
        currentStepTask?.cancel()
        currentStepTask = nil
        // Resume any pending manual-advance continuation so its async
        // wait point unblocks and the current step task can exit its
        // cancellation check cleanly.
        manualAdvanceContinuation?.resume()
        manualAdvanceContinuation = nil

        // Stop TTS playback too — otherwise the system voice keeps
        // narrating into the void after the user bailed.
        companionManager?.elevenLabsTTSClient.stopPlayback()

        // Clear any cursor pointing state so the blue cursor doesn't
        // stay frozen at the last target.
        companionManager?.detectedElementScreenLocation = nil
        companionManager?.detectedElementDisplayFrame = nil

        // Drop the Phase 2 workspace prep result so a subsequent
        // playback starts from a clean slate. The actual cloned
        // repo stays on disk — this only clears our in-memory
        // pointer to it.
        preparedWorkspaceResult = nil

        state = .idle
    }

    // MARK: - Phase 3 follow-along hooks

    /// True when the current session is in a state where the user
    /// can ask the follow-along assistant a question via push-to-talk.
    /// False when idle, loading, preparing workspace, failed, or
    /// already completed — in those states Ctrl+Option either
    /// controls nothing or does its normal push-to-talk job.
    var isGuidedFollowAlongAvailable: Bool {
        switch state {
        case .speakingNarration, .waitingToAdvance, .stuckOnStep, .completing:
            return true
        case .idle, .loadingGuide, .ready, .preparingWorkspace,
             .awaitingWorkspaceMatch, .workspacePreparationFailed,
             .completed, .failed:
            return false
        }
    }

    /// Returns the fully-baked follow-along system prompt for the
    /// current step, or nil when `isGuidedFollowAlongAvailable` is
    /// false. `CompanionManager.sendTranscriptToOpenAIWithScreenshot`
    /// calls this at the top of its transcript-handling pipeline —
    /// non-nil means "use this prompt instead of the generic
    /// push-to-talk system prompt, and skip the shared conversation
    /// history so guided Q&A doesn't pollute push-to-talk memory."
    func currentGuidedFollowAlongSystemPrompt() -> String? {
        guard isGuidedFollowAlongAvailable else { return nil }
        guard let guideBeingPlayed = currentGuide else { return nil }
        return GuidedFollowAlongContextBuilder.buildFollowAlongSystemPrompt(
            forGuide: guideBeingPlayed,
            currentStepIndex: currentStepIndex,
            preparedWorkspaceResult: preparedWorkspaceResult
        )
    }

    /// Advance from a `.manual` wait. Called by
    /// `CompanionManager.handleShortcutPressedTransition` when a guide
    /// is active in `.waitingToAdvance(_, .manual)` — push-to-talk is
    /// re-routed as "next step".
    func advanceManually() {
        guard case let .waitingToAdvance(_, currentMode) = state, currentMode == .manual else {
            return
        }
        LogGuru.info("Manual guide advance triggered", category: .guided)
        manualAdvanceContinuation?.resume()
        manualAdvanceContinuation = nil
    }

    /// True when the push-to-talk shortcut should be intercepted as
    /// a manual advance instead of starting a recording. Checked by
    /// CompanionManager before kicking off a dictation session.
    var shouldInterceptPushToTalkForManualAdvance: Bool {
        if case let .waitingToAdvance(_, currentMode) = state, currentMode == .manual {
            return true
        }
        return false
    }

    // MARK: - Step execution

    /// Starts the long-running Task that drives one step from narration
    /// through advance. Cancels any previously-running step Task first.
    private func playStep(at stepIndexToPlay: Int) {
        guard let guideBeingPlayed = currentGuide,
              stepIndexToPlay < guideBeingPlayed.steps.count else {
            completeSession()
            return
        }

        currentStepIndex = stepIndexToPlay
        updateProgressFraction()

        let stepToPlay = guideBeingPlayed.steps[stepIndexToPlay]

        currentStepTask?.cancel()
        currentStepTask = Task { [weak self] in
            guard let self else { return }

            // 1. Speak the narration first.
            self.state = .speakingNarration(stepIndex: stepIndexToPlay)
            await self.speakNarration(for: stepToPlay)
            guard !Task.isCancelled else { return }

            // 2. Fly the cursor to the step's target element (if any).
            if stepToPlay.point != nil {
                await self.groundAndPointAtElement(for: stepToPlay)
            }
            guard !Task.isCancelled else { return }

            // 3. Wait for the advance trigger — implementation depends
            //    on the step's advance mode.
            self.state = .waitingToAdvance(stepIndex: stepIndexToPlay, mode: stepToPlay.advance.mode)

            switch stepToPlay.advance.mode {
            case .auto:
                await self.waitForAutoAdvance(forStep: stepToPlay)
            case .manual:
                await self.waitForManualAdvance()
            case .timed:
                await self.waitForTimedAdvance()
            }

            guard !Task.isCancelled else { return }

            // 4. Done with this step — move on.
            ClickyAnalytics.trackGuideStepCompleted(
                guideID: guideBeingPlayed.id,
                stepID: stepToPlay.id
            )
            self.advanceToNextStep()
        }
    }

    // MARK: - Step actions

    /// Speaks the step's narration via the (system) TTS client and
    /// blocks until playback actually begins. The caller then moves on
    /// to the pointing phase — cursor movement can overlap with the
    /// rest of the speech, which feels more natural than serializing
    /// "finish speaking, THEN move".
    private func speakNarration(for stepBeingNarrated: GuideStep) async {
        guard let ttsClient = companionManager?.elevenLabsTTSClient else { return }
        do {
            try await ttsClient.speakText(stepBeingNarrated.narration)
        } catch {
            LogGuru.error(
                "Guided session TTS error: \(error.localizedDescription)",
                category: .guided
            )
        }
    }

    /// Asks MolmoWeb to find the element labelled by the step's
    /// `point.label` on the user's current screen, scales the result
    /// into AppKit coordinates, and sets
    /// `companionManager.detectedElementScreenLocation` to trigger the
    /// overlay's cursor-fly animation.
    ///
    /// If MolmoWeb is unavailable or grounding fails this silently
    /// returns without setting anything — the session still plays, it
    /// just doesn't visually point.
    private func groundAndPointAtElement(for stepBeingPointed: GuideStep) async {
        guard let companion = companionManager,
              let pointHint = stepBeingPointed.point else { return }

        do {
            let capturedScreens = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let cursorScreenCapture = capturedScreens.first(where: { $0.isCursorScreen }) else {
                LogGuru.warning(
                    "Guided session could not find the cursor screen for grounding",
                    category: .vision
                )
                return
            }

            guard companion.molmoWebClient.isAvailable else {
                LogGuru.notice(
                    "MolmoWeb unavailable; skipping guided cursor pointing for step \(stepBeingPointed.id)",
                    category: .vision,
                    privacy: .private
                )
                return
            }

            guard let groundedScreenshotCoordinate = await companion.molmoWebClient.groundElement(
                screenshotData: cursorScreenCapture.imageData,
                elementLabel: pointHint.label,
                screenshotWidthInPixels: cursorScreenCapture.screenshotWidthInPixels,
                screenshotHeightInPixels: cursorScreenCapture.screenshotHeightInPixels
            ) else {
                LogGuru.warning(
                    "MolmoWeb could not ground guided target \"\(pointHint.label)\" on step \(stepBeingPointed.id)",
                    category: .vision,
                    privacy: .private
                )
                return
            }

            // Scale screenshot-pixel coordinates into display-local
            // point coordinates (top-left origin), then flip to
            // bottom-left-origin AppKit coords, then offset by the
            // display's global origin so the overlay's
            // `detectedElementScreenLocation` expects the cursor fly
            // target in global AppKit space.
            let screenshotPixelWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
            let screenshotPixelHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
            let displayPointWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
            let displayPointHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
            let displayFrameInGlobalCoords = cursorScreenCapture.displayFrame

            let clampedScreenshotX = max(0, min(groundedScreenshotCoordinate.x, screenshotPixelWidth))
            let clampedScreenshotY = max(0, min(groundedScreenshotCoordinate.y, screenshotPixelHeight))

            let displayLocalPointX = clampedScreenshotX * (displayPointWidth / screenshotPixelWidth)
            let displayLocalPointYFromTop = clampedScreenshotY * (displayPointHeight / screenshotPixelHeight)
            let displayLocalPointYFromBottom = displayPointHeight - displayLocalPointYFromTop

            let globalScreenLocation = CGPoint(
                x: displayLocalPointX + displayFrameInGlobalCoords.origin.x,
                y: displayLocalPointYFromBottom + displayFrameInGlobalCoords.origin.y
            )

            companion.detectedElementScreenLocation = globalScreenLocation
            companion.detectedElementDisplayFrame = displayFrameInGlobalCoords
            LogGuru.info(
                "Guided session pointing at \"\(pointHint.label)\" → (\(Int(globalScreenLocation.x)), \(Int(globalScreenLocation.y)))",
                category: .vision,
                privacy: .private
            )
        } catch {
            LogGuru.error(
                "Guided session grounding error: \(error.localizedDescription)",
                category: .vision
            )
        }
    }

    // MARK: - Advance waits

    /// Polls the user's screen every 3 seconds via OpenAI screen
    /// matching. Returns when either (a) a YES response is received,
    /// (b) the task is cancelled, or (c) we decide to give up after a
    /// prolonged stuck state. Stuck state is entered once after
    /// `timeout_seconds`, the `stuck_hint` is spoken, and polling
    /// continues — we don't auto-fail the step, just nudge the user.
    private func waitForAutoAdvance(forStep stepBeingPolled: GuideStep) async {
        guard let companion = companionManager else { return }

        let pollIntervalNanoseconds: UInt64 = 3 * 1_000_000_000
        let stuckTimeoutSeconds = stepBeingPolled.advance.timeoutSeconds ?? 60
        let pollingStartDate = Date()
        var didSpeakStuckHint = false

        // Capture a reference screenshot at the very start of polling
        // so stuck detection can compare against it later.
        if let initialScreens = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(),
           let initialCursorScreen = initialScreens.first(where: { $0.isCursorScreen }) {
            lastStuckReferenceScreenshot = initialCursorScreen.imageData
        }

        LogGuru.debug(
            "Auto-advance polling started for step \(stepBeingPolled.id), timeout \(stuckTimeoutSeconds)s",
            category: .guided,
            privacy: .private
        )

        while !Task.isCancelled {
            // Perform one check. Any thrown error inside
            // `performSingleScreenCheck` is swallowed and returns false
            // so we just keep polling.
            let didConditionMatch = await performSingleScreenCheck(for: stepBeingPolled)
            guard !Task.isCancelled else { return }

            if didConditionMatch {
                LogGuru.info(
                    "Auto-advance matched for step \(stepBeingPolled.id)",
                    category: .guided,
                    privacy: .private
                )
                return
            }

            // Check if we should enter the stuck state.
            let elapsedSinceStart = Date().timeIntervalSince(pollingStartDate)
            if !didSpeakStuckHint && elapsedSinceStart >= Double(stuckTimeoutSeconds) {
                didSpeakStuckHint = true
                await runStuckHandling(for: stepBeingPolled)
                guard !Task.isCancelled else { return }
            }

            // Wait before the next poll. Use Task.sleep which
            // respects cancellation so Stop interrupts promptly.
            do {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } catch {
                return // cancelled
            }
        }

        // Small hush to satisfy the unused-variable compiler hint for
        // `companion` — we capture it at the top for clarity even
        // though individual calls reach through `companionManager`
        // again on each iteration.
        _ = companion
    }

    /// One iteration of the auto-advance polling loop. Captures the
    /// user's cursor screen, resolves the step's reference screenshot
    /// (if any), and asks OpenAI whether the advance condition is met.
    private func performSingleScreenCheck(for stepBeingChecked: GuideStep) async -> Bool {
        guard let companion = companionManager else { return false }
        guard let advanceConditionText = stepBeingChecked.advance.condition else {
            // No condition means nothing to match against — treat as
            // "done immediately". This shouldn't happen for .auto
            // steps in well-formed guides, but we degrade safely.
            return true
        }

        do {
            let capturedScreens = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let cursorScreenCapture = capturedScreens.first(where: { $0.isCursorScreen }) else {
                return false
            }

            let referenceScreenshotData = resolveReferenceScreenshotData(for: stepBeingChecked)

            return await companion.openAIAPI.checkScreenMatch(
                liveScreenshotData: cursorScreenCapture.imageData,
                referenceScreenshotData: referenceScreenshotData,
                advanceCondition: advanceConditionText
            )
        } catch {
            LogGuru.error(
                "Guided session screen capture failed: \(error.localizedDescription)",
                category: .guided
            )
            return false
        }
    }

    /// Suspends until `advanceManually()` resumes the stored
    /// continuation — or until the step task is cancelled, in which
    /// case `stopPlayback` resumes it with a no-op and the next
    /// cancellation check inside `playStep` exits the loop.
    private func waitForManualAdvance() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            manualAdvanceContinuation = continuation
        }
    }

    /// Timed advance — just waits a fixed duration after narration
    /// for the user to visually absorb the step before moving on.
    private func waitForTimedAdvance() async {
        let timedAdvanceDelayNanoseconds: UInt64 = 2_000_000_000 // 2 seconds
        try? await Task.sleep(nanoseconds: timedAdvanceDelayNanoseconds)
    }

    // MARK: - Stuck handling

    /// Handles the stuck condition for an auto-advance step: transitions
    /// state, captures a fresh screenshot, runs OpenAI stuck detection
    /// against the earlier reference screenshot (for logging only), and
    /// speaks the configured `stuck_hint`. Returns once TTS has started
    /// so the auto-advance loop can resume polling.
    private func runStuckHandling(for stepBeingStuckOn: GuideStep) async {
        state = .stuckOnStep(stepIndex: currentStepIndex)
        ClickyAnalytics.trackGuideStuck(
            guideID: currentGuide?.id ?? "unknown",
            stepID: stepBeingStuckOn.id
        )

        // Run a stuck detection check — purely for logging so we can
        // see in the console whether the model agrees the user is
        // stuck. The result does NOT gate whether we speak the hint;
        // we always speak the hint when the timeout fires.
        if let earlierScreenshotData = lastStuckReferenceScreenshot,
           let companion = companionManager,
           let expectedActionDescription = stepBeingStuckOn.advance.condition,
           let capturedScreens = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(),
           let currentCursorScreen = capturedScreens.first(where: { $0.isCursorScreen }) {
            _ = await companion.openAIAPI.detectStuck(
                previousScreenshotData: earlierScreenshotData,
                currentScreenshotData: currentCursorScreen.imageData,
                expectedActionDescription: expectedActionDescription
            )
        }

        guard let stuckHintText = stepBeingStuckOn.advance.stuckHint,
              !stuckHintText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            LogGuru.debug(
                "Guided session stuck timeout fired but no stuck hint was defined",
                category: .guided
            )
            return
        }

        LogGuru.notice(
            "Speaking stuck hint for step \(stepBeingStuckOn.id): \(stuckHintText)",
            category: .guided,
            privacy: .private
        )
        await speakArbitraryText(stuckHintText)
    }

    // MARK: - Navigation

    private func advanceToNextStep() {
        let nextStepIndex = currentStepIndex + 1
        guard let guideBeingPlayed = currentGuide,
              nextStepIndex < guideBeingPlayed.steps.count else {
            completeSession()
            return
        }
        playStep(at: nextStepIndex)
    }

    private func completeSession() {
        guard let completedGuide = currentGuide else {
            state = .idle
            return
        }

        state = .completing

        // Speak the completion narration if there is one, then land
        // on `.completed`. Fire and forget — we don't need the caller
        // to await this.
        Task { [weak self] in
            if let completionNarration = completedGuide.completion?.narration,
               !completionNarration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await self?.speakArbitraryText(completionNarration)
            }
            guard let strongSelf = self else { return }
            strongSelf.state = .completed
            strongSelf.progressFraction = 1.0
            ClickyAnalytics.trackGuideCompleted(guideID: completedGuide.id)
            LogGuru.notice(
                "Guide complete: \(completedGuide.title)",
                category: .guided,
                privacy: .private
            )
        }
    }

    // MARK: - Helpers

    /// Resolves the reference screenshot bytes for a step, checking
    /// the inline base64 field first (R2-hosted guides) and falling
    /// back to the relative path (local sidecar guides). Returns nil
    /// if neither is set or the path can't be read.
    private func resolveReferenceScreenshotData(for stepBeingResolved: GuideStep) -> Data? {
        if let inlineBase64Text = stepBeingResolved.refImageBase64,
           let decodedBytes = Data(base64Encoded: inlineBase64Text) {
            return decodedBytes
        }
        if let relativeImagePath = stepBeingResolved.refImage {
            let candidateFileURL = URL(fileURLWithPath: relativeImagePath)
            if let fileBytes = try? Data(contentsOf: candidateFileURL) {
                return fileBytes
            }
        }
        return nil
    }

    /// Speaks an arbitrary string via the system TTS client. Used for
    /// the stuck hint and completion narration — i.e. anything that
    /// isn't one of the step's own `narration` strings.
    private func speakArbitraryText(_ textToSpeak: String) async {
        guard let ttsClient = companionManager?.elevenLabsTTSClient else { return }
        do {
            try await ttsClient.speakText(textToSpeak)
        } catch {
            LogGuru.error(
                "Guided session speakArbitraryText error: \(error.localizedDescription)",
                category: .guided
            )
        }
    }

    private func updateProgressFraction() {
        guard let guideBeingPlayed = currentGuide, !guideBeingPlayed.steps.isEmpty else {
            progressFraction = 0
            return
        }
        progressFraction = Double(currentStepIndex) / Double(guideBeingPlayed.steps.count)
    }
}
