//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        LogGuru.notice("Clicky starting", category: .app)
        LogGuru.info(
            "Clicky version \(appVersion)",
            category: .app
        )

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Handles `clicky://` deep links. The app is registered for the
    /// `clicky` URL scheme via `CFBundleURLTypes` in Info.plist, so
    /// clicking a `clicky://guide?id=...` link anywhere on macOS (email,
    /// Slack, browser) routes back here to open the target guide.
    ///
    /// Currently only `clicky://guide?id=<guide_id>` is supported. The
    /// guide is fetched from the Worker's `/guide/:id` route, loaded
    /// into `GuidedSessionManager`, and the menu bar panel is opened
    /// so the user can hit Play.
    func application(_ application: NSApplication, open incomingURLs: [URL]) {
        for singleURL in incomingURLs {
            handleIncomingDeepLink(singleURL)
        }
    }

    private func handleIncomingDeepLink(_ deepLinkURL: URL) {
        LogGuru.notice(
            "Received deep link \(deepLinkURL.absoluteString)",
            category: .app,
            privacy: .private
        )

        guard deepLinkURL.scheme == "clicky" else {
            LogGuru.warning(
                "Unsupported URL scheme \(deepLinkURL.scheme ?? "nil")",
                category: .app
            )
            return
        }

        guard deepLinkURL.host == "guide" else {
            LogGuru.warning(
                "Unsupported deep link host \(deepLinkURL.host ?? "nil")",
                category: .app
            )
            return
        }

        guard let urlComponents = URLComponents(url: deepLinkURL, resolvingAgainstBaseURL: false),
              let queryItems = urlComponents.queryItems,
              let guideIDQueryItem = queryItems.first(where: { $0.name == "id" }),
              let guideIDFromDeepLink = guideIDQueryItem.value,
              !guideIDFromDeepLink.isEmpty else {
            LogGuru.warning(
                "Deep link missing id query parameter",
                category: .app
            )
            return
        }

        // Open the menu bar panel so the user can see the loading /
        // ready state and hit Play once the fetch completes.
        menuBarPanelManager?.showPanelOnLaunch()

        Task { @MainActor in
            do {
                try await companionManager.guidedSessionManager.loadGuide(
                    fromRemoteID: guideIDFromDeepLink
                )
                LogGuru.info(
                    "Guide \(guideIDFromDeepLink) loaded from deep link and is ready to play",
                    category: .guided,
                    privacy: .private
                )
            } catch {
                LogGuru.error(
                    "Failed to load guide \(guideIDFromDeepLink) from deep link: \(error.localizedDescription)",
                    category: .guided,
                    privacy: .private
                )
            }
        }
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                LogGuru.notice("Registered as login item", category: .app)
            } catch {
                LogGuru.error(
                    "Failed to register as login item: \(error.localizedDescription)",
                    category: .app
                )
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            LogGuru.error(
                "Sparkle updater failed to start: \(error.localizedDescription)",
                category: .app
            )
        }
    }
}
