//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Concern-specific
//  behavior is split into extensions for permissions, onboarding, and the
//  voice response pipeline.
//

import AppKit
import AVFoundation
import Combine
import Foundation

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published var voiceState: CompanionVoiceState = .idle
    @Published var lastTranscript: String?
    @Published var currentAudioPowerLevel: CGFloat = 0
    @Published var hasAccessibilityPermission = false
    @Published var hasScreenRecordingPermission = false
    @Published var hasMicrophonePermission = false
    @Published var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from the AI response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding State

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo = false
    @Published var onboardingVideoOpacity: Double = 0.0
    var onboardingVideoEndObserver: NSObjectProtocol?
    var onboardingDemoTimeObserver: Any?

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt = false

    var onboardingMusicPlayer: AVAudioPlayer?
    var onboardingMusicFadeTimer: Timer?

    // MARK: - Dependencies

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    /// Visual grounding client (MolmoWeb-4B, hosted on Modal).
    /// OpenAI produces an element label describing what to point at; this
    /// client turns the label into pixel coordinates on the live screenshot.
    /// If the Modal endpoint is unreachable or misconfigured, grounding
    /// returns nil and the cursor silently skips pointing.
    // Internal so `GuidedSessionManager` can reuse the grounding client
    // instead of instantiating its own — this also means the /health
    // probe result (and warm connection) are shared across both flows.
    lazy var molmoWebClient: MolmoWebClient = {
        return MolmoWebClient(
            vllmBaseURL: URL(string: Self.molmoWebServerURL)!,
            vllmAPIKey: Self.molmoWebAPIKey
        )
    }()

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    /// Internal so `GuidedSessionManager` can build `/guide/:id` URLs.
    static let workerBaseURL = AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL")
        ?? "https://replace-me.workers.dev"

    /// Modal-hosted endpoint serving MolmoWeb-4B for visual element grounding.
    /// Read from `.env` during local development so it doesn't live in source.
    private static let molmoWebServerURL = AppBundleConfiguration.stringValue(forKey: "MolmoWebServerURL")
        ?? "https://replace-me.modal.run"

    /// Bearer token for the MolmoWeb endpoint. Read from `.env` during local
    /// development instead of being hardcoded into source.
    private static let molmoWebAPIKey = AppBundleConfiguration.stringValue(forKey: "MolmoWebAPIKey") ?? ""

    // Internal (not private) so `GuidedSessionManager` can reach through
    // CompanionManager to share the same vision + TTS client instances
    // instead of spinning up its own duplicates.
    lazy var openAIAPI: OpenAIAPI = {
        return OpenAIAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// Guided walkthrough playback engine. Owns its own @Published
    /// state (step index, progress, current guide) that the menu bar
    /// panel binds to for rendering the progress bar + Stop button.
    /// Lazy so the `self` reference at init time is legal.
    lazy var guidedSessionManager: GuidedSessionManager = {
        return GuidedSessionManager(companionManager: self)
    }()

    /// Recording pipeline for User A-side guide authoring. Captures
    /// mic audio + periodic screenshots while the user narrates a
    /// walkthrough out loud. Stop returns a `GuideRecordingSession`
    /// that we hand off to `guideUploadQueue` for background processing.
    lazy var guideRecorder: GuideRecorder = {
        return GuideRecorder()
    }()

    /// Background processing + R2 upload queue for recorded guides.
    /// Consumes `GuideRecordingSession` values, runs the
    /// transcribe → segment → OpenAI → upload pipeline, and publishes
    /// per-entry status the panel renders as a processing list.
    lazy var guideUploadQueue: GuideUploadQueue = {
        return GuideUploadQueue(companionManager: self)
    }()

    // MARK: - In-Flight Work

    /// Conversation history so OpenAI remembers prior exchanges within a session.
    /// Each entry is the user's transcript and spoken response.
    var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    var currentResponseTask: Task<Void, Never>?

    var shortcutTransitionCancellable: AnyCancellable?
    var voiceStateCancellable: AnyCancellable?
    var audioPowerCancellable: AnyCancellable?
    var accessibilityCheckTimer: Timer?
    var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    var transientHideTask: Task<Void, Never>?

    // MARK: - UI State

    @Published var isRequestingScreenContent = false

    /// True when all four required permissions are granted. Used by the panel
    /// to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published var isOverlayVisible = false

    /// The OpenAI model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedOpenAIModel") ?? "gpt-5.4-mini"

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    // MARK: - User Actions

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedOpenAIModel")
        openAIAPI.model = model
    }

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            showPersistentOverlay()
        } else {
            hideOverlay()
        }
    }

    /// Starts a new recording via `guideRecorder`. Exposed as a
    /// wrapper so the panel's Record button has a single entry point
    /// rather than reaching into the recorder directly.
    func startGuideRecording() {
        do {
            try guideRecorder.startRecording()
        } catch {
            LogGuru.error(
                "Failed to start guide recording: \(error.localizedDescription)",
                category: .guided
            )
        }
    }

    /// Stops the in-flight recording, gives the author a chance to
    /// point at the file they were walking through (for repo-context
    /// capture), then hands the session off to `guideUploadQueue`.
    ///
    /// The file picker step is the v1 author side of the codebase
    /// distribution pipeline (spec §9). If the author picks a file
    /// inside a git repo, `CodebaseContextCaptureService` shells out
    /// to `git` to resolve the remote, branch, commit, repo-relative
    /// path, workspace name, and inferred clone preference — all of
    /// which get stored on the uploaded `ClickyGuide.context` so the
    /// eventual Phase 2 receiver-side workspace-restoration flow has
    /// everything it needs.
    ///
    /// Cancelling the picker is an explicit "upload without repo
    /// context" choice — the recording still uploads, just with the
    /// legacy `type:.url, target:"unknown"` default. This matches the
    /// spec's fallback: "allow guide upload but mark the guide as
    /// playback-only instead of workspace-restorable" (§9).
    func stopGuideRecordingAndEnqueueForProcessing() {
        guard let finishedRecordingSession = guideRecorder.stopRecording() else {
            return
        }

        let capturedResult = promptAuthorForWalkthroughFileAndBuildRepoContext(
            editorBundleIdAtRecordStart: finishedRecordingSession.frontmostApplicationBundleIdentifierAtRecordStart
        )

        guideUploadQueue.enqueueRecordingSession(
            finishedRecordingSession,
            withCapturedGuideContext: capturedResult?.guideContext,
            repoRootURL: capturedResult?.repoRootURL
        )
    }

    /// Shows an `NSOpenPanel` asking the author to pick the file they
    /// were walking through, then resolves the full repo context via
    /// `CodebaseContextCaptureService`. Returns nil when the author
    /// cancels the picker or when the picked file isn't inside a git
    /// repository — both cases are treated as "upload without repo
    /// context" by the caller.
    ///
    /// Runs on the main actor (`runModal` is blocking + main-thread
    /// only). That's fine because the user just hit Stop and is
    /// already looking at the menu bar — a brief modal is natural.
    private func promptAuthorForWalkthroughFileAndBuildRepoContext(
        editorBundleIdAtRecordStart: String?
    ) -> CapturedRepoContextResult? {
        let walkthroughFilePicker = NSOpenPanel()
        walkthroughFilePicker.title = "Pick the file you walked through"
        walkthroughFilePicker.message = "Optional — attach repo context to this walkthrough so receivers can open it in the right repo, branch, and file. Cancel to upload without repo context."
        walkthroughFilePicker.prompt = "Attach"
        walkthroughFilePicker.allowsMultipleSelection = false
        walkthroughFilePicker.canChooseDirectories = false
        walkthroughFilePicker.canChooseFiles = true
        walkthroughFilePicker.resolvesAliases = true
        walkthroughFilePicker.showsHiddenFiles = false

        // Activate the app before running the modal so the panel
        // reliably comes to the front from a menu-bar-only app with
        // no dock icon. `activate(ignoringOtherApps:)` is the
        // canonical dance for LSUIElement apps that occasionally
        // need a foreground window.
        NSApp.activate(ignoringOtherApps: true)

        let modalRunResult = walkthroughFilePicker.runModal()
        guard modalRunResult == .OK, let pickedFileURL = walkthroughFilePicker.url else {
            LogGuru.info(
                "Author skipped walkthrough file picker — guide will upload without repo context",
                category: .guided
            )
            return nil
        }

        let capturedResult = CodebaseContextCaptureService.captureRepoContext(
            forPickedFileURL: pickedFileURL,
            editorBundleId: editorBundleIdAtRecordStart
        )

        if capturedResult == nil {
            LogGuru.warning(
                "Author picked \(pickedFileURL.path) but it's not inside a git repo — saving without repo context",
                category: .guided
            )
        }

        return capturedResult
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func start() {
        refreshAllPermissions()
        LogGuru.info(
            "Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)",
            category: .app
        )
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()

        // Eagerly touch the OpenAI API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = openAIAPI

        // Probe the remote MolmoWeb endpoint in the background so
        // element grounding is ready by the time the first push-to-talk
        // response needs a pixel coordinate. Silently no-ops if the endpoint
        // isn't configured or reachable — the cursor will just skip pointing.
        Task { await molmoWebClient.checkAvailability() }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            showPersistentOverlay()
        }
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        hideOverlay()

        transientHideTask?.cancel()
        transientHideTask = nil
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    // MARK: - Overlay Helpers

    func showPersistentOverlay() {
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func showOnboardingOverlay(resetFirstAppearance: Bool = false) {
        if resetFirstAppearance {
            overlayWindowManager.hasShownOverlayBefore = false
        }
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func hideOverlay() {
        overlayWindowManager.hideOverlay()
        isOverlayVisible = false
    }
}
