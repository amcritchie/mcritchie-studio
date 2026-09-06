# G4 Ship — the frozen-SHA production gate

## Status: Active

G4 Ship is the fourth and final branded testing gate: the **release-grain**
record (GateRun key `g4_ship`, subject = the release slug) that the **frozen
ship SHA was certified and deployed to production**. It is produced by Steffon's
`production-deploy` act — `bin/release ship` opens it at the ship gate and
closes it after the post-ship smoke seal.

The four gates in order: [G1 Cert](g1-cert.md) → [G2 Review](g2-review.md) →
[G3 Candidate](g3-candidate.md) → **G4 Ship** (this doc).

## What this gate verifies

The gate window spans the whole irreversible half of the ship:

- **The frozen-SHA test gate** (`ship_test_gate` SOPs) — **GitHub CI's conclusion
  for the repo's QA-frozen SHA** is read BEFORE ship authority and before any push,
  so "shipped" can never mean "untested". Since DevOps v2 Phase 3 the verdict is CI
  (`ci_verdict(repo, frozen_sha)` → `ci_pass?`, fail-closed — **only green ships**),
  not a local re-run: the registry `test_cmd` is still **recorded** (the drift/skip
  check needs it) but its execution in an isolated gate workspace was demoted then
  **deleted in Phase 4**. CI's Actions run covers
  the repo's full suite INCLUDING the browser `test:system` lane no local gate ran.
- **Ship authority** — the explicit production confirm, after the gate and
  before any deploy.
- **The prod deploys** (`deploy:<repo>` SOPs) — per-app `git push` to Heroku
  or the repo's own `bin/deploy`, each with its `/up` hard-gate.
- **Post-deploy hooks** — each member's `devops.post_deploy_cmd` against
  PRODUCTION; a non-zero exit aborts before the ship record. Duplicate
  commands fold to one run.
- **The smoke seal** (`prod_smoke_seal` SOP) — the read-only `@qa-readonly`
  suite against prod. A SEAL, not a blocker: its verdict rides the gate
  (`metadata.seal: passed|failed`) but a red seal never flips the gate's
  success and never aborts the ship — the deploy already landed; the operator
  stays the gate on rollback.
  - **It retries once through the boot window.** The seal fires seconds after
    the deploy, so a smoke can land mid dyno boot/restart and fail against a
    HEALTHY prod (rel-20260720-c06235 red-sealed on `GET /tasks`; a re-run
    minutes later sealed 5/5 green). On a first failure the seal now waits
    **30s** and re-runs the suite **exactly once**. A first-attempt pass never
    waits — the happy path is unchanged.
  - **Reading the verdict.** A green seal whose summary says *"retried once
    after 30s boot-window wait"* passed on the second attempt — prod is fine,
    the first run caught the boot window. A **red seal now means the failure
    PERSISTED through the retry**: a confirmed failure, not a timing blip, so
    treat it with more weight than before. The seal's contract is otherwise
    unchanged — still non-blocking, still never auto-rolls-back.

## G4 self-gating (the 90/10 policy)

CI's verdict for the release SHA is established **once per release batch, at G3**.
The ship test gate SKIPS re-reading it for a repo **only against G3's own recorded
verdict** — `release.metadata["qa_gates"][repo] = {"sha", "cmd", "ok", "ci"}`, which
`prepare` writes ONLY after that repo's G3 verdict came back GREEN. It skips iff
(`Release::ShipSequence.ship_gate_skip?`, unit-tested):

- a G3 record exists for the repo and is **green** (`"ok" => true`), **and**
- its `"cmd"` is EXACTLY the `test_cmd` the ship gate would run, **and**
- its `"sha"` is EXACTLY the frozen ship SHA, **and**
- its **auditor did not go red** — `"ci" => {"state" => "red"}` means GitHub CI
  called that SAME SHA broken (in Phase 3 a red CI aborts `prepare`, so this is a
  defensive check against a stale or hand-built record — see
  [G3 Certification](g3-candidate.md#certification-what-g4-reads)).

Everything else does **not** self-skip — no record, an `ok:false` record, a
different command, a drifted/straggler SHA, a red auditor, blank inputs — and G4
**re-derives the verdict from GitHub CI on the frozen SHA** (`ci_verdict` → `ci_pass?`).

The skip decision and the verdict have **different failure modes**, and the
distinction is the whole point:

- **The skip is fail-OPEN.** A missing/mismatched/red-auditor record makes G4
  *re-check* rather than trust the record — a skip never fires on doubt. `none` /
  `pending` / `unverified` and a record with no `"ci"` key leave the skip decision
  exactly as it was (no data never arms the non-skip).
- **The verdict is fail-CLOSED.** Once G4 re-reads CI, only a **green** frozen SHA
  ships; red, and every no-data/pending state (`none`/`pending`/`unverified`/
  `unreadable` — e.g. a just-pushed re-pin whose CI has not concluded), **abort the
  ship**. This is the Phase 3 inversion: the pre-v2 gate re-ran a *local* suite here
  (fail-open, "not a backstop for CI's lane"); now CI itself is the last verdict
  before the irreversible deploy, and it CAN see every lane.

When a red auditor is what triggered the re-check, the ship **says so** — it names
the distrusted record and re-derives the verdict from GitHub CI on the frozen SHA.

> **Why not the registry + `qa_shas`?** That was the old rule, and it was a
> silent **disarm**. `qa_shas` is stamped by the QA *deploy loop*, so it records
> what was DEPLOYED, never what was CERTIFIED; and the registry is re-read at
> ship, so it can differ from what `prepare` read. The documented gate-skip
> recipe (blank `qa_test_cmd` so G3 skips → restore the file before ship, because
> ship's preflight used to refuse a dirty primary) therefore made G4 skip a suite
> that **nothing ever ran**, while printing "already green". A skipped G3 must
> never certify a SHA. **Do not use that recipe** — it no longer works, by design.

The skip is recorded as a **visible `ship_test_gate` SOP** on the gate run
("skipped — `<cmd>` certified green @ `<sha>` at G3"), never a silent omission.
A repo with **no registry `test_cmd` self-gates** at its own deploy and is
skipped with its own step note. In practice: the hub (same full suite registered
at G3 and G4) skips on an unchanged, G3-certified SHA; satellites (integration
subset at G3, full suite at their own deploy) always run their full pre-prod
check.

## Where the verdict comes from

**GitHub CI**, on the frozen ship SHA — `ci_verdict(repo, frozen_sha)` reads the
Actions conclusion for that exact commit, and the gate result is `ci_pass?` of it.
Nothing runs on this machine; the verdict comes off the laptop.

> **Pre-v2 (deleted): the isolated gate workspace suite.** Before Phase 3 the suite ran
> in the repo's isolated gate workspace (`Release::GateWorkspace`, role `gate`) — a
> private detached worktree at `<repo>/.worktrees/_gate` pinned at the frozen ship
> SHA, under the dedicated gate-workspace lock, with a test DB the gate **proved**
> private, **never** the shared primary. The gate's invocation of it was commented out
> in the canary window and **deleted in Phase 4**. The `GateWorkspace` primitive itself
> lives on under role `ship` — the ship reuses it to run a `repo_script` satellite's own
> pre-prod deploy suite — but no gate runs a suite in it. Its whole reason for existing
> as a *gate* — a suite that lazily autoloads over minutes against a tree other sessions
> can `git checkout` is not a check — is now moot: CI runs in a clean, isolated Actions
> environment by construction.

## Where the DEPLOY runs — the ship has its own checkout too

The gate moved off the primary before the ship did, and for a while the deploy
still fast-forwarded the primary's `main`, re-pinned Gemfiles there, and ran the
satellites' `bin/deploy` there — so **ship's preflight refused a dirty primary**.
That refusal **aborted a production ship after the gems had already published**,
because a concurrent feature session had staged work in the primary. Since
2026-07-12 the deploy owns its own tree, and the question "what does the deploy
actually need a checkout FOR?" has a two-line answer:

| Step | Needs a working tree? | Where it runs now |
|------|----------------------|-------------------|
| advance `main` → frozen SHA | **no** | `git push origin <frozen>:refs/heads/main` — a ref push out of the shared object store |
| `git_push_heroku` deploy (hub, rolio) | **no** | `git push <remote> <frozen>:refs/heads/main` — ships the frozen SHA *by value* |
| `repo_script` deploy (turf-monster) | **yes** (its `bin/deploy` runs the repo's suite, hashes the IDL, pushes) | the **ship workspace**: `<repo>/.worktrees/_ship`, detached at the frozen SHA, own lock, own test DB (`<app>_ship_test`) |
| gem re-pin commit | **yes** (`bundle lock` writes `Gemfile.lock`) | the ship workspace, pushed as `HEAD:refs/heads/release` |
| gem artifact build | **yes** (`gem build` packages what is on disk) | still the gem's **primary** — the one residual (see below) |

Ref pushes keep every safety property of the old fast-forward: git refuses a
**non-fast-forward** ref update without `--force` (which the ship never passes),
so a diverged `main` still **fails closed**; and they are idempotent, so a re-run
of a partial ship no-ops. Nothing is mutated before ship authority at all now — a
red gate or a declined confirm leaves the machine exactly as it found it.

**A refused `main` push does NOT mean `main` diverged** — and until 2026-08-29
the ship said it did. `push_frozen_main` ran `git push` without capturing its
output and then asserted the only cause it knew: *"origin/main has diverged from
the frozen SHA (someone pushed to main) — reconcile main, re-run `bin/release
prepare` to re-freeze."* Measured twice that day on a real ship, the true cause
was `remote: Invalid username or token`, three lines above in git's own output;
`main` was strictly **behind** `release` and a dry-run fast-forward succeeded. A
confident, specific, wrong diagnosis whose prescribed remedy — reconciling a
branch that needed nothing and re-freezing a good freeze — was pure waste.

The push output is now captured, echoed, and CLASSIFIED, the same way
`advance_accepted` already classified a refused `accepted` push:

| Outcome | What git said | What you do |
|---|---|---|
| **AUTH** | `Invalid username or token`, `Authentication failed`, `could not read Username`, `Permission denied (publickey)`, a 401/403 | `bin/gh-auth-refresh --identity deployer` — the ship pushes as the **deployer**, whose credential lives in `studio-agents-admin` and needs `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` (`~/.zprofile.admin`). Then re-run `bin/release ship`; it resumes. **Do NOT re-run `prepare`** — the freeze is still good. |
| **DIVERGED** | `non-fast-forward`, `[rejected] … (fetch first)`, `Updates were rejected because…` | Reconcile `main`, re-run `bin/release prepare` to re-freeze, then re-run `bin/release ship`. |
| **UNRECOGNISED** | anything else | Read git's output above before acting — **both** standard remedies may be the wrong errand. The ship says so rather than guessing. |

`error: failed to push some refs to …` appears in **both** failures, so it is
never the discriminator. Nothing forces in any case.

**A dirty app primary no longer blocks a ship.** The preflight prints a NOTE plus
a rescue (commit the stranded work to a labeled `rescue/<repo>-<timestamp>`
branch — never `git stash`, never discard: it may be a live session's work) and
deploys anyway.

### Resuming a PARTIAL ship (the re-pin is idempotent by identity)

A ship aborts on the first failure, and the re-run resumes: published gems skip,
ref pushes no-op, and **the auto-re-pin is idempotent**. That last one is not free,
and it used to be a **wedge**:

Auto-re-pin mints a NEW commit on top of the frozen SHA and advances the ship SHA
to it — but `qa_shas` still holds the **original** frozen SHA and nothing ever
rewrites it. So a ship that published the gems, pushed the re-pin, and *then* died
left `origin/release = repin₁` while `qa_shas = frozen`. The retry re-derived its
SHA from `qa_shas`, saw the frozen tree's Gemfile still branch-ref'd, decided a
re-pin was needed — and then read **its own re-pin commit** as un-QA'd drift:
`origin/release drifted past the QA-frozen SHA — re-run bin/release prepare`. After
the gems had published. (Underneath that guard sat a second failure: the retry would
mint `repin₂`, a distinct commit with an identical tree, whose push is
non-fast-forward against `repin₁`.)

The ship now asks whether a moved `origin/release` **is the re-pin this run would
have written**, and reuses it instead of minting a rival. It qualifies on all three
or not at all (`Release::ShipSequence.resumable_repin?`):

1. **Ancestry** — the frozen SHA is an ancestor of the head.
2. **Shape** — the diff touches **only** `Gemfile` / `Gemfile.lock`. This preserves
   the original guard's whole intent: no code reaches production un-QA'd under cover
   of a re-pin.
3. **Identity** — the head's Gemfile is **byte-identical** to what this run would
   write. Not merely "no branch refs left" — that weaker test would wave through a
   Gemfile someone pinned to the *wrong* version, and prod would build it.

Anything else **fails closed** and aborts as drift. Refusing a resumable ship costs
a conversation; completing an unresumable one costs production.

**The one residual primary dependency: gem builds.** A gem is built from its own
primary checkout, and `gem build` packages the files on disk — so a **modified
tracked file** in a gem repo would be *published* to RubyGems, where a version can
never be re-pushed. The preflight therefore still **aborts** on that (and only
that: untracked files are invisible to the gemspec's `git ls-files`), *before*
anything is published, printing the same labeled-branch rescue.

**Operator note — ship is now FASTER, but a non-green CI HOLDS it.** Since Phase 3
the ship gate no longer re-runs a local suite on the frozen SHA — it reads GitHub
CI's already-computed verdict, which is near-instant. The trade: an uncertified SHA
(a re-pin whose CI has not concluded, a red frozen commit) **fails the gate closed**
and holds the ship until CI is green — or you take the `--skip-test-gate` override
below. An uncertified SHA must not reach production unchecked.

## Overriding a ship gate you believe is a false negative

`bin/release ship --skip-test-gate --reason "…"`

It demands a reason, **confirms** before skipping, runs no suite, and records a
**red** `ship_test_gate` gate SOP — so a skipped gate is visible in the release
record forever. Use it only when the code is verified green elsewhere and the
instrument is the thing that's broken; then **fix the instrument**.

This replaces the old trick of blanking the registry's `test_cmd`/`qa_test_cmd`.
Do not do that: it **silently disarmed** this gate while printing "already green"
(see above), and it no longer works.

## Who runs it

**Steffon**, via the `production-deploy` SOP
([`../../agents/steffon/sops/production-deploy.md`](../../agents/steffon/sops/production-deploy.md))
— ship authority is granted per session by Mr. McRitchie. The gate writes are
conductor-owned (actor = the ship's `--by`, defaulting to the operator's
`$USER`; source `conductor`); you never post G4 markers by hand on the happy
path.

## Procedure

From the McRitchie Studio primary checkout (never a worktree), with a
QA-green `assembled` release:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/release ship --yes
```

The conductor records the gate for you:

1. **Open** — `g4_ship` opens as the ship gate starts (right after the
   `ship_gate started` release event; those `ship_gate` /
   `ship_authorized` ReleaseEvents STAY — they stamp the tracker's
   `confirming`/`confirmed` beats. Gates record verdicts; they never replace
   stamps).
2. **Collect** — every test scope inside the window appends an executed-SOP
   entry: `ship_test_gate` per app (run or visible skip), `deploy:<repo>` per
   deploy, `prod_post_deploy` per hook, `prod_smoke_seal`.
3. **Close** —
   - **`success`** after every repo deployed, `/up` came back green, the
     post-deploy hooks passed, and the seal recorded — with
     `metadata.seal: passed|failed` (a red seal alerts + prints the exact
     rollback but does not flip success).
   - **`failed` with `metadata.aborted: true`** on any abort inside the
     window — a red frozen-SHA gate, a failed deploy or `/up` smoke, a
     post-deploy hook failure. The close never masks the abort; the
     partial-ship report still prints, and the idempotent re-run resumes
     (gems skip, ffs no-op) on attempt n+1.

## Success, failure, and attempt semantics

- One GateRun attempt per ship run that enters the window; a re-run after an
  abort opens **attempt n+1** (visible `×n` badge), a still-open attempt is
  re-entered.
- The seal is G4's **non-blocking closing beat**: seal result ∈ metadata +
  SOPs; gate success reflects the deploy train, not the seal.
- All gate writes are **best-effort** — a board blip warns and the deploy
  continues; `--dry-run` suppresses every gate write (the plan still prints).

## UI surfaces

- **/deployments table** — the **G4 Ship** column
  (`Release::DEPLOYMENT_STAGES`: Assembled | G3 Candidate | G4 Ship |
  Deployed) is **gate-backed**: latest attempt's duration, fail tint, `×n`
  retry badge.
- **Pizza tracker** — node 4 (Confirming/Confirmed) is the G4 confirm beat:
  lit by the `ship_gate` / `ship_authorized` stage stamps, not by the gate
  record. Node 1 ≈ the [G2 wave](g2-review.md); node 4 ≈ this gate's opening
  beat.
- **CLI read:** `bin/gate show release <release-slug>`.

## Related

- [`../../agents/steffon/sops/production-deploy.md`](../../agents/steffon/sops/production-deploy.md)
  — the owning SOP; run that end-to-end, this doc explains the gate it
  produces.
- [`g3-candidate.md`](g3-candidate.md) — the gate whose certified SHA +
  command enable this gate's self-gating skip.
- [`../task-board-api.md`](../task-board-api.md) — the `/api/v1/gates` write
  surface.
