//
//  CodebaseContextCaptureService.swift
//  leanring-buddy
//
//  Builds a `GuideContext` (type == .repo) for a recorded walkthrough
//  by shelling out to `/usr/bin/git` against a file the author picks
//  after hitting Stop. This is the "producer" side of the codebase
//  distribution v1 pipeline — the receiver side lives in Phase 2
//  (`RepoWorkspaceResolver`, `EditorLauncher`, etc.).
//
//  Why a file-picker-driven capture instead of fully automatic:
//
//    - VS Code and Cursor don't expose the currently-open document via
//      AppleScript or a stable AX attribute, so any "auto-detect what
//      file you were looking at" approach has to walk window titles or
//      read editor storage files — both fragile and privacy-invasive.
//
//    - Letting the author pick a file via NSOpenPanel is trivially
//      reliable. Once we have that one absolute path, every other
//      field (`target`, `branch`, `commit_sha`, `open_path`,
//      `workspace_name`, `clone_preference`) is a one-liner `git`
//      shell-out against the file's parent directory.
//
//    - The spec's security and trust section (§19) asks for explicit,
//      author-visible metadata capture. A manual file pick is the
//      clearest possible expression of "the author confirmed what's
//      being uploaded."
//
//  The service is stateless — all functions are static and synchronous.
//  Call it on the main actor from `CompanionManager` after
//  `NSOpenPanel.runModal()` returns a URL.
//

import AppKit
import Foundation

/// Builds `GuideContext.repo` values from user-picked files by running
/// local `git` commands. All methods are pure + throwing — no state,
/// no background work, no side effects beyond the shell-outs.
enum CodebaseContextCaptureService {

    /// Captures the full repo context for a file the author picked
    /// after finishing a recording. Runs four `git` commands against
    /// the file's parent directory:
    ///
    ///   1. `git rev-parse --show-toplevel`    → repo root absolute path
    ///   2. `git remote get-url origin`         → remote URL (ssh/https)
    ///   3. `git branch --show-current`         → current branch name
    ///      (empty string when HEAD is detached)
    ///   4. `git rev-parse HEAD`                → current commit SHA
    ///
    /// If the file isn't inside a git repository, or any git command
    /// fails, returns nil so the caller can fall back to a non-repo
    /// context (the same "type:.url, target:unknown" default the
    /// recorder used before codebase distribution v1).
    ///
    /// `editorBundleId` is optional — caller passes the bundle id of
    /// whatever editor was frontmost when recording started (captured
    /// by `GuideRecorder`). It's stored on the returned context for
    /// Phase 2's editor-launch step.
    static func captureRepoContext(
        forPickedFileURL pickedFileURL: URL,
        editorBundleId: String?
    ) -> GuideContext? {
        let parentDirectoryURL = pickedFileURL.deletingLastPathComponent()

        // Step 1: find the repo root. If this fails the file isn't in
        // a git repo and we can't build a repo-type context.
        guard let repoRootAbsolutePath = runGitCommandCapturingOutput(
            arguments: ["rev-parse", "--show-toplevel"],
            inWorkingDirectory: parentDirectoryURL
        ) else {
            LogGuru.warning(
                "CodebaseContextCaptureService: file \(pickedFileURL.path) is not inside a git repo",
                category: .guided
            )
            return nil
        }

        let repoRootURL = URL(fileURLWithPath: repoRootAbsolutePath)

        // Steps 2–4 run against the repo root so multi-file repos work
        // regardless of which directory level the file lives at.
        let remoteURLString = runGitCommandCapturingOutput(
            arguments: ["remote", "get-url", "origin"],
            inWorkingDirectory: repoRootURL
        ) ?? ""

        let currentBranchName = runGitCommandCapturingOutput(
            arguments: ["branch", "--show-current"],
            inWorkingDirectory: repoRootURL
        ) ?? ""

        let currentCommitSHA = runGitCommandCapturingOutput(
            arguments: ["rev-parse", "HEAD"],
            inWorkingDirectory: repoRootURL
        ) ?? ""

        // Compute the repo-relative path for `open_path`. Guaranteed
        // to succeed because the picked file is a descendant of the
        // repo root by construction (git rev-parse --show-toplevel
        // walks up from the file's own directory).
        let repoRelativeFilePath = computeRepoRelativePath(
            forAbsoluteFileURL: pickedFileURL,
            insideRepoRootURL: repoRootURL
        )

        let workspaceFolderName = repoRootURL.lastPathComponent
        let inferredClonePreference = inferClonePreference(fromRemoteURLString: remoteURLString)

        LogGuru.notice(
            "CodebaseContextCaptureService captured repo context — root=\(repoRootURL.path), branch=\(currentBranchName), sha=\(currentCommitSHA.prefix(10)), file=\(repoRelativeFilePath)",
            category: .guided,
            privacy: .private
        )

        return GuideContext(
            type: .repo,
            // Fall back to the repo root's file:// URL if `origin` isn't
            // set — some authors record from a freshly-initialized
            // repo that hasn't been pushed anywhere. The share page
            // and Phase 2 can still render something useful.
            target: remoteURLString.isEmpty ? repoRootURL.absoluteString : remoteURLString,
            branch: currentBranchName.isEmpty ? nil : currentBranchName,
            openPath: repoRelativeFilePath,
            commitSha: currentCommitSHA.isEmpty ? nil : currentCommitSHA,
            openLine: nil,
            editorBundleId: editorBundleId,
            workspaceName: workspaceFolderName,
            clonePreference: inferredClonePreference
        )
    }

    // MARK: - Git shell-out

    /// Runs `git <arguments>` in the given working directory and
    /// returns its trimmed stdout on success. Returns nil on any
    /// failure — non-zero exit, missing git binary, launch error,
    /// empty output — so the caller can branch cleanly without
    /// needing to catch every failure mode.
    ///
    /// This is synchronous and blocks the calling thread. Intended
    /// to be called from the main actor during the post-stop flow
    /// where a brief (~100ms) blocking stall is fine because the user
    /// is already looking at a file picker dialog.
    private static func runGitCommandCapturingOutput(
        arguments: [String],
        inWorkingDirectory workingDirectoryURL: URL
    ) -> String? {
        let gitBinaryURL = URL(fileURLWithPath: "/usr/bin/git")
        let gitProcess = Process()
        gitProcess.executableURL = gitBinaryURL
        gitProcess.arguments = arguments
        gitProcess.currentDirectoryURL = workingDirectoryURL

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        gitProcess.standardOutput = standardOutputPipe
        gitProcess.standardError = standardErrorPipe

        do {
            try gitProcess.run()
        } catch {
            LogGuru.warning(
                "CodebaseContextCaptureService: failed to launch git \(arguments.joined(separator: " ")) — \(error.localizedDescription)",
                category: .guided
            )
            return nil
        }

        gitProcess.waitUntilExit()

        guard gitProcess.terminationStatus == 0 else {
            let errorOutputString = String(
                data: standardErrorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "<non-utf8 git stderr>"
            LogGuru.info(
                "CodebaseContextCaptureService: git \(arguments.joined(separator: " ")) exited \(gitProcess.terminationStatus) — \(errorOutputString.trimmingCharacters(in: .whitespacesAndNewlines))",
                category: .guided,
                privacy: .private
            )
            return nil
        }

        let rawOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let decodedOutputString = String(data: rawOutputData, encoding: .utf8) else {
            return nil
        }
        let trimmedOutputString = decodedOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedOutputString.isEmpty ? nil : trimmedOutputString
    }

    // MARK: - Helpers

    /// Computes a repo-relative path string (e.g. `src/main.ts`) from
    /// an absolute file URL that is guaranteed to live inside
    /// `repoRootURL`. Falls back to the file's last path component
    /// when relative-path computation fails, so `open_path` is always
    /// a meaningful string even in pathological cases.
    private static func computeRepoRelativePath(
        forAbsoluteFileURL absoluteFileURL: URL,
        insideRepoRootURL repoRootURL: URL
    ) -> String {
        let standardizedFilePath = absoluteFileURL.standardizedFileURL.path
        let standardizedRootPath = repoRootURL.standardizedFileURL.path

        // Append a trailing slash to the root so "/foo/bar" isn't
        // matched as a prefix of "/foo/barbaz".
        let rootPathWithTrailingSeparator: String = {
            if standardizedRootPath.hasSuffix("/") {
                return standardizedRootPath
            }
            return standardizedRootPath + "/"
        }()

        if standardizedFilePath.hasPrefix(rootPathWithTrailingSeparator) {
            return String(standardizedFilePath.dropFirst(rootPathWithTrailingSeparator.count))
        }
        return absoluteFileURL.lastPathComponent
    }

    /// Infers whether the author prefers SSH or HTTPS clone URLs based
    /// on the form of the origin remote. `git@github.com:org/repo.git`
    /// and `ssh://git@host/path` → `"ssh"`. Everything else (`https://`,
    /// bare file paths, unset remote) → `"https"`.
    private static func inferClonePreference(fromRemoteURLString remoteURLString: String) -> String {
        if remoteURLString.isEmpty {
            return "https"
        }
        if remoteURLString.hasPrefix("git@") || remoteURLString.hasPrefix("ssh://") {
            return "ssh"
        }
        return "https"
    }
}

// MARK: - Frontmost editor detection

extension CodebaseContextCaptureService {

    /// Bundle identifiers of editors we recognize as "code editors"
    /// when deciding whether to mark a recording as repo-eligible.
    /// Extend this list as we add first-class support for more
    /// editors — the set is intentionally small for v1 to keep the
    /// heuristic obvious.
    static let recognizedCodeEditorBundleIdentifiers: Set<String> = [
        // VS Code
        "com.microsoft.VSCode",
        // VS Code Insiders
        "com.microsoft.VSCodeInsiders",
        // Cursor (Anysphere's VS Code fork)
        "com.todesktop.230313mzl4w4u92",
        // Xcode
        "com.apple.dt.Xcode",
        // Zed
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
        // JetBrains — they all share the com.jetbrains.* prefix so we
        // check with a prefix helper below, not via this set.
    ]

    /// Returns the bundle identifier of the currently-frontmost
    /// application, or nil when nothing is frontmost or the frontmost
    /// app is Clicky itself (so record-start hotkeys don't mis-tag
    /// the walkthrough as being authored in our own app).
    ///
    /// Called from `GuideRecorder.startRecording` at the exact moment
    /// the user triggers a recording — Clicky's menu bar panel is
    /// non-activating so at that instant the frontmost app is still
    /// whatever the author was working in.
    static func currentFrontmostApplicationBundleIdentifier() -> String? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        guard let frontmostBundleId = frontmostApplication.bundleIdentifier else {
            return nil
        }
        // Filter out Clicky itself. `Bundle.main.bundleIdentifier`
        // resolves to the current app's id at runtime so this stays
        // correct even if the bundle id changes between dev and
        // release builds.
        if frontmostBundleId == Bundle.main.bundleIdentifier {
            return nil
        }
        return frontmostBundleId
    }
}
