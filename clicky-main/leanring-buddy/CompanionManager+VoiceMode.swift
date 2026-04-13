//
//  CompanionManager+VoiceMode.swift
//  leanring-buddy
//
//  Push-to-talk bindings, response generation, and target-tag parsing.
//

import AppKit
import Combine
import Foundation

extension CompanionManager {
    func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }

                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard voiceState != .responding else { return }

                if isFinalizing {
                    voiceState = .processing
                } else if isRecording {
                    voiceState = .listening
                } else if isPreparing {
                    voiceState = .processing
                } else {
                    voiceState = .idle

                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if currentResponseTask == nil {
                        scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            guard !showOnboardingVideo else { return }

            // If a guided session is sitting on a manual-advance step,
            // hijack the push-to-talk press to advance the guide
            // instead of starting a recording. This is how Ctrl+Option
            // doubles as the "Next" control during guided playback.
            if guidedSessionManager.shouldInterceptPushToTalkForManualAdvance {
                guidedSessionManager.advanceManually()
                return
            }

            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction.
            if !isClickyCursorEnabled && !isOverlayVisible {
                showPersistentOverlay()
            }

            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()
            dismissOnboardingPromptIfNeeded()

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI).
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        LogGuru.notice(
                            "Companion received transcript: \(finalTranscript)",
                            category: .companion,
                            privacy: .private
                        )
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToOpenAIWithScreenshot(transcript: finalTranscript)
                    }
                )
            }

        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()

        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you want to point at an element, append a target tag at the very end of your response, AFTER your spoken text. a separate visual grounding model looks at the screenshot and finds the exact pixel location, so you don't need to figure out coordinates yourself — you just need to describe the element clearly and specifically.

    format: [TARGET:label] where label is a specific, visually distinctive description of the UI element (like "search bar", "color inspector button in toolbar", "source control menu"). be descriptive enough that someone looking at the screenshot could find exactly the right element — include context like "in the toolbar", "in the left sidebar", or the element's color if helpful. if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [TARGET:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [TARGET:color inspector button in toolbar]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [TARGET:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [TARGET:source control menu in toolbar]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [TARGET:terminal window:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to OpenAI,
    /// and plays the response aloud via system TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// OpenAI's response may include a [TARGET:label] tag naming a UI element;
    /// MolmoWeb then grounds that label to pixel coordinates so
    /// the buddy can fly to the element on screen.
    ///
    /// Phase 3 follow-along: when a guided session is actively playing
    /// (speaking narration, waiting to advance, stuck, or completing),
    /// this function swaps in the guide-aware system prompt built by
    /// `GuidedSessionManager.currentGuidedFollowAlongSystemPrompt()`
    /// and skips the shared conversation history so guided Q&A
    /// doesn't leak into push-to-talk memory. Everything else (image
    /// capture, streaming, target-tag parsing, MolmoWeb grounding,
    /// TTS) stays identical between the generic and guided flows.
    func sendTranscriptToOpenAIWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        // Decide up-front whether this push-to-talk press is a
        // follow-along question against an active guided session or
        // a regular companion interaction. Captured once so the
        // decision stays stable across the async pipeline below.
        let guidedFollowAlongSystemPrompt = guidedSessionManager.currentGuidedFollowAlongSystemPrompt()
        let isActingAsGuidedFollowAlongAssistant = guidedFollowAlongSystemPrompt != nil

        currentResponseTask = Task {
            voiceState = .processing

            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so the grounding coordinate space matches the image OpenAI sees.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Guided follow-along questions run stateless — each
                // question is a fresh exchange scoped to the current
                // step. Push-to-talk questions reuse the companion's
                // rolling history so multi-turn conversations work.
                let historyForAPI: [(userPlaceholder: String, assistantResponse: String)]
                if isActingAsGuidedFollowAlongAssistant {
                    historyForAPI = []
                } else {
                    historyForAPI = conversationHistory.map { entry in
                        (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                    }
                }

                let systemPromptForThisRequest = guidedFollowAlongSystemPrompt
                    ?? Self.companionVoiceResponseSystemPrompt

                let (fullResponseText, _) = try await openAIAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: systemPromptForThisRequest,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays.
                    }
                )

                guard !Task.isCancelled else { return }

                let targetParseResult = Self.parseTargetElementLabel(from: fullResponseText)
                let spokenText = targetParseResult.spokenText

                let targetScreenCapture = preferredTargetScreenCapture(
                    from: screenCaptures,
                    specifiedScreenNumber: targetParseResult.screenNumber
                )

                var groundedScreenshotCoordinate: CGPoint?
                if let targetElementLabel = targetParseResult.elementLabel,
                   let targetScreenCapture {
                    groundedScreenshotCoordinate = await molmoWebClient.groundElement(
                        screenshotData: targetScreenCapture.imageData,
                        elementLabel: targetElementLabel,
                        screenshotWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
                        screenshotHeightInPixels: targetScreenCapture.screenshotHeightInPixels
                    )
                }

                guard !Task.isCancelled else { return }

                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                if groundedScreenshotCoordinate != nil {
                    voiceState = .idle
                }

                if let groundedScreenshotCoordinate,
                   let targetScreenCapture {
                    let globalScreenLocation = mapGroundedCoordinateToGlobalScreenLocation(
                        groundedScreenshotCoordinate,
                        in: targetScreenCapture
                    )

                    detectedElementScreenLocation = globalScreenLocation
                    detectedElementDisplayFrame = targetScreenCapture.displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: targetParseResult.elementLabel)
                    LogGuru.info(
                        "Element pointing: (\(Int(groundedScreenshotCoordinate.x)), \(Int(groundedScreenshotCoordinate.y))) → \"\(targetParseResult.elementLabel ?? "element")\"",
                        category: .vision,
                        privacy: .private
                    )
                } else if let targetElementLabel = targetParseResult.elementLabel {
                    LogGuru.warning(
                        "Element pointing failed to ground target \"\(targetElementLabel)\"",
                        category: .vision,
                        privacy: .private
                    )
                } else {
                    LogGuru.debug(
                        "Element pointing skipped because no target was requested",
                        category: .vision
                    )
                }

                // Guided follow-along exchanges are stateless for
                // v1 — don't append them to the shared companion
                // history so "where am i?" from a guided session
                // doesn't leak into the next push-to-talk prompt
                // and vice versa.
                if !isActingAsGuidedFollowAlongAssistant {
                    rememberConversationExchange(
                        userTranscript: transcript,
                        assistantResponse: spokenText
                    )
                }

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText)
                        voiceState = .responding
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        LogGuru.error(
                            "ElevenLabs TTS error: \(error.localizedDescription)",
                            category: .companion
                        )
                        speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted.
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                LogGuru.error(
                    "Companion response error: \(error.localizedDescription)",
                    category: .companion
                )
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    func speakCreditsErrorFallback() {
        let utterance = "I'm all out of credits. Please DM Farza and tell him to bring me back to life."
        let speechSynthesizer = NSSpeechSynthesizer()
        speechSynthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    func preferredTargetScreenCapture(
        from screenCaptures: [CompanionScreenCapture],
        specifiedScreenNumber: Int?
    ) -> CompanionScreenCapture? {
        if let specifiedScreenNumber,
           specifiedScreenNumber >= 1 && specifiedScreenNumber <= screenCaptures.count {
            return screenCaptures[specifiedScreenNumber - 1]
        }
        return screenCaptures.first(where: { $0.isCursorScreen })
    }

    func mapGroundedCoordinateToGlobalScreenLocation(
        _ groundedScreenshotCoordinate: CGPoint,
        in screenCapture: CompanionScreenCapture
    ) -> CGPoint {
        let screenshotWidthInPixels = CGFloat(screenCapture.screenshotWidthInPixels)
        let screenshotHeightInPixels = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidthInPoints = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeightInPoints = CGFloat(screenCapture.displayHeightInPoints)
        let displayFrame = screenCapture.displayFrame

        // Clamp to screenshot coordinate space.
        let clampedScreenshotX = max(0, min(groundedScreenshotCoordinate.x, screenshotWidthInPixels))
        let clampedScreenshotY = max(0, min(groundedScreenshotCoordinate.y, screenshotHeightInPixels))

        // Scale from screenshot pixels to display points.
        let displayLocalX = clampedScreenshotX * (displayWidthInPoints / screenshotWidthInPixels)
        let displayLocalYTopOrigin = clampedScreenshotY * (displayHeightInPoints / screenshotHeightInPixels)

        // Convert from top-left origin (screenshot) to bottom-left origin (AppKit).
        let displayLocalYBottomOrigin = displayHeightInPoints - displayLocalYTopOrigin

        // Convert display-local coords to global screen coords.
        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: displayLocalYBottomOrigin + displayFrame.origin.y
        )
    }

    func rememberConversationExchange(userTranscript: String, assistantResponse: String) {
        conversationHistory.append((
            userTranscript: userTranscript,
            assistantResponse: assistantResponse
        ))

        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }

        LogGuru.debug(
            "Conversation history size: \(conversationHistory.count) exchanges",
            category: .companion
        )
    }

    // MARK: - Target Tag Parsing

    /// Result of parsing a [TARGET:...] tag from the model's response.
    /// The tag carries an element *label* — a human-readable description of
    /// the UI element — but NOT pixel coordinates. MolmoWeb is responsible
    /// for turning the label into actual pixel coordinates via a separate
    /// grounding call against the live screenshot.
    struct TargetElementParseResult {
        /// The response text with the [TARGET:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// Short label describing the element (e.g. "source control menu in toolbar"),
        /// or nil if the model said "none" or no tag was present.
        let elementLabel: String?
        /// Which screen the element is on (1-based), or nil to default to the cursor's screen.
        let screenNumber: Int?
    }

    /// Parses a [TARGET:label:screenN] or [TARGET:none] tag from the end of the model's response.
    /// Returns the spoken text (tag removed) and the optional element label + screen number.
    /// The caller is responsible for passing the label to MolmoWeb to obtain pixel coordinates.
    static func parseTargetElementLabel(from responseText: String) -> TargetElementParseResult {
        let targetTagPattern = #"\[TARGET:(?:none|([^\]]+?)(?::screen(\d+))?)\]\s*$"#

        guard let targetTagRegex = try? NSRegularExpression(pattern: targetTagPattern, options: []),
              let regexMatch = targetTagRegex.firstMatch(
                in: responseText,
                range: NSRange(responseText.startIndex..., in: responseText)
              ) else {
            return TargetElementParseResult(
                spokenText: responseText,
                elementLabel: nil,
                screenNumber: nil
            )
        }

        let tagRange = Range(regexMatch.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var elementLabel: String?
        if regexMatch.numberOfRanges >= 2,
           let labelRange = Range(regexMatch.range(at: 1), in: responseText) {
            let extractedLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
            if !extractedLabel.isEmpty {
                elementLabel = extractedLabel
            }
        }

        var screenNumber: Int?
        if regexMatch.numberOfRanges >= 3,
           let screenRange = Range(regexMatch.range(at: 2), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return TargetElementParseResult(
            spokenText: spokenText,
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }
}
