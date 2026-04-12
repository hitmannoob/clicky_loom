//
//  RepoWorkspaceResolver.swift
//  leanring-buddy
//
//  Persistent memory of "which local folder does this guide's repo
//  live in on this receiver's machine" for the Phase 2 validation-gate
//  flow (`Clicky_Codebase_Distribution_Spec_v1.md` §10).
//
//  Refactor note (was Phase 2 scan-and-clone, now validation-gate):
//  this file used to auto-scan a default clone root (`~/Clicky-Repos`)
//  for existing repos matching the guide's remote URL and, on miss,
//  drive a clone flow with a destination picker. All of that was
//  deleted because the receiver now runs clone / checkout / fetch in
//  their own terminal — Clicky only observes + validates.
//
//  What remains is tiny: a per-remote-URL lookup table persisted in
//  UserDefaults. When `WorkspacePreparationCoordinator` needs to
//  validate a guide, it asks this resolver for a remembered folder.
//  On first run for a given repo the resolver has no memory, so the
//  coordinator shows an `NSOpenPanel` asking the user to pick the
//  local clone. Once validated (origin URL matches the guide's
//  target), the folder is remembered for next time.
//
//  Storage format (UserDefaults `com.clicky.workspace.repoFolderPathsByNormalizedRemoteURL`):
//
//      {
//        "github.com/org/repo":     "/Users/dev/src/repo",
//        "github.com/org/other":    "/Users/dev/code/other",
//        ...
//      }
//
//  Keys are the normalized-for-matching form produced by
//  `normalizeRemoteURLForMatching` so the lookup is robust against
//  the receiver's guide carrying a slightly different URL form than
//  what the author recorded (https vs ssh, trailing .git, etc.).
//

import Foundation

/// Static helper that remembers where each guide's target repo lives
/// on the receiver's machine, keyed by normalized remote URL.
enum RepoWorkspaceResolver {

    // MARK: - Storage

    /// UserDefaults key for the `[normalizedRemoteURL: folderPath]`
    /// dictionary that persists the user's picks across app launches.
    private static let userDefaultsKeyForRepoFolderMap =
        "com.clicky.workspace.repoFolderPathsByNormalizedRemoteURL"

    /// Reads the current `[normalizedRemoteURL: folderPath]` map from
    /// UserDefaults. Returns an empty dict when the key doesn't exist
    /// yet (first run) or when the stored value isn't the expected
    /// shape (unlikely — we only ever write this same shape).
    private static func loadPersistedRepoFolderMap() -> [String: String] {
        guard let storedDictionary = UserDefaults.standard.dictionary(
            forKey: userDefaultsKeyForRepoFolderMap
        ) as? [String: String] else {
            return [:]
        }
        return storedDictionary
    }

    /// Writes the given `[normalizedRemoteURL: folderPath]` map back
    /// to UserDefaults. Overwrites whatever was stored before.
    private static func savePersistedRepoFolderMap(_ updatedMap: [String: String]) {
        UserDefaults.standard.set(updatedMap, forKey: userDefaultsKeyForRepoFolderMap)
    }

    // MARK: - Lookup

    /// Returns the absolute folder URL where the receiver previously
    /// confirmed the guide's repo lives, or nil if we've never seen
    /// this repo before (or the user previously forgot it).
    ///
    /// Does NOT verify that the folder still exists on disk — the
    /// caller is expected to call `GitRepositoryClient.originRemoteURLString`
    /// on the returned URL to confirm it's still a valid clone of the
    /// expected repo. If the folder was moved/deleted since it was
    /// remembered, validation will fail and the caller re-prompts.
    static func rememberedRepoFolderURL(
        forGuideContext guideContext: GuideContext
    ) -> URL? {
        guard guideContext.type == .repo else { return nil }
        let normalizedTargetURL = normalizeRemoteURLForMatching(guideContext.target)
        guard !normalizedTargetURL.isEmpty else { return nil }

        let persistedMap = loadPersistedRepoFolderMap()
        guard let storedFolderPath = persistedMap[normalizedTargetURL],
              !storedFolderPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: storedFolderPath, isDirectory: true)
    }

    // MARK: - Remembering

    /// Writes a new `normalizedRemoteURL → folderPath` entry into
    /// the persistent map. Called by `WorkspacePreparationCoordinator`
    /// after the NSOpenPanel-picked folder has been validated as
    /// actually being a clone of the expected repo.
    static func rememberRepoFolderURL(
        _ folderURLToRemember: URL,
        forGuideContext guideContext: GuideContext
    ) {
        guard guideContext.type == .repo else { return }
        let normalizedTargetURL = normalizeRemoteURLForMatching(guideContext.target)
        guard !normalizedTargetURL.isEmpty else { return }

        var persistedMap = loadPersistedRepoFolderMap()
        persistedMap[normalizedTargetURL] = folderURLToRemember.path
        savePersistedRepoFolderMap(persistedMap)

        LogGuru.notice(
            "RepoWorkspaceResolver remembered \(normalizedTargetURL) → \(folderURLToRemember.path)",
            category: .guided,
            privacy: .private
        )
    }

    /// Removes the remembered folder for the given guide context.
    /// Called when the user clicks "Pick different folder" in the
    /// validation mismatch UI — forces the next validation pass to
    /// re-prompt via NSOpenPanel.
    static func forgetRepoFolderURL(forGuideContext guideContext: GuideContext) {
        guard guideContext.type == .repo else { return }
        let normalizedTargetURL = normalizeRemoteURLForMatching(guideContext.target)
        guard !normalizedTargetURL.isEmpty else { return }

        var persistedMap = loadPersistedRepoFolderMap()
        persistedMap.removeValue(forKey: normalizedTargetURL)
        savePersistedRepoFolderMap(persistedMap)

        LogGuru.info(
            "RepoWorkspaceResolver forgot remembered folder for \(normalizedTargetURL)",
            category: .guided,
            privacy: .private
        )
    }

    // MARK: - URL normalization

    /// Collapses a git remote URL to a canonical form suitable for
    /// equality matching. Handles:
    ///
    ///   - `git@github.com:org/repo.git`    (ssh short form)
    ///   - `ssh://git@github.com/org/repo`  (ssh long form)
    ///   - `https://github.com/org/repo.git`
    ///   - `https://github.com/org/repo`
    ///
    /// All of the above normalize to `github.com/org/repo`. Unknown
    /// forms are returned lowercased with the trailing `.git`
    /// stripped, which is at least a lossless best effort.
    ///
    /// The normalized form is intentionally NOT a valid URL — it's a
    /// comparison key, not something you'd pass to `git clone`.
    static func normalizeRemoteURLForMatching(_ rawRemoteURLText: String) -> String {
        let trimmedText = rawRemoteURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return "" }

        var workingText = trimmedText

        // Lowercase everything. GitHub paths are case-insensitive in
        // practice and the risk of a false negative on a rare
        // case-sensitive host is small.
        workingText = workingText.lowercased()

        // Strip scheme prefixes.
        if workingText.hasPrefix("https://") {
            workingText = String(workingText.dropFirst("https://".count))
        } else if workingText.hasPrefix("http://") {
            workingText = String(workingText.dropFirst("http://".count))
        } else if workingText.hasPrefix("ssh://") {
            workingText = String(workingText.dropFirst("ssh://".count))
        } else if workingText.hasPrefix("git://") {
            workingText = String(workingText.dropFirst("git://".count))
        }

        // Strip `git@` prefix from SSH URLs and translate the first
        // `:` into `/` so the short form `git@github.com:org/repo`
        // matches the long form `github.com/org/repo`.
        if workingText.hasPrefix("git@") {
            workingText = String(workingText.dropFirst("git@".count))
            if let firstColonIndex = workingText.firstIndex(of: ":") {
                workingText.replaceSubrange(firstColonIndex...firstColonIndex, with: "/")
            }
        }

        // Strip user info for http(s) forms like `user@github.com/...`
        // that might sneak in from credential-helpered URLs.
        if let atSignIndex = workingText.firstIndex(of: "@"),
           let firstSlashIndex = workingText.firstIndex(of: "/"),
           atSignIndex < firstSlashIndex {
            workingText = String(workingText[workingText.index(after: atSignIndex)...])
        }

        // Strip trailing `.git`
        if workingText.hasSuffix(".git") {
            workingText = String(workingText.dropLast(".git".count))
        }

        // Strip trailing slashes
        while workingText.hasSuffix("/") {
            workingText = String(workingText.dropLast())
        }

        return workingText
    }
}
