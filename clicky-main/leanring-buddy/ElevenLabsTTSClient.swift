//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  **NOTE**: despite the class name, this now speaks via macOS's built-in
//  `AVSpeechSynthesizer` instead of ElevenLabs. ElevenLabs' free tier kept
//  flagging our Cloudflare Worker requests as "unusual activity" (401
//  detected_unusual_activity) because proxied requests look like abuse to
//  their detector. For the prototype we swapped the implementation body to
//  the system synthesizer — free, offline, zero auth, robotic voice.
//
//  The class name, file name, and init signature are intentionally kept so
//  CompanionManager and the rest of the app stay unchanged. If/when
//  ElevenLabs gets restored (e.g., after upgrading to a Starter plan), swap
//  the body back to hit the `/tts` Worker endpoint.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    /// macOS built-in speech synthesizer. Lives as long as this client so
    /// its playback isn't killed by garbage collection mid-utterance.
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// `proxyURL` is accepted for interface compatibility with the earlier
    /// ElevenLabs-through-Cloudflare implementation but is intentionally
    /// unused now that speech runs locally on-device.
    init(proxyURL: String) {
        _ = proxyURL
    }

    /// Speaks `text` via the system synthesizer. Returns once speech has
    /// actually started (not when it finishes) so the caller can transition
    /// to `.responding` state and then poll `isPlaying` to detect completion.
    func speakText(_ text: String) async throws {
        LogGuru.debug(
            "System TTS speaking \(text.count) chars via AVSpeechSynthesizer",
            category: .companion
        )

        // Stop any in-progress utterance so back-to-back push-to-talk
        // presses don't queue up and over-speak each other.
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)

        // US English voice at a slightly snappier-than-default rate so the
        // response feels like a buddy talking, not a Carbon-era reader.
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        speechSynthesizer.speak(utterance)

        // `AVSpeechSynthesizer.speak(_:)` schedules the utterance and returns
        // immediately — `isSpeaking` may still be false for a few ms. Sleep
        // briefly so that by the time the caller's `while isPlaying` loop
        // starts polling, the synthesizer reliably reports playback in
        // progress.
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// Whether the synthesizer is currently speaking. Polled by the transient
    /// cursor fade-out logic in `CompanionManager` to keep the overlay alive
    /// until playback finishes.
    var isPlaying: Bool {
        speechSynthesizer.isSpeaking
    }

    /// Stops any in-progress utterance immediately. Called when the user
    /// starts a new push-to-talk session mid-playback.
    func stopPlayback() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }
}
