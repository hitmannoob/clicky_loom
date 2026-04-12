//
//  AppBundleConfiguration.swift
//  leanring-buddy
//
//  Shared helper for reading runtime configuration from the built app bundle,
//  process environment, and the repo-root `.env` file during local development.
//

import Foundation

enum AppBundleConfiguration {
    private static let sourceFileURL = URL(fileURLWithPath: #filePath)

    private static let environmentVariableNamesByConfigurationKey: [String: [String]] = [
        "WorkerBaseURL": ["CLICKY_WORKER_BASE_URL"],
        "MolmoWebServerURL": ["CLICKY_MOLMO_BASE_URL"],
        "MolmoWebAPIKey": ["CLICKY_MOLMO_API_KEY"],
        "EmailCaptureSubmitURL": ["CLICKY_EMAIL_CAPTURE_SUBMIT_URL"],
        "OpenAIAPIKey": ["OPENAI_API_KEY", "CLICKY_OPENAI_API_KEY"],
        "OpenAITranscriptionModel": ["OPENAI_TRANSCRIPTION_MODEL"],
        "VoiceTranscriptionProvider": ["VOICE_TRANSCRIPTION_PROVIDER"],
    ]

    private static let localEnvironmentValues: [String: String] = {
        guard let localEnvironmentFileURL = findLocalEnvironmentFileURL() else {
            return [:]
        }

        guard let localEnvironmentFileContents = try? String(contentsOf: localEnvironmentFileURL, encoding: .utf8) else {
            return [:]
        }

        return parseEnvironmentFileContents(localEnvironmentFileContents)
    }()

    static func stringValue(forKey key: String) -> String? {
        for environmentVariableName in environmentVariableNames(forConfigurationKey: key) {
            if let runtimeEnvironmentValue = normalizedValue(from: ProcessInfo.processInfo.environment[environmentVariableName]) {
                return runtimeEnvironmentValue
            }

            if let localEnvironmentValue = normalizedValue(from: localEnvironmentValues[environmentVariableName]) {
                return localEnvironmentValue
            }
        }

        if let infoDictionaryValue = normalizedValue(
            from: Bundle.main.object(forInfoDictionaryKey: key) as? String
        ) {
            return infoDictionaryValue
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath),
              let resourceInfoValue = normalizedValue(from: resourceInfo[key] as? String) else {
            return nil
        }

        return resourceInfoValue
    }

    private static func environmentVariableNames(forConfigurationKey key: String) -> [String] {
        var environmentVariableNames = environmentVariableNamesByConfigurationKey[key] ?? []
        if !environmentVariableNames.contains(key) {
            environmentVariableNames.append(key)
        }
        return environmentVariableNames
    }

    private static func normalizedValue(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            return nil
        }

        if trimmedValue.hasPrefix("\""), trimmedValue.hasSuffix("\""), trimmedValue.count >= 2 {
            return String(trimmedValue.dropFirst().dropLast())
        }

        return trimmedValue
    }

    private static func findLocalEnvironmentFileURL() -> URL? {
        let searchStartDirectories = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            sourceFileURL.deletingLastPathComponent(),
            Bundle.main.bundleURL.deletingLastPathComponent(),
        ]

        for searchStartDirectory in searchStartDirectories {
            if let localEnvironmentFileURL = firstEnvironmentFileURL(startingAt: searchStartDirectory) {
                return localEnvironmentFileURL
            }
        }

        return nil
    }

    private static func firstEnvironmentFileURL(startingAt startDirectory: URL) -> URL? {
        var currentDirectoryURL = startDirectory

        while true {
            let candidateEnvironmentFileURL = currentDirectoryURL.appendingPathComponent(".env")
            if FileManager.default.fileExists(atPath: candidateEnvironmentFileURL.path) {
                return candidateEnvironmentFileURL
            }

            let parentDirectoryURL = currentDirectoryURL.deletingLastPathComponent()
            if parentDirectoryURL.path == currentDirectoryURL.path {
                return nil
            }

            currentDirectoryURL = parentDirectoryURL
        }
    }

    private static func parseEnvironmentFileContents(_ fileContents: String) -> [String: String] {
        var parsedValues: [String: String] = [:]

        for rawLine in fileContents.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
                continue
            }

            let cleanedLine: String
            if trimmedLine.hasPrefix("export ") {
                cleanedLine = String(trimmedLine.dropFirst("export ".count))
            } else {
                cleanedLine = trimmedLine
            }

            guard let equalsIndex = cleanedLine.firstIndex(of: "=") else {
                continue
            }

            let key = cleanedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let valueStartIndex = cleanedLine.index(after: equalsIndex)
            let value = cleanedLine[valueStartIndex...].trimmingCharacters(in: .whitespacesAndNewlines)

            if !key.isEmpty {
                parsedValues[key] = value
            }
        }

        return parsedValues
    }
}
