//
//  OpenAIAPI.swift
//  OpenAI API implementation with streaming support
//
//  Mirrors the streaming + non-streaming shape of the legacy chat client
//  but speaks OpenAI's Chat Completions JSON and SSE format. All requests
//  go through the Cloudflare Worker proxy so the OpenAI API key never
//  ships in the app binary.
//

import Foundation

/// OpenAI Chat Completions API helper with streaming for progressive text display.
/// Routes through the Cloudflare Worker proxy (`POST /chat`) which forwards to
/// `https://api.openai.com/v1/chat/completions` and injects the `OPENAI_API_KEY`
/// header server-side.
class OpenAIAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL: URL
    var model: String
    private let session: URLSession

    init(proxyURL: String, model: String = "gpt-5.4-mini") {
        self.apiURL = URL(string: proxyURL)!
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        // Hitting the host instead of `/chat` avoids extra endpoint-specific noise.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Builds the OpenAI Chat Completions JSON request body.
    /// Used by both the streaming and non-streaming call sites so the shape
    /// (messages, vision content blocks, model name) stays consistent.
    private func buildRequestBody(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        shouldStream: Bool,
        maxCompletionTokens: Int
    ) -> [String: Any] {
        var messages: [[String: Any]] = []

        // OpenAI takes the system prompt as the first message in the array.
        messages.append([
            "role": "system",
            "content": systemPrompt
        ])

        // Add prior conversation turns so the model remembers earlier exchanges
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build the current user message with all labeled images + the user prompt.
        // OpenAI vision accepts a content array where each element is either a
        // text block or an image_url block carrying a base64 data URL.
        var currentUserContentBlocks: [[String: Any]] = []
        for image in images {
            currentUserContentBlocks.append([
                "type": "text",
                "text": image.label
            ])
            currentUserContentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(image.data.base64EncodedString())"
                ]
            ])
        }
        currentUserContentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": currentUserContentBlocks])

        var body: [String: Any] = [
            "model": model,
            // `max_tokens` is deprecated/incompatible for newer OpenAI models.
            "max_completion_tokens": maxCompletionTokens,
            "messages": messages
        ]
        if shouldStream {
            body["stream"] = true
        }
        return body
    }

    /// Send a vision request to OpenAI with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()

        let body = buildRequestBody(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            shouldStream: true,
            maxCompletionTokens: 1024
        )

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        LogGuru.info(
            "OpenAI streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)",
            category: .network
        )

        // Use bytes streaming for SSE (Server-Sent Events)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenAIAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        // If non-2xx status, read the full body as error text
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            LogGuru.error(
                "OpenAI streaming request failed — HTTP \(httpResponse.statusCode)",
                category: .network
            )
            LogGuru.error(
                "OpenAI error body: \(errorBody)",
                category: .network,
                privacy: .private
            )
            throw NSError(
                domain: "OpenAIAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        LogGuru.notice(
            "OpenAI streaming response: HTTP \(httpResponse.statusCode) — reading SSE stream",
            category: .network
        )

        // Parse OpenAI SSE stream — each event is "data: {json}\n"
        // Chunk shape: {"choices":[{"delta":{"content":"..."}, "finish_reason":null}]}
        // Terminal sentinel: "data: [DONE]"
        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            // SSE lines look like: "data: {...}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) // Drop "data: " prefix

            // End of stream marker
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = eventPayload["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any] else {
                continue
            }

            // The `content` field may be missing on the first/last chunk (role or finish_reason only)
            // or be an empty string. Only forward non-empty text chunks.
            if let textChunk = delta["content"] as? String, !textChunk.isEmpty {
                accumulatedResponseText += textChunk
                // Send the accumulated text so far to the UI for progressive rendering
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()

        let body = buildRequestBody(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            shouldStream: false,
            maxCompletionTokens: 600
        )

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        LogGuru.info(
            "OpenAI request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)",
            category: .network
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            LogGuru.error(
                "OpenAI request failed — HTTP \(statusCode)",
                category: .network
            )
            LogGuru.error(
                "OpenAI error body: \(responseString)",
                category: .network,
                privacy: .private
            )
            throw NSError(
                domain: "OpenAIAPI",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }
        LogGuru.notice(
            "OpenAI response: HTTP \(httpResponse.statusCode)",
            category: .network
        )

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(
                domain: "OpenAIAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}

// MARK: - Guided mode vision helpers

/// Guide-mode vision calls layered on top of `analyzeImage`. These live
/// in an extension (not the core class) so the networking layer stays
/// focused on raw request/response and guide-specific prompts are
/// grouped together in one place.
///
/// All three methods return parsed, typed results (`Bool`, `CGPoint?`)
/// rather than raw text so callers don't need to know the prompt
/// contract. If parsing fails or the HTTP call throws, they return a
/// "safe" value (false for yes/no checks, nil for grounding) rather
/// than propagating the error — guided playback should degrade
/// gracefully when OpenAI hiccups, not crash mid-session.
extension OpenAIAPI {
    /// Asks OpenAI whether the live screenshot matches a natural-language
    /// condition (optionally against a reference screenshot for context).
    /// Used by `GuidedSessionManager` to decide when to auto-advance from
    /// one step to the next.
    ///
    /// Returns `true` if the model answers YES, `false` otherwise. On
    /// error (network failure, unparseable response, etc.) returns
    /// `false` — the auto-advance loop will simply try again on the
    /// next poll.
    func checkScreenMatch(
        liveScreenshotData: Data,
        referenceScreenshotData: Data?,
        advanceCondition: String
    ) async -> Bool {
        let systemPromptText = """
        You are a screen state checker for a guided walkthrough app. You \
        receive the user's current screenshot and a natural-language \
        condition. If a reference screenshot is also provided, use it for \
        visual context — the user's screen will not look identical to the \
        reference (different resolution, theme, window sizes are normal), \
        but the key UI state should match.

        Answer with EXACTLY "YES" or "NO". No punctuation, no explanation, \
        no other words. A single token is the entire response.
        """

        let userPromptText = """
        Condition to check: "\(advanceCondition)"

        Does the user's current screen satisfy this condition? Answer YES or NO.
        """

        var imageInputs: [(data: Data, label: String)] = []
        if let referenceScreenshotData {
            imageInputs.append((
                data: referenceScreenshotData,
                label: "Reference screenshot (what the guide author saw)"
            ))
        }
        imageInputs.append((
            data: liveScreenshotData,
            label: "User's current screen"
        ))

        do {
            let (responseText, _) = try await analyzeImage(
                images: imageInputs,
                systemPrompt: systemPromptText,
                userPrompt: userPromptText
            )
            let normalizedResponse = responseText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let didMatch = normalizedResponse.contains("YES") && !normalizedResponse.contains("NO")
            LogGuru.debug(
                "Screen match check: condition=\"\(advanceCondition)\" → \(didMatch ? "YES" : "NO") (raw=\"\(normalizedResponse.prefix(40))\")",
                category: .guided,
                privacy: .private
            )
            return didMatch
        } catch {
            LogGuru.warning(
                "Screen match check failed: \(error.localizedDescription)",
                category: .guided
            )
            return false
        }
    }

    /// Structured output for `generateGuideStep` — the raw JSON the
    /// model returns in response_format=json_object, decoded into a
    /// typed value. `GuideUploadQueue` uses this to build each step
    /// of a recorded guide from its (screenshot, transcript-chunk)
    /// pair.
    struct GeneratedGuideStep {
        /// Polished one- or two-sentence voice narration, rewritten
        /// from the user's raw transcript chunk. Reads naturally as
        /// TTS — no markdown, no filler.
        let narrationText: String

        /// Short description of the UI element the user is pointing
        /// at, or nil if the step isn't targeting anything specific.
        let pointElementLabel: String?

        /// One of "auto", "manual", or "timed". Matches
        /// `StepAdvance.AdvanceMode` raw values.
        let advanceModeString: String

        /// Natural-language condition to check for auto-advance.
        /// Nil for manual/timed steps.
        let advanceConditionText: String?

        /// Optional hint to speak when the user gets stuck.
        let stuckHintText: String?
    }

    /// Takes one (screenshot, transcript-chunk) pair from a recording
    /// and asks OpenAI to produce the structured data needed to
    /// populate a `GuideStep`: polished narration, element label,
    /// advance mode + condition, and an optional stuck hint.
    ///
    /// Uses `response_format: json_object` so the model emits parseable
    /// JSON instead of free-form text. Returns nil on any failure —
    /// the upload queue can decide whether to retry or skip the step.
    func generateGuideStep(
        screenshotData: Data,
        transcriptChunkText: String,
        stepIndexInGuide: Int,
        totalStepCountInGuide: Int
    ) async -> GeneratedGuideStep? {
        let systemPromptText = """
        You are a guide-step generator for a macOS guided walkthrough app. \
        You are given one screenshot of the user's screen and one chunk of \
        what the user said out loud while that screenshot was captured. \
        Your job is to produce the structured data for a single step in a \
        walkthrough guide that another user will play back later.

        You MUST respond with a single valid JSON object and nothing else. \
        The JSON object must have exactly these fields:

          {
            "narration": string,
            "point_element_label": string | null,
            "advance_mode": "auto" | "manual" | "timed",
            "advance_condition": string | null,
            "stuck_hint": string | null
          }

        Field rules:

        - `narration`: rewrite the user's spoken words as one or two short, \
          natural, lowercase sentences that will be read aloud by TTS. Keep \
          it under ~30 words. No markdown, no quotes, no filler words like \
          "um" or "so".

        - `point_element_label`: a short description of the UI element the \
          user is interacting with in this step (e.g. "the blue Save \
          button", "the search input field at the top"). Set to null if \
          this is a read-only or navigation step that doesn't target a \
          specific element.

        - `advance_mode`: choose one:
            * "auto" — if completing the step produces a clearly visible \
              change on screen that another person could confirm visually \
              (e.g. a new page loads, a dialog opens, a field gets text).
            * "manual" — if the step requires the user to do something \
              Clicky can't reliably verify from a screenshot (e.g. "open \
              calculator from spotlight", "read this paragraph").
            * "timed" — for info-only steps with no user action required.

        - `advance_condition`: if `advance_mode` is "auto", describe what \
          the screen should look like when the step is complete, as a \
          natural-language sentence (e.g. "the calculator displays a 5"). \
          Set to null for manual or timed steps.

        - `stuck_hint`: one short sentence of help if the user gets stuck, \
          or null if the step is simple enough not to need one.

        You are generating step \(stepIndexInGuide + 1) of \(totalStepCountInGuide).
        """

        let userPromptText = """
        The user said: "\(transcriptChunkText)"

        Generate the step JSON based on that transcript chunk and the \
        screenshot of what the user was looking at.
        """

        let imageInputs: [(data: Data, label: String)] = [
            (data: screenshotData, label: "user's screen at the time they spoke this")
        ]

        do {
            let (rawResponseText, _) = try await analyzeImageWithJSONResponse(
                images: imageInputs,
                systemPrompt: systemPromptText,
                userPrompt: userPromptText
            )
            return parseGeneratedGuideStepJSON(rawResponseText)
        } catch {
            LogGuru.warning(
                "generateGuideStep failed for step \(stepIndexInGuide + 1): \(error.localizedDescription)",
                category: .guided
            )
            return nil
        }
    }

    /// Parses the raw JSON text OpenAI returned into a
    /// `GeneratedGuideStep` value. Returns nil if any required field
    /// is missing or malformed — the upload queue will log and skip.
    private func parseGeneratedGuideStepJSON(_ rawResponseText: String) -> GeneratedGuideStep? {
        // Some OpenAI responses wrap the JSON in ```json fences even
        // when you ask for json_object mode. Strip those defensively.
        var jsonBodyString = rawResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonBodyString.hasPrefix("```") {
            if let firstNewlineIndex = jsonBodyString.firstIndex(of: "\n") {
                jsonBodyString = String(jsonBodyString[jsonBodyString.index(after: firstNewlineIndex)...])
            }
            if jsonBodyString.hasSuffix("```") {
                jsonBodyString = String(jsonBodyString.dropLast(3))
            }
            jsonBodyString = jsonBodyString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let jsonBodyData = jsonBodyString.data(using: .utf8),
              let parsedJSONDictionary = try? JSONSerialization.jsonObject(with: jsonBodyData) as? [String: Any] else {
            LogGuru.warning(
                "generateGuideStep could not parse JSON response: \(jsonBodyString.prefix(200))",
                category: .guided,
                privacy: .private
            )
            return nil
        }

        guard let narrationTextFromModel = parsedJSONDictionary["narration"] as? String,
              !narrationTextFromModel.isEmpty else {
            LogGuru.warning(
                "generateGuideStep response missing narration",
                category: .guided
            )
            return nil
        }

        let pointElementLabelFromModel = parsedJSONDictionary["point_element_label"] as? String
        let advanceModeStringFromModel = (parsedJSONDictionary["advance_mode"] as? String) ?? "manual"
        let advanceConditionFromModel = parsedJSONDictionary["advance_condition"] as? String
        let stuckHintFromModel = parsedJSONDictionary["stuck_hint"] as? String

        return GeneratedGuideStep(
            narrationText: narrationTextFromModel,
            pointElementLabel: (pointElementLabelFromModel?.isEmpty ?? true) ? nil : pointElementLabelFromModel,
            advanceModeString: advanceModeStringFromModel,
            advanceConditionText: (advanceConditionFromModel?.isEmpty ?? true) ? nil : advanceConditionFromModel,
            stuckHintText: (stuckHintFromModel?.isEmpty ?? true) ? nil : stuckHintFromModel
        )
    }

    /// Low-level helper used by `generateGuideStep` — runs the same
    /// non-streaming vision call as `analyzeImage` but sets
    /// `response_format: {"type": "json_object"}` so the model is
    /// forced to emit valid JSON. Kept private because its prompt
    /// contract is specific to guide-step generation.
    private func analyzeImageWithJSONResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build messages using the same shape as buildRequestBody, but
        // with json_object response format tacked on. We don't reuse
        // buildRequestBody because it doesn't expose a way to override
        // response_format, and duplicating a short message array is
        // cleaner than adding a parameter with one caller.
        var messagesArray: [[String: Any]] = []
        messagesArray.append(["role": "system", "content": systemPrompt])

        var currentUserContentBlocks: [[String: Any]] = []
        for imageEntry in images {
            currentUserContentBlocks.append(["type": "text", "text": imageEntry.label])
            currentUserContentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(imageEntry.data.base64EncodedString())"
                ]
            ])
        }
        currentUserContentBlocks.append(["type": "text", "text": userPrompt])
        messagesArray.append(["role": "user", "content": currentUserContentBlocks])

        let requestBodyDictionary: [String: Any] = [
            "model": model,
            "max_completion_tokens": 600,
            "messages": messagesArray,
            "response_format": ["type": "json_object"]
        ]

        let requestBodyData = try JSONSerialization.data(withJSONObject: requestBodyDictionary)
        request.httpBody = requestBodyData

        let (responseData, rawResponse) = try await session.data(for: request)
        guard let httpResponse = rawResponse as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseBodyString = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            let statusCode = (rawResponse as? HTTPURLResponse)?.statusCode ?? -1
            LogGuru.error(
                "OpenAI guide-step request failed — HTTP \(statusCode)",
                category: .network
            )
            LogGuru.error(
                "OpenAI error body: \(responseBodyString.prefix(300))",
                category: .network,
                privacy: .private
            )
            throw NSError(
                domain: "OpenAIAPI",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseBodyString)"]
            )
        }

        let parsedResponseJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        guard let choicesArray = parsedResponseJSON?["choices"] as? [[String: Any]],
              let firstChoiceDictionary = choicesArray.first,
              let messageDictionary = firstChoiceDictionary["message"] as? [String: Any],
              let responseContentText = messageDictionary["content"] as? String else {
            throw NSError(
                domain: "OpenAIAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid guide-step response format"]
            )
        }

        let totalDurationSeconds = Date().timeIntervalSince(startTime)
        return (text: responseContentText, duration: totalDurationSeconds)
    }

    /// Compares two screenshots taken a few seconds apart and asks
    /// OpenAI whether the user has made meaningful progress on the
    /// expected action. Used by `GuidedSessionManager` after the
    /// `timeout_seconds` fires on an auto-advance step, to decide
    /// whether to speak the `stuck_hint`.
    ///
    /// Returns `true` if the model thinks the user is stuck (no
    /// progress). Returns `false` on error so we don't nag the user
    /// with a stuck hint they didn't ask for.
    func detectStuck(
        previousScreenshotData: Data,
        currentScreenshotData: Data,
        expectedActionDescription: String
    ) async -> Bool {
        let systemPromptText = """
        You are a progress detector for a guided walkthrough app. You \
        see two screenshots of the same user taken a few seconds apart, \
        plus a description of the action they were expected to take.

        Decide whether the user made meaningful progress toward the \
        expected action between the two screenshots. Small cursor \
        moves, hover states, or scroll position changes on unrelated \
        UI do NOT count as progress — progress means the user clicked, \
        typed, navigated, or otherwise moved closer to completing the \
        action.

        Answer with EXACTLY "PROGRESS" or "STUCK". No other words.
        """

        let userPromptText = """
        Expected action: "\(expectedActionDescription)"

        Did the user make progress between these two screenshots? Answer \
        PROGRESS or STUCK.
        """

        let imageInputs: [(data: Data, label: String)] = [
            (data: previousScreenshotData, label: "Earlier screenshot"),
            (data: currentScreenshotData, label: "Current screenshot")
        ]

        do {
            let (responseText, _) = try await analyzeImage(
                images: imageInputs,
                systemPrompt: systemPromptText,
                userPrompt: userPromptText
            )
            let normalizedResponse = responseText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let isStuck = normalizedResponse.contains("STUCK") && !normalizedResponse.contains("PROGRESS")
            LogGuru.debug(
                "Stuck detection: expected=\"\(expectedActionDescription)\" → \(isStuck ? "STUCK" : "PROGRESS") (raw=\"\(normalizedResponse.prefix(40))\")",
                category: .guided,
                privacy: .private
            )
            return isStuck
        } catch {
            LogGuru.warning(
                "Stuck detection failed: \(error.localizedDescription)",
                category: .guided
            )
            return false
        }
    }
}
