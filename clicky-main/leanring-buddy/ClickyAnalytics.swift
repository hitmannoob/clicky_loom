//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Centralized PostHog analytics wrapper. All event names and properties
//  are defined here so instrumentation is consistent and easy to audit.
//

import Foundation
import PostHog

enum ClickyAnalytics {

    // MARK: - Setup

    static func configure() {
        let config = PostHogConfig(
            apiKey: "phc_xcQPygmhTMzzYh8wNW92CCwoXmnzqyChAixh8zgpqC3C",
            host: "https://us.i.posthog.com"
        )
        PostHogSDK.shared.setup(config)
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        PostHogSDK.shared.capture("app_opened", properties: [
            "app_version": version
        ])
    }

    // MARK: - Onboarding

    /// User clicked the Start button to begin onboarding for the first time.
    static func trackOnboardingStarted() {
        PostHogSDK.shared.capture("onboarding_started")
    }

    /// User clicked "Watch Onboarding Again" from the panel footer.
    static func trackOnboardingReplayed() {
        PostHogSDK.shared.capture("onboarding_replayed")
    }

    /// The onboarding video finished playing to the end.
    static func trackOnboardingVideoCompleted() {
        PostHogSDK.shared.capture("onboarding_video_completed")
    }

    /// The 40s onboarding demo interaction where Clicky points at something.
    static func trackOnboardingDemoTriggered() {
        PostHogSDK.shared.capture("onboarding_demo_triggered")
    }

    // MARK: - Permissions

    /// All three permissions (accessibility, screen recording, mic) are granted.
    static func trackAllPermissionsGranted() {
        PostHogSDK.shared.capture("all_permissions_granted")
    }

    /// A single permission was granted. Called when polling detects a change.
    static func trackPermissionGranted(permission: String) {
        PostHogSDK.shared.capture("permission_granted", properties: [
            "permission": permission
        ])
    }

    // MARK: - Voice Interaction

    /// User pressed the push-to-talk shortcut (control+option) to start talking.
    static func trackPushToTalkStarted() {
        PostHogSDK.shared.capture("push_to_talk_started")
    }

    /// User released the shortcut — transcript is being finalized.
    static func trackPushToTalkReleased() {
        PostHogSDK.shared.capture("push_to_talk_released")
    }

    /// Transcription completed and the user's message is being sent to the AI.
    static func trackUserMessageSent(transcript: String) {
        PostHogSDK.shared.capture("user_message_sent", properties: [
            "transcript": transcript,
            "character_count": transcript.count
        ])
    }

    /// The AI responded and the response is being spoken via TTS.
    static func trackAIResponseReceived(response: String) {
        PostHogSDK.shared.capture("ai_response_received", properties: [
            "response": response,
            "character_count": response.count
        ])
    }

    /// The AI's response included a [TARGET:label] tag,
    /// so the buddy is flying to point at a UI element.
    static func trackElementPointed(elementLabel: String?) {
        PostHogSDK.shared.capture("element_pointed", properties: [
            "element_label": elementLabel ?? "unknown"
        ])
    }

    // MARK: - Errors

    /// An error occurred during the AI response pipeline.
    static func trackResponseError(error: String) {
        PostHogSDK.shared.capture("response_error", properties: [
            "error": error
        ])
    }

    /// An error occurred during TTS playback.
    static func trackTTSError(error: String) {
        PostHogSDK.shared.capture("tts_error", properties: [
            "error": error
        ])
    }

    // MARK: - Guided Mode Playback

    /// A guided walkthrough started playing for the user (User B side).
    static func trackGuideStarted(guideID: String) {
        PostHogSDK.shared.capture("guide_started", properties: [
            "guide_id": guideID
        ])
    }

    /// A single step in a guided walkthrough completed (either
    /// auto-advanced via screen match, or manually via push-to-talk,
    /// or timed out). Fires once per step.
    static func trackGuideStepCompleted(guideID: String, stepID: String) {
        PostHogSDK.shared.capture("guide_step_completed", properties: [
            "guide_id": guideID,
            "step_id": stepID
        ])
    }

    /// The auto-advance timeout fired on a step and Clicky spoke the
    /// `stuck_hint`. Useful for tracking which steps trip users up.
    static func trackGuideStuck(guideID: String, stepID: String) {
        PostHogSDK.shared.capture("guide_stuck", properties: [
            "guide_id": guideID,
            "step_id": stepID
        ])
    }

    /// A guided walkthrough finished playing all its steps.
    static func trackGuideCompleted(guideID: String) {
        PostHogSDK.shared.capture("guide_completed", properties: [
            "guide_id": guideID
        ])
    }

    // MARK: - Guided Mode Recording (User A)

    /// User A tapped the Record Guide button and started capturing
    /// audio + periodic screenshots.
    static func trackGuideRecordingStarted() {
        PostHogSDK.shared.capture("guide_recording_started")
    }

    /// User A stopped the in-flight recording. Doesn't mean it's
    /// uploaded yet — processing happens in the background queue.
    static func trackGuideRecordingStopped(stepCount: Int) {
        PostHogSDK.shared.capture("guide_recording_stopped", properties: [
            "step_count": stepCount
        ])
    }

    /// A recorded guide finished post-processing and was saved to
    /// the repo's `.clicky/` directory (or a user-chosen location).
    static func trackGuideSaved(filePath: String, stepCount: Int) {
        PostHogSDK.shared.capture("guide_saved", properties: [
            "file_path": filePath,
            "step_count": stepCount
        ])
    }
}
