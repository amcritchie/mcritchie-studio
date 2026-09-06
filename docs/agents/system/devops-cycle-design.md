# DevOps Cycle — Design (v2)

> **Status:** approved model, landing incrementally. The **two-workflow task
> status model is now live** — `Task` stages are
> `designed → building → submitted` (Build) and
> `submitted → reviewed → assembled → shipped → archived` (Deploy — the
> `shipped → archived` archive loop closes it, §1.4) — meeting at the
> `submitted` seam — plus `blocked` (side) and `archived` (terminal).
> `bin/task`, `bin/dor-check`, and the board speak it.
>
> **DevOps v2 — the `accepted` ladder + Actions-authoritative gates (approved
> 2026-07-14, in rollout).** Feature PRs will target a new persistent **`accepted`**
> branch below `release` (review merges there, stamping `merged: "accepted"`);
> **GitHub Actions becomes the authoritative gate verdict** at each promotion seam
> (G1 stays a fast local pre-flight); and QA + prod **deploys move into Actions**,
> gated by GitHub Environments (optimistic QA, operator-confirmed prod). See the
> **target-model** subsection at the head of §1 and the phased rollout in
> "Implementation order". Piloted in `mcritchie-studio`, then rolio, then
> turf-monster; the Phase-1 base-flip cuts over onto an empty board.
>
> **Landed since:** the `Release` singleton model; the persistent-`release`
> branch CLI — `bin/release init|merge|prepare|ship` (§1.1); and
> `bin/agent-worktree`'s release-aware base default — `new` cuts the feature
> branch from `origin/release` (falling back to `origin/main` where no `release`
> branch exists) and `finish --pr` opens the PR with `--base release`.
>
> **Still to land (each its own task):** the Discord progress webhook (§5). Where
> this doc describes it, it is the spec for the follow-up.
>
> **Since landed (do NOT rebuild):** **multi-repo `ship`** — `bin/release ship` is
> now a full producer-first, hub-before-satellites pipeline (gems publish → auto
> re-pin consumers → hub app deploy → satellites), with the per-repo `test_cmd`
> gate and partial-ship recovery (`Release::ShipSequence`, `bin/release.rb`); it is
> **not** hub-only. The heartbeat planner `bin/devops-cycle` was also migrated off
> the legacy stage names (it speaks `submitted`/`reviewed`/`assembled`).
>
> **Deploy-flow redesign (decided, 2026-06-22; review + release lanes re-homed
> 2026-07-22).** The `submitted → shipped` half was re-homed by role — review is
> **owned by Carl** (one Carl per PR, the standing primary + owner; no Avi
> supervisor), `assembled` is owned by **Avi** (Product Owner, the `qa-release`
> sweep + QA), and `shipped` is owned by **Steffon** (now titled **Platform
> Engineer**; full e2e on the frozen ship SHA) plus explicit ship authority: the
> default operator gate or the `full-cycle` autonomous kickoff. **§1.2 is the
> rewritten spec.**
> It lands via three build tasks: `deploy-flow-heartbeat-tooling` (planner/tooling + the
> `prepare` retry/wait-for-boot fix), `stages-page-step-outlines` (the per-step
> `/stages` outlines), and `seed-souls-prod-qa` (the reviewer souls, incl. a new
> **Alex Documentation** reviewer persona distinct from the orchestrator seat).
>
> Operator companion: the board stage guide at
> [`/stages`](https://mcritchie.studio/stages), and the rendered **SOP
> infographic** — the cycle drawn as accountability swimlanes, one row per owner —
> at [`/stages/sop`](https://mcritchie.studio/stages/sop). Both render from
> `config/devops_vocabulary.yml` (read via `Devops::Vocabulary`), the **single
> source of truth** for the SOP vocabulary: rename a term there and it flows to the
> UI in one edit, so the page and these docs cannot drift. This document remains
> the canonical full SOP.

This design answers seven goals:

1. Note the current infrastructure (done — see "What already exists").
2. A testing strategy on the unit→component→integration→E2E→manual pyramid,
   with a clear answer to *who writes which tier, when, and when we prune*.
3. An airgapped heartbeat DevOps agent (review→QA, **gate prod**).
4. Scale + resilience to 100 parallel feature agents.
5. Standardized, high-visibility Discord progress / blockers / release notes.
6. Self-loading agentic context (feature→X, bug→Y) so you never re-explain.
7. A clear deterministic-vs-judgment map + a model-per-step budget.

---

## What already exists (do not rebuild)

| Capability | Where | Reuse as |
|---|---|---|
| Task state machine — Build `designed→building→submitted→reviewed`, Deploy `reviewed→assembled→shipped`, plus `blocked`/`archived` | `Task` model, `devops-task-board.md` | The spine. Everything routes through the task. |
| `kind` (feature/bug/chore/qa/release/cleanup), `metadata["devops"]` contract | `devops-task-board.md` | SOP routing key + handoff record. |
| Activity log: `comment` / `clarification` / `qa_feedback` / `handoff` + scout reports | `Activity`, task-board API | The durable QA↔feature-agent channel. |
| Sealed-bid sizing, `backend_migration` claim lane, `release_conductor` lane | `sizing-rubric.md`, `exclusive-lanes.md` | Order-of-operations machinery. |
| Test lanes (pr_review_gate / local_proof / qa_acceptance / production_smoke / nightly_deep / quarantine) + `config/devops_test_suites.yml` + `bin/devops-tests` | `testing.md` | The *when/where* axis of the pyramid. |
| `bin/qa-intake`, `bin/devops-cycle` (scout packets/decisions/readiness), `bin/agent-worktree`, `bin/qa-server`, `bin/deploy` | `parallel-agent-devops.md` | The conductor toolchain the heartbeat agent drives. |
| Discord `POST /api/v1/release_notes` (dry-run, grouped-by-app, standardized) | release notes service | The standardized visibility primitive. |
| "Future Heartbeats" lease-model spec | `devops-task-board.md` | The literal blueprint for the airgapped agent. |

The job is **formalize + close gaps**, not greenfield.

---

## 1. The cycle, end to end

The flow is **two workflows**, matching how the work actually splits and *who
owns each*. **Building** a change (the feature agent) and **shipping** a release
(DevOps) are different jobs at different cadences, so they are different
lifecycles that meet at one seam — `submitted`.

- **Workflow 1 — Build (per task · feature agent):** `designed → building →
  submitted`. A task is specced (`designed`), an agent claims and builds it
  (`building`), and opens a PR (`submitted`) — where the feature agent's part
  ends. A wall, bounced PR, or unready dependency parks it at **`blocked`**.
- **Workflow 2 — Deploy (per release · DevOps):** `submitted → reviewed →
  assembled → shipped`. **The souls split it (2026-07-22): Carl owns review; Avi
  assembles + QAs; Steffon ships.** Review runs as **one Carl per PR** — the
  review session (a Pokémon orchestrator) claims reviewable PRs and spins up one
  **Carl**, the standing primary AND owner. **There is no Avi supervisor.** Each
  Carl does the deep review (acceptance, base tests, standards, smell,
  scalability), owns the gates, **summons a domain LIGHT specialist at his
  discretion** for a focused second read, drives the verdict, and on a
  merge-ready verdict **merges the feat PR into `accepted`** (stamping `merged:
  "accepted"`) and drives the task to **`reviewed`** — then STOPS. Review still
  never touches `release`/`main` and never deploys. A blocker lands it at
  **`blocked`** (rework, with a `qa_feedback` note). **Avi** (Product Owner) then
  runs the **self-healing `qa-release`** (`bin/release prepare`): it promotes
  **ONE `accepted → release` batch PR per repo** — not N per-task merges — onto
  the single **release candidate (RC)**, re-stamping `merged: "release"` on its
  members (stages unmoved), gates `origin/release` on the next tier (integration
  + an e2e smoke), deploys it to QA, and flips members `reviewed → assembled`
  only on **QA-green**. At ship **Steffon** runs the full e2e
  on the frozen ship SHA and, with explicit ship authority, the conductor
  fast-forwards `release → main` (stamping `merged: "main"`, then `shipped`).
  `submitted` is the seam — the feature agent hands the PR to DevOps there.

QA and production are properties of the **release**, not the individual task —
so there is no per-task QA stage; ship authority is a single decision on the RC
after the frozen-SHA gate.

```
WORKFLOW 1 · Build (feature agent)         WORKFLOW 2 · Deploy (DevOps · Release model)
designed → building → submitted ─────────► submitted → reviewed → assembled → shipped → archived
               ▲         │                  (review)   (approved) (merged RC,  ("run the    (archive
               └ blocked ┘                                         e2e green,   deployment" loop,
                 (rework / env / dep)                              QA-deployed)  → prod)    §1.4)
```

`blocked` is the "not in the pipeline's court" signal — an agent hit a wall, QA
bounced the PR, or a dependency isn't ready. It is **NOT a stage**: it's an
ATTRIBUTE of a `building` task (a block means "more building to do"). `Task#block!`
lands the task on `building` and stamps `blocked_at` (when) + `blocked_from` (the
stage it stalled in) + `blocked_by` (the agent) + `block_kind` (environment /
rework / dependency); `#blocked?` re-derives a live block from those columns, and
the card glows red in the Building column until it's resumed (`Task#unblock!`) or
advances. The durable block markers retros/insights key on are `blocked_at` + the
`qa_feedback` Activity a caller posts alongside — never a `→blocked` transition
(there is none). `archived` is terminal.

The RC is a **`Release` singleton** (only one assembles at a time). Member tasks
carry its `release_slug`; it carries them through QA→prod and flips them to
`shipped` when it ships. The airgapped agent runs both workflows and crosses the
ship gate only when the session carries explicit production authority (`Merge,
Assemble, Deploy`, direct ship approval, or an already-approved rollout prompt).
The task API is on production, so the airgapped box only needs an internet
connection — no separate pull/sync layer.

**Open every cycle by assessing the board BY STAGE** — `bin/task list --stage
reviewed|assembled|shipped|submitted|building`, never the default flat `bin/task
list` (it caps at the 20 newest tasks across all stages with no truncation
warning, so older actionable work silently falls off). See
[`parallel-agent-devops.md` → Step 0](../modules/parallel-agent-devops.md#step-0--assess-the-queue-by-stage).

### Target model — the `accepted` ladder + Actions-authoritative gates (read this first)

*Approved 2026-07-14; landing incrementally (phases in "Implementation order"),
piloted in `mcritchie-studio` first. The subsections that follow (§1.1, §1.2, the
Feature/Bug SOPs, §3.3 DoR, and Workflow 2 in §4) describe today's two-branch
mechanics and are reconciled to this model as each phase lands. Where they still
say "PR into `release`", "the sweep merges each feature PR", or "the gate runs the
local suite", read the target below.*

**Why.** Today the *authoritative* test-and-deploy verdict runs locally on a
developer machine — `fast-check`/`full-suite-check` certify G1, and `bin/release
prepare`/`ship` run the G3/G4 suites in local gate workspaces and `git push heroku`
directly. That local-cert model is the root of a documented flakiness class
(parallel-cert SIGSEGVs, stale-cert false positives, shared-primary-torn-mid-suite
false reds) that we have spent real effort mitigating with fingerprinting and
isolated gate workspaces. v2 moves the deciding run onto clean, isolated GitHub
Actions runners and moves deploys into Actions — deterministic verdicts, and
orchestrators that "just work with PRs and trigger Actions".

**Three persistent branches per repo — a promotion ladder.** `accepted → release
→ main`, one name each, all permanent (like today's `release`) and each
re-baselined after a ship:

- **`accepted`** — the integration line. `feat/<slug>` PRs target it, and
  **review merges them here on approval** (the merge *is* the acceptance). This is
  new authority: today review is review-only and nobody merges at review.
  Complications are resolved on `accepted`, never on `release`.
- **`release`** — the release-state machine (the exact code a release *is*). qa
  promotes **ONE `accepted → release` batch PR** — replacing today's N per-task
  `feat → release` sweep-merges — merges it on green, and QA-deploys.
- **`main`** — production. `release → main` is the production candidate; the merge
  is a formality after the release gate + operator confirm.

**`merged` gains an `"accepted"` state.** The crash-recovery git-location field
becomes `nil → "accepted" → "release" → "main"` (each stamp = where the code
physically sits: review-merged onto `accepted` → swept into `release` → ff'd into
`main`). An interrupted reviewer skips re-merging `accepted`; the interrupted-Avi
(re-merge `release`) and interrupted-Steffon (re-ff `main`) skips are unchanged.

**GitHub Actions is the authoritative test verdict at every seam**, read via
`CiStatus`/`gh` and recorded into the same attempt-aware `GateRun` rows the gates
already use. One reusable workflow, one tier per seam:

| Seam (PR into) | CI tier | Grain | Gate |
|---|---|---|---|
| `accepted` | **Tier 1** — scan + lint + full base+system suite | per-feature ("granular") | **G1 / G2** |
| `release` (+ push to `release`) | **Tier 2** — the batch suite | release-batch ("group") | **G3** |
| `main` | **Tier 3** — exhaustive / pre-prod superset | full app | **G4** precondition |

**G1 stays a fast local pre-flight** (`fast-check`, ~1 min) to save Actions
minutes and catch obvious breaks; the **authoritative** G1/G2/G3/G4 verdict is the
Actions conclusion for the seam's SHA (at G3/G4 this *promotes* today's existing
non-blocking CI auditor to the verdict). On the hub all three tiers run the same
suite — the hub already runs full+system+scans per PR — so they differ mostly in
scope; depth divergence (e.g. staging Playwright/@devnet) is a turf-monster
concern. To keep that overlap from waiting out the identical suite twice on one
tree, the G3 pre-QA gate **credits** an existing green conclusion before polling,
in two shapes (both `bin/release.rb`, `pre_qa_gate`): **same-SHA** — the promote
fast-forwarded, so the release tip IS the accepted head whose completed greens
cover the pending duplicates (`ci_credit_verdict` → `CiStatus.credit_for_sha`,
G4's `ship_gate_skip?` discipline); and **same-TREE** — the live batch-PR merge
minted a new SHA snapshotting the accepted head's exact tree
(`tree_identical_promote`), so the accepted head's green vouches for that content
— credited when it is already green, and **waited on** when it is still in flight
(`tree_identical_ci_outcome`; the gate note records both SHAs + the shared tree
in `qa_gates[repo]["ci"]["credited"]`), since in a fast pipeline accepted CI is
essentially never settled at gate time. A consumer lock-bump commit riding
`release` (gems publish before QA) breaks tree identity by design — the credit
refuses and the post-bump SHA earns its own polled verdict. Red, missing-checks,
and diverged-tree verdicts poll exactly as before; an in-flight (pending)
accepted run on the identical tree is now WAITED ON rather than duplicated (the
wait shares the gate's poll deadline), and every non-credit logs why. The
release-push workflow still runs (canceling the superseded duplicate run is an
Actions-side follow-up, not a gate concern).

**Deploys run in GitHub Actions, gated by GitHub Environments:**

- **QA — auto + optimistic.** A push to `release` triggers the `qa-deploy`
  workflow (`qa` environment, no reviewer). qa does **not** block on it: once
  Tier-2 CI is green it opens the `release → main` PR immediately (a broken QA boot
  no longer stalls the pipeline — the operator launching `production-deploy` is the
  human gate).
- **Production — operator-launched.** The `prod-deploy` workflow is
  `workflow_dispatch` into a `production` environment (kept for `HEROKU_API_KEY`
  secret scoping + deploy history); its required-reviewer approval was **removed
  2026-07-20** (task `remove-prod-deploy-approval`), so a dispatched run deploys
  straight through. The human gate is the operator's act of launching `bin/release
  ship` plus its `--yes` confirm — not a second click. It is `workflow_dispatch`,
  **not** `push:[main]`, so the ship's `release → main` ref-push can't self-fire a
  production deploy.

**Rollout** (each phase = its own task + PR through the cycle): **0** ratify this
doc · **1** `accepted` + tiered CI (hub) · **2** Actions CD (hub) · **3** flip gate
authority + rewrite SOPs (hub) · **4** canary + delete the demoted local gates ·
**5** propagate to rolio then turf-monster. The Phase-1 base-flip cutover lands on
an **empty board** (after the current release drain), so the in-flight-PR retarget
risk is zero.

### 1.1 The Release model + the persistent `release` branch

**Release** (singleton model) coordinates one candidate from assembly through
ship. *Consolidation (decided):* the legacy `release_train` field has become
**`release_slug`** — one concept, one name.

**The integration branch is PERSISTENT.** Every repo keeps a single `release`
branch — the *same* name in every repo (`Release::BRANCH = "release"`). Feature
PRs target `release`, not `main`; `main` is always an ancestor of `release`.
`bin/release init` creates the branch (= `main`) on every gem + app repo, once
(idempotent). Membership records **at the sweep**: Avi's `bin/release
prepare` (or the per-task `bin/release merge <task>` primitive it loops) merges
an approved PR into `release` and attaches the task to the active candidate —
`release_slug` + `merged: "release"`, stage still `reviewed`. The member flips
`reviewed → assembled` only on **QA-green** (`Release::Conductor.qa_green!`,
after `prepare` deploys `origin/release` to QA and it smokes green). `ship`
fast-forwards each repo's `release → main` (stamping members `merged: "main"`)
and deploys prod. After a ship, `release` collapses to `main` and re-accumulates
the next candidate.

| Field | Meaning |
|---|---|
| `slug` | Canonical id, e.g. `2026-06-20-s3-uploads`. |
| `state` | `assembling` → `assembled` → `shipped` (+ `abandoned`). `assembled` = the QA candidate is built (members merged into `release`) **and** its suite checks out. |
| `branch` | The persistent integration branch `release` (same name in every repo); feature PRs merge into it, QA deploys from it, and `ship` fast-forwards it into `main`. |
| `confirmed_at` / `confirmed_by` | The ship authorization at `assembled → shipped` — operator approval for the QA workflow, or the autonomous production kickoff. |
| `qa_url` / `production_url` / `deployed_sha` / `release_notes_sent_at` | Deploy + notes record. |
| stage timestamps | The fine-grained **stage timeline** under `state` — see below. |
| has_many `tasks` | via `tasks.release_slug`. |

**The stage timeline (`Release::STAGES`).** Under the coarse `state` machine the
release carries an ordered set of timestamp columns, each a **time-and-boolean**
(stamped = the stage started/landed; blank = not yet). They are the single input
the /deployments pizza-tracker reads, they stamp **first-write-wins** (a replay
never rewrites history), and the release's current stage is the **latest**
stamped one (monotonic — a late upstream write never winds the tracker back):

| Stage | Stamp | Tracker reads |
|---|---|---|
| `testing` | `testing_started_at` | node 1 Testing yellow |
| `tested` | `tested_at` | (not a tracker node) — the /deployments **Tested** column's end stamp |
| `assembling` | `assembling_started_at` | node 1 green · node 2 Assembling yellow |
| `assembled` | `assembled_at` | node 2 green |
| `qa_deploying` | `qa_deploy_started_at` | node 3 Deploying QA yellow |
| `qa_deployed` | `qa_deployed_at` | node 3 green **"Live on QA"** — node 4 stays dark |
| `confirming` | `confirming_started_at` | node 4 Confirming yellow |
| `confirmed` | `confirmed_at` | node 4 green |
| `prod_deploying` | `prod_deploy_started_at` | node 5 Deploying yellow |
| `shipped` | `shipped_at` | node 5 green |

Stamps flow from the release **event trail**: every `record_event!` write — the
conductor's `bin/release prepare`/`ship` checkpoints AND the agent-facing
`POST /api/v1/releases/:slug|current/events/:step/(start|complete)` API — maps
`(step, status)` to its stage stamp (`Release::EVENT_STAGE_STAMPS`). `prepare`
brackets its `pre_qa_gate` (the integration/e2e-smoke test run) with
`review_tests started`/`completed`, which stamp `testing_started_at` /
`tested_at` — the /deployments **Tested** column (`testing_started_at → tested_at`).
`tested` is a duration stamp only, NOT a sixth tracker node (node 1 still greens
on `assembling`). A node
lights yellow ONLY on its own start stamp, so a finished stage leaves the next
node **dark until its owner posts their start**. That gap is the explicit
**Avi → Steffon handoff**: Avi's qa-release finishes at `qa_deployed` (three
greens, Confirming dark, "Live on QA"); stage 4 lights only when Steffon posts
`confirming/start` as he picks the candidate up (`production-deploy` SOP).
`reopen!` (a late sweep onto an assembled RC) clears the `assembled` →
`confirmed` stamps so the re-assembly + re-QA re-stamp fresh; `shipped` is only
ever stamped by `ship!`, never by an API post. Full API contract + the
post-by-post table: `docs/agents/modules/task-board-api.md` ("Release stage
timeline").

**Task** gains three links:

| Field | Meaning |
|---|---|
| `release_slug` | The Release this task rides (null until the sweep attaches it; the stage flips `assembled` on QA-green, not at merge). |
| `merged` | WHERE the code physically is — the crash-recovery git-location, orthogonal to `stage`: `nil` = not merged anywhere · `"release"` = merged onto the release branch (QA in flight) · `"main"` = ff'd into main (prod deploy in flight). Matrix: reviewed+nil = not swept · reviewed+release = swept/QA-in-flight · assembled+release = QA-green awaiting Steffon · assembled+main = ff'd/prod-in-flight · shipped+main = done. An interrupted Avi skips re-merging `release`; an interrupted Steffon skips re-ff'ing `main`. |
| `dependencies` | Array of task slugs this one needs shipped first. **Now enforced** by the conductor (`Release::Ordering`) — a member sorts after every task listed here — composed under the producer-first rule (e.g. an engine gem before the apps that consume it). |

`dependencies` (task→task) and the exclusive **lanes** (resource-level:
migration, release, vault single-writer) compose: dependencies say *"B needs A's
output"*; lanes say *"only one of these at a time."* As of the gems-first
release work, `dependencies` is no longer spec-only: `Release#ordered_members`
honors it (a stable topological sort that falls back to `position`), so the
conductor sequences members producer-first **and** respects explicit
task-to-task edges. See "Gem members & producer-first ordering" below.

**Membership records at the sweep; the stage flips on QA-green.** Feature PRs
already target `release`, so there is no branch-cut and no PR-base retarget.
Avi's **`bin/release prepare`** (the self-healing qa-release) DETECTS the
work — every `reviewed` task plus any `assembled` straggler not riding the
current RC — ensures a candidate exists (`Release.current_or_open!`), and SWEEPS
each detected task: `gh pr merge` its PR into its repo's `release` (SKIPPED for
a task already `merged: release/main` — the crash-recovery signal an interrupted
run leaves behind), then `Release::Conductor.sweep!` records membership +
`merged: "release"` in **one `heroku run`** for the whole batch. **Stages do NOT
move at the sweep.** The per-task primitive is still **`bin/release merge <task>
[<task> …]`** (batched; with ≥2 slugs it prints an **overlap planner** —
colliding files + suggested order + likely rebases, warning-only). A merge
conflict surfaces **at this PR-merge step** (resolve on GitHub, or block the
task for rework — prepare sweeps past it and keeps the rest) — `release` never
force-pushes. Next comes Avi's **pre-QA gate** — the registry `qa_test_cmd`
tier (integration + e2e-smoke) on `origin/release` BEFORE anything deploys; a
regression **ejects the offender** (`bin/release eject <task>` → blocked +
detached + merged cleared, pair with the merge-commit revert) and the REST of
the RC rides the re-run. Gate green → `prepare` deploys `origin/release` to
**QA** + records the QA URL, waits for boot, smokes `/up`, and on **QA-green**
flips the swept members `reviewed → assembled` (`Release::Conductor.qa_green!`;
`merged` stays `"release"`) → the release is **`assembled`** (the QA candidate).
A QA failure flips NOTHING — members stay `reviewed` and the next self-healing
run picks them back up, skipping the already-done merges. A late PR sweeping in
after the flip **reopens** the RC (`Release#reopen!`) so it re-QAs before
shipping. At ship, **Steffon** first runs the **full e2e + highest-tier suite on the
frozen ship SHA** (the exact prod code — closing the merge-forward "shipped ≠
tested" gap); on green the ending depends on the trigger. A QA-only run
(`pr-review` → `qa-release`) stops for the operator, while `full-cycle`
continues with the already-authorized ship. The ship action (surfaced as the current release on
`/deployments`, not a passive status): `bin/release ship` fast-forwards each
repo's `main` up to `release` (so `release` collapses into `main`), stamps that
repo's members `merged: "main"` as each ff lands, deploys prod, and flips
members to `shipped`. Ship authority always lands **after Steffon's test
confirmation, before the deploy**.

Release progress is also recorded as explicit `ReleaseEvent` checkpoints
(`review_tests`, `assemble_release`, `deploy_qa`, `qa_smoke`, `ship_gate`,
`ship_authorized`, `deploy_prod`, `prod_smoke`, `release_notes`,
`archive_tasks`). The `/deployments` tracker reads those events before falling
back to legacy `Release` fields, so `ship_gate:completed` can visibly finish the
Confirming step before `deploy_prod:started` begins production work. Steps that
take measurable work should be bookended with `started` and `completed`; older
completed-only checkpoints render as instant duration rows so their recorded
timestamp is still visible in release analytics.

Release analytics are cached on the `Release` record. `Release::DurationCache`
stores `duration_metrics` (versioned JSON), `duration_metrics_cached_at`, and
`duration_cache_version`; the `/deployments` dashboard shows last-three-release
averages, `/deployments/all` lists release timestamp rows, and
`/deployments/:slug` shows the per-release read view. Task/release event writes
refresh the owning release best-effort, and production follow-up tasks should use
the idempotent post-deploy hook `bin/rails releases:refresh_duration_metrics` to
backfill the last three shipped releases after a deploy.

**Gem members & producer-first ordering.** A release is not apps-only — it can
carry **gem** tasks (`studio-engine`, `solana-studio`) as first-class members
alongside apps. The classification lives in `config/release_repos.yml` (read by
`Release::Repos`): every member is a `:gem` (producer) or an `:app` (consumer).
Gems and apps are handled differently at both ends of the Deploy workflow:

- **Gem members are PUBLISHED, not app-deployed — and published at *prepare*,
  BEFORE QA** (publish-gems-before-qa). A gem's PR merges into the gem's own
  repo's `release` branch like any other, but there is no app artifact to
  deploy. `bin/release prepare` runs the producer-first sequence up front,
  before the pre-QA gate and any QA deploy — in **two phases**, because a
  RubyGems push can never be re-pushed: phase 1 validates EVERY swept gem
  (fail-closed fetch, version parses, stranded-work guard, a swept consumer
  declares it) and aborts on ANY failure with zero gems published; phase 2
  then publishes each validated gem's `origin/release` version to RubyGems
  (skip-if-live) and commits each
  consumer's `Gemfile.lock` bump onto the consumer's `release` branch — so the
  pre-QA CI verdict targets the post-bump SHA, QA bundles the **real published
  gem**, and prod ships the exact tree QA tested. The gem member itself still
  rides the release as a *record* (no QA deploy of its own); it is QA'd through
  the consuming app's bumped lock. **The accepted cost:** a publish is
  irreversible (RubyGems forbids re-pushing a number), so a QA bounce can
  orphan a published version — the fix bumps past it and the dead number sits
  on RubyGems, harmless.
- **The stranded-work guard — an ORDERING invariant.** For each swept gem repo,
  if `origin/release` is ahead of the last published `v*` tag while the version
  did **not advance past that tag**, prepare **BLOCKS loudly**, naming the
  stranded commits and the fix (the conductor commits the advanced version onto
  the gem repo's `accepted`, then re-runs prepare — *not* through a feature PR,
  which `dor-check` refuses). The comparison is `Gem::Version` semantics, not
  string equality, so **three** vectors block together: an EQUAL version (the
  publish silently self-skips "already live" and the commits ride nowhere — the
  failure mode that once stranded 9 engine commits behind an all-green
  pipeline), a BACKWARD version (worse: it skips as already-live AND rewrites
  the consumer pin DOWNWARD, shipping a production downgrade with every gate
  green), and an UNPARSEABLE version (it cannot prove it advanced, so it fails
  to the blocking side).
- **Consumer pins: lock always, constraint only on escape.** Consumers pin
  RubyGems versions (`gem "studio-engine", "~> 0.10"` — no git/branch refs).
  The prepare bump always runs `bundle lock --update <gem> --conservative`;
  it rewrites the Gemfile constraint **only when the published version escapes
  it** (a two-segment `~>` holds the major, so minor/patch bumps are
  lock-only). Pure decisions: `Release::ShipSequence.consumer_bump_action` /
  `.stranded_gem_work?`, `Release::GemfileRepin.version_requirements` /
  `.constraint_allows?` / `.rewrite_pin`.
- **Run Deployment stays producer-before-consumer — as the idempotent VERIFY.**
  `Release#ordered_members` returns members **gems-first** (then apps),
  honoring `dependencies` within that. `bin/release ship` still walks every gem
  member before any app deploy: on the happy path each version is already live
  from prepare (skip + `release → main` collapse), and it remains the real
  publish backstop for a release prepared before this change. If a gem fails to
  publish, the ship aborts before any app deploys.
- **The version belongs to the RELEASE, never to a PR.** N pull requests riding
  one candidate publish exactly **one** version, so no individual PR can know the
  right answer when it is written. `bin/dor-check` therefore **refuses** any diff
  touching a registered `version_file` (`lib/studio/version.rb` for
  studio-engine, `lib/solana_studio/version.rb` for solana-studio) at the merge
  gate; the `build`
  gate is exempt, and `CHANGELOG.md` is deliberately **not** refused. The bump is
  derived from the candidate's membership — `breaking` risk tag → major, else a
  `feature` member → minor, else patch — by `Release::GemVersion`
  (`app/models/release/gem_version.rb`), pure and unit-tested. **`bin/release
  prepare` allocates it at step 4d**: it derives the number from the membership,
  writes the `version_file` **with its `Gemfile.lock`** in one commit onto
  `origin/release`, and does that BEFORE the publish. The conductor sets no
  version by hand on the happy path (finding-d0621629719b, now closed);
  `member_plan` then *reads* it for the publish + the board's `💎 gem` badge.
  Allocation refuses rather than guesses — an unreadable `--gem-bump`, an
  unparseable last version, or a lockfile that did not move aborts the sweep with
  nothing published — and the stranded-work guard stays armed behind it as the
  backstop for the times allocation is skipped or wrong. Per-task override:
  `bin/task update <task-slug> --gem-bump major`. See
  `docs/agents/modules/deployment.md` → "Releasing a gem (producer-first)" for
  the operator runbook.

This is the ordered `release_conductor` lane from §4.2 ("gem publish → consumer lockfile
bump → app deploy"), now expressed as first-class release membership rather than
a separate lane: the gem and its consumers can be members of the same release,
sequenced by kind + `dependencies`.

**Abandon (revert, never force-push).** `release` is permanent and shared, so a
stuck RC is **not** thrown away by deleting a branch — it is unwound by reverting.
`Release#abandon!` drops board membership (members fall back to `reviewed`,
release → `abandoned`, the singleton frees up). The git-side remediation is owned
by the conductor/CLI as a documented step:

1. For each member whose merge you want out, **revert its merge commit on
   `release`** (`git revert -m 1 <merge-sha>`, push) — never a force-push, since
   `release` is the shared persistent branch.
2. The member's task drops to `reviewed`; the e2e culprit goes to `blocked`.
3. Re-merge the surviving/fixed members into `release` (a new candidate
   accumulates) and re-`prepare`. `main` never moved.

### 1.2 Stage ownership — who progresses each stage

Distinguish the **accountable role** (the soul whose rubric governs the stage)
from the **executor** (who moves it). The heartbeat agent executes by wearing
each lane's hat; accountability maps to a soul; there is exactly **one operator
gate** — the ship.

**Redesigned `submitted → shipped` (decided, 2026-06-22; review lane re-homed
2026-06-26; assembly moved to Steffon 2026-07-03; review re-homed to Carl and
release lanes flipped 2026-07-22).** The Deploy half is re-homed by role —
**Carl owns review; Avi assembles + QAs (`accepted → release` sweep + QA);
Steffon ships**. Review runs as **one Carl per PR, not a supervisor hierarchy**:
the review session (a Pokémon orchestrator) claims a PR and spins one **Carl**,
the standing primary AND owner — **there is no Avi supervisor**. Carl does the
deep technical review, owns the gates, **summons a domain LIGHT specialist at his
discretion** (a focused second read), drives the verdict, and on a merge-ready
verdict **merges the feat PR into `accepted`** (stamping `merged: "accepted"`)
and the task stops at `reviewed` — review never touches `release`/`main` and
never deploys. **The `accepted → release` promotion and `assembled`** are owned
by **Avi** (Product Owner) via the self-healing `qa-release` sweep; and
**`shipped`** is owned by **Steffon** (Platform Engineer, who runs the full e2e
on the frozen ship SHA) ahead of explicit ship authority. The senior reviewer
pool is **{Shannon = UI · Carl = backend · Jasper = Web3 · Steffon =
DevOps/Platform · Alex = Documentation}** (Carl is the standing primary on every
PR; Alex is both the orchestrator and the pool's launchable Documentation review
seat — one identity). Carl previews the domain light with **`bin/reviewer-select
<task>`** (wraps `ReviewerSelector`).

**Merge timing (accepted ladder — LIVE):** on a merge-ready verdict (Carl's deep
review + the light's second read) with no blocker **Carl merges the feat PR into
the persistent `accepted` branch** (stamping `merged: "accepted"`) and drives the
task to `reviewed`, then stops — review still never touches `release`/`main` and
never deploys. **Avi's self-healing `qa-release` sweep** (`bin/release prepare`)
then promotes **ONE `accepted → release` batch PR per repo** — not N per-task
`feat → release` merges — re-stamping `merged: "release"` on its members but
moving NO stage; the `reviewed → assembled` flip lands only on **QA-green**.
`accepted` is the integration line and `release` the live RC; `main` only moves
when it ships. **Bias to action: green tests = go**, because both `accepted` and
`release` are recoverable by revert, so we don't fear merging there.

| Stage (entity) | Accountable | Progressed by | Action | Gate |
|---|---|---|---|---|
| **→ submitted** (task, entry) | Feature agent | Feature agent | certify — `bin/fast-check` (~1 min; credited once the PR's GitHub CI is green) or `bin/full-suite-check` (CI-independent) → pass `bin/dor-check`, record `checks_run`, open PR (base `accepted`), move in | self-gate — **G1 Cert** (the cert self-opens+closes its `g1_cert` attempt) → **DoR** (the `bin/dor-check` verdict opens+closes the `dor` gate) |
| **submitted** (task) — REVIEW | **Carl** (standing primary + owner) + a domain LIGHT | Session Pokémon spins **one Carl per PR** → Carl summons **one LIGHT** at his discretion | The review session claims a green-CI PR (`bin/task claim-next-review`) and spins **one Carl** — the standing primary AND owner; **there is no Avi supervisor**. Carl does the deep review, owns the gates, and **summons one domain LIGHT** for a focused second read — the domain pick from {Shannon=UI · Jasper=Web3 · Steffon=DevOps/Platform · Alex=Documentation}, previewed by **`bin/reviewer-select <task>`** (`ReviewerSelector`, excluding the QA owner so a reviewer never QAs their own change, **the task's builder** so a soul never reviews their own work, **and busy souls** — the builder is read from `devops.built_by`, **auto-stamped on the move to building from the soul build-claim actor (`--actor <soul>`) OR the task's assigned `agent_slug`**; **busy souls** come from `--busy a,b,c` and/or `--busy-auto`; **KEEP fallback:** when the exclusions would leave too few, the least-bad are kept; the primary Carl + domain light is recorded on the `submitted→reviewed` `TaskEvent.metadata["reviewers"]` for the avatars UI). Carl and the light confirm DoR **base** tests green, code standards, code smell, scalability, **and acceptance**. No blocker → **Carl merges the feat PR into `accepted`** (stamping `merged: "accepted"`) and drives the task to `reviewed` ✅, then STOPS — review never touches `release`/`main` and never deploys; the `accepted → release` promotion (next row) is Avi's; a blocker → `blocked` (rework, with `qa_feedback`) | **G2 Review** (lanes `g2a_primary` + `g2b_light`; Carl's gate-zero = `bin/dor-check <task> --gate-role review`, recorded on the separate `dor_review` gate) — merge-ready primary + light reads (Carl = Opus on migration/payment/solana/auth); ⛔ one complete `qa_feedback` on fail |
| **reviewed** ✅ — SWEEP (task) | **Avi** (Product Owner) | DevOps agent *as Avi* (`qa-release`) | `bin/release prepare` DETECTS every `reviewed` task + any `assembled` straggler off the current RC, ensures a candidate (`Release.current_or_open!`), and PROMOTES **ONE `accepted → release` batch PR per repo** — not N per-task `feat → release` merges (review already landed each feat PR on `accepted`); the promote is SKIPPED for a repo already level, or for a task already stamped `merged: release/main` (interrupted-run recovery). Then record membership + `merged: "release"` (`Release::Conductor.sweep!`) — **stage stays `reviewed`**. Honors `dependencies` + producer-first. Nothing detected + nothing active → idempotent no-op. **Bias to action: green tests = go** (`release` reverts cleanly) | deterministic sweep (conflicts surface at PR-merge; a conflicted PR is swept PAST — block-and-move); review gate: only `reviewed`/`assembled` tasks sweep (`--override` = audited `review_bypassed`) |
| **assembled** (release) — QA | **Avi** (Product Owner) | DevOps agent *as Avi* (`qa-release`, same run) | After the sweep, the **stale-tree gate** (`Release::StaleTreeCheck`) re-reads `origin/release..origin/accepted` for every three-rung repo in the deploy plan and REFUSES unless `release` already carries `accepted` — asserting the promote's EFFECT, because the promote picks its repos from board stamps and so cannot see a commit with no task behind it (that gap once printed `✓ Assembled` over a tree missing the fix). Then the **pre-QA gate** runs the **next tier — integration + an e2e smoke** (registry `qa_test_cmd`) on `origin/release` BEFORE deploying; green → `prepare` deploys it to QA → **Discord QA-deployment note** → on **QA-green** `Release::Conductor.qa_green!` flips swept members `reviewed → assembled` (merged stays `release`) + release `assembled` | **G3 Candidate** (release-grain; spans pre-QA suite → QA boot smokes → post-deploy hooks; closes with the QA-green flip) — deterministic suite; ⛔ regression → **eject the offender** (`bin/release eject <task>` = detach + block + merged cleared; revert its merge commit) — the REST rides the re-run. **`prepare` waits-for-boot** (`/up`-smoke race) and **defers the flip** until QA returns 200 — a failure leaves members `reviewed` for the next self-healing run |
| **→ shipped** (release) | **Steffon**, then ship authority | Steffon tests; operator or autonomous kickoff authorizes; conductor deploys | Steffon runs the **full local suite (registry `test_cmd`) on the FROZEN ship SHA** (the exact prod code — fixes "shipped ≠ tested"; self-gated when G3 certified that exact SHA + command this run). A QA-only run (`pr-review` → Avi's `qa-release`) stops here for the operator; Steffon's **`production-deploy`** act ships a QA-green release, and Alex's **`full-cycle`** continues with `bin/conductor ship --run`. On ship authority: `bin/release ship` ff's `release → main` per repo (stamping members **`merged: "main"`** as each ff lands — the interrupted-ship skip signal), deploys → `production_smoke` → **Discord release notes** → members `shipped` (merged stays `main`) | **G4 Ship** (release-grain; spans the frozen-SHA gate → prod deploys → `/up` smokes → hooks → the non-blocking smoke seal, which retries once after 30s through the dyno boot window before recording red) — 🔒 explicit ship authority — after Steffon's test confirmation, before deploy; rollback on smoke fail |

Clarifications:

- **Product-acceptance is a core check at BOTH ends.** The two senior reviewers
  confirm the task's acceptance criteria at the review step, and **Avi confirms
  acceptance again at ship** (on the frozen SHA). It is checked twice by design —
  once before merge, once before prod — not a one-time gate.
- **Test-tier → step map (efficiency — no redundant re-runs):** **base**
  (unit/component) @ **review** (the two seniors — the **G2 Review** gate) ·
  **integration + e2e-smoke** @ **QA** (Avi — the **G3 Candidate** gate;
  the hub registers its FULL suite as `qa_test_cmd`, the batch certification) ·
  **full-suite** @ **ship** (Steffon, on the frozen ship SHA — the **G4 Ship**
  gate; the honest relabel from "full e2e": the registry `test_cmd` is the
  repo's highest LOCAL tier, never a browser run). Each tier runs once, at the
  step that owns it — no step re-runs a lower tier the previous step already
  proved green, and G4 **self-gates** (skips, with a visible skip SOP) when G3
  certified the exact frozen SHA with the same command this run **and its CI
  auditor did not go red** — a G3 green that GitHub CI CONTRADICTS for that same
  SHA fails open and re-runs the suite, like a missing/red/drifted record
  (`Release::ShipSequence.ship_gate_skip?`; fail-open only — an auditor can cause
  more checking, never block a ship, and no-data never arms it). Encoded as
  `Release::STEP_TEST_TIERS` (ownership is disjoint by construction — a tier maps
  to exactly one step); ship runs Steffon's frozen-SHA gate **before**
  ship authorization (`bin/release ship` → `ship_gate`, then `confirm`, unless
  the authorized autonomous workflow passes `--yes`). Each gate's verdicts are
  recorded as attempt-aware `GateRun` rows — the standalone gate docs live in
  `docs/agents/modules/gates/` (`g1-cert.md` … `g4-ship.md`).
- **`assembled` now means ONE thing at both scopes: QA-green.** A *task* flips
  `assembled` only when the QA deploy it rides smokes green
  (`Release::Conductor.qa_green!`) — being merged into `release` alone leaves it
  `reviewed` + `merged: "release"`. The *release* assembles in the same flip.
  Production authority is at **ship** (after Steffon's full-suite run on the frozen
  SHA), **not here** — at this scope `assembled` is a state the conductor flips,
  not a human approval.
- **Review is Carl-owned — one Carl per PR, not an Avi supervisor gate.** The
  review session (a Pokémon orchestrator) spins **one Carl** per PR — the
  standing primary AND owner. Carl does the deep review, owns the gates, and
  **summons one domain LIGHT** at his discretion for a focused second read. On a
  merge-ready verdict Carl merges the feat PR into `accepted` (stamping `merged:
  "accepted"`), drives `reviewed`, and stops — review never touches
  `release`/`main` and never deploys; the `accepted → release` promotion belongs
  to Avi's sweep. There is no Avi supervisor.
  The selection tiebreak is **seeded per task** (reproducible, not
  process-random) and **logged** (auditable), so reviews spread across the pool
  instead of always landing on the obvious domain owner. Because the seed is
  derived from the task identity (+ its exclusions), **`bin/reviewer-select`'s
  preview matches the pair recorded on the `submitted→reviewed` `TaskEvent`** —
  the CLI and the in-app recorder roll identically and never disagree. (That
  match holds for the **default QA owner**; passing a custom `--qa-owner` changes
  the candidate pool + seed, so the preview is then advisory.)
- **No self-gating:** `bin/reviewer-select` **excludes the QA owner** (the soul
  who QAs the assembled RC) from the light pool, so one soul never both reviews
  and QAs the same change. (That soul remains a valid reviewer for **other**
  PRs.)
- **Alex is the Documentation reviewer.** The `alex` seat is the orchestrator who
  **also** holds the **Documentation** domain review seat — one identity (seeded in
  `db/seeds/02_agents.rb`, a launchable review agent). `ReviewerSelector` /
  `bin/reviewer-select` pick `alex` for docs-shaped PRs (the QA-owner and
  builder exclusions still apply, so Alex never reviews a change he built).
- **There is no per-task QA stage.** Avi owns the QA deploy, the QA tier
  (integration + e2e-smoke), and Steffon owns the prod mechanics — but there is no separate
  approval ceremony; the suite is a green/red *signal* and the operator OK at
  ship is the gate. QA + production are properties of the **release**, not the
  task.
- **Review merges even funds-touching work into `accepted` autonomously** once
  it carries the two approvals (primary + light), and the sweep then promotes it
  to `release` — the consequence of "Review + QA, gate prod". Risk raises
  *scrutiny* (the PRIMARY review goes to Opus + full integration/security suite),
  not a second human.
  `config/release_builder.yml` gates only QA assembly autonomy; adding a separate
  human pre-sweep gate for `payment`/`solana` would require a code/config
  change, not a doc-only knob.
- **Humility valve:** low confidence → a reviewer marks `conductor-review` and
  routes to a *human* Carl/Avi/Steffon session instead of approving the task into
  the sweep queue.

### 1.3 Decided — and where to tune the release builder

Resolved: `release_train` → **`release_slug`** (one field/model); **feature PRs
merge into a persistent per-repo `release` branch, membership recording at
Avi's sweep with the `assembled` flip on QA-green (2026-07-03)**;
no per-task QA stage; Release is its own singleton model — states `assembling →
assembled → shipped`, where explicit ship authority **Makes the release** from
the assembled RC. **Decided 2026-06-22 (§1.2); re-homed 2026-07-22:** review is
**owned by Carl** (one Carl per PR — the standing primary + owner, no Avi
supervisor); the `accepted → release` sweep + `assembled` are owned by **Avi**
(Product Owner); and at `shipped` **Steffon** (titled **Platform Engineer**) runs
the full e2e + highest tier on the **frozen ship SHA** *before* ship authority is
exercised — so the deploy gate sits **after test confirmation, before the
deploy**.

**RC assembly autonomy is the one evolving policy** — so it lives in one
tunable config file, `config/release_builder.yml`, read by
`Release::BuilderPolicy`. Current policy:

- **Auto-assemble + auto-deploy-to-QA** only when the reviewed queue is one
  task, one repo, with no `migration`/`payment`/`solana` risk tag.
- **Propose for operator confirmation** for an empty queue, multi-task release,
  cross-repo release, or blocked-risk release. The conductor can draft the plan,
  but waits before changing release state.
- Production ship remains **operator-gated by default**
  (`production_ship.operator_gated` is `true`) for a QA-only run (`pr-review` →
  Avi's `qa-release`). Alex's **`full-cycle`** launcher is the explicit
  autonomous production authorization; it uses the same frozen-SHA/test/smoke
  gates, then passes `--yes` to the production ship command.

Change thresholds in `config/release_builder.yml`, then run
`bin/rails test test/models/release/builder_policy_test.rb`. This policy only
decides QA assembly autonomy plus names the autonomous production kickoff;
ordinary `bin/release ship` remains separately gated unless that kickoff or
another explicit production rollout prompt grants ship authority.

### 1.4 Kickoff commands — board → agent session

The `/deployments` board and `/stages` page surface a short copy-paste command
per DevOps stage (source of truth: `ApplicationHelper#devops_kickoffs`). Pasted
into an agent session run from `/Users/alex/projects`, each kicks off that
stage's workflow. The feature-agent lane (`designed → building → blocked →
submitted`) has none — the operator drives those hands-on. The DevOps lane maps
each command to a deterministic runbook. The release-wide launchers are the
**soul heartbeat acts** on the /deployments **Workflows card**
(`ApplicationHelper#heartbeat_launchers`; every row is a recognized launcher —
see "The five soul heartbeat launchers" below):

- **`pr-review`** / **`pr-review-slow`** (`Carl Heartbeat` acts) — review ALL
  `submitted` PRs, in waves of ≤5 or serialized one PR at a time. On a
  merge-ready verdict review **merges the feat PR into `accepted`** (stamping
  `merged: "accepted"`) and stops at `reviewed` — it never touches
  `release`/`main` and never deploys; the `accepted → release` promotion is
  Avi's sweep.
- **`qa-release`** (`Avi Heartbeat` act) — the **self-healing sweep**: merge
  reviewed tasks + `assembled` stragglers onto `release`, deploy QA, and flip
  members `assembled` only on QA-green.
- **`production-deploy`** (`Steffon Heartbeat` act; ship authority) — ship a
  QA-green release: fast-forward `release → main` and deploy prod; idempotent
  no-op when nothing is ready.
- **`full-cycle`** (`Alex Heartbeat` act; full ship authority) — the whole
  release, review → assemble → QA → prod ship.
- **`deploy-with-task`** (`Avi Heartbeat` act; ship authority for ONE task) —
  expedite ONE task to prod. Guarded on a clean LADDER — `accepted == release ==
  main`, both rungs, because the sweep promotes all of `accepted` and the ff
  ships all of `release`; on a dirty ladder it refuses and points at the full
  release pipeline (`full-cycle`) instead. Launched bare it asks "What task?".

#### The composable launcher set — atoms + compositions

The launchers above are not monoliths — they are **a small set of atoms plus
compositions of them**, so the same building blocks recombine instead of each
flow carrying its own copy of the runbook. Learn the atoms once; every launcher
is a sequence of them.

**Atoms** (the indivisible steps — each maps onto an existing `bin/release` verb
or the `review-one` SOP; none is a new command to build):

| Atom | Is | Command / SOP |
|---|---|---|
| **`review-one <task>`** | the PRIMITIVE — the Modular PR-Review SOP on ONE PR (one Carl per PR — the standing primary + owner; Carl summons a domain LIGHT at his discretion → merge-ready = Carl merges the feat PR into `accepted` + drives `reviewed`, then STOPS (never touches `release`/`main`, never deploys); else block) | [`pr-review-sop.md`](../modules/pr-review-sop.md) |
| **`pr-review`** | `review-one` fanned across **all** `submitted` PRs, in **waves of ≤5** (review merges to `accepted`; Avi's sweep promotes `accepted → release`) | [`agents/carl/sops/pr-review.md`](../agents/carl/sops/pr-review.md) |
| **`pr-review-slow`** | the same, **serialized** — one PR at a time | [`agents/carl/sops/pr-review-slow.md`](../agents/carl/sops/pr-review-slow.md) |
| **`qa-release`** | the SELF-HEALING sweep: detect `reviewed` + stragglers → merge PRs into `release` (skip `merged:` ones) → pre-QA gate → deploy QA → members `assembled` on QA-green | [`agents/avi/sops/qa-release.md`](../agents/avi/sops/qa-release.md) / `bin/release prepare --yes` |
| **`archive-shipped`** | archive shipped work and reclaim completed worktrees from prior cycles — **run by `production-deploy` as its final step**, so it is not a card chip; still invocable by name | [`agents/steffon/sops/archive-shipped.md`](../agents/steffon/sops/archive-shipped.md) / `bin/release archive --yes` |
| **`clean-infra`** | reclaim this machine's local infra: finished desks, the Redis band, regenerable disk, orphaned per-desk DBs. Off-sequence — the catch-all when an agent reports there is no space | [`agents/steffon/sops/clean-infra.md`](../agents/steffon/sops/clean-infra.md) |
| **`live-score-watch`** | watch a live NFL slot: poll ESPN on a cadence, record scoring plays, propagate contest scores. Holds no release lane | [`agents/turf_monster/sops/live-score-watch.md`](../agents/turf_monster/sops/live-score-watch.md) |
| **`contest-rehearsal`** | run one contest lifecycle end to end on QA devnet: create, enter, replay a played week, settle on-chain, close. Holds no release lane and refuses any target but QA | [`agents/turf_monster/sops/contest-rehearsal.md`](../agents/turf_monster/sops/contest-rehearsal.md) |
| **`production-deploy`** | ff each repo `release → main` (members stamp `merged: "main"`), deploy prod, smoke, release notes (members → `shipped`), post-ship agent-docs sync — **ship-authority gated** | [`agents/steffon/sops/production-deploy.md`](../agents/steffon/sops/production-deploy.md) / `bin/release ship` |

**Compositions** (the operator-facing launcher phrases = a sequence of atoms):

| Composition | Expands to |
|---|---|
| **`full-cycle`** (Alex Heartbeat act; full ship authority) | [`agents/alex/sops/full-cycle.md`](../agents/alex/sops/full-cycle.md): `pr-review` → `qa-release` → `production-deploy` — the whole release, review to prod. *Formerly the retired `Merge, Assemble, Deploy` chip;* named `full-cycle` to avoid colliding with the read-only `bin/devops-cycle` snapshot tool. |
| **`deploy-with-task`** (Avi act; ship authority for ONE task) | [`agents/avi/sops/deploy-with-task.md`](../agents/avi/sops/deploy-with-task.md): **GUARD `release == main`** → `review-one <task>` (merge to `accepted` → `reviewed`) → `qa-release` (promotes `accepted → release`) → `production-deploy`. Interactive — launched bare it asks "What task?". *Formerly the `Deploy with Task <task>` write-up here.* |

> **Retired chips (2026-07-02).** The four legacy release-card chips — `Avi Heartbeat
> Slow`, `Avi Heartbeat Fast`, `Build and Deploy QA Release`, `Merge, Assemble,
> Deploy` — were removed from the UI and relocated into the soul heartbeat acts:
> serialized review is now Carl's **`pr-review-slow`** act, QA-only is `pr-review` →
> Avi's **`qa-release`**, and the full autonomous run is Alex's **`full-cycle`**
> act. (2026-07-03: the acts went back to **review-only** — the accepted→release
> merge lives in Avi's self-healing `qa-release` sweep.) The `bin/pr-review` review-only
> loop still exists but is no longer a card chip.

The only NEW code this set required is the clean-ladder **GUARD** that
`deploy-with-task` runs first (`bin/release status --clean-only --task <task>`,
backed by the unit-tested `Release::CleanCheck`) and re-runs at the promote
(`bin/release prepare --expedite`); everything else is the atoms recombined. The
guard covers BOTH rungs the expedite walks — work parked on `accepted` (which
the sweep promotes) as well as work riding `release` (which the ff ships) — and
reads a board signal and a git signal on each, refusing when they disagree.

#### The five soul heartbeat launchers — the Workflows card

The standalone **Workflows card** (`tasks/_heartbeats_card` on `/deployments`,
sized to match the Next Release card) renders the five soul heartbeat launchers
(`ApplicationHelper#heartbeat_launchers`, one `tasks/_heartbeat_launcher` per soul)
in a 5-up grid. Each launcher is a soul face (**linking to `/agents/<slug>`**) over
a **prompt-like row 1** (`Carl Heartbeat` / `Avi Heartbeat` / `Steffon Heartbeat` /
`Alex Heartbeat` / `Turf Monster Heartbeat`) plus one or more **copyable action
rows**, each with a leading icon (❤️ on the heartbeat row; `1️⃣`–`3️⃣` on the three
ordered release actions, a themed glyph on the rest). **Any row**, pasted into a
fresh session, is a **recognized launcher**. The 5-stage release tracker stays in
the **Next Release** card. Cross-soul launcher map:
[`heartbeats.md`](../modules/heartbeats.md). Per-soul heartbeat launchers live
with the souls:
[`Carl`](../agents/carl/HEARTBEAT.md),
[`Avi`](../agents/avi/HEARTBEAT.md),
[`Steffon`](../agents/steffon/HEARTBEAT.md),
[`Alex`](../agents/alex/HEARTBEAT.md), and
[`Turf Monster`](../agents/turf_monster/HEARTBEAT.md).

It is titled **Workflows**, not Heartbeats, because every row is a flow the
operator launches — not a liveness signal. The per-soul entry command is still
`bin/agent-activity heartbeat <soul>`, and the files are still `HEARTBEAT.md`;
only the card's name changed.

> **Sticky attribution.** The FIRST action of a `<Soul> Heartbeat` is
> `bin/agent-activity heartbeat <soul>` — it sets a session-sticky acting-agent so
> every activity self-attributes to that soul (stacked over the base mascot) without
> re-passing `--agent`; an explicit `--agent` still wins, and it clears at session
> end (`close-open`) or `heartbeat --clear`.

| Soul (row 1) | Acts | Does | Exit seam |
|---|---|---|---|
| **Carl** (`Carl Heartbeat`) | `pr-review` · `pr-review-slow` | review submitted PRs — one Carl per PR, **merging each to `accepted`, never touching `release`/`main`** (waves ≤5, or serialized via `pr-review-slow`) | each PR `reviewed`/`blocked` |
| **Avi** (`Avi Heartbeat`) | `qa-release` · `deploy-with-task` (direct-invoke only) | the **self-healing sweep** — merge the reviewed queue onto `release`, pre-QA gate, deploy QA, flip members `assembled` on QA-green (`bin/release prepare --yes`, stages 1–3) | RC **deployed to QA**, members `assembled` |
| **Steffon** (`Steffon Heartbeat`) | `production-deploy` · `archive-shipped` | **downstream-first:** ship a QA-green release (`bin/release ship --yes`, stages 4–5, stamping `merged: "main"` at each ff) if one is ready; then archive shipped tasks (`bin/release archive --yes`) from the prior cycle | the ready release `shipped` (or no-op); then prior cycle `archived` |
| **Alex** (`Alex Heartbeat`) | `grade-events` · `share-insights` · `full-cycle` | grade the 10 most recent resolved activities at `/alex/heartbeat`; share the `mcr`-confirmed insights out (regenerate the lessons doc + distribute); OR run the whole cycle review→assemble→QA→prod ship (`full-cycle`, full ship authority) | 10 graded + insights banked; confirmed insights shared out; or the whole release `shipped` |

**The release handoff seam.** The release stages (`Release::STAGES`, rendered on
/deployments as the per-repo lanes tracker, `ApplicationHelper#release_repo_lanes`)
are five: 1 **Testing**, 2 **Assembling**, 3 **Deploying QA**, 4 **Confirming**, 5
**Deploying** (prod) — the lanes fold Testing into Assembling (it finishes before a
release exists), so they chart four. **Avi owns stages 1–3** (`qa-release` = `bin/release
prepare`) and stops at **Live on QA**; **Steffon owns stages 4–5** (`production-deploy`
= `bin/release ship`) and finishes at **Deployed**. The seam between them —
**"deployed to QA."** — is the **Avi → Steffon handoff**: Avi's `qa-release`
ends and reports there; Steffon's `production-deploy` starts only once it is true.

These are **operator-launched (copy-paste) today, schedule-ready tomorrow** — each
act is idempotent, with an explicit precondition + a named exit seam, so a
scheduler can fire it later without rework (see [`heartbeats.md`](../modules/heartbeats.md)).
Note `pr-review` **merges the reviewed feat PR into `accepted`** and stops at
`reviewed` (it never touches `release`/`main`, never deploys) — Avi's
`qa-release` sweep then promotes `accepted → release` and flips members
`assembled` on QA-green.

**Per-act procedures live in the registered SOP files, not here.** Each act in
the atom and composition tables above links its owning
`docs/agents/agents/<agent>/sops/<sop>.md`, and every SOP is executable
standalone. This section keeps only the architecture: the atom/composition map
and the per-stage building blocks the deploy CLI implements. (The retired
composition write-ups that lived here — `Avi Heartbeat Slow`/`Fast`,
`Build and Deploy QA Release`, `Merge, Assemble, Deploy` — were absorbed into
`pr-review-slow`, `pr-review`, `qa-release`, `full-cycle`, and
`deploy-with-task`.)

> **A non-interactive agent MUST pass `--yes` only for approved confirms.** An
> agent's shell has no TTY — stdin is EOF, which a confirm prompt reads as
> **"no"**. The consequence differs per release verb:
> - **`prepare`** aborts without confirmation in a non-interactive shell. Always
>   run `bin/release prepare --yes` for the approved QA deploy step.
> - **`ship`** *aborts loudly* without confirmation — that is intentional. Do not
>   pass `--yes` unless the session launched a ship-authority SOP
>   (`production-deploy`, `full-cycle`, `deploy-with-task`) or Mr. McRitchie
>   explicitly gives the production ship go in this session.
> - **`status`** is a read-only report (no confirm); `--clean-only` makes it a
>   GATE that exits non-zero when the `accepted → release → main` ladder is
>   dirty on EITHER rung, and `--task <slug>` excuses the expedited task from its
>   own guard. It never deploys, so it needs no ship authority. `prepare
>   --expedite --task <slug>` re-runs the same verdict immediately before the
>   promote, which is the placement that survives the review window.
> - **`archive`** can use `--yes` after the shipped release is verified and the
>   operator has approved cleanup.
> - **`merge`** does not prompt today; `--yes` is harmless future-proofing.
>
> `--yes` bypasses the **human confirm only** — it never skips a test gate
> (`run_ship_gate` runs and can still abort the ship). `--prod` is already the
> default (the board is prod) — don't add it redundantly.

The per-stage commands below are the building blocks the compositions above
sequence:

**One-time setup (per machine/clone).** Run **`bin/release init`** once: it
creates the persistent `release` branch (= `origin/main`) on every gem + app repo
in `config/release_repos.yml` that doesn't already have one. Idempotent — a repo
that already has `origin/release` is skipped.

**`Review submitted PRs`**  *(submitted → reviewed — review merges the feat PR into `accepted`)*
Review is **one Carl per PR** (§1.2): the review session (a Pokémon orchestrator)
claims a green-CI PR and spins **one Carl** — the standing primary AND owner.
**There is no Avi supervisor.** Carl does the deep review, owns the gates,
**summons one domain LIGHT** at his discretion for a focused second read, drives
the verdict, and on all-clear merges the feat PR into `accepted` (the
`accepted → release` promotion is Avi's sweep). The formalized, agent-role
how-to — Carl summons the light, each reviewer narrates its review **as its
soul** (`--agent`) into the heartbeat's Agent column, any reviewer can block — is
the reusable **[PR Review SOP module](../modules/pr-review-sop.md)**; this section
is its release-context anchor. For each `submitted` task (`bin/task list` or the
board):

1. **Claim the PR + spin one Carl.** The session claims the highest-ranked
   reviewable green-CI PR (`bin/task claim-next-review`) and spins **one Carl**,
   the standing primary + owner. Carl confirms the open PR (base `accepted`) meets
   the task's acceptance criteria.
2. **Carl picks his domain LIGHT.** Carl runs **`bin/reviewer-select <task>`** — it
   loads the app and scores the pool `{shannon, jasper, steffon, alex}` by
   **domain fit** (the task's shape + repositories + risk tags vs each soul's
   `domains`) with a **logged, seeded-per-task tiebreak**, previews **Carl (primary)
   + 1 LIGHT**, and **excludes the QA owner** (whoever QAs the assembled RC — no
   self-gating), **the builder** (read from `devops.built_by`, auto-stamped on the
   build move from the assigned `agent_slug` — so a soul never reviews their own
   work with **no manual flag**), **and any busy souls** you name. `alex` is the
   orchestrator who also holds the launchable Documentation review seat — one
   identity. (`--qa-owner SLUG` excludes a different soul; `--builder SLUG`
   overrides the recorded built_by; **`--busy a,b,c`** and/or **`--busy-auto`** (a
   board query of agents on `stage=building` tasks) drop agents mid-build/review
   elsewhere — the pool is never starved below a pair, the least-bad are kept
   back; `--json` for a machine-readable pick; **`--record`** writes the picked
   pair onto the task as a **review intent** so /deployments + the task timeline
   show Carl + the light reviewing live — a green ticking timer — the moment
   review kicks off, before `→reviewed` lands.)
3. **Carl summons the LIGHT (his own child).** Carl does the deep pass (Opus on
   `migration`/`payment`/`solana`/`auth`) — **diff-vs-acceptance + code standards +
   code smell + scalability**, plus confirming the shape's **base** tiers are
   green — and summons **one** domain LIGHT as his own child for a focused second
   read (nested under Carl, not a supervisor's siblings). **Honor the
   ≤5-concurrent cap** (operating model): across all PRs in flight, keep at most 5
   review agents running at once (a Carl + his light count as two) — a wider queue
   reviews in **waves of ≤5**, never the whole batch at once.
4. **Resolve — Carl, the OWNER, owns the close.** Carl's deep read + the light's
   second read complete with **no blocker** → **Carl merges the feat PR into
   `accepted`** (stamping `merged: "accepted"`) and drives the task to `reviewed`
   (`bin/task move <task> reviewed --actor carl`), then STOPS — review never
   touches `release`/`main` and never deploys; Avi's `qa-release` sweep then
   promotes `accepted → release` and flips the member `assembled` on QA-green. Any
   reviewer blocks → **`bin/task block <task> --kind rework --feedback "…"`** (one
   complete send-back). That command runs the **two-bounce circuit breaker** first
   (`bin/task bounces <task>` reads it standalone: exit 0 CLEAR · 10 TRIPPED ·
   any other non-zero UNKNOWN, which is never to be read as zero) and **refuses**
   a second send-back, routing the deadlock to the operator as a `dependency`
   escalation instead; a mechanical bounce (red CI, merge conflict) proceeds on a
   recorded `--breaker-ack "<reason>"`. Bias to action: a clean merge-ready
   verdict = go (`release` reverts cleanly, and the sweep follows promptly).

**Agentic intent — the live "who's on it now".** Each event carries the agent
that STARTED it, not only the one that completed it, so /deployments and the
task's consolidated **Stage Timeline** show who's working *right now* with a
green ticking timer — the Deploy mirror of the build lane's live counter. These
are append-only `TaskEvent`s of `kind: intent` (completed transitions stay
`kind: transition`; named non-moving lifecycle completions such as heavy/light
review verdicts use `kind: checkpoint`; and an intent never enters the duration spine); an intent is
"open" only inside the source-stage cycle where it was recorded. A later
transition into its target stage supersedes it, and leaving the source stage
(for example `submitted → blocked`) closes it even if the target never landed.
If QA blocks a PR for rework and the feature agent rebuilds/resubmits it, Avi can
record a fresh `→reviewed` intent for the second review round. The build lane is
the special viewer case: `building` is both the stage-change conclusion and the
"agent started working" signal, so the task detail timeline marks the existing
`Designed → Building` card live instead of rendering a duplicate live
`Building` card. The `Created → Designed` genesis row stays deterministic and
usage-free; design accounting belongs on the `Designed → Building` transition
because `bin/task create` seeds the usage baseline only after the task slug
exists. The build-lane face is the task's
Pokémon mascot (assigned at create). The
review pair is recorded by **`bin/reviewer-select <task>`** (step 2 — recording
is the DEFAULT now; pass `--no-record`/`--dry` for an advisory-only preview);
Avi's QA and Steffon's ship intents are **auto-recorded by the deploy CLI** —
**`bin/release prepare`** fires the `assembled` intent (`actor: avi`) and
**`bin/release ship`** the `shipped` intent (`actor: steffon`), both via
`Release::Conductor.record_deploy_intents!` over every release member (the Deploy
mirror of `bin/reviewer-select`'s default review-intent write). So the conductor
no longer hand-runs them — the 2026-06-25 unfilled-ship-slot incident (a missed
manual `bin/task intent --to shipped --actor steffon` left the ship crew slot blank
mid-deploy). The manual **`bin/task intent <task> --to assembled --actor
avi`** / **`--to shipped --actor steffon`** (or `POST
/api/v1/tasks/<slug>/intent`) stays as the fallback / one-off path. All of them
are append-only + idempotent — an identical open intent in the current
source-stage cycle is reused, and the call is a no-op once the target stage has
landed in that cycle. Actor-less
conductor moves on `assembled`/`shipped` still attribute to their role owners
(Avi QAs `assembled`, Steffon ships) so the Deploy crew never goes blank.

**`Prepare release`**  *(reviewed → assembled — Avi's SELF-HEALING qa-release)*
ONE deterministic verb — **`bin/release prepare --yes [--task SLUG ...]
[--slug rel-…] [--prod]`** — owns the whole middle:

1. **Detect.** Every `reviewed` task + any `assembled` straggler not riding the
   current RC (`Release::Conductor.sweep_candidates`). Nothing detected and no
   active release → **idempotent no-op** (report + exit 0). `--task` narrows the
   sweep to the named slugs (operator curation).
2. **Ensure a candidate.** Use the in-flight release, else open one
   (`Release.current_or_open!`; `--slug` names a fresh one).
3. **Sweep + merge (BATCHED).** Per detected task: verify its PR base is
   `release`, `gh pr merge` it — **SKIPPED when `merged: release/main`** (an
   interrupted prior run already landed it; a failed gh merge also falls back to
   the PR's real state) — then record ALL memberships in **one `heroku run`**
   (`Release::Conductor.sweep!`: `release_slug` + `merged: "release"`, **stage
   stays `reviewed`**). The record write rides an `ensure`, so every PR that DID
   merge is recorded even if a later merge aborts. A merge **conflict** is
   block-and-move: that task is left `reviewed` (resolve on GitHub or block it)
   and the REST of the sweep proceeds; `release` is never force-pushed. Gem PRs
   merge into their own repo's `release` like any other. The **overlap planner**
   (warning only, ≥2 PRs) prints pairwise file collisions + a suggested order +
   likely rebases (`Release::MergePlan.compute`). The per-task primitive stays
   available as **`bin/release merge <slug> [<slug> …] --yes`** (same sweep
   semantics; `--override` = the audited `review_bypassed` bypass). The sweep
   records the reviewed→assembled intent, so assembly duration caches measure
   from the sweep to the QA-green flip.
4c. **Merge-forward guard** (`merge_forward_release_branches`). Every app **and
   gem** repo's `origin/release` must **CONTAIN** `origin/main` before the gate
   reads it — `main` moves outside the cycle (an emergency hotfix pushed
   straight to it), and a `release` that lags **cannot ship**:
   `push_frozen_main` pushes `main` without `--force` in apps and gems alike,
   so git refuses the non-fast-forward. The hotfix is never reverted — the
   cost is a candidate gated, QA'd, and assembled without a fix already live
   in production, and a ship that dead-ends at the last gate. The merge runs
   in a **detached ship workspace, never the primary**, every step is
   result-checked, and containment is **read back** after the push; a
   conflict, a failed push, or a push after which containment still does not
   hold all **abort** — and each landed push feeds the `@prepare_live`
   already-done ledger the abort path prints. It sits ABOVE the gate because a
   merge that lands moves `origin/release`, so running it later would move the
   branch past the SHA the gate just certified and QA would deploy a tree G3
   never verified; and ABOVE the gem publish (4d) because a publish is
   irreversible — a gem published from a pre-merge tree would lack a `main`
   hotfix forever (ship's publish skips an already-live version), while this
   order aborts a conflict with ZERO gems published. (It lived inside step 6
   until 2026-08-09, where a dirty primary made its `git checkout` refuse, its
   discarded result let a no-op on the wrong branch read as success, and the
   sweep assembled a candidate missing a live production hotfix.)
4d. **Publish gem members + bump consumer locks (producer-first, AFTER the
   merge-forward (4c) so every gem publishes the post-merge tree, and BEFORE
   the gate — validate ALL, then publish).** Phase 1 preflights EVERY swept
   **gem** member before the first irreversible push: fail-closed
   `origin/release` fetch (a stale ref must never drive a publish), the
   `version_file` parses, the **stranded-work guard** (`origin/release` ahead
   of the last `v*` tag with an unbumped `version_file` → BLOCK, naming the
   commits), build gated on tracked-dirty gem primaries exactly like ship's
   preflight, and a swept consuming app whose `origin/release` Gemfile
   declares the gem (a gem-only candidate would otherwise assemble QA-green
   untested). ANY failure aborts with ZERO gems published. Phase 2 publishes
   each validated gem's `origin/release` version to RubyGems (skip-if-live),
   then for each consumer app: `bundle lock --update <gem> --conservative` in
   the ship workspace at the release tip — rewriting the Gemfile pin only when
   the version escapes it — and **commit + push the bump onto
   `origin/release`**, fast-forward-checked behind its own fail-closed fetch.
   The lock commit lands BEFORE the gate resolves `origin/release`, so the CI
   verdict targets the post-bump SHA and QA tests the real published gem
   (`validate_gems_for_qa` / `publish_gems_for_qa` / `bump_consumer_locks_for_qa`).
5. **Pre-QA gate.** Each app's registry **`qa_test_cmd`** (the integration +
   e2e-smoke tier `prepare` owns — `Release::STEP_TEST_TIERS`) runs on
   `origin/release` BEFORE anything deploys. A regression → **eject the
   offender** (`bin/release eject <task> --feedback "…"` — detach + block +
   `merged` cleared — then revert its merge commit on `release`) and re-run: the
   sweep self-heals and the REST of the RC rides on. Unset `qa_test_cmd` = the
   repo self-gates (skip).
6. **Deploy QA.** Auto-records the Avi QA intent for every member
   (`Release::Conductor.record_deploy_intents!`, append-only + idempotent) so
   /deployments shows Avi QA-ing live; then `bin/qa-server
   deploy <qa_app> origin/release` per **app** member — **gem members are
   skipped** (no app artifact; already published at step 4d, QA'd via the
   consuming app's bumped lock). Records `release.qa_url` + per-repo QA SHAs,
   waits for boot
   (`wait_for_boot` polls `/up`), then runs each member's declared
   `devops.post_deploy_cmd` on its **QA heroku app** (`heroku run`, records the
   `[post-deploy]` outcome, **aborts on non-zero** — the
   `{task, tasks, app, cmd}` plan is the unit-tested
   `Release::PostDeploy.plan`). Members that declare the SAME work on the same
   app run **once**: the plan folds the interchangeable `rake`/`bin/rails`
   spellings of one command into a single dyno and stamps the `[post-deploy]`
   check on every folded member.
7. **QA-green flip.** Only after every QA dyno boots AND every post-deploy hook
   is green: `Release::Conductor.qa_green!` flips the swept members `reviewed →
   assembled` (`merged` stays `"release"`) and the RC assembling→assembled. **A
   QA failure flips NOTHING** — members stay `reviewed`, the RC stays
   `assembling`, and the next self-healing run picks everything back up
   (skipping the already-done merges).

   Record ops run on the **prod board by default** (the board IS production) via
   `heroku run`; `--local` opts into the stale local DB.

**`Run Deployment`**  *(assembled → shipped — promote the QA'd RC to prod)*
Run **`bin/release ship [--by NAME] --prod`**. Without `--yes` it confirms
before deploying; under the **`full-cycle`** launcher (or another
explicit production rollout prompt), use
`bin/release ship --by conductor --yes`. `--yes` skips only the confirm prompt.
**The ship deploys from its OWN checkout — a dirty primary does NOT block it.**
`bin/release ship` never reads an app primary's working tree: it advances `main`
with a **ref push** (`git push origin <frozen>:refs/heads/main` — no checkout, no
index, still fast-forward-checked, so a diverged `main` fails closed), and the two
steps that genuinely need a tree — the gem re-pin commit, and a `repo_script`
satellite's own `bin/deploy` — run in the **ship workspace**
(`Release::GateWorkspace`, role `ship`): `<repo>/.worktrees/_ship`, detached at the
QA-frozen SHA, with its own lock and its own test DB.
It used to ff the primary's `main` and refuse a dirty/off-main checkout — and that
refusal **aborted a production ship after the gems had already published**, over a
concurrent feature session's staged work. **Preflight FIRST (before anything
irreversible):** it pins each app's ship workspace at the frozen SHA (so a broken
worktree aborts while the release is still fully recoverable), **aborts** on the one
primary-state hazard that survives — a **gem** repo with modified **tracked** files,
because `gem build` packages what is on disk and the edits would be *published*
irreversibly — and merely **advises** on a dirty app primary. Every dirty-primary
surface prints the SAME rescue: commit the stranded work to a labeled
`rescue/<repo>-<timestamp>` branch. **Never stash, never discard** — it may be a live
session's work. Pure decisions: `Release::ShipSequence.preflight_offenders` /
`.advisory_message` / `.gem_build_offenders` / `.gem_build_message` /
`.rescue_commands`. **Live ship
crew:** right after ship authorization (so a declined gated ship never shows it),
ship **auto-records the Steffon → `shipped` intent** for every member
(`Release::Conductor.record_deploy_intents!(r, to_stage: "shipped", actor:
"steffon")`) so /deployments shows Steffon shipping live — a green ticking timer — through
the whole deploy instead of an empty dashed ship slot until `ship!` lands (the
2026-06-25 incident). Append-only + idempotent (`ship!` supersedes it; a
partial-ship abort leaves it open — correct, Steffon is still shipping — and a re-run
reuses it). **Producer-first:** before any app deploy, it walks every
**gem member** in order. On the happy path `prepare` already published each
version BEFORE QA (publish-gems-before-qa), so this is the **idempotent
verify** — already-live → skip, then the `release → main` collapse. When a
version is NOT yet live (a release prepared before the prepare-side publish,
or a version bumped after QA froze), it still publishes for real: the gem's
build (studio-engine: `bin/release-check --build`; otherwise `gem build
<gemspec>`), `gem push`, and a `v<version>` tag in the gem repo. A build/push
failure **aborts the ship** before any
app deploys, so apps never deploy against an unpublished gem. Then for the apps
it fast-forwards each repo's `main` up to `release` (so `release` collapses into
`main`), pushes origin — stamping that repo's members **`merged: "main"`** as
each ff lands (best-effort; the interrupted-run skip signal — a re-run's ffs
no-op and `ship!` re-stamps it regardless) — deploys (`git push heroku main`;
release phase runs migrations), and smokes `/up`. After every app deploys + smokes (and before the
`shipped` record), the **post-deploy hook** runs each member's
`devops.post_deploy_cmd` on its **production app** via `heroku run` (duplicate
commands fold to one run, as on QA), records the
`[post-deploy]` outcome, and **aborts `ship` on a non-zero exit** — the abort
lands before `ship!`, so the release stays `assembled` (recoverable) and a re-run
resumes (the command is expected idempotent). On success it stamps `deployed_sha`,
flips the RC + its members to `shipped` (`Release::Conductor.ship!`), and
**auto-posts release notes**
(`Release::Conductor.post_release_notes` → the same Formatter/Discord path as
`POST /api/v1/release_notes`; non-fatal if the webhook is unset). After a ship,
each repo's `release` equals `main` and re-accumulates the next candidate. Run
`ship` from a **primary checkout** (not a worktree): the gem repos are resolved
as siblings at the projects root.
**Post-ship agent-docs sync (the OWNED installer run).** After the primaries are
restored to the freshly shipped `main`, ship auto-runs the hub primary's
**`bin/install-agent-docs`** (`sync_agent_docs`, ship step 7b) — the owned
pipeline step that keeps the installed docs (`~/.claude` + `~/.codex` skills,
the projects-root `AGENTS.md`/`CLAUDE.md`) in sync with what shipped, so an
adapter/skill/SOP merge no longer drifts until someone happens to run the
installer by hand. It is post-SHIP by design — the installer reads the LOCAL hub
checkout's docs, and only after the ff `release → main` + restore does the
primary's `main` hold the merged docs (a qa-release-time / prepare-time run
would install `main`'s stale docs) — and NON-FATAL by construction (rescue-and-warn; a docs
sync never aborts a completed ship). **Owner: Steffon (infra) owns the step and
its mechanism;** it runs inside whichever act drives `bin/release ship`
(`production-deploy` / `full-cycle`). If the step warns, the fix is running
`bin/install-agent-docs` from the hub primary by hand.

**`Archive completed tasks`**  *(shipped → archived — the Deploy loop's conclusion)*
Run **`bin/release archive [--dry-run] [--yes] [--prod]`** to close the loop. It
archives every `shipped` task that is **not** a member of `Release.last_shipped`
(`shipped → archived`), so the most recently shipped release stays on the board
as the read-only **Last Release** while older, superseded completed work is filed
away. The pure, unit-tested rule lives in
`Release::Conductor.archive_completed!` / `.archivable_completed_slugs`; the CLI
owns the board write plus the worktree teardown around it. After archiving it
reclaims the merged/shipped feature worktrees (`bin/agent-worktree cleanup
--reclaim --yes`). `--dry-run` previews the plan (archivable + kept) and the
reclaim list without mutating anything; `--yes` runs it hands-off (skips the
single confirm). The sweep runs **card by card, from the top of the Shipped
column down**, one every `BOARD_FLIP_CADENCE` (0.8s) — each flip is its own
commit and its own live broadcast, so an open /deployments plays the sweep
instead of blinking the column away. The same cadence and top-down order carry
the ship's `assembled → shipped` member flips. Idempotent — a re-run finds
nothing new to archive (and a mid-batch failure simply leaves the remainder for
the next run; there is deliberately no transaction around the batch, which would
hold every broadcast to a single commit). Archiving
only flips a task's stage, never its `release_slug`, so the board's Last Release
section keeps linking to its members even after they're later archived,
preserving the release history. `shipped` is therefore **no longer terminal** —
the Deploy loop now closes at `archived`. **Desk teardown records are board rows**
(`DeskRecord`, on the Desks panel at `/deployments`) — the reclaim no longer writes
`delete-later.md`, because a sweep runs from the primary, the primary sits on `main`, and
166 rows were stranded that way (recovered onto the board by `bin/harvest-desk-ledger`). The archive beat still rolls that file's historical
resolved rows into its archive and commits **that** update to `release` (best-effort, only
when the ledger is the *sole* uncommitted change — pure guard `Release::ArtifactCommit`),
so it ships next round instead of piling up as uncommitted dirt.

**`Release retro`**  *(post-ship "review & learn" — completely NON-BLOCKING)*
Run **`bin/release retro [release-slug] [--worked "…"] [--friction "…"] [--followup
"…"] [--file-tasks] [--yes] [--dry-run]`** after a ship to capture what the release
taught us. It defaults to the current / most-recently-shipped release, **auto-gathers**
the release record (member tasks + kinds, per-member `submitted → shipped` cycle
timing from `TaskEvents`, rework rounds = bounces into `blocked`, reviewers, and
recorded `checks_run`), prompts a few judgment questions (what worked / what caused
friction / follow-ups — `--worked`/`--friction`/`--followup` supply them from args,
`--yes` runs fully non-interactive), and **writes a durable doc** at
`docs/agents/audits/retro-<slug>.md`, then **commits that doc to `release`**
(best-effort, non-fatal, only when the doc is the *sole* uncommitted change —
`Release::ArtifactCommit`) so the generated retro ships next round rather than
piling up as uncommitted dirt.

**Where follow-ups land, and how they stay de-duplicated.** By default each
`--followup` is filed as a **triage finding** (`bin/triage file`) — a finding costs
nothing sitting in the inbox, while a task costs a worktree, a review, and a
release slot. `--file-tasks` opts back into opening each one via `bin/task create`.
Filing is **idempotent on the finding path**: retro reads the OPEN inbox first
(`bin/triage list --json`) and **skips a follow-up whose title AND body already
match VERBATIM**, byte-for-byte. The match is deliberately never fuzzy — a fuzzy
match would silently swallow a genuinely distinct finding, which is worse than a
duplicate, because a duplicate is visible at `/triage` and a swallowed finding is
not. Two follow-ups that merely share their first eight words therefore both file.
A follow-up too short to identify itself (under `RETRO_FOLLOWUP_MIN_WORDS` words —
"fix flake") **warns and is still filed**, tagged with its release slug in the
title so two real occurrences from different releases stay distinguishable while
one occurrence refiled twice does not. Refusing was considered and rejected: it
would discard text the operator just typed at the end of a ship, and the retro's
whole contract is non-blocking. The `--file-tasks` titles are NOT slug-tagged —
`Task::TITLE_WORD_RANGE` caps titles at 3-5 words, so a `(rel-…)` suffix would
422 the create; the release rides in `agent_context` there instead.

**PRIOR ART — the three-state field every finding carries.** A finding records
whether anyone checked what was ALREADY on the surface it describes, because a
blank gets read as "nothing was there":

| State | Means | How to record it |
|-------|-------|------------------|
| `unknown` | **Nobody looked.** The default — an answer, not an absence. | omit `--prior-art` |
| `none` | Somebody looked; the surface is new here. | `--prior-art none` |
| `found` | Somebody looked; `prior_art_note` says what was there. | `--prior-art "<evidence>"` |

The column is `NOT NULL DEFAULT 'unknown'`, so "nobody looked" is stored as a
statement rather than a NULL; `found` without a note is rejected (a claimed check
with no evidence is the same blank in a badge). It is **never required** — filing
must stay free, and a requirement would only make the cheapest path "don't file
it", which is the behaviour this inbox exists to prevent. It is instead made
**loud** at the three points where a finding is acted on: `bin/triage file` warns
on stderr when it files an uninvestigated one, the `/triage` card renders
**⚠ Prior art: NOT INVESTIGATED**, and **promotion injects it into the new task's
`agent_context`** with the instruction to establish what was there before assuming
the change introduced it. `bin/triage list` marks only the *investigated* rows —
~90 rows all reading "unknown" is noise everyone tunes out, and a signal nobody
reads is worse than none.

The cost of not having it, measured once: `finding-84205478cca3` correctly flagged
an unsandboxed engine preview iframe, but travelled without the prior-art question.
The next reviewer inherited the framing and filed `finding-6a5fdcd157b3` — "the
first consumer where the iframe actually renders", "the adoption PR makes it
user-visible". Both false; turf-monster's *deleted* view had carried the identical
iframe, same URL, same 8 previews, same production CSP. Net exposure change: zero
(`finding-8b29dc565d28`). The reviewer's side of this is an obligation, not a
field — see [`../modules/pr-review-sop.md`](../modules/pr-review-sop.md#the-prior-art-obligation--before-you-say-a-change-exposes-anything).

The gather + render rule is the pure, unit-tested
`Release::Retro` (`.gather` / `.render` / `.write_doc`); the CLI reaches it through
the same read-only `conductor` runner and writes the returned markdown to the local
tree. It writes **no** agent-memory store — the doc (+ any filed findings/tasks) is
the only record. **Retro is decoupled from the pipeline by design:** `archive` does
not depend on, trigger, or wait for it, so the loop closes whether or not a retro
was run. Retro never DEPLOYS, which is why it does not gate on `--yes` — but note
it **does write to the board** when it has follow-ups to file. (This page used to
claim retro "never … mutates the board". That sentence was false, and its being
false is why nobody expected a *test* exercising `--followup` to reach production:
`test_retro_collects_repeated_answer_flags_into_the_runner_payload` shelled out to
the real `bin/triage` on every suite run and filed 39 live "fix flake" findings —
45% of the open inbox. The test now stubs the seam, and `release_cli_test.rb` pins
`TASK_API_BASE` at an unroutable loopback base so no test in that file can reach
the live board again.)

---

## 2. Two SOPs: Feature and Bug

Both ride the same stage machine. They differ at entry and in test emphasis.
Routing lives in `AGENTS.md` (see §6) so an agent self-loads the right one.

### Feature SOP

1. **Classify the shape** (see §3) — this selects the test contract.
2. Accumulate acceptance criteria with Mr. McRitchie until aligned (existing rule).
3. Set `test_plan` = the shape's required tiers.
4. Build **and write the tests at each required tier as you go** — unit first.
   This is the lever for the real complaint: *bugs that reach PR are bugs unit
   tests should have caught.* Left-shift is mechanical, not optional.
5. Self-run the **Definition of Ready (DoR)** check (`bin/dor-check`) — `--gate
   build` before you start coding, `--gate merge` before handoff (§3.3).
6. Record `checks_run`, hand off with a `handoff` note, move to `submitted`.

> **Every `bin/task move` leaves a paper trail — for free.** Each stage change
> appends a `TaskEvent` capturing `from → to`, the timestamp, and the time spent
> in the prior stage (the deterministic spine; it renders as the **Stage Timeline**
> on the task page). You do nothing to get it. To *also* attribute model cost to a
> transition, add the optional per-transition usage on the move:
> `bin/task move <task> submitted --model claude-opus-4-8 --tokens-in N --tokens-out N --cost D`.
> Usage is best-effort and opt-in; the spine is recorded regardless (and for
> non-agent moves too). Details:
> [`task-board-api.md`](../modules/task-board-api.md#stage-change-event-trail).

### Bug SOP

1. Classify **severity**: `hotfix` (production broken / funds at risk) vs `normal`.
2. **Write a failing regression test that reproduces the bug *first*** — at the
   lowest tier that can express it (a bug fixable by a unit test must get a unit
   test, not an E2E). The red test is the acceptance criterion.
3. Fix until the regression test is green; run the shape's contract for the
   touched surface.
4. `hotfix` may go straight to `building` and use an expedited review, but
   **never** skips the regression test or the operator ship gate.

> Why regression-test-first for bugs: it both proves the fix and permanently
> pushes that class of bug down the pyramid, shrinking future PR-stage churn.

### Standalone / Client App SOP

Not every app is a managed satellite. A **standalone / client app** uses the
studio's *process* — the task board, worktrees, the multi-agent merge patterns,
and the evergreen build conventions — but **owns its own runtime** and may be
handed off to a client. It rides the same **Build** workflow
(`designed → building → submitted`). Its **Deploy** half has two modes:

**Release-managed standalone** (Rolio, as of 2026-06-27):

- **PRs target `release`** once `bin/release init` has created the branch.
- **QA RC exists** — reviewed PRs merge into `origin/release`, and
  `bin/release prepare` deploys `origin/release` to the app's QA Heroku target
  from `config/qa_environments.yml`.
- **Operator ship gate exists** — `bin/release ship --by conductor` fast-forwards
  `release → main`, pushes production, and smokes the app's
  `prod_deploy.smoke_url`.
- **Runtime remains app-owned** — no `studio-engine` or hub SSO requirement.

**App-owned standalone**:

- **PRs target `main`, not `release`** — there is no persistent `release` branch
  and no release slug. `bin/agent-worktree` already falls back to `origin/main`
  as the base for any repo without a `release` branch.
- **The app team owns the merge** — an approved PR is merged into `main` by the
  app's owner; it is not assembled into a studio RC.
- **Lite DoR** — task + tests-as-you-go + the non-optional error-logging
  discipline; no release-slug / shape-gated `bin/dor-check` ceremony. (Robust
  error/API-failure logging is evergreen for *both* tiers — managed apps via
  `studio-engine`'s `rescue_and_log`/`ErrorLog`, standalone apps via plain
  `Rails.logger` and/or their own tracker.)
- **No QA RC, no operator ship gate** — the app owns its deploy and its eventual
  client handoff.

Full tier decision + phased checklist:
[`new-app-onboarding-sop.md`](new-app-onboarding-sop.md). Multi-agent build/merge
patterns (several agents scaffolding one app in parallel):
[`../modules/worktrees.md`](../modules/worktrees.md) → **Multi-Agent Safety &
Merge Patterns**.

> **Shapes are deployment-agnostic.** `config/feature_shapes.yml` and the
> shape→tier contract (§3) classify the *kind of change* (ui-only, backend,
> library, …), not the deploy tier — so they apply unchanged to a standalone app.
> The shape still selects which tiers you write; the standalone tier only changes
> *where the PR lands and who ships it*. No `feature_shapes.yml` change is needed.

---

## 3. The adaptive testing pyramid

Your insight: the pyramid must *adapt to the nature of the feature*, from one
general strategy, across all five repos. Three pieces: tier definitions (the
*what*), the shape→contract matrix (the *adaptation*), and the DoR gate (the
*enforcement*).

### 3.1 Tier definitions (general, then per-repo)

| Tier | General definition | Rails apps | studio-engine | solana-studio | turf-vault |
|---|---|---|---|---|---|
| **Unit** | Pure logic, no I/O | model/service/PORO/decoder specs | pure lib (`ColorScale`, `Email`…) | Borsh/keypair/tx builders | single instruction handler logic |
| **Component** | One behavior + its immediate collaborators, no full stack | request/controller specs + rendered partial + Alpine factory | UI primitive via a host harness | client method w/ stubbed RPC | instruction + its account constraints |
| **Integration** | Multiple objects across a boundary | request→DB→job, RPC-mocked Solana (`FakeVault`) | consumer-CI against both apps | client against test-validator | multi-instruction lifecycle (create→enter→settle) |
| **E2E** | Real browser / real chain | Playwright | (via consumers) | (via consumers) | devnet on-chain spec |
| **Manual** | Operator visual/UX acceptance | **the release QA stop** (eyeball the `assembled` RC, then Make the release) | — | — | contract transparency / `/contract` review |

Tiers are the **what**; the existing **test lanes** are the **when/where**.
Mapping: Unit+Component+Integration → `pr_review_gate`/`local_proof` (block
merge); **E2E → the sharded `playwright` job in `ci.yml`, which BLOCKS MERGE**
(G2 Review) — as of 2026-07-13 (PR #543); before that no lane ran it at all and
this line routed it to `nightly_deep`, which is why the `e2e` tier went uncollected
while `feature_shapes.yml` demanded it. Manual → `qa_acceptance`; post-deploy →
`production_smoke`.

### 3.2 Shape → test contract (the adaptation)

A feature's **shape** is recorded in `devops.shape`. It selects the minimum
tiers that must be green by the time the task is `submitted` for review:

| Shape | Example | Required tiers (DoR contract) |
|---|---|---|
| **ui-only** | "make the button blue" | `component` — rendered partial / Alpine, plus manual review at QA (add `unit` if it grows real logic) |
| **ui+db** | new form that persists | `unit` `component` `integration` `e2e` — model/validation, request+view, request→DB, happy path |
| **backend** | new job/service | `unit` `integration` — service/PORO, job + mocked I/O |
| **library** | studio-engine change | `unit` `integration` — in the engine, plus consumer-CI in *both* apps |
| **onchain** | new turf-vault instruction | `unit` `integration` — Anchor unit, Anchor lifecycle, Ruby decoder unit |
| **onchain-vertical** | new workflow w/ wallet + DB + UI + program | `unit` `component` `integration` `e2e` — almost always its own `release` |
| **docs** | SOP / runbook / README edit | none — no code tiers; routes to the documentation seat (Alex) and certifies by review, not a test lane. **Claimable only on a diff observed to be prose, optionally with its own registry-guard tests** — `*_test.rb` under `test/docs/`, nothing else (`claimable_when: docs_with_guards_diff`) — which is what makes the empty column safe |
| **test-only** | delete a stale assertion; fix a flaky spec | none — a diff with no behavior has nothing for a tier to be evidence of; it owes a **control** instead (below), and still owes the full-suite cert |

**The backticked tier names are load-bearing, not formatting.** They are the
canonical `dor_tiers` from `config/feature_shapes.yml`, and
`test/lib/feature_shape_tiers_test.rb` asserts this table and that file name the
**same tiers for every shape** — set equality, both directions. Prose after the
`—` is free text and is not scanned.

That guard exists because this table lied for months, in the way that costs the
most. It demanded `devnet E2E (nightly)` of the two shapes that move real
money — routing a **required** tier to `devnet-nightly.yml`, a workflow gated on
`vars.DEVNET_NIGHTLY_ENABLED` that has completed `skipped` on every scheduled run
and **has never once executed**. A required tier with no lane behind it is the
same self-declaration disease this whole section exists to cure, and it survived
here, in the canonical spec, precisely because prose and config were two
independent copies of one truth. Now they are one truth with a test on it: adding
a tier here that no runner runs is a RED test, not a documentation opinion.

Devnet verification of on-chain work is real and still expected — as an
**operator/QA stop**, not as a DoR tier a builder can satisfy by typing.

**A zero-tier shape is only safe while it cannot be claimed by a diff that does
not match it**, and both zero-tier shapes now say what earns them:
`claimable_when: docs_with_guards_diff` on `docs` (prose plus docs-guard tests, since 2026-09-03), `test_only_diff` on `test-only`.
`bin/dor-check` checks the claim against the **observed diff**, never the label,
and fails closed on a diff it cannot observe.

`docs` gained that guard on 2026-09-02, after shipping without one. Measured on
PR #1172: a task shaped `docs` whose diff carried
`test/integration/open_pr_receipt_visibility_test.rb` was told **"DoR-to-Merge
met"** with no tier demanded and no full-suite cert demanded — and the verdict
named neither waiver, so it read as a clean pass. Production code rode it just as
easily. The hole was a **fall-through**: the exempt-`kind` gate asks this exact
question on this exact diff and already refuses, then hands off to the shape
contract, which granted the same exemption one step later. One observation, asked
twice, answered two opposite ways — so the claim guard reuses `CodeDiff`, the
classifier the kind gate runs, rather than a second prose list that could drift
back apart.

**Doc-only means the file's TYPE is non-behavioral** (`.md`/`.markdown`/`.mdx`/
`.rdoc`, inert media, LICENSE-class basenames). A test file is not doc-only; a
comment-only edit to a `.yml` or an `.rb` is not doc-only (the granularity is the
FILE, never the hunk); and location buys nothing (`docs/agents/setup.sh` is mode
100755). The fix deliberately did **not** set `full_suite_gate: true` on `docs` —
making every prose correction pay a full suite would undo the cheap single-pass
doc change and push people to mislabel shapes, which is worse than the hole.
**Gate the claim, not the cost.**

**A waived requirement now names itself.** When a shape skips a tier or the
full-suite cert, the verdict says so and says what earned it —
`ⓘ shape docs: no test tier required · full-suite cert waived — claim verified
against the OBSERVED diff (docs_with_guards_diff, 2 file(s) [source: pr])`
(the label read `doc_only_diff` before the 2026-09-03 widening). Silence was
the other half of the defect: a gate that skips a requirement without saying so
reads exactly like a gate that enforced one and passed, which is why #1172's
output was seen by several readers before anyone noticed what it had not asked
for.

**`test-only` is the one shape whose contract is not a tier list, and reading its
empty column as a discount gets it exactly backwards.** A diff made entirely of
test code has no behavior for a tier to be evidence *of* — measured, 2026-08-10: a
builder who deleted **one assertion** from an integration test ran the hub's whole
unit tier (4,103 runs) purely to have something truthful to tag, and it said
nothing about his change. So the shape swaps the question. Not *which tiers did
you run* but **does the changed test still bite?** Its contract, all three parts
enforced by `bin/dor-check`:

| It requires | How it is checked |
|---|---|
| the diff is **100% test code** (`test/`, `tests/`, `e2e/`) | **verified from the observed diff**, never from the label — an unrecognized file *blocks* the claim, and so does a diff the gate cannot observe (`bin/lib/test_only_diff.rb`, an allowlist) |
| the **full-suite + rubocop** cert, exactly as a feature | the existing fingerprint-bound `[full-suite@<fp>]` / `[rubocop@<fp>]` evidence — test code is code, and this shape is the one most able to break the suite quietly, so `full_suite_gate: true` |
| a **control** | **EXECUTED** where the diff has a replayable file — `bin/control-check <task>` replays the pre-change test files against current production code and stamps a fingerprint-bound `[control@<fp>]` line the gate re-grades. Where it does not, a `[control]` prose line that **names a file in the diff** — a control that could have been written before the change was made is a sentence, not a result |

The control is the artifact both builders produced unprompted: run the pre-change
test against current production code and show it failing at the line you touched,
or force the failure your new diagnostic is for and show it firing.

Since 2026-08-11 the first of those is **run by a lane**. `bin/control-check`
restores the pre-change content of the changed test files and runs them — sound
only because the diff is 100% test code, so production code at the base is
identical to production code at HEAD. Two populations, and the runner names which
files fall in each: a **Ruby minitest file with a pre-change version** is replayed
(~79% of this repo's test-only history), while an **added** file (no pre-change
version at all) and **`e2e/` / `tests/`** files (no runner here — a booted server
or a funded validator, the `e2e_onchain` argument) stay the reviewer's prompt. The
runner stamps **nothing** when it replayed nothing, so the gate never credits a
run that did not happen.

The **verdict never refuses**. `old RED` is a NECESSARY change; `old GREEN` is
NO-SIGNAL — and a rename, a move, a consolidation and a silently deleted assertion
all look identical from there. The gate reports it and asks the author for the
sentence that disambiguates it, because a false refusal would land on legitimate
work and teach people to stop claiming the shape. `control` is still deliberately
**not** a `dor_tiers` entry: it is `required_evidence` with its own machine-owned
lane, executed only where a replay exists.

The matrix is the single source of "how much testing is enough" — it removes
the per-task judgment call that currently lets thin PRs through.

### 3.3 Definition of Ready for review (DoR) — the enforcement (the DoR gate)

A task **may not advance `submitted → reviewed`** unless, for its shape:

- every required tier is present and green, recorded in `checks_run`;
- the **FULL test suite and a FULL `rubocop`** are certified green against the
  *exact code being shipped* — not the touched-file subset. The shape's tier tags
  prove the agent *wrote* unit/integration; they do not prove nothing *else*
  broke. `bin/full-suite-check <task>` runs **what CI runs, verbatim** — read from
  the repo's own `.github/workflows/ci.yml`, today `bin/rails db:test:prepare test
  test:system` (base **and** system tiers) — plus `bin/rubocop` in full, and stamps
  fingerprint-bound `[full-suite@<fp>]` / `[rubocop@<fp>]`
  `checks_run` lines; `bin/dor-check` re-grades them against the current code
  fingerprint (a git tree hash — content-addressed, so it is **stable across the
  pre-commit→commit boundary** and identical in a reviewer's fresh checkout of the
  same tree), so a **stale** (edited-since) or **partial** (one-lane / touched-files)
  record is **refused**. Both gates root the CODE they run + fingerprint at the
  **current worktree** (the cwd's git toplevel), so a **satellite** task (turf-monster,
  rolio) certifies its OWN repo even though it runs the hub's gate script — while the
  shape config (`feature_shapes.yml`) stays resolved from the studio. Run
  `bin/full-suite-check` **from the worktree** — a cert *writer* refuses a foreign
  root outright, because it stamps evidence about the tree it stands in.
  `bin/dor-check` **self-roots** at the task's tree from anywhere (it only *reads*
  evidence) and announces the re-root on stderr; see
  [the DoR gate](../modules/gates/dor.md#the-gate-grades-the-tasks-tree--never-the-one-you-stand-in).
  (The `FULL_SUITE_ROOT` / `DOR_CHECK_DIFF_ROOT` envs override the root; they are a
  CI/test seam, not for routine use.) Escape hatch — a *record*, exactly like `post_deploy_cmd: none`: a
  reasoned `[full-suite-bypass] <why>` `checks_run` line passes the gate but is
  flagged **loudly** in the verdict (use it for a pre-existing, unrelated red
  tracked elsewhere — never to wave through your own break).
  **Fast route (the builder default — the 90/10 rethink):** GitHub CI already
  runs the FULL suite + `test:system` on every PR push and the merge gate blocks
  on CI green anyway, so a ~6-minute local full suite bought *earliness*, not
  coverage. `bin/fast-check <task>` keeps the earliness at ~1/6 the cost: it runs
  the tests the branch diff **maps to** (path convention — `app/models/x.rb` →
  `test/models/x_test.rb`, views → their controller test, `bin/tool` →
  `test/lib/tool_test.rb` — with a class-name grep fallback) **plus** the curated
  core spine (`config/fast_cert_spine.yml`) and `rubocop` on the **changed files
  only**, stamping a fingerprint-bound `[fast-cert@<fp>]` line. `bin/dor-check`
  credits a FRESH fast cert **only alongside a green GitHub CI** — a red,
  pending, missing, or unverified CI does not credit it. `bin/full-suite-check`
  stays unchanged as the CI-independent local cert and the release-verification
  tool;
- required `metadata["devops"]` fields are populated (existing contract);
- a local proof URL exists when the shape touches UI;
- if the branch diff touches a **seed or data-migration** (`db/seeds`,
  `db/migrate/`), the task declares `devops.post_deploy_cmd` — the command
  `bin/release` runs on the deployed app (QA on `prepare`, prod on `ship`) so a
  seed/backfill isn't run by hand post-ship. Heroku's release phase auto-runs
  `db:migrate` but **not** `db:seed` or a backfill rake; set `post_deploy_cmd` to
  `none` to acknowledge a schema-only migration that needs no command.
- **`post_deploy_cmd` safety rule (both gates):** `bin/release` runs the command
  **verbatim against PRODUCTION**, so it must be **narrow, prod-safe, and
  idempotent**. A declared `post_deploy_cmd` is **rejected** when it is a bare
  full-suite seed — `bin/rails db:seed`, `rails db:seed`, `bundle exec rails
  db:seed`, `db:seed:replant`, or `rake db:seed`. `db/seeds.rb` loads **every**
  `db/seeds/*.rb`, so a bare seed would inject demo News/Content/Tasks into prod
  **and** abort the release on the first non-idempotent seed file. Declare a
  narrow command instead: a **scoped single-file runner** —
  `rails runner 'load Rails.root.join("db/seeds/NN_x.rb").to_s'` — or a
  **dedicated idempotent rake task** (e.g. `bin/rails pokemon:seed`). This is the
  fix for a real near-miss: `merge-docs-reviewer-into-alex` shipped
  `post_deploy_cmd='bin/rails db:seed'` and was caught only when QA aborted,
  because reviewers read the code diff, not the deploy metadata.

This is **deterministic** — a `bin/` gate (`bin/dor-check <task>`, default
`--gate merge`), not a judgment call. There is also a lighter `--gate build`
(spec-complete, no tiers) for the `designed → building` entry. The feature agent
runs it before handoff; the heartbeat agent re-runs `--gate merge` as gate zero
of review (the fingerprint-bound full-suite evidence is checkout-independent, so
gate-zero credits the same evidence the feature agent recorded). A failed DoR is
an *immediate, cheap* send-back that never consumes review-judgment tokens. This
is the structural fix for the review ping-pong: most "PR not ready" churn becomes
a pre-PR mechanical check.

On the **merge gate**, `dor-check` also verifies the PR is **open** and reads its
**real GitHub CI** (`gh pr view --json state` then `gh pr checks`, folded to one
verdict by `bin/lib/ci_status.rb`): a **failing**, **still-running**, or
**closed/merged** PR is refused — a closed PR's green checks are *historical*, not
a live target, so a stale `pr_url` never passes as green — an **all-green open** PR
passes, and a task with **no PR yet** stays silent (nothing to verify). This closes the blocker-analysis
**#1 class** — a PR green *locally* but red on CI, because the **fast** local cert
(`bin/fast-check`, the builder default) runs only the diff-mapped tests + the core
spine, and **not** the browser `test:system` lane GitHub also runs. (The *full*
cert no longer has this gap: `bin/full-suite-check` runs CI's own command verbatim,
`test:system` included — which is why `dor-check` credits it without CI's verdict,
and credits the fast cert only once CI is green.) It
rides the existing gate-zero re-run: the feature agent's pre-PR run is silent on
CI, but the heartbeat's `--gate merge` gate zero runs **after** the PR is up and
refuses a red (or not-yet-green) PR before any review-judgment tokens are spent. A
`gh`/network error or a PR with no checks degrades to a *note*, never a hard block
— we don't trade a flaky CI lane for a flaky gate.

`bin/dor-check` itself stays a **fast, deterministic verdict** — it does *not*
run the suite; `bin/full-suite-check` is the (slower, run-once-before-handoff)
runner that produces the evidence (format + fingerprint live in
`bin/lib/full_suite_gate.rb`). It closes the retro gap where a build passed only
the **files it touched** while the full suite or `rubocop` broke post-merge. For
those who want the lanes wired locally, `bin/full-suite-check --install-hook`
installs an **opt-in pre-push** hook (off by default; runs the gate before each
push, blocks a red push; remove with `--uninstall-hook`) — pre-push, not
pre-commit, because a full suite on every commit is untenable. But the
**authoritative** gate is `bin/dor-check` validating the recorded evidence: the
hook is a convenience, and evidence on the task record survives a fresh checkout
where a local hook artifact would not.

The §3.3 sequence is recorded as **two branded gates** (attempt-aware `GateRun`
rows; "Option B" split, 2026-07-11):

- **G1 Cert** (`g1_cert`) — the **self-closing cert**: the cert tools
  (`bin/fast-check` / `bin/full-suite-check`) OPEN the attempt, append one SOP
  per lane, and CLOSE it themselves — `success` on all-green, `failed` on a red
  lane (the re-run opens attempt n+1). `dor-check` no longer touches `g1_cert`.
- **DoR** — the Definition-of-Ready **verdict**, its own gate now, split by
  role: the builder's `bin/dor-check <task>` opens+closes **`dor`**, and the
  reviewer's gate-zero `bin/dor-check <task> --gate-role review` opens+closes
  **`dor_review`** (the review session's pre-claim CI-red skip also closes
  `dor_review` failed). CI stays a **handoff, not a gate** — its verdict rides as
  a `ci` SOP inside DoR, never its own gate row.

Standalone gate SOPs: `docs/agents/modules/gates/g1-cert.md` / `dor.md` /
`g2-review.md` (task-grain), `g3-candidate.md` / `g4-ship.md` (release-grain,
conductor-recorded).

### 3.4 Test ownership & timing — *who writes what, when*

| Tier | Author | When |
|---|---|---|
| Unit | Feature agent | During build, before first commit |
| Component | Feature agent | Before `submitted` |
| Integration | Feature agent | Before `submitted` (mandatory for any `migration`/`solana`/`payment`/`auth` risk tag) |
| E2E (happy path) | Feature agent | Before `submitted` for ui+db / vertical shapes |
| **Fast cert (builder default)** | Feature agent | Before `submitted` — `bin/fast-check <task>` runs diff-mapped tests + the core spine + rubocop on changed files (~1 min); its fingerprint-bound evidence is credited by `bin/dor-check` once the PR's GitHub CI (the full net) is green |
| **Full suite + rubocop** | Feature agent | Before `submitted` when CI can't vouch (or for release verification) — `bin/full-suite-check <task>` certifies the WHOLE suite + lint (not the touched-file subset); records fingerprint-bound evidence `bin/dor-check` re-grades |
| E2E (edge/regression) | QA lane (Avi/Steffon) | May add during review; becomes a follow-up task if large |
| Manual | **Mr. McRitchie** | At the release QA stop (this *is* the manual tier) |

### 3.5 Test pruning — *when and how we keep tests effective*

Pruning is a recurring **`chore`** task owned by the QA/infra lane (Steffon),
on a monthly cadence, tracked like any other task.

- **Triggers:** suite wall-clock regression, flake-rate climbing, an
  "inverted pyramid" smell (E2E count growing while unit coverage stalls).
- **Actions:** flaky → `quarantine` lane + a follow-up task (never silently
  skip); redundant → delete the higher-tier test when a lower tier now covers
  it (push coverage *down* the pyramid); dead → remove tests for removed
  behavior.
- **KPIs (tie to Avi's rework-rate):** suite wall-clock per lane, flake rate,
  coverage-per-tier, and "bugs that reached PR" (a falling number proves
  left-shift is working). Track these through task QA notes, CI, and
  `bin/devops-tests`; daily steering still comes from task status.

---

## 4. The airgapped heartbeat DevOps agent

Runs on the OpenClaw box every ~10 minutes. Builds directly on the
`devops-cycle`/`qa-intake` toolchain and the "Future Heartbeats" lease spec.

### 4.1 One heartbeat = evaluate every in-flight task, advance each ONE safe step

```
# Workflow 1 — per task (review).  Each submitted task, one safe step.
for each task in {submitted}:
  acquire lease (claimed_by, claim_expires_at)   # resilience: reclaimable
  1. bin/dor-check --gate merge (gate-zero: metadata + tiers + FRESH full-suite/rubocop evidence) — fail ⇒ block(rework) + qa_feedback, release
  2. run pr_review_gate suite (base: unit/component)            — fail ⇒ classify, block(rework), release
  3. one Carl per PR (standing primary + owner) summons 1 domain LIGHT (fit + LOGGED tiebreak) — §1.2
     each: diff-vs-acceptance + standards/smell/scalability     — changes ⇒ ONE complete qa_feedback + block
  4. on a merge-ready verdict → reviewed ✅                       — Discord: approved

# Workflow 2 — the ONE active release (singleton).
release.assembling:
  bin/release prepare (Avi, SELF-HEALING): detect reviewed + assembled stragglers, honoring dependencies + lanes (§4.2)
  sweep: overlap planner (warn) → gh pr merge each (base release; SKIP merged: release/main) → sweep! ALL in ONE heroku run (ensure)  — conflict ⇒ leave reviewed, keep the rest
  members reviewed + merged:release; pre-QA gate (qa_test_cmd: integration + e2e-smoke on origin/release)  — regression ⇒ bin/release eject <task> + revert, keep the rest
  deploy origin/release → QA + Discord notes → wait-for-boot /up → QA-GREEN ⇒ qa_green!: members → assembled + release.assembled  — failure ⇒ members stay reviewed (next run self-heals)
  # full e2e + highest tier runs at ship, on the FROZEN ship SHA (Steffon) — §1.2
release.assembled:
  Steffon: full e2e + highest tier on the FROZEN ship SHA      # §1.2 — closes "shipped ≠ tested"
  if operator_made_the_release: bin/release ship → PREFLIGHT (each app on clean main, else abort) → ff release → main, bin/deploy → production_smoke → notes → members shipped  # ONLY here
  else: no-op (HARD STOP — wait for the operator to Make the release)

update last_heartbeat_at, current_command, blocked_reason; emit progress
```

Properties that give resilience + scale:

- **One step per heartbeat** → bounded blast radius; an interrupted step is
  re-attempted next tick from the durable task state, not from agent memory.
- **Lease fields** (`claimed_by`, `claim_expires_at`, `last_heartbeat_at`) →
  an interrupted task is reclaimable by the next heartbeat; this is exactly the
  interruption-resilience you asked for, at the task level.
- **Idempotent steps** → merge/deploy/notes are safe to retry.
- **Every heartbeat produces evaluation + progress** by construction — even a
  "nothing changed" tick posts a one-line status.

### 4.2 Order-of-operations / conflict serialization (the multi-feature problem)

The heartbeat agent will not merge-race conflicting work:

- **Overlap planner (pre-merge heads-up).** A batched `bin/release merge a b c`
  prints, before merging, the **files each PR shares with the others**, a
  suggested merge order (smallest-footprint first), and which PRs will need a
  post-merge rebase — so siblings that all touched `task.rb` / a shared helper /
  the docs don't conflict on `release` *after* passing review. Warning-only (it
  never blocks); the conductor reads it to choose order / rebase the loser.
- **Migrations:** two tasks touching `db/schema.rb` or migrations → serialize
  via the `backend_migration` lane (`bin/task migration-lane acquire
  <task-slug>`, a durable unique-indexed claim — see `exclusive-lanes.md`); the
  second one holds with a note.
- **studio-engine + consumers:** gem publish → consumer lockfile bump → app
  deploy is one ordered `release_conductor` lane; the agent promotes the
  train in order, never a consumer ahead of its gem.
- **turf-vault program:** **new rule** — at most one in-flight task may change
  the Anchor program (same single-flight lane pattern as migrations). A vault change
  and its turf-monster IDL re-pin form a `release_conductor` lane deployed *in order*
  (Squads program upgrade first, then app IDL re-pin via `bin/deploy`'s
  allow-list dance). The agent refuses to deploy two program upgrades
  concurrently.
- Because **prod is always human-gated**, the riskiest ordering decisions
  (anything `migration`/`solana`/`payment`) still land in your one-click queue
  with full context — the agent sequences, you approve.

---

## 5. Visibility — standardized Discord

Three message classes, **deterministic templates** with a small freeform
`notes` slot. Posted freely by the heartbeat agent.

| Class | Trigger | Shape (deterministic) |
|---|---|---|
| **Heartbeat digest** | every tick (or every N) | `🔄 DevOps tick HH:MM — N in review · M in QA · K awaiting approval. Blockers: …` |
| **Task event** | stage advance / send-back | `✅ <title> merged → QA <url>` · `⛔ <title> sent back: <reason>` · `🟡 <title> QA-passed — approve to ship: <qa url>` |
| **Release notes** | after prod deploy | existing `POST /api/v1/release_notes` (already standardized, grouped-by-app, task-linked) |

The 1000ft view: blockers + "awaiting approval" are the only two classes you
*must* read; the digest is ambient. Webhooks: reuse
`DISCORD_RELEASE_NOTES_WEBHOOK_URL`; add `DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL`
for digests/events so release notes stay clean.

---

## 6. Agentic context routing (never re-explain the cycle)

Add a routing block to `AGENTS.md` so a fresh agent self-selects its SOP:

```text
## DevOps Routing
Before implementing, identify your role and read the matching section of
docs/agents/system/devops-cycle-design.md:
- Handling a FEATURE → § Feature SOP. Classify the feature SHAPE and load its
  test contract before writing code. Build: designed → building → submitted.
- Handling a BUG → § Bug SOP. Write the failing regression test first.
- Running the airgapped/QA cycle → § Heartbeat agent. One safe step per task;
  review moves submitted → reviewed or blocked; never ship a release without the
  operator OK.
```

Everything else the agent needs already loads via the existing `Start Here`
table. No per-session explanation from you.

---

## 7. Deterministic vs judgment + model budget

Compartmentalize tokens: deterministic scripts carry the 80%; escalate to a
capable model only for genuine review judgment, and only to Opus for high-risk
surfaces.

| Step | Nature | Engine | Model |
|---|---|---|---|
| DoR gate, metadata presence | deterministic | `bin/dor-check` | none |
| Run test suites | deterministic | CI / `bin/devops-tests` | none |
| Conflict / lane check | deterministic | `bin/` + durable lane claims | none |
| Classify a check failure (real / flaky / stale) | light judgment | small model | Haiku |
| QA acceptance evaluation | suite + light judgment | suite + small model | Haiku |
| PR diff vs acceptance review | judgment | capable model | **Sonnet**, **Opus** if `solana`/`payment`/`migration`/`auth` |
| Merge decision | rules-gated judgment | rules + model | Sonnet |
| QA deploy / prod deploy | deterministic | `bin/qa-server` / `bin/deploy` | none |
| Release-notes formatting | deterministic | `POST /api/v1/release_notes` | none |
| Release-notes highlights prose | light judgment | small model | Haiku |
| Discord digest / event messages | deterministic templates | script | none |
| Production ship authority | **human** | `production-deploy` launch + `--yes` | Mr. McRitchie |

---

## Decisions to confirm (call these before implementation)

1. **`shape` field** vs inferring shape from `risk_tags` — add an explicit
   `devops.shape` field, or derive it? (Recommend explicit; it's the contract key.)
2. **Hotfix lane** — do you want an expedited `hotfix` severity that goes
   straight to `building` and shortens review, still regression-tested +
   ship-gated? (Recommend yes.)
3. **turf-vault single-writer lane** — confirm only one in-flight program change
   at a time is acceptable (it serializes blockchain work). (Recommend yes; it's
   the safe default given Squads + IDL pinning.)
4. **Progress webhook** — separate `DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL`, or
   reuse the release channel? (Recommend separate.)
5. **Heartbeat read path** — the airgapped box reads the production task board
   over the existing bearer-token API; confirm that network path is allowed from
   the OpenClaw environment (the one external dependency the airgap must permit).

## Implementation order (each its own task)

**Done**

- `bin/dor-check` + the `shape`→contract matrix in `config/feature_shapes.yml`.
- `AGENTS.md` / `CLAUDE.md` routing block.
- **The two-workflow status model**: Task stages + state machine,
  `bin/task` / `bin/dor-check` / board, the data migration, `blocked` metadata
  (`blocked_from` + `block_kind`), and the DoR-to-Build / DoR-to-Merge gates.
- `Release` singleton model + `release_slug` / `dependencies` on Task + the
  board's "current release" header.
- **The persistent-`release` branch cutover**: `bin/release init|merge|prepare|
  eject|ship` on the persistent per-repo `release` branch — membership records at
  the sweep (`merge`/`prepare` → `gh pr merge` + `Release::Conductor.sweep!`,
  stage flip on QA-green via `qa_green!`), `prepare` deploys `origin/release` to
  QA, `ship` fast-forwards `release → main` stamping `merged: "main"` (§1.1).
- **`bin/agent-worktree` release-base default**: `new` cuts the feature branch from
  `origin/release` (falling back to `origin/main`), and `finish --pr` opens the PR
  with `--base release` — feature agents no longer pass `--base release` by hand.
- **`bin/devops-cycle` stage-name migration**: the heartbeat planner (+ its snapshot
  fixture + `bin/devops-tests` lanes) speaks the new stages
  (`submitted`/`reviewed`/`assembled`).
- **Multi-repo `ship`**: producer-first, hub-before-satellites deploy across every
  release repo (gems → re-pin consumers → hub → satellites) with the per-repo
  `test_cmd` gate and partial-ship recovery (§1.1).

**Next**

1. Pyramid re-tag of suites in `config/devops_test_suites.yml`.
2. Discord progress/event templates + `DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL`.
3. The heartbeat agent script for the OpenClaw box (review→QA first; ship gate as
   a no-op approval check).
4. turf-vault single-writer advisory lane.

**DevOps v2 — the `accepted` ladder + Actions-authoritative gates (in rollout, hub-first)**

The target model is specified at the head of §1. Each phase is its own task + PR
through the cycle; the Phase-1 base-flip cuts over onto an **empty board** (after
the current release drain), so the in-flight-PR retarget risk is zero.

0. **Ratify this doc** — the target-model subsection + status note (this task).
1. **`accepted` + tiered CI (hub)** — create the persistent `accepted` branch
   (`origin/release` ref-push, mirroring `bin/release init`); split `ci.yml` into a
   `workflow_call` suite (`ci-suite.yml`, suite step kept literal) + a thin
   entrypoint that selects Tier 1/2/3 by target branch **via `with:`** (never
   `if:`/`concurrency:`/path filters — the trigger guard tests forbid them); repoint
   `ci_workflow_triggers_test.rb` / `repos_test.rb` per-tier; flip the feature-branch
   base `release → accepted` in `bin/dor-check`, `bin/fast-check`,
   `bin/agent-worktree`.
2. **Actions CD (hub)** — `qa-deploy.yml` (push→`release`, `qa` env, optimistic
   `/up` smoke) + `prod-deploy.yml` (`workflow_dispatch`, `production` env, hard-gated
   `/up`; the `production` required reviewer this phase added was later removed
   2026-07-20 — task `remove-prod-deploy-approval` — so the dispatched run deploys
   straight through); the conductor triggers + `gh run watch`es instead of local
   `git push heroku`.
3. **Flip gate authority + rewrite SOPs (hub)** — promote the existing `CiStatus`
   auditor to the G3/G4 verdict (G1 stays a local pre-flight); reconcile §1.1/§1.2,
   the Feature/Bug SOPs, §3.3 DoR, Workflow 2 (§4), and the gate docs to the target
   model; `bin/install-agent-docs`.
4. **Canary + cleanup** — drive one change end-to-end through the new pipeline;
   then delete the demoted local gate execution.
5. **Propagate** — rolio (resolve its RUNBOOK "no release branch" note + the
   system-wait-budget prereq), then turf-monster (`repo_script` deploy + Solana
   keys + Playwright staging; per-tier registry↔CI binding). Gems (publish-first) +
   turf-vault (on-chain) are separate tracks.
