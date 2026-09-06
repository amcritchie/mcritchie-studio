# Task-Board API

The McRitchie Studio task board is the durable coordination surface for the
feature → task → PR → QA → deploy loop (see
[`devops-task-board.md`](devops-task-board.md) for the workflow and stage
policy). This file documents the **HTTP API** an agent uses to create and move
tasks. The workflow doc describes *what* to record; this doc describes *how to
talk to the board*.

It is written against the live code (`config/routes.rb`,
`app/controllers/api/v1/*`, `app/models/task.rb`). When the code changes, update
this file in the same pass.

> ⚠️ **Mostly current, with legacy examples below.** The live task model is the
> two-workflow **7-stage** one (`designed → building → submitted → reviewed →
> assembled → shipped`, plus `archived`). **`blocked` is no longer a stage** — it's
> an ATTRIBUTE of a `building` task (`blocked_at`/`blocked_from`/`blocked_by`/
> `block_kind`); see **Stages** below. The endpoints table and task-transition
> sections are current; any older examples that mention named legacy transition
> routes should be treated as historical and replaced with either `PATCH stage` or
> the event APIs documented here.

> **Preferred path: use `bin/task`.** Don't hand-roll the HTTP calls below
> unless you're debugging. `bin/task create|update|move|list|show` handles auth,
> JSON, devops read-merge-write, and stage routing for you, and reads the secret
> from `ENV` or the repo `.env`. The raw API in this doc is the reference `bin/task` is built
> on. See the "Use bin/task" section at the end.

## Authentication

Every endpoint except `POST /api/v1/auth` requires a bearer token.

1. The board reads a shared secret from
   `Rails.application.credentials.agent_api_secret || ENV["AGENT_API_SECRET"]`.
   **If neither is set, auth fails closed and no agent can authenticate.**
   - Production/local value: 1Password item **`Agent API Secret`**
     (the agent vault's `Agent API Secret/AGENT_API_SECRET`); also present in
     `mcritchie-studio/.env` and the Heroku config. See
     [`credential-inventory.md`](credential-inventory.md).
2. Exchange the secret for a token:

   ```
   POST /api/v1/auth
   Content-Type: application/json
   { "secret": "<AGENT_API_SECRET>" }
   ```

   Returns `{ "token": "...", "expires_at": "<iso8601>" }`. The token is a Rails
   `MessageVerifier` token (purpose `api_auth`), valid **24h**.
3. Send it on every other call:

   ```
   Authorization: Bearer <token>
   ```

   Missing/invalid/expired tokens return `401` with
   `{ "error": "...", "error_code": "UNAUTHORIZED" }`.

### Secret hygiene

**Read the secret from the repo `.env`, not the vault.** On any provisioned
machine the two hold the same string, and `.env` is free while every `op read`
spends one credential against a **1,000/day cap shared account-wide** — a cap
routine board traffic has exhausted twice, taking every agent lane down for a
day each time. `bin/task` and the rest of the CLIs resolve it that way already
(`ENV` → `.env` → 1Password; see `bin/lib/task_board.rb#agent_secret`), so you
usually never touch the secret directly.

If you must call the API by hand, never inline the secret or echo it — read it at
call time and pipe it straight into the request:

```bash
# ENV first, then the repo .env. Quotes stripped; a set-but-empty value is no value.
SECRET="${AGENT_API_SECRET:-$(grep -m1 '^AGENT_API_SECRET=' .env | cut -d= -f2- | tr -d "\"'")}"
[ -n "$SECRET" ] || { echo "no AGENT_API_SECRET in ENV or .env" >&2; exit 1; }
TOKEN="$(curl -sS -X POST https://mcritchie.studio/api/v1/auth \
  -H 'Content-Type: application/json' \
  -d "{\"secret\": \"$SECRET\"}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')"
# use $TOKEN; never print $SECRET or $TOKEN
```

**Only** on a fresh machine mid-bootstrap, which has no `.env` yet, fall back to
the vault — `bin/secret agents 'Agent API Secret' AGENT_API_SECRET` (value to
stdout, diagnostics to stderr) rather than a hand-rolled `op read`. That call is
metered; the `.env` read above is not.

**Sub-agent constraint:** in sub-agent/headless sandboxes the
`op read → curl` secret chain (and `redis-cli`) is classifier-blocked. A
sub-agent therefore cannot drive this API directly — the **orchestrator brokers
task-board writes** on the sub-agent's behalf.

## Endpoints

Base path `/api/v1`. From `config/routes.rb`:

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/auth` | Exchange secret → bearer token |
| `POST` | `/release_notes` | Send canonical Discord release notes for deployed task slugs |
| `GET` | `/tasks` | List tasks (newest first, paginated) |
| `GET` | `/tasks/:slug` | Show one task |
| `POST` | `/tasks` | Create a task |
| `PATCH`/`PUT` | `/tasks/:slug` | Update a task |
| `DELETE` | `/tasks/:slug` | Delete a task |
| `POST` | `/tasks/:slug/intent` | Record live agent intent for a target stage |
| `POST` | `/tasks/:slug/review_events` | Record a primary/light reviewer check-in |
| `POST` | `/tasks/:slug/events/:stage/start` | Record a task transition start checkpoint |
| `POST` | `/tasks/:slug/events/:stage/complete` | Complete a task transition stage/checkpoint |
| `POST` | `/tasks/:slug/events/:stage/fail` | Fail a named task transition step and block the task |
| `POST` | `/releases/:slug/events/:step/start` | Record a release checkpoint start (stamps the stage timeline; `:slug` accepts `current`) |
| `POST` | `/releases/:slug/events/:step/complete` | Complete a release checkpoint (stamps the stage timeline; `:slug` accepts `current`) |
| `POST` | `/releases/:slug/events/:step/fail` | Fail a release checkpoint (never stamps a stage) |
| `GET` | `/gates/:subject_type/:subject_slug` | List a task's/release's gate-run attempts (chronological) |
| `POST` | `/gates/:subject_type/:subject_slug/:key/open` | Open (or re-enter) a gate attempt |
| `POST` | `/gates/:subject_type/:subject_slug/:key/sops` | Append one executed-SOP entry to the in-flight attempt |
| `POST` | `/gates/:subject_type/:subject_slug/:key/close` | Close the in-flight attempt with its verdict |

`GET /tasks` accepts `?stage=<stage>` and `?agent_slug=<slug>` filters (plus
`?page` / `?per_page`) and returns `{ "data": [...], "meta": { page, per_page,
total, total_pages } }`. Each list item includes its `stage`, so callers can
filter/triage without a per-task `show`. **The filter param is `stage`, not
`status`** — an unsupported query param is rejected with `400
{ "error": "unsupported query param(s): …", "error_code": "UNSUPPORTED_PARAM" }`
rather than silently ignored (which used to return every task). **The default is
`per_page=20`** (capped at 100), ordered newest-CREATED first (`Task.recent` =
`created_at DESC`) **across all stages** — so an unpaginated, unfiltered read
returns only the 20 most recent tasks. `meta.total` is the real count; a client
that ignores `meta` sees no truncation signal. To enumerate a stage in full,
filter with `?stage=` (an actionable stage holds far fewer than 20 rows). A `GET
/tasks/:slug` for an unknown slug returns `404 { "error": "task not found" }`.

Task JSON (show and index) carries a cached `gates` projection — the LATEST
attempt per task-grain gate, keyed under `gates.gates`:
`{ "cache_version": 1, "cached_at": "…", "gates": { "g1_cert": { "attempt",
"started_at", "finished_at", "success", "sops" }, "g2a_primary": …,
"g2b_light": … } }`. `success` is `null` while the attempt is in flight; a
never-attempted gate carries the all-nil row. `gate_runs` stays the source of
truth (`GET /gates/...` above for the full attempt history); show self-heals a
stale cache, index serves the raw column. Release-grain gates (G3/G4) are not
projected — read them via `GET /gates/release/<slug>`.
(There are also `agents`, `activities`, and `usages` resources; out of scope
here.)

### Release Notes

`POST /api/v1/release_notes` is the canonical way to post production Release
Notes to Discord. Do not hand-compose the Discord message when this API is
available.

The endpoint:

- resolves the provided task slugs from the production task board
- groups linked task titles by application in the standard ecosystem order
- links every task to `https://mcritchie.studio/tasks/<task-slug>`
- includes empty application sections as `No deployed tasks`
- posts to `DISCORD_RELEASE_NOTES_WEBHOOK_URL` with
  `DISCORD_DEPLOY_WEBHOOK_URL` as a compatibility fallback

Request body:

```json
{
  "app": "mcritchie-studio",
  "environment": "production",
  "release": "v71",
  "sha": "ef693ab1",
  "url": "https://mcritchie.studio/",
  "release_slug": "rel-2026-06-18-devops-tooling",
  "task_slugs": ["task-abc123def456"],
  "checks": ["production /up 200", "/signin 200", "/tasks 200", "web + worker dynos running"]
}
```

Use `dry_run: true` first to render and review the message without sending it:

```bash
api POST /api/v1/release_notes '{
  "app": "mcritchie-studio",
  "environment": "production",
  "release": "v71",
  "sha": "ef693ab1",
  "url": "https://mcritchie.studio/",
  "release_slug": "rel-2026-06-18-devops-tooling",
  "task_slugs": ["task-abc123def456"],
  "checks": ["production /up 200", "/signin 200", "/tasks 200", "web + worker dynos running"],
  "dry_run": true
}'
```

Successful responses return `{ "data": { "delivered": true|false,
"dry_run": true|false, "message": "...", "task_slugs": [...] } }`.
Unknown task slugs return `422 UNKNOWN_TASKS`; missing webhook config on a live
send returns `422 MISSING_WEBHOOK`.

### Transition APIs

Agents should prefer the transition endpoints for new automation. The legacy task
stage `PATCH` still exists, but transition endpoints give the board a deterministic
paper trail and enforce usage metadata on completed/failed agent work. The
underlying route still uses `/events/` for backwards compatibility.

Task transition endpoints:

```bash
POST /api/v1/tasks/:slug/events/:stage/start
POST /api/v1/tasks/:slug/events/:stage/complete
POST /api/v1/tasks/:slug/events/:stage/fail
```

Known `:stage` values include the normal task stages
`designed|building|submitted|reviewed|assembled|shipped|archived`, plus named
checkpoints such as `heavy_review`, `light_review`, `design`, and
`design_complete`. `start` records an intent when the named stage is the task's
next workflow stage; otherwise it records a checkpoint. `complete` moves the
task when the stage is a real workflow stage; named review/design checkpoints
record an append-only `TaskEvent(kind: checkpoint)` without moving the task.
`fail` records the named failed checkpoint, then BLOCKS the task with `kind`
defaulting to `rework`. A block is a `building` ATTRIBUTE now (not a stage):
`Task#block!` lands the task on `building` and stamps `blocked_at` / `blocked_from`
/ `blocked_by` / `block_kind`. Agents can also block directly via `PATCH
/api/v1/tasks/:slug/block` with `{ "kind": "...", "by": "<agent>" }` (the CLI
shortcut is `bin/task block`), posting a `qa_feedback` Activity alongside for the
prose feedback.

Release checkpoint endpoints:

```bash
POST /api/v1/releases/:slug/events/:step/start
POST /api/v1/releases/:slug/events/:step/complete
POST /api/v1/releases/:slug/events/:step/fail
```

Canonical release steps are:

```text
review_tests assemble_release deploy_qa qa_smoke ship_gate ship_authorized
deploy_prod prod_smoke release_notes archive_tasks
```

The tracker aliases also work: `testing`, `assembling`, `qa_deploying`,
`confirming`, and `production_deploying`.

#### Release Transition Timeline (the /deployments tracker)

The release carries an ordered set of **stage timestamps** — each acts as a time
AND a boolean (stamped = the stage started/landed, blank = not yet) — and the
/deployments progress tracker derives every node's green/yellow/dark state purely
from them. **Posting a release event IS the stage notification**: the server maps
the `(step, status)` pair to its stage stamp, first-write-wins (replays never
rewrite history), and broadcasts the live tracker to every viewer.

| You post | Stage stamped | Tracker effect |
|---|---|---|
| `testing/start` (alias of `review_tests/start`) | `testing` | stamps `testing` on an **already-active** release only — it no longer OPENS one, and node 1 greens from `assembling` regardless, so this no longer lights node 1 yellow (rarely posted now) |
| `testing/complete` (alias of `review_tests/complete`) | `tested` | (no tracker node) — ends the /deployments **Tested** column |
| `assembling/start` | `assembling` | node 1 green, node 2 Assembling yellow |
| `assembling/complete` | `assembled` | node 2 green (node 3 stays dark) |
| `qa_deploying/start` | `qa_deploying` | node 3 Deploying QA yellow |
| `qa_deploying/complete` | `qa_deployed` | node 3 green "Live on QA" (**node 4 stays dark**) |
| `confirming/start` | `confirming` | node 4 Confirming yellow — **the Avi handoff** |
| `confirming/complete` | `confirmed` | node 4 green (node 5 stays dark) |
| `production_deploying/start` | `prod_deploying` | node 5 Deploying yellow |
| — | `shipped` | node 5 green; only `bin/release ship` sets it, never an API post |

The gaps are deliberate: a completed stage does NOT light the next node. The
Steffon→Avi seam is the load-bearing case — Steffon's `qa_deploying/complete`
("Live on QA") leaves Confirming dark until Avi posts `confirming/start`.

Tracker stamps and **gate runs** (next section) are two surfaces, never merged:
stamps record stages, gates record test verdicts. The node↔gate mapping:
**node 1 (Testing) ≈ the pre-assembly state** — it greens automatically the
instant qa-release's first sweep stamps `assembling` (the review wave no longer
posts `testing/start`; the candidate doesn't exist during review), and **node 4
(Confirming) ≈ the G4 Ship opening beat** (the
`ship_gate`/`ship_authorized` stamps land as `bin/release ship` opens
`g4_ship`). G3/G4 verdicts render as their own gate-backed `/deployments`
columns, not as tracker nodes.

`:slug` accepts the literal `current` to target the singleton active release
without a lookup. When nothing is active, `current` 404s — except `assembling/start`
(assembly-start, the qa-release sweep's kick-off), which may OPEN the next
candidate. A review-wave `testing/start` (or any later stage) with no active
release 404s too: the candidate is born at assembly, never during review, so a
pre-assembly post never spawns a ghost release.

Every response carries the moved timeline so the poster can verify:

```json
{ "data": { "step": "ship_gate", "status": "started",
  "release": { "slug": "rel-20260704-a6ad35", "state": "assembled",
               "stage": "confirming", "stage_stamps": { "qa_deployed": "…", "confirming": "…", "confirmed": null } } } }
```

`bin/release` (prepare/ship) records these same checkpoints server-side, so
CLI-driven stages stamp themselves — the API posts matter at the seams the CLI
cannot see: Avi beginning his QA confirmation (`confirming/start`), or manual
recovery after an interrupted run.

For `complete` and `fail` calls from agent/API/CLI sources, usage is mandatory:

```json
{
  "event": {
    "actor": "avi",
    "source": "api",
    "model": "gpt-5",
    "tokens_in": 12000,
    "tokens_out": 1800,
    "cost": "0.4200",
    "idempotency_key": "rel-20260628-demo:ship_gate:complete"
  }
}
```

`start` does not require usage because work has just begun. Deterministic
server-side writers such as `bin/release` use `source: "conductor"` and may
record spine-only events. Steps that take measurable work should write `start`
and then `complete` or `fail`; completed-only legacy checkpoints render as
instant activities in release analytics so their timestamp remains visible. Repeated
calls should pass `idempotency_key` so retries return the existing release event
instead of stacking duplicates.

Start/intents create the analytics timestamp; completions create the accounting
row. Do not put model/tokens/cost on `start` or intent calls. Agent/API/CLI
`complete` and `fail` calls must report `model`, `tokens_in`, `tokens_out`, and
`cost`; deterministic `source: conductor|system` completions may stay
spine-only.

### Gate Runs API (the branded testing gates)

Gate runs record the **branded testing gates** — attempt-aware pass/fail
records with the test SOPs each attempt executed (`GateRun`; the standalone
gate docs live in `docs/agents/modules/gates/`). Keys and grains:

| Key | Gate | Grain (`:subject_type`) |
|---|---|---|
| `g1_cert` | G1 Cert (builder certification) | `task` |
| `g2a_primary` | G2a Primary (deep review lane) | `task` |
| `g2b_light` | G2b Light (second-read lane) | `task` |
| `g3_candidate` | G3 Candidate (pre-QA + QA deploy) | `release` |
| `g4_ship` | G4 Ship (frozen-SHA + prod deploy) | `release` |

```bash
GET  /api/v1/gates/:subject_type/:subject_slug
POST /api/v1/gates/:subject_type/:subject_slug/:key/open
POST /api/v1/gates/:subject_type/:subject_slug/:key/sops
POST /api/v1/gates/:subject_type/:subject_slug/:key/close
```

Same bearer auth as every endpoint. Semantics live server-side in the model's
one write funnel: `open` finds the in-flight attempt or starts attempt n+1
(a partial unique index converges racing openers onto one row); `sops` appends
one executed-SOP entry, implicitly opening (appending IS evidence the gate is
running); `close` records the verdict — closing with NO open attempt records a
self-contained attempt (a lone verdict is still a real attempt).

Payloads ride under a `gate` key (top-level also accepted); `close` takes a
top-level `success`:

```bash
api POST /api/v1/gates/task/<task-slug>/g1_cert/open \
  '{"gate": {"actor": "carl"}}'
api POST /api/v1/gates/task/<task-slug>/g1_cert/sops \
  '{"gate": {"sop": {"sop": "spine", "cmd": "bin/rails test test/models", "result": "pass", "duration_ms": 9800}}}'
api POST /api/v1/gates/task/<task-slug>/g1_cert/close \
  '{"success": true, "gate": {"sops": [{"sop": "dor-check", "result": "pass"}], "metadata": {"route": "fast"}}}'
```

A SOP entry keeps `{sop, cmd, tier, result, duration_ms, at}` (`at` is stamped
server-side when absent). `source` defaults to `"system"`. Errors: an unknown
key → `INVALID_GATE_KEY`; a task-grain key on a release (or vice versa) →
`GATE_GRAIN_MISMATCH`; an unknown subject → `404 NOT_FOUND`; `close` without
`success` → `MISSING_SUCCESS`.

**Deliberately NO usage gate** — gate markers are deterministic pipeline
boundaries, not usage-bearing work events (the same rationale as `bin/task
checkpoint`'s `source=system` default). Do not re-add a
`MISSING_EVENT_USAGE`-style requirement; producers (`bin/fast-check`,
`bin/full-suite-check`, `bin/dor-check`, `bin/pr-review`, `bin/release`) post
fire-and-forget — a gate write must never break the work it observes.

Prefer the CLI over raw curl: `bin/gate open|sop|close|show` wraps this
surface with the same flags the producers use (`bin/gate show task <slug>` /
`bin/gate show release <slug>` to read).

### Desk Ledger API (the worktree desk records)

```bash
POST /api/v1/desk_records         # file ONE desk record (a nomination or a teardown)
POST /api/v1/desk_records/sync    # fold a whole `snapshot --write` registry in
GET  /api/v1/desk_records         # read (filters: app, status, worktree_path, open=1)
```

**Why this exists.** `bin/agent-worktree` used to append its teardown row to
`docs/agents/maintenance/delete-later.md`, resolved against the hub checkout. A cleanup
is normally run from the **primary**, which sits on `main` — a branch nobody may commit
to — so the audit row was created in the one place it could never be saved from. Twelve
"restore later" stashes carrying 166 rows accumulated, plus the primary's own uncommitted
tree, and none was ever restored. The records live here now and render on the **Desks
panel at `/deployments`**; `bin/harvest-desk-ledger` recovered the stranded ones.

**Post the registry record verbatim.** The caller sends the hash
`bin/agent-worktree snapshot` already builds; the server owns the mapping onto columns
(`DeskRecord.registry_attributes`), so the single-desk post and the bulk sync can never
give two accounts of the same desk. The full record is also kept in `payload`, so nothing
the snapshot knew is dropped.

```bash
api POST /api/v1/desk_records '{
  "desk": {
    "registry": { "worktree": "/…/.worktrees/_ship", "branch": "release", "…": "…" },
    "status": "removed",
    "source": "remove",
    "safety": "merged",
    "reason": "Hidden worktree; branch `release` is clean and HEAD be798149 is contained in origin/accepted."
  }
}'
```

**`status` is `live` | `candidate` | `removed`**, and the episode rule is the markdown
ledger's, unchanged: a `removed` record is DATED and immutable; anything else is the
**open** episode for that desk path, updated in place. A second teardown of a **recycled**
path (`_ship` goes every release cycle) opens a NEW episode beside the resolved one. An
attempt to rewrite a resolved episode answers **409 `RESOLVED_RECORD_IMMUTABLE`** — a
distinguishable code on purpose, because a poster reading a 422 would retry a write that
must never succeed.

**This endpoint is on the DESTROY path, so it is NOT fire-and-forget.**
`bin/agent-worktree` posts here *before* it stops a stack or drops a worktree and aborts
the teardown on anything but a 2xx. There is deliberately no local queue: a spool that
flushes "on next contact" is the same *somebody must remember* the move removes.

### Review Check-In API

Reviewer agents broadcast progress with:

```bash
POST /api/v1/tasks/:slug/review_events
```

It records a `TaskEvent(kind: checkpoint)` and does not move the task stage. The
task detail page links reviewed/live-review timeline cards to
`/tasks/:slug/review_events`, which groups these check-ins by the heavy and
light reviewer swimlanes. On a specific task, the reader derives each moment's
duration from the review intent and subsequent checkpoint timestamps; callers do
not send a duration. The deployments board's Submitted column also links to the
global review-process hub at `/review_events`, which shows the canonical moment
order, top recent role owners, and recent submitted/reviewed/assembled/shipped
task drilldowns.

Payload:

```json
{
  "review_event": {
    "role": "primary",
    "moment": "diff",
    "status": "info",
    "actor": "carl",
    "source": "agent",
    "message": "Routes, controller, and persistence diff scanned.",
    "idempotency_key": "task-slug:primary:diff",
    "metadata": { "pr": "https://github.com/McRitchie-Studio/mcritchie-studio/pull/123" }
  }
}
```

Roles are `primary` and `light`. The UI labels `primary` as the **heavy**
swimlane. The legacy aliases `heavy`, `heavy_review`, and `light_review` are
accepted for API compatibility; they normalize to `primary`/`light`.

Canonical primary moments:

```text
started context diff tests risk findings completed failed
```

Canonical light moments:

```text
started context diff smoke handoff completed failed
```

`status` is `started`, `info`, `completed`, or `failed`; when omitted it is
derived from the moment (`started`, `completed`, and `failed` self-map,
everything else is `info`). `completed` and `failed` events from `api`, `agent`,
or `cli` sources must include `model`, `tokens_in`, `tokens_out`, and `cost`.
Mid-review `started`/`info` check-ins may be spine-only. Pass
`idempotency_key` on every automated broadcast so retries return the existing
checkpoint instead of stacking duplicates.

The older task transition aliases still work:

```bash
POST /api/v1/tasks/:slug/events/heavy_review/complete
POST /api/v1/tasks/:slug/events/light_review/complete
```

Use the dedicated `review_events` endpoint for new reviewer automation because
it captures the specific check-in moment and message.

## Writable fields

`POST`/`PATCH` permit exactly (`tasks_controller.rb#task_params`):

- `title` (required), `description`
- `priority` — `0`, `1`, or `2`
- `agent_slug` — owning agent (optional)
- `stage` — see stages below
- `required_skills` — array of strings
- `metadata` — free-form hash
- `devops` — **top-level** object, normalized and stored at `metadata.devops`

`slug` is **not** writable — it is auto-generated as `task-<hex>` on create. The
human-readable handle lives in `devops.worktree_slug`; see
[`devops-task-board.md`](devops-task-board.md). Bind the generated production
task URL to the local stack with
`bin/agent-worktree bind-task <app> <worktree-slug> <task-slug-or-url>` so
terminal context and PR bodies can lead from the task record.

## Stages

Seven stages (`Task::STAGES`):
`designed` → `building` → `submitted` → `reviewed` → `assembled` → `shipped`,
plus `archived`. `blocked` is **no longer a stage** — it's an ATTRIBUTE of a
`building` task (`blocked_at`/`blocked_from`/`blocked_by`/`block_kind`).

There are no named transition endpoints. Move stages with a raw update:

```
PATCH /api/v1/tasks/:slug   { "stage": "submitted" }
```

Stage is also directly settable on create/update; transitions are **not**
guarded by a state machine, so any stage can be set to any value (only validated
against `Task::STAGES`). Follow the documented stage policy by convention.

## Timeline inspection views

Two read-only Postgres views project the task/release timestamps in logical
progress order (not the alphabetized physical column order) for `psql` / DB-browser
inspection: **`task_timeline`** (per task) and **`release_timeline`** (per
release). They're created by a plain `execute "CREATE VIEW …"` migration and —
because a raw `CREATE VIEW` does NOT dump to the `:ruby` `schema.rb` — are absent
from a fresh `db:schema:load` (test/CI); treat them as operator-inspection-only.

## Stage-change event trail

Every stage change appends an **append-only `TaskEvent`** — the durable change
log behind the **Stage Timeline** on the task page (`/tasks/<slug>`). You get the
core of it for **zero effort**:

- **Automatic (deterministic spine).** On *every* move — CLI, API, web, or
  release-conductor — the board records `from_stage`, `to_stage`, `occurred_at`,
  and `seconds_in_from` (time spent in the stage you left). Moving the task is the
  only action required; the duration is measured server-side, never passed.
- **Optional (agent-reported usage).** To attribute model cost to the work you
  did in the stage you're leaving, pass it on the move. It is **best-effort and
  per-transition** — null when omitted, and for non-agent moves. `bin/task`
  auto-captures this usage for Claude (`CLAUDE_CODE_SESSION_ID`) and Codex
  (`CODEX_THREAD_ID`) sessions from the local transcript when explicit usage
  flags are absent; missing transcripts or unpriced models degrade to the
  deterministic spine only.

```bash
bin/task move <slug> submitted \
  --model claude-opus-4-8 --tokens-in 240000 --tokens-out 96000 --cost 5.40 \
  --actor alex        # --actor optional; the working session is auto-stamped otherwise
```

Raw API: send a top-level `event` object alongside `stage` on the `PATCH` (it is
consumed for the event row only — not stored on the task):

```
PATCH /api/v1/tasks/:slug
{ "stage": "submitted",
  "event": { "model": "claude-opus-4-8", "tokens_in": 240000,
             "tokens_out": 96000, "cost": 5.40, "actor": "alex" } }
```

**Backfill** existing tasks once, from their stage-timestamp columns:
`rake task_events:backfill` (idempotent; reconstructed rows are flagged
`source=system`).

Source of truth: `app/models/task_event.rb`, `Task#record_genesis_event` /
`#record_transition_event`, and `app/models/current.rb` (the request-scoped
bridge that carries usage into the event).

**Genesis and live building display.** `Created → Designed` is the deterministic
task-creation marker. It has no actor/model/tokens/cost because the task slug and
usage baseline do not exist until the create call lands. `bin/task create` then
seeds the usage baseline, so design work is accounted on the next conclusion:
`Designed → Building`. While the task is currently `building`, the task detail
timeline marks that same `Designed → Building` card live; it does not append a
second `Building` card.

**Release duration cache.** `Release::DurationCache` derives stage durations from
task intents to conclusions (`building`, `reviewing`, `assembled`, `shipped`)
and release durations from `ReleaseEvent`s. Cached metrics live on
`releases.duration_metrics` with `duration_metrics_cached_at` and
`duration_cache_version`. Task/release event writes refresh the owning release
best-effort, `bin/rails releases:refresh_duration_metrics` refreshes the last
three shipped releases (aborting non-zero if it refreshes fewer than it selected,
so the post-deploy hook cannot record green over a stale cache), and
`/deployments/all` plus `/deployments/:slug` render from the cache with an
in-memory fallback when a row is missing.

## The `devops` object

Send `devops` as a top-level key; it is normalized
(`Task.normalize_devops_metadata`) and merged into `metadata.devops`. Only these
keys survive (`Task::DEVOPS_KEYS`):

- **Scalars:** `kind`, `worktree_slug`, `branch`, `pr_url`, `local_url`, `qa_url`,
  `production_url`, `requires_release_conductor`, `approval_status`,
  `approval_requested_at`, `approval_requested_by`, `approval_approved_at`

`release_slug`, `release_train`, and `block_kind` are **not** in this list and are
not silently ignored either — `Task::DEVOPS_COLUMN_KEYS` refuses them with a 422
naming the column each one actually lives in (footgun 5).
- **Lists:** `repositories`, `risk_tags`, `acceptance`, `test_plan`,
  `checks_run`
- **Maps** (`{ "<repo>": "<value>" }`): `pr_urls`

`pr_urls` is the **per-repo PR register** — where a task naming more than one
repo records the second repo's PR. `pr_url` holds a single url and the release
lane parses *that url* for the repo it plans against, so on 2026-08-13 a task
naming `[mcritchie-studio, turf-monster]` with the hub's PR url promoted, QA'd
and shipped the hub alone, and was still stamped `shipped` + `merged: "main"`
while turf production ran the unpatched code.

**The sweep reads it; nothing refuses an incomplete record yet.** The release lane
plans against `Task#release_repos` — the primary repo, every repo with a PR
recorded here, and every declared `repositories` entry — so a multi-repo task now
promotes, QA's and ships *every* repo it names, and
`Release::Conductor#member_plan` carries each repo's PR url with it. What is still
missing is the refusal: `Task#repos_missing_pr_url` is the query that will answer
*which repo has no PR*, and it has no caller until
`/tasks/merge-promotes-every-repo` ships it. So a repo you neither declare nor
record is simply absent from the plan — while a repo you **declare** without
recording its PR is planned, promoted and QA-deployed like any other, which
leaves the release holding evidence for it, so `Release::MemberEvidence` does
**not** hold the member. That guard keys on what the RUN LANDED per repo, never
on PR coverage: it catches a repo missing from the *plan*, not a repo missing a
*PR*. **Keep hand-checking PR coverage** until the refusal lands.

`pr_url` stays the primary and is folded into the map automatically
(`Task#release_pr_urls`) — do not repeat it. **It wins for the repo it names**,
over any `pr_urls` entry for the same repo: `pr_url` is what `release_repo`,
`bin/dor-check` and `bin/pr-review` already act on, so one repo has one
authoritative PR and correcting it with `--pr-url` actually takes effect.

**Writing it.** The CLI writes one entry at a time, merging into whatever is
already recorded:

```bash
bin/task update <slug> --pr-url-for turf-monster=https://github.com/McRitchie-Studio/turf-monster/pull/305
bin/task update <slug> --pr-url-for turf-monster=none    # remove one entry
```

Over the JSON API, send `devops.pr_urls` as a `{ repo => url }` object — the
shape the CLI writes. A list of bare PR urls is also accepted and each url is
keyed by the repo it names, but nothing ships that form.

**Every value is validated, both shapes alike.** A url must parse as
`github.com/<owner>/<repo>/pull/<n>`, and in the object form the **key must be
the repo the url names** — filing turf's PR under `mcritchie-studio` is a 422,
not a stored lie. A url naming no repo is a 422 too, never a silent drop. A
**blank** value is the exception: it drops, and that is how the API unsets one
entry (the writers all send the whole map). This validation is why the register
is evidence — before it, `{"turf-monster": "lol"}` stored `"lol"` verbatim and
turf then read as fully covered.

**Reading it back.** `bin/task show <slug> --verbose` always prints a `pr_urls:`
block (`-` when empty), and `bin/task field <slug> pr_urls` prints one
`<repo>=<url>` per line — the same syntax `--pr-url-for` takes, so a read-back
round-trips into the write.

`merged` is **not** in this list and never will be — it is a top-level column.
See footgun 4 for the full set of fields that live outside `devops`.

## Footguns (verified, will bite you)

1. **`update` MERGES `metadata.devops` key by key.** If a `PATCH` includes a
   `devops` object, each name you send is authoritative and **every name you omit
   is left unchanged**. To DELETE a key, post it with a blank value — deletion is
   expressible, it just has to be said out loud. (A `PATCH` that omits `devops`
   entirely leaves `metadata` untouched — use that to move only the stage.)
   `bin/task update` also does a client-side read-merge-write, so partial updates
   are safe through the CLI whichever board version you are pointed at.

   **⚠ IT REPLACED THE HASH WHOLESALE UNTIL 2026-08-30**, and this footgun told
   you so — correctly, and at the cost of a task. A one-key PATCH
   (`{"devops": {"included_in_release": false}}`) took a **`reviewed`** task from
   20 devops keys to 8 at HTTP 200 with no warning; `acceptance`,
   `agent_context`, `checks_run` and `risk_tags` were unrecoverable, and the lost
   acceptance criteria were the contract that review had been conducted against.
   The board keeps no task-version history, so **prevention is the whole remedy**
   — there is nothing to restore from. If you are reading a cached copy of this
   page, or code whose comments still say "wholesale": the merge landed with
   task `api-devops-patch-replaces`, and the board form has always merged.

   **The merge is per KEY, not per list element.** A `devops` name you post
   replaces that name's whole value — so sending `acceptance` replaces the whole
   acceptance list, and sending one `pr_urls` entry replaces the whole map. Send
   every element you want kept (`bin/task`'s list flags work the same way, which
   is why `--checks` REPLACES your tier tags).
   **One exception, by design: cert evidence in `checks_run` is machine-owned.**
   The fingerprint-bound lines the cert tools stamp (`[full-suite@<fp>]`,
   `[rubocop@<fp>]`, `[fast-cert@<fp>]`, `[cert-deferred@<fp>]` — what
   `bin/dor-check` grades) survive a
   `checks_run` you send without them: the board carries forward every evidence
   lane your payload does not itself supply (`Task#preserve_cert_evidence`,
   `lib/cert_evidence.rb`). Your own tier tags are still replaced wholesale, so
   send every `[unit] …` / `[integration] …` line you want kept. Supplying a
   `[<lane>@<fingerprint>]` line by hand is not a legitimate write — it forges a
   certification; run `bin/fast-check` / `bin/full-suite-check` instead.
2. **List delimiting differs by input type.** `normalize_devops_list` treats
   **array** input (the JSON API / `bin/task`) as already-delimited and splits it
   **only on newlines** — so commas inside an `acceptance`/`test_plan` sentence
   are preserved. **String** input (UI free-text fields) still splits on both
   commas and newlines, so one field can carry several entries. Practical rule:
   from the API/`bin/task`, **always pass list values as arrays** (one element
   per item) and commas are safe.
3. **Unsupported `devops` keys are silently dropped.** Anything not in
   `DEVOPS_KEYS` is discarded by the normalizer. To stash extra data, write it
   under `metadata` directly instead of `devops`.
4. **Some load-bearing fields are TOP-LEVEL COLUMNS, not `devops` keys — and
   `metadata.devops.<name>` reads `null` for them on every task, stamped or
   not.** The set: `merged`, `stage`, `agent_slug`, `priority`, `required_skills`,
   and the size trio `po_size` / `dev_size` / `pm_size` / `actual_size`. Send them
   at the top level of the PATCH body, and **read them back from the top level**:

   ```bash
   bin/task show <slug> --json | jq '{stage, merged, release_slug}'   # top level
   bin/task show <slug> --verbose | grep merged                        # prints all three states
   ```

   This is the single most expensive misread on the board. `merged` is the stamp
   the release sweep uses to decide whether a `reviewed` task rides the
   candidate, so it gets verified constantly — and an agent checking
   `.metadata.devops.merged` gets `null` whether the write landed or not, which
   reads as a dropped write. Three agents lost time to exactly that inference in
   24 hours on 2026-08-11/12, one of them nearly filing a false persistence
   incident. `bin/task show --verbose` now always prints `merged` and
   `release_slug` and distinguishes an empty column (`not merged`) from a payload
   that carries no such key (`UNREPORTED`), and `bin/task field <slug> merged`
   reads the column — but a raw `jq` on `.metadata.devops` still lies.

5. **`release_slug` is a COLUMN ONLY — a `devops` write to it is refused (422).**
   It used to exist in both places, disjoint: the column carried real release
   membership (`Release#record_members` writes it beside the `merged` stamp;
   `bin/conductor` reads `task["release_slug"]`) while a same-named `devops` key
   carried whatever a human typed and fed only the task page's card. A slug typed
   into the board form persisted, displayed, and meant nothing to the sweep.
   Resolved (`/tasks/release-slug-two-universes`): membership is attached by the
   sweep and by nothing else. `Task::DEVOPS_COLUMN_KEYS` now rejects a `devops`
   write to `release_slug`, `release_train`, or `block_kind` with a 422 naming the
   real column, a `before_save` sheds any stored shadow, the `--release-slug` flag
   and the board form field are gone, and the task page renders the column. Read
   it from the top level (`bin/task field <slug> release_slug`, or `--verbose`).

6. **`slug` IS settable — but only on create.** Pass `slug` in the create body
   (or `bin/task create --slug <readable-handle>`) for a readable `/tasks/<slug>`;
   it also seeds `worktree_slug` and the `feat/<slug>` branch. Omit it and you get
   an opaque `task-<hex>`. The model marks it `attr_readonly`, so an update that
   sends `slug` is ignored — the URL id wins.
7. **`event.source` is clamped to the authenticated lane.** A bearer write that
   sends `event.source: "web"` is recorded as `"api"` — `"web"` is stamped only
   server-side by the admin-gated board UI, so the TaskEvent trail always names
   the channel the write actually came through. This is attribution only; it
   changes nothing about which fields you may write. **`approval_status` is fully
   agent-writable, `"approved"` included** (since 2026-08-09): when the operator
   approves a live preview in words, the agent that heard him records it with
   `bin/task update <task> --approval approved`, and the board stops pulsing
   WAITING. `approval_approved_at` is still server-stamped the first time approval
   enters `"approved"`, so you do not need to send it.

## Worked example

```bash
BASE=https://mcritchie.studio
# ENV, then the repo .env — never the vault on a provisioned machine (see Secret hygiene).
SECRET="${AGENT_API_SECRET:-$(grep -m1 '^AGENT_API_SECRET=' .env | cut -d= -f2- | tr -d "\"'")}"
auth() { curl -sS -X POST "$BASE/api/v1/auth" -H 'Content-Type: application/json' \
  -d "{\"secret\": \"$SECRET\"}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])'; }
TOKEN="$(auth)"
api() { curl -sS -X "$1" "$BASE$2" -H "Authorization: Bearer $TOKEN" \
  ${3:+-H 'Content-Type: application/json' -d "$3"}; }

# 1. Create (list values are arrays; commas inside an item are preserved)
api POST /api/v1/tasks '{
  "title": "Add sticky header to admin users table",
  "priority": 1,
  "agent_slug": "shannon",
  "devops": {
    "kind": "feature",
    "worktree_slug": "admin-users-sticky-header",
    "repositories": ["mcritchie-studio"],
    "risk_tags": ["ui"],
    "acceptance": ["Header stays pinned while the table scrolls"],
    "test_plan": ["bin/rails test"],
    "checks_run": ["bin/rails test test/controllers/tasks_controller_test.rb"]
  }
}'   # -> returns the created task with slug "task-<hex>"

# 2. Claim it (creates/enters the worktree first, then:)
api PATCH /api/v1/tasks/task-XXXX '{"stage": "building"}'

# 3. Submit for review — PATCH the stage and
#    RE-SEND the full devops (update overwrites it) plus branch + pr_url:
api PATCH /api/v1/tasks/task-XXXX '{
  "stage": "submitted",
  "devops": {
    "kind": "feature",
    "worktree_slug": "admin-users-sticky-header",
    "repositories": ["mcritchie-studio"],
    "risk_tags": ["ui"],
    "branch": "feat/admin-users-sticky-header",
    "pr_url": "https://github.com/McRitchie-Studio/mcritchie-studio/pull/123",
    "acceptance": ["Header stays pinned while the table scrolls"],
    "test_plan": ["bin/rails test"],
    "checks_run": ["bin/rails test test/controllers/tasks_controller_test.rb"]
  }
}'

# Preferred CLI path for the pre-PR operator validation gate:
bin/task update task-XXXX --local-url http://localhost:3001/admin/users --approval waiting
# `waiting` is legal only before the `submitted` seam: any save at `submitted` or
# later settles an open request to `none` (settled — never a fabricated `approved`).

# 4. Review/merge/QA progression uses the same update path:
api PATCH /api/v1/tasks/task-XXXX '{"stage": "reviewed"}'
api PATCH /api/v1/tasks/task-XXXX '{"stage": "assembled"}'   # devops preserved (no devops param)

# 5. Shipped (after approved deploy + post-deploy check):
api PATCH /api/v1/tasks/task-XXXX '{"stage": "shipped"}'

# 6. Production release notes (dry-run first, then repeat without dry_run):
api POST /api/v1/release_notes '{
  "app": "mcritchie-studio",
  "environment": "production",
  "release": "v71",
  "sha": "ef693ab1",
  "url": "https://mcritchie.studio/",
  "release_slug": "rel-2026-06-18-devops-tooling",
  "task_slugs": ["task-XXXX"],
  "checks": ["production /up 200", "/signin 200", "/tasks 200", "web + worker dynos running"],
  "dry_run": true
}'
```

## Verifying this doc

Cross-check against source when in doubt:

```bash
sed -n '/namespace :api/,/^  end/p' config/routes.rb       # endpoints
grep -n "params.permit" app/controllers/api/v1/tasks_controller.rb   # writable fields
grep -n "STAGES\|DEVOPS_KEYS\|normalize_devops" app/models/task.rb   # stages + devops contract
```

## Use `bin/task` (the preferred path)

`bin/task` wraps everything above so you don't construct JSON, manage tokens, or
remember which stages have transition endpoints. It reads the secret from `ENV`
or the repo `.env` (the vault only on a machine that has neither), does devops
**read-merge-write** (partial updates never wipe
fields), and sends list flags as arrays so comma-containing items stay intact.

```bash
bin/task list [--stage S] [--agent A]
bin/task show <slug>
bin/task create --title T [--kind K] [--repo R ...] [--risk R ...] \
                [--accept "..." ...] [--test "..." ...] [--agent A]
bin/task update <slug> --local-url U --approval waiting   # request operator validation
bin/task move <slug> submitted                            # settles an open approval to none
bin/task update <slug> --branch B --pr-url U              # merges into existing devops
bin/task move <slug> <stage>                   # bare Claude/Codex moves auto-capture usage
bin/task move <slug> submitted \               # optional per-transition usage →
  --model M --tokens-in N --tokens-out N --cost D --actor A   #   recorded on the TaskEvent
```

> ⚠️ **`bin/task list` caps at 20 rows, recency-ordered across all stages, with
> no truncation warning.** It surfaces only the API's default page (`per_page=20`,
> `created_at DESC`) and discards `meta`, so it prints `(20 task(s))` even when
> more exist — older tasks in quiet apps silently fall off. **`bin/task list
> --stage <stage>` is the reliable enumeration** (an actionable stage holds far
> fewer than 20); enumerate the Deploy queue by stage at the start of every cycle
> (see [`parallel-agent-devops.md` → Step 0](parallel-agent-devops.md#step-0--assess-the-queue-by-stage)).

List flags are **repeatable** (one value per flag), so commas inside an
`acceptance`/`test_plan` item are safe. Fall back to the raw API above only when
`bin/task` can't express what you need.
