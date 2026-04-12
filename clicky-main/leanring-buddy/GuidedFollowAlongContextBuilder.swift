//
//  GuidedFollowAlongContextBuilder.swift
//  leanring-buddy
//
//  Builds the guide-aware system prompt used for Phase 3 AI follow-along
//  during guided playback (`Clicky_Codebase_Distribution_Spec_v1.md` §14).
//
//  When a guided session is actively playing and the user triggers
//  push-to-talk, `CompanionManager.sendTranscriptToOpenAIWithScreenshot`
//  swaps its usual generic companion system prompt for the one this
//  builder produces. That prompt embeds:
//
//    - the walkthrough title and the current step number
//    - the current step's narration (what the author said here)
//    - the narration of nearby steps (brief, for "what's next?" and
//      "what have we covered?" questions)
//    - repo metadata captured at author-time (remote URL, branch,
//      commit SHA, workspace folder name) when the guide has
//      `context.type == .repo`
//    - the currently opened file path + line (if any), so the
//      assistant can ground answers in the exact receiver state
//      that `WorkspacePreparationCoordinator` just prepared
//
//  Intentionally NOT included (deferred to Phase 3.5 / later):
//
//    - Inline file contents. The model already sees the live screen
//      via the image input, which shows the editor with the open
//      file — redundant text would just burn tokens.
//    - Conversation history. Each follow-along question is a fresh
//      exchange in v1; multi-turn within a session is a later polish.
//    - Runtime diffing / "what changed in this step" semantic
//      reasoning. The model gets the step narrations as plain text
//      and reasons about changes directly from the screenshot.
//
//  The prompt text is a single Swift string built with `String(
//  reflecting:)`-style interpolation. No templating engine — the
//  shape is small enough that direct interpolation is the cleanest
//  expression.
//

import Foundation

/// Pure helper that assembles a guide-aware system prompt for the
/// Phase 3 follow-along assistant. Called from `GuidedSessionManager`
/// which owns the session state the builder reads from.
enum GuidedFollowAlongContextBuilder {

    /// Builds the full system prompt string to send to OpenAI when
    /// the user asks a follow-along question mid-playback.
    ///
    /// - `guideBeingPlayed`: the currently loaded guide.
    /// - `currentStepIndex`: 0-based index of the step the session is
    ///   currently on (speaking, waiting to advance, or stuck).
    /// - `preparedWorkspaceResult`: set when Phase 2 workspace prep
    ///   succeeded; nil for non-repo guides and for guides playing in
    ///   watch-only fallback mode. The repo-related prompt section is
    ///   omitted when this is nil.
    static func buildFollowAlongSystemPrompt(
        forGuide guideBeingPlayed: ClickyGuide,
        currentStepIndex: Int,
        preparedWorkspaceResult: WorkspacePreparationResult?
    ) -> String {
        let totalStepCount = guideBeingPlayed.steps.count
        let clampedCurrentStepIndex = max(0, min(currentStepIndex, totalStepCount - 1))
        let currentStep = guideBeingPlayed.steps[clampedCurrentStepIndex]

        let oneBasedCurrentStepNumber = clampedCurrentStepIndex + 1
        let guideTitleOrFallback = guideBeingPlayed.title.isEmpty
            ? "Untitled walkthrough"
            : guideBeingPlayed.title
        let authorNameOrFallback = guideBeingPlayed.author.name.isEmpty
            ? "the author"
            : guideBeingPlayed.author.name

        let currentStepSection = """
        CURRENT STEP (\(oneBasedCurrentStepNumber) of \(totalStepCount)):
        \(currentStep.narration)
        """

        // Prior step narrations — up to 2 most recent — so the
        // assistant can summarize "what have we covered?" without
        // needing the full transcript.
        let priorStepsSection: String
        let priorStepsRange = max(0, clampedCurrentStepIndex - 2)..<clampedCurrentStepIndex
        if priorStepsRange.isEmpty {
            priorStepsSection = ""
        } else {
            let priorStepLines = priorStepsRange.map { priorStepIndex -> String in
                let priorStep = guideBeingPlayed.steps[priorStepIndex]
                return "- step \(priorStepIndex + 1): \(priorStep.narration)"
            }
            priorStepsSection = """

            PREVIOUSLY COVERED:
            \(priorStepLines.joined(separator: "\n"))
            """
        }

        // Next step narration — just the immediately upcoming step.
        // Supports "what's next?" questions without leaking too much
        // of the walkthrough ahead of the user.
        let nextStepSection: String
        let nextStepIndex = clampedCurrentStepIndex + 1
        if nextStepIndex < totalStepCount {
            let nextStep = guideBeingPlayed.steps[nextStepIndex]
            nextStepSection = """

            COMING UP NEXT (step \(nextStepIndex + 1)):
            \(nextStep.narration)
            """
        } else {
            nextStepSection = """

            This is the last step — after this, the walkthrough is complete.
            """
        }

        // Repo + workspace section. Only rendered when Phase 2 prep
        // populated `preparedWorkspaceResult`. For non-repo guides
        // and watch-only fallback sessions this is omitted entirely
        // so the prompt stays tight.
        let repoContextSection = buildRepoContextSection(
            forGuideContext: guideBeingPlayed.context,
            preparedWorkspaceResult: preparedWorkspaceResult
        )

        // Assemble the whole prompt. The rules block at the end
        // mirrors `companionVoiceResponseSystemPrompt` but scoped
        // to guided playback — same speech style and target-tag
        // format, different persona and intent list.
        return """
        you're clicky, a guided walkthrough assistant. the user is currently PLAYING a recorded walkthrough and just asked you a question mid-session. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk.

        WALKTHROUGH: "\(guideTitleOrFallback)" by \(authorNameOrFallback)

        \(currentStepSection)\(priorStepsSection)\(nextStepSection)\(repoContextSection)

        WHAT THE USER MIGHT ASK AND HOW TO ANSWER:
        - "where am i?" → tell them they're on step \(oneBasedCurrentStepNumber) of \(totalStepCount) and briefly describe what this step is about.
        - "what do i do next?" → if this is the current step they're acting on, restate the current step's instruction in your own words. if they're already done with it, describe the next step.
        - "what's this step about?" or "explain this step" → unpack the current step using the narration plus what you see on screen.
        - "i'm stuck" → look at the live screenshot, compare it to what the step wants, and suggest the concrete next action. if the step has a stuck hint, use it as a starting point.
        - "explain this file" or "what does this code do" → read the file on screen in the screenshot and explain it at the level the walkthrough needs.
        - general questions about the walkthrough → answer from the narrations above. don't invent steps the author didn't mention.

        CRITICAL RULES:
        - you are NOT an autonomous coder. don't write code, don't suggest edits, don't offer to refactor anything. your job is to help the user complete THIS walkthrough.
        - default to one or two sentences. be direct. elaborate only when explicitly asked.
        - all lowercase, casual, warm. no emojis, no markdown, no lists, no bullets.
        - write for the ear. short sentences. no abbreviations — "for example" not "e.g."
        - never say "simply" or "just".
        - don't read code verbatim. describe what it does.
        - the screenshot shows what the user is looking at RIGHT NOW. use it as your primary source of truth about their current state.
        - if the user seems confused about what to do on the current step, prioritize getting them unstuck over educating them.

        ELEMENT POINTING:
        you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would help the user complete the current step — if they're asking where a button is, what to click, or where something lives in the UI, point at it.

        when you want to point at an element, append a target tag at the very end of your response, AFTER your spoken text. a separate visual grounding model looks at the screenshot and finds the exact pixel location, so you don't need coordinates yourself — just describe the element clearly.

        format: [TARGET:label] where label is a specific, visually distinctive description of the UI element (like "search bar", "commit button in source control panel", "file tab in editor tabs"). be descriptive enough that someone looking at the screenshot could find it. if the element is on a different screen than the cursor, append :screenN.

        if pointing wouldn't help, append [TARGET:none].
        """
    }

    /// Builds the repo context section of the follow-along system
    /// prompt. Returns an empty string when the guide isn't a repo
    /// type or when Phase 2 prep didn't run successfully, so the
    /// whole block disappears gracefully from the prompt.
    private static func buildRepoContextSection(
        forGuideContext guideContext: GuideContext,
        preparedWorkspaceResult: WorkspacePreparationResult?
    ) -> String {
        guard guideContext.type == .repo else {
            return ""
        }

        var repoSectionLines: [String] = []
        repoSectionLines.append("")
        repoSectionLines.append("REPO CONTEXT (captured when the walkthrough was recorded):")
        repoSectionLines.append("- repository: \(guideContext.target)")

        if let workspaceName = guideContext.workspaceName, !workspaceName.isEmpty {
            repoSectionLines.append("- workspace folder: \(workspaceName)")
        }
        if let branchName = guideContext.branch, !branchName.isEmpty {
            repoSectionLines.append("- branch: \(branchName)")
        }
        if let commitSha = guideContext.commitSha, !commitSha.isEmpty {
            repoSectionLines.append("- commit: \(commitSha.prefix(10))")
        }
        if let openPath = guideContext.openPath, !openPath.isEmpty {
            if let openLine = guideContext.openLine, openLine > 0 {
                repoSectionLines.append("- walkthrough is focused on: \(openPath):\(openLine)")
            } else {
                repoSectionLines.append("- walkthrough is focused on: \(openPath)")
            }
        }

        // If Phase 2 workspace prep actually ran for this session we
        // also know what the receiver has open on their machine —
        // that's a richer signal than the author-time fields alone
        // because it reflects the current state after resolve / clone
        // / checkout / editor launch.
        if let preparedWorkspaceResult {
            repoSectionLines.append("")
            repoSectionLines.append("RECEIVER STATE (prepared for this playback session):")
            repoSectionLines.append("- local repo root: \(preparedWorkspaceResult.repoRootURL.path)")
            if let openedFileURL = preparedWorkspaceResult.openedFileURL {
                repoSectionLines.append("- currently opened file: \(openedFileURL.path)")
            }
            if !preparedWorkspaceResult.nonFatalWarningMessages.isEmpty {
                repoSectionLines.append("- note: \(preparedWorkspaceResult.nonFatalWarningMessages.joined(separator: " "))")
            }
        } else {
            repoSectionLines.append("")
            repoSectionLines.append("NOTE: workspace preparation didn't run for this playback (watch-only mode). the user may not have the actual repo open — rely on the screenshot for what they're seeing.")
        }

        return "\n" + repoSectionLines.joined(separator: "\n")
    }
}
