# PR Review SOP (modular) — the `review-one` primitive

This is the **reusable, self-contained PR-review procedure** — the review half of
the Deploy workflow (`submitted → reviewed`), factored out so any conductor or QA
session can invoke it the same way "all over the place." The release SOP
([`../system/devops-cycle-design.md`](../system/devops-cycle-design.md) §1.2 /
§1.4), the [heartbeats launcher map](heartbeats.md), and Carl's
[`pr-review`](../agents/carl/sops/pr-review.md) /
[`pr-review-slow`](../agents/carl/sops/pr-review-slow.md) SOPs all include this
module **by reference** rather than restating it — edit the review contract here
and it flows everywhere.

> **This module IS the `review-one <task>` atom** — the indivisible PRIMITIVE the
> composable deploy launchers are built from (§1.4). One run = **one PR / one
> task**: the review session spins **one Carl** (the standing primary + owner) →
> Carl summons **one domain LIGHT** at his discretion → on a merge-ready verdict
> Carl **merges the feat PR into `accepted`** and drives the task to **`reviewed`
> and STOPS** (review never touches `release`/`main` and never deploys — Avi's
> self-healing `qa-release` sweeps the reviewed queue, promotes the `accepted →
> release` batch PR, and flips members `assembled` on QA-green), or **any**
> reviewer blocks. The plural atoms just LOOP this body over the `submitted`
> queue: **`pr-review`** runs it fanned across all submitted PRs in **waves of
> ≤5**; **`pr-review-slow`** runs it serialized, one PR at a time. So the sections
> below are the body of `review-one`; the loop that turns it into `pr-review` is
> the concurrency wrapper in §1.4 — nothing here changes between the two.

It follows the established **2-read review** model (a deep primary + a focused
light), but **formalizes the agent roles**: the session Pokémon (identity +
orchestrator) → **one Carl per PR** (the standing primary AND owner) → **one domain
LIGHT** Carl summons. **There is no Avi supervisor.** Carl reviews deeply, owns the
gates, summons the light, drives the verdict, and merges. Each reviewer reviews **as
their own soul**, and each review shows up in the Agent column of the Alex heartbeat
(`/alex/heartbeat`) attributed to that soul. Nothing here overrides the canonical
stage ownership in `devops-cycle-design.md` §1.2 — it is the operational how-to for
that stage.

> **Stale GitHub credential? Fix it yourself and keep going — do not escalate.**
> App installation tokens expire **~hourly BY DESIGN**. On `Bad credentials`, a
> 401/403, an unreadable CI, or a `gh auth login` prompt, run
> `eval "$(bin/gh-auth-refresh --export)"` — read its **stderr**, because `eval`
> hides the exit code — then retry the exact command that failed. Asking Mr.
> McRitchie to run `gh auth login` is both the terminal chore the operating model
> forbids and a step that cannot work: `gh` refuses to store a credential while
> `GH_TOKEN` is set. Architecture and symptom→fix: [`source-control.md`](source-control.md).

## When to invoke

Run this whenever a `submitted` task's PR needs review before it can advance —
as the `review-one` atom inside a `full-cycle` / `deploy-with-task`
composition, as the body of a Carl Heartbeat `pr-review` / `pr-review-slow`
sweep (review-only — the `accepted → release` promotion belongs to Avi's
`qa-release` sweep), or a one-off review a conductor kicks off by hand. The unit
of work is **one PR / one task**; a queue is just this cascade run per task
(`pr-review`), in **waves of ≤5 concurrent agents** (the board DB's connection
budget — a Carl and his light count as two; see "Concurrency cap" in the
operating model).

You are the **SESSION orchestrator** here, not a feature agent — you orchestrate
review on work that is **already built**. Do not create a task, take a worktree, or
write feature code.

## The reviewer pool — Carl is the standing primary; the light is the domain pick

Carl is the **standing primary** on every PR (Lead Architect). The **LIGHT** is the
domain specialist Carl summons at his discretion by the PR's change surface:

| Change surface | Light reviewer soul | `subagent_type` |
|---|---|---|
| Backend — Rails, models, jobs, services | **Carl** is primary; light rarely needed | `carl` |
| UI — ERB, Tailwind, Alpine, theme | **Shannon** | `shannon` |
| On-chain / Solana — turf-vault, `Solana::*`, wallets | **Jasper** | `jasper` |
| Infra / deploy — Heroku, CI, env, buildpacks | **Steffon** | `steffon` |
| Docs / operating-model — agent docs, runbooks, README | **Alex** | `alex` |

Alex is the orchestrator **and** the pool's launchable Documentation review seat —
one identity. Each review names exactly **one PRIMARY** — Carl (deep review, owns
the lane) — and **one LIGHT** (a focused domain second read).

## Step 1 — the session spins one Carl; Carl's gate-zero

The session claims a green-CI PR (`bin/task claim-next-review`) and **spins one
Carl** (Agent tool, `subagent_type: carl`) as the **review OWNER** — there is no
Avi supervisor. Carl:

1. Re-checks the PR's **live GitHub CI** (the claim only pops green-CI PRs, but CI
   can flip mid-review): his gate-zero `bin/dor-check <task> --gate-role review` is
   **strict** — **red** → `bin/task block <task> --kind rework` naming the failing
   checks; **conflicted** (`gh pr view <pr> --json mergeStateStatus` reports
   `DIRTY`) → `bin/task block <task> --kind rework` with "merge the PR's base in and
   resolve" guidance (`outcome=ci-conflicted`); **pending** → defer to a later pass;
   **green** → continue. (A red or conflicted PR is never claimed in the first
   place — `claim-next-review` only pops green-CI tasks — so this is the mid-review
   catch.) Both gate-zero bounces are **MECHANICAL** — there is no disagreement for
   the operator to arbitrate — so if the two-bounce breaker (Step 3) refuses one on
   an already-bounced task, re-run it with `--breaker-ack "red CI, mechanical"`
   (or `"merge conflict, mechanical"`); the reason is recorded on the row.
2. Confirms **product-acceptance** — does the open PR (base `accepted`) meet the
   task's acceptance criteria?
3. Determines the **domain LIGHT** by change surface (the table above), previewing
   with **`bin/reviewer-select <task>`**. It scores the pool by domain fit with a
   logged, seeded-per-task tiebreak and **excludes** the QA owner (who QAs the
   assembled RC — no self-gating), **every AUTHOR** (a soul never reviews its own
   work), and any **busy souls** (`--busy a,b,c` and/or `--busy-auto`). The pool is
   never starved below a pair.

   **Every author, not just the last one to claim.** A task can have several: a
   session limit kills a builder mid-work and another soul finishes it.
   `devops.built_by` holds ONE slug, so on 2026-08-30 it named steffon while ALEX
   had written every test on the diff — and this command duly seated Alex as the
   light on Alex's own PR (#1081). The exclusion now reads `devops.builders`, the
   server-owned set stamped on every build claim AND on the submit, unioned with
   `built_by` and every `→ building` event actor **that is a build claim** — a rework
   bounce lands the task on `building` too, and that actor is you (see below).

   **The author is not always the claimer.** A session limit kills the claimer with
   nothing committed and another soul writes and ships the whole diff — the standard
   shape of a handover, four of them in one day. Accumulating on the CLAIM alone read
   as COMPLETE and named the wrong soul: on PR #1094 the selector excluded shannon,
   who wrote nothing, and left the real author (alex) a live light candidate at rank
   3. So the SUBMIT is an authorship moment too: `bin/task move <task> submitted
   --actor <soul>` ADDS that soul to the set, and a bare submit whose session never
   claimed the task stamps `builders_unattributed` instead — the refusal below.
   Forgetting the flag is therefore LOUD, not silent.

   **It REFUSES (exit 2) in four states**, because an empty exclusion list is not
   the same answer as "nobody to exclude":

   | Refusal | What it means |
   |---------|---------------|
   | AN AUTHOR NAMED NOBODY | a `--builder` entry matches no roster soul — including a PARTIAL typo (`--builder steffon,alexx`), where the list still resolves to someone and the missed soul silently goes un-excluded |
   | authors unknown | no *soul* is named — `built_by` blank, or holding a name that is not on the roster, and no soul on a `→ building` **build claim** (a rework bounce lands there too and is deliberately not read as authorship) |
   | author set INCOMPLETE | another session claimed **or shipped** the task and named no soul (`devops.builders_unattributed`) — never YOUR OWN bounce; see below |
   | an author would be SEATED | the pool was too small to drop them all, so one was kept eligible |

   Say which it is: `--builder <soul>[,<soul>]` names the authors (comma-separated
   for a handoff), `--builder none` asserts that no soul built it. Stamp it durably
   with `bin/task move <task> building --actor <soul>` (which works on a task
   already at `building`, so a fast-lane build can be corrected in place). A soul who
   picked the work up mid-flight and shipped it names themselves the same way, on the
   submit: `bin/task move <task> submitted --actor <soul>`.

   **A typo cannot lift any of that.** Every slug is checked against the roster
   (`Task.soul?`), not merely a lowercase-word shape — `--builder stefon` names
   nobody, so it refuses rather than passing as a known builder who excludes no one.
   A typo on the RECORD is reported as one: a `built_by` holding `shanon` refuses
   and quotes the name back, rather than calling the field blank and sending you to
   re-stamp over it.

   **YOUR OWN BOUNCE NO LONGER CAUSES ONE.** `bin/task block <slug> --kind rework`
   lands the task on `building`, and every reader that took that for a build claim
   recorded the REVIEWER: the status-line heartbeat adopted the free lease (so you
   held the builder's desk and the documented repair was refused as
   `:held_by_other`), `builders_unattributed` got your session, and
   `ReviewerSelector#builders` got your soul off the block's `→ building` event.
   Measured 2026-09-04 on four bounced tasks in one sitting. All three now
   distinguish a review write from a build write, so a bounce leaves the author set
   exactly as it found it. If a bounced task still refuses, the missing author is a
   REAL one — do not reach for `--builder` reflexively.

   **The SEATED refusal has no widening flag, by construction.** The light pool is
   the specialist pool minus the standing primary, and the default QA owner is not
   in it — so the pool is already at its maximum and `--qa-owner` can only hold or
   shrink it (naming `carl` costs the standing-primary seat and keeps MORE authors
   eligible). The only lever that clears it is `--builder`, stating a smaller true
   author set. If the set is right, every eligible light wrote the diff.

**Record the intent.** `bin/reviewer-select <task>` **records the picked pair by
default** — it writes Carl + the light onto the task as the live **review intent**
(the "record intent on PR review" convention), so `/deployments` and the task
timeline show them reviewing live — a green ticking timer — the moment review kicks
off, before `→ reviewed` lands. Pass `--no-record` / `--dry` only for an
advisory-only preview. (The manual fallback is
`bin/task intent <task> --to reviewed --actor carl`.)

Carl then **summons his LIGHT** (Step 2) — his own child, nested under him.

## Step 2 — Carl reviews deep; the LIGHT reads AS its soul

Carl runs the deep review
([`../agents/carl/sops/pr-review-primary.md`](../agents/carl/sops/pr-review-primary.md))
and **summons one LIGHT** (Agent tool, the light's domain `subagent_type`) for the
focused second read
([`../agents/carl/sops/pr-review-light.md`](../agents/carl/sops/pr-review-light.md)).
The light is Carl's own child (nested), running concurrently with his deep review
and reporting up to him. Carl summons **at most one** light — a focused second read,
not a committee (he may skip it on a trivial change and note that he did).

Carl emits the light spawn as an **intent-labeled delegate action** — the Agent-tool
`description` **is** the action label: **`light review: <soul>`**. (`bin/pr-review`
prints the same label on the deterministic path.) The spawn's label keeps the
structure legible; the review tree nests the light under Carl.

**The split is role, not just depth.** **Carl, the PRIMARY, is the review OWNER**:
he runs the gates (`bin/dor-check <task> --gate-role review` / cert / CI /
acceptance) and **drives the verdict** (merge-ready or request-changes). The
**LIGHT is a focused second read** through its domain lens that **reports up to
Carl**: it does **not** run the gates and does **not** drive the verdict — though
**any reviewer can block** on a defect.

**The review is the task's G2 Review gate**
([`gates/g2-review.md`](gates/g2-review.md)): two task-grain lanes,
`g2a_primary` + `g2b_light`, opened as the pair launches and each closed from
its own reviewer's scout report (`merge-ready` = passed). Carl's
gate-zero runs with `--gate-role review` so its verdict opens+closes its own
`dor_review` gate instead of touching the builder's G1 Cert or a G2 lane.
`bin/pr-review` posts all of this
automatically; on a hand-run review Carl posts the same markers with
`bin/gate` (the exact commands are in the gate doc).

**Each reviewer narrates their review as their own soul** so the Agent column
attributes it to them, not to the base session mascot:

```bash
bin/agent-activity start --category Verify --agent <soul> --task <task-slug> --reason "review: <task-slug>"
# … diff, checks, tests, DoR …
bin/agent-activity end --outcome "<verdict>: <one-line reason>"
```

> The **`--agent <soul>`** and **`--task <slug>`** flags are live (task
> `agent-attribution-on-events`). A reviewer that omits `--agent` falls back to
> the session's **base mascot** — the review still narrates, it just attributes
> to the mascot instead of the soul. `bin/pr-review` interpolates both flags
> into each reviewer prompt automatically.

Each reviewer goes through the review cycle and **responds with concise notes**:

- **diff vs. acceptance** — the change does what the task's acceptance criteria say.
- **checks / tests** — the shape's DoR **base** tiers are green in `checks_run`;
  `bin/dor-check <task> --gate-role review` passes (Carl's gate-zero —
  its verdict opens+closes its own `dor_review` gate, never the builder's G1 or
  a G2 lane).
- **code standards + code smell + scalability** — Carl goes deep here
  (Opus on `migration` / `payment` / `solana` / `auth`); the LIGHT gives a focused
  second read.
- **docs** — behavior/env/ports/auth/deploy changes carry doc updates.

### The prior-art obligation — before you say a change EXPOSES anything

**Whoever asserts that a diff introduces, exposes, or widens a risk owes the
prior-art check first.** Not "is this bad?" — *was it already there?* Answer
three things before the words "introduces", "first consumer", "now user-visible",
or "makes it reachable" go into a finding, a block, or an advisory:

1. **Did this surface already exist here?** Read what the diff REPLACED, deleted
   files included — `git show origin/accepted:<path>` and `git diff --diff-filter=D --name-only origin/accepted...HEAD`.
   A moved or adopted view is not a new view.
2. **Under what controls?** Same route, same CSP, same auth, same data — or different?
3. **What actually CHANGED?** State the delta in one line. "Net exposure change:
   zero" is a complete and valuable answer.

If you did not look, **say so in those words** — `prior art: not investigated`.
A finding that omits prior art does not read as silent; it reads as *"none"*, and
the reader will act on that. When you file the finding, record the answer:

```bash
bin/triage file --title "…" --body "…" --repo <app> --source <soul> \
  --prior-art none                       # I looked; the surface is new here
bin/triage file --title "…" --prior-art "TM's deleted preview view carried the identical iframe since 2025-11"
# omit --prior-art entirely -> recorded as "unknown" (nobody looked), and it says so
```

**Why this is a rule and not a nicety.** `finding-84205478cca3` correctly flagged
an unsandboxed engine preview iframe and correctly noted the hub was safe (zero
registered preview builders). It travelled without the prior-art question. The
next reviewer inherited that framing and filed `finding-6a5fdcd157b3` — "the
first consumer where the iframe actually renders", "the adoption PR makes it
user-visible". **Both false.** turf-monster's *deleted* view had carried the
identical unsandboxed iframe, at the identical URL, over the same 8 previews,
under the same production CSP. Net exposure change: zero (corrected as
`finding-8b29dc565d28`). The error direction is what makes it a rule: it
inflated urgency on a long-standing defect while implicating a same-day ship,
and it was caught only because a deletion-parity check forced someone to read
code that no longer exists.

Reviewers may also broadcast in-app progress with
`POST /api/v1/tasks/:slug/review_events` (primary = `primary` swimlane, light =
light swimlane) — see [`parallel-agent-devops.md`](parallel-agent-devops.md#picking-the-domain-light-binreviewer-select).

## Step 3 — Any reviewer can BLOCK

**A block is spent only on a REACHABLE regression** — a correctness, security,
or data-loss defect someone can actually hit, or an acceptance criterion the
diff does not meet — named with its trigger. A zap-scale finding is **fixed
forward** on the PR branch instead ([`zap-protocol.md`](zap-protocol.md)
reviewer seam, verdict stays merge-ready); scope/style/hardening ideas ride as
`bin/task note --comment` entries; metadata gaps the reviewer repairs with
`bin/task update` and proceeds. If a block is earned, **any** reviewer marks
the task blocked — one complete send-back, then the session moves on
(block-and-move: one block never holds back the PRs that passed):

```bash
bin/task block <task> --kind rework --summary "<4-6 word headline>" --feedback "<what is wrong + why>"
```

**Two-bounce circuit breaker:** a task that already carries a prior send-back is
never re-blocked to the builder. Read it with `bin/task bounces <task>`: **exit 0
= CLEAR is the only exit that authorizes a re-block**, 10 = TRIPPED, and any
other non-zero is a FAILED read or an unknown slug — never a zero. `bin/task
block --kind rework` runs the same check and refuses the
second bounce on its own. It counts the task's `qa_feedback` activity rows, one
per bounce, classified by the kind stamped on each; never probe the live block
columns, which a compliant resubmission wipes exactly when the breaker must fire.
On TRIPPED, escalate instead (`bin/task block <task> --kind dependency --summary
"Escalated: <disagreement>" --feedback "<both positions>"`) and flag it
**⚠ Escalated** in the run handoff; a review deadlock is the operator's call. A
MECHANICAL bounce (red CI, merge conflict) proceeds on `--breaker-ack "<reason>"`,
which records the reason on the row.

`--summary` is the short headline the task header shows; `--feedback` carries
the full detail the builder fixes from. Omit `--summary` and the header derives
one from the feedback's first line, so legacy blocks still read clean.

That returns the task to the builder as a fresh feature-agent cycle (block notes
land in the task activities as `qa_feedback`). Surface each blocking event in the
run handoff as a **❌ Block Resolved — <slug>: <reason>** line ("resolved" =
recorded and routed back, not fixed); omit that section entirely on a clean run.

## Step 4 — Verdict

**Carl, the review OWNER, collects the light's read and drives the verdict**; his
deep review carries the most weight, the LIGHT adds a focused second perspective.

- **Merge-ready** (no reviewer blocked) → **Carl merges the feat PR into
  `accepted`** — revalidate the head, `gh pr merge --merge --match-head-commit`,
  `bin/task merged <task> accepted`, then `bin/task move <task> reviewed --actor
  carl` (merge → stamp → move; the task is `reviewed` iff its code is on
  `accepted`) — **and stops there.** Review is **review-only**: Carl does NOT run
  `bin/release merge` and never touches `release`/`main`. Avi's self-healing
  **`qa-release`** (`bin/release prepare`) sweeps the whole reviewed queue, promotes
  the **ONE `accepted → release` batch PR per repo** (stamping `merged: "release"`),
  and flips members to `assembled` only on QA-green. **Bias to action: a clean
  merge-ready verdict = go** — the sweep follows promptly, and `accepted`/`release`
  are recoverable by revert. The **sweep → QA → ship** pipeline continues from there
  (`devops-cycle-design.md` §1.4).
- **Any block** → the task is at `blocked` (Step 3), out of the pipeline until the
  builder resubmits.
- **Low confidence** (humility valve) → a reviewer marks `conductor-review` and
  routes to a human Carl / Avi / Steffon session instead of merging.

## At a glance

One `review-one <task>` run, start to finish (the loop that fans this across the
`submitted` queue = `pr-review`, §1.4):

| # | Actor | Agent (`subagent_type`) | Does | Records |
|---|---|---|---|---|
| 1 | **Session Pokémon** (orchestrator — never reviews) | base mascot | `bin/task claim-next-review` → spins one Carl per PR | claim lease on the task |
| 2 | **Carl** (PRIMARY — review OWNER) | `carl` | product-acceptance + gate-zero (`--gate-role review`); deep review; **owns the gates** + **drives the verdict**; **summons one LIGHT** (`light review: <soul>`); on merge-ready **merges the feat PR into `accepted`** (runs `pr-review-primary.md`) | review intent (pair) on the task; opens the `dor_review` gate-zero + the G2a lane; `submitted → reviewed` + `merged: accepted` |
| 2 | **LIGHT** | domain soul | focused second read through its domain lens; **reports up to Carl**; no gates, no verdict-drive (runs `pr-review-light.md`); Carl's **child** | `Verify --agent <soul>` activity + notes; closes the G2b lane |
| 3 | any reviewer | — | block on a defect | `bin/task block --kind rework --feedback` |

## Where this plugs in

- [`../system/devops-cycle-design.md`](../system/devops-cycle-design.md) §1.2 /
  §1.4 — the canonical stage ownership and the `Review submitted PRs` building
  block; this module is its formalized, agent-role how-to.
- [`../agents/carl/sops/pr-review.md`](../agents/carl/sops/pr-review.md) and
  [`../agents/carl/sops/pr-review-slow.md`](../agents/carl/sops/pr-review-slow.md)
  — the Carl-owned SOPs that run this cascade unattended, spinning one Carl per PR
  who runs the
  [`pr-review-primary.md`](../agents/carl/sops/pr-review-primary.md) and summons the
  [`pr-review-light.md`](../agents/carl/sops/pr-review-light.md) role SOP.
- [`parallel-agent-devops.md`](parallel-agent-devops.md) — the `bin/reviewer-select`
  mechanics, review-events API, and broader queue/scout context.
- [`review-comment-taxonomy.md`](review-comment-taxonomy.md) — which activity type
  (`comment` / `clarification` / `qa_feedback` / `handoff`) a reviewer's note uses.
- [`heartbeats.md`](heartbeats.md) — the launcher map that invokes this review
  cascade as Review round 1.
