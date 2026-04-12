//
//  WorkspacePreparationCoordinator.swift
//  leanring-buddy
//
//  Validation-gate workspace preparation for Phase 2 receiver-side
//  playback (`Clicky_Codebase_Distribution_Spec_v1.md` §6.3, §10–13,
//  §15 — implemented as "tell the user what to do" instead of "do it
//  for them").
//
//  Refactor note (was clone/checkout orchestrator):
//  this file used to drive the full resolve → clone → dirty-tree →
//  checkout → editor-launch state machine, shelling out to git to
//  put the user's repo into the author-recorded state automatically.
//  That whole surface was deleted after we decided the "magic clone
//  flow" was the wrong tradeoff for a dev audience. Devs already
//  have opinions about where clones live, how they handle dirty
//  work, and when they want to switch branches. Taking those
//  decisions over added friction, not magic.
//
//  New flow (much simpler):
//
//    1. Look up a remembered folder for this repo. None? Show an
//       NSOpenPanel asking the user where their clone lives. Reject
//       folders that aren't git repos or whose origin doesn't match
//       the guide's target.
//    2. Read the receiver's current state (branch, commit, dirty).
//    3. Compare against the author's recorded state from the guide.
//       Build a `WorkspaceStateComparison` describing each mismatch
//       plus a list of shell commands the user can run to fix them.
//    4. If everything matches: launch the editor on the target file
//       and return `.ready`. The session proceeds to playback.
//    5. If anything doesn't match: return `.needsUserAction(comparison)`.
//       The session transitions to the `.awaitingWorkspaceMatch` state
//       and the panel renders a checklist with the required commands,
//       a Copy / Retry / Pick different folder / Watch only button row.
//       The user runs the commands in their own terminal and hits
//       Retry — we re-read and re-compare.
//
//  What we DON'T do anymore, deliberately:
//
//    - `git clone` the repo for the user. They have to clone it
//      themselves. On first run, we show the suggested command line
//      in the checklist so they can copy-paste it.
//    - `git fetch` to pull missing commits. Suggested as a shell
//      command instead.
//    - `git checkout` to move branches or revisions. Suggested as a
//      shell command instead.
//    - `git stash` to get out of a dirty tree. Dirty is just an
//      informational note in the checklist now; the user decides
//      what to do about it.
//    - Clone root memory / filesystem scanning. Single remembered
//      folder per repo, picked by the user once.
//
//  What we DO still do:
//
//    - Launch the preferred editor on the target file once validation
//      passes. `EditorLauncher` is unchanged and still useful.
//    - Surface the author-recorded state verbatim so the user sees
//      exactly what Clicky is looking for.
//    - Render git errors directly in the mismatch panel so the user
//      sees git's own message, not our translation.
//

import AppKit
import Foundation

// MARK: - Public types

/// Outcome returned from `validateWorkspaceStateForGuide`. Either the
/// receiver is fully ready to play (`.ready`) or they need to run
/// some shell commands first (`.needsUserAction`).
enum WorkspaceValidationOutcome {
    /// Every state check matched; the editor was launched on the
    /// target file and playback can begin. The associated
    /// `WorkspacePreparationResult` is what `GuidedSessionManager`
    /// stashes so Phase 3 follow-along can reference the real
    /// receiver-side repo root + opened file path.
    case ready(preparedContext: WorkspacePreparationResult)
    /// One or more state checks didn't match. The `comparison`
    /// struct describes what's wrong and what commands would fix it.
    /// The session manager parks in `.awaitingWorkspaceMatch(comparison:)`
    /// until the user hits Retry.
    case needsUserAction(comparison: WorkspaceStateComparison)
}

/// Post-validation snapshot of the prepared workspace, stored on
/// `GuidedSessionManager` so Phase 3 follow-along can surface the
/// real receiver-side repo root + opened file to the assistant.
///
/// Re-used by name from the pre-refactor "clone orchestrator" era
/// because the consumer (`GuidedFollowAlongContextBuilder`) already
/// reads these fields — no need to churn the reader side just
/// because the producer side got simpler.
struct WorkspacePreparationResult: Equatable {
    /// Absolute path of the verified local clone.
    let repoRootURL: URL
    /// Absolute path of the file that was opened in the editor, or
    /// nil when the guide didn't specify `open_path` or the file
    /// didn't exist in the repo.
    let openedFileURL: URL?
    /// Non-fatal notes the UI / log can surface to the user. In the
    /// validation-gate model the only warning that's ever populated
    /// is the dirty-working-tree heads-up.
    let nonFatalWarningMessages: [String]

    static func == (
        lhs: WorkspacePreparationResult,
        rhs: WorkspacePreparationResult
    ) -> Bool {
        lhs.repoRootURL == rhs.repoRootURL
            && lhs.openedFileURL == rhs.openedFileURL
            && lhs.nonFatalWarningMessages == rhs.nonFatalWarningMessages
    }
}

/// Typed error for validator failures that the user can't fix via
/// shell commands. The session manager catches these and transitions
/// to `.workspacePreparationFailed` with the reason text visible.
enum WorkspaceValidationError: LocalizedError {
    case guideIsNotRepoType
    case userCancelledFolderPicker
    case pickedFolderIsNotAGitRepo(pickedFolderPath: String, underlyingGitError: String)
    case pickedFolderRemoteURLMismatch(
        pickedFolderPath: String,
        pickedNormalizedURL: String,
        expectedNormalizedURL: String
    )
    case gitCommandFailed(underlyingErrorDescription: String)

    var errorDescription: String? {
        switch self {
        case .guideIsNotRepoType:
            return "Guide has no repo context — nothing to validate."
        case .userCancelledFolderPicker:
            return "Cancelled — no folder picked."
        case .pickedFolderIsNotAGitRepo(let pickedFolderPath, let underlyingGitError):
            return "That folder (\(pickedFolderPath)) isn't a git repo: \(underlyingGitError)"
        case .pickedFolderRemoteURLMismatch(let pickedFolderPath, let pickedNormalizedURL, let expectedNormalizedURL):
            return "That folder (\(pickedFolderPath)) is a clone of \(pickedNormalizedURL), but the guide is about \(expectedNormalizedURL). Pick a different folder."
        case .gitCommandFailed(let underlyingErrorDescription):
            return "Git command failed: \(underlyingErrorDescription)"
        }
    }
}

/// Snapshot of the receiver's current git state at validation time.
/// All fields are best-effort reads — a missing value means "we
/// couldn't determine that" rather than "that's definitely null".
struct WorkspaceStateSnapshot: Equatable {
    let remoteNormalizedURL: String?
    let branchName: String?
    let commitSHA: String?
    let isWorkingTreeDirty: Bool
}

/// One row of the mismatch checklist. The panel renders these as
/// bullet lines with ✓ / ✗ icons.
struct WorkspaceMismatchFinding: Equatable {
    enum FindingKind: String {
        case repository
        case branch
        case commit
        case workingTree
    }

    let kind: FindingKind
    let displayLabel: String
    let expectedDisplayValue: String
    let actualDisplayValue: String
    let isMatched: Bool
}

/// Full comparison result surfaced to the session manager (and from
/// there to the panel) when validation doesn't fully match. Carries
/// everything the user needs to understand the mismatch and fix it.
struct WorkspaceStateComparison: Equatable {
    /// Absolute path of the folder the user (or their remembered
    /// pick) pointed Clicky at. Already verified as a git repo whose
    /// origin matches the guide's target URL.
    let repoRootURL: URL

    /// Per-field comparison results. Ordered for display.
    let findings: [WorkspaceMismatchFinding]

    /// Shell commands the user can copy-paste into their terminal to
    /// move from their current state to the author's state. Assembled
    /// to be runnable in sequence from the repo root. Empty when
    /// nothing needs to change (but in that case the outcome should
    /// be `.ready`, not `.needsUserAction`, so this list is only
    /// nonempty in the needs-action branch).
    let suggestedShellCommands: [String]

    /// True when every finding is matched. When this is true the
    /// caller should have returned `.ready` instead — it's exposed
    /// as a computed property so the UI can assert consistency.
    var isFullMatch: Bool {
        findings.allSatisfy { $0.isMatched }
    }
}

/// Callback type used to stream status descriptions while validation
/// runs. Short-lived — most of validation is fast reads, only the
/// NSOpenPanel step is user-blocking.
typealias WorkspaceValidationStatusCallback = @MainActor (String) -> Void

// MARK: - Coordinator

/// Static orchestrator for the Phase 2 validation-gate flow. Call
/// `validateWorkspaceStateForGuide` to run one validation pass, or
/// `launchEditorAfterVerifiedMatch` after the user has manually
/// resolved a mismatch and hit Retry.
@MainActor
enum WorkspacePreparationCoordinator {

    /// Runs one validation pass for the given guide. On `.ready` the
    /// editor has already been launched on the target file. On
    /// `.needsUserAction` the caller should surface the comparison
    /// to the UI and wait for Retry.
    ///
    /// Throws `WorkspaceValidationError` for catastrophic failures
    /// (no git, folder picker cancelled, picked folder isn't the
    /// right repo after retrying). The caller maps those to
    /// `.workspacePreparationFailed` for the watch-only fallback UI.
    static func validateWorkspaceStateForGuide(
        _ guideBeingValidated: ClickyGuide,
        statusUpdateCallback: WorkspaceValidationStatusCallback
    ) async throws -> WorkspaceValidationOutcome {
        let guideContext = guideBeingValidated.context
        guard guideContext.type == .repo else {
            throw WorkspaceValidationError.guideIsNotRepoType
        }

        // Phase A: resolve which folder on disk the receiver's clone
        // of this repo lives in. Uses remembered pick first, falls
        // back to NSOpenPanel on miss.
        statusUpdateCallback("Finding your local clone…")
        let repoRootURL = try await resolveRepoRootForGuideContext(guideContext)

        // Phase B: read current receiver state via GitRepositoryClient.
        statusUpdateCallback("Reading repo state…")
        let receiverState: WorkspaceStateSnapshot
        do {
            receiverState = try await readCurrentWorkspaceState(atRepoRootURL: repoRootURL)
        } catch {
            throw WorkspaceValidationError.gitCommandFailed(
                underlyingErrorDescription: error.localizedDescription
            )
        }

        // Phase C: build the comparison against author state.
        let stateComparison = buildWorkspaceStateComparison(
            repoRootURL: repoRootURL,
            receiverState: receiverState,
            guideContext: guideContext
        )

        if stateComparison.isFullMatch {
            // Everything matches — launch the editor and return
            // .ready. Playback proceeds from here.
            statusUpdateCallback("Opening your editor…")
            let editorLaunchOutcome = await EditorLauncher.launchPreferredEditor(
                repoRootURL: repoRootURL,
                repoRelativeOpenPath: guideContext.openPath,
                openAtLineNumber: guideContext.openLine,
                preferredEditorBundleIdentifier: guideContext.editorBundleId
            )

            // Resolve the absolute file URL EditorLauncher actually
            // opened so the Phase 3 follow-along context builder can
            // surface it verbatim. Nil when the guide has no
            // openPath or the file doesn't exist in the repo root.
            let openedFileURL: URL? = {
                guard let openPath = guideContext.openPath, !openPath.isEmpty else { return nil }
                let candidateURL = repoRootURL.appendingPathComponent(openPath)
                return FileManager.default.fileExists(atPath: candidateURL.path) ? candidateURL : nil
            }()

            // The only non-fatal warning we emit in the validation-
            // gate model is a heads-up about a dirty working tree
            // (which didn't block validation because we decided
            // dirty is the user's business).
            var warningMessages: [String] = []
            if receiverState.isWorkingTreeDirty {
                warningMessages.append("Heads up — your working tree has uncommitted changes. They won't affect playback.")
            }

            LogGuru.debug(
                "Workspace validation launched editor: \(String(describing: editorLaunchOutcome))",
                category: .guided,
                privacy: .private
            )

            let preparedContext = WorkspacePreparationResult(
                repoRootURL: repoRootURL,
                openedFileURL: openedFileURL,
                nonFatalWarningMessages: warningMessages
            )
            return .ready(preparedContext: preparedContext)
        }

        // Mismatch — hand back for the user to fix.
        return .needsUserAction(comparison: stateComparison)
    }

    // MARK: - Phase A: folder resolution

    /// Returns the absolute folder URL of the receiver's clone of
    /// the guide's target repo. Uses the remembered pick when
    /// available, otherwise prompts the user via NSOpenPanel. Always
    /// verifies the returned folder is a git repo whose origin
    /// matches the guide's target before handing it back.
    private static func resolveRepoRootForGuideContext(
        _ guideContext: GuideContext
    ) async throws -> URL {
        // Try the remembered pick first.
        if let rememberedFolderURL = RepoWorkspaceResolver.rememberedRepoFolderURL(
            forGuideContext: guideContext
        ) {
            if FileManager.default.fileExists(atPath: rememberedFolderURL.path) {
                do {
                    try await verifyFolderIsExpectedRepo(
                        folderURL: rememberedFolderURL,
                        guideContext: guideContext
                    )
                    return rememberedFolderURL
                } catch {
                    // Remembered folder no longer validates — forget
                    // it and fall through to the picker.
                    LogGuru.warning(
                        "Remembered folder \(rememberedFolderURL.path) for \(guideContext.target) is no longer valid — re-prompting. Underlying: \(error.localizedDescription)",
                        category: .guided,
                        privacy: .private
                    )
                    RepoWorkspaceResolver.forgetRepoFolderURL(forGuideContext: guideContext)
                }
            } else {
                LogGuru.info(
                    "Remembered folder \(rememberedFolderURL.path) no longer exists — re-prompting",
                    category: .guided,
                    privacy: .private
                )
                RepoWorkspaceResolver.forgetRepoFolderURL(forGuideContext: guideContext)
            }
        }

        // No remembered folder (or the remembered one is gone /
        // moved). Ask the user.
        let userPickedFolderURL = try runRepoFolderPicker(forGuideContext: guideContext)
        try await verifyFolderIsExpectedRepo(
            folderURL: userPickedFolderURL,
            guideContext: guideContext
        )
        RepoWorkspaceResolver.rememberRepoFolderURL(
            userPickedFolderURL,
            forGuideContext: guideContext
        )
        return userPickedFolderURL
    }

    /// Shows an `NSOpenPanel` asking the user to pick the local
    /// folder where their clone of the guide's repo lives. Uses a
    /// title / message that surfaces the guide's target URL per spec
    /// §19 ("always show the repo host and normalized clone URL").
    private static func runRepoFolderPicker(
        forGuideContext guideContext: GuideContext
    ) throws -> URL {
        let folderPickerPanel = NSOpenPanel()
        folderPickerPanel.title = "Pick your local clone"
        folderPickerPanel.message = "This walkthrough is about \(guideContext.target). Point Clicky at the folder where you have it cloned, or cancel to play in watch-only mode."
        folderPickerPanel.prompt = "Use this folder"
        folderPickerPanel.canChooseDirectories = true
        folderPickerPanel.canChooseFiles = false
        folderPickerPanel.allowsMultipleSelection = false
        folderPickerPanel.canCreateDirectories = false

        // Activate the app so the panel reliably comes to the front
        // from a menu-bar-only LSUIElement process.
        NSApp.activate(ignoringOtherApps: true)

        let modalRunResult = folderPickerPanel.runModal()
        guard modalRunResult == .OK, let pickedFolderURL = folderPickerPanel.url else {
            throw WorkspaceValidationError.userCancelledFolderPicker
        }
        return pickedFolderURL
    }

    /// Confirms the given folder is a git repo whose origin URL
    /// matches the guide's target URL (normalized). Throws a
    /// descriptive error on failure so the caller can surface it in
    /// the folder-picker retry flow.
    private static func verifyFolderIsExpectedRepo(
        folderURL folderURLToVerify: URL,
        guideContext: GuideContext
    ) async throws {
        let folderOriginURLString: String?
        do {
            folderOriginURLString = try await GitRepositoryClient.originRemoteURLString(
                atRepoRootURL: folderURLToVerify
            )
        } catch {
            throw WorkspaceValidationError.pickedFolderIsNotAGitRepo(
                pickedFolderPath: folderURLToVerify.path,
                underlyingGitError: error.localizedDescription
            )
        }

        guard let folderOriginURLText = folderOriginURLString else {
            throw WorkspaceValidationError.pickedFolderIsNotAGitRepo(
                pickedFolderPath: folderURLToVerify.path,
                underlyingGitError: "no origin remote configured"
            )
        }

        let folderNormalizedURL = RepoWorkspaceResolver.normalizeRemoteURLForMatching(folderOriginURLText)
        let guideNormalizedURL = RepoWorkspaceResolver.normalizeRemoteURLForMatching(guideContext.target)
        guard folderNormalizedURL == guideNormalizedURL else {
            throw WorkspaceValidationError.pickedFolderRemoteURLMismatch(
                pickedFolderPath: folderURLToVerify.path,
                pickedNormalizedURL: folderNormalizedURL,
                expectedNormalizedURL: guideNormalizedURL
            )
        }
    }

    // MARK: - Phase B: state reading

    /// Reads the receiver's current git state into a snapshot struct.
    /// Every field is individually tolerant of failure so one bad
    /// read doesn't tank the whole comparison.
    private static func readCurrentWorkspaceState(
        atRepoRootURL repoRootURL: URL
    ) async throws -> WorkspaceStateSnapshot {
        // Origin URL — normalized via the resolver for match-key
        // equality against the guide's target.
        let remoteURLString = (try? await GitRepositoryClient.originRemoteURLString(
            atRepoRootURL: repoRootURL
        )) ?? nil
        let remoteNormalizedURL = remoteURLString.map { rawURL in
            RepoWorkspaceResolver.normalizeRemoteURLForMatching(rawURL)
        }

        let branchName = try? await GitRepositoryClient.currentBranchName(
            atRepoRootURL: repoRootURL
        )
        let commitSHA = try? await GitRepositoryClient.currentHeadCommitSHA(
            atRepoRootURL: repoRootURL
        )
        let isWorkingTreeDirty = (try? await GitRepositoryClient.isWorkingTreeDirty(
            atRepoRootURL: repoRootURL
        )) ?? false

        return WorkspaceStateSnapshot(
            remoteNormalizedURL: remoteNormalizedURL,
            branchName: branchName,
            commitSHA: commitSHA,
            isWorkingTreeDirty: isWorkingTreeDirty
        )
    }

    // MARK: - Phase C: comparison

    /// Builds the checklist of per-field match results plus the
    /// suggested shell commands to move from the receiver's state to
    /// the author's state. The receiver's dirty working tree is
    /// surfaced as a separate info-only row — it's never a blocker.
    private static func buildWorkspaceStateComparison(
        repoRootURL: URL,
        receiverState: WorkspaceStateSnapshot,
        guideContext: GuideContext
    ) -> WorkspaceStateComparison {
        var findings: [WorkspaceMismatchFinding] = []

        // Repository URL check. This should almost always match
        // because we already validated the folder's origin when we
        // picked it, but we include it in the checklist so the user
        // sees "✓ repo matches" as reassurance.
        let expectedNormalizedURL = RepoWorkspaceResolver.normalizeRemoteURLForMatching(guideContext.target)
        let actualNormalizedURL = receiverState.remoteNormalizedURL ?? "<no origin>"
        findings.append(WorkspaceMismatchFinding(
            kind: .repository,
            displayLabel: "Repository",
            expectedDisplayValue: expectedNormalizedURL,
            actualDisplayValue: actualNormalizedURL,
            isMatched: expectedNormalizedURL == actualNormalizedURL
        ))

        // Branch check. Only applicable when the guide specifies a
        // branch. If it doesn't, the row is omitted.
        if let expectedBranchName = guideContext.branch, !expectedBranchName.isEmpty {
            let actualBranchName = receiverState.branchName ?? "<detached HEAD>"
            findings.append(WorkspaceMismatchFinding(
                kind: .branch,
                displayLabel: "Branch",
                expectedDisplayValue: expectedBranchName,
                actualDisplayValue: actualBranchName,
                isMatched: expectedBranchName == actualBranchName
            ))
        }

        // Commit check. Only applicable when the guide specifies a
        // commit SHA. Compared case-insensitively to be safe against
        // mixed-case SHAs.
        if let expectedCommitSHA = guideContext.commitSha, !expectedCommitSHA.isEmpty {
            let actualCommitSHA = receiverState.commitSHA ?? "<unknown>"
            let isCommitMatched = actualCommitSHA.lowercased() == expectedCommitSHA.lowercased()
            findings.append(WorkspaceMismatchFinding(
                kind: .commit,
                displayLabel: "Commit",
                expectedDisplayValue: String(expectedCommitSHA.prefix(10)),
                actualDisplayValue: String(actualCommitSHA.prefix(10)),
                isMatched: isCommitMatched
            ))
        }

        // Working tree note. Surfaces dirty state as informational;
        // marked as "matched" regardless of cleanliness so it doesn't
        // block the isFullMatch gate.
        if receiverState.isWorkingTreeDirty {
            findings.append(WorkspaceMismatchFinding(
                kind: .workingTree,
                displayLabel: "Working tree",
                expectedDisplayValue: "any state is fine",
                actualDisplayValue: "uncommitted changes (won't block playback)",
                isMatched: true
            ))
        }

        // Build the suggested shell commands to fix any mismatches.
        let suggestedShellCommands = buildSuggestedFixCommands(
            findings: findings,
            guideContext: guideContext
        )

        return WorkspaceStateComparison(
            repoRootURL: repoRootURL,
            findings: findings,
            suggestedShellCommands: suggestedShellCommands
        )
    }

    /// Produces a copy-pasteable list of git commands the user can
    /// run in their terminal to move from their current state to
    /// the expected state. Commands are ordered so running them in
    /// sequence produces the right final state: fetch first (to
    /// populate missing refs), then checkout the target commit or
    /// branch.
    private static func buildSuggestedFixCommands(
        findings: [WorkspaceMismatchFinding],
        guideContext: GuideContext
    ) -> [String] {
        let commitMismatched = findings.contains { finding in
            finding.kind == .commit && !finding.isMatched
        }
        let branchMismatched = findings.contains { finding in
            finding.kind == .branch && !finding.isMatched
        }

        guard commitMismatched || branchMismatched else {
            return []
        }

        var commandLines: [String] = []

        // Always fetch first so commits the user doesn't have yet
        // become available for checkout. This is a read-only
        // suggestion — Clicky doesn't run it.
        commandLines.append("git fetch origin")

        // Prefer checking out the exact commit when the guide has
        // one — matches the author's tree exactly. Fall back to the
        // branch name when there's no commit SHA.
        if commitMismatched, let expectedCommitSHA = guideContext.commitSha, !expectedCommitSHA.isEmpty {
            commandLines.append("git checkout \(expectedCommitSHA)")
        } else if branchMismatched, let expectedBranchName = guideContext.branch, !expectedBranchName.isEmpty {
            commandLines.append("git checkout \(expectedBranchName)")
        }

        return commandLines
    }

    // MARK: - Editor launch after retry success

    /// Re-runs validation and, if everything matches, launches the
    /// editor. Used by `GuidedSessionManager.retryWorkspaceValidation`
    /// when the user hits Retry in the mismatch UI.
    ///
    /// This is the same as `validateWorkspaceStateForGuide` but
    /// without the NSOpenPanel-on-miss fallback — by the time the
    /// user is in the Retry loop we already have a remembered
    /// folder, so re-prompting would be surprising.
    static func retryValidationForGuide(
        _ guideBeingValidated: ClickyGuide,
        statusUpdateCallback: WorkspaceValidationStatusCallback
    ) async throws -> WorkspaceValidationOutcome {
        // Reuse the main flow — it already handles the "remembered
        // folder still valid" fast path. If the user happened to
        // delete the folder between validation runs, this will
        // gracefully re-prompt them.
        return try await validateWorkspaceStateForGuide(
            guideBeingValidated,
            statusUpdateCallback: statusUpdateCallback
        )
    }
}
