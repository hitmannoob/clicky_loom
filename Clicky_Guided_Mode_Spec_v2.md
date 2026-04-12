# Clicky guided mode — technical spec

> **v2 — updated with MolmoWeb integration**
> Local MolmoWeb 4B handles all fast, repetitive vision tasks (screen
> matching, element grounding, advance checks). Claude is only called
> once per step for narration generation. ~95% API cost reduction.

## 1. Guide file schema

### Location conventions

```
# For repos — auto-detected on clone/open
.clicky/
  guides/
    onboarding.clicky.json
    ci-setup.clicky.json
    assets/
      step1.jpg
      step2.jpg

# For standalone docs — sidecar file
README.md
README.clicky.json

# For remote docs (Google Docs, Notion) — hosted payload
https://api.clicky.dev/guides/{script_id}
```

### Schema: `*.clicky.json`

```jsonc
{
  "version": "1.0",
  "id": "guide_abc123",
  "title": "Setting up CI/CD in GitHub Actions",
  "author": {
    "name": "Rakesh",
    "email": "rakesh@company.com"
  },
  "created_at": "2026-04-11T10:30:00Z",
  "context": {
    // What should be open when this guide plays
    "type": "repo",                    // "repo" | "url" | "file" | "app"
    "target": "github.com/org/repo",   // repo URL, doc URL, file path, or app bundle ID
    "branch": "main",                  // optional: specific branch
    "open_path": "src/config.ts"       // optional: specific file to open first
  },
  "voice": {
    "provider": "elevenlabs",          // "elevenlabs" | "system"
    "voice_id": "pNInz6obpgDQGcFmaJgB" // optional: specific voice clone
  },
  "steps": [
    {
      "id": "step_1",
      "narration": "first, open your repo settings — you'll see it in the top nav bar",
      "ref_image": "assets/step1.jpg",
      "point": {
        "x": 850,
        "y": 42,
        "label": "settings tab",
        "screen": 1
      },
      "advance": {
        "mode": "auto",                // "auto" | "manual" | "timed"
        "condition": "settings page is visible",
        "timeout_seconds": 30,         // fallback: prompt user if stuck
        "stuck_hint": "look for the gear icon in the top navigation bar"
      }
    },
    {
      "id": "step_2",
      "narration": "scroll down to actions in the left sidebar and click general",
      "ref_image": "assets/step2.jpg",
      "point": {
        "x": 180,
        "y": 340,
        "label": "actions menu"
      },
      "advance": {
        "mode": "auto",
        "condition": "actions general settings page visible",
        "timeout_seconds": 20
      }
    },
    {
      "id": "step_3",
      "narration": "enable workflow permissions — select read and write, then hit save",
      "ref_image": "assets/step3.jpg",
      "point": {
        "x": 620,
        "y": 580,
        "label": "read and write radio"
      },
      "advance": {
        "mode": "manual",
        "condition": "permissions saved confirmation toast visible"
      }
    }
  ],
  "completion": {
    "narration": "nice, you're all set — your repo now has CI/CD configured",
    "action": null                     // optional: "open_url", "run_command"
  }
}
```

### Key design decisions

**`ref_image` is the anchor.** Each step stores a screenshot from User A's recording. During playback, Claude receives both the ref image and User B's live screenshot, and determines whether User B has reached the right state. The `condition` field is a natural language hint that helps Claude decide — it's not a programmatic check.

**`point` coordinates are from User A's recording.** They won't match User B's screen exactly (different resolution, window position, etc.). During playback, Claude re-localizes the element by looking at User B's live screenshot and finding the equivalent UI element. The ref `point` is a hint, not a hard coordinate.

**`advance.mode` controls pacing:**
- `auto` — Clicky continuously screenshots User B (every 2-3s) and advances when Claude confirms the condition is met
- `manual` — User B presses Ctrl+Option or clicks "Next" to advance
- `timed` — advances after TTS finishes + a fixed delay (for info-only steps)


---

## 2. Deep link scheme

### URL format

```
clicky://guide?id={script_id}&source={source_type}&target={encoded_target}
```

Examples:
```
# GitHub repo with guide
clicky://guide?id=onboarding&source=repo&target=github.com/org/repo

# Google Doc with hosted guide
clicky://guide?id=guide_abc123&source=url&target=https://docs.google.com/d/xyz

# Local file with sidecar
clicky://guide?source=file&target=/Users/dev/project/README.md
```

### macOS URL scheme registration

Add to `Info.plist`:
```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>clicky</string>
    </array>
    <key>CFBundleURLName</key>
    <string>com.yourcompany.leanring-buddy.guide</string>
  </dict>
</array>
```

### Web fallback

For sharing via Slack/email where `clicky://` won't render as clickable:
```
https://clicky.dev/g/{script_id}
```
This page checks if Clicky is installed (attempts `clicky://` redirect), falls back to "Download Clicky" with the guide pre-queued.


---

## 3. MolmoWeb local inference layer

### Why MolmoWeb

The original spec used Claude API for screen matching (every 3s) and
element re-localization — ~20 API calls per step. MolmoWeb 4B runs
locally on any M-series Mac, handles both tasks in <500ms per call,
and costs zero API credits.

Allen AI's MolmoWeb is an open-weight visual web agent (4B and 8B
parameters) that works from screenshots alone — no HTML or
accessibility tree needed. It outperforms Claude 3.7 on ScreenSpot
grounding benchmarks, which is exactly the "find this button on
screen" task we need.

### Task split

| Task | Model | Where | When |
|------|-------|-------|------|
| Screen match (is User B on the right step?) | MolmoWeb 4B | Local | Every 3s during auto-advance |
| Element grounding (find button at x,y) | MolmoWeb 4B | Local | Once per step after narration |
| Advance condition check | MolmoWeb 4B | Local | Every 3s during auto-advance |
| Stuck detection | MolmoWeb 4B | Local | After timeout |
| Narration generation (recording) | Claude | Cloud | Once per step (User A side) |
| Freeform Q&A mid-guide | Claude | Cloud | On demand (User B speaks) |
| TTS playback | ElevenLabs | Cloud | Once per step |

### Local inference setup

MolmoWeb 4B runs as a sidecar process managed by Clicky. Three
deployment options in order of preference:

**Option A: Bundled `llama.cpp` server (recommended)**
- Ship `llama-server` binary + quantized MolmoWeb 4B GGUF in the app
  bundle (~2.5 GB for Q4_K_M quantization)
- Clicky spawns it on launch: `llama-server -m molmoweb-4b.gguf
  --port 8411 --n-gpu-layers 99`
- Communicates over `http://localhost:8411/completion`
- Auto-managed lifecycle (start on app launch, kill on quit)

**Option B: Ollama (if user has it installed)**
- Detect Ollama via `which ollama` or check if port 11434 is open
- Pull model on first use: `ollama pull allenai/molmoweb-4b`
- Call via `http://localhost:11434/api/generate`

**Option C: Remote fallback**
- If local inference unavailable (old Intel Mac, low RAM), fall back
  to a self-hosted MolmoWeb endpoint or degrade to Claude API
- Add `/ground` and `/match` routes to the CF Worker that proxy to a
  GPU instance running MolmoWeb 8B

### New file: `MolmoWebClient.swift`

```swift
import Foundation
import AppKit

/// Client for the local MolmoWeb 4B inference server.
/// Handles screen matching, element grounding, and advance checks
/// without any external API calls.
@MainActor
final class MolmoWebClient: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isStarting = false

    private var serverProcess: Process?
    private let port: Int = 8411
    private let session = URLSession.shared

    private var baseURL: URL {
        URL(string: "http://localhost:\(port)")!
    }

    // MARK: - Server lifecycle

    /// Attempts to connect to an already-running server, then falls
    /// back to starting the bundled llama-server, then tries Ollama.
    func start() async {
        isStarting = true
        defer { isStarting = false }

        // 1. Check if llama-server is already running on our port
        if await healthCheck() {
            isAvailable = true
            print("🧠 MolmoWeb: connected to existing server on :\(port)")
            return
        }

        // 2. Try starting bundled llama-server
        if let modelPath = Bundle.main.path(
            forResource: "molmoweb-4b-q4km",
            ofType: "gguf"
        ) {
            await startBundledServer(modelPath: modelPath)
            if await healthCheck() {
                isAvailable = true
                print("🧠 MolmoWeb: started bundled server")
                return
            }
        }

        // 3. Try Ollama
        if await startViaOllama() {
            isAvailable = true
            print("🧠 MolmoWeb: using Ollama backend")
            return
        }

        print("⚠️ MolmoWeb: no local inference available, will fall back to Claude API")
    }

    func stop() {
        serverProcess?.terminate()
        serverProcess = nil
        isAvailable = false
    }

    private func startBundledServer(modelPath: String) async {
        guard let serverBinary = Bundle.main.path(
            forResource: "llama-server",
            ofType: nil
        ) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBinary)
        process.arguments = [
            "-m", modelPath,
            "--port", String(port),
            "--n-gpu-layers", "99",
            "--ctx-size", "4096",
            "--log-disable"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            serverProcess = process
            // Wait for server to become ready
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if await healthCheck() { return }
            }
        } catch {
            print("⚠️ MolmoWeb: failed to start server: \(error)")
        }
    }

    private func startViaOllama() async -> Bool {
        // Check if Ollama is installed and running
        let ollamaCheck = Process()
        ollamaCheck.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        ollamaCheck.arguments = ["ollama"]
        let pipe = Pipe()
        ollamaCheck.standardOutput = pipe
        do {
            try ollamaCheck.run()
            ollamaCheck.waitUntilExit()
            guard ollamaCheck.terminationStatus == 0 else { return false }
        } catch {
            return false
        }

        // Pull model if not present (async, may take a while on first run)
        let pull = Process()
        pull.executableURL = URL(fileURLWithPath: "/usr/local/bin/ollama")
        pull.arguments = ["pull", "allenai/molmoweb-4b"]
        do {
            try pull.run()
            pull.waitUntilExit()
        } catch {
            return false
        }

        return true
    }

    private func healthCheck() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("/health"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Vision tasks

    /// Checks if User B's current screen matches the expected state
    /// for a given step. Returns true if the condition is met.
    func checkScreenMatch(
        liveScreenshot: Data,
        refScreenshot: Data?,
        condition: String
    ) async -> Bool {
        let prompt = buildPrompt(
            task: "screen_match",
            condition: condition
        )

        let images = buildImageList(
            live: liveScreenshot,
            ref: refScreenshot
        )

        guard let response = await runInference(
            prompt: prompt,
            images: images
        ) else { return false }

        return response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .contains("YES")
    }

    /// Finds a UI element on the live screenshot and returns its
    /// pixel coordinates. Uses MolmoWeb's grounding capability.
    func groundElement(
        screenshot: Data,
        screenshotWidth: Int,
        screenshotHeight: Int,
        elementLabel: String,
        hintX: Int?,
        hintY: Int?
    ) async -> CGPoint? {
        var prompt = "Point to the UI element: \"\(elementLabel)\""
        if let hx = hintX, let hy = hintY {
            prompt += " (approximately near \(hx),\(hy) on a similar screen)"
        }
        prompt += """
        . The image is \(screenshotWidth)x\(screenshotHeight) pixels. \
        Return ONLY the coordinates as: x,y
        """

        guard let response = await runInference(
            prompt: prompt,
            images: [screenshot.base64EncodedString()]
        ) else { return nil }

        // Parse "x,y" from response
        let parts = response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }

    /// Determines if the user appears stuck — i.e. the screen hasn't
    /// meaningfully changed across multiple checks.
    func detectStuck(
        previousScreenshot: Data,
        currentScreenshot: Data,
        expectedAction: String
    ) async -> Bool {
        let prompt = """
        Compare these two screenshots taken 10 seconds apart. The \
        user was expected to: "\(expectedAction)". Has the screen \
        changed meaningfully to indicate progress? Respond YES if \
        progress was made, NO if the user appears stuck.
        """

        guard let response = await runInference(
            prompt: prompt,
            images: [
                previousScreenshot.base64EncodedString(),
                currentScreenshot.base64EncodedString()
            ]
        ) else { return false }

        return response
            .uppercased()
            .contains("NO") // NO progress = stuck
    }

    // MARK: - Inference

    private func runInference(
        prompt: String,
        images: [String]
    ) async -> String? {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("/completion")
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "prompt": prompt,
            "images": images,
            "n_predict": 64,
            "temperature": 0.1,
            "stop": ["\n\n"]
        ]

        request.httpBody = try? JSONSerialization.data(
            withJSONObject: body
        )

        do {
            let (data, _) = try await session.data(for: request)
            let json = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any]
            return json?["content"] as? String
        } catch {
            print("⚠️ MolmoWeb inference error: \(error)")
            return nil
        }
    }

    private func buildPrompt(
        task: String,
        condition: String
    ) -> String {
        switch task {
        case "screen_match":
            return """
            You are a screen state checker. You see a reference \
            screenshot (what the guide author saw) and the user's \
            current screen. Determine if this condition is met: \
            "\(condition)". Be lenient — different themes, window \
            sizes, and resolutions are fine as long as the key UI \
            state matches. Respond with ONLY "YES" or "NO".
            """
        default:
            return condition
        }
    }

    private func buildImageList(
        live: Data,
        ref: Data?
    ) -> [String] {
        var images = [String]()
        if let ref { images.append(ref.base64EncodedString()) }
        images.append(live.base64EncodedString())
        return images
    }
}
```

### Performance expectations

| Task | MolmoWeb 4B (M1) | MolmoWeb 4B (M3 Pro) | Claude API |
|------|------------------|----------------------|------------|
| Screen match | ~400ms | ~250ms | ~2-3s + latency |
| Element grounding | ~350ms | ~200ms | ~2s + latency |
| Stuck detection | ~500ms | ~300ms | ~3s + latency |
| Cost per call | $0 | $0 | ~$0.01-0.03 |

With 3-second polling, MolmoWeb 4B on M1 easily fits within the
polling window with ~2.5s to spare. On M3 Pro, it's ~10x faster
than needed.

### Graceful degradation

If MolmoWeb is unavailable (Intel Mac, low RAM, user declined
download), `GuidedSessionManager` falls back to Claude API for
screen matching and grounding. The `MolmoWebClient.isAvailable`
flag controls this at runtime — no code path changes needed, just
a conditional check before each vision call.


## 4. Swift changes to Clicky codebase

### 4a. New files to add

#### `GuidedSession.swift` — guide data model

```swift
import Foundation

struct ClickyGuide: Codable {
    let version: String
    let id: String
    let title: String
    let author: GuideAuthor
    let createdAt: Date
    let context: GuideContext
    let voice: GuideVoice?
    let steps: [GuideStep]
    let completion: GuideCompletion?

    enum CodingKeys: String, CodingKey {
        case version, id, title, author, context, voice, steps, completion
        case createdAt = "created_at"
    }
}

struct GuideAuthor: Codable {
    let name: String
    let email: String?
}

struct GuideContext: Codable {
    let type: ContextType
    let target: String
    let branch: String?
    let openPath: String?

    enum ContextType: String, Codable {
        case repo, url, file, app
    }

    enum CodingKeys: String, CodingKey {
        case type, target, branch
        case openPath = "open_path"
    }
}

struct GuideVoice: Codable {
    let provider: String
    let voiceId: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case voiceId = "voice_id"
    }
}

struct GuideStep: Codable {
    let id: String
    let narration: String
    let refImage: String?
    let point: GuidePoint?
    let advance: StepAdvance

    enum CodingKeys: String, CodingKey {
        case id, narration, point, advance
        case refImage = "ref_image"
    }
}

struct GuidePoint: Codable {
    let x: Int
    let y: Int
    let label: String
    let screen: Int?
}

struct StepAdvance: Codable {
    let mode: AdvanceMode
    let condition: String?
    let timeoutSeconds: Int?
    let stuckHint: String?

    enum AdvanceMode: String, Codable {
        case auto, manual, timed
    }

    enum CodingKeys: String, CodingKey {
        case mode, condition
        case timeoutSeconds = "timeout_seconds"
        case stuckHint = "stuck_hint"
    }
}

struct GuideCompletion: Codable {
    let narration: String?
    let action: String?
}
```

#### `GuidedSessionManager.swift` — step sequencer

```swift
import Foundation
import Combine
import SwiftUI

enum GuidedSessionState {
    case idle
    case loading
    case playing(stepIndex: Int)
    case waitingForAdvance(stepIndex: Int)
    case stuck(stepIndex: Int)
    case completed
}

@MainActor
final class GuidedSessionManager: ObservableObject {
    @Published private(set) var state: GuidedSessionState = .idle
    @Published private(set) var currentGuide: ClickyGuide?
    @Published private(set) var currentStepIndex: Int = 0
    @Published private(set) var progressFraction: Double = 0

    /// Reference to the main companion manager for screen capture,
    /// TTS, and element pointing
    private weak var companionManager: CompanionManager?
    /// Local MolmoWeb client for fast vision tasks (screen matching,
    /// element grounding). Falls back to Claude API if unavailable.
    private let molmoWeb = MolmoWebClient()
    private var screenCheckTimer: Timer?
    private var stuckTimer: Timer?
    private var currentStepTask: Task<Void, Never>?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        // Start local MolmoWeb inference server in background
        Task { await molmoWeb.start() }
    }

    // MARK: - Session lifecycle

    func loadGuide(from url: URL) async throws {
        state = .loading
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        currentGuide = try decoder.decode(ClickyGuide.self, from: data)
        currentStepIndex = 0
        updateProgress()
    }

    func loadGuide(fromRemote scriptId: String) async throws {
        state = .loading
        let url = URL(string: "\(CompanionManager.workerBaseURL)/guide/\(scriptId)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        currentGuide = try decoder.decode(ClickyGuide.self, from: data)
        currentStepIndex = 0
        updateProgress()
    }

    func startPlayback() {
        guard let guide = currentGuide else { return }
        guard currentStepIndex < guide.steps.count else {
            completeSession()
            return
        }
        playStep(at: currentStepIndex)
    }

    func stopPlayback() {
        currentStepTask?.cancel()
        screenCheckTimer?.invalidate()
        stuckTimer?.invalidate()
        state = .idle
        currentGuide = nil
    }

    func advanceManually() {
        guard case .waitingForAdvance = state else { return }
        advanceToNextStep()
    }

    // MARK: - Step execution

    private func playStep(at index: Int) {
        guard let guide = currentGuide,
              index < guide.steps.count else {
            completeSession()
            return
        }

        let step = guide.steps[index]
        state = .playing(stepIndex: index)

        currentStepTask?.cancel()
        currentStepTask = Task {
            guard let companion = companionManager else { return }

            // 1. Speak the narration via TTS
            do {
                try await companion.elevenLabsTTSClient.speakText(step.narration)
            } catch {
                print("⚠️ Guide TTS error: \(error)")
            }

            guard !Task.isCancelled else { return }

            // 2. Point at the element if specified
            // We need to re-localize the point on User B's screen.
            // Send ref image + live screenshot to Claude to find the element.
            if let point = step.point {
                await relocateAndPoint(step: step, refPoint: point)
            }

            guard !Task.isCancelled else { return }

            // 3. Set up advance mechanism
            switch step.advance.mode {
            case .auto:
                state = .waitingForAdvance(stepIndex: index)
                startScreenCheckLoop(for: step)

            case .manual:
                state = .waitingForAdvance(stepIndex: index)
                // User must press Ctrl+Option or tap Next

            case .timed:
                // Wait 2 seconds after TTS, then advance
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled {
                    advanceToNextStep()
                }
            }
        }
    }

    // MARK: - Screen matching (auto-advance)

    /// Periodically captures User B's screen and asks Claude if the
    /// advance condition is met by comparing against the ref image.
    private func startScreenCheckLoop(for step: GuideStep) {
        // Check every 3 seconds
        screenCheckTimer?.invalidate()
        screenCheckTimer = Timer.scheduledTimer(
            withTimeInterval: 3.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkScreenState(for: step)
            }
        }

        // Start stuck timer if timeout is set
        if let timeout = step.advance.timeoutSeconds {
            stuckTimer?.invalidate()
            stuckTimer = Timer.scheduledTimer(
                withTimeInterval: Double(timeout),
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleStuck(step: step)
                }
            }
        }
    }

    private func checkScreenState(for step: GuideStep) async {
        guard let companion = companionManager else { return }

        do {
            let screenCaptures = try await CompanionScreenCaptureUtility
                .captureAllScreensAsJPEG()

            guard let cursorScreen = screenCaptures
                .first(where: { $0.isCursorScreen }) else { return }

            // Load reference image if available
            var refData: Data? = nil
            if let refImagePath = step.refImage,
               let guide = currentGuide {
                let refURL = guideBaseURL(for: guide)
                    .appendingPathComponent(refImagePath)
                refData = try? Data(contentsOf: refURL)
            }

            let condition = step.advance.condition ?? "step completed"
            var matched = false

            // Prefer MolmoWeb (local, free, fast)
            if molmoWeb.isAvailable {
                matched = await molmoWeb.checkScreenMatch(
                    liveScreenshot: cursorScreen.imageData,
                    refScreenshot: refData,
                    condition: condition
                )
            } else {
                // Fall back to Claude API
                var images: [(data: Data, label: String)] = []
                if let refData {
                    images.append((
                        data: refData,
                        label: "Reference screenshot (what User A saw)"
                    ))
                }
                let dimInfo = " (\(cursorScreen.screenshotWidthInPixels)x\(cursorScreen.screenshotHeightInPixels))"
                images.append((
                    data: cursorScreen.imageData,
                    label: "User B's current screen" + dimInfo
                ))

                let (response, _) = try await companion.claudeAPI.analyzeImage(
                    images: images,
                    systemPrompt: Self.screenMatchSystemPrompt,
                    userPrompt: """
                        Step condition to check: "\(condition)"
                        Respond with ONLY "YES" or "NO".
                        """
                )
                matched = response
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                    .contains("YES")
            }

            if matched {
                screenCheckTimer?.invalidate()
                stuckTimer?.invalidate()
                advanceToNextStep()
            }
        } catch {
            print("⚠️ Screen check error: \(error)")
        }
    }

    private static let screenMatchSystemPrompt = """
    you are a screen state checker for a guided walkthrough app. you \
    receive a reference screenshot (what the guide author saw) and the \
    current user's live screenshot. your job is to determine if the \
    user has completed the step described in the condition.

    compare the two screenshots and determine if the condition is met. \
    be lenient — the user's screen won't look identical to the \
    reference (different resolution, theme, window size) but the key \
    UI state should match.

    respond with ONLY "YES" or "NO". nothing else.
    """

    // MARK: - Element re-localization

    /// Takes the ref point from User A's recording and finds the
    /// equivalent element on User B's live screen. Prefers MolmoWeb
    /// for grounding (local, faster, better at ScreenSpot benchmarks
    /// than Claude). Falls back to Claude API if unavailable.
    private func relocateAndPoint(
        step: GuideStep,
        refPoint: GuidePoint
    ) async {
        guard let companion = companionManager else { return }

        do {
            let screenCaptures = try await CompanionScreenCaptureUtility
                .captureAllScreensAsJPEG()

            guard let cursorScreen = screenCaptures
                .first(where: { $0.isCursorScreen }) else { return }

            var pointCoordinate: CGPoint? = nil

            // Prefer MolmoWeb (better grounding accuracy, zero cost)
            if molmoWeb.isAvailable {
                pointCoordinate = await molmoWeb.groundElement(
                    screenshot: cursorScreen.imageData,
                    screenshotWidth: cursorScreen.screenshotWidthInPixels,
                    screenshotHeight: cursorScreen.screenshotHeightInPixels,
                    elementLabel: refPoint.label,
                    hintX: refPoint.x,
                    hintY: refPoint.y
                )
            } else {
                // Fall back to Claude API
                let dimInfo = " (image dimensions: \(cursorScreen.screenshotWidthInPixels)x\(cursorScreen.screenshotHeightInPixels) pixels)"
                let (response, _) = try await companion.claudeAPI.analyzeImage(
                    images: [(
                        data: cursorScreen.imageData,
                        label: "User's current screen" + dimInfo
                    )],
                    systemPrompt: Self.relocateSystemPrompt,
                    userPrompt: """
                        Find the UI element described as: "\(refPoint.label)"
                        The original coordinates were approximately \
                        (\(refPoint.x), \(refPoint.y)) on the author's screen, \
                        but the user's screen may differ. Find the same \
                        element on this screenshot and respond with ONLY \
                        the coordinates in format: [POINT:x,y:\(refPoint.label)]
                        """
                )
                let parseResult = CompanionManager
                    .parsePointingCoordinates(from: response)
                pointCoordinate = parseResult.coordinate
            }

            // Convert screenshot coords to AppKit global coords
            if let coord = pointCoordinate {
                let sw = CGFloat(cursorScreen.screenshotWidthInPixels)
                let sh = CGFloat(cursorScreen.screenshotHeightInPixels)
                let dw = CGFloat(cursorScreen.displayWidthInPoints)
                let dh = CGFloat(cursorScreen.displayHeightInPoints)
                let frame = cursorScreen.displayFrame

                let clampedX = max(0, min(coord.x, sw))
                let clampedY = max(0, min(coord.y, sh))
                let localX = clampedX * (dw / sw)
                let localY = clampedY * (dh / sh)
                let appKitY = dh - localY

                companion.detectedElementScreenLocation = CGPoint(
                    x: localX + frame.origin.x,
                    y: appKitY + frame.origin.y
                )
                companion.detectedElementDisplayFrame = frame
            }
        } catch {
            print("⚠️ Relocate error: \(error)")
        }
    }

    private static let relocateSystemPrompt = """
    you are a UI element locator. given a screenshot, find a \
    specific UI element and return its pixel coordinates. use the \
    image dimensions as the coordinate space. origin (0,0) is \
    top-left. respond with ONLY the coordinate tag, nothing else. \
    format: [POINT:x,y:label]
    """

    // MARK: - Stuck handling

    private func handleStuck(step: GuideStep) {
        state = .stuck(stepIndex: currentStepIndex)
        screenCheckTimer?.invalidate()

        // Speak the stuck hint if available
        if let hint = step.advance.stuckHint {
            Task {
                try? await companionManager?.elevenLabsTTSClient
                    .speakText(hint)
            }
        }

        // Resume screen checking (user might figure it out)
        startScreenCheckLoop(for: step)
    }

    // MARK: - Navigation

    private func advanceToNextStep() {
        currentStepIndex += 1
        updateProgress()

        guard let guide = currentGuide,
              currentStepIndex < guide.steps.count else {
            completeSession()
            return
        }

        playStep(at: currentStepIndex)
    }

    private func completeSession() {
        screenCheckTimer?.invalidate()
        stuckTimer?.invalidate()
        state = .completed

        if let narration = currentGuide?.completion?.narration {
            Task {
                try? await companionManager?.elevenLabsTTSClient
                    .speakText(narration)
            }
        }

        ClickyAnalytics.trackGuideCompleted(
            guideId: currentGuide?.id ?? "unknown"
        )
    }

    private func updateProgress() {
        guard let guide = currentGuide, !guide.steps.isEmpty else {
            progressFraction = 0
            return
        }
        progressFraction = Double(currentStepIndex)
            / Double(guide.steps.count)
    }

    private func guideBaseURL(for guide: ClickyGuide) -> URL {
        // Resolve relative to the guide file's location
        // This will vary based on how the guide was loaded
        return URL(fileURLWithPath: NSHomeDirectory())
    }
}
```

#### `GuideDetector.swift` — auto-detect `.clicky.json` files

```swift
import Foundation

/// Watches for `.clicky.json` sidecar files and `.clicky/` directories
/// to auto-prompt the user when a guide is available for the current
/// document or repo.
@MainActor
final class GuideDetector: ObservableObject {
    @Published private(set) var detectedGuides: [ClickyGuide] = []
    @Published var pendingGuidePrompt: ClickyGuide?

    private var fsEventStream: FSEventStreamRef?

    /// Scans a directory for `.clicky.json` files or a `.clicky/guides/`
    /// subdirectory. Called when Clicky detects the frontmost app has
    /// opened a new file or project.
    func scanForGuides(in directory: URL) {
        var found: [ClickyGuide] = []
        let fm = FileManager.default

        // Check for .clicky/ directory (repo-style)
        let clickyDir = directory.appendingPathComponent(".clicky/guides")
        if fm.fileExists(atPath: clickyDir.path) {
            if let contents = try? fm.contentsOfDirectory(
                at: clickyDir,
                includingPropertiesForKeys: nil
            ) {
                for file in contents where file.pathExtension == "json" {
                    if let guide = loadGuide(from: file) {
                        found.append(guide)
                    }
                }
            }
        }

        // Check for sidecar files (*.clicky.json)
        if let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for file in contents {
                if file.lastPathComponent.hasSuffix(".clicky.json") {
                    if let guide = loadGuide(from: file) {
                        found.append(guide)
                    }
                }
            }
        }

        detectedGuides = found

        // Auto-prompt with the first detected guide
        if let first = found.first {
            // Only prompt if user hasn't dismissed this guide before
            let dismissedKey = "dismissed_guide_\(first.id)"
            if !UserDefaults.standard.bool(forKey: dismissedKey) {
                pendingGuidePrompt = first
            }
        }
    }

    func dismissGuidePrompt(guide: ClickyGuide) {
        UserDefaults.standard.set(true, forKey: "dismissed_guide_\(guide.id)")
        pendingGuidePrompt = nil
    }

    private func loadGuide(from url: URL) -> ClickyGuide? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClickyGuide.self, from: data)
    }
}
```

### 4b. Changes to existing files

#### `CompanionManager.swift` — add guided session support

```swift
// Add these properties:
let guidedSessionManager: GuidedSessionManager
let guideDetector = GuideDetector()
let molmoWebClient = MolmoWebClient()

// In init or start():
guidedSessionManager = GuidedSessionManager(companionManager: self)

// Start MolmoWeb local server in background:
Task { await molmoWebClient.start() }

// Make these internal so GuidedSessionManager can access them:
// - claudeAPI (change from private lazy var to internal)
// - elevenLabsTTSClient (change from private lazy var to internal)
// - workerBaseURL (change from private static to internal static)

// In handleShortcutTransition(.pressed):
// Add check — if a guided session is active and mode is .manual,
// treat the push-to-talk as "advance to next step" instead of
// starting a new recording.
case .pressed:
    if case .waitingForAdvance = guidedSessionManager.state {
        guidedSessionManager.advanceManually()
        return
    }
    // ... existing push-to-talk code ...
```

#### `leanring_buddyApp.swift` — handle URL scheme

```swift
// In CompanionAppDelegate:

func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
        handleDeepLink(url)
    }
}

private func handleDeepLink(_ url: URL) {
    guard url.scheme == "clicky",
          url.host == "guide" else { return }

    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let params = Dictionary(
        uniqueKeysWithValues: (components?.queryItems ?? [])
            .compactMap { item in
                item.value.map { (item.name, $0) }
            }
    )

    Task { @MainActor in
        // 1. Open the target document/repo
        if let target = params["target"],
           let source = params["source"] {
            openTarget(source: source, target: target)
        }

        // 2. Load and prompt the guide
        if let scriptId = params["id"] {
            try? await companionManager.guidedSessionManager
                .loadGuide(fromRemote: scriptId)
            // Show the toast prompt
            menuBarPanelManager?.showGuidePrompt()
        }
    }
}

private func openTarget(source: String, target: String) {
    switch source {
    case "repo":
        // Open in VS Code or default git client
        if let url = URL(string: "vscode://vscode.git/clone?url=https://\(target)") {
            NSWorkspace.shared.open(url)
        }
    case "url":
        if let url = URL(string: target) {
            NSWorkspace.shared.open(url)
        }
    case "file":
        let fileURL = URL(fileURLWithPath: target)
        NSWorkspace.shared.open(fileURL)
    case "app":
        NSWorkspace.shared.launchApplication(target)
    default:
        break
    }
}
```

#### `CompanionPanelView.swift` — add guide toast UI

```swift
// Add a toast view that appears when a guide is detected:

struct GuidePromptToast: View {
    let guide: ClickyGuide
    let onPlay: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(guide.author.name + " left a walkthrough")
                    .font(.system(size: 13, weight: .medium))
                Text(guide.title)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Play") {
                onPlay()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(radius: 8, y: 4)
    }
}

// Add a progress bar for active guided sessions:

struct GuideProgressBar: View {
    @ObservedObject var sessionManager: GuidedSessionManager

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(stepLabel)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Stop") {
                    sessionManager.stopPlayback()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue)
                        .frame(width: geo.size.width
                               * sessionManager.progressFraction)
                        .animation(.easeInOut(duration: 0.3), value:
                            sessionManager.progressFraction)
                }
            }
            .frame(height: 4)
        }
    }

    private var stepLabel: String {
        guard let guide = sessionManager.currentGuide else {
            return ""
        }
        let total = guide.steps.count
        let current = min(sessionManager.currentStepIndex + 1, total)
        return "Step \(current) of \(total) — \(guide.title)"
    }
}
```

### 4c. Worker addition — `/guide/:id` route

```typescript
// Add to worker/src/index.ts:

if (url.pathname.startsWith("/guide/")) {
  return await handleGuideGet(url, env);
}

async function handleGuideGet(
  url: URL,
  env: Env
): Promise<Response> {
  const scriptId = url.pathname.split("/guide/")[1];

  // Fetch from your guide storage (R2, KV, or D1)
  const guide = await env.GUIDE_BUCKET.get(scriptId);

  if (!guide) {
    return new Response("Guide not found", { status: 404 });
  }

  return new Response(guide.body, {
    headers: {
      "content-type": "application/json",
      "cache-control": "public, max-age=3600",
    },
  });
}
```

Add to `Env` interface:
```typescript
GUIDE_BUCKET: R2Bucket;  // Cloudflare R2 for guide storage
```

---

## 5. Recording pipeline (User A side)

### New file: `GuideRecorder.swift`

This is the authoring side — User A hits "Record Guide" in the panel,
does their walkthrough, and the app generates the `.clicky.json`.

```swift
@MainActor
final class GuideRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var steps: [RecordedStep] = []

    private var recordingStartTime: Date?
    private var audioRecorder: AVAudioRecorder?
    private var screenshotTimer: Timer?

    struct RecordedStep {
        let timestamp: TimeInterval
        let screenshot: Data        // JPEG
        let audioSegment: URL       // temp audio file
    }

    func startRecording() {
        isRecording = true
        recordingStartTime = Date()
        steps = []

        // Start continuous audio recording
        startAudioCapture()

        // Capture screenshots every 5 seconds
        screenshotTimer = Timer.scheduledTimer(
            withTimeInterval: 5.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.captureStep()
            }
        }
    }

    func stopRecording() async -> ClickyGuide? {
        isRecording = false
        screenshotTimer?.invalidate()
        stopAudioCapture()

        // Process: transcribe audio, generate guide
        return await processRecording()
    }

    private func processRecording() async -> ClickyGuide? {
        // 1. Transcribe full audio via Whisper
        //    (via CF Worker /transcribe endpoint)
        // 2. Align transcript segments to screenshot timestamps
        // 3. For each segment, use Claude to:
        //    a. Generate a natural narration from the transcript
        //    b. Identify the key UI element to point at
        //    c. Generate an advance condition
        // 4. Assemble into ClickyGuide
        // 5. Save screenshots to .clicky/guides/assets/

        return nil // Implementation depends on Whisper integration
    }
}
```

---

## 6. Frontmost app detection (for auto-scan)

To auto-detect guides when User B opens a repo or document, Clicky
needs to watch which app/file is in the foreground.

```swift
// Add to CompanionManager:

private var frontmostAppObserver: NSObjectProtocol?

private func startFrontmostAppObservation() {
    frontmostAppObserver = NSWorkspace.shared
        .notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else { return }

            self?.checkForGuidesInFrontmostApp(app)
        }
}

private func checkForGuidesInFrontmostApp(
    _ app: NSRunningApplication
) {
    // For VS Code / Xcode / terminal — check the working directory
    // by querying accessibility APIs or reading recent files.
    // For browsers — check the URL bar.
    // For Finder — check the current directory.

    // Simplified: check common project directories
    guard let bundleId = app.bundleIdentifier else { return }

    switch bundleId {
    case "com.microsoft.VSCode":
        // VS Code exposes workspace via accessibility or CLI
        // `code --status` shows open folders
        detectVSCodeWorkspace()
    case "com.apple.dt.Xcode":
        detectXcodeProject()
    default:
        break
    }
}
```

---

## 7. Summary of all file changes

| File | Action | What |
|------|--------|------|
| `GuidedSession.swift` | **NEW** | Guide data model (Codable structs) |
| `GuidedSessionManager.swift` | **NEW** | Step sequencer, screen matching, TTS |
| `GuideDetector.swift` | **NEW** | Auto-detect `.clicky.json` files |
| `GuideRecorder.swift` | **NEW** | Recording pipeline (User A) |
| `MolmoWebClient.swift` | **NEW** | Local MolmoWeb 4B inference client |
| `CompanionManager.swift` | **EDIT** | Add guided session, MolmoWeb client, change access levels |
| `leanring_buddyApp.swift` | **EDIT** | URL scheme handler |
| `CompanionPanelView.swift` | **EDIT** | Toast prompt + progress bar UI |
| `Info.plist` | **EDIT** | Register `clicky://` URL scheme |
| `worker/src/index.ts` | **EDIT** | Add `/guide/:id` route + R2 storage |
| `molmoweb-4b-q4km.gguf` | **BUNDLE** | Quantized MolmoWeb 4B model (~2.5 GB) |
| `llama-server` | **BUNDLE** | llama.cpp server binary for local inference |
