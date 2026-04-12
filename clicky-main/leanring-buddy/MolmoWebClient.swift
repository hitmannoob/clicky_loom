//
//  MolmoWebClient.swift
//  leanring-buddy
//
//  Client for a remote MolmoWeb-4B visual grounding server hosted on Modal.
//
//  MolmoWeb-4B is Allen AI's open-weight web agent model. We adapt it to
//  UI element grounding by framing each request as a one-shot "Click the X"
//  task and parsing pixel coordinates out of MolmoWeb's THOUGHT/ACTION
//  response. MolmoWeb is significantly more accurate at pointing at UI
//  elements than general-purpose vision APIs (OpenAI, Gemini) which is
//  why we do this two-step split (OpenAI for chat/narration, MolmoWeb
//  only for coordinate localization).
//
//  Deployment: the user runs `modal deploy modal/molmoweb.py` which spins
//  up a Modal function serving HuggingFace Transformers with MolmoWeb-4B
//  loaded via `trust_remote_code=True`. The server exposes two endpoints:
//
//      GET  <url>/health   — liveness probe, no auth, doesn't load model
//      POST <url>/ground   — Bearer auth, runs inference, returns raw text
//
//  Graceful degradation: if the Modal endpoint is unreachable, misconfigured,
//  or returns a parse-failing response, `groundElement` returns nil and the
//  caller should treat that as "don't point at anything" — the narration
//  still plays via TTS.
//
//  Why a custom API shape (not OpenAI-compatible): we tried vLLM's
//  OpenAI-compatible server first, but vLLM's multimodal model registry
//  doesn't recognize MolmoWeb-4B's `Molmo2` architecture and refused to
//  load it as a multimodal model. Pivoting to direct Transformers meant
//  writing our own thin HTTP wrapper, so we went with a purpose-built
//  endpoint shape rather than emulating OpenAI chat completions on top.
//

import Foundation

/// Remote visual grounding client. Routes element-localization requests to
/// a MolmoWeb-4B model served by HuggingFace Transformers on Modal.
///
/// This is intentionally the ONLY thing this class does — it's not a general
/// LLM client. For text generation and reasoning we use OpenAI; this client
/// only answers "where is the UI element labeled X in this screenshot?".
@MainActor
final class MolmoWebClient {
    /// True when the Modal endpoint has responded successfully to a recent
    /// `/health` probe. Checked on app start via `checkAvailability()`,
    /// re-checked lazily whenever the caller wants to retry after a failure.
    private(set) var isAvailable = false

    private let modalServerBaseURL: URL
    private let bearerAPIKey: String
    private let session: URLSession

    init(
        vllmBaseURL: URL,
        vllmAPIKey: String
    ) {
        // Parameter names kept as `vllmBaseURL`/`vllmAPIKey` for continuity
        // with the earlier vLLM-based deployment, even though we're now
        // serving via raw Transformers. Not worth rotating the constant
        // names in CompanionManager for the rename.
        self.modalServerBaseURL = vllmBaseURL
        self.bearerAPIKey = vllmAPIKey

        // Generous timeouts — the Modal endpoint is remote, and the first
        // request after a scale-to-zero cold start can take 30-60 seconds
        // to load the 16 GB model into GPU memory.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Availability

    /// Probes the Modal server's `/health` endpoint (no auth required) and
    /// marks the client as available on 2xx. Does NOT trigger a model load
    /// on the server — the first `groundElement` call does that. Safe to
    /// call repeatedly.
    func checkAvailability() async {
        // Skip the probe entirely if the base URL is still a placeholder —
        // there's no point making a network call we know will fail.
        if modalServerBaseURL.host?.contains("your-username") == true ||
           modalServerBaseURL.host?.contains("replace-me") == true {
            isAvailable = false
            LogGuru.notice(
                "MolmoWeb base URL is still a placeholder; grounding is disabled until CLICKY_MOLMO_BASE_URL is configured",
                category: .vision
            )
            return
        }

        var healthRequest = URLRequest(
            url: modalServerBaseURL.appendingPathComponent("/health")
        )
        healthRequest.httpMethod = "GET"
        healthRequest.timeoutInterval = 90

        do {
            let (responseData, rawResponse) = try await session.data(for: healthRequest)
            guard let httpResponse = rawResponse as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (rawResponse as? HTTPURLResponse)?.statusCode ?? -1
                isAvailable = false
                LogGuru.warning(
                    "MolmoWeb health probe returned HTTP \(statusCode); grounding disabled",
                    category: .vision
                )
                return
            }

            // Parse `{"status":"ok","model":"...","model_loaded":true|false}`.
            // We only require status=ok — model_loaded can be false on a
            // fresh cold start and will flip to true after the first call.
            if let parsedJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let statusString = parsedJSON["status"] as? String,
               statusString == "ok" {
                isAvailable = true
                let modelLoadedFlag = parsedJSON["model_loaded"] as? Bool ?? false
                LogGuru.notice(
                    "MolmoWeb available at \(modalServerBaseURL.absoluteString) (model_loaded=\(modelLoadedFlag))",
                    category: .vision
                )
            } else {
                isAvailable = false
                LogGuru.warning(
                    "MolmoWeb health probe response did not match the expected shape",
                    category: .vision
                )
            }
        } catch {
            isAvailable = false
            LogGuru.warning(
                "MolmoWeb health probe failed at \(modalServerBaseURL.absoluteString); grounding disabled: \(error.localizedDescription)",
                category: .vision
            )
        }
    }

    // MARK: - Element grounding

    /// Asks MolmoWeb to locate the UI element matching `elementLabel` on the
    /// supplied screenshot, and returns its pixel coordinates in the
    /// screenshot's coordinate space (top-left origin).
    ///
    /// Returns nil when:
    /// - the endpoint is not available (isAvailable == false)
    /// - the HTTP call fails, times out, or returns non-2xx
    /// - MolmoWeb's response cannot be parsed into a coordinate
    ///
    /// The caller is responsible for scaling the pixel coordinates from the
    /// screenshot space to display points and flipping from top-left to
    /// bottom-left origin for AppKit.
    func groundElement(
        screenshotData: Data,
        elementLabel: String,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) async -> CGPoint? {
        guard isAvailable else { return nil }

        let base64Screenshot = screenshotData.base64EncodedString()
        let requestBody: [String: Any] = [
            "screenshot_base64": base64Screenshot,
            "element_label": elementLabel,
        ]

        var groundingRequest = URLRequest(
            url: modalServerBaseURL.appendingPathComponent("/ground")
        )
        groundingRequest.httpMethod = "POST"
        groundingRequest.timeoutInterval = 120
        groundingRequest.setValue("Bearer \(bearerAPIKey)", forHTTPHeaderField: "Authorization")
        groundingRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            groundingRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

            let (responseData, rawResponse) = try await session.data(for: groundingRequest)
            guard let httpResponse = rawResponse as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (rawResponse as? HTTPURLResponse)?.statusCode ?? -1
                let errorBody = String(data: responseData, encoding: .utf8) ?? "unknown"
                LogGuru.error(
                    "MolmoWeb ground API error HTTP \(statusCode): \(errorBody.prefix(200))",
                    category: .vision,
                    privacy: .private
                )
                return nil
            }

            // The server returns `{"raw_output": "..."}` — we do our own
            // coordinate parsing on the Swift side so we can iterate on the
            // parser without redeploying the Modal container.
            guard let parsedJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let rawOutputText = parsedJSON["raw_output"] as? String else {
                LogGuru.error(
                    "MolmoWeb could not parse ground response",
                    category: .vision
                )
                return nil
            }

            LogGuru.debug(
                "MolmoWeb raw output for \"\(elementLabel)\": \(rawOutputText.prefix(200))",
                category: .vision,
                privacy: .private
            )

            return parseCoordinateFromResponseText(
                modelResponseText: rawOutputText,
                elementLabel: elementLabel,
                screenshotWidthInPixels: screenshotWidthInPixels,
                screenshotHeightInPixels: screenshotHeightInPixels
            )
        } catch {
            LogGuru.error(
                "MolmoWeb ground request failed: \(error.localizedDescription)",
                category: .vision
            )
            return nil
        }
    }

    // MARK: - Response parsing

    /// Extracts pixel coordinates from MolmoWeb's raw generated text.
    ///
    /// Three formats are supported, tried in order of how frequently we
    /// actually see them in MolmoWeb-4B's output:
    ///
    ///   1. **Click-action JSON** (what MolmoWeb-4B's "pointing:" mode
    ///      actually emits — confirmed via end-to-end testing):
    ///          {"name": "click", "button": "left", "click_type": "single",
    ///           "x": 52.4, "y": 31.0}
    ///      Where `x` and `y` are 0-100 **percentages** of the image.
    ///   2. **Native Molmo `<point x="42.5" y="89.3">label</point>` tags**
    ///      — same 0-100 percentage format, legacy Molmo style. MolmoWeb-4B
    ///      doesn't currently emit this but we keep it as a fallback in
    ///      case future model versions or sibling models return it.
    ///   3. **Plain `x,y` integer pair** — last-ditch fallback for any
    ///      format we haven't anticipated. Treated as pixel coordinates.
    ///
    /// Formats 1 and 2 use percentage coordinates and require the image
    /// dimensions to convert back to pixel space. Format 3 assumes pixel
    /// coordinates already.
    private func parseCoordinateFromResponseText(
        modelResponseText: String,
        elementLabel: String,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> CGPoint? {
        let trimmedResponseText = modelResponseText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Format 1: click-action JSON. Rather than full JSON-parse (which
        // would fail on truncated output from max_tokens cutoff), we regex
        // for the `"x": NUM` and `"y": NUM` fields independently. This also
        // handles the case where MolmoWeb emits slight variations in the
        // wrapping fields (different key order, extra fields, etc.).
        let jsonXFieldPattern = #""x"\s*:\s*(-?[\d.]+)"#
        let jsonYFieldPattern = #""y"\s*:\s*(-?[\d.]+)"#
        if let jsonXRegex = try? NSRegularExpression(pattern: jsonXFieldPattern),
           let jsonYRegex = try? NSRegularExpression(pattern: jsonYFieldPattern),
           let jsonXMatch = jsonXRegex.firstMatch(
             in: trimmedResponseText,
             range: NSRange(trimmedResponseText.startIndex..., in: trimmedResponseText)
           ),
           let jsonYMatch = jsonYRegex.firstMatch(
             in: trimmedResponseText,
             range: NSRange(trimmedResponseText.startIndex..., in: trimmedResponseText)
           ),
           jsonXMatch.numberOfRanges >= 2,
           jsonYMatch.numberOfRanges >= 2,
           let jsonXRange = Range(jsonXMatch.range(at: 1), in: trimmedResponseText),
           let jsonYRange = Range(jsonYMatch.range(at: 1), in: trimmedResponseText),
           let jsonXPercentValue = Double(trimmedResponseText[jsonXRange]),
           let jsonYPercentValue = Double(trimmedResponseText[jsonYRange]) {
            let xPixelValue = (jsonXPercentValue / 100.0) * Double(screenshotWidthInPixels)
            let yPixelValue = (jsonYPercentValue / 100.0) * Double(screenshotHeightInPixels)
            LogGuru.info(
                "MolmoWeb grounded \"\(elementLabel)\" → (\(Int(xPixelValue)), \(Int(yPixelValue))) from click-action JSON (\(jsonXPercentValue)%, \(jsonYPercentValue)%)",
                category: .vision,
                privacy: .private
            )
            return CGPoint(x: xPixelValue, y: yPixelValue)
        }

        // Format 2: legacy Molmo <point x="42.5" y="89.3">label</point>
        // Percentages 0-100 of the image dimensions. Also accepts the
        // <points x1="..." y1="..."> multi-point form — we take point 1.
        let nativePointPattern = #"<point[s]?\s+x1?="([\d.]+)"\s+y1?="([\d.]+)""#
        if let nativeRegex = try? NSRegularExpression(pattern: nativePointPattern),
           let nativeMatch = nativeRegex.firstMatch(
            in: trimmedResponseText,
            range: NSRange(trimmedResponseText.startIndex..., in: trimmedResponseText)
           ),
           nativeMatch.numberOfRanges >= 3,
           let xPercentRange = Range(nativeMatch.range(at: 1), in: trimmedResponseText),
           let yPercentRange = Range(nativeMatch.range(at: 2), in: trimmedResponseText),
           let xPercentValue = Double(trimmedResponseText[xPercentRange]),
           let yPercentValue = Double(trimmedResponseText[yPercentRange]) {
            let xPixelValue = (xPercentValue / 100.0) * Double(screenshotWidthInPixels)
            let yPixelValue = (yPercentValue / 100.0) * Double(screenshotHeightInPixels)
            LogGuru.info(
                "MolmoWeb grounded \"\(elementLabel)\" → (\(Int(xPixelValue)), \(Int(yPixelValue))) from point tag (\(xPercentValue)%, \(yPercentValue)%)",
                category: .vision,
                privacy: .private
            )
            return CGPoint(x: xPixelValue, y: yPixelValue)
        }

        // Format 3: last-ditch fallback — any "number,number" pair anywhere
        // in the response, treated as pixel coordinates. Handles formats
        // like "CLICK(285, 11)" or "click [285, 11]" etc.
        let plainPixelPattern = #"(\d+)\s*,\s*(\d+)"#
        if let plainRegex = try? NSRegularExpression(pattern: plainPixelPattern),
           let plainMatch = plainRegex.firstMatch(
            in: trimmedResponseText,
            range: NSRange(trimmedResponseText.startIndex..., in: trimmedResponseText)
           ),
           plainMatch.numberOfRanges >= 3,
           let xPixelRange = Range(plainMatch.range(at: 1), in: trimmedResponseText),
           let yPixelRange = Range(plainMatch.range(at: 2), in: trimmedResponseText),
           let xPixelValue = Double(trimmedResponseText[xPixelRange]),
           let yPixelValue = Double(trimmedResponseText[yPixelRange]) {
            LogGuru.info(
                "MolmoWeb grounded \"\(elementLabel)\" → (\(Int(xPixelValue)), \(Int(yPixelValue))) from plain coordinate pair",
                category: .vision,
                privacy: .private
            )
            return CGPoint(x: xPixelValue, y: yPixelValue)
        }

        LogGuru.warning(
            "MolmoWeb could not extract coordinates for \"\(elementLabel)\" from response: \(trimmedResponseText.prefix(200))",
            category: .vision,
            privacy: .private
        )
        return nil
    }
}
