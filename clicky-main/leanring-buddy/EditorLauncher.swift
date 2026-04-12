//
//  EditorLauncher.swift
//  leanring-buddy
//
//  Opens a prepared repository and a target file in the receiver's
//  preferred editor for Phase 2 workspace restoration
//  (`Clicky_Codebase_Distribution_Spec_v1.md` §13).
//
//  Launch precedence (per the accepted defaults in the Phase 2
//  planning discussion):
//
//    1. The editor whose bundle id matches `GuideContext.editorBundleId`
//       (what the author was using when they recorded), if installed
//       locally. Detected via `NSWorkspace.urlForApplication(withBundleIdentifier:)`.
//    2. Cursor, if installed.
//    3. VS Code, if installed.
//    4. `NSWorkspace.open(openedFileURL)` which defers to whatever
//       the receiver has set as the default app for the file's type.
//       This is the universal fallback — it always succeeds if the
//       file exists, even if no "real" editor is installed.
//
//  For Cursor and VS Code we prefer their CLI shims (`cursor -g`,
//  `code -g`) because they support the `file:line[:column]` form
//  natively and can open a specific file inside an already-running
//  editor window, which matters for the UX. The CLI shims ship in
//  each editor's bundle under `Contents/Resources/app/bin/`. If the
//  shim is missing (user hasn't run "Install 'code' command in PATH"
//  from the command palette, or it got removed) we fall back to
//  `open -a <AppName> <file>`, which works but doesn't support the
//  `:line` suffix — the editor just opens the file and leaves the
//  cursor wherever it was.
//

import AppKit
import Foundation

/// Static helper that opens a repo + file in the user's preferred
/// editor. All methods are pure wrappers around `Process` / `open` /
/// `NSWorkspace` — no state, no caching.
enum EditorLauncher {

    // MARK: - Known editor bundle ids

    private static let cursorEditorBundleIdentifier = "com.todesktop.230313mzl4w4u92"
    private static let vsCodeEditorBundleIdentifier = "com.microsoft.VSCode"
    private static let vsCodeInsidersEditorBundleIdentifier = "com.microsoft.VSCodeInsiders"

    // MARK: - Result type

    /// Describes what actually happened during the launch attempt so
    /// the orchestrator can surface a matching status message.
    enum LaunchOutcome {
        /// Launched the preferred editor via its CLI shim. Supports
        /// opening at a specific line.
        case launchedViaCommandLineShim(editorDisplayName: String)
        /// Launched the preferred editor via `open -b <bundle-id>`.
        /// File was opened but line navigation isn't supported in
        /// this path.
        case launchedViaOpenCommand(editorDisplayName: String)
        /// Fell through to `NSWorkspace.open(fileURL)` — the file
        /// opened in whatever app the user has configured as the
        /// default, which may or may not be an editor at all.
        case launchedViaSystemDefaultHandler
        /// No file was provided or the file didn't exist — opened
        /// just the repo root in Finder as a best-effort fallback.
        case openedRepoRootOnly
    }

    // MARK: - Public entry point

    /// Attempts to open the target file in the author's preferred
    /// editor, falling through to Cursor → VS Code → system default.
    ///
    /// - `repoRootURL`: absolute path of the prepared (cloned +
    ///   checked-out) repository.
    /// - `repoRelativeOpenPath`: path relative to the repo root, as
    ///   stored in `GuideContext.openPath`. Nil when the guide
    ///   doesn't identify a specific file.
    /// - `openAtLineNumber`: 1-based line number within the file.
    ///   Only honored when the selected editor supports it via CLI.
    /// - `preferredEditorBundleIdentifier`: bundle id of whatever
    ///   editor the author was using at record time. Honored only
    ///   if that editor is actually installed on the receiver.
    static func launchPreferredEditor(
        repoRootURL: URL,
        repoRelativeOpenPath: String?,
        openAtLineNumber: Int?,
        preferredEditorBundleIdentifier: String?
    ) async -> LaunchOutcome {
        let absoluteFileToOpenURL: URL? = {
            guard let openPath = repoRelativeOpenPath, !openPath.isEmpty else { return nil }
            let candidateURL = repoRootURL.appendingPathComponent(openPath)
            guard FileManager.default.fileExists(atPath: candidateURL.path) else {
                LogGuru.warning(
                    "EditorLauncher: repo-relative path \(openPath) doesn't exist in \(repoRootURL.path)",
                    category: .guided,
                    privacy: .private
                )
                return nil
            }
            return candidateURL
        }()

        // Build an ordered list of editors to try. The author's
        // preferred editor (if installed) comes first; Cursor and
        // VS Code follow as second-chance fallbacks unless they're
        // already the preferred editor.
        var orderedEditorCandidates: [EditorCandidate] = []

        if let authorPreferredBundleId = preferredEditorBundleIdentifier {
            if let preferredCandidate = editorCandidate(forBundleIdentifier: authorPreferredBundleId) {
                orderedEditorCandidates.append(preferredCandidate)
            }
        }

        // Add Cursor / VS Code as fallbacks, skipping whichever (if
        // any) is already in the list as the preferred editor.
        let alreadyQueuedBundleIds = Set(orderedEditorCandidates.map { $0.bundleIdentifier })
        for fallbackBundleId in [cursorEditorBundleIdentifier, vsCodeEditorBundleIdentifier, vsCodeInsidersEditorBundleIdentifier] {
            guard !alreadyQueuedBundleIds.contains(fallbackBundleId) else { continue }
            if let fallbackCandidate = editorCandidate(forBundleIdentifier: fallbackBundleId) {
                orderedEditorCandidates.append(fallbackCandidate)
            }
        }

        // Try each candidate in order. The first one that launches
        // successfully wins. If the file doesn't exist we still open
        // the editor at the repo root — better than bailing out and
        // showing nothing.
        for candidateEditor in orderedEditorCandidates {
            let launchURL = absoluteFileToOpenURL ?? repoRootURL
            if await tryLaunchingEditor(
                candidateEditor,
                openingAbsoluteURL: launchURL,
                atLineNumber: absoluteFileToOpenURL != nil ? openAtLineNumber : nil,
                repoRootURL: repoRootURL
            ) {
                return .launchedViaCommandLineShim(editorDisplayName: candidateEditor.displayName)
            }
        }

        // All known editors failed or none are installed. Try the
        // system default handler for the file type.
        if let fileURL = absoluteFileToOpenURL {
            if NSWorkspace.shared.open(fileURL) {
                LogGuru.notice(
                    "EditorLauncher: opened \(fileURL.path) via NSWorkspace default handler",
                    category: .guided,
                    privacy: .private
                )
                return .launchedViaSystemDefaultHandler
            }
        }

        // Absolute last resort: reveal the repo root in Finder so
        // the user at least sees where the prepared repo lives.
        NSWorkspace.shared.open(repoRootURL)
        LogGuru.warning(
            "EditorLauncher: no editor could open the target file; opened repo root in Finder",
            category: .guided,
            privacy: .private
        )
        return .openedRepoRootOnly
    }

    // MARK: - Editor candidate table

    /// A single editor we know how to launch. `commandLineShimPath`
    /// is the expected filesystem path of the editor's CLI tool
    /// inside its bundle, or nil when the editor doesn't ship one.
    private struct EditorCandidate {
        let bundleIdentifier: String
        let displayName: String
        /// Relative path from the .app bundle to the CLI shim, or
        /// nil if the editor doesn't have one.
        let relativeCLIShimPath: String?
    }

    /// Returns a candidate struct for the given bundle id IF the
    /// editor is actually installed. Nil means "not installed" and
    /// the caller should move on to the next fallback.
    private static func editorCandidate(forBundleIdentifier bundleId: String) -> EditorCandidate? {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil else {
            return nil
        }

        switch bundleId {
        case cursorEditorBundleIdentifier:
            return EditorCandidate(
                bundleIdentifier: cursorEditorBundleIdentifier,
                displayName: "Cursor",
                relativeCLIShimPath: "Contents/Resources/app/bin/cursor"
            )
        case vsCodeEditorBundleIdentifier:
            return EditorCandidate(
                bundleIdentifier: vsCodeEditorBundleIdentifier,
                displayName: "Visual Studio Code",
                relativeCLIShimPath: "Contents/Resources/app/bin/code"
            )
        case vsCodeInsidersEditorBundleIdentifier:
            return EditorCandidate(
                bundleIdentifier: vsCodeInsidersEditorBundleIdentifier,
                displayName: "Visual Studio Code - Insiders",
                relativeCLIShimPath: "Contents/Resources/app/bin/code-insiders"
            )
        default:
            // Editor we don't have a CLI shim path for (e.g. Xcode,
            // Zed). We'll still attempt to launch it via `open -b`
            // but can't pass a line number.
            return EditorCandidate(
                bundleIdentifier: bundleId,
                displayName: bundleId,
                relativeCLIShimPath: nil
            )
        }
    }

    // MARK: - Launch attempts

    /// Tries to launch the given editor candidate on the given URL.
    /// Returns true on success so the caller can stop iterating.
    ///
    /// Strategy:
    ///   1. If the editor has a CLI shim AND we have a line number,
    ///      use `<shim> -g <file>:<line>` — supports cursor-line jump.
    ///   2. If the editor has a CLI shim (no line number), use
    ///      `<shim> <path>` — opens the repo / file without jumping.
    ///   3. Fall back to `/usr/bin/open -b <bundle-id> <path>` which
    ///      works for any installed app but doesn't support line
    ///      navigation.
    private static func tryLaunchingEditor(
        _ editorCandidate: EditorCandidate,
        openingAbsoluteURL openTargetURL: URL,
        atLineNumber lineNumber: Int?,
        repoRootURL: URL
    ) async -> Bool {
        if let relativeShimPath = editorCandidate.relativeCLIShimPath,
           let applicationBundleURL = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: editorCandidate.bundleIdentifier
           ) {
            let absoluteShimURL = applicationBundleURL.appendingPathComponent(relativeShimPath)
            if FileManager.default.isExecutableFile(atPath: absoluteShimURL.path) {
                // Build the arguments. We always open the repo root
                // first (so the editor's workspace is set), then the
                // file with `-g file:line` so the cursor jumps. If we
                // only have the root, just open the root.
                var shimArguments: [String] = []
                if openTargetURL.path == repoRootURL.path {
                    shimArguments = [repoRootURL.path]
                } else {
                    // -r forces reuse of an existing window rather
                    // than spawning a new one, which is what the
                    // author's flow expects. The first argument is
                    // the workspace folder; the second jumps to the
                    // file.
                    shimArguments = ["-r", repoRootURL.path]
                    if let lineNumber = lineNumber, lineNumber > 0 {
                        shimArguments.append("-g")
                        shimArguments.append("\(openTargetURL.path):\(lineNumber)")
                    } else {
                        shimArguments.append("-g")
                        shimArguments.append(openTargetURL.path)
                    }
                }

                let didRunSuccessfully = await runExecutableIgnoringOutput(
                    executableURL: absoluteShimURL,
                    arguments: shimArguments
                )
                if didRunSuccessfully {
                    LogGuru.notice(
                        "EditorLauncher: launched \(editorCandidate.displayName) via CLI shim with \(shimArguments.joined(separator: " "))",
                        category: .guided,
                        privacy: .private
                    )
                    return true
                }
            }
        }

        // Fall through to `open -b <bundle-id>` for editors without
        // a CLI shim or when the shim wasn't executable.
        let openBinaryURL = URL(fileURLWithPath: "/usr/bin/open")
        let openCommandArguments = [
            "-b",
            editorCandidate.bundleIdentifier,
            openTargetURL.path,
        ]
        let didRunSuccessfully = await runExecutableIgnoringOutput(
            executableURL: openBinaryURL,
            arguments: openCommandArguments
        )
        if didRunSuccessfully {
            LogGuru.notice(
                "EditorLauncher: launched \(editorCandidate.displayName) via `open -b` (no line navigation)",
                category: .guided,
                privacy: .private
            )
            return true
        }

        return false
    }

    /// Runs an external process and returns true on zero-exit. Used
    /// for editor launches where we don't care about stdout — we
    /// just want to know whether the launch succeeded. Runs on a
    /// detached task so the UI stays responsive during the ~50–200ms
    /// spawn.
    private static func runExecutableIgnoringOutput(
        executableURL: URL,
        arguments processArguments: [String]
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let runningProcess = Process()
            runningProcess.executableURL = executableURL
            runningProcess.arguments = processArguments
            runningProcess.standardOutput = Pipe()
            runningProcess.standardError = Pipe()
            do {
                try runningProcess.run()
                runningProcess.waitUntilExit()
                return runningProcess.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}
