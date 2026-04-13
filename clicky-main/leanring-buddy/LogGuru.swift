//
//  LogGuru.swift
//  leanring-buddy
//
//  Lightweight project-local wrapper around Apple's unified logging so
//  call sites can move off `print` without taking a third-party dependency.
//

import Foundation
import OSLog

enum LogGuru {
    enum Category: String {
        case app
        case companion
        case permissions
        case onboarding
        case guided
        case transcription
        case vision
        case network
        case recording
        case shortcut
    }

    enum Privacy {
        case `public`
        case `private`

        var osLogPrivacy: OSLogPrivacy {
            switch self {
            case .public:
                return .public
            case .private:
                return .private
            }
        }
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "clicky"

    private static let appLogger = Logger(subsystem: subsystem, category: Category.app.rawValue)
    private static let companionLogger = Logger(subsystem: subsystem, category: Category.companion.rawValue)
    private static let permissionsLogger = Logger(subsystem: subsystem, category: Category.permissions.rawValue)
    private static let onboardingLogger = Logger(subsystem: subsystem, category: Category.onboarding.rawValue)
    private static let guidedLogger = Logger(subsystem: subsystem, category: Category.guided.rawValue)
    private static let transcriptionLogger = Logger(subsystem: subsystem, category: Category.transcription.rawValue)
    private static let visionLogger = Logger(subsystem: subsystem, category: Category.vision.rawValue)
    private static let networkLogger = Logger(subsystem: subsystem, category: Category.network.rawValue)
    private static let recordingLogger = Logger(subsystem: subsystem, category: Category.recording.rawValue)
    private static let shortcutLogger = Logger(subsystem: subsystem, category: Category.shortcut.rawValue)

    static func debug(
        _ message: @autoclosure () -> String,
        category: Category = .app,
        privacy: Privacy = .public
    ) {
        let msg = message()
        switch privacy {
        case .public:
            logger(for: category).debug("\(msg, privacy: .public)")
        case .private:
            logger(for: category).debug("\(msg, privacy: .private)")
        }
    }

    static func info(
        _ message: @autoclosure () -> String,
        category: Category = .app,
        privacy: Privacy = .public
    ) {
        let msg = message()
        switch privacy {
        case .public:
            logger(for: category).info("\(msg, privacy: .public)")
        case .private:
            logger(for: category).info("\(msg, privacy: .private)")
        }
    }

    static func notice(
        _ message: @autoclosure () -> String,
        category: Category = .app,
        privacy: Privacy = .public
    ) {
        let msg = message()
        switch privacy {
        case .public:
            logger(for: category).notice("\(msg, privacy: .public)")
        case .private:
            logger(for: category).notice("\(msg, privacy: .private)")
        }
    }

    static func warning(
        _ message: @autoclosure () -> String,
        category: Category = .app,
        privacy: Privacy = .public
    ) {
        let msg = message()
        switch privacy {
        case .public:
            logger(for: category).warning("\(msg, privacy: .public)")
        case .private:
            logger(for: category).warning("\(msg, privacy: .private)")
        }
    }

    static func error(
        _ message: @autoclosure () -> String,
        category: Category = .app,
        privacy: Privacy = .public
    ) {
        let msg = message()
        switch privacy {
        case .public:
            logger(for: category).error("\(msg, privacy: .public)")
        case .private:
            logger(for: category).error("\(msg, privacy: .private)")
        }
    }

    private static func logger(for category: Category) -> Logger {
        switch category {
        case .app:
            return appLogger
        case .companion:
            return companionLogger
        case .permissions:
            return permissionsLogger
        case .onboarding:
            return onboardingLogger
        case .guided:
            return guidedLogger
        case .transcription:
            return transcriptionLogger
        case .vision:
            return visionLogger
        case .network:
            return networkLogger
        case .recording:
            return recordingLogger
        case .shortcut:
            return shortcutLogger
        }
    }
}
