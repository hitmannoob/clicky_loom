//
//  GitRepositoryClient.swift
//  leanring-buddy
//
//  Async read-only wrapper around `/usr/bin/git` for the Phase 2
//  validation-gate flow (`Clicky_Codebase_Distribution_Spec_v1.md`
//  §10–12, implemented as "tell the user what to do" instead of
//  "do it for them").
//
//  This file used to contain the full write-side of Phase 2 — clone,
//  fetch, checkout, stash — but those were deliberately deleted when
//  we refactored Phase 2 to the validation-gate model. The receiver
//  now runs all destructive git operations themselves in their own
//  terminal; Clicky only observes + compares.
//
//  Why the refactor:
//
//    - Complexity. The write-side had ~250 LoC of code that existed
//      only to preserve safety invariants on the user's repo (never
//      hard-reset, stash-don't-pop, confirm-before-checkout, etc.).
//      Removing those operations removes the invariants they
//      defended and the UX branches that implemented them.
//
//    - Respect for dev workflow. The target user of Clicky is a
//      developer who already has opinions about where their clones
//      live and how they manage uncommitted work. Taking over those
//      decisions added friction, not magic.
//
//    - Safety by construction. Read-only means Clicky literally
//      cannot damage the user's repo. The worst thing that can
//      happen is we report the wrong state, which the user can
//      verify in their own terminal.
//
//  Read operations used by the validator:
//
//    - originRemoteURLString — used to verify a user-picked folder
//      is actually the repo the guide was authored against
//    - currentBranchName — used in the state comparison
//    - currentHeadCommitSHA — used in the state comparison
//    - isWorkingTreeDirty — surfaced as an informational note in
//      the checklist; NOT a hard gate (the user's stash / commit /
//      ignore choice is their business)
//

import Foundation

/// Thin async wrapper over the subset of git commands needed for
/// Phase 2 validation-gate state checks. Stateless — all methods
/// are static, no instance state, each call spawns a fresh `Process`.
enum GitRepositoryClient {

    // MARK: - Errors

    /// Typed error for git command failures. The validator uses
    /// `standardErrorText` verbatim when surfacing a failure to the
    /// user so they see the real git error, not our translation.
    struct GitCommandError: LocalizedError {
        let commandArguments: [String]
        let exitCode: Int32
        let standardErrorText: String

        var errorDescription: String? {
            let joinedCommand = (["git"] + commandArguments).joined(separator: " ")
            let trimmedStderr = standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedStderr.isEmpty {
                return "\(joinedCommand) exited with code \(exitCode)"
            }
            return "\(joinedCommand): \(trimmedStderr)"
        }
    }

    // MARK: - Read operations

    /// Returns the `origin` remote URL for the repo at `repoRootURL`,
    /// or nil when the repo has no origin configured. Throws on any
    /// other git failure so the caller can tell "not a git repo"
    /// from "no origin set".
    static func originRemoteURLString(atRepoRootURL repoRootURL: URL) async throws -> String? {
        do {
            let outputText = try await runGitCapturingStdout(
                arguments: ["remote", "get-url", "origin"],
                inWorkingDirectory: repoRootURL
            )
            let trimmedOutput = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedOutput.isEmpty ? nil : trimmedOutput
        } catch let gitError as GitCommandError where gitError.exitCode == 2 {
            // Exit code 2 from `git remote get-url` means "no such
            // remote" (origin not set). Surface as nil so the caller
            // can still proceed with a local-only repo.
            return nil
        }
    }

    /// Returns the current branch name, or nil when HEAD is detached
    /// (e.g. after `checkout <sha>`). An empty string return from
    /// `git branch --show-current` becomes nil.
    static func currentBranchName(atRepoRootURL repoRootURL: URL) async throws -> String? {
        let outputText = try await runGitCapturingStdout(
            arguments: ["branch", "--show-current"],
            inWorkingDirectory: repoRootURL
        )
        let trimmedOutput = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedOutput.isEmpty ? nil : trimmedOutput
    }

    /// Returns the commit SHA currently checked out at HEAD. Throws
    /// on any git failure — a repo without a HEAD commit is an
    /// unexpected state the validator shouldn't try to recover from.
    static func currentHeadCommitSHA(atRepoRootURL repoRootURL: URL) async throws -> String {
        let outputText = try await runGitCapturingStdout(
            arguments: ["rev-parse", "HEAD"],
            inWorkingDirectory: repoRootURL
        )
        return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns true when `git status --porcelain` reports ANY change
    /// — modified tracked files, staged changes, or untracked files.
    /// The validator surfaces this as an informational note in the
    /// mismatch UI ("heads up: you have uncommitted changes") but
    /// does NOT use it as a blocking condition — stash, commit, or
    /// ignore is the user's call.
    static func isWorkingTreeDirty(atRepoRootURL repoRootURL: URL) async throws -> Bool {
        let outputText = try await runGitCapturingStdout(
            arguments: ["status", "--porcelain"],
            inWorkingDirectory: repoRootURL
        )
        let trimmedOutput = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedOutput.isEmpty
    }

    // MARK: - Shared low-level runner

    /// Runs `git <arguments>` asynchronously in `workingDirectoryURL`
    /// and returns stdout as a string on zero-exit. Throws
    /// `GitCommandError` on any non-zero exit so callers can inspect
    /// the exit code + stderr.
    ///
    /// Runs on a background `Task.detached` so the main actor isn't
    /// blocked during the ~50ms each read command typically takes.
    private static func runGitCapturingStdout(
        arguments gitCommandArguments: [String],
        inWorkingDirectory workingDirectoryURL: URL
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let gitExecutableURL = URL(fileURLWithPath: "/usr/bin/git")
            let gitProcess = Process()
            gitProcess.executableURL = gitExecutableURL
            gitProcess.arguments = gitCommandArguments
            gitProcess.currentDirectoryURL = workingDirectoryURL

            let standardOutputPipe = Pipe()
            let standardErrorPipe = Pipe()
            gitProcess.standardOutput = standardOutputPipe
            gitProcess.standardError = standardErrorPipe

            do {
                try gitProcess.run()
            } catch {
                throw GitCommandError(
                    commandArguments: gitCommandArguments,
                    exitCode: -1,
                    standardErrorText: "failed to launch git: \(error.localizedDescription)"
                )
            }

            gitProcess.waitUntilExit()

            let standardErrorText = String(
                data: standardErrorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""

            guard gitProcess.terminationStatus == 0 else {
                throw GitCommandError(
                    commandArguments: gitCommandArguments,
                    exitCode: gitProcess.terminationStatus,
                    standardErrorText: standardErrorText
                )
            }

            let standardOutputText = String(
                data: standardOutputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            return standardOutputText
        }.value
    }
}
