//
//  CompanionGuidedModeSection.swift
//  leanring-buddy
//
//  Guided walkthrough controls and the upload queue shown in the panel.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Guided walkthrough UI section of the menu bar panel. Three visual
/// modes, keyed on `guidedSessionManager.state`:
///
///   1. Idle / ready  — shows Load Guide (file picker) and
///                      Open by Deep Link ID input + Play button if
///                      a guide is loaded and ready.
///   2. Playing       — shows title, step counter, progress bar,
///                      and Stop button. Also a stuck indicator when
///                      the step's stuck hint has been spoken.
///   3. Completed     — shows "Guide complete" with a button to
///                      load another.
struct GuidedModeSection: View {
    @ObservedObject var guidedSessionManager: GuidedSessionManager
    @ObservedObject var guideRecorder: GuideRecorder
    @ObservedObject var guideUploadQueue: GuideUploadQueue
    @ObservedObject var companionManager: CompanionManager
    @State private var deepLinkGuideIDInputText: String = ""
    @State private var lastLoadErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("GUIDED MODE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .tracking(0.5)
                Spacer()
            }

            if isInPreparingWorkspaceState {
                preparingWorkspaceStateView
            } else if isInAwaitingWorkspaceMatchState {
                awaitingWorkspaceMatchStateView
            } else if isInWorkspacePreparationFailedState {
                workspacePreparationFailedStateView
            } else if isInPlayingState {
                playingStateView
            } else if isInCompletedState {
                completedStateView
            } else {
                idleStateView
            }

            if let lastLoadErrorMessage {
                Text(lastLoadErrorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(3)
            }

            if !guideUploadQueue.pendingEntries.isEmpty {
                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.vertical, 4)
                GuideUploadQueueListView(guideUploadQueue: guideUploadQueue)
            }
        }
    }

    private var recordToggleButton: some View {
        Button(action: {
            if guideRecorder.isRecording {
                companionManager.stopGuideRecordingAndEnqueueForProcessing()
            } else {
                companionManager.startGuideRecording()
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: guideRecorder.isRecording ? "stop.fill" : "record.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(guideRecorder.isRecording ? .red : DS.Colors.textSecondary)
                Text(recordButtonLabelText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(guideRecorder.isRecording ? .red : DS.Colors.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(guideRecorder.isRecording
                          ? Color.red.opacity(0.12)
                          : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var recordButtonLabelText: String {
        if guideRecorder.isRecording {
            return "Stop  \(formattedRecordingDuration)"
        }
        return "Record"
    }

    private var formattedRecordingDuration: String {
        let totalRecordingSeconds = Int(guideRecorder.currentRecordingDurationSeconds)
        let minutesComponent = totalRecordingSeconds / 60
        let secondsComponent = totalRecordingSeconds % 60
        return String(format: "%02d:%02d", minutesComponent, secondsComponent)
    }

    private var isInPlayingState: Bool {
        switch guidedSessionManager.state {
        case .speakingNarration, .waitingToAdvance, .stuckOnStep, .completing:
            return true
        default:
            return false
        }
    }

    private var isInCompletedState: Bool {
        if case .completed = guidedSessionManager.state { return true }
        return false
    }

    private var isInPreparingWorkspaceState: Bool {
        if case .preparingWorkspace = guidedSessionManager.state { return true }
        return false
    }

    private var isInWorkspacePreparationFailedState: Bool {
        if case .workspacePreparationFailed = guidedSessionManager.state { return true }
        return false
    }

    private var isInAwaitingWorkspaceMatchState: Bool {
        if case .awaitingWorkspaceMatch = guidedSessionManager.state { return true }
        return false
    }

    /// Current comparison pulled out of `.awaitingWorkspaceMatch`,
    /// or nil when the state is something else. Used by the
    /// validation checklist view to read findings + commands.
    private var currentWorkspaceStateComparison: WorkspaceStateComparison? {
        if case let .awaitingWorkspaceMatch(comparison) = guidedSessionManager.state {
            return comparison
        }
        return nil
    }

    private var isLoading: Bool {
        if case .loadingGuide = guidedSessionManager.state { return true }
        return false
    }

    /// Shown while Phase 2 workspace restoration is running — spinner
    /// plus the live status description the coordinator pushes via
    /// its statusUpdateCallback (e.g. "Cloning foo-repo…",
    /// "Checking out main…", "Opening Cursor…").
    private var preparingWorkspaceStateView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.65)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Preparing workspace")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(preparingWorkspaceDescriptionText)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                }

                Spacer()

                Button(action: {
                    guidedSessionManager.stopPlayback()
                }) {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    /// Current status string pulled out of the `.preparingWorkspace`
    /// associated value, with a safe fallback for other states so
    /// the view's type stays `some View` without an extra optional.
    private var preparingWorkspaceDescriptionText: String {
        if case let .preparingWorkspace(currentPhaseDescription) = guidedSessionManager.state {
            return currentPhaseDescription
        }
        return ""
    }

    /// Validation-gate mismatch view — shown when Phase 2 validation
    /// found the receiver's git state doesn't match what the guide
    /// was authored against. Renders a per-finding checklist (✓ or
    /// ✗ per row), a monospaced block of suggested shell commands,
    /// and an action row: Copy commands / Retry / Pick different
    /// folder / Watch only / Cancel.
    private var awaitingWorkspaceMatchStateView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your repo isn't in the right state yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Run the commands below in your repo, then hit Retry.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            if let currentComparison = currentWorkspaceStateComparison {
                // Per-finding checklist
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(currentComparison.findings, id: \.displayLabel) { singleFinding in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: singleFinding.isMatched ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(singleFinding.isMatched ? DS.Colors.success : .red)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(singleFinding.displayLabel)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(DS.Colors.textSecondary)
                                if singleFinding.isMatched {
                                    Text(singleFinding.actualDisplayValue)
                                        .font(.system(size: 9))
                                        .foregroundColor(DS.Colors.textTertiary)
                                        .lineLimit(1)
                                } else {
                                    Text("expected: \(singleFinding.expectedDisplayValue)")
                                        .font(.system(size: 9))
                                        .foregroundColor(DS.Colors.textTertiary)
                                        .lineLimit(1)
                                    Text("yours: \(singleFinding.actualDisplayValue)")
                                        .font(.system(size: 9))
                                        .foregroundColor(DS.Colors.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.leading, 4)

                // Suggested shell commands block — monospaced,
                // scrollable-if-needed, with a Copy button.
                if !currentComparison.suggestedShellCommands.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("RUN IN YOUR TERMINAL")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .tracking(0.5)
                            Spacer()
                            Button(action: {
                                copyShellCommandsToClipboard(currentComparison.suggestedShellCommands)
                            }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 8, weight: .medium))
                                    Text("Copy")
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white.opacity(0.08))
                                )
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("cd \(currentComparison.repoRootURL.path)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ForEach(currentComparison.suggestedShellCommands, id: \.self) { singleCommandLine in
                                Text(singleCommandLine)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(DS.Colors.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white.opacity(0.04))
                        )
                    }
                }
            }

            // Action button row: Retry is primary. Watch only and
            // Pick different folder are secondary. Cancel is last.
            HStack(spacing: 6) {
                Button(action: {
                    guidedSessionManager.retryWorkspaceValidation()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                        Text("Retry")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DS.Colors.blue400)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button(action: {
                    guidedSessionManager.playbackInWatchOnlyMode()
                }) {
                    Text("Watch only")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button(action: {
                    guidedSessionManager.pickDifferentRepoFolderAndRevalidate()
                }) {
                    Text("Pick folder…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Spacer()

                Button(action: {
                    guidedSessionManager.stopPlayback()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    /// Joins the suggested commands with newlines + a `cd <repo>`
    /// preamble and writes to the system clipboard so the user can
    /// paste them into their terminal as a single block.
    private func copyShellCommandsToClipboard(_ commandLines: [String]) {
        guard let currentComparison = currentWorkspaceStateComparison else { return }
        let pasteboardString: String = (
            ["cd \(currentComparison.repoRootURL.path)"] + commandLines
        ).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pasteboardString, forType: .string)
        LogGuru.info(
            "Copied workspace-fix commands to clipboard: \(pasteboardString)",
            category: .guided,
            privacy: .private
        )
    }

    /// Shown when Phase 2 workspace restoration failed or was
    /// cancelled. Surfaces the underlying reason + a "Play anyway
    /// (watch only)" button that jumps straight to the existing
    /// playback flow using the embedded screenshots.
    private var workspacePreparationFailedStateView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Workspace prep didn't finish")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(workspacePreparationFailureReasonText)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(4)
                }
            }

            HStack(spacing: 8) {
                Button(action: {
                    guidedSessionManager.playbackInWatchOnlyMode()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("Play anyway (watch only)")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DS.Colors.blue400)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button(action: {
                    guidedSessionManager.stopPlayback()
                }) {
                    Text("Dismiss")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private var workspacePreparationFailureReasonText: String {
        if case let .workspacePreparationFailed(failureReason, _) = guidedSessionManager.state {
            return failureReason
        }
        return ""
    }

    private var idleStateView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: loadGuideFromLocalFile) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 11, weight: .medium))
                        Text("Load from file")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                recordToggleButton
            }

            HStack(spacing: 6) {
                TextField("paste guide id", text: $deepLinkGuideIDInputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.06))
                    )

                Button(action: loadGuideFromRemoteID) {
                    Text("Fetch")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(trimmedGuideIDInput.isEmpty)
            }

            if case .ready = guidedSessionManager.state,
               let loadedGuide = guidedSessionManager.currentGuide {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(loadedGuide.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Text("\(loadedGuide.steps.count) steps · by \(loadedGuide.author.name)")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }

                    Spacer()

                    Button(action: {
                        guidedSessionManager.startPlayback()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Play")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(DS.Colors.blue400)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            if isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Loading guide…")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
    }

    private var playingStateView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let playingGuide = guidedSessionManager.currentGuide {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(playingGuide.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Text(stepLabelText(for: playingGuide))
                            .font(.system(size: 10))
                            .foregroundColor(stepLabelColor)
                    }

                    Spacer()

                    Button(action: {
                        guidedSessionManager.stopPlayback()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Stop")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(DS.Colors.blue400)
                            .frame(width: proxy.size.width * guidedSessionManager.progressFraction)
                            .animation(.easeInOut(duration: 0.3), value: guidedSessionManager.progressFraction)
                    }
                }
                .frame(height: 4)

                // Phase 3 hint: tell the user they can ask the
                // follow-along assistant via push-to-talk. Hidden
                // during manual-advance wait where Ctrl+Option is
                // already wired as the "Next step" trigger.
                if shouldShowFollowAlongAssistantHint {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 8))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text("⌃⌥ ask the assistant")
                            .font(.system(size: 9))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    /// True when the "⌃⌥ ask the assistant" hint should be visible
    /// in the playing state view. Suppressed in manual-advance wait
    /// because the existing step label already tells the user to
    /// press Ctrl+Option to continue — showing both hints would be
    /// confusing.
    private var shouldShowFollowAlongAssistantHint: Bool {
        switch guidedSessionManager.state {
        case .waitingToAdvance(_, .manual):
            return false
        case .speakingNarration, .waitingToAdvance, .stuckOnStep, .completing:
            return true
        default:
            return false
        }
    }

    private var completedStateView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(DS.Colors.success)
            VStack(alignment: .leading, spacing: 1) {
                Text("Guide complete")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                if let completedGuide = guidedSessionManager.currentGuide {
                    Text(completedGuide.title)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: {
                guidedSessionManager.stopPlayback()
            }) {
                Text("Done")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private func stepLabelText(for currentGuide: ClickyGuide) -> String {
        let totalStepCount = currentGuide.steps.count
        let oneBasedStepNumber = min(guidedSessionManager.currentStepIndex + 1, totalStepCount)

        switch guidedSessionManager.state {
        case .stuckOnStep:
            return "Step \(oneBasedStepNumber) of \(totalStepCount) — stuck, try the hint"
        case .waitingToAdvance(_, let advanceMode):
            switch advanceMode {
            case .auto:
                return "Step \(oneBasedStepNumber) of \(totalStepCount) — waiting for you…"
            case .manual:
                return "Step \(oneBasedStepNumber) of \(totalStepCount) — press ctrl+option to continue"
            case .timed:
                return "Step \(oneBasedStepNumber) of \(totalStepCount) — continuing"
            }
        case .speakingNarration:
            return "Step \(oneBasedStepNumber) of \(totalStepCount) — narrating"
        case .completing:
            return "Finishing up"
        default:
            return "Step \(oneBasedStepNumber) of \(totalStepCount)"
        }
    }

    private var stepLabelColor: Color {
        if case .stuckOnStep = guidedSessionManager.state {
            return .orange
        }
        return DS.Colors.textTertiary
    }

    private var trimmedGuideIDInput: String {
        deepLinkGuideIDInputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadGuideFromLocalFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.title = "Select a .clicky.json guide file"

        guard openPanel.runModal() == .OK, let pickedURL = openPanel.url else { return }

        do {
            lastLoadErrorMessage = nil
            try guidedSessionManager.loadGuide(fromLocalFileURL: pickedURL)
        } catch {
            lastLoadErrorMessage = "load failed: \(error.localizedDescription)"
            LogGuru.error(
                "Guide load from local file failed: \(error.localizedDescription)",
                category: .guided
            )
        }
    }

    private func loadGuideFromRemoteID() {
        guard !trimmedGuideIDInput.isEmpty else { return }

        Task { @MainActor in
            do {
                lastLoadErrorMessage = nil
                try await guidedSessionManager.loadGuide(fromRemoteID: trimmedGuideIDInput)
            } catch {
                lastLoadErrorMessage = "fetch failed: \(error.localizedDescription)"
                LogGuru.error(
                    "Remote guide fetch failed: \(error.localizedDescription)",
                    category: .guided
                )
            }
        }
    }
}

struct GuideUploadQueueListView: View {
    @ObservedObject var guideUploadQueue: GuideUploadQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RECORDINGS")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .tracking(0.5)
                Spacer()
            }

            ForEach(guideUploadQueue.pendingEntries) { currentEntry in
                GuideUploadQueueRowView(queueEntry: currentEntry)
            }
        }
    }
}

private struct GuideUploadQueueRowView: View {
    let queueEntry: GuideUploadQueueEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIconName)
                .font(.system(size: 11))
                .foregroundColor(statusIconColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(statusHeadlineText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(statusSublineText)
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            if case let .completed(_, deepLinkString, shareURLString) = queueEntry.currentStatus {
                // Prefer the universal https share_url when the worker
                // returned one (codebase distribution v1+) so the
                // copied link works for receivers who don't have
                // Clicky installed yet. Falls back to the clicky://
                // deep link when the worker is an older build.
                let linkToCopyForClipboard = shareURLString ?? deepLinkString
                let copyButtonLabelText = shareURLString != nil ? "Copy link" : "Copy deep link"
                Button(action: {
                    copyShareLinkToClipboard(linkToCopyForClipboard)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9, weight: .medium))
                        Text(copyButtonLabelText)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIconName: String {
        switch queueEntry.currentStatus {
        case .queued:            return "clock"
        case .transcribing:      return "waveform"
        case .segmenting:        return "rectangle.split.3x1"
        case .generatingSteps:   return "sparkles"
        case .uploading:         return "arrow.up.circle"
        case .completed:         return "checkmark.circle.fill"
        case .failed:            return "exclamationmark.triangle.fill"
        }
    }

    private var statusIconColor: Color {
        switch queueEntry.currentStatus {
        case .completed:         return DS.Colors.success
        case .failed:            return .red
        default:                 return DS.Colors.blue400
        }
    }

    private var statusHeadlineText: String {
        switch queueEntry.currentStatus {
        case .queued:            return "Queued"
        case .transcribing:      return "Transcribing audio…"
        case .segmenting:        return "Segmenting steps…"
        case .generatingSteps(let currentStepNumber, let totalStepCount):
            return "Generating step \(currentStepNumber) of \(totalStepCount)…"
        case .uploading:         return "Uploading to R2…"
        case .completed:         return "Ready to share"
        case .failed(let errorMessage):
            return "Failed: \(errorMessage)"
        }
    }

    private var statusSublineText: String {
        let durationString = String(format: "%.0fs", queueEntry.totalDurationSeconds)
        let frameString = "\(queueEntry.screenshotCount) frames"

        switch queueEntry.currentStatus {
        case .completed(let guideID, _, _):
            return "\(durationString) · \(frameString) · id \(guideID.prefix(8))"
        default:
            return "\(durationString) · \(frameString)"
        }
    }

    /// Writes the given link (share URL or deep link — caller picks
    /// which one to prefer) to the system clipboard so the user can
    /// paste it into Slack / email / etc.
    private func copyShareLinkToClipboard(_ linkStringToCopy: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(linkStringToCopy, forType: .string)
        LogGuru.info(
            "Copied guide share link to clipboard: \(linkStringToCopy)",
            category: .guided,
            privacy: .private
        )
    }
}
