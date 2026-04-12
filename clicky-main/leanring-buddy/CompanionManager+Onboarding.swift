//
//  CompanionManager+Onboarding.swift
//  leanring-buddy
//
//  Email capture, onboarding media, and the pointing demo sequence.
//

import AppKit
import AVFoundation
import Foundation
import PostHog
import SwiftUI

extension CompanionManager {
    /// Submits the user's email to the configured capture endpoint and
    /// identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        guard let emailCaptureSubmitURLString = AppBundleConfiguration.stringValue(forKey: "EmailCaptureSubmitURL"),
              let emailCaptureSubmitURL = URL(string: emailCaptureSubmitURLString) else {
            return
        }

        Task {
            var request = URLRequest(url: emailCaptureSubmitURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()
        startOnboardingMusic()
        showOnboardingOverlay()
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        showOnboardingOverlay(resetFirstAppearance: true)
    }

    func dismissOnboardingPromptIfNeeded() {
        guard showOnboardingPrompt else { return }

        withAnimation(.easeOut(duration: 0.3)) {
            onboardingPromptOpacity = 0.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.showOnboardingPrompt = false
            self.onboardingPromptText = ""
        }
    }

    func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    func startOnboardingMusic() {
        stopOnboardingMusic()

        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            LogGuru.error(
                "Onboarding music ff.mp3 not found in bundle",
                category: .onboarding
            )
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s.
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            LogGuru.error(
                "Failed to play onboarding music: \(error.localizedDescription)",
                category: .onboarding
            )
        }
    }

    func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var remainingFadeSteps = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            remainingFadeSteps -= 1
            player.volume -= volumeDecrement

            if remainingFadeSteps <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        onboardingVideoPlayer = player
        showOnboardingVideo = true
        onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false

        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }

        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil

        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()

                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }

            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var remainingSteps = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            remainingSteps -= 1
            player.volume += volumeIncrement

            if remainingSteps <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL LOCATION RULE: you MUST only pick elements clearly in the central area of the screen. do NOT pick anything in the menu bar, the dock, any sidebar, or anywhere near the edges of the screen. only things visibly in the middle. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the target tag. nothing else. all lowercase.

    format: your comment [TARGET:label]

    where label is a specific, visually distinctive description of the element (like "blue save button" or "xcode project navigator icon"). a separate visual grounding model will find the exact pixel coordinates on the screenshot — you just describe the element clearly.
    """

    /// Captures a screenshot and asks OpenAI to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so OpenAI can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    LogGuru.warning(
                        "Onboarding demo could not find the cursor screen",
                        category: .onboarding
                    )
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await openAIAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let targetParseResult = Self.parseTargetElementLabel(from: fullResponseText)

                guard let targetElementLabel = targetParseResult.elementLabel else {
                    LogGuru.warning(
                        "Onboarding demo response did not include a target element",
                        category: .onboarding
                    )
                    return
                }

                guard let groundedScreenshotCoordinate = await molmoWebClient.groundElement(
                    screenshotData: cursorScreenCapture.imageData,
                    elementLabel: targetElementLabel,
                    screenshotWidthInPixels: cursorScreenCapture.screenshotWidthInPixels,
                    screenshotHeightInPixels: cursorScreenCapture.screenshotHeightInPixels
                ) else {
                    LogGuru.warning(
                        "Onboarding demo could not ground target \"\(targetElementLabel)\"",
                        category: .onboarding,
                        privacy: .private
                    )
                    return
                }

                let globalScreenLocation = mapGroundedCoordinateToGlobalScreenLocation(
                    groundedScreenshotCoordinate,
                    in: cursorScreenCapture
                )

                detectedElementBubbleText = targetParseResult.spokenText
                detectedElementScreenLocation = globalScreenLocation
                detectedElementDisplayFrame = cursorScreenCapture.displayFrame
                LogGuru.info(
                    "Onboarding demo pointing at \"\(targetElementLabel)\" — \"\(targetParseResult.spokenText)\"",
                    category: .onboarding,
                    privacy: .private
                )
            } catch {
                LogGuru.error(
                    "Onboarding demo error: \(error.localizedDescription)",
                    category: .onboarding
                )
            }
        }
    }
}
