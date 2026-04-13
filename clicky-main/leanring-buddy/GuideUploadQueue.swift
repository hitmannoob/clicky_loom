//
//  GuideUploadQueue.swift
//  leanring-buddy
//
//  Background processing queue for recorded walkthrough guides. Takes
//  a finished `GuideRecordingSession` from `GuideRecorder` and turns
//  it into a `.clicky.json` file saved inside the repo's `.clicky/`
//  directory (or a user-chosen location via NSSavePanel when no repo
//  root is available). Pipeline:
//
//      1. Submit the WAV audio to the Worker's
//         `POST /audio/transcribe/submit` — returns a transcript_id.
//      2. Poll `GET /audio/transcribe/status/:id` every ~1.2s until
//         AssemblyAI reports status == completed (or error). When
//         done we get the full text plus word-level timestamps.
//      3. Segment the transcript into step buckets by aligning word
//         timestamps against the recorded screenshot timestamps.
//         Each screenshot becomes the "cover frame" for a step whose
//         transcript chunk is the set of words that fell in
//         [screenshot_t, next_screenshot_t).
//      4. For each (screenshot, transcript-chunk) pair, call
//         `OpenAIAPI.generateGuideStep` which returns structured JSON:
//         narration, point element label, advance mode, advance
//         condition, stuck hint. gpt-5.4-mini reads the screenshot
//         directly so it can pick the right element label.
//      5. Assemble a full `ClickyGuide` with all the returned steps,
//         base64-embedding each reference screenshot inline so the
//         saved JSON is self-contained (no separate asset fetches
//         on the playback side).
//      6. Save the ClickyGuide as pretty-printed JSON to
//         `<repoRoot>/.clicky/<title>-<id>.clicky.json`.
//      7. Publish the result so the menu bar panel can show a
//         "Reveal in Finder" button for the saved guide.
//
//  The queue processes one entry at a time in FIFO order and is
//  intentionally simple — no retry logic, no persistence across app
//  launches. For the prototype the cost of a failed recording is low
//  (User A can just re-record); reliability can come later. Every
//  state transition (queued → transcribing → segmenting →
//  generatingSteps → saving → completed | failed) is mirrored on
//  `@Published pendingEntries` so the panel shows live progress.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

// MARK: - Queue entry

/// One recording waiting to be processed + uploaded. Appears in the
/// panel's upload queue list and mutates in place as its processing
/// progresses.
struct GuideUploadQueueEntry: Identifiable, Equatable {
    let id: UUID
    let createdAtDate: Date
    let totalDurationSeconds: TimeInterval
    let screenshotCount: Int
    var currentStatus: Status

    /// Per-entry status used by the panel to render a status line
    /// (e.g. "transcribing…", "generating step 2 of 4…",
    /// "Saved").
    enum Status: Equatable {
        case queued
        case transcribing
        case segmenting
        case generatingSteps(currentStepNumber: Int, totalStepCount: Int)
        case saving
        case completed(savedFileURL: URL, guideTitle: String)
        case failed(errorMessage: String)
    }
}

// MARK: - Queue

@MainActor
final class GuideUploadQueue: ObservableObject {
    // MARK: Published state

    /// Current pending + processing + completed entries, most recent
    /// first. Entries stay in the list after completion so the user
    /// can see + copy the deep link for past recordings in the same
    /// session — the list does NOT persist across app launches.
    @Published private(set) var pendingEntries: [GuideUploadQueueEntry] = []

    // MARK: Private

    /// Weak back-reference so we can share the OpenAI client and read
    /// `CompanionManager.workerBaseURL`. Weak to avoid a cycle —
    /// `CompanionManager` owns the queue via a lazy var.
    private weak var companionManager: CompanionManager?

    /// One-at-a-time processing task. When a new entry arrives we
    /// either let the in-flight task finish naturally (the loop will
    /// pick up the next entry on its own) or, if the queue was
    /// drained, spin up a new task.
    private var activeProcessingTask: Task<Void, Never>?

    /// In-flight session payloads keyed by queue entry id. The queue
    /// entry struct intentionally doesn't carry the audio/screenshot
    /// data (it's all metadata so the published snapshot stays small
    /// and cheap to diff for SwiftUI).
    private var sessionPayloadByEntryID: [UUID: GuideRecordingSession] = [:]

    /// Repo context captured by `CodebaseContextCaptureService` when
    /// the author picked a file after recording. Nil when the author
    /// skipped the file picker or when the picked file wasn't inside
    /// a git repo — in which case `processEntry` falls back to the
    /// legacy `type:.url, target:"unknown"` default.
    private var capturedContextByEntryID: [UUID: GuideContext] = [:]

    /// Repo root URL captured alongside the guide context. Used to
    /// write the `.clicky.json` file into the repo's `.clicky/` dir.
    /// Nil when the author skipped the file picker or picked outside
    /// a git repo — in that case we show an NSSavePanel instead.
    private var repoRootURLByEntryID: [UUID: URL] = [:]

    // MARK: Init

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    // MARK: - Enqueue

    /// Adds a finished recording session to the queue and kicks off
    /// processing if nothing is currently running. Called by
    /// `CompanionManager` when `GuideRecorder.stopRecording()` returns.
    ///
    /// `capturedGuideContext` carries the repo metadata captured via
    /// the post-stop file picker flow (codebase distribution v1). It
    /// is nil when the author either skipped the file picker or
    /// picked a file outside any git repo — the queue then uploads
    /// the guide with the legacy non-repo default context so the
    /// pipeline degrades cleanly instead of failing.
    func enqueueRecordingSession(
        _ recordingSession: GuideRecordingSession,
        withCapturedGuideContext capturedGuideContext: GuideContext? = nil,
        repoRootURL: URL? = nil
    ) {
        let newEntry = GuideUploadQueueEntry(
            id: UUID(),
            createdAtDate: Date(),
            totalDurationSeconds: recordingSession.totalDurationSeconds,
            screenshotCount: recordingSession.timestampedScreenshots.count,
            currentStatus: .queued
        )
        pendingEntries.insert(newEntry, at: 0)
        sessionPayloadByEntryID[newEntry.id] = recordingSession
        if let capturedGuideContext {
            capturedContextByEntryID[newEntry.id] = capturedGuideContext
        }
        if let repoRootURL {
            repoRootURLByEntryID[newEntry.id] = repoRootURL
        }

        let contextLogSummary: String = {
            guard let capturedGuideContext else { return "no repo context" }
            return "repo=\(capturedGuideContext.target) branch=\(capturedGuideContext.branch ?? "-") file=\(capturedGuideContext.openPath ?? "-")"
        }()
        LogGuru.notice(
            "GuideUploadQueue enqueued entry \(newEntry.id) (\(newEntry.screenshotCount) screenshots, \(String(format: "%.1f", newEntry.totalDurationSeconds))s, \(contextLogSummary))",
            category: .guided,
            privacy: .private
        )

        startProcessingIfIdle()
    }

    private func startProcessingIfIdle() {
        guard activeProcessingTask == nil || activeProcessingTask?.isCancelled == true else {
            return
        }
        activeProcessingTask = Task { [weak self] in
            await self?.runProcessingLoop()
            await MainActor.run { [weak self] in
                self?.activeProcessingTask = nil
            }
        }
    }

    // MARK: - Processing loop

    /// Walks the queue one entry at a time and runs the full transcribe
    /// → segment → generate → upload pipeline for each. Exits when the
    /// next-queued-entry lookup returns nil.
    private func runProcessingLoop() async {
        while let nextEntryToProcess = findNextQueuedEntry() {
            await processEntry(nextEntryToProcess)
        }
    }

    /// Finds the oldest queued entry (i.e. the last element in
    /// `pendingEntries` since newest is at index 0) whose status is
    /// still `.queued`. Returns nil if nothing left to process.
    private func findNextQueuedEntry() -> GuideUploadQueueEntry? {
        // Walk back-to-front because insert(at: 0) puts newest first.
        for candidateEntry in pendingEntries.reversed() {
            if case .queued = candidateEntry.currentStatus {
                return candidateEntry
            }
        }
        return nil
    }

    // MARK: - Per-entry pipeline

    private func processEntry(_ entryToProcess: GuideUploadQueueEntry) async {
        guard let recordingSession = sessionPayloadByEntryID[entryToProcess.id] else {
            updateEntryStatus(entryID: entryToProcess.id, newStatus: .failed(errorMessage: "missing recording payload"))
            return
        }
        guard let companion = companionManager else {
            updateEntryStatus(entryID: entryToProcess.id, newStatus: .failed(errorMessage: "companion manager gone"))
            return
        }

        // Phase 1: transcribe audio via Worker /audio/transcribe/submit
        updateEntryStatus(entryID: entryToProcess.id, newStatus: .transcribing)
        let transcriptionResult: BatchTranscriptionResult
        do {
            transcriptionResult = try await submitAndPollTranscriptionJob(
                audioWavData: recordingSession.audioWavData
            )
        } catch {
            LogGuru.error(
                "GuideUploadQueue transcription failed for entry \(entryToProcess.id): \(error.localizedDescription)",
                category: .guided,
                privacy: .private
            )
            updateEntryStatus(entryID: entryToProcess.id, newStatus: .failed(errorMessage: "transcription failed: \(error.localizedDescription)"))
            sessionPayloadByEntryID.removeValue(forKey: entryToProcess.id)
            capturedContextByEntryID.removeValue(forKey: entryToProcess.id)
            return
        }

        LogGuru.notice(
            "GuideUploadQueue transcription complete — \(transcriptionResult.transcriptText.count) chars, \(transcriptionResult.wordEntries.count) word timings",
            category: .guided
        )

        // Phase 2: segment transcript by screenshot timestamps
        updateEntryStatus(entryID: entryToProcess.id, newStatus: .segmenting)
        let segmentedStepInputs = segmentTranscriptByScreenshots(
            wordEntries: transcriptionResult.wordEntries,
            timestampedScreenshots: recordingSession.timestampedScreenshots,
            fallbackFullTranscriptText: transcriptionResult.transcriptText,
            totalRecordingDurationSeconds: recordingSession.totalDurationSeconds
        )

        LogGuru.info(
            "GuideUploadQueue segmented into \(segmentedStepInputs.count) step inputs",
            category: .guided
        )

        // Phase 3: generate each step via OpenAI
        var finishedStepsAccumulator: [GuideStep] = []
        for (stepIndex, stepInputPair) in segmentedStepInputs.enumerated() {
            updateEntryStatus(
                entryID: entryToProcess.id,
                newStatus: .generatingSteps(
                    currentStepNumber: stepIndex + 1,
                    totalStepCount: segmentedStepInputs.count
                )
            )

            let maybeGeneratedStepData = await companion.openAIAPI.generateGuideStep(
                screenshotData: stepInputPair.screenshotBytes,
                transcriptChunkText: stepInputPair.transcriptChunkText,
                stepIndexInGuide: stepIndex,
                totalStepCountInGuide: segmentedStepInputs.count
            )
            guard let generatedStepData = maybeGeneratedStepData else {
                LogGuru.warning(
                    "GuideUploadQueue step generation returned nil for step \(stepIndex + 1); skipping",
                    category: .guided
                )
                continue
            }

            let normalizedAdvanceMode: StepAdvance.AdvanceMode = {
                switch generatedStepData.advanceModeString.lowercased() {
                case "auto": return .auto
                case "timed": return .timed
                default: return .manual
                }
            }()

            let pointHint: GuidePoint? = {
                guard let elementLabel = generatedStepData.pointElementLabel else { return nil }
                // We don't know exact pixel coordinates from the recording
                // side — MolmoWeb will re-ground using the label at
                // playback time. Store 0,0 as a placeholder.
                return GuidePoint(
                    x: 0,
                    y: 0,
                    label: elementLabel,
                    screen: nil
                )
            }()

            let stepAdvanceSpec = StepAdvance(
                mode: normalizedAdvanceMode,
                condition: generatedStepData.advanceConditionText,
                timeoutSeconds: normalizedAdvanceMode == .auto ? 45 : nil,
                stuckHint: generatedStepData.stuckHintText
            )

            let assembledGuideStep = GuideStep(
                id: "step_\(stepIndex + 1)",
                narration: generatedStepData.narrationText,
                refImage: nil,
                refImageBase64: stepInputPair.screenshotBytes.base64EncodedString(),
                point: pointHint,
                advance: stepAdvanceSpec
            )
            finishedStepsAccumulator.append(assembledGuideStep)
        }

        guard !finishedStepsAccumulator.isEmpty else {
            updateEntryStatus(entryID: entryToProcess.id, newStatus: .failed(errorMessage: "no steps could be generated"))
            sessionPayloadByEntryID.removeValue(forKey: entryToProcess.id)
            capturedContextByEntryID.removeValue(forKey: entryToProcess.id)
            return
        }

        // Phase 4: save assembled guide to local `.clicky/` directory
        updateEntryStatus(entryID: entryToProcess.id, newStatus: .saving)

        // Prefer the repo context captured by the author's post-stop
        // file pick (codebase distribution v1). Falls back to the
        // legacy non-repo default so guides recorded without a file
        // pick still save cleanly — they just won't be eligible
        // for the Phase 2 workspace-restoration flow on playback.
        let contextForAssembledGuide: GuideContext =
            capturedContextByEntryID[entryToProcess.id]
            ?? GuideContext(type: .url, target: "unknown")

        let assembledGuide = ClickyGuide(
            version: "1.0",
            id: UUID().uuidString,
            title: defaultGuideTitleFromTranscript(transcriptionResult.transcriptText),
            author: GuideAuthor(
                name: "Clicky user",
                email: nil
            ),
            createdAt: Date(),
            context: contextForAssembledGuide,
            voice: nil,
            steps: finishedStepsAccumulator,
            completion: GuideCompletion(
                narration: "and that's the walkthrough. thanks for following along.",
                action: nil
            )
        )

        do {
            let savedFileURL: URL
            if let repoRootURL = repoRootURLByEntryID[entryToProcess.id] {
                savedFileURL = try saveAssembledGuideToRepo(assembledGuide, repoRootURL: repoRootURL)
            } else {
                savedFileURL = try saveAssembledGuideViaUserPicker(assembledGuide)
            }
            updateEntryStatus(
                entryID: entryToProcess.id,
                newStatus: .completed(
                    savedFileURL: savedFileURL,
                    guideTitle: assembledGuide.title
                )
            )
            ClickyAnalytics.trackGuideSaved(
                filePath: savedFileURL.path,
                stepCount: finishedStepsAccumulator.count
            )
            LogGuru.notice(
                "GuideUploadQueue entry \(entryToProcess.id) saved to \(savedFileURL.path)",
                category: .guided,
                privacy: .private
            )
        } catch {
            LogGuru.error(
                "GuideUploadQueue save failed for entry \(entryToProcess.id): \(error.localizedDescription)",
                category: .guided,
                privacy: .private
            )
            updateEntryStatus(entryID: entryToProcess.id, newStatus: .failed(errorMessage: "save failed: \(error.localizedDescription)"))
        }

        // Drop the heavy session payload after processing either way —
        // we keep the metadata in `pendingEntries` for UI but the
        // audio/screenshots and captured repo context are no longer
        // needed once the guide has been saved.
        sessionPayloadByEntryID.removeValue(forKey: entryToProcess.id)
        capturedContextByEntryID.removeValue(forKey: entryToProcess.id)
        repoRootURLByEntryID.removeValue(forKey: entryToProcess.id)
    }

    private func updateEntryStatus(entryID: UUID, newStatus: GuideUploadQueueEntry.Status) {
        guard let entryIndex = pendingEntries.firstIndex(where: { $0.id == entryID }) else { return }
        pendingEntries[entryIndex].currentStatus = newStatus
    }

    // MARK: - Transcription (AssemblyAI batch via Worker)

    /// Result of one successful AssemblyAI batch transcription call.
    /// `wordEntries` powers the screenshot-timestamp alignment pass;
    /// `transcriptText` is kept as a fallback in case the word list
    /// is empty (shouldn't happen, but safer to degrade).
    private struct BatchTranscriptionResult {
        let transcriptText: String
        let wordEntries: [WordEntry]

        struct WordEntry {
            /// Word text, e.g. "calculator".
            let wordText: String
            /// Start time in seconds relative to recording start.
            let startSeconds: TimeInterval
            /// End time in seconds.
            let endSeconds: TimeInterval
        }
    }

    /// Submits the audio to the Worker's transcribe endpoint and
    /// polls until complete. Throws on any HTTP error or after a
    /// generous timeout.
    private func submitAndPollTranscriptionJob(audioWavData: Data) async throws -> BatchTranscriptionResult {
        // Step A: submit
        let submitURL = URL(string: "\(CompanionManager.workerBaseURL)/audio/transcribe/submit")!
        var submitRequest = URLRequest(url: submitURL)
        submitRequest.httpMethod = "POST"
        submitRequest.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        submitRequest.httpBody = audioWavData
        submitRequest.timeoutInterval = 60

        let (submitResponseData, submitResponseObject) = try await URLSession.shared.data(for: submitRequest)
        guard let submitHTTPResponse = submitResponseObject as? HTTPURLResponse,
              (200...299).contains(submitHTTPResponse.statusCode) else {
            let errorBodyString = String(data: submitResponseData, encoding: .utf8) ?? "<unreadable>"
            throw NSError(domain: "GuideUploadQueue", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "transcribe submit failed: \(errorBodyString.prefix(300))"])
        }

        guard let submitParsedJSON = try? JSONSerialization.jsonObject(with: submitResponseData) as? [String: Any],
              let returnedTranscriptID = submitParsedJSON["transcript_id"] as? String else {
            throw NSError(domain: "GuideUploadQueue", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "transcribe submit response missing transcript_id"])
        }

        LogGuru.info(
            "GuideUploadQueue transcription job submitted, id=\(returnedTranscriptID)",
            category: .guided,
            privacy: .private
        )

        // Step B: poll
        let pollIntervalNanoseconds: UInt64 = 1_200_000_000  // 1.2s
        let maxTotalPollDurationSeconds: TimeInterval = 240  // 4 min ceiling
        let pollStartDate = Date()

        while Date().timeIntervalSince(pollStartDate) < maxTotalPollDurationSeconds {
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)

            let statusURL = URL(string: "\(CompanionManager.workerBaseURL)/audio/transcribe/status/\(returnedTranscriptID)")!
            let (statusResponseData, _) = try await URLSession.shared.data(from: statusURL)

            guard let statusParsedJSON = try? JSONSerialization.jsonObject(with: statusResponseData) as? [String: Any],
                  let currentStatusString = statusParsedJSON["status"] as? String else {
                continue
            }

            switch currentStatusString {
            case "completed":
                let transcriptTextFromResponse = (statusParsedJSON["text"] as? String) ?? ""
                let rawWordsArray = (statusParsedJSON["words"] as? [[String: Any]]) ?? []
                let parsedWordEntries: [BatchTranscriptionResult.WordEntry] = rawWordsArray.compactMap { wordDictionary in
                    guard let wordTextValue = wordDictionary["text"] as? String else { return nil }
                    // AssemblyAI returns start/end in MILLISECONDS as integers.
                    let startMilliseconds = (wordDictionary["start"] as? Double) ?? 0
                    let endMilliseconds = (wordDictionary["end"] as? Double) ?? 0
                    return BatchTranscriptionResult.WordEntry(
                        wordText: wordTextValue,
                        startSeconds: startMilliseconds / 1000.0,
                        endSeconds: endMilliseconds / 1000.0
                    )
                }
                return BatchTranscriptionResult(
                    transcriptText: transcriptTextFromResponse,
                    wordEntries: parsedWordEntries
                )

            case "error":
                let errorMessageText = (statusParsedJSON["error"] as? String) ?? "unknown assemblyai error"
                throw NSError(domain: "GuideUploadQueue", code: -12,
                              userInfo: [NSLocalizedDescriptionKey: "transcription error: \(errorMessageText)"])

            case "queued", "processing":
                // Keep polling.
                continue

            default:
                // Unknown status — keep polling to be safe.
                continue
            }
        }

        throw NSError(domain: "GuideUploadQueue", code: -13,
                      userInfo: [NSLocalizedDescriptionKey: "transcription timed out after \(Int(maxTotalPollDurationSeconds))s"])
    }

    // MARK: - Segmentation

    /// One segmented step input — the screenshot that anchors the
    /// step plus the transcript chunk that was spoken while that
    /// screenshot was the most recent.
    private struct SegmentedStepInput {
        let screenshotBytes: Data
        let transcriptChunkText: String
    }

    /// Walks the list of timestamped screenshots and, for each one,
    /// builds a string of every transcript word whose start timestamp
    /// falls in the interval [screenshot_t, next_screenshot_t).
    ///
    /// If there are no word timings (transcript was empty or AssemblyAI
    /// only returned plain text), we fall back to assigning the full
    /// transcript to every screenshot so downstream generation still
    /// runs — the generated narrations will be somewhat redundant, but
    /// that's better than dropping the whole guide.
    private func segmentTranscriptByScreenshots(
        wordEntries: [BatchTranscriptionResult.WordEntry],
        timestampedScreenshots: [GuideRecordingSession.TimestampedScreenshot],
        fallbackFullTranscriptText: String,
        totalRecordingDurationSeconds: TimeInterval
    ) -> [SegmentedStepInput] {
        guard !timestampedScreenshots.isEmpty else { return [] }

        if wordEntries.isEmpty {
            // Degrade gracefully: give each screenshot the full
            // transcript text so OpenAI has *something* to generate
            // from. Less accurate, but better than empty output.
            return timestampedScreenshots.map { singleScreenshot in
                SegmentedStepInput(
                    screenshotBytes: singleScreenshot.jpegImageData,
                    transcriptChunkText: fallbackFullTranscriptText
                )
            }
        }

        var segmentedResults: [SegmentedStepInput] = []

        for (screenshotIndex, currentScreenshot) in timestampedScreenshots.enumerated() {
            let windowStartSeconds = currentScreenshot.timestampSeconds
            let windowEndSeconds: TimeInterval
            if screenshotIndex + 1 < timestampedScreenshots.count {
                windowEndSeconds = timestampedScreenshots[screenshotIndex + 1].timestampSeconds
            } else {
                // Last screenshot: window extends to end of recording.
                windowEndSeconds = totalRecordingDurationSeconds + 10  // padding so trailing words aren't dropped
            }

            let wordsInWindow = wordEntries.filter { wordEntry in
                wordEntry.startSeconds >= windowStartSeconds &&
                wordEntry.startSeconds < windowEndSeconds
            }
            let concatenatedWordsForWindow = wordsInWindow
                .map { $0.wordText }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Drop step windows that captured zero words — they'd just
            // produce filler narration. Exception: if this is the ONLY
            // screenshot, keep it and use the full fallback transcript.
            if concatenatedWordsForWindow.isEmpty {
                if timestampedScreenshots.count == 1 {
                    segmentedResults.append(SegmentedStepInput(
                        screenshotBytes: currentScreenshot.jpegImageData,
                        transcriptChunkText: fallbackFullTranscriptText
                    ))
                }
                continue
            }

            segmentedResults.append(SegmentedStepInput(
                screenshotBytes: currentScreenshot.jpegImageData,
                transcriptChunkText: concatenatedWordsForWindow
            ))
        }

        return segmentedResults
    }

    // MARK: - Local file save

    /// Writes the assembled guide as pretty-printed JSON into the
    /// repo's `.clicky/` directory: `<repoRoot>/.clicky/<title>-<id>.clicky.json`.
    /// Creates the `.clicky/` directory if it doesn't exist yet.
    private func saveAssembledGuideToRepo(_ assembledGuide: ClickyGuide, repoRootURL: URL) throws -> URL {
        let clickyDirectoryURL = repoRootURL.appendingPathComponent(".clicky", isDirectory: true)
        try FileManager.default.createDirectory(at: clickyDirectoryURL, withIntermediateDirectories: true)

        let sanitizedTitle = sanitizeForFilename(assembledGuide.title)
        let shortID = String(assembledGuide.id.prefix(8))
        let fileName = "\(sanitizedTitle)-\(shortID).clicky.json"
        let fileURL = clickyDirectoryURL.appendingPathComponent(fileName)

        let prettyEncoder = JSONEncoder()
        prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        prettyEncoder.dateEncodingStrategy = .iso8601
        let jsonData = try prettyEncoder.encode(assembledGuide)
        try jsonData.write(to: fileURL)

        return fileURL
    }

    /// Shows an NSSavePanel so the author can pick where to save the
    /// guide when no repo root is available.
    private func saveAssembledGuideViaUserPicker(_ assembledGuide: ClickyGuide) throws -> URL {
        let savePanel = NSSavePanel()
        savePanel.title = "Save walkthrough guide"
        savePanel.nameFieldStringValue = "\(sanitizeForFilename(assembledGuide.title)).clicky.json"
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true

        NSApp.activate(ignoringOtherApps: true)
        guard savePanel.runModal() == .OK, let chosenURL = savePanel.url else {
            throw NSError(domain: "GuideUploadQueue", code: -30,
                          userInfo: [NSLocalizedDescriptionKey: "author cancelled save panel"])
        }

        let prettyEncoder = JSONEncoder()
        prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        prettyEncoder.dateEncodingStrategy = .iso8601
        let jsonData = try prettyEncoder.encode(assembledGuide)
        try jsonData.write(to: chosenURL)

        return chosenURL
    }

    /// Lowercases the input, replaces non-alphanumeric runs with a
    /// single dash, and truncates to 50 characters for safe filenames.
    private func sanitizeForFilename(_ rawTitle: String) -> String {
        let lowercased = rawTitle.lowercased()
        let sanitized = lowercased
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return String(sanitized.prefix(50))
    }

    // MARK: - Title helper

    /// Picks a short title for the recorded guide based on the first
    /// few words of the transcript. Users can rename later.
    private func defaultGuideTitleFromTranscript(_ rawTranscriptText: String) -> String {
        let trimmedTranscript = rawTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return "Untitled walkthrough"
        }
        let firstHundredCharacters = trimmedTranscript.prefix(100)
        return String(firstHundredCharacters)
    }
}
