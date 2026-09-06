# QA Release

## Status: Active

This is Avi's `qa-release` SOP. It is the self-healing release prepare sweep:
detect reviewed work and release stragglers, promote `accepted → release` via ONE
batch PR per repo (review already merged each feat PR onto `accepted`), allocate
each gem member's version + publish it + bump consumer locks (producer-first,
before anything tests or deploys), run the pre-QA gate, deploy QA, and flip
members to `assembled` only on QA-green. `qa-deploy` is the legacy name for this
same act.

## Scope

Avi owns release stages 1-3 as the **assembler** (`ReleaseConductorClaim` role
`assembler`):

1. Testing
2. Assembling
3. Deploying QA / Live on QA

This SOP stops at the Avi -> Steffon handoff: the release candidate is live on
QA and ready for Steffon's `production-deploy` (deployer) act. It does not ship
production.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

The sweep runs under the **default agent GitHub App identity**
(`github.mcritchie-agent`) — it opens and merges the batch promote PRs, which
the deployer identity deliberately cannot. Two auth legs, and they are not
interchangeable: git pushes ride the global credential helper
(`bin/gh-app-git-credential`); the sweep's `gh` calls (`gh pr create`/`merge`)
ride a per-session minted token — before the sweep, export:

```bash
export GH_TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | \
  /Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential get | \
  sed -n 's/^password=//p')
```

Do not export `GH_APP_ITEM` here; that override belongs to Steffon's
`production-deploy` ship lane only — and it is not advice, it is the mechanism:
the helper above reads `GH_APP_ITEM` and mints whatever identity it names, so a
leftover ship-lane export makes this command hand the sweep the **deployer**
token, which has **no `pull_requests` grant** and cannot open or merge the batch
PR. If `gh pr create`/`merge` fails with `Resource not accessible by
integration`, that is what happened: `unset GH_APP_ITEM`, re-run the export
above, then re-run `bin/release prepare` — it resumes.

(1-hour TTL. A mid-sweep **401 `Bad credentials`** means the token expired —
re-mint. A **403 `not accessible by personal access token`** means `GH_TOKEN`
is unset or empty and `gh` fell back to the stored PAT — re-mint. Never print
it.)

The shorthand for that re-mint is `eval "$(bin/gh-auth-refresh --export)"`: it
resolves **this lane** (agent here, because `GH_APP_ITEM` stays unset), refreshes
both stores, and verifies by read-back. It is **self-service** — never stall the
sweep to ask Mr. McRitchie for a token, and never fall back to `gh auth login`,
which `gh` refuses outright while `GH_TOKEN` is set. Architecture and
symptom→fix: [`source-control.md`](../../../modules/source-control.md).

Use the production board by default. Do not add `--local`.

## Assembler claim — automatic, on the RELEASE record

The lock that stops two `qa-release` sessions from both merging onto `release` and
racing the candidate N-behind (the parallel-conductor bug) now lives on the RELEASE
RECORD, not on a per-role `steffon` shift. **`bin/release prepare` takes it for you** —
the per-release `assembler` conductor claim (`ReleaseConductorClaim`) — BEFORE the
irreversible `accepted → release` promote, over the fast HTTP claim path, spawns a
detached renewer for the sweep's whole life, and releases it on completion. There is
**no `bin/devops-shift acquire steffon` step any more.**

What you will see when a second session is already assembling:

- **Stand down** — `bin/release prepare` prints `🛑 <release> assembler already held —
  STAND DOWN`, names the holder, and **aborts (exit non-zero) before anything merges or
  deploys**. Announce the holder and STOP; its lease lapses ~120s after that session
  stops if it truly died, and a re-run then resumes.
- **Resume** — if YOUR OWN earlier prepare was interrupted, re-running `bin/release
  prepare` re-acquires the same claim (same session + nonce = a no-op renew) and picks
  up where it left off.
- **Fail-open** — a claim-transport hiccup never wedges the sweep; `bin/release`
  proceeds unclaimed rather than blocking on telemetry.

Because the lock is on the release record (which turns over each release), a stale or
ghost claim can never strand the whole qa-release lane again — the failure the old
`steffon` shift lease could suffer. (Background — not needed to execute: the design is
`docs/agents/system/devops-shift-lease.md`, section B.)

### And a LOCAL presence claim, automatic, on THIS MACHINE

The assembler claim above is a **board** claim: it answers *"is a release live"*
to every machine, on a TTL. It does not answer *"is this machine saturated"*,
and only the second question decides whether the agent at the next desk may
launch a suite. That gap cost a measured 45-minute full-suite run — SIGTERMed
at its 2700s ceiling, 11% complete, killed by a sweep no status command
reported (`docs/agents/system/agent-presence.md`, cost #3).

So `bin/release prepare` now also publishes a **local** claim beside the board one, in
the session-marker namespace at
`<projects>/.agents/sessions/<key>.presence-sweep-<pid>`, carrying `kind: sweep`,
`lane: release:prepare`, a phase, a weight, and the OS's `(pid, lstart)` identity for
this process. (It records its OWN pid as the group it speaks for, never the
group it was launched in — a conductor inherits the launching shell's group,
and a claim naming that group reads as alive long after the conductor is
dead.) A peer reads it with `bin/agent-presence`. Nothing here needs running
by hand:

| | |
|---|---|
| Opened | at the top of `bin/release prepare`, before the first `git`/`gh`/board call |
| Weight | `light` while the conductor works; `suite` inside work THIS box runs; `idle` while parked on a GitHub Actions poll |
| Cleared | on graceful exit — **an optimization only** |
| On a kill | the file stays, by design, and the reader grades it a corpse on the very next read. No TTL to wait out |
| Disarm | `RELEASE_PRESENCE=off` |

**What counts as a `suite` is read from the registry, not hardcoded.**
`config/devops_test_suites.yml` already gives every release scope a `host:` and
a `tier:`, and the weight derives from them: a scope is `light` only when its
host is not `local` **and** its tier executes elsewhere (`smoke`, a curl poll;
`hook`, a `heroku run`). Everything else costs a full suite, including anything
unrecognised. So the `/up` polls and the post-deploy hooks no longer claim this
box is busy while a Heroku dyno does the work, and a scope added later declares
its cost by declaring the metadata it must declare anyway.

**Two conductors do not fight.** A `prepare` and a `ship` may legitimately run
at once; the marker is keyed per process, so both publish and a peer sees the
machine's real combined cost.

**It changes nothing about certs.** The claim lives in the session-marker
namespace, which `bin/agent-presence` reads and `CertOrphanGuard.preflight`
never touches — *read here, reaped nowhere*. So a live conductor cannot refuse
a `bin/fast-check` / `bin/full-suite-check`, cannot have a reaper pointed at
its process group, and cannot make a cert print a `kill -TERM` line naming a
production deploy. Certifying from a primary checkout during a sweep behaves
exactly as it did before this existed.

## Preconditions

There is work to prepare:

- `reviewed` tasks waiting to ride the next release candidate
- `assembled` stragglers not riding the current candidate
- an interrupted release candidate already in flight

If nothing is waiting and no candidate is in flight, report "nothing to prepare"
and stop.

## Disposition — which applications ride this candidate (Avi curates)

**The default is to ship ALL reviewed work.** `bin/release prepare` sweeps EVERY
`reviewed` task (+ any `assembled` straggler) across every application and opens
ONE `accepted → release` batch PR per repo. On the happy path you take the whole
reviewed queue and this step is a no-op — do not hold work back without a reason.

**You (Avi, the assembler) decide which APPLICATIONS go in when order-of-operations
matters.** Some releases must not carry every app at once: a gem has to publish
before its consuming app can ride the bumped lock; an app depends on another app's
release landing first; a risky app should wait a cycle. In those cases curate the
candidate by APPLICATION:

- **Make the decision board-visible first.** Mark the reviewed tasks of an app you
  are holding back `included_in_release: false` (via the board, or `PATCH
  /api/v1/tasks/<slug>` with `{ "devops": { "included_in_release": false } }`).
  The reviewed-stage card then shows an amber **HELD FROM RELEASE · <app>** marker
  instead of the green **IN RELEASE**, so the disposition is legible on
  `/deployments` before anything merges. Leave the apps you ARE shipping at the
  default (unset ⇒ included ⇒ green marker).
- **Then sweep only the included apps.** Pass the tasks you ARE shipping to
  prepare: `bin/release prepare --task <slug> [--task <slug> …] --yes` sweeps just
  those (and lands ALL of `accepted` for their repos). Omit `--task` to sweep
  everything (the default). A held-back app's reviewed work sits on `accepted`, so
  that repo reads AHEAD — expected, and prepare's accepted-coverage guard (step
  4a-bis) is scoped to the repos this release's own members name so it never
  refuses the hold-back for it.
- **Eject a member that must not ride after a candidate has formed** with
  `bin/release eject <task> --feedback "<reason>"`, then re-run `bin/release
  prepare --yes` so the rest of the candidate rides.

The `included_in_release` flag is the RECORD of your disposition (it drives the
board marker and `Task.reviewed_release_inclusion`); the `--task`/`eject` controls
are what actually shape the sweep. Keep the two in sync so the board never says
"shipping" for an app you ejected.

## Procedure

**Direct-drive this act — do NOT delegate it to a subagent.** Run
`bin/release prepare --yes` in the conductor session itself. Do NOT wrap it in an
Agent-tool subagent (`subagent_type: avi`) for sub-agent-tree visibility.

- **The rule.** Any op that MUTATES shared state across many minutes —
  `qa-release`, `production-deploy`, `archive-shipped` — is DIRECT-DRIVEN by the
  conductor session, never handed to an ephemeral subagent. Subagents stay
  first-class for **read** fan-out (reviews, audits, searches, exploration), where
  a detach costs a retry rather than a half-applied mutation. Parallel fan-out is
  still the default for devops; the line is **mutating vs reading**, not *parallel
  vs serial*.
- **Why — learned the hard way (2026-07-11).** This SOP once told you to summon
  the sweep as a Steffon subagent. That subagent DETACHED mid-sweep and left a
  **partial release candidate**: one PR merged onto `release`, but nothing gated,
  deployed, or assembled, and no attached terminal to notice or finish it. The
  candidate just sat there. `production-deploy` was already direct-drive for
  exactly this reason; the lesson generalizes to every long mutation.
- **Visibility is not a reason to delegate.** The durable, full-visibility surface
  is the Activities timeline — narrate the act there
  (`bin/agent-activity start/next/end`). The sub-agent tree is ephemeral (it dies
  with the session) and the autonomous heartbeat has no terminal, so it renders no
  tree at all.

Review has already merged each feat PR into `accepted` (stamping `merged:
"accepted"`), so the sweep no longer carries per-task feat PRs — the accepted-
ladder retarget stopgap is retired. `prepare` opens/merges ONE `accepted →
release` batch PR per repo instead.

Run the self-healing prepare sweep:

```bash
bin/release prepare --yes
```

`prepare` owns the whole QA-release act:

1. Detect every `reviewed` task plus any `assembled` straggler.
2. Open or resume the release candidate.
3. **Promote `accepted → release`**: for each repo with reviewed work, open (or
   reuse) ONE `--base release --head accepted` batch PR and merge it — landing ALL
   of `accepted` on `release` at once, not N per-task merges. Idempotent +
   fail-closed: if `accepted` is level with `release` it skips the PR but still
   records + deploys. Then record membership (re-stamping `merged: "release"`),
   skipping work already stamped `merged: release`/`main`. A `reviewed` member
   with no `merged` stamp (`merged: ""`) is a HELD anomaly — review never landed
   its feat PR on `accepted` — so it is warned and left `reviewed` (re-review to
   heal), never swept onto the RC.
3b. **VERIFY the promote reached the candidate** — the stale-tree gate, and the
   first thing the deploy half does. For every three-rung repo in the deploy
   plan it re-reads `origin/release..origin/accepted` and REFUSES unless
   `release` already carries `accepted`. This is not a second copy of step 3's
   read; it asserts step 3's EFFECT. Step 3 chooses which repos to promote from
   BOARD STAMPS (candidates stamped `merged: "accepted"`), so a commit that
   reached `accepted` with **no task stamped for it** — a conductor zap onto the
   sanctioned seam, a hand-merge, a review whose stamp never landed — is
   invisible to it, the promote is skipped, and every step below used to succeed
   on the OLD tree and print `✓ Assembled`.
   **The abort now names WHICH of those it is.** A merge commit carries its
   branch (`Merge pull request #N from …/feat/<slug>`), and `<slug>` IS the task
   slug by construction, so the gate looks the task up: when it exists but is
   unstamped the refusal says **LOST STAMP**, names the task, and prescribes the
   two-command repair instead of the hand-landed batch PR. Only a commit no task
   owns still gets the generic three-cause text. That happened live on 2026-08-11:
   `accepted` at `ed4d16a`, `release` at `b032e58`, one commit stranded, QA
   serving the previous tree, and both sentences prepare printed were true of a
   tree that did not contain the fix.
   It **refuses rather than promoting**, even on an `assembled` candidate, and
   the refusal prints the stranded SHAs plus the exact recovery (see the
   **STALE TREE** row in the abort table below). A rung it could not read counts
   as stale — a failed read is not a clean read. A dry run takes no fetch, so
   the gate runs live only, and a normal sweep just promoted, so it measures
   level and rides straight through.
4c. **Merge `main` forward into `release`** in every app **and gem repo**, so the
   branch about to be gated CONTAINS what is already live in production. Without
   it a hotfix pushed straight to `main` **blocks the ship**: `bin/release ship`
   advances `main` with a non-forced ref push, so git refuses the
   non-fast-forward. (It is never reverted — the cost is a whole candidate
   gated, QA'd, and assembled without a fix that is already in production, then
   a ship that dead-ends.) The merge runs in a detached workspace (a dirty
   primary is irrelevant to it), every step is checked, and containment is
   re-fetched and read back afterwards — a conflict, a failed push, or a push
   after which containment still does not hold all **abort**. It runs BEFORE the
   gate so the SHA the gate certifies is the SHA that deploys, and BEFORE the
   gem publish (step 4d) so a conflict aborts with zero gems published and every
   gem publishes the post-merge tree — a gem published from a pre-merge tree
   would lack a main hotfix forever, because a RubyGems version can never be
   re-pushed and ship's publish skips an already-live version. On a conflict:
   resolve it on a branch off `origin/release`, merge `origin/main` into it,
   push to `release`, then re-run `bin/release prepare` — it resumes.
   **Do not `reset` `release` to "clean up" an aborted sweep** — the batch
   `accepted → release` merges, any earlier repo's merge-forward, and (on a
   resumed sweep) a prior run's gem publish have already landed.
4d. **Allocate gem versions, publish gem members, bump consumer locks — BEFORE
   the gate and QA** (producer-first — a RubyGems push can never be re-pushed).

   **Each publish is gated on GitHub's CLEAN-ENV verdict for the exact tip it
   would push**, and fails closed. The gem's own `bin/release-check --build`
   still runs first and still aborts first when it is red — but it runs on the
   conductor's machine, and a local green is not evidence about anyone else's.
   Every other shippable tip here earns a clean-env verdict before it moves; the
   gem is the one artifact that cannot be rolled back, so it earns one too.
   Pending and not-yet-started both WAIT (the sweep normally arrives before CI
   finishes); a terminal non-green, or a poll that times out, aborts with
   **nothing published** and the version still free. If it stops here, watch the
   run named in the abort, fix or re-run it, then re-run `prepare` — it resumes.

   **Phase 0 ALLOCATES the version, so you never type one.** For each swept gem
   prepare derives the bump from the candidate's membership (`breaking` risk tag
   → major, else a `feature` member → minor, else patch; a member's `gem_bump`
   overrides), advances the **last published** version — the higher of the last
   `v*` tag and the highest version live on RubyGems — and commits the
   `version_file` **together with its `Gemfile.lock`** onto `origin/release`.
   The lockfile rides in the same commit because studio-engine bundles itself as
   a path gem and CI installs frozen: a version commit without its lock fails
   `bundle install` before a single test runs. Phase 0 decides for EVERY gem
   before writing to ANY of them, and it **refuses rather than guesses** — an
   unreadable `gem_bump`, an unparseable last version, a `version_file`
   declaring its version twice, or a `bundle lock` that did not land the number
   all abort with nothing written and nothing published (see the GEM VERSION
   ALLOCATION REFUSED row below). It is idempotent: a version already past the
   last published one is left alone, so re-runs never burn a second number.

   Phase 1 **preflights EVERY swept gem before the first push**: a fail-closed
   fetch of `origin/release` (a stale ref must never drive an irreversible
   decision), the `version_file` parses, the **stranded-work guard** —
   `origin/release` ahead of the last published `v*` tag while the version did
   NOT advance past that tag (compared with `Gem::Version` semantics, so
   **equal, backward, and unparseable versions all block**; a backward version
   would otherwise "skip as already live" and rewrite consumers DOWNWARD into a
   production downgrade with every gate green). Phase 0 normally leaves this
   guard nothing to catch — it stays armed as the **backstop** for allocation
   being skipped or wrong, and if it fires, see the STRANDED GEM WORK row in the
   abort table below. Plus a consumer-coverage check —
   **unless the gem is self-gated** (gem-only-deployments): a gem carrying a
   `release_check` in `config/release_repos.yml` (studio-engine) is its OWN
   release candidate — its suite is the verdict and the RubyGems publish is its
   prod deploy — so it may be published with **no consuming app** in the sweep,
   and a **self-gated gem-only candidate is now allowed** (it gates at G3 on its
   own CI, step 5). A **non-self-gated** gem (one with no `release_check`; none
   registered today — solana-studio was the last, and it registered
   `bin/release-check` on 2026-08-20 when it grew a Rails engine)
   still requires a swept consuming app whose Gemfile declares it — a
   non-self-gated gem-only candidate, or a non-self-gated gem no swept consumer
   bundles, would assemble QA-green untested and still aborts. ANY
   failure aborts loudly with every finding named and **zero gems published**.
   Phase 2 then publishes each validated gem's `origin/release` version to
   RubyGems (skip-if-live, so re-runs are safe) and commits each consumer
   app's `Gemfile.lock` bump (`bundle lock --update <gem> --conservative`; the
   Gemfile pin is rewritten only when the new version escapes it) onto the
   consumer's `origin/release`. **The bump is VERIFIED, not assumed**: `bundle
   lock` exits 0 whether or not it could see the version we just pushed, so the
   sweep reads the version back out of the lockfile and only commits once it
   matches. A stale resolution — the compact index bundler resolves through has
   not caught up — is RETRIED on the same 3-attempt backoff a failed bundle
   gets, and aborts only once that ladder is exhausted. (Before this, an
   unchanged working tree was read as "already at the new version" and
   turf-monster rode QA on the OLD engine while the release record asserted the
   new one — rel-20260809-3b8f3d.)
   **The bump carries any new ENGINE MIGRATIONS with it.** `<engine>:install:
   migrations` is a manual step Rails hands the consuming app, and every consumer
   asserts it was taken (`EnginePinContractTest`). Since the publish happens
   BEFORE the pre-QA gate runs those suites, an engine release that adds a
   migration would otherwise redden every consumer after the point of no return —
   measured on studio-engine PR 169, where that assertion fired in all three
   consumer lanes. So the same commit that bumps the lock also runs the installer,
   runs `db:migrate` against a THROWAWAY database purely so `db/schema.rb` lands
   with the migration (a copied-but-unrun migration is pending, and Rails refuses
   to run a suite with one), and commits both.

   **It installs the workspace bundle first, and it refuses to guess.** `bundle
   lock` resolves without INSTALLING and nothing else in the sweep installs the
   version just pushed, so without that the app cannot boot and every probe reads
   as "this gem ships no migrations" — a silent skip, with no log line, while this
   SOP told you they were handled. A non-zero probe is now an ABORT, not a skip.
   It fails closed twice more: a schema dump that removes or rewrites anything
   beyond the version stamp means that repo's committed schema was already behind
   its own migrations, and a Postgres consumer whose throwaway database cannot be
   derived stops rather than run against the gate's own.

   The pre-QA gate and the QA deploy then read
   the post-bump SHA, so QA tests the real published gem and prod ships the
   exact tree QA tested. Note: a publish is irreversible — a QA bounce can
   orphan a published version; the fix bumps past it (a dead number on
   RubyGems is harmless).
5. Run the pre-QA gate on `origin/release`. **GitHub CI's conclusion for that
   exact SHA IS the verdict** (DevOps v2 Phase 3 — the local isolated-workspace
   suite is deleted at this gate; nothing runs on your machine): the gate reads
   the SHA's check-runs, **polls** a not-yet-concluded run (a just-merged tip is
   normally `pending` for a few minutes), passes on exactly one state — green —
   and fails closed on everything else. Before polling it may **credit** an
   existing green for the same commit or for the accepted head's **identical
   tree** (the live batch-PR merge re-runs a tree the accepted seam already
   greened); a credited pass names its source in the gate note and changes
   nothing else — red, pending-evidence, and diverged trees (a gem sweep's
   lock-bump commit from step 4d) poll exactly as always. On green it RECORDS
   what it certified (SHA + command + CI verdict), which is the only thing the
   G4 ship gate will accept as grounds to skip its own gate. The gate reads the
   same CI the app path does for a **self-gated gem in a gem-only release**
   (gem-only-deployments): its `accepted→release` promote PR is a `pull_request`
   run engine-ci greened, so the gem's release SHA earns the identical-tree
   credit exactly like an app, and the gate records the gem's `release_check` as
   the certified command. (A gem RIDING an app gets no extra gem gate — it is
   QA'd through its consumer.) A red gate, and
   what to do about it (hint: **do not** blank the registry's `qa_test_cmd` —
   that silently disarms the production gate):
   [`../../../modules/gates/g3-candidate.md`](../../../modules/gates/g3-candidate.md).
6. Deploy QA and wait for boot (gem members are not QA-deployed — they were
   published at step 4d and are QA'd through the consuming app's bumped lock; a
   **gem-only release has no app QA deploy at all** — it assembles on its G3 CI
   verdict, and the /deployments board shows a **GEM-ONLY** badge with the
   published `💎 <gem> <version>` as the deployment artifact).
7. Flip members from `reviewed` to `assembled` only after QA is green.

`prepare` also narrates the release's **stage timeline** as it goes — its
conductor checkpoints (`assemble_release started/completed`, `deploy_qa
started/completed`, `qa_smoke started/completed`) stamp the release's stage
timestamps, which drive the /deployments tracker live: Assembling yellow →
Assembled green → Deploying QA yellow → **Live on QA** green. (Node 1 Testing
greens on its own the instant your first sweep stamps `assembling` — the
candidate doesn't exist before qa-release opens it, so nothing lights it
earlier.) You post nothing extra on the happy path.

`prepare` records its test verdicts as the **G3 Candidate gate**
([`../../../modules/gates/g3-candidate.md`](../../../modules/gates/g3-candidate.md)):
it opens the release's `g3_candidate` attempt (under the assembler actor
`bin/release` records) before the
pre-QA gate, collects every test SOP in the window (`pre_qa_gate` per app,
`qa_up_smoke` boot polls, `qa_post_deploy` hooks), and closes it `success`
beside the QA-green flip — or `failed` on a boot failure or any in-window
abort. Attempt-aware: a re-run opens attempt n+1, so repeated QA failures show
as a `×n` badge on the /deployments **G3 Candidate** column (which replaced
the old `review_tests`-bracketed "Tested" column). All gate writes are
best-effort and automatic — post nothing by hand.

Smoke QA after prepare reports success:

```bash
curl -fsS https://qa.mcritchie.studio/up
```

If a run was interrupted and a stage boundary went unrecorded, backfill it via
the release events API (`docs/agents/modules/task-board-api.md`, "Release stage
timeline") — e.g. `POST /api/v1/releases/current/events/qa_deploying/complete`
once QA is verifiably live. Stamps are first-write-wins, so a re-post is a safe
no-op.

If the pre-QA gate identifies an offender, eject that task instead of forcing the
candidate forward:

```bash
bin/release eject <task> --feedback "<specific failing evidence>"
```

Then re-run `bin/release prepare --yes` so the rest of the candidate can ride.

## Recovery — an INTERRUPTION and an ABORT need OPPOSITE responses

**Diagnose which one you have BEFORE you re-run.** `prepare` is self-healing, but
self-healing means it RESUMES work that was cut short — it does not fix work that
FAILED. A re-run skips the merges it already did and re-tests/re-deploys **the same
member code**, so re-running a red candidate goes red again, the same way, forever.

- **INTERRUPTION** — no verdict: a detached agent, a killed terminal, a timeout, a
  crash. Work is half-applied. **Re-run it.**
- **ABORT** — `prepare` reached a verdict and refused: a red pre-QA gate, a failed
  QA boot, a failed merge. **Fix the cause first, THEN re-run.**

The last run tells you which: an abort PRINTS its reason and its fix. If the sweep
simply vanished with no verdict, it was interrupted.

### INTERRUPTION — re-run `bin/release prepare --yes`. That is the whole fix.

Do not hand-merge, do not hand-flip stages, and above all do not leave a
half-finished candidate sitting because you are unsure whether a re-run would
double-merge. It will not:

- **Already-promoted work is skipped.** The sweep skips re-promoting any task
  already stamped `merged: release` or `merged: main`, and the `accepted → release`
  promote is crash-recovery-aware (idempotent: `accepted` level with `release` →
  skip the PR), so work that landed before the interruption is never re-merged.
- **An interrupted run leaves members `reviewed`** (the flip lands only on
  QA-green), which is exactly the state the next run detects and finishes.
- **A re-run resumes the candidate**; it does not open a second one.
- **Stage stamps are first-write-wins**, so re-posted timeline boundaries are safe
  no-ops (see the backfill note above).
- **A re-run resumes; it does not paper over.** The one case where a re-run
  REFUSES instead of finishing is a stale tree (step 3b): work reached `accepted`
  that the promote could not carry, so finishing would deploy — and report ✓ over
  — a tree missing it. That refusal is the gate working; take the **STALE TREE**
  row in the abort table below, then re-run.

### ABORT — fix the cause, THEN re-run

An abort leaves members `reviewed` (+ `merged: release`) and the release NOT
assembled — the same board state an interruption leaves, which is exactly why you
must not reflexively re-run. Each abort names its own case and its own fix:

| Abort | Fix FIRST | Then |
|---|---|---|
| **A GEM'S `version_file` MOVED AND THE SWEEP ABORTS EITHER WAY** (either "gem <repo>: <version_file> does not declare EXACTLY ONE version literal" — **phase 0b, the WRITE, not the phase-0 refusal one row down** — OR "promote refused — <repo> (suite workflow …) cannot certify `accepted`") | **The registry and the gem tree must move TOGETHER, and `bin/release.rb` reads the registry from the CONDUCTOR'S OWN checkout** (`RELEASE_REPOS`, `bin/release.rb:267`) — not from the candidate. So a self-shipping RC driven from `origin/main` reads the OLD registry against a NEW gem tree. Both mismatches fail closed and neither publishes, but **they abort in different places and say different things**, which is what makes this hard to look up:<br>**OLD registry + NEW gem tree** → allocation SUCCEEDS (it derives 0.5.0 quite happily); the failure lands one phase later, in `commit_gem_version!` at `bin/release.rb:4838`, when `rewrite_version` finds no literal to rewrite. Its message interpolates the `version_file` — so it names the **gemspec**, which is misleading once the version has moved out of it. **⚠ Do not follow that abort's own remedy here.** It says "set it to <version> by hand and commit it onto `release`", which in THIS case means hardcoding a literal back into the gemspec — re-introducing the very coupling the move exists to remove, and hand-setting a version the row below rightly warns against. The fix is to land the hub registry change.<br>**NEW registry + OLD gem tree** → the **promote** aborts in `refuse_blind_accepted!`, taking every repo in the candidate with it. This one never mentions the gemspec: it names the repo and its suite workflow, and **reads identically to the A REPO CANNOT CERTIFY `accepted` row below**. Do not apply that row's remedy here. The difference is that here the workflow is **already correct** (`gem-ci.yml` declares `push: branches: [accepted, release, main]`) and it is the GEM TREE that has not landed — editing `on.push.branches` changes a correct file and leaves the real cause untouched.<br>**Only NEW+NEW works.** Land the gem-side move and the `config/release_repos.yml` change in the SAME release, gem repo first (its workflow must be on the gem's `accepted` before the map points at it), and drive the sweep from a checkout carrying the new registry.<br>**AND EXPECT THE BUILDER'S GATE TO LOOK CIRCULAR WHILE YOU DO.** `bin/dor-check` reads the registry from ITS OWN checkout too (`bin/dor-check:991`), so until the hub change lands, the gem PR's edit to the old version_file stays REFUSED — the gem must merge first for the sweep, yet cannot clear dor-check until the hub half exists. It is not a deadlock: run dor-check from a checkout that already carries the registry change (the hub worktree holding it), and land the two together | land both, then re-run `prepare`; nothing was published |
| **GEM VERSION ALLOCATION REFUSED** (step 4d phase 0 — "REFUSING to allocate a version") | **Do not set a version by hand to route around this.** The refusal names its own cause and each has a one-line fix: an unreadable override → `bin/task update <task> --gem-bump patch\|minor\|major` (or clear it); an unparseable last published version → fix the gem's `v*` tag or its `version_file` by hand; a `version_file` declaring its version twice → make it declare one; `bundle lock` failed or left the lock on the old version → fix the bundle in the gem repo (a stale resolution is usually RubyGems propagation — wait, as in the CONSUMER LOCK BUMP row below). Nothing was written to any release branch, so there is nothing to undo | re-run `prepare`; allocation resumes |
| **STRANDED GEM WORK** (gem `origin/release` ahead of its last `v*` tag, version not advanced past it — unbumped, BACKWARD, or unparseable) | **Rare now — step 4d allocates the version, so reaching this guard means allocation did not run or was wrong.** Check the run's phase-0 output first: if it *refused*, fix that (row above) rather than the version. If you must set the number yourself, compute `next = <the tag the abort names> + bump`, where bump is **major** if any member of this candidate is risk-tagged `breaking`, else **minor** if any member has `kind: feature`, else **patch** (a member's `gem_bump` overrides). Commit it straight onto the gem repo's `accepted` — not a PR, which `bin/dor-check` refuses; no gem rung is branch-protected, and the batch promote carries it to `release`:<br>`cd /Users/alex/projects/<gem-repo> && git checkout accepted && git pull`<br>edit the `version_file` (`lib/studio/version.rb` for studio-engine, `lib/solana_studio/version.rb` for solana-studio — it moved off the gemspec on 2026-08-20; read the registry rather than trusting this parenthetical)<br>`bundle lock` **← REQUIRED when the repo tracks a `Gemfile.lock`**: studio-engine bundles itself as a path gem, so its lock names its own version and CI installs frozen — a version commit without its lock fails `bundle install` before running a test, and it is invisible locally because a plain `bundle install` regenerates it<br>`git commit -am "Release <next>" && git push origin accepted`<br>A **backward** version — the abort says `DOWNGRADE` — means a version conflict was resolved the wrong way on a merge into `release`; fix the version file forward, don't force it through | re-run `prepare`; nothing was published or deployed |
| **Pre-QA gate red — a member REGRESSION** | `bin/release eject <task> --feedback "<failing evidence>"`, then revert its merge commit on `release` (the abort prints the guidance) — as the eject step above says | re-run `prepare`; the rest of the RC rides |
| **Pre-QA gate red — ENV/toolchain** (unsatisfied bundle, Postgres down, Ruby divergence) | **Nothing to eject or revert.** Fix the environment exactly as the abort names it | re-run `prepare` |
| **QA deploy / boot FAILED** | Fix the boot failure (the summary prints the `bin/qa-server deploy …` retry); eject the member if it is the cause | re-run `prepare` **once QA boots** |
| **STALE TREE** (step 3b — "prepare refused: … would deploy a tree that does NOT contain `accepted`") | **This is the good outcome — the sweep caught itself about to report success over an old tree.** The abort prints the repo, the stranded SHAs with their subjects, and the two commands to run, filled in. Land the stranded work on `release` by hand: `gh pr create --repo <owner/name> --base release --head accepted …`, **watch that PR's CI to green**, then `gh pr merge <pr-url> --merge --match-head-commit <the accepted head the abort names>`. Do **not** hand-move `release` with a push or a reset, and do **not** go looking for a flag to make prepare promote it for you — there isn't one, deliberately: on an `assembled` candidate a silent promote would leave the recorded QA verdict describing a tree nobody tested. **READ THE REFUSAL FIRST — it now tells you which case you have.** If it says **LOST STAMP** and names a task, the batch PR above is the WRONG act: review already landed that PR on `accepted` and only the stamp is missing, so run the two commands the abort prints (`bin/task merged <slug> accepted` — plus `bin/task move <slug> reviewed` unless it is already `reviewed`) and re-run `prepare`, which then promotes normally. The batch-PR path is for a commit **no task owns** (a conductor zap or a hand-merge), which is what the refusal says when it cannot attribute the commit | re-run `prepare`; it promotes nothing new, re-gates, and re-deploys QA over the tree that now carries the work |
| **STALE TREE — rung could NOT be read** (step 3b — "a failed read is not a clean read") | The gate could not measure `origin/release..origin/accepted` for a repo it was about to deploy: a missing sibling checkout, an unfetched branch, a failed `rev-list`. Unverified is treated as stale on purpose. Clone the repo as a sibling (or `git fetch origin` in it) so the rung can be read | re-run `prepare` |
| **`accepted → release` promote failed** (a conflict on the batch PR) | Resolve the conflict on the batch PR (or `bin/task block` the offending member) | re-run `prepare` |
| **Member left `reviewed` with `merged: ""`** (review never landed its feat PR on `accepted`) | Re-review the task so `pr-review` merges it onto `accepted` | re-run `prepare` |
| **MULTI-REPO PR RECORD INCOMPLETE** (step 3a — "sweep refused … multi-repo task(s) with an incomplete PR record"; `bin/release merge` refuses the same shape at its step 2a) | The task names several repos but recorded a PR for only some of them, so the sweep can promote only the repos it can see — and used to stamp the task assembled and shipped for the rest (2026-08-13: turf-monster never left `accepted` while the board said the security patch was in production). The abort names the repo with no PR. Record it — `bin/task update <slug> --pr-url-for <repo>=<pr-url>` — or, if that repo carries no work, drop it from the task's `devops.repositories` (`bin/task update <slug> --repo …`, which REPLACES the list). Nothing was promoted, recorded or deployed | re-run `prepare`; the member sweeps with every repo it names |
| **ACCEPTED NOT COVERED BY THE PROMOTE** (step 4a-bis — "git says `accepted` carries commits for X, a repo this release's members NAME, but this sweep would promote only Y") | A repo one of THIS release's members names has work on `accepted` that this sweep would not carry, so promoting now leaves X behind while stamping its tasks assembled and shipped. Usually a member whose `merged` stamp says its code is already past `accepted` when that repo's is not — a PARTIAL earlier promote. Land it (`bin/release merge <slug>`, which fans out over every repo the task names), or drop X from the task if it carries no work; `bin/release status` prints the git and board signals side by side. **A repo NO member names is deliberately out of scope** — that is what keeps the `--task` hold-back below legal | re-run `prepare` once every member-named ahead repo rides |
| **A REPO CANNOT CERTIFY `accepted`** (inside the promote — "promote refused — <repo> (suite workflow "CI") cannot certify `accepted`") | **This is the guard that used to be missing, not a new obstacle.** The named repo's DECLARED suite workflow has no push trigger for `accepted` on `origin/accepted`, so GitHub never builds that rung — which means the RED-accepted guard immediately above it read `:none` and passed WITHOUT EVER HAVING BEEN CAPABLE OF FAILING, while naming that repo as checked. Fix it in the named repo: add `accepted` to its workflow's `on.push.branches` (`mcritchie-studio/.github/workflows/ci.yml` is the reference, and its comment explains why there is deliberately **no** `concurrency:` block — a cancelled run folds as RED to a SHA-addressed reader), then land that on the repo's `accepted`. Do **not** route around it by dropping the repo from the sweep. A repo that ships no suite workflow at all is exempt only when it DECLARES that (`Release::AcceptedCertification::GEM_SUITE_WORKFLOWS`, nil — **no gem declares nil today**; solana-studio was the standing example until it shipped a "Gem CI" lane on 2026-08-20); a repo whose checkout could not be read is reported and does NOT refuse. Nothing was promoted, recorded or deployed | re-run `prepare`; it resumes |
| **CONSUMER LOCK BUMP did not land** (`bundle lock … did not land in <repo> … resolves <old>, wanted <new>`) | **Nothing to fix in the code — WAIT.** The gem published fine; the resolver just cannot see it yet. The abort already retried on a 5s→10s backoff. Watch the surface **bundler** resolves through — the compact index: `curl -sS https://index.rubygems.org/info/<gem> \| tail -5` — until the version appears THERE. Do **not** wait on `https://rubygems.org/api/v1/versions/<gem>.json` or the HTML gem page: both are separate services with their own CDN caching, so a version showing on either is not proof bundler can resolve it. Do **not** bump the version: the gem is already published, and a bump would burn a number for nothing | re-run `prepare`; the publish skips as already-live and the bump lands |

`prepare` never force-ships a red candidate. The only ways past a real regression
are to eject it or to fix it forward — never to re-run harder.

**A member left `reviewed` on a GREEN QA run is not a bug — it is the per-repo
evidence guard.** `qa_green!` stamps a member `assembled` only when the candidate
recorded something for **every** repo that member names (a QA sha or a passing
pre-QA gate). Two kinds of repo are exempt, and both are exempt because they
**declare** it, never because their config merely looks empty:

- **gem repos** — they publish rather than deploy, so they carry neither a QA sha
  nor an ff'd `main`.
- **a repo declaring `qa_evidence: exempt`** in `config/release_repos.yml` —
  today only **turf-vault**, an Anchor program with no dyno and no URL, whose
  pre-QA gate and QA deploy are both skipped by design.

A member spanning a repo this candidate never promoted stays `reviewed` — swept,
`merged: "release"`, and picked up by the next self-healing run once its missing
repo rides — and the reason is logged as `[release-evidence] <release>: <slug>
names N repo(s) … but this release landed nothing for <repo>`. The ship has the
same guard against `metadata["shipped_shas"]`, so such a member stays `assembled`
rather than being stamped `shipped` for a repo whose `main` never moved.

**The QA exemption does NOT extend to the ship.** `bin/release ship` really does
fast-forward turf-vault's `release → main` and records the sha at the push, so
its `shipped` stamp is backed by real evidence and the ship-side guard stays
armed for it exactly as for any app.

**The `merged: "main"` stamp is NOT withheld with it** — say the half that still
bites rather than imply a clean stop. `record_merged_main` fires per repo-group
inside the deploy/publish path (`bin/release ship`), entirely outside
`Release#ship!` and outside this guard, so a held member parks at `assembled` +
`merged: "main"` — the registry's "prod-deploy in flight" badge — and keeps it.
That stamp is pre-existing and per-repo; the evidence guard withholds the STAGE,
not the git-location stamp. Fix a held member the same way as the aborts above:
get the missing repo onto this candidate, or drop it from the task if it carries
no work.

### Detecting an UNFINISHED release candidate

An unfinished RC is a candidate whose members are **merged but never assembled** —
the sweep promoted `accepted → release` (step 3) but never reached the `assembled`
flip (step 7).
Nothing is corrupt, but nothing is finished, and it is invisible unless you look:

```bash
bin/release status                      # current release + state
bin/task list --stage reviewed          # any of these merged onto release is an unfinished member
bin/task show <task> --json | jq '{stage, merged, release_slug}'
```

The smoking gun is a task stamped **`merged: "release"` while its stage is still
`reviewed`**. Compare the healthy readings:

| `stage` | `merged` | Meaning |
|---|---|---|
| `reviewed` | `null` | Waiting to be swept — normal. |
| `reviewed` | `"release"` | **UNFINISHED — merged, never assembled. Diagnose before re-running.** |
| `assembled` | `"release"` | Healthy member, QA-green. |

On the /deployments tracker the same state reads as an **Assembling / Deploying QA
node stuck yellow** with Live on QA never greening.

⚠️ **This board state does NOT tell you WHY, and the two causes need opposite
responses.** An INTERRUPTED sweep and an ABORTED (red) sweep leave the *identical*
`reviewed` + `merged: "release"` reading. Do not re-run on the strength of this
table alone — establish which one it is:

- **The release's latest G3 Candidate attempt** (the /deployments **G3 Candidate**
  column) — closed `failed` means the sweep reached a verdict and refused: an
  **ABORT**. Still open with no verdict means it died mid-flight: an
  **INTERRUPTION**.
- **The last run's output**, if you still have it — an abort printed its reason and
  its fix; an interruption printed nothing.

Then take the matching recovery above: interruption → re-run; abort → fix the
cause, then re-run.

## Exit Seam

The release candidate is `assembled` and live on QA; members are `assembled` with
`merged: release`, and the release's latest **G3 Candidate** attempt is closed
with `success`. On the /deployments tracker the release reads **three greens
(Tested · Assembled · Live on QA) with Confirming deliberately DARK** — that gap
is the handoff itself. Do NOT start or stamp `confirming`; stage 4 lights only
when Avi posts `confirming/start` as he picks the release up
(`production-deploy`). Report:

- release slug
- QA URL
- member task list
- ejected task, if any, with failing evidence
- the exact phrase "deployed to QA" for Avi's handoff

On a clean no-op, report "nothing to prepare."

## Related

- [`../../steffon/sops/production-deploy.md`](../../steffon/sops/production-deploy.md)
  - the Steffon deployer act this assembled candidate hands off to.
- [`../../steffon/sops/archive-shipped.md`](../../steffon/sops/archive-shipped.md)
  - Steffon's post-ship closeout act.
- [`../../../modules/gates/g3-candidate.md`](../../../modules/gates/g3-candidate.md)
  - the G3 Candidate gate this act produces.
