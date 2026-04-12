/**
 * Clicky Proxy Worker
 *
 * Proxies requests to OpenAI and ElevenLabs APIs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat                      → OpenAI Chat Completions API (streaming)
 *   POST /tts                       → ElevenLabs TTS API
 *   POST /transcribe-token          → AssemblyAI short-lived websocket token
 *   POST /guide/upload              → Stores a ClickyGuide JSON blob in R2,
 *                                      returns { guide_id, deep_link, share_url }
 *   GET  /guide/:id                 → Fetches a previously uploaded guide
 *                                      from R2 by id (raw JSON)
 *   GET  /g/:id                     → Renders a lightweight HTML share page
 *                                      for a previously uploaded guide,
 *                                      with an "Open in Clicky" deep-link
 *                                      button. This is the universal share
 *                                      target returned as `share_url` from
 *                                      /guide/upload.
 *   POST /audio/transcribe/submit   → Uploads WAV audio to AssemblyAI's
 *                                      batch API, creates a transcript job,
 *                                      returns { transcript_id }. Client then
 *                                      polls /audio/transcribe/status/:id.
 *   GET  /audio/transcribe/status/:id → Returns the current state of a
 *                                        submitted transcript job (queued /
 *                                        processing / completed / error).
 */

interface Env {
  OPENAI_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
  /**
   * R2 bucket binding for guide storage.
   * Bucket name: `clicky-guides` (configured in wrangler.toml).
   * Object keys are shaped as `guides/{uuid}.json`.
   */
  GUIDE_BUCKET: R2Bucket;
  /**
   * Optional override for the base URL used when constructing
   * `share_url` values returned from `/guide/upload`. Set this in
   * `wrangler.toml` `[vars]` once a public-facing domain is in place
   * (e.g. `https://clicky.dev`) so shared links survive worker
   * redeploys under different `*.workers.dev` hostnames. Leave unset
   * during local `wrangler dev` — the handler falls back to the
   * incoming request origin.
   */
  SHARE_BASE_URL?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    try {
      // POST routes (most endpoints — proxies and uploads)
      if (request.method === "POST") {
        if (url.pathname === "/chat") {
          return await handleChat(request, env);
        }

        if (url.pathname === "/tts") {
          return await handleTTS(request, env);
        }

        if (url.pathname === "/transcribe-token") {
          return await handleTranscribeToken(env);
        }

        if (url.pathname === "/guide/upload") {
          return await handleGuideUpload(request, env);
        }

        if (url.pathname === "/audio/transcribe/submit") {
          return await handleAudioTranscribeSubmit(request, env);
        }
      }

      // GET routes (share-link style resources — guides are public once
      // you know the random id, no auth required to fetch them)
      if (request.method === "GET") {
        if (url.pathname.startsWith("/guide/")) {
          return await handleGuideGet(url, env);
        }

        if (url.pathname.startsWith("/g/")) {
          return await handleGuideSharePage(url, env);
        }

        if (url.pathname.startsWith("/audio/transcribe/status/")) {
          return await handleAudioTranscribeStatus(url, env);
        }
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] OpenAI API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "audio/mpeg" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}

/**
 * Uploads a ClickyGuide JSON blob to the `clicky-guides` R2 bucket.
 *
 * The request body is expected to be a complete `.clicky.json` payload
 * as produced by `GuideRecorder.swift` on the macOS client — with
 * reference screenshots already base64-embedded inline under
 * `steps[].ref_image_base64`. The Worker does not validate the schema;
 * it accepts any JSON and stores it verbatim.
 *
 * Returns:
 *   - `guide_id`   — random UUID for the stored guide
 *   - `deep_link`  — `clicky://guide?id=...` native handoff link
 *   - `share_url`  — `https://<share-base>/g/<id>` universal web page
 *
 * The guide can be fetched in raw JSON form via `GET /guide/:id` or in
 * human-readable form via `GET /g/:id`. Both are public — guide ids are
 * random UUIDs, so possession of the id is treated as share-link auth.
 */
async function handleGuideUpload(request: Request, env: Env): Promise<Response> {
  const rawBody = await request.text();

  // Validate JSON parseability before we waste an R2 put on garbage.
  // We don't validate the schema here — the macOS client is responsible
  // for producing a well-formed ClickyGuide. Bad data that survives
  // upload will just fail on the playback side.
  try {
    JSON.parse(rawBody);
  } catch (parseError) {
    console.error(`[/guide/upload] invalid JSON: ${parseError}`);
    return new Response(
      JSON.stringify({ error: "invalid JSON in request body" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  // crypto.randomUUID() is built into the Workers runtime, no import needed
  const guideId = crypto.randomUUID();
  const r2ObjectKey = `guides/${guideId}.json`;

  await env.GUIDE_BUCKET.put(r2ObjectKey, rawBody, {
    httpMetadata: { contentType: "application/json" },
  });

  const deepLink = `clicky://guide?id=${guideId}`;
  const shareBaseURL = resolveShareBaseURL(request, env);
  const shareURL = `${shareBaseURL}/g/${guideId}`;

  console.log(
    `[/guide/upload] stored ${r2ObjectKey} (${rawBody.length} bytes) share=${shareURL}`
  );

  return new Response(
    JSON.stringify({
      guide_id: guideId,
      deep_link: deepLink,
      share_url: shareURL,
    }),
    {
      status: 200,
      headers: { "content-type": "application/json" },
    }
  );
}

/**
 * Resolves the base URL to embed in `share_url` responses.
 *
 * Precedence:
 *   1. `env.SHARE_BASE_URL` if set (wrangler.toml `[vars]` or secret)
 *   2. the request origin (`https://{host}`), so local `wrangler dev`
 *      and `*.workers.dev` preview hostnames both work without config
 *
 * A trailing slash on the configured value is stripped so callers can
 * always append `/g/<id>` cleanly.
 */
function resolveShareBaseURL(request: Request, env: Env): string {
  const configuredBaseURL = env.SHARE_BASE_URL?.trim();
  if (configuredBaseURL && configuredBaseURL.length > 0) {
    return configuredBaseURL.replace(/\/+$/, "");
  }
  const incomingRequestURL = new URL(request.url);
  return `${incomingRequestURL.protocol}//${incomingRequestURL.host}`;
}

/**
 * Fetches a previously uploaded guide from R2 by its random id.
 * Returns the raw JSON body untouched so the macOS client can decode
 * it directly into a `ClickyGuide` struct.
 *
 * This endpoint is intentionally public — guide ids are random UUIDs,
 * so possession of the id is treated as proof-of-access (share-link
 * semantics). No Bearer token, no login.
 */
async function handleGuideGet(url: URL, env: Env): Promise<Response> {
  // URL shape: /guide/{guideId}. Extract the id after the first slash
  // past `/guide/` so ids containing slashes (shouldn't happen with
  // UUIDs, but defensive) still parse cleanly.
  const pathAfterGuidePrefix = url.pathname.slice("/guide/".length);
  const guideId = pathAfterGuidePrefix.split("/")[0];

  if (!guideId) {
    return new Response(
      JSON.stringify({ error: "missing guide id in path" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const r2ObjectKey = `guides/${guideId}.json`;
  const r2Object = await env.GUIDE_BUCKET.get(r2ObjectKey);

  if (!r2Object) {
    console.log(`[/guide/:id] not found: ${r2ObjectKey}`);
    return new Response(
      JSON.stringify({ error: "guide not found", guide_id: guideId }),
      { status: 404, headers: { "content-type": "application/json" } }
    );
  }

  const guideJsonText = await r2Object.text();
  return new Response(guideJsonText, {
    status: 200,
    headers: {
      "content-type": "application/json",
      // Cache for 5 minutes — guides are effectively immutable (we don't
      // support edits), but a short TTL lets us invalidate manually by
      // re-uploading with a new id if needed.
      "cache-control": "public, max-age=300",
    },
  });
}

// ---------------------------------------------------------------------
// Guide share page (GET /g/:id)
//
// Renders a lightweight light-theme HTML page for a guide so the share
// link works in any browser — not just a machine that already has
// Clicky installed. The primary call-to-action on the page is the
// `clicky://guide?id=...` deep link; we also surface an install CTA for
// receivers who don't have the app yet.
//
// Everything is server-rendered (no JS, no external assets) so the
// page loads in one request and the Worker's CPU budget stays tiny.
// User-authored content (title, author name, narration text) is
// passed through `escapeHTMLForTemplate` to prevent injected HTML in
// user content from breaking the page.
// ---------------------------------------------------------------------

/**
 * Subset of the ClickyGuide schema the share page actually reads. We
 * declare it explicitly (instead of trusting the JSON as `any`) so
 * TypeScript can catch field-access typos here — the macOS client is
 * the source of truth for the full schema in `GuidedSession.swift`.
 */
interface ClickyGuideSharePageShape {
  title?: string;
  author?: { name?: string; email?: string | null };
  created_at?: string;
  context?: {
    type?: string;
    target?: string;
    branch?: string | null;
    open_path?: string | null;
    commit_sha?: string | null;
    open_line?: number | null;
    workspace_name?: string | null;
  };
  steps?: Array<{ id?: string; narration?: string }>;
}

async function handleGuideSharePage(url: URL, env: Env): Promise<Response> {
  const pathAfterSharePrefix = url.pathname.slice("/g/".length);
  const guideId = pathAfterSharePrefix.split("/")[0];

  if (!guideId) {
    return renderSharePageHTMLResponse(
      400,
      renderShareErrorPage(
        "Missing guide id",
        "This link doesn't point at a guide. Check that the url looks like /g/<id>."
      )
    );
  }

  const r2ObjectKey = `guides/${guideId}.json`;
  const r2Object = await env.GUIDE_BUCKET.get(r2ObjectKey);

  if (!r2Object) {
    console.log(`[/g/:id] not found: ${r2ObjectKey}`);
    return renderSharePageHTMLResponse(
      404,
      renderShareErrorPage(
        "Guide not found",
        `No guide exists with id <code>${escapeHTMLForTemplate(guideId)}</code>. It may have been deleted or the link may be wrong.`
      )
    );
  }

  const guideJsonText = await r2Object.text();
  let parsedGuide: ClickyGuideSharePageShape;
  try {
    parsedGuide = JSON.parse(guideJsonText) as ClickyGuideSharePageShape;
  } catch (parseError) {
    console.error(`[/g/:id] guide JSON parse failed for ${guideId}: ${parseError}`);
    return renderSharePageHTMLResponse(
      500,
      renderShareErrorPage(
        "Guide unavailable",
        "The stored guide couldn't be read. This is a server-side problem — try again later."
      )
    );
  }

  const renderedHTML = renderGuideSharePage(parsedGuide, guideId);
  return renderSharePageHTMLResponse(200, renderedHTML);
}

function renderSharePageHTMLResponse(statusCode: number, htmlBody: string): Response {
  return new Response(htmlBody, {
    status: statusCode,
    headers: {
      "content-type": "text/html; charset=utf-8",
      // Same 5-minute TTL rationale as /guide/:id — guides are
      // effectively immutable once uploaded.
      "cache-control": statusCode === 200 ? "public, max-age=300" : "no-store",
    },
  });
}

/**
 * HTML-escapes a string for safe insertion into an HTML element body
 * or a double-quoted attribute value. Only handles the five special
 * characters relevant to those two contexts — it is NOT a general
 * sanitizer and must not be used for JS / CSS contexts.
 */
function escapeHTMLForTemplate(rawText: string): string {
  return rawText
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Main share page renderer. Produces a complete HTML document with
 * inline CSS — light theme, single-column, no external assets.
 */
function renderGuideSharePage(
  guide: ClickyGuideSharePageShape,
  guideId: string
): string {
  const safeTitle = escapeHTMLForTemplate(guide.title ?? "Untitled walkthrough");
  const safeAuthorName = escapeHTMLForTemplate(guide.author?.name ?? "Anonymous");
  const safeCreatedAtDisplay = formatCreatedAtForDisplay(guide.created_at);
  const deepLinkURL = `clicky://guide?id=${encodeURIComponent(guideId)}`;
  const safeDeepLinkURLAttribute = escapeHTMLForTemplate(deepLinkURL);

  const contextCardHTML = renderContextCardHTML(guide.context);
  const transcriptPreviewHTML = renderTranscriptPreviewHTML(guide.steps);
  const stepCountLabel = guide.steps?.length
    ? `${guide.steps.length} step${guide.steps.length === 1 ? "" : "s"}`
    : "no steps";

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${safeTitle} — Clicky</title>
<style>
${renderSharePageStyles()}
</style>
</head>
<body>
<header class="page-header">
  <a class="brand" href="/">Clicky</a>
</header>

<main class="share-container">
  <section class="guide-card">
    <div class="guide-meta-row">
      <span class="guide-meta-pill">${escapeHTMLForTemplate(stepCountLabel)}</span>
      ${safeCreatedAtDisplay ? `<span class="guide-meta-dot">·</span><span class="guide-meta-text">${safeCreatedAtDisplay}</span>` : ""}
    </div>

    <h1 class="guide-title">${safeTitle}</h1>
    <p class="guide-author">by ${safeAuthorName}</p>

    ${contextCardHTML}

    <div class="primary-action-row">
      <a class="primary-button" href="${safeDeepLinkURLAttribute}">Open in Clicky</a>
      <p class="primary-action-hint">
        Don't have Clicky yet?
        <a class="secondary-link" href="https://github.com/deepesh-ienergizer/clicky_loom">Install it here</a>.
      </p>
    </div>
  </section>

  ${transcriptPreviewHTML}
</main>

<footer class="page-footer">
  <span>Shared with Clicky · guide id <code>${escapeHTMLForTemplate(guideId)}</code></span>
</footer>
</body>
</html>`;
}

/**
 * Renders the "context" card — the block that shows repo metadata
 * (target, branch, commit, file, workspace) for `type == "repo"`
 * guides, or a simpler label for non-repo contexts.
 *
 * Returns an empty string when no context is present so the page
 * degrades gracefully for legacy guides uploaded before the schema
 * extension.
 */
function renderContextCardHTML(
  context: ClickyGuideSharePageShape["context"]
): string {
  if (!context || !context.type) {
    return "";
  }

  const contextRows: Array<{ rowLabel: string; rowValueHTML: string }> = [];

  if (context.type === "repo") {
    if (context.target) {
      contextRows.push({
        rowLabel: "Repository",
        rowValueHTML: `<code>${escapeHTMLForTemplate(context.target)}</code>`,
      });
    }
    if (context.workspace_name) {
      contextRows.push({
        rowLabel: "Workspace",
        rowValueHTML: escapeHTMLForTemplate(context.workspace_name),
      });
    }
    if (context.branch) {
      contextRows.push({
        rowLabel: "Branch",
        rowValueHTML: `<code>${escapeHTMLForTemplate(context.branch)}</code>`,
      });
    }
    if (context.commit_sha) {
      // Abbreviate sha to first 10 chars for display but keep full
      // value in a title tooltip so the receiver can inspect it.
      const shortSha = context.commit_sha.slice(0, 10);
      contextRows.push({
        rowLabel: "Commit",
        rowValueHTML: `<code title="${escapeHTMLForTemplate(context.commit_sha)}">${escapeHTMLForTemplate(shortSha)}</code>`,
      });
    }
    if (context.open_path) {
      const displayPath = typeof context.open_line === "number"
        ? `${context.open_path}:${context.open_line}`
        : context.open_path;
      contextRows.push({
        rowLabel: "Open file",
        rowValueHTML: `<code>${escapeHTMLForTemplate(displayPath)}</code>`,
      });
    }
  } else if (context.target) {
    // Non-repo contexts get a single-row summary so the viewer can
    // still see what the guide is about (e.g. app bundle id, url).
    const friendlyTypeLabel =
      context.type === "app"
        ? "App"
        : context.type === "url"
          ? "Web page"
          : context.type === "file"
            ? "File"
            : context.type;
    contextRows.push({
      rowLabel: escapeHTMLForTemplate(friendlyTypeLabel),
      rowValueHTML: `<code>${escapeHTMLForTemplate(context.target)}</code>`,
    });
  }

  if (contextRows.length === 0) {
    return "";
  }

  const rowsHTML = contextRows
    .map(
      (singleRow) => `
    <div class="context-row">
      <span class="context-label">${singleRow.rowLabel}</span>
      <span class="context-value">${singleRow.rowValueHTML}</span>
    </div>`
    )
    .join("");

  return `<div class="context-card">${rowsHTML}</div>`;
}

/**
 * Renders a read-only transcript preview — the narration text from
 * the first few steps. Capped at 3 steps so the page stays above the
 * fold. If there are more steps we show a "+N more steps" footer.
 */
function renderTranscriptPreviewHTML(
  steps: ClickyGuideSharePageShape["steps"]
): string {
  if (!steps || steps.length === 0) {
    return "";
  }

  const maxPreviewSteps = 3;
  const previewSlice = steps.slice(0, maxPreviewSteps);
  const remainingStepCount = Math.max(0, steps.length - previewSlice.length);

  const previewStepsHTML = previewSlice
    .map((singleStep, stepIndex) => {
      const safeNarration = escapeHTMLForTemplate(
        (singleStep.narration ?? "").trim() || "(no narration)"
      );
      return `
    <li class="preview-step">
      <span class="preview-step-number">${stepIndex + 1}</span>
      <p class="preview-step-narration">${safeNarration}</p>
    </li>`;
    })
    .join("");

  const remainingFooterHTML = remainingStepCount > 0
    ? `<p class="preview-more">+${remainingStepCount} more step${remainingStepCount === 1 ? "" : "s"} in the full walkthrough</p>`
    : "";

  return `
  <section class="preview-card">
    <h2 class="preview-title">What you'll walk through</h2>
    <ol class="preview-steps">${previewStepsHTML}</ol>
    ${remainingFooterHTML}
  </section>`;
}

/**
 * Renders the same light-theme layout as the main share page but with
 * an error headline and explanation instead of guide content. Used
 * for 400/404/500 responses so the UX stays consistent.
 */
function renderShareErrorPage(headline: string, explanationHTML: string): string {
  const safeHeadline = escapeHTMLForTemplate(headline);
  // explanationHTML is intentionally NOT escaped — callers pass
  // pre-escaped strings (or safe static HTML like <code>) so this
  // rendering path can include minor markup.
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${safeHeadline} — Clicky</title>
<style>
${renderSharePageStyles()}
</style>
</head>
<body>
<header class="page-header">
  <a class="brand" href="/">Clicky</a>
</header>

<main class="share-container">
  <section class="guide-card">
    <h1 class="guide-title">${safeHeadline}</h1>
    <p class="error-explanation">${explanationHTML}</p>
  </section>
</main>

<footer class="page-footer">
  <span>Clicky · shared walkthroughs</span>
</footer>
</body>
</html>`;
}

/**
 * Tiny date formatter for the "shared on" label. Kept as a string
 * pass-through when parsing fails so we don't 500 the whole page over
 * a slightly-off ISO timestamp.
 */
function formatCreatedAtForDisplay(rawCreatedAtString: string | undefined): string {
  if (!rawCreatedAtString) return "";
  const parsedDate = new Date(rawCreatedAtString);
  if (Number.isNaN(parsedDate.getTime())) {
    return escapeHTMLForTemplate(rawCreatedAtString);
  }
  // Deliberately simple — no timezone handling, no locale switch.
  // Matches the aesthetic of "recorded April 11, 2026".
  const monthLabels = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ];
  const dayOfMonth = parsedDate.getUTCDate();
  const monthLabel = monthLabels[parsedDate.getUTCMonth()];
  const fullYear = parsedDate.getUTCFullYear();
  return `${monthLabel} ${dayOfMonth}, ${fullYear}`;
}

/**
 * All of the inline CSS for the share + error pages, kept in one
 * place so both renderers share a single aesthetic. Light theme,
 * system font stack, no external fetches.
 */
function renderSharePageStyles(): string {
  return `
:root {
  --color-background: #f7f8fa;
  --color-surface: #ffffff;
  --color-surface-sunken: #f1f3f6;
  --color-border: #e5e7eb;
  --color-text-primary: #0f172a;
  --color-text-secondary: #475569;
  --color-text-tertiary: #94a3b8;
  --color-accent: #2563eb;
  --color-accent-hover: #1d4ed8;
  --font-stack: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  --mono-stack: ui-monospace, SFMono-Regular, Menlo, Monaco, "Liberation Mono", monospace;
}

* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  font-family: var(--font-stack);
  background: var(--color-background);
  color: var(--color-text-primary);
  -webkit-font-smoothing: antialiased;
  line-height: 1.5;
}

.page-header {
  max-width: 720px;
  margin: 0 auto;
  padding: 28px 24px 0;
}
.brand {
  font-size: 14px;
  font-weight: 600;
  letter-spacing: 0.2px;
  color: var(--color-text-primary);
  text-decoration: none;
}

.share-container {
  max-width: 720px;
  margin: 0 auto;
  padding: 24px;
}

.guide-card {
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: 14px;
  padding: 32px;
  box-shadow: 0 1px 2px rgba(15, 23, 42, 0.04);
}

.guide-meta-row {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
  color: var(--color-text-tertiary);
  margin-bottom: 12px;
}
.guide-meta-pill {
  background: var(--color-surface-sunken);
  border-radius: 999px;
  padding: 3px 10px;
  font-weight: 500;
  color: var(--color-text-secondary);
}
.guide-meta-dot { opacity: 0.6; }
.guide-meta-text { color: var(--color-text-tertiary); }

.guide-title {
  font-size: 26px;
  font-weight: 700;
  margin: 0 0 4px;
  line-height: 1.25;
  color: var(--color-text-primary);
}
.guide-author {
  font-size: 14px;
  color: var(--color-text-secondary);
  margin: 0 0 20px;
}

.context-card {
  background: var(--color-surface-sunken);
  border: 1px solid var(--color-border);
  border-radius: 10px;
  padding: 14px 16px;
  margin-bottom: 24px;
}
.context-row {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  padding: 6px 0;
  font-size: 13px;
}
.context-row + .context-row {
  border-top: 1px dashed var(--color-border);
}
.context-label {
  flex: 0 0 95px;
  color: var(--color-text-tertiary);
  font-weight: 500;
  text-transform: uppercase;
  font-size: 10px;
  letter-spacing: 0.4px;
  padding-top: 2px;
}
.context-value {
  flex: 1 1 auto;
  color: var(--color-text-primary);
  word-break: break-all;
}
.context-value code,
.error-explanation code,
.page-footer code {
  font-family: var(--mono-stack);
  font-size: 12px;
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: 4px;
  padding: 1px 6px;
}

.primary-action-row {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 8px;
  margin-top: 8px;
}
.primary-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  background: var(--color-accent);
  color: #ffffff;
  font-weight: 600;
  font-size: 14px;
  padding: 11px 22px;
  border-radius: 8px;
  text-decoration: none;
  transition: background-color 0.15s ease;
}
.primary-button:hover { background: var(--color-accent-hover); }
.primary-action-hint {
  font-size: 12px;
  color: var(--color-text-tertiary);
  margin: 0;
}
.secondary-link {
  color: var(--color-accent);
  text-decoration: none;
}
.secondary-link:hover { text-decoration: underline; }

.preview-card {
  margin-top: 24px;
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: 14px;
  padding: 24px 32px;
  box-shadow: 0 1px 2px rgba(15, 23, 42, 0.04);
}
.preview-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--color-text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.4px;
  margin: 0 0 16px;
}
.preview-steps {
  list-style: none;
  padding: 0;
  margin: 0;
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.preview-step {
  display: flex;
  gap: 14px;
  align-items: flex-start;
}
.preview-step-number {
  flex: 0 0 24px;
  height: 24px;
  border-radius: 999px;
  background: var(--color-surface-sunken);
  color: var(--color-text-secondary);
  font-size: 12px;
  font-weight: 600;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.preview-step-narration {
  flex: 1 1 auto;
  margin: 2px 0 0;
  font-size: 14px;
  color: var(--color-text-primary);
  white-space: pre-wrap;
}
.preview-more {
  margin: 16px 0 0;
  font-size: 12px;
  color: var(--color-text-tertiary);
}

.error-explanation {
  font-size: 14px;
  color: var(--color-text-secondary);
  margin: 8px 0 0;
}

.page-footer {
  max-width: 720px;
  margin: 0 auto;
  padding: 24px;
  font-size: 12px;
  color: var(--color-text-tertiary);
  text-align: center;
}

@media (max-width: 560px) {
  .guide-card, .preview-card { padding: 24px; border-radius: 12px; }
  .guide-title { font-size: 22px; }
  .context-label { flex-basis: 80px; }
}
`;
}

/**
 * Kicks off an AssemblyAI batch transcription job for a WAV audio blob.
 *
 * The client sends the raw WAV bytes as the POST body (Content-Type:
 * audio/wav). This handler:
 *
 *   1. Streams the bytes to `POST https://api.assemblyai.com/v2/upload`
 *      which returns a short-lived `upload_url`.
 *   2. Starts a transcript job via `POST .../v2/transcript` with that
 *      url. AssemblyAI returns `{id, status: "queued", ...}`.
 *   3. Returns `{ transcript_id }` to the client immediately.
 *
 * The client then polls `/audio/transcribe/status/:id` until the job
 * is `completed` and has `text` + `words` populated. We don't await
 * transcription completion in this handler because AssemblyAI batch
 * jobs can take 10-30 seconds which eats into worker CPU time budget.
 *
 * Note: AssemblyAI batch upload accepts binary directly at
 * `/v2/upload` — no multipart form-data needed — with the raw audio
 * bytes as the request body. That makes the Worker proxy trivial.
 */
async function handleAudioTranscribeSubmit(
  request: Request,
  env: Env
): Promise<Response> {
  // Step 1: stream the audio bytes to AssemblyAI's upload endpoint.
  // Passing `request.body` as the ReadableStream means the Worker
  // never has to buffer the full audio in memory — it proxies.
  const uploadResponse = await fetch("https://api.assemblyai.com/v2/upload", {
    method: "POST",
    headers: {
      authorization: env.ASSEMBLYAI_API_KEY,
      // AssemblyAI's upload endpoint wants a content-type that isn't
      // JSON but doesn't care about the exact value beyond that.
      "content-type": "application/octet-stream",
    },
    body: request.body,
  });

  if (!uploadResponse.ok) {
    const errorBody = await uploadResponse.text();
    console.error(
      `[/audio/transcribe/submit] upload error ${uploadResponse.status}: ${errorBody}`
    );
    return new Response(
      JSON.stringify({
        error: "audio upload failed",
        assemblyai_status: uploadResponse.status,
        assemblyai_body: errorBody,
      }),
      { status: 502, headers: { "content-type": "application/json" } }
    );
  }

  const uploadResultJson = (await uploadResponse.json()) as { upload_url?: string };
  if (!uploadResultJson.upload_url) {
    console.error(
      `[/audio/transcribe/submit] upload response missing upload_url: ${JSON.stringify(uploadResultJson)}`
    );
    return new Response(
      JSON.stringify({ error: "upload response missing upload_url" }),
      { status: 502, headers: { "content-type": "application/json" } }
    );
  }

  // Step 2: create a transcript job pointing at the upload_url.
  // We ask for word-level timestamps (`auto_chapters` off,
  // punctuation on) since `GuideUploadQueue` needs to segment the
  // transcript by screenshot timestamps — word-level timing is how.
  const transcriptCreateResponse = await fetch(
    "https://api.assemblyai.com/v2/transcript",
    {
      method: "POST",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        audio_url: uploadResultJson.upload_url,
        punctuate: true,
        format_text: true,
        // AssemblyAI now requires an explicit speech_models list on
        // /v2/transcript. Universal-2 is the standard-quality model
        // available on all tiers; Universal-3-Pro is the premium
        // option. We pick Universal-2 for the prototype because the
        // accuracy is sufficient for guide narration and it's the
        // more predictable billing target.
        speech_models: ["universal-2"],
      }),
    }
  );

  if (!transcriptCreateResponse.ok) {
    const errorBody = await transcriptCreateResponse.text();
    console.error(
      `[/audio/transcribe/submit] transcript create error ${transcriptCreateResponse.status}: ${errorBody}`
    );
    return new Response(
      JSON.stringify({
        error: "transcript create failed",
        assemblyai_status: transcriptCreateResponse.status,
        assemblyai_body: errorBody,
      }),
      { status: 502, headers: { "content-type": "application/json" } }
    );
  }

  const transcriptCreateJson = (await transcriptCreateResponse.json()) as { id?: string };
  if (!transcriptCreateJson.id) {
    return new Response(
      JSON.stringify({ error: "transcript create response missing id" }),
      { status: 502, headers: { "content-type": "application/json" } }
    );
  }

  return new Response(
    JSON.stringify({ transcript_id: transcriptCreateJson.id }),
    { status: 200, headers: { "content-type": "application/json" } }
  );
}

/**
 * Polls AssemblyAI for the status of a previously-submitted transcript
 * job. The client calls this every ~1s from Swift until `status`
 * becomes `completed` or `error`, then reads `text` and `words`.
 *
 * Returns the raw AssemblyAI response verbatim so the Swift client can
 * decode whichever fields it needs without a second schema definition
 * on the proxy side.
 */
async function handleAudioTranscribeStatus(
  url: URL,
  env: Env
): Promise<Response> {
  const pathAfterStatusPrefix = url.pathname.slice("/audio/transcribe/status/".length);
  const transcriptId = pathAfterStatusPrefix.split("/")[0];

  if (!transcriptId) {
    return new Response(
      JSON.stringify({ error: "missing transcript id in path" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const statusResponse = await fetch(
    `https://api.assemblyai.com/v2/transcript/${encodeURIComponent(transcriptId)}`,
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!statusResponse.ok) {
    const errorBody = await statusResponse.text();
    console.error(
      `[/audio/transcribe/status/${transcriptId}] error ${statusResponse.status}: ${errorBody}`
    );
    return new Response(errorBody, {
      status: statusResponse.status,
      headers: { "content-type": "application/json" },
    });
  }

  const statusBody = await statusResponse.text();
  return new Response(statusBody, {
    status: 200,
    headers: {
      "content-type": "application/json",
      // Don't cache — status changes over time.
      "cache-control": "no-store",
    },
  });
}
