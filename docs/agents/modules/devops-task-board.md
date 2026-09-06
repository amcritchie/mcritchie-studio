# DevOps Task Board

McRitchie Studio's task board is the durable coordination surface for feature,
bug, QA, release, and cleanup work. Chat can start work, but task metadata is
the handoff that survives across agents, PRs, QA deploys, production deploys,
and cleanup.

This file covers the **workflow** (stages, metadata, duties). For the **HTTP
API** an agent uses to authenticate and create/move tasks — auth secret, bearer
token, endpoints, writable fields, and the normalizer footguns — see
[`task-board-api.md`](task-board-api.md).

## Flat Tasks First

Do not create parent/child task trees by default. Deliver increments of work as
flat tasks. Tasks that must ship together do so by riding the same release
candidate — the sweep promotes everything on `accepted` in one batch, so
"promoted together" is the default, not something you tag for.

Use parent/child modeling only after flat tasks prove too weak in real
operations.

## Required Task-Tracking Rule

Every feature, bug, QA, release, cleanup, or active-doc change that may produce
a branch, PR, QA deployment, production deployment, or cleanup follow-up must
have a McRitchie Studio task-board item. Chat, `bin/agent-worktree`, GitHub PRs,
and `bin/qa-intake` are supporting channels; they do not replace the task.

Create or update the durable handoff task in production McRitchie Studio at
`https://mcritchie.studio` before implementation starts. Local, QA, and
worktree task boards are only for testing task-board behavior; they are not
durable handoff records. If an agent records task metadata outside production
while implementing, the agent must backfill or update the production task before
PR handoff.

If Mr. McRitchie starts work in chat and no task exists yet, the feature agent
creates a flat production task from the ask before allocating a worktree or
editing files. If a task already exists, the agent updates that task instead of
creating a duplicate.

After the task is created and the isolated worktree is bound, run
`bin/session-preflight <task-slug>` before editing. It is the start-of-session
counterpart to `bin/dor-check`: it reads latest task feedback, branch drift
against `origin/release`, PR merge/check state, same-file overlap with open or
recent PRs, **duplicate migration installs**, installed docs/skills drift, stale
terminology, and the required test tiers from `config/feature_shapes.yml`.
Everything there is a warning except the last two and the migration check: two
branches installing ONE engine migration under two host timestamps merge cleanly
(the files have different names — only `db/schema.rb` conflicts) and then raise
`ActiveRecord::DuplicateMigrationNameError` on every `db:migrate`, including the
Heroku release phase, so it **blocks**. The mechanism, both detection keys, and
the resolution live in `bin/lib/migration_collision.rb` — kept beside the code so
they cannot drift from it. Non-code kinds (`chore`,
`cleanup`, `docs`) skip the shape/required-metadata gate exactly as
`bin/dor-check` does — but the `kind` label alone never earns that skip. The
exemption is earned by the **observed diff**: a file is non-behavioral only if it
is provably prose (`*.md`) or inert media, judged by **file type, never by
directory** — so `docs/agents/setup.sh` gates like any other script, while
`docs/agents/sop.md` skips. Anything else — `.github/workflows/*`, `Gemfile`,
`config/*.yml`, `bin/*`, migrations, `test/**` — forfeits the exemption. See
[gates/dor.md](gates/dor.md).

Feature agents should first identify the feature and accumulate acceptance
criteria until the agent and Mr. McRitchie are aligned on the goal. The task is
the durable version of that alignment. Exceptions are narrow conductor sessions
such as Avi running the DevOps/QA cycle, pure read-only audits, and explicit
release/deploy lanes; those sessions still update tasks when they change
handoff state.

Use one task per independently reviewable increment. For a vertical feature
that touches multiple repos and ships together, either use one task with all
repos listed in `repositories`, or separate flat tasks whose ordering you record
in `dependencies` when one must ship before another.

Minimum task setup before implementation:

- `title` and `description` summarize the user-visible ask.
- `kind` is `feature`, `bug`, `chore`, `qa`, `release`, or `cleanup`.
- `worktree_slug` is the human-readable feature handle used for the branch,
  worktree path, terminal context, and local stack. The app-generated
  `Task.slug` remains the immutable production task id.
- `repositories` lists every repo expected to change.
- `acceptance` records concrete acceptance criteria. If the ask is ambiguous,
  confirm criteria with Mr. McRitchie before building.
- `risk_tags` captures likely risk such as `auth`, `email`, `solana`,
  `payment`, `migration`, `ui`, `provider`, `docs`, or `deploy`.
- `test_plan` records the checks the agent expects to run.
- `checks_run` records the checks actually completed before handoff.
- `requires_release_conductor` is `true` when production deploy, gem publish,
  provider config, env vars, data correction, credentials, or migration/backfill
  handling may be needed.

Stage movement:

1. Create captured work in `designed` once acceptance criteria are clear enough
   to track.
2. Move to `building` when an agent claims the task and creates or enters the
   worktree.
3. Before opening the PR, use the Operator Validation Gate when the work has a
   local UI or inspectable workflow Mr. McRitchie should approve.
4. Move to `submitted` only after the branch is pushed, the PR exists, the
   local URL is recorded when applicable, and `checks_run` records actual
   feature-agent verification.
5. Move to `reviewed` only after the review gate approves the PR.
6. Move to `assembled` when the PR is merged into `release` and deployed or
   ready to deploy on the QA candidate. Record QA URL, deployed SHA, and QA
   checks when available.
7. Move to `shipped` only after the final approved target is deployed or otherwise
   complete, post-deploy verification is recorded, and cleanup status is clear.
8. Use `blocked` for a real blocker that needs new action, and `archived` for
   historical or cleaned-up work.

Handoff connections:

- Set `devops.worktree_slug` to the human-readable worktree slug. The generated
  `Task.slug` is not human-readable and should not be manually changed.
- Bind the production task to the local stack with
  `bin/agent-worktree bind-task <app> <worktree-slug> <task-slug-or-url>`.
- The PR body and final handoff should lead with the task URL before the PR URL.
- The task must record `branch`, `pr_url`, `local_url` when applicable,
  `qa_url` after QA deployment, `production_url` after production deploy,
  `test_plan`, and `checks_run`.
- `bin/qa-intake` should be used by Avi to discover worktree/PR state, but Avi
  should join that queue back to tasks and leave feedback on the task or PR when
  metadata is missing.
- Final handoff should name the task, PR, release slug when present, URLs,
  `checks_run`, deployment SHA/release, and cleanup decision.

## Operator Validation Gate

Use this gate when a feature agent has built enough for Mr. McRitchie to inspect
locally, but before the PR is opened or moved to `submitted`.

1. Start or verify the task worktree stack, and record the reviewable URL:

   ```bash
   bin/agent-worktree up <app> <task-slug>
   bin/task update <task-slug> --local-url http://localhost:<port>/<path> --approval waiting
   ```

2. Add a `handoff` note describing what changed, what to inspect, and any known
   caveats. The task remains in `building` while waiting for operator approval.
3. In chat, put the local URL in a standard top-level line:

   ```text
   Task: https://mcritchie.studio/tasks/<task-slug>
   Local Demo: http://localhost:<port>/<path>
   Local Inbox: http://localhost:<port>/_studio/local_emails   # only for email/auth flows
   ```

4. The board treats `devops.approval_status=waiting` as an attention state: the
   card ranks above its stage peers, pulses, and flashes a card-width **WAITING
   APPROVAL** bar. Clicking that bar bounces to the LOCAL stack's dev-only mint
   endpoint (`/_studio/local_review`, studio-engine >= 0.19), which signs Mr.
   McRitchie in on THAT server and lands him on the page under review — the
   board itself cannot mint a session for another server, which is why it hands
   off instead of minting. It refuses any `local_url` that is not loopback.
5. If Mr. McRitchie approves, finish DoR, commit, push, open the PR, and hand off.
6. If changes are requested, set `--approval changes_requested` and keep the task
   in `building` until the next validation packet is ready.
7. A `waiting` request is only legal BEFORE the `submitted` seam (`designed` /
   `building`, and `blocked` — which parks the task on `building`). Past the
   seam the PR review flow owns the work, so **any** save at `submitted` or
   later settles an open request to `none` — settled, NOT `approved`: the
   operator never granted anything, and faking a grant would misreport the
   acceptance metric. This is an invariant re-asserted on every save, not a
   one-shot transition: until 2026-07-27 it fired only on the building →
   submitted save, so a later wholesale devops echo restored `waiting` and the
   badge rode all the way to `shipped`.

## Task Conversation and QA Feedback

The task board owns the durable conversation for an increment. `/tasks` cards
show the latest feedback inline so agents can scan the queue without opening a
separate tool. Open the task detail page when you need the full thread or need
to add a note. The response taxonomy lives in
[`review-comment-taxonomy.md`](review-comment-taxonomy.md); use it when deciding
whether a note is a non-blocking clarification or blocking review feedback.

Use these activity types:

- `comment` for general coordination notes.
- `clarification` for non-blocking questions or answers that should not send the
  task back for rework by themselves.
- `qa_feedback` for Avi or Steffon review findings, QA blockers, failed checks,
  missing metadata, or changes requested before merge/deploy.
- `handoff` for feature-agent responses, rebase notes, local proof URLs, or
  "ready again" messages after addressing feedback.

Review scouts record their findings as `comment` activities with
`metadata.kind=scout_report`. This keeps scout evidence visible without
accidentally turning a scout's recommendation into Avi's final review decision.
The normal path is:

1. Avi runs `bin/devops-cycle --scout-packets` and gives a packet to a
   review-only scout session.
2. The scout reviews the task and PR, then dry-runs a structured report:

   ```bash
   bin/devops-cycle --record-scout-report task-XXXX \
     --outcome merge-ready \
     --summary "No blockers found." \
     --finding "Diff matches the task acceptance criteria." \
     --check "Reviewed PR body, changed files, and CI." \
     --dry-run
   ```

3. The scout removes `--dry-run` only after the payload is correct.
4. Avi runs `bin/devops-cycle --scout-reports` to see recorded scout reports
   alongside the task queue.
5. Avi makes the final call. If changes are required, Avi leaves
   `qa_feedback` on the task and usually a PR comment with the code-specific
   blocker.

Valid scout outcomes are `merge-ready`, `wait-for-ci`, `request-changes`, and
`conductor-review`. Scouts do not merge, deploy, move task stages, publish
gems, change providers, rotate credentials, force-push, or take over branches.

When Avi sends work back, Avi should add `qa_feedback` on the task with the
specific action needed and also comment on the PR when the feedback is tied to
GitHub review, CI, or changed code. The task thread is the durable handoff for
the original agent; the PR comment is the code-review surface.

When the feature agent returns, the agent should read the task conversation,
address each open `qa_feedback` item, add a `handoff` note with what changed,
update branch/PR/local URL/check metadata if needed, and move the task back to
`submitted` when ready.

Agents can read or write the same thread through the Activities API:

```bash
GET /api/v1/activities?task_slug=<task-slug>
POST /api/v1/activities
```

Post payloads should include `task_slug`, `activity_type`, `description`,
optional `agent_slug`, and optional `metadata`. API calls require the app's API
bearer token. The HTML task page remains the operator-friendly source of truth.

⚠️ **PARSE THE BODY — AND NEVER COUNT THROUGH A LENIENT PARSE.** A hand-rolled
read of this endpoint is a documented trap with two layers.

The first: `TaskBoard.request` returns a `Net::HTTPResponse`, and
`Net::HTTPResponse#[]` is the HTTP **header** reader — so `response["data"]` is
`nil`, `Array(nil)` is `[]`, and a row count comes out **0 with no error
raised**. It cost the two-bounce circuit breaker its entire working life
(`/tasks/circuit-breaker-check-always-zero`).

The second survives the obvious fix: `TaskBoard.parse_body` is **lenient by
design** — `{}` on an empty or non-JSON body — so parsing correctly and *then*
reading `["data"]` still scores an unreadable answer as **zero rows**. A proxy's
HTML error page, a truncated response, and an expired 24h token all land there,
and for a safety count empty is the reassuring answer
(`/tasks/board-parse-silently-returns-empty`).

So pick the reader by what you are about to do with the answer:

| Doing what | Use | On an unreadable body |
|---|---|---|
| Rendering, logging, plucking an optional field, reading an error page | `TaskBoard.parse_body(res)` | `{}` — renders something |
| **Counting, testing `.empty?`, concluding "none, therefore proceed"** | **`TaskBoard.rows!(res)`** | raises `TaskBoard::UnreadableResponse` |

`rows!` takes either a response or an already-parsed payload, so a CLI whose
`api` wrapper parses leniently for its error line can still count strictly:
`TaskBoard.rows!(payload)`. An `[]` from `rows!` means genuinely none.

Prefer an existing command over a fresh hand-roll: **`bin/task bounces <slug>`**
counts prior send-backs and refuses to answer a read it could not make.

## Stage Flow

> **Canonical stages (two-workflow model).** The live board runs **Build**
> (`designed → building → submitted`) and **Deploy** (`submitted → reviewed →
> assembled → shipped`), plus `blocked` (side) and `archived` (terminal). Under
> the persistent-`release` branch model, **`reviewed`** = an approved PR whose
> base is `release`, and **`assembled`** = that PR merged into `release`
> (`bin/release merge` flips the task at merge); the conductor then deploys
> `origin/release` to QA (`bin/release prepare`) and ships by fast-forwarding
> `release → main` (`bin/release ship`). Full spec:
> [`devops-cycle-design.md`](../system/devops-cycle-design.md) §1.

The board stages should mirror the release path, not generic activity buckets:

| Stage | Use when |
|---|---|
| `designed` | Scope and acceptance criteria are clear enough to track |
| `building` | A feature agent is actively implementing or fixing the task |
| `submitted` | Branch is pushed and the PR is ready for review |
| `reviewed` | Review approved the PR for merge into `release` |
| `assembled` | PR is merged into `release` and included in the QA candidate |
| `shipped` | Production or final approved target is shipped and verified |
| `archived` | Historical or cleaned-up work that should not appear on the active board |

`blocked` is **not a stage** — it's an ATTRIBUTE of a `building` task (`blocked_at`
+ `blocked_from` + `blocked_by` + `block_kind`, set via `bin/task block` / `PATCH
/api/v1/tasks/:slug/block`). A blocked task rides the Building column with a red
glow until it's resumed or advances.

### "Was this task sent back?" — do NOT ask the block fields

A `--kind rework` block returns the task to **`building`**, deliberately: `blocked`
reads as *not in the pipeline's court* (an env blocker, a dependency, QA waiting on
someone else), and a rework is squarely in the **builder's**. The cost is that a
resubmission and a fresh build are the same shape, and three fields will confidently
tell you nothing is wrong:

| Field | What it actually answers | What it CANNOT answer |
|-------|--------------------------|------------------------|
| `blocked_at` / `block_kind` / `blocked_from` | Is there a LIVE block right now? | Was this task ever sent back? They are null after a rework block, **by design**, and `Task#clear_block_on_forward_move` NULLs them on any forward move. |
| `unresolved_feedback` | The TEXT of an open send-back | Whether the work answering it landed. It is cleared only by an explicit `bin/task note <slug> --handoff "…" --resolves-feedback`, never by the fix landing — so it reads blocked forever after an un-ceremonied fix, and reads clear after a ceremony with no fix behind it. |
| `bin/task list --stage blocked` | Tasks carrying a LIVE block right now. It resolves through the `Task.blocked` scope — a `building` task with `blocked_at` set — not the stage column. | Whether this task was ever sent back. A resubmission moves the task forward, which NULLs `blocked_at`, so a bounced-then-resubmitted task drops out of this listing exactly like one that was never blocked. |

**Measured, 2026-09-01→02** (`stale-engine-web3-comments` / turf PR #513): all three
answered "no block" while `bin/task bounces` read `BREAKER: TRIPPED` and the PR head
had not moved since the send-back. The task was promoted to `submitted` and a
reviewer briefed that a merge-ready verdict was on record — one step from a correct
verdict becoming send-back 2 of 2, which escalates to Mr. McRitchie over a
resubmission that never happened.

**Ask the tree instead.** The board now serves a `resubmission` verdict on every task
(`Task::Resubmission`), rendered as a card bar plus a task-page banner, and carried in
the API record — so `bin/task show <slug> --json | jq .resubmission` answers it with no
new command to learn:

| `state` | Meaning |
|---------|---------|
| `fresh` | No send-back on the ledger — an ordinary build |
| `unaddressed` | Sent back, and the PR head has **not moved** since. Reviewing this re-reads the tree that was already bounced |
| `addressed` | Sent back, and the head moved after the bounce |
| `unknown` | Sent back, but no ingested CI run resolves the head on one side. **Never read this as `addressed`** |

It counts a send-back exactly as `bin/task bounces` does (both read
`BounceLedger::COUNTABLE_KINDS`, so they cannot drift), and carries
`breaker_tripped` + `bounce_count` so the circuit-breaker state is visible where a
reader already is. A `resolves_feedback` handoff deliberately does **not** override an
unmoved head — that claim is precisely what lied in the measured case.

Do not skip `assembled` for user-facing app changes. Do not move a task to
`shipped` for production work until production has actually deployed and the
post-deploy check has passed.

## Timeline Inspection Views

Two read-only Postgres views project the task + release lifecycle in **logical
stage order** — the order the pipeline PROGRESSES through — so `psql` / a DB
browser reads a lifecycle left-to-right instead of hunting alphabetized columns.
(The physical column order is alphabetical, a past rebuild, and Postgres can't
reorder in place; hence a view.)

**Logical, NOT chronological.** `release_timeline` mirrors `Release::STAGES` — the
same canonical order the /deployments tracker uses. Release stamps deliberately
land OUT of wall-clock order: `assembling_started_at` is stamped back at MERGE time
(`Conductor.sweep!`) and `qa_deploy_started_at` before the QA deploy, so both land
BEFORE `qa_green!` stamps `tested_at`. That is by design — it is precisely why
`Release#current_stage` is documented MONOTONIC over these stamps. Do **not** "fix"
the views by re-ordering them to chronology: logical progress order is the product.

- **`task_timeline`** — a **status header** (`slug, title, stage` + the block set
  `blocked_at, blocked_from, blocked_by, block_kind` — when / from where / who /
  why), then the lifecycle chain: `created_at, updated_at → queued_at,
  sizes_revealed_at, started_at → g1_testing_started_at, g1_testing_finished_at,
  g1_failed_at → submitted_at, reviewed_at, assembled_at, completed_at,
  archived_at`, then the cache stamps `gates_cached_at, testing_phases_cached_at`.
  The block set is a HEADER, **not** the first link of the chain:
  `Task#clear_block_on_forward_move` NULLs all four the moment a task leaves
  `building`, so they carry values only while it is CURRENTLY blocked.
- **`release_timeline`** — `slug, state → created_at, updated_at →
  testing_started_at, tested_at → assembling_started_at, assembled_at →
  qa_deploy_started_at, qa_deployed_at → confirming_started_at, confirmed_at →
  prod_deploy_started_at, shipped_at → abandoned_at, release_notes_sent_at,
  duration_metrics_cached_at`.

**Always NULL today** (kept so the declared lifecycle stays complete — deliberate,
not oversight): `releases.testing_started_at` (no producer; tracker node 1 greens
off `assembling`), `tasks.queued_at`, `tasks.sizes_revealed_at`. `tasks.failed_at`
is deliberately OMITTED (dead column, not part of the flow).

Created by a plain `execute "CREATE VIEW …"` migration — DROP+CREATE, so `up` is
re-runnable; never `CREATE OR REPLACE` (Postgres cannot reorder an existing view's
columns, and order is the whole point). **Caveat:** with the `:ruby` schema format a
raw `CREATE VIEW` does NOT dump to `schema.rb`, so a fresh `db:schema:load` (test/CI
databases) will NOT have them — they are operator-inspection-only; don't back a
model or suite assertion on their existence in every environment.

### Operator footguns

1. **A schema-load rebuild loses them permanently.** `schema.rb` carries
   `assume_migrated_upto_version`, so a database REBUILT from the schema (e.g.
   `heroku pg:reset` + `db:schema:load`) marks the view migration ALREADY APPLIED —
   a later `db:migrate` SKIPS it and that database has no views, forever. After any
   schema-load rebuild, re-run the migration's `up` (it is idempotent) or execute
   the two `CREATE VIEW` statements directly.

2. **The views PIN every column they select — and the failure is CI-INVISIBLE.** A
   plain Postgres view hard-depends on each of the 39 columns it SELECTs (22 task +
   17 release). A future `DROP COLUMN` / `RENAME COLUMN` on any of them will ERROR
   unless the view is dropped first — and because the views do NOT exist in the
   test/CI database (the caveat above), such a migration **passes CI and fails on
   the production deploy**. Rule: if you drop or rename any column these views
   select, `DROP VIEW release_timeline, task_timeline` first and recreate them in
   the same migration.

## Task Metadata Contract

Tasks carry DevOps metadata in `tasks.metadata["devops"]`. The UI exposes these
fields, and agents may also write them through the JSON API with a top-level
`devops` object.

Supported fields:

| Field | Meaning |
|---|---|
| `kind` | `feature`, `bug`, `chore`, `qa`, `release`, or `cleanup` |
| `worktree_slug` | Human-readable feature handle used for the worktree path, branch, terminal context, and task binding |
| `repositories` | Repos touched by this increment, such as `mcritchie-studio` or `turf-monster` |
| `branch` | The feature branch (opened as a PR with base `release`). The shared integration branch is the persistent per-repo `release` (same name everywhere). |
| `pr_url` | GitHub PR URL |
| `local_url` | Worktree review URL, rendered as the `Local Demo` card button |
| `approval_status` | Operator validation state: `waiting`, `approved`, `changes_requested`, or `none`. `waiting` floats and pulses the card, and is legal only before the `submitted` seam — any save at `submitted` or later settles it to `none` (settled, never a fabricated `approved`) |
| `approval_requested_at` | Server-stamped ISO8601 timestamp when approval first enters `waiting` |
| `approval_requested_by` | Optional agent/session label that requested operator validation |
| `approval_approved_at` | Server-stamped ISO8601 timestamp when approval first enters `approved`. Any lane may record the grant — the board UI, or an agent writing down an approval the operator gave in words (`bin/task update <task> --approval approved`) |
| `qa_url` | Stable QA URL or specific QA route |
| `production_url` | Production URL or specific production route |
| `requires_release_conductor` | `true` when production deploy, gem publish, provider config, or env change is involved |
| `risk_tags` | Short tags such as `auth`, `email`, `solana`, `payment`, `migration`, `ui`, `provider` |
| `acceptance` | Acceptance criteria, one item per line |
| `test_plan` | Checks the feature agent expects to run, one item per line |
| `checks_run` | Checks actually completed before the current handoff, one item per line |
| `post_deploy_cmd` | Command `bin/release` runs **verbatim against the deployed app** (QA on `prepare`, prod on `ship`) after migrations, so a seed/backfill isn't run by hand. Must be **narrow, prod-safe, and idempotent** — **never a bare `db:seed`** (see safety rule below). Set to `none` to acknowledge a schema-only migration that needs no command. Two members declaring the same work **on the same app** run **once**: the plan folds the interchangeable runner spellings (`bundle exec` / `bin/` / `./` / `rails` / `rake`) and stamps the `[post-deploy]` check on both. **That prefix is the only thing normalised** — everything after the runner is compared **verbatim**, case and whitespace included, so a command differing by one space inside a quoted argument does NOT fold and runs twice. The bias is deliberate: a false split repeats idempotent work (merely slow), while a false merge silently skips declared work and still stamps that member's check green. |

**The command's EXIT STATUS is its verdict — and the only thing that is.**
`bin/release` runs it under `heroku run --exit-code` and decides pass/fail on
that status alone. The output is **read but never judged**: the captured stdout
is echoed into the release log (`print(out)`), and `parse_test_counts` scans it
so the telemetry line can carry a `12 runs, 0 failures` summary — a read wrapped
in a `rescue` exactly so telemetry can never change a release's outcome. Nothing
the command PRINTS can pass or fail it. A command that prints its own failure
and exits 0 records the hook **GREEN** and the release ships past it. So a
command that can partially fail must compare what it did against what it should
have done and exit non-zero on the shortfall.
`tasks:backfill_testing_phases` and `releases:refresh_duration_metrics` are the
worked examples — and they pick DIFFERENT skip allowances on purpose. The
backfill walks every task, so it tolerates a few isolated poisoned rows
(`BACKFILL_MAX_SKIPPED`); the refresh walks a set bounded by `LIMIT`, where a
flat allowance would swallow the whole population, so it tolerates none by
default (`REFRESH_MAX_SKIPPED`). Size the allowance to the POPULATION, and
measure against what the command actually selected rather than against its
ceiling.

**`BACKFILL_MAX_SKIPPED` — the backfill's escape hatch, and the three things it
cannot do.** `tasks:backfill_testing_phases` tolerates **5** individually-skipped
tasks by default (`Task::TestingPhases::BACKFILL_SKIP_ALLOWANCE`) and aborts the
release past that. Raise it for a known-bad row by setting
`BACKFILL_MAX_SKIPPED=<n>` on the `heroku run`. Zero would be stricter and is the
wrong trade — this hook runs AFTER the code is live, so an abort leaves a
half-shipped release for a human to unwind, and one genuinely poisoned event
history must not wedge every future release. It stays an escape hatch, not a
switch, and it cannot be widened into one:

| It cannot… | Because |
|------------|---------|
| **…be disarmed by a garbled value** | Only a bare digit string is honoured (`/\A\d+\z/`). `lots`, `5x`, `-1`, and an empty string all fall back to the **default of 5** — never to "unbounded". A typo in a deploy env var must not be the thing that lets a broken backfill ship. |
| **…authorise skipping half the board** | The allowance in force is `min(requested, ceiling)` where `ceiling = max(5, attempted / 2)`. On a board of ten rows or more that ceiling **is** half, so no override gets past it — a run that skipped half is systematic by definition, which is the condition the guard exists to catch. The floor at the default means the ceiling can only ever LOWER an override, never tighten the un-overridden guard: a 6-row board still tolerates its 5 poisoned rows. When a value is cut down the abort says so (`BACKFILL_MAX_SKIPPED=999999 capped to 10`), so the number you read is one you can account for against the value you set. |
| **…rescue a total no-op** | `attempted > 0` with `refreshed == 0` aborts **before** the allowance is consulted at all (`BackfillResult#no_op?`). No value of this variable reaches that check. |

The last two exist because both failures actually shipped: `BACKFILL_MAX_SKIPPED=999999`
once let 19 of 20 tasks fail, exit 0, and stamp the `[post-deploy]` check GREEN
over a board that had almost entirely failed to rewrite; and before `no_op?`, a
run where every single refresh raised printed `0`, exited 0, and satisfied
`heroku run --exit-code` just the same.

**`post_deploy_cmd` safety rule.** Because `bin/release` runs the command
verbatim against PRODUCTION, `bin/dor-check` **rejects** a bare full-suite seed
(`bin/rails db:seed`, `rails db:seed`, `bundle exec rails db:seed`,
`db:seed:replant`, `rake db:seed`): `db/seeds.rb` loads **every** `db/seeds/*.rb`,
so it would inject demo News/Content/Tasks into prod and abort the release on the
first non-idempotent seed file. Declare a **scoped single-file runner**
(`rails runner 'load Rails.root.join("db/seeds/NN_x.rb").to_s'`) or a **dedicated
idempotent rake task** (e.g. `bin/rails pokemon:seed`) instead. (Near-miss:
`merge-docs-reviewer-into-alex` shipped `post_deploy_cmd='bin/rails db:seed'`,
caught only when QA aborted because reviewers read the diff, not the metadata.)

Example API payload:

```json
{
  "title": "Fix QA wallet chooser",
  "description": "Clicking Solana auth on QA should open the wallet chooser modal.",
  "priority": 1,
  "agent_slug": "shannon",
  "devops": {
    "kind": "bug",
    "worktree_slug": "qa-wallet-chooser",
    "repositories": ["turf-monster"],
    "branch": "fix/qa-wallet-chooser",
    "local_url": "http://localhost:3102/contests",
    "qa_url": "https://qa.turfmonster.media/contests",
    "risk_tags": ["auth", "wallet", "qa"],
    "acceptance": [
      "Solana auth opens the wallet chooser modal on QA",
      "Email auth still opens the email flow",
      "Non-production banner remains visible"
    ],
    "test_plan": [
      "bin/rails test",
      "QA_BASE_URL=https://qa.turfmonster.media npx playwright test --grep @qa-readonly"
    ],
    "checks_run": [
      "bin/rails test test/controllers/auth_controller_test.rb",
      "local browser smoke on http://localhost:3102/contests"
    ]
  }
}
```

## Feature Agent Duties

Before implementation, the agent should record or confirm:

- task kind
- affected repo or repos
- acceptance criteria
- likely risk tags
- expected local proof URL
- expected tests/checks in `test_plan`

During handoff, the agent updates:

- worktree slug in `worktree_slug`
- branch
- PR URL
- local URL
- approval status, if the work needed operator validation
- checks actually run in `checks_run`
- any changed acceptance criteria
- release lane flag if the work needs production deploy, gem publish, provider
  config, env vars, or credential handling
- a `handoff` note on the task conversation summarizing what changed, what was
  verified, and what Avi should inspect first

## Fast Lane: `bin/task begin` and `bin/ship`

Two orchestration wrappers collapse the cycle's bookends into one command each.
**They are the default path for a single-repo task** — the entry docs
(`docs/agents/index.md`, `docs/agents/claude.md`) route feature agents here
first and keep the long form as the fallback.
They change **no gate semantics** — every gate (the build claim,
`bin/session-preflight`, `bin/fast-check`, `bin/dor-check`, the stage read-back
verify) still runs and still owns its verdict; the wrappers only sequence the
steps and skip the ones whose outcome is already durably recorded, so rerunning
after a partial failure **resumes** instead of duplicating. Resume `begin` **by
slug**: once the task exists it REFUSES create flags rather than dropping them,
so the whole `--title …` line is not the way back in.

Session start (create → `agent-worktree new` → `bind-task` → `move building` →
`session-preflight`, printing the worktree path, port, and task URL):

```bash
bin/task begin --title "Three To Five Words" --repo <app> --agent <soul> --shape <shape> \
  --risk <tag> --accept "criterion" --test "[unit] ..."
bin/task begin <task-slug>        # resume a partial begin
```

The slug is derived from the title client-side and passed explicitly, so the
same `begin` rerun finds the task it created. A resume of an already-`building`
task runs the **same build-claim gate** as `bin/task move building`, before any
worktree step: a task a different live instance holds refuses loudly with the
holder named; `bin/task begin <task-slug> --steal` takes it over, and on the
fresh path `--steal` is forwarded to the child move. Handoff (commit → `bin/fast-check`
→ push → **non-draft** PR into `accepted` whose body leads with the task URL →
record `pr_url` → `bin/dor-check` → `move submitted` → read-back verify):

```bash
bin/ship <task-slug>                     # commit message defaults to the task title
bin/ship <task-slug> -m "Commit message"
```

**Both wrappers talk to GitHub, and that credential expires ~hourly BY DESIGN.**
`bin/ship` pushes, opens the PR, and polls `gh pr checks`; `begin`'s preflight
reads PR state. When one of those refuses — `Bad credentials`, a 401/403, an
unreadable CI, a `gh auth login` prompt — it is **yours to fix, and NOT an
escalation to Mr. McRitchie**: run `eval "$(bin/gh-auth-refresh --export)"`, read
its **stderr** (`eval` reports the `export` builtin's status, so it hides the
command's exit code), then re-run the wrapper — **it resumes**, so a stale token
costs you the refresh and nothing else. Never fall back to `gh auth login`: `gh`
refuses to store a credential while `GH_TOKEN` is set, and `GH_TOKEN` outranks the
keyring it would write to, so the one step that looks like the fix is refused
outright and would repair the wrong store anyway. Architecture, the two lane
identities, and a symptom→fix table: [`source-control.md`](source-control.md).

Run `bin/ship` from the task worktree (elsewhere it re-roots at the worktree,
loudly). Before its first side effect it enforces the two handoff-seam guards
the child gates don't own: the task must be `building` (or `submitted` — a
resume; a `designed` task is sent back through `bin/task begin`), and the
build claim must not belong to a **different live instance**. That refusal
**names the holder's ROLE and routes on it**: a **builder** is taken over with
`bin/task begin <task-slug> --steal` first, then ship; a **reviewer** is
**asked to release** (`bin/task review-claim release <task-slug>`, run by
them) and never stolen, because a takeover mid-review voids the no-self-review
guarantee for that review and strands its verdict. When the board cannot
establish the role it says so and sends you to `bin/task review-claim status
<task-slug>`, which OBSERVES the lease rather than printing a timestamp to
difference by hand. Its
read-back pins the exact `pr_url` it recorded — a stale/foreign URL on the
board fails the verify. It repairs an existing PR in place — `gh pr ready` for
a draft, `gh pr edit --base accepted` for a mis-based one — and never
duplicates it. The long-form commands remain the canonical path for anything
the wrappers don't cover (multi-repo tasks, bespoke PR bodies).

**The CI settle wait (step 6/8, `gate-submit-on-green-ci`).** With the PR open and
`pr_url` recorded, ship HOLDS until the PR's CI reaches a real state, then runs
the DoR verdict — so `submitted` normally carries a **green** CI instead of a fast
cert credited provisionally against a pending one, and a red CI arrives while the
builder's worktree is still warm rather than bouncing into a cold session.

Three properties keep it from becoming a gate of its own, and all three are the
point:

- **It decides nothing.** The wait classifies into exactly two buckets — keep
  waiting, or stop waiting — and hands the state to `bin/dor-check`, which owns
  the verdict exactly as before. A red CI stops the handoff because *dor-check
  refuses it*, recording its usual failed `dor` attempt with the failing checks
  named. Duplicating that allow-list in the wrapper is how the two copies drift.
- **It is bounded at BOTH ends, and names which end it hit.** `:pending` gets the
  full budget (`SHIP_CI_WAIT_TIMEOUT`, default 900s). But `gh pr checks` reports
  `none` in the window between the push and GitHub creating the run, and
  `unverified` when the read ITSELF fails (a gh/network fault) — treat either as
  settled and the wait exits within a second of every push, silently doing nothing
  while the handoff still succeeds. So those get a **shorter** appearance budget
  (`SHIP_CI_WAIT_APPEARANCE`, default 120s). They WAIT alike and REPORT
  differently: `none` expires to `:absent` ("GitHub answered and reported no
  checks"), `unverified` to `:unread` ("could not read CI … whether this PR has CI
  is UNKNOWN"). "CI said no", "we stopped asking", and "we never got through" are
  three facts with three remedies, so they print as three sentences.
- **It reports the READ, never the repo.** A query that FAILED is not evidence
  about GitHub. Task `ship-waiter-misreports-ci` (2026-09-01) fixed a wait that
  printed "no CI run appeared within 2277s — treating this PR as having none"
  while `gh pr checks` showed 12/12 GREEN and dor-check said "GitHub CI green": it
  had rendered a network fault with `none`'s sentence. Elapsed figures are
  reconciled against the budget they were judged against, too — budgets are tested
  BETWEEN polls, so the elapsed CAN overrun one, and the summary says so instead of
  printing a number that cannot come from the configured timeout. **It reports the
  read's MEASURED duration and never infers it.** The first cut of that note charged
  the whole excess to the final read, reasoning that a nap is capped at the remaining
  budget — but the cap is on the nap the loop *computes*, `Kernel#sleep` is only
  lower-bounded, and the default clock counts host suspend on macOS, so an overrun
  can be 100% sleep and 0% read. `settle` times the probe; whatever the measured read
  does not account for is named as unbounded wall-clock rather than blamed on `gh`.
  A read the TOKEN was refused (`unreadable`, a 401/403) settles at once — waiting
  cannot mend a credential — and `bin/ship` points at `bin/gh-auth-refresh` for it,
  not only for the gh/network fault a re-run may clear on its own.
- **An unknown state settles.** `CiStatus`'s state list may grow; a state the wait
  has never heard of degrades to the behaviour that predates it, never to an
  unbounded wait on an unrecognised symbol.

`SHIP_CI_WAIT=off` disarms it. Note the wait lives in the **wrapper**: a hand-run
`bin/task move <slug> submitted` still does not wait, and `bin/dor-check`'s own
semantics are untouched. Owned by `bin/lib/ci_wait.rb`; the rule is proven in
`test/lib/ci_wait_test.rb` and its presence on the path in `test/lib/ship_test.rb`.

With the PR open, ship asks two questions of the sibling PRs in **one**
`gh pr list` — same-file overlap, which **advises**, and duplicate migration
installs, which **block**. The second is not a stricter flavour of the first: the
same-file check intersects FILENAMES, and two installs of one engine migration
have different filenames by construction, so it is blind to them by design. A
duplicate migration class raises on every `db:migrate` including the Heroku
release phase, and the cure is always the same — the task that OWNS the migration
keeps its copy, the other drops it. Ship refuses to move the task to `submitted`
until it is resolved. Both checks also run at `bin/session-preflight`, where the
migration one adds a local leg (the base ref) that needs no GitHub at all.

**Limits, stated plainly.** `bin/ship` stops at the `submitted` seam — it never
merges, never deploys, never touches `release`/`main`. It has **no `--steal` of
its own**; takeover is `bin/task begin <task-slug> --steal`, then ship — and
only against a **builder**, never against a live review. Neither
wrapper writes your tests. And `bin/ship` is **not** `bin/release ship`: despite
the name collision, `bin/release ship` is the **G4 production deploy**
(`release → main`, ship-authority only), while `bin/ship:79` pins
`BASE_BRANCH=accepted` and halts at `submitted`. The collision is fail-safe in
the dangerous direction — reaching for `bin/ship` when you meant production does
strictly less — but it has already caused one false alarm in a review brief, so
name the distinction rather than assume it.

`begin`'s step 5 invokes `bin/session-preflight` with `--root <worktree>` (the
script otherwise roots at its own file location — see `modules/worktrees.md`,
Fresh Worktree Checklist step 3), and the preflight self-defends that the
inspected root carries the task's branch, refusing a mismatched checkout. So
begin's preflight verdict describes the worktree it just created.

## QA / Avi Duties

Avi starts with the task board plus the local PR/worktree tools:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/devops-cycle
bin/devops-cycle --plan
bin/devops-cycle --decisions
bin/devops-cycle --scout-packets
bin/devops-cycle --write-scout-packets tmp/devops-scouts
bin/devops-cycle --scout-runs tmp/devops-scouts --max-scouts 3
bin/devops-cycle --scout-coverage tmp/devops-scouts
bin/devops-cycle --scout-reports
bin/devops-cycle --readiness
bin/qa-intake --refresh --apps mcritchie-studio,turf-monster
```

`bin/devops-cycle` is the first-pass conductor view. It groups active
`submitted`, `reviewed`, and `assembled` tasks with task URLs, PR URLs,
local/QA/production URLs, latest task conversation notes, and matching qa-intake
status when available. `bin/devops-cycle --plan` adds a read-only batch plan
that separates parallel PR reviews, serialized/high-risk work, blocked returns
to feature agents, reviewed work ready for release merge, and assembled release
work waiting for explicit ship authority.
`bin/devops-cycle --decisions` adds an Avi decision summary for PR-review tasks,
combining qa-intake status, latest task activity, and scout report outcomes into
`merge-ready`, `wait-for-ci`, `request-changes`, or `conductor-review`
recommendations.
`bin/devops-cycle --scout-packets` turns reviewable PR-review lanes into
copy-paste prompts for additional review-only sessions. Accurate `repositories`,
`risk_tags`, `pr_url`, `qa_url`, `acceptance`, `test_plan`, and `checks_run`
metadata make the plan and packets useful at scale. `bin/devops-cycle
--write-scout-packets tmp/devops-scouts` writes one prompt file per packet plus
a manifest so Avi can hand files to parallel review sessions without copying
large prompts through chat. `bin/devops-cycle --scout-reports` shows structured
scout reports recorded on task comments so Avi can make the final
merge/request-changes decision from multiple review sessions without losing the
thread. `bin/qa-intake` remains the raw local worktree and GitHub PR view for
branch freshness, stack health, and cleanup-state details.

`bin/devops-cycle --scout-runs tmp/devops-scouts --max-scouts 3` is the local
run-control view for Phase 3B. It reads the launcher manifest and local
`scout-runs.json`, then prints pending/launched/completed/blocked packet counts
and the next prompt files that fit inside the concurrency limit. It does not
spawn agents or update external systems. Avi marks local state with
`--mark-scout-status scout-task-XXXX:launched` and later `:completed` when a
scout report is back.

`bin/devops-cycle --scout-coverage tmp/devops-scouts` is the Phase 3C harvest
view. It compares manifest packets with structured `scout_report` task comments
and calls out missing reports or conflicting outcomes. `bin/devops-cycle
--readiness` is the Phase 3D conductor view: it groups tasks into
ready-to-merge, needs-conductor-review, needs-changes, waiting, Ready To
Assemble, Assembled Release, and scout-gap lanes. These views accelerate
review; they do not transfer release authority. Avi owns review resolution and
production ship, while Avi's `qa-release` sweep owns merge plus QA deploy.

Scout reports are supporting evidence. Avi turns blocker findings into
`qa_feedback` or PR review comments when the work must return to the feature
agent. Scout reports do not move stages; the active release SOP owns final
merge, QA deploy, production deploy, and task stage changes (Avi for
`qa-release`, Steffon for `production-deploy`).

Use the decision recommendations conservatively:

- `request-changes` means Avi should return the task to the feature agent with
  `qa_feedback` or a PR comment.
- `wait-for-ci` means the next action is to inspect or wait for checks, not
  merge.
- `conductor-review` means the task needs Avi's direct review because it is
  high-risk, multi-repo, missing local intake, or lacks enough scout signal.
- `merge-ready` means scout evidence and qa-intake are aligned; Avi still
  performs the final PR review before moving the task to `reviewed`.

1. Find `submitted` tasks with PR URLs or branches.
2. Confirm acceptance criteria match the PR body and diff.
3. **Review `devops.post_deploy_cmd`, not just the diff** — it runs verbatim
   against prod on ship. Reject a bare `db:seed`; require a narrow, idempotent
   command (`bin/dor-check` enforces this, but read it yourself).
4. Check `risk_tags` for Steffon/infra gate needs.
5. Move only approved PRs to `reviewed`; do not merge during review.
6. Let Avi's `qa-release` sweep merge reviewed PRs into `release` and deploy QA.
7. Let the sweep move QA-green tasks to `assembled` with QA URL, release SHA, and `checks_run`.
8. Leave production ship gated until Mr. McRitchie explicitly approves release work.

If the PR is not ready, Avi leaves `qa_feedback` on the task conversation with
the exact blocker, expected owner action, and any PR/CI link needed to reproduce
the issue. Also leave a GitHub PR comment when the blocker is code-review
specific or should be visible on the PR.

## Assignee vs Builder — two facts, two labels

`bin/task show <slug>` prints both, and they are **different questions**:

| Line | Reads | Means |
|------|-------|-------|
| `assignee:` | the top-level `agent_slug` column | who the task is assigned to; `unassigned` when blank |
| `builders:` | `metadata.devops.builders` + `built_by` | the AUTHOR SET `bin/reviewer-select` excludes; `NOT STAMPED` when blank |

**They disagree routinely, by design.** `bin/task move <slug> building --actor
<soul>` stamps the author (`Task#builder_to_stamp` rule 1) and sets no assignee
at all, so an actor-stamped task is correctly attributed while carrying no
`agent_slug`. Measured 2026-08-30 across four such tasks, three of them.

Until this split landed the summary printed ONE line, `agent: <agent_slug>`, and
those three read `agent: -`. Two agents checking the field the operating model
tells them is load-bearing reported a blank builder that was in fact stamped;
a third instance was avoided only because a conductor knew to read `--json`.
Neither empty prints `-` any more, because "nobody is assigned" is ordinary and
"nobody is recorded as having built it" makes review fail closed.

```bash
bin/task show <slug>              # assignee: unassigned  builders: carl
bin/task show <slug> --verbose    # built_by / builders / unattributed, + where each lives
bin/task move <slug> building --actor <soul>   # stamp an author, in place, at any time
```

`builders: shannon +1 UNNAMED` means `devops.builders_unattributed` is set — a
session worked the task while naming no soul, so the names shown are a SUBSET and
`bin/reviewer-select` refuses rather than seating a pool that may hold an author.
A value shown as `not a soul handle` is a session id or an email left on the
record by a claim that ran without `--actor`: visible on purpose, because it is
the tell for a stamp that never happened. The roster check itself lives in
`ReviewerSelector` (DB-backed), so this display reports what the record holds and
never predicts the selector's verdict.

**A REVIEWER IS NOT AN AUTHOR, and a bounce no longer says otherwise.** `bin/task
block <slug> --kind rework` lands the task back on `building`, and three readers
used to take that for a build claim by the blocking session:

| Reader | What it recorded | Now |
|--------|------------------|-----|
| the build-claim heartbeat (`bin/task heartbeat`, fired by `bin/statusline`) | ADOPTED the free lease, so the reviewer held the desk | renews a lease this session already holds; only a bound DESK may adopt a free one |
| `devops.builders_unattributed` | the reviewer's SESSION, so the author set read incomplete | a write from the session holding the task's live `TaskReviewClaim` is not a build claim |
| `ReviewerSelector#builders` | the blocking SOUL, from the block's `→ building` event | a block's transition carries `blocked: true` and is skipped |

Measured 2026-09-04: four bounced tasks in one review sitting, each needing a
hand-passed `--builder <soul>` before it could be reviewed again — and a hand-pass
is not a property, because a reviewer who passes it reflexively is exactly how a
REAL incomplete author set gets waved through. `--agent <soul>` on the block never
helped: the stamp was written by the throttled heartbeat that FOLLOWED the block,
which carries no actor at all.

The refusal itself is unchanged and still fails closed. A session that holds no
review claim and names no soul is an ordinary anonymous handoff, and selection
still refuses on it.

## Release Slug — read-only, attached by the sweep

`release_slug` is a **top-level Task column, not a field you set.** It is the
`belongs_to :release` FK, and only `Release#record_members` writes it — at the
sweep, when the task's PR actually lands on the `release` branch. It means "this
task rides release X", which is a fact about where the code is, not an intention
about where it should go.

So there is nothing to tag. Do not look for a `--release-slug` flag or a form
field; both were removed. A `devops` write to the name is refused with a 422
naming the column (`Task::DEVOPS_COLUMN_KEYS`), because it previously succeeded
against a shadow store that no release code read — the value showed on the task
page while `bin/conductor` reported no candidate.

Read it, never write it:

```bash
bin/task field <slug> release_slug      # the column, machine-readable
bin/task show <slug> --verbose          # "release_slug: rel-…" or "not on a release"
```

To order work that must ship in sequence, use `dependencies` (enforced by
`Release::Ordering`); to flag work needing an exclusive rollout lane, use
`requires_release_conductor`. Each task still owns its own PR, acceptance
criteria, and URLs.

## Cleanup Tasks

Cleanup is part of the QA/release conductor cycle, not feature-agent scope.
After a task's PR has merged and the accepted release has deployed, the
conductor records or completes a cleanup task with:

- worktree path
- branch
- merged PR
- deployed SHA
- safe-delete condition
- `bin/agent-worktree remove <app> <task-slug> --yes` result

For routine batch cleanup after a wave of PRs land, the conductor can use
`bin/agent-worktree cleanup --reclaim` as the **scale-down-on-close normal
flow**: the dry run lists every worktree that is SAFE to auto-release (clean +
merged-to-`origin/main` or main-equivalent + **unoccupied**, primary checkout
excluded) with its Redis DB, and `cleanup --reclaim --yes` runs the same full
teardown as `remove` for each one, then shrinks the Redis band toward the floor.
It never touches a dirty or unmerged worktree, and never one somebody is working
at — a fresh desk is git-identical to a merged one, so git eligibility alone once
destroyed a live builder's desk. See
[`worktrees.md`](worktrees.md) for the occupancy guard. Use targeted
`remove <app> <task-slug> --yes` when recording a single named cleanup task; use
`cleanup --reclaim` to reclaim all merged slots at once.

Feature agents keep worktrees and branches until Avi or the release conductor
confirms the PR was merged or intentionally abandoned.

## Test Suite Catalog

`bin/devops-tests` reads `config/devops_test_suites.yml` and shows the local,
QA, devnet, and production checks for each managed app, including lane, trigger,
whether each suite blocks PR merge, and whether it mutates data.

Add or update this catalog whenever a new app joins the managed stack, a test
genre changes, or a deploy smoke command changes.

## Parked Identities

Every managed app should define parked/core identities for known operators. At
minimum, `alex@mcritchie.studio` and `team@mcritchie.studio` must resolve to
admin-capable rows. Apps with wallet auth should also bind known wallets so a
first email, Google, or wallet login adopts the same seeded identity instead of
creating a fresh operator account.

New apps should ship:

- a `User::PARKED_IDENTITIES`-style constant or equivalent app-owned contract
- seeds that consume the same identity contract
- login hooks that claim a parked identity by verified email or wallet
- tests proving known email and wallet logins adopt the parked row

## Discord Deploy Notices

Production deploy conductors must use `POST /api/v1/release_notes` to send the
canonical Discord Release Notes message after a successful production deploy.
Do not hand-format the Discord post when the API is available.

Call the API with the accepted production task slugs, release metadata, URL, and
verification checks. The API groups linked task titles by application in the
standard ecosystem order and points every task link at the production task read
page on McRitchie Studio.

Run a dry-run first:

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

After confirming the rendered `message`, repeat the same request without
`dry_run`. Production uses `DISCORD_RELEASE_NOTES_WEBHOOK_URL`, with
`DISCORD_DEPLOY_WEBHOOK_URL` retained as a fallback for older environments.
Never commit webhook URLs.

## The build claim: liveness and progress are two facts

Unsupervised task claiming arrived, so the lease fields this section once
deferred now ship. They live in `metadata.devops` and the math is `ClaimLease`
(`lib/claim_lease.rb`), shared verbatim by the `bin/task` CLI and the Task model:

- `claimed_session` — the agent session holding the desk
- `claim_nonce` — a per-PROCESS token (two terminals resuming one session id are
  two instances)
- `claim_expires_at` — a 120s TTL, renewed by the heartbeat in `bin/statusline`,
  and **declined once the holder can be shown to have gone** (see "A lease is
  renewed by work" below)

**The lease attests that a terminal is painting, and that nothing has shown the
holder to be gone.** It does NOT attest that someone is working — the rule is
negative on purpose, because every unknown keeps the desk. The second half
arrived on 2026-08-13; before it, the ~5s status-line
render renewed the claim unconditionally, so the lease stayed green through a
wedged agent — on 2026-07-13 a session held a perfectly healthy-looking lease for
35 minutes while producing nothing, and the board's green dot was read as
progress. It never meant that.

**A claim is released when the task leaves `building`.** The build claim is a
build-stage lease, re-asserted as an invariant on every save
(`Task#enforce_build_claim_invariant`), so `submitted`/`blocked`/`reviewed`/… all
drop the keys. The same invariant carries a live claim through a PATCH that omits
it: the API used to replace `metadata["devops"]` wholesale (it merges since
`api-devops-patch-replaces`), and the board's own edit form permits no claim keys,
so before this a board save silently destroyed a live claim — which then read as
*unclaimed* and invited a second agent onto an occupied desk. The invariant stays:
it is what defends the claim against a caller that posts the keys BLANK, which the
merge honors as a deliberate clear.

So the board carries a **second, independent fact** beside it — the task's last
**durable artifact**, derived (never declared) from evidence we already write:

- **TaskEvents** — stage moves, intents, and cert checkpoints
- **GateRuns** — a gate opening, recording a lane, or closing

`Task#last_progress_at` / `#last_progress_label` / `#progress_seconds_ago` expose
it; the API projects it on the task; the card and the claim gate state it in words
("last durable progress ~2.5h ago · g1_cert failed"). A wedged agent cannot fake
these, because they exist only when work actually landed.

**There is deliberately no STALLED verdict, and you should not add one.** Measured
over 243 real building windows (prod, 14 days): the median HEALTHY window already
contains a **26-minute** board-write silence (p90 66m, p99 125m), and legitimate
certs run to **94 minutes** at p99. A "no durable write in 15m ⇒ stalled" rule —
the obvious design — flags **79% of healthy desks**, and still misses the wedge
that motivated it (its failing certs wrote no gate rows at all). Silence is not
evidence of a wedge: agents think, run long certs, and wait on the operator. A
chip that cries wolf on four of five healthy desks is the same lying gate with its
polarity flipped, and it trains every reader to ignore it.

What ships instead is honest and quiet about its limits:

- the **age** is always shown for a live claim — a fact, not a verdict;
- a conservative `quiet` note, **derived from the measurements above rather than
  chosen**: `ClaimLease::PROGRESS_QUIET_SECONDS` = the worst measured healthy
  window (the 125m p99) × 1.5 = **3h07m**. It carries a margin because at n=243
  that p99 rests on two or three tail observations — a point estimate the corpus
  cannot pin down — and a threshold parked ON it would flag healthy desks whenever
  the tail breathed. It is suppressed while a gate is in flight, and reads
  **healthy whenever the fact is unknown**. Re-measure the corpus and the
  threshold moves with it; the guard test asserts the property (no measured
  healthy window may ever render quiet), never the literal;
- **nothing is destructive.** Quiet reclaims no desk, blocks no move, and never
  touches the lease. A quiet desk is still a HELD desk.

### Progress belongs to whoever produced it

A durable artifact records **who** made it — the session, stamped in
`metadata["session"]` by `bin/task checkpoint` and `bin/gate`, or already carried
in `task_events.actor` on a CLI stage move. Unattributed progress used to be
credited to whoever held the claim, which let a lease manufacture its own
evidence: on 2026-08-13 a challenger ran `bin/full-suite-check`, the cert landed a
`g1_cert` row on a task it did **not** hold, and the claim gate refused that same
challenger with *"last durable progress ~2m ago (g1_cert passed)"* — the
challenger's own work, quoted back as proof the holder was alive.

So the gate reports `holder_progress_*` (the newest artifact the **holder**
produced) and names the remainder honestly — "THIS session's own work", "belongs
to …abcd", or "has no recorded owner". An unowned row stays unowned; a guessed
owner is the failure this exists to end.

### A lease is renewed by work, not by a status line

`bin/statusline` fires `bin/task heartbeat <slug> --desk <desk>` every ~45s. The
heartbeat renews only when it cannot show the holder has gone; it declines when
**every** channel has been silent past `ClaimLease::DESK_IDLE_SECONDS`:

- **desk mtimes** (`DeskActivity`) — authored files under the holder's own desk,
  pruned of machine churn (`.git`, `log`, `tmp`, `node_modules`, build output). A
  running server or a `git status` from the status line is not a worker.
- **a gate in flight** — a cert writes nothing into the desk for up to 94 minutes.
- **operator approval** — a task parked on Mr. McRitchie is not abandoned.
- **durable board progress** — a holder working through the API still reads alive.

**The two board channels are holder-scoped**, and that is the difference between
fixing this and half-fixing it. Both once read the *task-wide* fact, so a queued
challenger running `bin/full-suite-check` on a held slug landed a checkpoint and
opened a `g1_cert` on someone else's task — and the abandoned holder renewed for
another 1h29m on the strength of the challenger's own work. The heartbeat reads
`holder_liveness_seconds_ago` and `holder_gate_in_flight` instead. The gate
channel is **filtered, never dropped**: a holder mid-cert still needs it, so a
gate opened *by the holder* protects the holder and one opened by a challenger
does not.

**Every unknown keeps the desk.** No desk bound to the task, an unreadable root, a
walk over budget, an exception, an artifact **nobody signed**, or a board too old
to publish the holder-scoped field all resolve to "not abandoned", because freeing
a desk too late costs waiting while freeing it too early costs the work. So an
unsigned gate run still protects its holder — nobody is not "somebody else", and
reading a missing field as proof of absence would evict a live worker on a schema
gap. The desk must be bound to *this* task (`.agent-context.json`); a primary
checkout is written by every agent on the machine, so judging a claim there would
renew it forever — the same bug one indirection out.

The same rule runs in **both directions**, which is why the refusal message and
the reaping decision disagree about an unsigned row on purpose. The message
argues the holder is *alive*, so it may never cite a row nobody signed
(`holder_progress_*`, strict). The heartbeat argues the holder is *gone*, so it
may never reap on one (`holder_liveness_*`, permissive). Both refuse to invent
evidence; they are asserting opposite propositions.

`DESK_IDLE_SECONDS` is **derived, not chosen**: 341 desk-edit gaps measured across
37 real worktrees split into a working band and an abandoned (left-overnight) one,
with no samples in the 3556s–3895s gutter between them. The threshold is the worst
**working** gap × 1.5 = **1h29m**. Deriving it from the pooled p99 (6.4h) would be
circular — that tail *is* the bug. The guard test asserts both sides: no measured
working gap may read as abandoned, and the median abandoned gap must still be
caught.

Nothing here reclaims a desk. The heartbeat simply stops renewing, the TTL lapses,
and the ordinary claim gate admits the next claimant — and if the call was wrong,
the holder's next heartbeat re-claims the task, so the mistake heals itself.

**And a heartbeat never ACQUIRES a lease it does not hold.** Everything above is
about *keeping* a claim; this is the other end. A claim is made deliberately
(`bin/task move <slug> building`), never inferred from the fact that a terminal is
painting — so an `:unclaimed` or `:expired` lease is not adopted just because a
session's marker points at the task. The one exception is a bound DESK: a worktree
whose `.agent-context.json` names *this* task is evidence the session is at its
workbench, which is how a builder whose lease lapsed re-adopts it. A reviewer's
primary checkout can never produce that evidence, which is the point — `bin/task
block` repoints the blocking session's marker at the task it just bounced, and the
heartbeat that followed used to take the desk and the authorship with it.

## The release owns the gem version — builders never write one

**Do not set a gem's version in a feature PR** — `lib/studio/version.rb`, or the
version line of a gemspec. `bin/dor-check` refuses a PR that does, and the refusal
names the remedy. This is not a style preference; it is arithmetic.

**`CHANGELOG.md` is NOT gated** — deliberately, for now. The version is safe to
refuse because it has a working manual path: the release conductor commits it onto
the gem's `accepted` during the sweep. Nothing yet assembles a changelog from a
release's members, so refusing changelog edits would leave the file un-editable with
no writer and no manual path. It becomes release-owned when its assembler ships.

A version is a property of the **release**, not of any PR. N pull requests riding
one candidate publish exactly **one** version, so no individual PR can know the
right answer at the moment it is written. On 2026-08-10 four open `studio-engine`
PRs each chose independently — `0.33.0` (already published), `0.34.0`, `0.35.0`,
against an `accepted` at `0.33.0`. A PR carrying an already-published version leaves
`origin/release` ahead of the last tag without advancing past it, which is the
stranded-work guard's exact trigger — and that guard aborts the sweep for **every
repo**, not just the gem. The obvious remedy for the first PR collided with the
second, so the naive fix just moves the collision one PR to the right.

So the number is derived from the candidate's **membership** — the first moment it
is knowable — by `Release::GemVersion` (`app/models/release/gem_version.rb`, pure
and unit-tested), from metadata your task already carries:

| The candidate contains | Bump |
|---|---|
| any member risk-tagged `breaking` | major |
| any member with `kind: feature` | minor |
| otherwise (`bug`, `chore`) | patch |

`next = last published + max(bump across members)`, where **last published** is the
higher of the last `v*` tag and the highest version live on RubyGems — a tag that
lags a publish can never re-tread a spent number.

**`bin/release prepare` allocates it at step 4d — nobody sets it by hand**
(finding-d0621629719b, now closed). Prepare derives the number from the table above,
writes the `version_file` **with its `Gemfile.lock` in the same commit** onto
`origin/release`, and does it before the publish. The lockfile is not optional:
studio-engine bundles itself as a path gem, so its own lock names its own version,
and CI installs frozen — a version commit without its lock fails `bundle install`
before a single test runs.

The "mutate before validate" concern that descoped this originally is answered by
running allocation in two phases of its own: it DECIDES for every swept gem before
WRITING to any of them, so a refusal anywhere leaves every release branch untouched.
What it writes is a git commit (reversible); the irreversible `gem push` still
happens only after `validate_gems_for_qa` has preflighted every gem.

**It refuses rather than guesses.** An unreadable `--gem-bump`, an unparseable last
version, a `version_file` declaring its version twice, or a `bundle lock` that did
not land the new number each abort the sweep with nothing published — a refusal
costs a re-run, a wrong allocation costs the RubyGems number forever. Allocation is
idempotent, so a re-run skips a version already past the last published one. The
stranded-work guard stays armed behind all of it as the backstop: if allocation is
ever skipped or wrong, the sweep still aborts for **every** repo, loudly, with
nothing published and nothing deployed.

**The derived bump is a floor for routine work, not a judgment about public
surface.** The table reads a task's `kind`; it cannot know that a `bug` also
removed documented API. MEASURED, 2026-08-11: studio-engine 0.38.0 → 0.39.0 rode
a `kind: bug` member that dropped `--studio-bars-h`, a documented public
contract. The derived bump scores that a **patch** (0.38.1); the conductor
correctly called it a **minor**. When a change touches public surface, say so —
`--gem-bump minor`, or a `breaking` risk tag when it deserves a major.

**Your only lever, and you rarely need it:** when the derived bump is wrong — most
often a `chore` that is genuinely breaking, or a `bug` that removes public API —

```bash
bin/task update <task-slug> --gem-bump major   # patch | minor | major
```

It is an override, never a requirement. Leave it unset and the release derives the
bump from the task's `kind`.

