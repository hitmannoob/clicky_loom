//
//  GuidedSession.swift
//  leanring-buddy
//
//  Codable data model for the `.clicky.json` guide file format used by
//  Clicky's guided walkthrough mode. Mirrors the schema defined in
//  `Clicky_Guided_Mode_Spec_v2.md` section 1.
//
//  A `ClickyGuide` is a single walkthrough — title, ordered steps,
//  optional completion message — that User A records and User B plays
//  back. At playback time each step is narrated via TTS, the cursor
//  points at a UI element, and the session advances automatically
//  (polling the screen every 3s to check a condition), manually (user
//  presses Ctrl+Option), or on a timer.
//
//  Two things deviate from the spec on purpose:
//
//    1. `refImageBase64` is added alongside the path-based `refImage`.
//       The spec assumes guides live in a checked-out repo with sidecar
//       image files at `assets/step1.jpg`. Our Phase 2 implementation
//       stores guides as a single JSON blob in R2, so reference
//       screenshots are base64-embedded inline inside each step. Both
//       fields are optional so either layout decodes cleanly — local
//       test guides on disk use `refImage`, R2-hosted guides use
//       `refImageBase64`.
//
//    2. Dates are decoded with a lenient ISO8601 formatter that accepts
//       both plain `2026-04-11T10:30:00Z` and the fractional-second
//       variant `2026-04-11T10:30:00.123Z`, since the recording side
//       emits whatever Swift's default `JSONEncoder` produces.
//

import Foundation

// MARK: - Top-level guide

/// A single recorded walkthrough. Produced by `GuideRecorder` (User A)
/// and consumed by `GuidedSessionManager` (User B).
struct ClickyGuide: Codable {
    /// Schema version. Bumped when we make breaking changes to the
    /// on-the-wire shape so playback can reject incompatible guides.
    let version: String

    /// Random UUID assigned at upload time by the Worker's
    /// `POST /guide/upload` route. Also embedded in the `clicky://`
    /// deep link as `?id=...`.
    let id: String

    let title: String
    let author: GuideAuthor
    let createdAt: Date
    let context: GuideContext
    let voice: GuideVoice?
    let steps: [GuideStep]
    let completion: GuideCompletion?

    enum CodingKeys: String, CodingKey {
        case version, id, title, author, context, voice, steps, completion
        case createdAt = "created_at"
    }
}

// MARK: - Author

struct GuideAuthor: Codable {
    let name: String
    /// Optional — prototype uploads from the macOS client leave this
    /// empty because we don't ask User A for their email.
    let email: String?
}

// MARK: - Context

/// Describes what should be open / active on User B's machine for the
/// guide to play correctly. `GuidedSessionManager` uses this to decide
/// whether to open the target automatically before starting playback.
///
/// The repo-specific fields (`commitSha`, `openLine`, `editorBundleId`,
/// `workspaceName`, `clonePreference`) were added for the codebase
/// distribution v1 work (`Clicky_Codebase_Distribution_Spec_v1.md` §8).
/// They are all optional so guides produced before that work still
/// decode unchanged, and guides with `type != .repo` simply leave them
/// nil.
struct GuideContext: Codable {
    let type: ContextType
    /// Interpretation depends on `type`:
    /// - `.repo`  → git remote URL (ssh or https form, normalized on
    ///              the receiver side before local-clone matching)
    /// - `.url`   → full https URL to open in the default browser
    /// - `.file`  → local filesystem path
    /// - `.app`   → macOS bundle identifier (e.g. `com.apple.finder`)
    let target: String
    /// Optional git branch name — only meaningful for `type == .repo`.
    let branch: String?
    /// Optional file-within-context to open first (e.g. `src/main.ts`).
    let openPath: String?
    /// Exact commit SHA the author recorded against. When present, the
    /// receiver's workspace preparation step prefers this over `branch`
    /// so playback lines up with the author's actual tree.
    let commitSha: String?
    /// Optional 1-based line number inside `openPath` where the
    /// receiver should land when the editor opens.
    let openLine: Int?
    /// Bundle identifier of the editor the author was using at record
    /// time (e.g. `com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92`
    /// for Cursor). Used as a hint when deciding which editor to launch
    /// on the receiver side.
    let editorBundleId: String?
    /// Human-readable label for the workspace — typically the repo
    /// folder name. Shown during clone prompts so the receiver sees
    /// "clone repo" instead of just a bare url.
    let workspaceName: String?
    /// Author's preferred clone transport. `"ssh"` or `"https"`. The
    /// receiver still ultimately picks based on local availability but
    /// this biases the default.
    let clonePreference: String?

    enum ContextType: String, Codable {
        case repo
        case url
        case file
        case app
    }

    enum CodingKeys: String, CodingKey {
        case type, target, branch
        case openPath = "open_path"
        case commitSha = "commit_sha"
        case openLine = "open_line"
        case editorBundleId = "editor_bundle_id"
        case workspaceName = "workspace_name"
        case clonePreference = "clone_preference"
    }

    /// Explicit init so the optional codebase-distribution fields have
    /// parameter defaults. Without this Swift's synthesized memberwise
    /// init would require every caller to pass `commitSha: nil,
    /// openLine: nil, ...` which makes non-repo contexts noisy.
    init(
        type: ContextType,
        target: String,
        branch: String? = nil,
        openPath: String? = nil,
        commitSha: String? = nil,
        openLine: Int? = nil,
        editorBundleId: String? = nil,
        workspaceName: String? = nil,
        clonePreference: String? = nil
    ) {
        self.type = type
        self.target = target
        self.branch = branch
        self.openPath = openPath
        self.commitSha = commitSha
        self.openLine = openLine
        self.editorBundleId = editorBundleId
        self.workspaceName = workspaceName
        self.clonePreference = clonePreference
    }
}

// MARK: - Voice config

/// Per-guide voice override. The player respects this if the requested
/// provider is available; otherwise it falls back to the app's default
/// TTS (currently the macOS system synthesizer).
struct GuideVoice: Codable {
    /// Either `"elevenlabs"` or `"system"` today. Strings rather than
    /// an enum so unknown providers don't fail decoding.
    let provider: String
    /// Optional ElevenLabs voice clone id. Ignored when provider is
    /// `"system"`.
    let voiceId: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case voiceId = "voice_id"
    }
}

// MARK: - Step

/// One step in the walkthrough. Steps execute in array order.
struct GuideStep: Codable {
    let id: String

    /// The exact text that gets fed to the TTS synthesizer. Must read
    /// naturally as spoken — commas, short sentences, no markdown.
    let narration: String

    /// Relative path to a reference screenshot inside a repo-hosted
    /// guide (e.g. `assets/step1.jpg`). Mutually exclusive with
    /// `refImageBase64` in practice, but both fields can be present
    /// and the player picks whichever it can resolve first.
    let refImage: String?

    /// Base64-encoded reference screenshot bytes, embedded inline in
    /// the guide JSON. This is how R2-hosted guides carry their assets
    /// so the entire guide is a single self-contained blob.
    let refImageBase64: String?

    /// Optional pointer to a UI element on the author's recording.
    /// Coordinates are hints, not exact — at playback time
    /// `GuidedSessionManager` re-localizes against User B's live
    /// screenshot via MolmoWeb (or OpenAI as fallback).
    let point: GuidePoint?

    let advance: StepAdvance

    enum CodingKeys: String, CodingKey {
        case id, narration, point, advance
        case refImage = "ref_image"
        case refImageBase64 = "ref_image_base64"
    }
}

// MARK: - Point hint

/// UI element hint captured by User A during recording. Coordinates
/// come from the author's display (which may differ in size/resolution
/// from User B's), so they're treated as approximate — the real work
/// happens in `MolmoWebClient.groundElement` which finds the matching
/// element on User B's actual screen.
struct GuidePoint: Codable {
    let x: Int
    let y: Int
    /// Human-readable description of the element, e.g. "settings tab".
    /// Used as the natural-language query when re-grounding.
    let label: String
    /// Optional 1-based display index (1 = primary display, 2 = second
    /// connected monitor, etc.). Only relevant when the author
    /// recorded a multi-monitor walkthrough.
    let screen: Int?
}

// MARK: - Advance

/// Controls how the session progresses from this step to the next.
struct StepAdvance: Codable {
    let mode: AdvanceMode

    /// Natural-language condition passed to the screen-match model.
    /// Example: `"settings page is visible"`. Required for `.auto`
    /// mode, optional for `.manual` / `.timed`.
    let condition: String?

    /// Safety timeout for `.auto` mode. After this many seconds the
    /// session transitions to the stuck state and speaks `stuckHint`.
    let timeoutSeconds: Int?

    /// Optional hint to speak to the user when they get stuck, e.g.
    /// `"look for the gear icon in the top navigation bar"`.
    let stuckHint: String?

    enum AdvanceMode: String, Codable {
        /// Auto-advance: `GuidedSessionManager` polls the screen every
        /// 3s and advances when OpenAI confirms the condition is met.
        case auto
        /// Wait for user to press Ctrl+Option (or the Next button).
        case manual
        /// Advance after TTS finishes plus a fixed short delay. Used
        /// for info-only steps that don't require any user action.
        case timed
    }

    enum CodingKeys: String, CodingKey {
        case mode, condition
        case timeoutSeconds = "timeout_seconds"
        case stuckHint = "stuck_hint"
    }
}

// MARK: - Completion

/// Optional end-of-guide payload. If `narration` is set, it's spoken
/// via TTS when the final step completes. `action` is reserved for a
/// future "run this command / open this url" behavior and currently
/// ignored by the player.
struct GuideCompletion: Codable {
    let narration: String?
    let action: String?
}

// MARK: - JSON coding helpers

extension ClickyGuide {
    /// Shared JSON decoder with a lenient ISO8601 date strategy so we
    /// accept both plain and fractional-second timestamps. Callers
    /// should use this instead of building their own decoder.
    static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainIsoFormatter = ISO8601DateFormatter()
        plainIsoFormatter.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoderContext in
            let container = try decoderContext.singleValueContainer()
            let rawDateString = try container.decode(String.self)
            if let parsedDate = isoFormatter.date(from: rawDateString) {
                return parsedDate
            }
            if let parsedDate = plainIsoFormatter.date(from: rawDateString) {
                return parsedDate
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Guide created_at is not a valid ISO8601 timestamp: \(rawDateString)"
            )
        }
        return decoder
    }

    /// Shared JSON encoder that emits fractional-second ISO8601 so
    /// round-tripping a guide through `JSONEncoder` → `JSONDecoder`
    /// doesn't lose precision.
    static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { dateValue, encoderContext in
            var container = encoderContext.singleValueContainer()
            try container.encode(isoFormatter.string(from: dateValue))
        }
        return encoder
    }

    /// Decodes a guide from raw JSON bytes (typically the response body
    /// of a `GET /guide/:id` call or the contents of a local
    /// `.clicky.json` file).
    static func decode(from jsonData: Data) throws -> ClickyGuide {
        try jsonDecoder.decode(ClickyGuide.self, from: jsonData)
    }

    /// Encodes a guide to raw JSON bytes — used by `GuideRecorder` /
    /// `GuideUploadQueue` to prepare the `POST /guide/upload` body.
    func encodeToJSONData() throws -> Data {
        try Self.jsonEncoder.encode(self)
    }
}
