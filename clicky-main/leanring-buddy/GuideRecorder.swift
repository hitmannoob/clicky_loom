//
//  GuideRecorder.swift
//  leanring-buddy
//
//  Recording pipeline for the "User A" side of guided walkthroughs.
//  User A taps Record, narrates their walkthrough out loud while doing
//  the actions on their screen, then taps Stop. The recorder captures:
//
//    - Continuous mic audio, converted on the fly to 16kHz mono PCM16
//      (ready to ship straight to AssemblyAI batch transcription).
//    - One screenshot of the user's cursor screen every 5 seconds,
//      timestamped against the recording start so the upload queue can
//      align transcript word timings to the right screenshot window.
//    - One screenshot at t=0 immediately on start, so very short
//      recordings still have at least one frame to ground against.
//
//  On stop, `stopRecording()` returns a `GuideRecordingSession` value
//  bundling everything needed for downstream processing — WAV audio
//  bytes, timestamped screenshots, and the total duration. The caller
//  (`CompanionManager`) hands that session off to `GuideUploadQueue`
//  which transcribes, segments, post-processes, and uploads to R2 in
//  the background, freeing User A to immediately start a new recording.
//
//  Why record to in-memory PCM instead of writing to disk: the recorder
//  is only alive for the duration of one walkthrough (typically 30s to
//  a few minutes) and the audio fits easily in memory at 32 KB/sec for
//  PCM16 @ 16kHz. No temp files to clean up, no disk I/O in the hot
//  path, and the session value is directly consumable by the upload
//  queue without an extra read-from-disk step.
//

import AVFoundation
import AppKit
import Combine
import Foundation

// MARK: - Recording session value

/// Immutable bundle of everything a single finished recording produced.
/// Consumed by `GuideUploadQueue` which transcribes the audio, aligns
/// transcript chunks to screenshots by timestamp, and assembles a
/// `ClickyGuide` from the result.
struct GuideRecordingSession {
    /// WAV file bytes (header + PCM16 mono @ 16kHz), ready to POST to
    /// the Worker's `/audio/transcribe/submit` endpoint.
    let audioWavData: Data

    /// Screenshots captured during the recording. `timestampSeconds`
    /// is measured from recording start (t=0 is immediately after
    /// `startRecording()` returned). Ordered chronologically.
    let timestampedScreenshots: [TimestampedScreenshot]

    /// Wall-clock duration of the recording in seconds, computed from
    /// the delta between start and stop calls.
    let totalDurationSeconds: TimeInterval

    /// Bundle identifier of the application that was frontmost at the
    /// moment `startRecording()` was called, captured via
    /// `NSWorkspace.shared.frontmostApplication` — nil when nothing
    /// was frontmost or when Clicky itself held focus. Used downstream
    /// by `CodebaseContextCaptureService` to tag the uploaded guide
    /// with `editor_bundle_id` so Phase 2 can re-open the walkthrough
    /// in the same editor the author used.
    let frontmostApplicationBundleIdentifierAtRecordStart: String?

    struct TimestampedScreenshot {
        let timestampSeconds: TimeInterval
        let jpegImageData: Data
        let screenshotWidthInPixels: Int
        let screenshotHeightInPixels: Int
    }
}

// MARK: - Recorder

@MainActor
final class GuideRecorder: ObservableObject {
    // MARK: Published state

    /// True while a recording is in progress (between `startRecording`
    /// and `stopRecording`). The menu bar panel binds to this to show
    /// a pulsing red "REC" indicator.
    @Published private(set) var isRecording = false

    /// Elapsed seconds since `startRecording` was called, updated 5x
    /// per second. Used by the panel to render a running duration
    /// label like "00:42".
    @Published private(set) var currentRecordingDurationSeconds: TimeInterval = 0

    /// Number of screenshots captured so far in the current recording.
    /// Used by the panel to reassure the user that screen capture is
    /// actually working ("3 frames captured").
    @Published private(set) var currentRecordingScreenshotCount: Int = 0

    // MARK: Audio capture

    /// Target sample rate for the captured audio. AssemblyAI accepts
    /// most common rates but 16 kHz mono is the smallest format that
    /// still transcribes accurately — that's ~32 KB per second vs.
    /// ~192 KB per second at 48 kHz stereo.
    private static let targetAudioSampleRate = 16_000

    /// Shared AVAudioEngine instance. Owned by the recorder so start/
    /// stop cycles don't fight with the push-to-talk dictation engine
    /// over the input device.
    private let recordingAudioEngine = AVAudioEngine()

    /// Converts incoming mic buffers (whatever native format the mic
    /// uses — usually 48 kHz float on macOS) down to 16 kHz PCM16
    /// mono on the audio thread. Shared helper from the existing
    /// BuddyAudioConversionSupport infrastructure.
    private let pcm16AudioConverter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(GuideRecorder.targetAudioSampleRate)
    )

    /// Rolling buffer of all PCM16 audio captured since `startRecording`.
    /// Mutated on the main actor only (the tap callback hops to main
    /// via `DispatchQueue.main.async` before appending) to avoid
    /// concurrent-append races.
    private var accumulatedPCM16AudioBuffer = Data()

    // MARK: Screenshot capture

    /// How often to capture a screenshot during recording, in seconds.
    /// 5s balances "enough frames to segment meaningfully" against
    /// "don't burn CPU running ScreenCaptureKit on a tight loop".
    private static let screenshotCaptureIntervalSeconds: TimeInterval = 5.0

    /// Timestamped screenshots captured so far during this recording.
    /// Reset to empty on each `startRecording`.
    private var capturedTimestampedScreenshots: [GuideRecordingSession.TimestampedScreenshot] = []

    /// Timer that fires every `screenshotCaptureIntervalSeconds` to
    /// trigger a new screenshot capture. Invalidated on stop.
    private var screenshotCaptureTimer: Timer?

    // MARK: Duration tracking

    /// Wall-clock start time of the current recording. Used to compute
    /// per-screenshot timestamps and the published duration label.
    private var recordingStartDate: Date?

    /// Bundle id of whatever app was frontmost when the current
    /// recording started, captured once at `startRecording` time. Nil
    /// when no recording is active or when the frontmost app at
    /// record-start couldn't be resolved.
    private var frontmostApplicationBundleIdentifierFromRecordStart: String?

    /// Fires at ~5 Hz to update `currentRecordingDurationSeconds` for
    /// live UI display.
    private var durationPublishTimer: Timer?

    // MARK: - Lifecycle

    /// Starts audio + screenshot capture. Throws if the audio engine
    /// fails to start (e.g. mic permission missing, device busy). The
    /// caller should show the thrown error to the user.
    func startRecording() throws {
        guard !isRecording else {
            LogGuru.warning(
                "GuideRecorder startRecording called while already recording",
                category: .recording
            )
            return
        }

        // Reset all per-recording state before arming the engine so a
        // failed start leaves no stale buffers behind.
        accumulatedPCM16AudioBuffer = Data()
        capturedTimestampedScreenshots = []
        currentRecordingDurationSeconds = 0
        currentRecordingScreenshotCount = 0
        recordingStartDate = Date()

        // Snapshot the frontmost app BEFORE any UI interaction hops
        // focus to Clicky. The menu bar panel is non-activating so
        // in practice the editor stays frontmost even while the
        // panel is open, and NSWorkspace reports it correctly here.
        frontmostApplicationBundleIdentifierFromRecordStart =
            CodebaseContextCaptureService.currentFrontmostApplicationBundleIdentifier()

        try installAudioEngineTap()
        try startAudioEngine()
        installScreenshotCaptureTimer()
        installDurationPublishTimer()

        // Capture one frame immediately at t≈0 so even a sub-5-second
        // recording has something to ground against.
        Task { @MainActor [weak self] in
            await self?.captureOneScreenshotFrame()
        }

        isRecording = true
        ClickyAnalytics.trackGuideRecordingStarted()
        LogGuru.notice("GuideRecorder recording started", category: .recording)
    }

    /// Stops audio + screenshot capture and returns the finished
    /// session bundle for downstream processing. Returns nil if no
    /// recording was in progress.
    func stopRecording() -> GuideRecordingSession? {
        guard isRecording else {
            LogGuru.warning(
                "GuideRecorder stopRecording called while not recording",
                category: .recording
            )
            return nil
        }

        tearDownScreenshotCaptureTimer()
        tearDownDurationPublishTimer()
        tearDownAudioEngineTap()

        // Compute final duration once before clearing start date so the
        // returned session has an accurate length.
        let finalDurationSeconds: TimeInterval
        if let startDate = recordingStartDate {
            finalDurationSeconds = Date().timeIntervalSince(startDate)
        } else {
            finalDurationSeconds = 0
        }
        recordingStartDate = nil

        // Snapshot the captured bundle id into a local so we can clear
        // the instance property before returning (keeps the recorder
        // ready for a fresh start without stale state).
        let bundleIdentifierSnapshotForSession = frontmostApplicationBundleIdentifierFromRecordStart
        frontmostApplicationBundleIdentifierFromRecordStart = nil

        // Build the WAV payload from the PCM16 buffer so the upload
        // queue can ship it straight to AssemblyAI without any extra
        // format conversion.
        let audioWavData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: accumulatedPCM16AudioBuffer,
            sampleRate: GuideRecorder.targetAudioSampleRate,
            channelCount: 1,
            bitsPerSample: 16
        )

        let finishedSession = GuideRecordingSession(
            audioWavData: audioWavData,
            timestampedScreenshots: capturedTimestampedScreenshots,
            totalDurationSeconds: finalDurationSeconds,
            frontmostApplicationBundleIdentifierAtRecordStart: bundleIdentifierSnapshotForSession
        )

        isRecording = false
        currentRecordingDurationSeconds = 0
        ClickyAnalytics.trackGuideRecordingStopped(
            stepCount: capturedTimestampedScreenshots.count
        )

        LogGuru.notice(
            "GuideRecorder recording stopped — \(String(format: "%.1f", finalDurationSeconds))s, \(capturedTimestampedScreenshots.count) screenshots, \(audioWavData.count / 1024) KB WAV",
            category: .recording
        )

        return finishedSession
    }

    // MARK: - Audio engine wiring

    /// Installs a tap on the default input bus that feeds every audio
    /// buffer through `pcm16AudioConverter` and appends the resulting
    /// bytes to `accumulatedPCM16AudioBuffer` on the main actor.
    private func installAudioEngineTap() throws {
        let inputNode = recordingAudioEngine.inputNode
        let inputHardwareFormat = inputNode.inputFormat(forBus: 0)

        // Sanity check — if the input bus reports 0 sample rate the
        // mic isn't available (usually means the user denied mic
        // permission or another app has exclusive access).
        guard inputHardwareFormat.sampleRate > 0 else {
            throw NSError(
                domain: "GuideRecorder",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "microphone input bus reports sample rate 0 — is the mic permission granted?"]
            )
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputHardwareFormat
        ) { [weak self] incomingAudioBuffer, _ in
            // This callback runs on a background audio thread. Do the
            // format conversion here (it's cheap and stays off-main),
            // then hop to main to mutate the accumulated buffer.
            guard let self else { return }
            guard let convertedPCM16Bytes = self.pcm16AudioConverter
                .convertToPCM16Data(from: incomingAudioBuffer) else {
                return
            }
            DispatchQueue.main.async {
                self.accumulatedPCM16AudioBuffer.append(convertedPCM16Bytes)
            }
        }
    }

    private func startAudioEngine() throws {
        recordingAudioEngine.prepare()
        try recordingAudioEngine.start()
    }

    private func tearDownAudioEngineTap() {
        recordingAudioEngine.inputNode.removeTap(onBus: 0)
        if recordingAudioEngine.isRunning {
            recordingAudioEngine.stop()
        }
    }

    // MARK: - Screenshot timer

    private func installScreenshotCaptureTimer() {
        screenshotCaptureTimer?.invalidate()
        screenshotCaptureTimer = Timer.scheduledTimer(
            withTimeInterval: Self.screenshotCaptureIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.captureOneScreenshotFrame()
            }
        }
    }

    private func tearDownScreenshotCaptureTimer() {
        screenshotCaptureTimer?.invalidate()
        screenshotCaptureTimer = nil
    }

    /// Captures one screenshot of the user's cursor screen via
    /// `CompanionScreenCaptureUtility` and appends it to the recording
    /// session with a timestamp measured from `recordingStartDate`.
    private func captureOneScreenshotFrame() async {
        guard let startDate = recordingStartDate else { return }

        do {
            let allScreenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let cursorScreenCapture = allScreenCaptures.first(where: { $0.isCursorScreen }) else {
                LogGuru.warning(
                    "GuideRecorder could not find the cursor screen for screenshot capture",
                    category: .recording
                )
                return
            }

            let timestampSecondsSinceStart = Date().timeIntervalSince(startDate)
            let newScreenshot = GuideRecordingSession.TimestampedScreenshot(
                timestampSeconds: timestampSecondsSinceStart,
                jpegImageData: cursorScreenCapture.imageData,
                screenshotWidthInPixels: cursorScreenCapture.screenshotWidthInPixels,
                screenshotHeightInPixels: cursorScreenCapture.screenshotHeightInPixels
            )
            capturedTimestampedScreenshots.append(newScreenshot)
            currentRecordingScreenshotCount = capturedTimestampedScreenshots.count

            LogGuru.debug(
                "GuideRecorder captured frame #\(capturedTimestampedScreenshots.count) at t=\(String(format: "%.1f", timestampSecondsSinceStart))s (\(cursorScreenCapture.imageData.count / 1024) KB)",
                category: .recording
            )
        } catch {
            LogGuru.error(
                "GuideRecorder screenshot capture failed: \(error.localizedDescription)",
                category: .recording
            )
        }
    }

    // MARK: - Duration publish timer

    private func installDurationPublishTimer() {
        durationPublishTimer?.invalidate()
        durationPublishTimer = Timer.scheduledTimer(
            withTimeInterval: 0.2,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startDate = self.recordingStartDate else { return }
                self.currentRecordingDurationSeconds = Date().timeIntervalSince(startDate)
            }
        }
    }

    private func tearDownDurationPublishTimer() {
        durationPublishTimer?.invalidate()
        durationPublishTimer = nil
    }
}
