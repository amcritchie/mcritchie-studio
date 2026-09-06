# G1 Cert — the builder's certification gate

## Status: Active

G1 Cert is the first branded testing gate of the devops pipeline: the
**builder's certification that the exact code being handed off is green**. It is
a **task-grain** gate (GateRun key `g1_cert`) owned by the feature agent, run
from the task's worktree. It is a **self-closing cert**: `bin/fast-check` or
`bin/full-suite-check` OPEN and CLOSE the `g1_cert` attempt themselves (green →
success, red → failed). The Definition-of-Ready verdict (`bin/dor-check`) is a
**separate** gate now — see [`dor.md`](dor.md) — so G1 Cert is exactly the local
test/lint cert, nothing else.

The gate flow order: **G1 Cert** (this doc) → [DoR](dor.md) →
[G2 Review](g2-review.md) → [G3 Candidate](g3-candidate.md) →
[G4 Ship](g4-ship.md).

## What this gate verifies

- The shape's **DoR test tiers** are green, tier-tagged in `devops.checks_run`
  (`[unit] …`, `[integration] …`, per `config/feature_shapes.yml`).
- The **suite evidence** proves the tree being shipped is certified, via one of
  three routes (all fingerprint-bound to a git TREE hash, so a stale or partial
  record is refused):
  - **fast** (the builder default) — a fresh `[fast-cert@<fp>]` line from
    `bin/fast-check`, credited alongside a **GREEN GitHub CI** (CI runs the
    full suite + `test:system` on every PR push, so the full net still runs).
    Submit-side it is also credited **PROVISIONALLY** while the open PR's CI is
    still pending / not yet reported — see "The CI seam" below.
  - **full** — fresh `[full-suite@<fp>]` + `[rubocop@<fp>]` lines from
    `bin/full-suite-check`. Accepted on its own, CI-independent.
    A repo that DECLARES `lint_lane: none` in `config/release_repos.yml`
    (today: `studio-engine` and `solana-studio`, neither of which ships
    rubocop at all) owes only the `[full-suite@<fp>]` line — the waiver is
    declared, never inferred from a missing binary. See
    `FullSuiteGate.required_lanes`. The REFUSAL names only the lanes that
    repo owes: it is built from `required_lanes`, not the full `LANES`, in
    both the primary refusal (`suite_evidence_error`) and the secondary one
    (`secondary_cert_lane_state`), so a waived repo is never sent after a
    rubocop it does not ship.
  - **bypass** — a `[full-suite-bypass] <reason>` checks_run line. Honored but
    flagged loudly; a conscious, justified skip only.

The suite evidence, required metadata, and the PR's GitHub CI are checked by the
`dor-check` **verdict** — but that verdict now closes the separate **DoR** gate
([`dor.md`](dor.md)), not this one. G1 Cert is purely the local cert lanes.

## Who runs it

The **feature (builder) agent**, from the task worktree. The cert opens AND
closes `g1_cert` on its own — no reviewer ever touches this gate. (The primary
reviewer's gate-zero re-runs `dor-check --gate-role review`, but that lands on
the [DoR review](dor.md) gate `dor_review`, not here.)

## Procedure

Run everything from the task worktree. Order matters: **final commit → cert →
push → open the PR → dor-check → submit** (the cert fingerprint is a tree
hash; committing after the cert makes it stale — and the fast route's
provisional credit needs the PR open, so the verdict runs last, with **no CI
wait** before `submitted`).

The worktree rooting is **enforced**: given a task slug, both cert runners
verify the cwd's checkout IS the task's tree (its branch, or its desk in
EITHER layout — `<repo>/.worktrees/<slug>`, or the sibling
`<repo>.worktrees/<slug>` the gem repos use) and **refuse** otherwise. A run
from the wrong checkout (e.g. the hub primary on `main`) exits 1 instead of
green-certifying an unrelated tree, and the refusal names WHICH case it is:
the desk to `cd` into, the desks that exist but are not this task's (each with
the axis it failed), the desks that tie, or no desk anywhere
(`bin/lib/cert_root_guard.rb`).

**A cert can refuse for an ENV/CONFIG reason — that is not a red suite.** Before
any lane runs, both cert runners boot the app in the desk and prove its test
database is not the repo's **shared** one (`bin/lib/desk_guard.rb`). A cert
against a shared DB certifies nothing, and `full-suite-check`'s first lane
(`db:test:purge`) would destroy that database under every concurrent suite. The
refusal says which of two things it is — bringup did not complete
(re-provision: `bin/agent-worktree new <app> <slug>`), or the repo's
`config/database.yml` does not honour the desk's `TEST_DATABASE_URL` pin (fix
the repo, or rebase). It also refuses a **Rails** desk when it cannot prove
isolation **either way** (the app will not boot). A repo that is **not a Rails
app** — a gem or Anchor desk (`studio-engine`, `solana-studio`, `turf-vault`)
with no `bin/rails` and no `config/database.yml` — has no test DB to protect, so
the guard is inapplicable and **admits without booting**; it never refuses one
for lacking an app to boot. **None of these is a regression in your diff** — do
not go hunting one, and do not record the refusal as a failed cert attempt.

The **committed tree** is enforced the same way: given a task slug, both cert
runners **refuse a dirty working tree**, naming the uncommitted files and
telling you to commit first (`bin/lib/cert_tree_guard.rb`). The fingerprint is a
tree hash of the WORKING tree, so certifying with edits still uncommitted stamps
GREEN evidence over code the PR never receives — on 2026-07-14 a worktree's 146
lines of finished, tested work were certified and then never reached PR #537.
"Certify after the final commit" is now a rule, not a memory. (A stat-stale
index — a file rewritten with identical content, so only its mtime moved — is
NOT dirt: the guard refreshes the index before reading it, so it cannot
false-refuse a tree nobody edited.)

Both cert runners open with an **orphan preflight** (`bin/lib/cert_orphan_guard.rb`)
before any lane runs. A cert that outran its harness timeout leaves its
`bin/rails test` grandchild alive, holding the worktree's test DB — and every
retry then dies in test-prepare on `PG::ObjectInUse`, so the retry path recreates
the deadlock and the agent can never dig out (live, 2026-07-13: three attempts,
35 minutes, zero board progress). Each cert therefore leaves a runlock naming its
process group **and that group's OS start time**, and the next cert reads it:

| It finds | It does |
|----------|---------|
| a suite whose start time **matches** the runlock | **reaps** the group, names it, continues |
| a **live** sibling cert | **refuses** — two suites on one test DB SIGSEGV Ruby |
| the pgid **recycled** onto a stranger | **never kills it**; discards the lock, continues |
| a group it **cannot prove** is ours | **refuses** and names what is alive — a human decides |
| a **malformed** lock (names no integer pid/pgid) | **clears it** loudly and continues — it names nobody, so there is nobody to kill; the DB backstop speaks for a real orphan |
| a lock naming group **0 or 1** | **refuses** and leaves the lock — the lock is corrupt, no cert ever ran in those groups, and no kill would be correct. `rm` it yourself |
| a reap it **could not perform** (the suite outlived TERM+KILL, or its identity stopped matching under us) | **refuses, and KEEPS the runlock** — the lock is the only record naming that process. It offers a kill **only** when the group is still provably ours; against a stranger it offers `rm <lock>` and an `inspect` line, never a kill |

An exit-1 from the preflight is an **ENV refusal, not a red diff** — it names the
pid and the DB. Never `rm` the runlock to get past a refusal you have not read: it
is naming a process that is still holding your database.

**Every kill the cert prints is a kill it would fire.** The command in a refusal is an
instruction — it gets pasted into a shell exactly as printed — so the copy is gated on
the same predicate as the trigger (`CertOrphanGuard.reapable?`): signalable **and**
provably ours, re-proved at the moment of emission. When the guard cannot prove the
group is ours it prints **no kill at all**, because none would be correct. If you ever
see the cert suggest a kill it did not itself attempt, that is a bug — report it.

**The runlock lives in the repo's git dir** (`<git-dir>/cert-run.json`; in a worktree
that is `.git/worktrees/<name>/`, so each desk keeps its own), **never in the working
tree**. It has to: the lock's job is to SURVIVE a SIGKILLed cert, so a lock inside the
tree is an untracked file in any repo that does not ignore `tmp/` — studio-engine and
turf-vault do not — and the cert **refuses a dirty tree**. The next cert would abort
`DIRTY` on the guard's own artefact, the orphan preflight would never run, and the
deadlock above would be back, permanently. Keeping the lock out of the tree makes that
impossible by construction rather than by every repo remembering to ignore `tmp/`.

1. **Certify — fast route (default):**

   ```bash
   bin/fast-check <task-slug>
   ```

   Lanes, in order (each recorded on the gate as one executed-SOP entry):

   - `test-prepare` — `bin/rails db:test:prepare test:prepare` (abort on red —
     never certify against an unprepared test env). **Read the output; do not
     assume the cause.** A red here has three quite different meanings and
     guessing among them is what burned 35 minutes: `PG::ObjectInUse` is an
     ORPHANED suite holding your test DB (the preflight above names it — if it
     did not, say so, that is a guard gap); an asset error such as `The asset
     "tailwind.css" is not present` after a stylesheet change is a REGRESSION IN
     YOUR DIFF failing the asset build; a missing DB/role is a genuine env gap.
     Blaming "an ENV gap" by reflex is the reflex this gate exists to break.
     There is a FOURTH meaning the cert now separates by itself: the runner is
     simply **not in this checkout** (turf-vault is Anchor/Rust and has no
     `bin/rails`). That prints `COULD NOT RUN`, never "an ENV gap you can fix" —
     there is no fix, because there is nothing to prepare. The cert **refuses**
     rather than skipping the lane, since a skipped prepare certifies a repo
     whose tests never ran; a repo whose cert lane is not Rails has to DECLARE
     one, and `/tasks/turf-vault-needs-ci` owns what that lane should be. The
     same split applies to the later lanes: a missing command is reported as
     `lane(s) COULD NOT RUN`, never `lane(s) RED`.
     Both tasks, one boot: the test DB, and
     Rails' `test:prepare` hook, which is what BUILDS the gitignored
     `app/assets/builds/tailwind.css`. The lanes below pass explicit test
     paths, and Rails skips its own `test:prepare` whenever an argument looks
     like a path — so without this lane a fresh worktree red-flags every
     view-rendering test with `The asset "tailwind.css" is not present in the
     asset pipeline`. See `docs/agents/modules/testing.md`.
   - **A GEM REPO TAKES A DIFFERENT ROUTE ENTIRELY.** The three lanes below are
     Rails-app assumptions — `bin/rails`, `bin/rubocop` — and a gem has neither, so
     an unaided `bin/fast-check` used to die on an unrescued `Errno::ENOENT` before
     running a single test. A repo the registry files under `gems`
     (`config/release_repos.yml`) now runs **its own gate command** from that row's
     `release_check` (studio-engine: `bin/release-check`, measured 2026-08-26 at ~215s for 102 files /
     1491 runs), skips the Rails prepare lane that does not apply to it, and runs
     no rubocop lane. There is no diff-mapped shortcut for a gem — the registry
     command IS the suite — and the evidence line says so rather than reporting a
     subset that was never selected. So a studio-engine builder CAN use the fast
     route; this doc previously implied they could not.
   - `mapped-tests` — `bin/rails test <files the branch diff maps to>` (path
     convention with a class-name grep fallback; skipped when nothing maps).
     **CAPPED at 15 files** after the spine dedupe: past that the lane is SKIPPED
     with a loud line naming the cap and the widest-mapping file, and the spine
     still runs. A file with no convention target falls back to a word-boundary
     grep of its camelized name, and when that matches much of the suite it is
     telling you the token is generic rather than which tests are relevant —
     `config/initializers/studio.rb` mapped to 45 files and ran for 39m34s against
     this ~1-minute budget before the cap existed. For a diff that wide the right
     cert is `bin/full-suite-check`; raise the cap deliberately with
     `FAST_CHECK_MAPPED_CAP=<n>`.
   - `spine` — `bin/rails test <config/fast_cert_spine.yml entries>` (the
     always-run critical core, ~10-20s). **The list is anchored in the HUB** and
     filtered to paths that exist under the code root, so a SATELLITE checkout
     resolves NONE of it — verified 2026-09-05: all five entries are absent from
     both turf-monster and rolio. On a satellite the mapped lane is therefore the
     only lane that can run a test at all, which is what makes the guard below
     more than a corner case.
   - `rubocop-changed` — `bin/rubocop <changed lintable files>` (never the
     whole repo; skipped when none)

   **A CERT THAT EXECUTES ZERO TEST FILES DOES NOT CERTIFY.** Before any lane
   runs, `bin/fast-check` counts the test paths this run will actually execute —
   the mapped lane (EMPTY when the cap skipped it) plus the spine — and refuses
   to report green when that set is empty. **It has two verdicts, and which one
   you get depends on WHY nothing would run:**

   | the set is empty because… | verdict | exit | what happens |
   |---|---|---|---|
   | the diff maps to **NO test file** (no convention target, no grep hit) | **REFUSE** | `1` | nothing recorded, nothing pushed; remedy is `bin/full-suite-check <task>` |
   | the mapped lane was **CAPPED** (more mapped tests than the cap) | **DEFER** | `2` | a `[cert-deferred@<fp>]` receipt is recorded; `bin/ship` pushes and opens the PR; **`bin/dor-check` then requires a GREEN CI** |

   **Deferring is not skipping — the refusal MOVES, from ship step 2 to step 7.**
   A capped diff mapped to MORE relevant tests than the cap, not fewer, and CI
   runs every one of them on this exact tree in the run the PR triggers anyway;
   only the RUNNER was wrong, and we chose that ourselves for a budget reason. So
   the cert authority moves to CI, and `bin/dor-check` credits the receipt **only
   alongside a GREEN CI — never provisionally**, unlike the fast lane (a fast cert
   has a real local run underneath it; a deferral has nothing). A red CI, an
   ABSENT CI (`:none`), a CI nobody could read, and a receipt gone STALE under a
   later edit all still refuse the submit. Exit `2` is deliberately non-zero so
   every `system(...)` caller that has not been taught about deferral keeps
   reading it as "not certified".

   Why it moved at all: `bin/fast-check` runs at **ship step 2 of 8 — before the
   push, before the PR, before any CI exists**, so a refusal left the builder with
   no PR and one remedy — a local full suite MEASURED at ~30 minutes against CI's
   ~9 for the identical command. A build paid that in full on 2026-09-06, and any
   diff wide enough to trip the cap pays it (`app/services/solana/config.rb` trips
   it at 26-29 paths routinely).

   On the REFUSE path nothing is recorded and no `g1_cert` attempt is stamped; it
   is a precondition on the SELECTION, the same shape as the root, desk, and
   dirty-tree guards. On the DEFER path the receipt is the ONLY thing written —
   still no `g1_cert` attempt, because no lane ran and an attempt would report a
   testing window that measured nothing. A deferral that cannot be RECORDED
   refuses (exit 1) instead: an unrecorded deferral would push, wait out CI, and
   be refused at step 7 for want of the receipt.

   It exists because turf-monster PR #549 recorded this, verbatim:
   `fast cert green: 0 mapped (CAPPED: 26 > 15; spine only) + 0 spine test
   path(s), rubocop on 3 changed file(s)`. The mapped lane was capped, so it
   announced a fallback to the spine; the spine then resolved to zero paths. The
   gate printed **green** having run no test at all — rubocop was the only
   executed lane, and a linter cannot observe behaviour. Three of five builds
   that night degraded this way and every reviewer had to be told by hand to
   weight CI over the G1 cert.

   **Keyed on the zero, not on the cap** — deliberately. Keyed on the cap, a
   satellite diff mapping to 26 test files would be treated worse than one mapping
   to NONE, strictly less evidence, which would still certify green on rubocop
   alone. The cap decides only WHICH of the two verdicts you get, never whether a
   run with no tests may report green.
   **A capped run whose spine still ran is NOT refused**: it executed real tests
   and its evidence already reads `0 mapped (CAPPED: …)` beside the loud
   `MAPPED LANE CAPPED` narration — a narrower cert, honestly labelled, which is
   what the cap was designed to produce. A gem repo is exempt (its registry
   command IS its suite and runs as the mapped lane). **The cap itself is
   unchanged**: this alters what a capped run REPORTS, never how much it runs.

   All lanes green stamps one `[fast-cert@<fp>]` line into `checks_run`,
   merged with the existing list (tier tags and full-suite evidence are
   preserved; only a prior fast-cert line is replaced). A skipped lane is
   recorded as a pass with a `skipped: <why>` command — considered, not lost.

   Preview without writing anything: `bin/fast-check <task-slug> --print`
   (also skips every gate/board write). `--list` prints the selected test
   files and exits.

2. **Or certify — full route** (when CI can't vouch, or for release-grade
   verification):

   ```bash
   bin/full-suite-check <task-slug>
   ```

   Lanes: `test-db-reset` (`bin/rails db:test:purge db:test:prepare`),
   `full-suite` (**what CI's `test` job runs, verbatim** — read from the repo's own
   `.github/workflows/ci.yml`; today `bin/rails db:test:prepare test test:system` — which since the hub's suite was SHARDED is the single command covering CI's `rails` shards plus its `system` job, not a copy of any one CI step,
   the ENTIRE Ruby suite **including the system tier**), `rubocop` (`bin/rubocop`,
   the whole repo — the rubocop check in CI's `static` job). Green lanes stamp `[full-suite@<fp>]` +
   `[rubocop@<fp>]`.

   The `rubocop` lane is SKIPPED-BY-DECLARATION for a repo carrying
   `lint_lane: none`, and BOTH halves now honour it. The READER
   (`FullSuiteGate.required_lanes`) stops asking for the evidence, and the
   WRITER skips the lane rather than shelling out: `bin/full-suite-check`
   resolves `lint_waived = FullSuiteGate.lint_waived?(cert_repo)`, warns that
   the lane is skipped by declaration, and records `rubocop_res = lint_waived
   ? nil : run_lane(...)` — so no `bin/rubocop` is invoked and no rubocop
   evidence is stamped. Such a repo therefore CERTIFIES BY THIS ROUTE, owing
   only `[full-suite@<fp>]`.

   **Who declares it:** `studio-engine` and — since 2026-08-31 — `solana-studio`.
   Until then solana-studio declared nothing, so this route COULD NOT PASS there:
   the lane shelled out to a `bin/rubocop` the repo does not ship, came back
   `COULD NOT RUN`, and the writer exits before recording — **discarding the GREEN
   suite lane with it** (`no evidence recorded for the red lane(s)`). That is not
   cosmetic. `agents/carl/sops/pr-review-primary.md` names this command as THE
   escape when a PR's CI verdict is red, pending or unreadable, so a reviewer
   following the SOP in that repo had no path at all.

   **ABSENT vs BROKEN — the pair of rules that keeps them apart.** A missing lint
   toolchain and a broken one want opposite treatments, and the waiver is only safe
   because BOTH rules hold:

   - **Never inferred** (`FullSuiteGate#lint_waived?`). A missing `bin/rubocop`
     waives NOTHING — only a reviewable line in `config/release_repos.yml` does.
     Without this, every broken rubocop install silently stops linting its repo.
   - **Always audited** (`bin/lib/lint_waiver_guard.rb`). A declaration is a claim
     about the tree, so a waived repo found carrying a lint toolchain
     (`.rubocop.yml`, `bin/rubocop`, or rubocop in the `Gemfile`/gemspec — a
     transitive `Gemfile.lock` entry is deliberately NOT a marker) is **REFUSED**,
     before any lane runs, naming the registry line to delete. Without this, a
     waived repo that later GAINS rubocop certifies green while nothing lints it.

   The guard can only ever REVOKE a waiver, never grant one; that is why it lives
   outside `FullSuiteGate`, whose source is asserted free of any environment read
   (`test/lib/cert_lint_lane_waiver_test.rb`). When the lint lane is UNRUNNABLE in
   a repo that declared nothing, the verdict stays RED — and now also names the
   registry route, so a genuinely toolchain-less repo has somewhere to go.

   (This paragraph previously said the writer did not yet honour the
   declaration and that such a repo "cannot yet be certified by this route".
   That was true for fifteen minutes: the prose landed `f99639be` at 13:18:33
   and the code that honoured the flag landed `b677fb91` at 13:33:19 the same
   day, and the file contradicted itself from then until this correction.)

   The lane runs CI's command because this route's whole claim is
   CI-INDEPENDENCE — **it may never run less of CI's Ruby suite than CI does**.
   (It once did: it ran `bin/rails test`, which **skips `test/system`**, so a
   builder could take the CI-independent route, go green, and have zero system
   coverage.) Scope it exactly: the cert stands in for CI's **`test` job**, not for
   all of CI — `scan_ruby` (brakeman), `scan_js` (importmap audit) and
   turf-monster's `playwright` e2e job are CI's alone, which is why review's
   gate-zero still holds the authoritative CI verdict. The cert keeps that claim by
   **refusing whatever it cannot SEE or cannot RUN**, across the repo's **PR-gating
   workflows**: CI's Ruby suite split across steps, across **jobs**, or across
   **workflow files**; a suite it can see but cannot run verbatim (a multi-line
   script, or a **wrapper** like `docker compose run web bin/rails test:system`); a
   foreign runner beside the rails step; a job it **cannot see into** (a job-level
   `uses:`, a composite action, a body with no `steps:`); and a command whose text
   does not say what it runs (`run: ${{ matrix.cmd }}`, `run: $SUITE`) each make the
   cert **REFUSE loudly** instead of certifying the narrower half. What it still does
   NOT see, stated plainly: a suite inside a **third-party `uses:` action** (list it
   in `KNOWN_INERT_ACTIONS` once you have checked it, or it refuses) or behind an
   executable that is neither a known runner nor a readable file in this repo; and a
   repo with **no `ci.yml`** falls back to the `DEFAULT` full-suite command — a
   superset, not CI's own line. Two consequences
   worth knowing: the system tier drives a real headless **Chrome**, and a host
   without one **aborts up front as an ENV error** — *"NOT a regression in your
   diff"* — never as a red suite; and the command's shape is load-bearing —
   `bin/rails test test:system` is **broken** (`test` is a real rails command, so
   `test:system` parses as a path → `LoadError`), which is why `db:test:prepare`
   leads and routes the line through rake. See `bin/lib/ci_test_command.rb`.

3. **Record the tier tags as you built** — in either order, before or after you
   certify:

   ```bash
   bin/task update <task-slug> --checks "[unit] ..." --checks "[integration] ..."
   ```

   `checks_run` holds two namespaces, and each side preserves the other's:

   - **You own the tier tags** (`[unit] …`, `[integration] …`, a
     `[full-suite-bypass] <why>` record). `--checks` REPLACES those — pass every
     tag you want kept. The cert tools never touch them.
   - **The cert tools own the evidence** (`[full-suite@<fp>:<repo>]`,
     `[rubocop@<fp>:<repo>]`, `[fast-cert@<fp>:<repo>]`). `--checks` **cannot**
     drop those: any lane your update does not itself supply is carried forward,
     by the CLI and by the board (`lib/cert_evidence.rb`). Recording your test
     plan after certifying used to wipe the cert and make `bin/dor-check` report
     `full-suite: MISSING` on freshly certified code — it no longer can.

   A lane is superseded only by a line FOR that lane **in that repo**, which is what
   a re-cert writes. The `:<repo>` scope is why a task naming two repos keeps a cert
   for EACH: certifying the second repo used to erase the first's line silently, and
   the false STALE surfaced much later on a repo you had already certified green.
   Certify each repo in its own tree (`cd <that repo's desk> && bin/full-suite-check
   <task>`); `bin/dor-check` grades every repo the task names and has a PR in, and
   names each one in its verdict. Never hand-write a `[<lane>@<fingerprint>]` line:
   that forges a certification, and the fingerprint exists to make the cert mean
   something.

4. **Verdict — the DoR gate** (its own gate; closes `dor`, not `g1_cert`):

   ```bash
   bin/dor-check <task-slug>
   ```

   Deterministic, no judgment: shape tiers, required metadata, suite evidence
   (fast/full/bypass), post-deploy nudges, and the PR's real GitHub CI. Exit 0
   = ready to advance `submitted → reviewed` — **without waiting for CI**: a
   fresh fast cert with CI still pending on the open PR is credited
   provisionally (a red CI still refuses; a fast cert with NO open PR is
   refused — push and open the PR first, then run the verdict). Full mechanics:
   [`dor.md`](dor.md).

## Success, failure, and attempt semantics

One GateRun row = one **attempt** (`started_at → finished_at`, `success`,
`sops`). Retries are first-class: a failed attempt closes and the re-run opens
attempt n+1 — repeated cert failures are visible signal, never one collapsed
window.

- `bin/fast-check` / `bin/full-suite-check` **OPEN** the task's `g1_cert`
  attempt at start and append one SOP entry per lane
  (`{sop, cmd, result, duration_ms}`).
- A **red lane closes the attempt `failed`** (the re-run opens attempt n+1) —
  a red test-DB lane short-circuits the cert on the spot; a red mapped / spine
  / rubocop lane still lets the remaining lanes run, and the `failed` close
  lands once the lanes finish. Either way the cert REFUSES and the attempt
  never closes `success`; a lane that went red or hung records nothing.
- **A green lane is banked even when a SIBLING lane fails** — `bin/full-suite-check`
  only, since 2026-09-01. A rubocop lane that passed over 1,229 files used to be
  discarded because the suite lane hung at the ceiling, so the re-run re-paid
  twenty minutes at an UNCHANGED tree hash. The banked line is fingerprint-bound
  and per-repo, exactly as on the green path, so two partial runs over one tree
  COMPOSE. It buys no pass: the run still exits 1, still closes `failed`, and the
  task still owes every lane it did not measure. `bin/fast-check` does not bank —
  its lanes roll into one `[fast-cert@…]` line, so there is no sibling to keep.
- A **green cert CLOSES the attempt `success`** ITSELF — the cert owns the whole
  `g1_cert` window (open + close). `dor-check` no longer touches `g1_cert`; its
  verdict is the separate [DoR](dor.md) gate.
- **Never emitted:** `--print` cert runs. All gate writes are fire-and-forget —
  a board blip never changes a verdict or an exit code.

The Definition-of-Ready verdict semantics — the `dor` / `dor_review` attempts,
their `dor-check` / `tiers` / `full-suite-evidence` / `ci` SOPs, the
submit-before-CI-settles credit, and the `--gate-role` split — now live in
their own gate doc: [`dor.md`](dor.md).

## The CI seam — the cert is CI-independent either way

**This gate is unaffected by the CI wait**, and that is worth saying plainly: the
cert runs before the PR exists, so it has never had a CI state to wait on. Whether
CI is green, red, or unborn changes nothing about `bin/fast-check` or
`bin/full-suite-check`.

What sits downstream of it did change (`gate-submit-on-green-ci`, 2026-08-16):
`bin/ship` now holds between opening the PR and running the DoR verdict, until the
PR's CI settles — so the builder certs (this gate), opens the PR, **waits**, runs
the dor-check verdict (the DoR gate), and moves the task `submitted` on a green CI
rather than a provisional one. Full CI-seam mechanics — the provisional fast-cert
credit that remains the fallback, the review-side gate-zero, and the bounce
round-trip — are in [`dor.md`](dor.md).

## UI surfaces

- **Task gates card** — the "Testing gates" card on
  `https://mcritchie.studio/tasks/<slug>` renders the G1 Cert chip: latest
  attempt (`attempt ×n` retry badge), passed / failed / in-flight status, and
  the expandable per-lane SOP list with ✓/✗ and durations.
- **CLI read:** `bin/gate show task <task-slug>` (add `--json` for the raw
  attempts).

## Background — not needed to execute

- The 90/10 rethink behind the fast route, the fingerprint mechanics, and the
  CI-status gate: `docs/agents/system/devops-cycle-design.md` §3.3.
- Evidence format + fingerprint implementation: `bin/lib/full_suite_gate.rb`;
  test selection: `bin/lib/fast_cert.rb`.
- **Disarm switches — for the harness only, never for a wedge.**
  `FAST_CHECK_SKIP_ORPHAN_GUARD=1` (`bin/fast-check`) and
  `FULL_SUITE_SKIP_ORPHAN_GUARD=1` (`bin/full-suite-check`) skip the orphan
  preflight entirely. They exist so the guard's OWN test suite can spawn certs
  without each one refusing against its siblings. **Do not reach for them to get
  past a refusal**: the refusal is naming a live process holding your test DB,
  and skipping it just walks you back into `PG::ObjectInUse` with the evidence
  suppressed. `CERT_GUARD_PS` / `CERT_GUARD_PSQL` likewise exist to inject
  fixtures in tests, not to steer a real cert.

## Related

- [`dor.md`](dor.md) — the next gate; the DoR verdict (`bin/dor-check`) the
  builder runs at submit (`dor`) and the primary reviewer re-runs as gate-zero
  (`dor_review`, `--gate-role review`).
- [`g2-review.md`](g2-review.md) — the senior-review lanes that follow DoR.
- [`../task-board-api.md`](../task-board-api.md) — the `/api/v1/gates` write
  surface `bin/gate` posts through.
