# RFC: Simplify the Admin Web UI with htmx 4

| | |
|---|---|
| **Status** | Draft — for discussion |
| **Branch** | `rfc/htmx-admin-ui` |
| **Author** | franky (AI coding agent) |
| **Created** | 2025-09-08 |
| **Target release** | v0.6.0 (proposed) |

## 1. Summary

Replace the hand-rolled JavaScript admin front-end with a thin
[htmx 4](https://four.htmx.org) layer, and move all view rendering from the
browser into the Zig server. The server stops emitting JSON for admin views
and instead emits **HTML fragments** that htmx swaps into the page. This
removes ~270 lines of JavaScript (every `loadX()` view-builder, the
`api()`/`headers()`/`escapeHtml()` helpers, the toast/spinner code, the
mobile-nav toggle, and the dispatch form wiring) and lets the single
`admin.html` shell collapse to a static layout plus a handful of `hx-*`
attributes.

The agent-facing JSON API (`/v1/...`) is **untouched** — only the
`/admin/*` admin routes and `src/web/admin.html` change.

## 2. Motivation

### 2.1 Current state

`src/web/admin.html` is a 479-line single-file SPA. It:

- Loads Pico CSS from a CDN and ships a 180-line `<style>` block (kept).
- Renders a nav bar with `onclick="loadAgents(); closeNav();"` handlers.
- Contains a `<section id="content">` that is **empty** on first paint.
- Ships ~270 lines of vanilla JS (18 functions) that:
  - read an auth token from a cookie (`fb_admin_token`),
  - `fetch()` six JSON endpoints (`/admin/agents`, `/admin/inbox`,
    `/admin/outbox`, `/admin/archive`, `/admin/workstreams`,
    `/admin/dispatch`),
  - hand-build HTML strings with string concatenation + `escapeHtml()` /
    `escapeJson()`,
  - inject the result via `el.innerHTML = html`,
  - manage a spinner, toast notifications, a mobile-nav toggle, and a
    dispatch form whose `<select>` of workstreams is populated by a
    second fetch.

`src/server.zig` (787 lines) dedicates **~330 lines** to nine admin
handlers (`handleAdminPage`, `handleAdminApi`, `handleAdminAgentsApi`,
`handleAdminInboxApi`, `handleAdminOutboxApi`, `handleAdminArchiveApi`,
`handleAdminWorkstreamsApi`, `handleAdminDispatch`,
`handleAdminRegisterAgent`). Six of those build JSON by hand with
`std.ArrayList(u8)` + `buf.print(...)` + a custom `jsonString()` escaper
and a hand-rolled `extractJsonField()` scanner for the dispatch body.

### 2.2 Problems

1. **Duplicated rendering logic.** Every view exists twice: once as a
   JSON shape in `server.zig` and once as an HTML template in
   `admin.html`. Adding a column means touching both files in two
   languages. The Inbox, Outbox, and Archive tables are near-identical
   in JS yet copy-pasted.
2. **Duplicated escaping logic.** The server has `jsonString()` /
   `emitOptField()` / `jsonPayload()` for JSON; the browser has
   `escapeHtml()` / `escapeJson()` for HTML. Two escapers, two bug
   surfaces. (The current server JSON builders also `buf.print` raw
   `agent_id`/`action`/`tenant_id` **without** `jsonString()` — a
   latent JSON-injection / corruption bug if any field ever contains a
   quote or backslash.)
3. **No CSRF / no `<form>` semantics.** The dispatch "form" is a
   `<form onsubmit="return doDispatch(event)">` that never actually
   submits — JS reads fields by `id` and `JSON.stringify`s them. It is
   invisible to no-JS clients and bypasses native validation wiring.
4. **Hand-rolled JSON parser on the server.** `extractJsonField()` is a
   ~120-line character scanner because the admin dispatch endpoint
   accepts JSON but the codebase has no JSON library. htmx submits
   `application/x-www-form-urlencoded` by default, which Zig's
   `std` can parse trivially — eliminating the scanner entirely.
5. **No progressive enhancement.** With JS disabled the page shows
   "Select a tab above." and every nav link is a dead `#` anchor.
6. **Mobile nav is JS-only.** The hamburger toggle is a `click` listener
   that toggles a `.open` class; it is inaccessible without JS.
7. **Token in a cookie read by JS.** `fb_admin_token` is a
   non-`HttpOnly` cookie so that `getCookie()` can read it. htmx sends
   cookies automatically (same-origin), so the cookie can become
   `HttpOnly` and disappear from `document.cookie` — removing an XSS
   token-exfil vector.

### 2.3 Why htmx 4 (and not 2.x, or a framework)

htmx is a 50 KB (minified) dependency-free library that extends HTML with
`hx-get` / `hx-post` / `hx-target` / `hx-swap` attributes. The browser
issues a normal HTTP request; the server responds with an **HTML
fragment**; htmx swaps it into the DOM. No client-side rendering, no
client-side JSON parsing, no client-side templating.

**Why htmx 4 specifically:**

- htmx 4.0.0 shipped 2026-08-28 and is the current major. htmx 2.x is in
  maintenance (the project has stated 2.x stays supported, but `latest`
  moves to 4 in early 2027). Starting a **new** integration on 2.x today
  would mean a forced migration within ~18 months.
- The breaking changes in 4 (explicit inheritance, `fetch()` instead of
  `XMLHttpRequest`, error responses swap, 60s default timeout, event
  renames, `hx-disable`→`hx-ignore`) **do not affect this RFC** because
  we are writing net-new htmx markup, not upgrading an existing htmx 2
  app. There is no migration surface.
- htmx 4's new `hx-status` attribute + "error responses swap" default is
  a *good fit* for the admin UI: a 401 from a stale token can return a
  "Session expired — reload" fragment and htmx will swap it in
  automatically, with zero JS.
- htmx 4 moved SSE, WebSocket, and many other features into opt-in
  extensions (loaded via `<script src>`, no `hx-ext`). We need none of
  them for the admin UI — plain `hx-get` polling is enough — so the
  core is all we ship.

**Why not a JS SPA framework (React/Vue/Svelte)?**

- The admin UI is 6 read-only tables + 1 form. A SPA is 10–50× the
  build tooling, bundle, and complexity for zero feature gain.
- The server is Zig with no JS toolchain; a SPA would require
  introducing `npm`/a bundler into the build. htmx is one `<script>`
  tag (or can be vendored as a static file like Pico).
- The whole point of this RFC is to **remove** client-side rendering,
  not replace it with a different client-side renderer.

**Why not stay vanilla JS?**

Because the vanilla JS is exactly the code being simplified. The
duplication and double-escaping problems (§2.2) are structural to
"server emits JSON, browser builds HTML" and cannot be fixed by tidying
the JS — only by picking one render location. htmx lets that location be
the server, where Zig already has the data in scope.

## 3. Proposal

### 3.1 Architecture

```
Browser                          Zig server (src/server.zig)
───────                          ──────────────────────────
GET /admin            ───────►   handleAdminPage
                                 → emits full admin.html shell
                                   (static nav + empty #content +
                                   <script src="htmx.min.js">)
                                   AND seeds #content via an inline
                                   hx-get that fires on load

click "Inbox" nav     ───► hx-get="/admin/fragments/inbox"
                                 handleAdminInboxFragment
                                 → emits ONLY the <h2>+<table> HTML
htmx swaps #content   ◄─── HTML fragment (text/html)
                                   (no JSON, no {tasks:[...]})

submit dispatch form  ─► hx-post="/admin/dispatch"
                                 (form-encoded, not JSON)
                                 handleAdminDispatch
                                 → on success: 200 + toast fragment
                                   → htmx swaps #dispatchResult
                                 → on error: 4xx + error fragment
                                   → htmx swaps #dispatchResult
                                   (htmx 4 swaps errors by default)
```

Key shifts:

| Concern | Before | After |
|---|---|---|
| View rendering | browser JS string concat | Zig `std.fmt` / `std.ArrayList` |
| Data format to browser | JSON (`{\"tasks\":[...]}`) | HTML fragments |
| Dispatch request body | `application/json` | `application/x-www-form-urlencoded` |
| Server JSON parsing | `extractJsonField()` scanner (120 LoC) | `std` form decoding (~10 LoC) |
| Auth token cookie | non-HttpOnly, read by JS | `HttpOnly`, sent automatically by htmx |
| Client JS | ~270 LoC (18 fns) | ~0 (a few `hx-on` one-liners if needed) |
| Mobile nav | JS toggle | `<details>`/`<summary>` or CSS `:target` |
| Toasts | JS `showToast()` | server-emitted `<div class="toast">` fragment |
| Spinner | JS `.spinner` inject | htmx `hx-indicator` + CSS class |
| Errors | JS try/catch → toast | htmx 4 swaps 4xx/5xx HTML into target |

### 3.2 Routes

**Agent JSON API — unchanged:**

| Method | Path | Handler | Body |
|---|---|---|---|
| POST | `/v1/agents` | `handleRegisterAgent` | JSON |
| POST | `/v1/tasks/dispatch` | `handleDispatch` | JSON |
| POST | `/v1/agents/{id}/inbox/claim` | `handleClaim` | — |
| GET  | `/v1/agents/{id}/outbox` | `handleReadOutbox` | — |
| POST | `/v1/agents/{id}/outbox/{task}/ack` | `handleAck` | — |
| POST | `/v1/agents/{id}/outbox/ack-all` | `handleAckAll` | — |
| POST | `/v1/agents/{id}/outbox/{task}/complete` | `handleComplete` | JSON |
| POST | `/v1/agents/{id}/outbox/{task}/fail` | `handleFail` | JSON |
| GET  | `/v1/results/{id}` | `handleGetResult` | — |

**Admin routes — restructured.** The existing JSON endpoints become
HTML-fragment endpoints. The URL space moves under
`/admin/fragments/*` to make the content-negotiation intent explicit and
to keep the fragment handlers visually separate in the router.

| Method | Path | Returns | Replaces |
|---|---|---|---|
| GET  | `/admin` | full HTML shell | (unchanged) `handleAdminPage` |
| GET  | `/admin/api` | JSON `{status,version}` | (unchanged) `handleAdminApi` — kept for `update --check` |
| GET  | `/admin/fragments/agents` | HTML fragment | `handleAdminAgentsApi` (JSON) |
| GET  | `/admin/fragments/inbox` | HTML fragment | `handleAdminInboxApi` (JSON) |
| GET  | `/admin/fragments/outbox` | HTML fragment | `handleAdminOutboxApi` (JSON) |
| GET  | `/admin/fragments/archive` | HTML fragment | `handleAdminArchiveApi` (JSON) |
| GET  | `/admin/fragments/workstreams` | HTML fragment | `handleAdminWorkstreamsApi` (JSON) |
| GET  | `/admin/fragments/dispatch` | HTML fragment (the form) | `showDispatch()` JS |
| GET  | `/admin/fragments/workstream-options` | HTML fragment (`<option>`s) | `loadWorkstreamOptions()` JS |
| POST | `/admin/dispatch` | HTML fragment (toast) | `handleAdminDispatch` (JSON → HTML) |
| POST | `/admin/agents` | HTML fragment (updated agents table) | `handleAdminRegisterAgent` (JSON → HTML) |

`/admin/api` stays JSON because `franky-box update --check` parses it
programmatically (see `src/update.zig`). Everything else that was JSON
only existed to feed the browser and becomes HTML.

### 3.3 `admin.html` shell (sketch)

The 180-line `<style>` block is kept verbatim (Pico + responsive table
CSS). The `<nav>` and the ~270-line `<script>` are replaced:

```html
<!DOCTYPE html>
<html lang="en" lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Franky-Box Admin</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css">
  <!-- htmx 4: pin an exact version, do not use @latest (4 is not `latest` until 2027) -->
  <script src="https://unpkg.com/htmx.org@4.0.0/dist/htmx.min.js"></script>
  <style> /* …existing 180 lines unchanged… */ </style>
</head>
<body>
  <nav class="container-fluid">
    <!-- <details>/<summary> replaces the JS hamburger; works with no JS -->
    <details class="navbar">
      <summary class="navbar-brand">🔧 Franky-Box Admin</summary>
      <ul class="navbar-links">
        <li><a hx-get="/admin/fragments/agents"      hx-target="#content">Agents</a></li>
        <li><a hx-get="/admin/fragments/inbox"       hx-target="#content">Inbox</a></li>
        <li><a hx-get="/admin/fragments/outbox"      hx-target="#content">Outbox</a></li>
        <li><a hx-get="/admin/fragments/archive"     hx-target="#content">Archive</a></li>
        <li><a hx-get="/admin/fragments/workstreams" hx-target="#content">Workstreams</a></li>
        <li><a hx-get="/admin/fragments/dispatch"    hx-target="#content">Send Task</a></li>
      </ul>
    </details>
  </nav>
  <main class="container">
    <hr/>
    <!-- hx-trigger="load" fires once on page load → seeds Agents table,
         replacing the loadAgentsOnStart() IIFE -->
    <section id="content"
             hx-get="/admin/fragments/agents"
             hx-trigger="load"
             hx-swap="innerHTML">
      <div class="spinner" hx-indicator="this"></div>
    </section>
  </main>
</body>
</html>
```

No `<script>` block of our own. The htmx `<script>` is the only JS.

**Notes on the htmx 4 specifics used here:**

- `hx-target="#content"` — standard, unchanged from htmx 2.
- `hx-trigger="load"` — standard.
- `hx-indicator="this"` — the spinner div is shown during the request
  and hidden after. In htmx 4 the indicator CSS is emitted via
  Constructable Stylesheets (no nonce needed), but our `.spinner` class
  is already in our own `<style>`, so we just add `hx-indicator` and
  keep the existing keyframes.
- We use **no** `:inherited` attributes, no extensions, no SSE/WS, no
  `hx-ext`, no `hx-vals`/`hx-vars`, no `queue:` modifier, no
  `htmx.config.*` overrides. Everything is core htmx 4.
- Auth: the `fb_admin_token` cookie is sent automatically with every
  same-origin `hx-get`/`hx-post`. The cookie should be marked
  `HttpOnly` (and `SameSite=Strict`) when set. htmx needs no
  `Authorization` header and no `hx-headers`.

### 3.4 Fragment handlers (server side)

Each existing `handleAdminXApi` is rewritten to emit HTML instead of
JSON. Example — the inbox:

```zig
fn handleAdminInboxFragment(self: *Server, req: *http.Server.Request) !void {
    if (!requireAdmin(req)) return htmlError(req, .unauthorized, "unauthorized");
    const a = self.allocator;
    const tasks = self.store.fetchInbox(a) catch |err|
        return htmlError(req, .internal_server_error, @errorName(err));
    defer { for (tasks) |t| t.deinit(a); a.free(tasks); }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "<h2 id=\"inbox\">📥 Inbox (Pending Tasks)</h2>");
    if (tasks.len == 0) {
        try buf.appendSlice(a, "<p>No pending tasks.</p>");
    } else {
        try buf.appendSlice(a,
            "<table class=\"resp-table\"><thead><tr>" ++
            "<th>Task ID</th><th>Workstream</th><th>Agent</th>" ++
            "<th>Action</th><th>Payload</th><th>Try</th><th>Locked Until</th>" ++
            "</tr></thead><tbody>");
        for (tasks) |t| {
            const lock_class = if (t.locked_until != null) "locked" else "pending";
            try buf.print(a,
                "<tr><td data-label=\"Task ID\"><code>{s}</code></td>" ++
                "<td data-label=\"Workstream\"><code>{s}</code></td>" ++
                "<td data-label=\"Agent\">{s}</td>" ++
                "<td data-label=\"Action\">{s}</td>" ++
                "<td data-label=\"Payload\"><pre>{s}</pre></td>" ++
                "<td data-label=\"Try\"><span class=\"status-badge {s}\">{d}</span></td>" ++
                "<td data-label=\"Locked Until\">{s}</td></tr>",
                .{ htmlEsc(t.task_id), htmlEsc(t.workstream_id orelse "-"),
                   htmlEsc(t.agent_id), htmlEsc(t.action),
                   htmlEsc(t.payload), lock_class, t.try_count,
                   htmlEsc(t.locked_until orelse "-") });
        }
        try buf.appendSlice(a, "</tbody></table>");
    }
    try htmlResp(req, buf.items);
}
```

A single `htmlEsc()` helper (an `htmlEscape(buf, a, src) !void` that
appends) replaces both the browser `escapeHtml()` and, for the admin
views, the server `jsonString()`. HTML-escaping is the only escaping
needed now — there is no second encoding layer.

**Dispatch — form-encoded, no JSON scanner.** The dispatch form becomes
a real `<form>`:

```html
<form hx-post="/admin/dispatch" hx-target="#dispatchResult" hx-swap="innerHTML">
  <label>Agent ID <input name="agent_id" value="agent-0" required></label>
  <label>Action   <input name="action"   value="process"  required></label>
  <label>Payload (JSON) <textarea name="payload" rows="4" required>{"key":"value"}</textarea></label>
  <fieldset>
    <legend>Workstream</legend>
    <label>Join existing
      <select name="workstream_id"
              hx-get="/admin/fragments/workstream-options"
              hx-target="this" hx-trigger="load">
        <option value="">— none (create new below) —</option>
      </select>
    </label>
    <label>…or create by name
      <input type="text" name="workstream_name" maxlength="256">
    </label>
  </fieldset>
  <button type="submit">🚀 Dispatch</button>
</form>
<div id="dispatchResult"></div>
```

htmx submits this as `application/x-www-form-urlencoded`. The server
parses it with a tiny `formField()` helper (~15 lines, URL-decode +
split on `&`/`=`), and `extractJsonField()` (the 120-line JSON scanner)
is **deleted**. On success the handler returns `200` + a
`<div class="toast success">…</div>` fragment; on error it returns `4xx`
+ a `<div class="toast error">…</div>` fragment. Because htmx 4 swaps
error responses by default, the error toast lands in `#dispatchResult`
with zero JS.

**Register agent** follows the same pattern: a `<form
hx-post="/admin/agents" hx-target="#agents-table">` that returns the
refreshed agents `<tbody>`.

### 3.5 Polling (optional, incremental)

A common follow-up is auto-refreshing the inbox. With htmx this is one
attribute on the fragment's own root:

```html
<div hx-get="/admin/fragments/inbox" hx-trigger="every 5s" hx-target="this" hx-swap="outerHTML">
  …table…
</div>
```

This is **not** part of the initial migration but is called out to show
the ceiling: features that today would each be ~30 LoC of JS become one
attribute.

### 3.6 Vendoring htmx (option B)

To avoid a runtime CDN dependency (offline / air-gapped / reproducible
builds), htmx 4 `htmx.min.js` (~50 KB) can be vendored under
`src/web/htmx.min.js` and `@embedFile`-ed, exactly as `admin.html` is
today, and served from a `/admin/static/htmx.min.js` route (or inlined
into the shell). This keeps the single-binary deployment story. The RFC
proposes **vendoring** as the default and CDN as opt-out, matching how
SQLite is already vendored under `vendor/`.

## 4. Detailed design

### 4.1 New helpers in `server.zig`

- `fn htmlEscape(buf: *std.ArrayList(u8), a: std.mem.Allocator, src: []const u8) !void`
  — appends `src` to `buf` with `&`/`<`/`>`/`"`/`'` escaped. One helper
  replaces `escapeHtml` (JS) and, for admin views, `jsonString`.
- `fn htmlResp(req, body) !void` — already exists; reused as-is.
- `fn htmlError(req, status, msg) !void` — responds with
  `<div class="toast error">{msg}</div>` (HTML-escaped) at the given
  status. Used for 401/500 from fragment handlers so htmx 4 swaps a
  user-visible error instead of a blank swap.
- `fn formField(body: []const u8, name: []const u8, a) ?[]u8` —
  URL-decode + scan `name=` in `application/x-www-form-urlencoded`
  bodies. Replaces `extractJsonField` for the admin dispatch/register
  routes. (The agent JSON routes keep `extractJsonField` for now; a
  future RFC can migrate them to `std.json` or form-encoding.)

### 4.2 Removed code

- `src/web/admin.html`: the entire `<script>…</script>` block
  (lines ~207–478, ~270 LoC) except the single htmx `<script src>`. The
  `onclick="loadX(); closeNav();"` handlers on nav links become
  `hx-get`/`hx-target`. The mobile-nav JS becomes a `<details>`/`<summary>`.
- `src/server.zig`:
  - `extractJsonField` (only if no other admin route still uses JSON
    input — the agent routes do, so it stays for now; but the admin
    dispatch path stops calling it).
  - `jsonString`, `emitOptField`, `jsonPayload` — reviewed per call
    site. The admin fragment handlers no longer need them. If the agent
    JSON routes still need JSON string escaping, `jsonString` stays but
    is scoped to those handlers; otherwise it moves to a shared util.

### 4.3 Security improvements (side effects)

1. **HttpOnly cookie.** `fb_admin_token` can be set with `HttpOnly;
   SameSite=Strict; Path=/admin`. It vanishes from `document.cookie`,
   closing the XSS-reads-the-admin-token vector. htmx, being
   same-origin `fetch()`, still sends it.
2. **One escaper, correct by construction.** HTML-escaping for HTML
   output is the only escape boundary. The current latent bug where
   `buf.print("{s}", .{t.action})` emits raw user data into JSON (no
   `jsonString()`) is eliminated because the same data goes through
   `htmlEscape` into HTML.
3. **CSRF.** htmx same-origin requests send the cookie. If we later add
   cross-site exposure, a CSRF token can be injected via
   `hx-config`/`htmx:config:request` — out of scope here, but the
   `SameSite=Strict` cookie already blocks the common CSRF case.

### 4.4 Build & packaging

- No new build step. htmx is either a CDN `<script src>` (zero build
  impact) or a vendored `@embedFile` (same as `admin.html` today).
- No `npm`, no bundler, no Node toolchain. `zig build` is unchanged.
- Binary size: +~50 KB if htmx is embedded (vs. the ~270 LoC of JS
  removed from the HTML, which is ~10–15 KB minified). Net near-zero.

### 4.5 Tests

- `tests/integration_test.zig` currently asserts on JSON shapes from
  `/admin/agents` etc. These assertions change to assert on HTML
  fragments (substring checks like
  `std.mem.indexOf(u8, body, "<table class=\"resp-table\">")` and
  `std.mem.indexOf(u8, body, escapeHtml(agent_id))`). The agent API
  tests (`/v1/...`) are untouched.
- A new test: `GET /admin` returns the shell containing
  `<script src="…/htmx.min.js">` (or the inlined htmx) and an
  `hx-trigger="load"` on `#content`.
- A new test: `POST /admin/dispatch` with form-encoded body succeeds
  and returns a `toast success` fragment; a missing `agent_id` returns
  4xx + `toast error`.
- A new test: `GET /admin/fragments/inbox` without a valid admin cookie
  returns 401 + an error fragment (not JSON).

## 5. Drawbacks

1. **One new runtime dependency** — htmx 4 (~50 KB). Mitigated by
   vendoring (§3.6). The alternative (more vanilla JS) is what we have
   today and is the thing being simplified.
2. **Server-side HTML generation in Zig** is verbose (`buf.print` with
   `{s}` and manual `htmlEscape`). It is, however, **strictly less**
   code than the current server-side JSON generation + client-side HTML
   generation combined, and it removes the duplication. A tiny
   `std.fmt`-based HTML helper module (`src/web/html.zig`,
   `element()`, `table()`, `td()`) could further reduce verbosity; this
   RFC does not require it but leaves room for it.
3. **htmx 4 is new** (released 2026-08). Pinning an exact version
   (`@4.0.0`) avoids churn. The `htmx:2:compat` extension exists if any
   2.x-ism ever leaks in, but a greenfield integration should not need
   it.
4. **Fragment endpoints are not a stable public API.** `/admin/fragments/*`
   return HTML, not JSON, so they are not machine-consumable. This is
   intentional — the JSON surface for automation is `/v1/*` and
   `/admin/api`. The `/admin/fragments/*` paths are an internal
   implementation detail of the admin UI and may change between
   releases.
5. **No streaming / no live push.** The admin UI becomes
   request/response only. If we later want live inbox updates, htmx 4's
   `hx-sse`/`hx-ws` extensions (or `hx-trigger="every Ns"` polling,
   §3.5) are available. The current UI has no live updates either, so
   this is not a regression.

## 6. Alternatives considered

1. **Do nothing; keep the vanilla JS SPA.** Rejected — see §2.2
   (duplicated rendering, duplicated escaping, latent JSON-injection in
   the server builders, no progressive enhancement, JS-only mobile nav,
   token in JS-readable cookie).
2. **htmx 2.x.** Rejected for a new integration — 2.x is maintenance and
   would force a migration to 4 within ~18 months. There is no existing
   htmx 2 code to preserve, so 4's breaking changes cost nothing here.
3. **A JS SPA framework (React/Vue/Svelte).** Rejected — 6 tables + 1
   form does not justify a build toolchain, a bundler, or a 100+ KB JS
   runtime. The goal is to *remove* client rendering, not swap it.
4. **Server-side templates (a Zig template engine).** Considered but
   out of scope. The Zig ecosystem has no stdlib templating; pulling in
   a third-party template engine is a bigger change than this RFC and
   not necessary — `std.fmt` + `htmlEscape` is adequate for 6 tables.
   A small `src/web/html.zig` helper (§4.5) can evolve later without a
   template engine.
5. **Migrate only the dispatch form, leave tables as JSON.** Rejected —
   half the duplication. The tables are where the copy-paste is worst
   (Inbox/Outbox/Archive are near-identical), so they are the prime
   target.
6. **Keep JSON endpoints and add a thin htmx layer that calls them.**
   Rejected — this keeps *both* the JSON builders and the HTML builders,
   doubling the server code instead of halving it. The point is to
   delete the JSON-for-admin-views layer entirely.

## 7. Migration plan

The work is mechanical and can land in a single PR on this branch, or be
sequenced into review-sized commits:

1. **Vendor htmx 4** — add `src/web/htmx.min.js` + serve route, or CDN
   `<script src>`. No behaviour change yet.
2. **Add `htmlEscape` / `htmlError` / `formField` helpers** to
   `server.zig`. No behaviour change yet.
3. **Add fragment handlers** (`handleAdminXFragment`) alongside the
   existing JSON handlers, behind the `/admin/fragments/*` routes. Both
   old and new paths coexist; tests added for fragments.
4. **Rewrite `admin.html`** to the htmx shell. Switch the nav and
   dispatch form to `hx-*`. Mark the admin cookie `HttpOnly`.
5. **Delete the old JSON admin handlers** (`handleAdminAgentsApi`, …,
   `handleAdminWorkstreamsApi`) and their routes, once the shell no
   longer references them. Keep `handleAdminApi` (version JSON) and
   `handleAdminDispatch`/`handleAdminRegisterAgent` (now form-encoded →
   HTML).
6. **Delete the `<script>` block** from `admin.html`.
7. **Update integration tests** to assert on HTML fragments.
8. **Manual QA**: nav, all five tables, dispatch (success + error +
   unknown agent + new-workstream-name + existing-workstream-id),
   register-agent, mobile nav with JS disabled, 401 flow (expire
   cookie, click nav → error fragment).

Steps 1–3 are additive and safe to merge independently; 4–7 are the
"flip" that must land together.

## 8. Open questions

1. **Vendor vs. CDN for htmx?** Proposed default: vendor (matches SQLite
   under `vendor/` and keeps single-binary reproducible builds). Confirm
   with maintainers.
2. **Should `/admin/api` (version JSON) stay, or should `update --check`
   move to a dedicated `/version` or `/health` route?** This RFC keeps
   `/admin/api` as-is to avoid touching `update.zig`, but a future
   cleanup could split it.
3. **Auto-refresh / polling?** Not in scope, but if wanted, which tables
   and at what interval? (Inbox is the obvious candidate, 5–10s.)
4. **`src/web/html.zig` helper module?** Worth introducing in this RFC,
   or keep raw `buf.print` for v1 and extract helpers later?
5. **CSRF token?** `SameSite=Strict` covers the admin UI today. Do we
   need an explicit CSRF token for any deployment shape (e.g. behind a
   reverse proxy that strips `Referer`)? If yes, wire it via
   `htmx:config:request` in a follow-up.

## 9. References

- htmx 4 "What's New" (breaking changes, renames, removals):
  https://four.htmx.org/docs/whats-new-in-htmx-4
- htmx 4.0.0 release announcement (2026-08-28):
  https://four.htmx.org/announcements/2026:8:28-htmx-4.0.0-is-released
- htmx releases: https://github.com/bigskysoftware/htmx/releases
- htmx 2→4 compatibility extension (`htmx:2:compat`):
  https://four.htmx.org/docs/whats-new-in-htmx-4 (search "htmx:2:compat")
- Current admin UI: `src/web/admin.html` (479 LoC, ~270 JS)
- Current admin handlers: `src/server.zig` lines 155–194 (routes) and
  460–678 (handlers, ~330 LoC incl. JSON helpers)