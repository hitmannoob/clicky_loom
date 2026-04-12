# Clicky codebase distribution — product and technical spec

> **v1**
> Focus the next Clicky iteration on codebase walkthrough distribution.
> The recording experience stays ambient, the share becomes web-first,
> and opening the share in Clicky prepares the repo locally before the
> interactive guide begins.

## 1. Problem statement

The current guided walkthrough flow is strong on authoring but weak on
distribution:

- the primary output is a `clicky://guide?id=...` deep link
- the receiver effectively needs Clicky installed before the share is useful
- code walkthroughs do not yet restore the receiver into the same repo,
  branch, commit, and file context as the author

That makes Clicky feel closer to a custom playback client than a
distribution product.

For code walkthroughs, the receiver should be able to:

1. open a normal web link
2. understand what the share is about
3. click `Open in Clicky`
4. have Clicky find or clone the repo
5. open the right file in the right editor context
6. start the guide with AI follow-along attached

## 2. Product thesis

For v1, Clicky should be positioned as:

**"Loom for code walkthroughs, but the share can reopen the codebase
locally and guide you through it with AI."**

The differentiator is not raw screen recording quality. The
differentiator is workspace restoration plus interactive follow-along.

## 3. Product principles

### Ambient authoring

The author should not need to foreground Clicky while recording. Clicky
must remain menu-bar-driven or shortcut-driven so the author can stay in
Cursor, VS Code, terminal, browser, or other dev tools.

### Web-first distribution

The primary share target must be an HTTPS URL, not a custom scheme. The
web share page is the universal entrypoint. `clicky://` remains a
secondary handoff into the native app.

### Workspace before playback

When a receiver opens a codebase share in Clicky, Clicky should prepare
the repo and file context first. The guide should not start while the
user is still choosing folders, cloning, or finding the right file.

### AI as follow-along, not just narration

Once the workspace is ready, the AI companion should stay available
during playback so the receiver can ask what changed, where they are,
what to do next, or why they are stuck.

### Safe repo operations

Clicky may automate git operations, but it must not silently create
destructive local state. Clone, checkout, and editor-launch flows must
be explicit and reversible.

## 4. V1 scope

V1 is **codebases-first**.

Supported:

- git-backed repositories
- shareable HTTPS page for each uploaded guide
- `Open in Clicky` handoff from web to native app
- existing-clone detection
- clone-if-missing flow
- checkout of the target branch or commit when safe
- open the target file and optional line
- guided playback with AI follow-along

Not in scope for v1:

- PPT / slides / deck workflows
- arbitrary app walkthroughs
- fully interactive browser-only playback
- automatic dependency install or setup script execution
- multi-repo monorepo graph setup beyond opening a single repo root
- background code edits by the AI companion

## 5. User stories

### Author

An engineer records a walkthrough while working in their repo. When they
share it, the receiver should get a normal link that opens a useful web
page immediately, even before Clicky is installed.

### Receiver with local clone

A teammate clicks `Open in Clicky`, Clicky finds the repo locally,
checks out the right branch or commit when safe, opens the right file,
then starts the guide and AI follow-along.

### Receiver without local clone

A teammate clicks `Open in Clicky`, Clicky asks where to clone the repo,
clones it, opens the target file, then starts the guide and AI
follow-along.

### Receiver blocked on repo access

If the repo is private and clone access fails, the receiver should still
be able to consume the web share in watch-only mode. Native playback
should degrade cleanly instead of failing hard.

## 6. Experience flow

### 6.1 Author flow

1. User records a walkthrough from the menu bar or shortcut.
2. Clicky captures guide data as it does today.
3. Clicky additionally captures codebase context from the active
   workspace when possible.
4. Upload completes.
5. Clicky returns:
   - `share_url` for universal distribution
   - `clicky_deep_link` for native handoff
6. User shares the HTTPS URL.

### 6.2 Receiver web flow

1. Receiver opens `https://...`.
2. Web page shows:
   - title
   - author
   - repo name
   - branch or commit
   - target file
   - transcript or summary preview
   - `Open in Clicky`
   - fallback `Watch in browser`
3. If Clicky is installed, `Open in Clicky` launches the app via
   `clicky://`.
4. If not installed, the page offers install instructions.

### 6.3 Receiver native flow

1. Clicky receives the share id.
2. Clicky fetches the guide and codebase context.
3. Clicky resolves whether the repo already exists locally.
4. If found:
   - validate the remote matches
   - check whether the requested branch or commit is available
   - open the repo
5. If not found:
   - ask for a clone location
   - clone the repo
   - open the repo
6. Clicky opens the target file and optional line in the preferred editor.
7. Clicky starts guided playback.
8. AI follow-along is active throughout playback.

## 7. Distribution model

### Current state

Today the Worker returns a `deep_link` shaped like:

```text
clicky://guide?id={guide_id}
```

### V1 target

The Worker should return both:

```text
https://clicky.dev/g/{guide_id}
clicky://guide?id={guide_id}
```

The HTTPS URL is the primary share artifact.

### Why keep the guide id as the share id in v1

For v1, the simplest model is to keep the existing uploaded
`ClickyGuide` as the canonical stored object and make the web share page
render from that object. A separate share envelope can come later if we
need comments, analytics, ACLs, or mutable metadata.

## 8. Guide schema changes

The current `ClickyGuide.context` model already supports:

- `type`
- `target`
- `branch`
- `open_path`

That is close, but not sufficient for robust codebase restoration. V1
should extend the repo context shape.

### Proposed schema extension

```jsonc
{
  "context": {
    "type": "repo",
    "target": "https://github.com/org/repo.git",
    "branch": "feature/new-onboarding",
    "commit_sha": "1f2e3d4c5b6a7...",
    "open_path": "src/onboarding/GuidePanel.tsx",
    "open_line": 84,
    "editor_bundle_id": "com.microsoft.VSCode",
    "workspace_name": "repo",
    "clone_preference": "ssh" // "ssh" | "https"
  }
}
```

### New fields

- `commit_sha`
  Locks the share to the exact revision the author recorded against.
- `open_line`
  Allows Clicky to land the receiver at a specific point in a file.
- `editor_bundle_id`
  Tells Clicky which editor the author used, which can influence the
  open command when the same app exists locally.
- `workspace_name`
  Helpful as a label during repo resolution and clone UX.
- `clone_preference`
  Lets Clicky preserve whether the author expects SSH or HTTPS clone
  semantics.

### Compatibility

These fields should be additive. Existing guides without the new fields
must continue to decode and play.

## 9. Codebase context capture

Clicky should attempt to capture codebase metadata at recording time.

### Desired capture set

- repository remote URL
- current branch
- current commit SHA
- current open file path
- current line number if available
- active editor bundle id

### Initial capture strategy

V1 does not need deep IDE integrations on day one. The first pass can be:

1. infer the active app
2. detect whether the frontmost context looks like a code editor
3. capture the repo root and current file path when discoverable
4. allow the author to edit or confirm the captured repo context before
   final upload if confidence is low

### Fallback

If Clicky cannot confidently capture repo context, it should still allow
guide upload but mark the guide as playback-only instead of
workspace-restorable.

## 10. Repo resolution behavior

When a repo share is opened, Clicky should try to match the target repo
to an existing local clone before asking to clone.

### Candidate resolution sources

- previously opened repos remembered by Clicky
- common workspace directories
- user-approved search roots
- explicit user selection via file picker if auto-match fails

### Matching strategy

Match on normalized git remote URL, not folder name alone.

Examples that should normalize to the same repo:

- `git@github.com:org/repo.git`
- `https://github.com/org/repo.git`
- `https://github.com/org/repo`

### Successful existing-clone path

If a matching clone is found:

1. verify the repo root is accessible
2. fetch only if needed and safe
3. try to checkout the requested commit or branch
4. open the requested file and line
5. proceed into guide playback

## 11. Clone-if-missing behavior

If no matching clone exists, Clicky should offer a clone flow.

### Clone UX

1. show repo name and source host
2. ask user where to clone
3. clone using the preferred transport when possible
4. show progress
5. open the repo and target file
6. start the guide

### Failure handling

If clone fails:

- show the git error clearly
- allow retry
- allow changing clone destination
- allow switching SSH vs HTTPS
- allow falling back to watch-only mode

## 12. Checkout behavior

Restoring the right revision matters for walkthrough correctness, but
checkout can also create risk in a dirty working tree.

### Desired behavior

- if target `commit_sha` exists locally, prefer that exact revision
- else if target `branch` exists, use the branch
- else stay on the current branch and warn the user that context may not
  match

### Safety rules

- never hard-reset the user’s repo
- if the working tree is dirty, ask before checkout
- if checkout would fail, leave the repo unchanged and offer watch-only
  playback

## 13. Editor launch behavior

After the repo is ready, Clicky should open the target file where the
receiver already works.

### V1 behavior

Support at least:

- Cursor
- VS Code
- default system editor fallback

### Inputs

- repo root path
- `open_path`
- optional `open_line`
- optional `editor_bundle_id`

### Expected result

The receiver lands in the right repo and file before the guide begins.

## 14. Guided playback with AI follow-along

The guide should not just play narration. Once the repo and file are
open, Clicky should attach an interactive assistant layer.

### Primary follow-along intents

- "where am I?"
- "what changed in this step?"
- "what do I do next?"
- "I’m stuck"
- "explain this file"

### Context available to the assistant

- current guide step
- repo metadata
- current file path
- current line if known
- live screen capture
- guide transcript and narration

### V1 goal

The assistant should help the receiver complete the walkthrough, not act
as a general autonomous coding agent.

## 15. Native state machine changes

`GuidedSessionManager` currently assumes that opening a guide is roughly
equivalent to being ready to play it. That is no longer enough for repo
shares.

### Proposed new states

- `loadingGuide`
- `preparingWorkspace`
- `resolvingLocalRepo`
- `cloningRepo`
- `checkingOutRevision`
- `openingEditor`
- `ready`
- existing playback states
- `failed`

The guide should only move to `ready` after workspace preparation
finishes or the user explicitly accepts degraded playback.

## 16. New app components

V1 likely needs the following new native services:

- `CodebaseContextCaptureService`
  Captures repo, branch, commit, file, line, and editor context during
  or immediately after recording.
- `RepoWorkspaceResolver`
  Finds local clones by normalized remote URL.
- `GitRepositoryClient`
  Wraps non-destructive git commands such as remote inspection, branch
  presence checks, clone, fetch, and checkout.
- `EditorLauncher`
  Opens the prepared repo and file in the preferred editor.
- `GuideShareResolver`
  Fetches a guide share from the web URL or deep-link payload and hands
  it to guided playback.

## 17. Worker and backend changes

The existing Worker and R2 storage are enough for a first distribution
pass, but the API contract needs to expand.

### Worker changes

`POST /guide/upload` should return:

```json
{
  "guide_id": "uuid",
  "deep_link": "clicky://guide?id=uuid",
  "share_url": "https://clicky.dev/g/uuid"
}
```

### Future backend extensions

Not required for v1, but likely later:

- share access controls
- expiry / revoke link
- view analytics
- comments
- org-only shares

## 18. Web share page requirements

The web page should be intentionally lightweight in v1.

### Required

- render title and author
- show repo name and branch or commit
- show target file
- show transcript or summary preview
- expose `Open in Clicky`
- expose install CTA if app missing
- expose watch-only or read-only fallback

### Not required in v1

- full browser-native interactive playback
- comments
- reactions
- timeline editing

## 19. Security and trust

Because Clicky may clone repos and change checkout state, trust signals
must be explicit.

### Requirements

- always show the repo host and normalized clone URL before cloning
- always show the destination path before clone
- always prompt before checkout if local changes may be affected
- never run setup scripts automatically
- never silently install dependencies

## 20. Metrics for success

The v1 codebase distribution flow is successful if:

- authors primarily share the HTTPS URL, not the raw deep link
- receivers can open most shares without manual repo hunting
- existing-clone resolution succeeds for common teammate scenarios
- clone-if-missing succeeds without bespoke support
- receivers can finish a walkthrough from inside their local editor
- AI follow-along reduces confusion during playback

## 21. Implementation phases

### Phase 1: schema and distribution

- extend `GuideContext` for repo-specific metadata
- return `share_url` from upload
- build a minimal web share page
- keep current playback unchanged if repo context is absent

### Phase 2: native repo preparation

- add repo resolution
- add clone flow
- add checkout flow
- add editor launch
- add new guided-session preparation states

### Phase 3: AI follow-along attachment

- pass active repo/share context into the companion
- improve stuck help for code walkthroughs
- add guide-aware follow-up prompts during playback

## 22. Open questions

- Which editor should be the first-class launch target: Cursor, VS Code,
  or whatever is already installed?
- Should the exact `commit_sha` be required for a share to be marked
  "workspace-restorable"?
- Should private repos be supported in v1, or should v1 initially assume
  repos the receiver already has access to locally?
- Should the web share page show a generated summary, full transcript,
  or both?
- Should Clicky remember approved clone roots globally, per host, or per
  repo?

## 23. Recommended v1 decision

To keep scope tight, v1 should assume:

- codebase shares only
- one repo per share
- one primary file target per share
- HTTPS distribution first
- Clicky native app as the interactive playback surface
- AI follow-along as assistive help, not autonomous execution

That is a focused enough wedge to ship and test without turning Clicky
into a general-purpose workflow platform too early.
