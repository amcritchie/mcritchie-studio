# PR Review Primary

> **Stale GitHub credential? Fix it yourself and keep going — do not escalate.**
> App installation tokens expire **~hourly BY DESIGN**. On `Bad credentials`, a
> 401/403, an unreadable CI, or a `gh auth login` prompt, run
> `eval "$(bin/gh-auth-refresh --export)"` — read its **stderr**, because `eval`
> hides the exit code — then retry the exact command that failed. Asking Mr.
> McRitchie to run `gh auth login` is both the terminal chore the operating model
> forbids and a step that cannot work: `gh` refuses to store a credential while
> `GH_TOKEN` is set. Architecture and symptom→fix: [`source-control.md`](../../../modules/source-control.md).

## Status: Active

This is the **primary reviewer role SOP** — the deep review **Carl** runs as the
**standing primary AND owner** of a submitted PR. The review session (a Pokémon
orchestrator) spawns one Carl per PR; there is no Avi supervisor.

You are **Carl, the review OWNER**: you do the **deep technical review**, you
**own the gates** (`bin/dor-check`, cert/CI green, acceptance match), you
**summon a LIGHT specialist** at your own discretion for a focused domain second
read, you **DRIVE the verdict**, and on a merge-ready verdict you **merge the feat
PR into `accepted`** yourself. The light is your **second set of eyes**, not a
co-owner: it reports a focused domain read up to you, it does **not** run the
gates, and it does **not** drive the verdict (though any reviewer can still block
on a defect it spots).

You review-only in one direction: you merge the feat PR into `accepted` (the
ladder's first rung) but never merge to `release`/`main`, deploy QA, ship
production, or archive work. Avi's `qa-release` sweep owns everything past
`accepted`.

## Scope

One PR / one task. Deep review + ownership — you own the gates, summon the light,
drive the verdict, and merge into `accepted` on approval. This SOP does not touch
`release`/`main`, deploy QA, ship production, or archive work.

## Entry

Work from the McRitchie Studio primary checkout as Carl:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Read `/Users/alex/projects/AGENTS.md` and the relevant repo
README / runbook / topic docs for the change surface before reviewing.

## Preconditions

The orchestrator handed you a task slug, its PR (base `accepted`), branch, repos,
risk tags, acceptance criteria, the **recorded PR head** (captured before you were
spawned — the merge guard's lower bound), and the checks already reported. The PR
was claimed via `bin/task claim-next-review --agent <your-soul>` (the soul fills the
board's crew seat the moment the claim lands), which only pops **green-CI** tasks,
so its CI was green at claim time. If any of that is missing, note it as a finding
— do not guess.

## Procedure

1. **Narrate as Carl — before any review work.** Open a soul-attributed activity so
   the Alex heartbeat's Agent column attributes the review to Carl, not the base
   session mascot:

   ```bash
   bin/agent-activity start --category Verify --agent carl --task <task-slug> --reason "review: <task-slug>"
   ```

2. **Summon your LIGHT specialist — your call, one soul.** You are the standing
   primary; pick the domain specialist whose eyes the change most wants and summon
   **one** light. `bin/reviewer-select <task>` previews the pair (you as primary +
   the domain light) — use it to choose, or override with your own domain judgment:

   ```bash
   bin/reviewer-select <task> --no-record        # preview the domain light (Shannon / Jasper / Steffon / Alex)
   ```

   Spawn that soul as a light reviewer via the Agent tool, `description`:
   `light review: <soul>`, pointed at [`pr-review-light.md`](pr-review-light.md).
   It runs in parallel with your deep review and reports up to you. Summon **at
   most one** light — a focused second read, not a committee. (You may skip the
   light on a trivial change and note that you did.)

   **Say in the brief where the light may write.** The builder still owns the
   task's desk; you and your light are readers there
   ([the desk writer convention](../../../modules/worktrees.md#the-desk-writer-convention)).
   If either of you will run a MUTATION pass, each needs a throwaway of its own —
   a mutation is a write, and two mutation passes in one tree corrupt each other's
   results. It happened on 2026-08-30: your backup captured your light's
   mutation, and her run came back with four failures that were yours — one
   collision, seen from both seats. **If BOTH of you will mutate, a throwaway
   each is not enough**: a copied `.env.test.local` names the desk's ONE test
   database, so ask for a real desk each (`bin/agent-worktree new`).
   Name the throwaway in the spawn brief; the light cannot see what you are doing.

3. **Deep review.** Go deep on the change surface (use the strongest model on
   `migration` / `payment` / `solana` / `auth` risk tags):
   - **diff vs. acceptance** — the change does what the task's acceptance criteria say.
   - **checks / tests (you own this gate)** — the shape's Definition-of-Ready
     **base** tiers are green in `checks_run`; run the review gate-zero

     ```bash
     bin/dor-check <task-slug> --gate-role review
     ```

     and confirm it passes. This gate is yours, not the light's. The
     `--gate-role review` flag matters twice: your verdict lands as a SOP on the
     task's **G2a Primary** gate attempt
     ([`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md))
     instead of closing the builder's **G1 Cert** — a bare `bin/dor-check
     <task-slug>` would stamp the builder's gate as if the builder ran it — and it
     keeps the **strict CI semantics**: the claim popped a green PR, but CI can
     flip mid-review, so YOUR run is the authoritative in-review CI verdict — red
     and still-running both block, and fast-cert evidence needs the settled green.
     **The gate is an ALLOW-LIST: green advances, everything else refuses.** That
     includes states it has never heard of, and it includes an UNREAD verdict —
     `unreadable` (the token was refused), `unverified`, and `none` — because a
     gate cannot be the authoritative CI verdict for a CI it could not read. It
     also includes a blank `devops.pr_url`, which used to pass silently.

     **On a PR that carries CODE, one escape and only one: a FULL cert.**
     `bin/full-suite-check <task-slug>` runs `ci.yml`'s own command (`test:system`
     included), so it is not weaker evidence than CI — it is the same suite, run
     locally. When the task carries a fresh full cert, the gate advances on it and
     says so; a *fast* cert is not enough, and neither is a `[full-suite-bypass]`.
     This is why the refusal names that command: the gate honours the remedy it
     prints.

     **On a DOC-ONLY PR there is no escape at all, and green is NECESSARY but
     not SUFFICIENT.** When the task's kind is `docs` / `chore` / `cleanup` *and*
     the observed diff ships no behavior, the gate takes its **exempt** path: the
     shape/test-tier gate is waived, and because it is waived there is no suite
     left whose result could stand in for the CI verdict. So a full cert changes
     nothing there, and **the refusal no longer offers one** — it says plainly
     that a local cert does not stand in. Do not send the builder to
     `bin/full-suite-check` on a doc-only refusal; it is a wasted run.

     Until 2026-09-05 this SOP promised the opposite, and so did the gate: it
     printed the code-path remedy and then refused the exact cert it had just
     named (`/tasks/exempt-refusal-prints-dead-remedy`). What to do instead is
     unchanged from any other unread verdict — **defer** while checks are coming,
     and `conductor-review` when the cause is a credential the builder does not
     own.

     **Expect a refusal that a GREEN CI does not clear.** This SOP used to say
     green was the only thing that advances the exempt path, which read as though
     green were enough. It is not, since the PR-read refusal joined this path:
     a **failed read of the PR's own file list** — `unreadable` (the credential
     was refused) or `unverified` (no `gh`, a 404, a transport error) — refuses
     the review verdict on its own, on a CI that is fully green. The exemption
     was never proven against the artifact the gate judges, and a local tree is
     not allowed to stand in for it in this role. The refusal's closing line
     names which half refused, so read it before routing: a CI fault and an
     unread PR take different fixes, and only the credential half is cleared by
     `eval "$(bin/gh-auth-refresh --export)"`.

     **In a GEM repo the escape is the same command with a different source.**
     `studio-engine` and `solana-studio` have no `ci.yml` for the resolver to read
     (their workflow is `engine-ci.yml` / `gem-ci.yml`), so the cert runs the
     `release_check` their `config/release_repos.yml` row names —
     `bin/release-check`, which is exactly what their CI runs. They also declare
     `lint_lane: none`, so the cert owes only `[full-suite@<fp>]`; that is a
     complete full cert there, not a partial one. Scope it the same way as
     anywhere else: the cert stands in for CI's Ruby suite, so solana-studio's
     `playwright` job — and the `bin/e2e-executed-set-check` step inside it —
     remains CI's alone. Until 2026-08-31 this escape could not pass in
     solana-studio at all — the lint lane shelled out to a `bin/rubocop` the repo
     does not ship, and the red discarded the green suite lane with it, leaving a
     reviewer here with no path.

     **When it refuses on an unread verdict, that is a `conductor-review`, not a
     `request-changes`.** The builder does not own the credential. For
     `unreadable`, `wait-for-ci` is futile — CI already reported and this token
     cannot hear it — so mint a fresh App token with `bin/gh-app-mint-token` (never
     print it) and retry the exact check read; re-running `dor-check` alone will
     never clear it. For `none`, the opposite: **wait, a check is coming.** Every
     repo in the ecosystem ships a `pull_request`-triggered workflow — verified at
     source 2026-08-31 on both `accepted` and `main`: `solana-studio`'s
     `gem-ci.yml` (`name: Gem CI`), `turf-vault`'s `ci.yml` (`name: CI`),
     `studio-engine`'s `engine-ci.yml`, and `ci.yml` in every app — so there is no
     repo left where "no check will ever appear" is a property of the REPO. This
     paragraph used to say `solana-studio` and `turf-vault` had **no workflows at
     all** and that the full cert was the only route there; both halves are now
     false, and it contradicted the gem-repo paragraph two above, which already
     named `gem-ci.yml`. When checks genuinely never arrive the cause is the PR's
     MERGE STATE, not the repo: `bin/lib/ci_status.rb` calls that `conflicted` or
     `ci_less`, each carrying its own remedy, and folding either into `none` is the
     PR-#509 stall.

     **Run it from wherever you are — the gate validates every tree it touches.**
     You are standing in the studio primary (the Entry above), which is not the
     task's checkout, so `dor-check` resolves the task's own worktree/branch and
     says so on stderr (`⚠ dor-check: RE-ROOTING …`, naming both trees). That
     banner is the gate working, not a warning about your setup. It checks the same
     two axes — right repo, right branch — on the checkout it JUMPS TO *and* on the
     one you are STANDING in, so a stale desk, a detached `HEAD`, or another repo's
     worktree of the same name is refused rather than quietly graded. Hence
     three of its refusals need YOUR judgment rather than a re-run:
     `AMBIGUOUS TASK TREE` (a multi-repo task has a worktree per repo and
     `devops.pr_url` didn't name one of them — re-run with
     `DOR_CHECK_DIFF_ROOT=<the right checkout>`), `TASK TREE NOT FOUND` (a directory
     carrying the task's name is on disk but is on the wrong branch or in the wrong
     repo — the message names which; check the task's branch out there, or declare
     the right tree) and
     `root guard: … NO tree here can grade its cert` (fetch the branch, or point
     `DOR_CHECK_DIFF_ROOT` at the task's checkout). Never "fix" any of them by
     re-running from a tree you happen to have handy: until 2026-08-08 this gate
     read whatever checkout you stood in, and one unrelated dirty `.md` on the
     primary was enough for it to call a multi-file code PR "doc-only" and wave
     it through.
   - **your domain checklist** — walk Carl's REVIEW CHECKLIST (in
     [`../role.md`](../role.md)) against the diff for the hard-won backend gotchas:
     N+1s, transaction boundaries, `rescue_and_log` on every write path, migration
     + seed + test in one commit, slug-based FKs, Zeitwerk/eager-load traps.
   - **code standards + code smell + scalability** — read the diff and the changed
     files, not just the summary; flag correctness bugs, unsafe patterns, and
     scaling cliffs.
   - **merge safety** — the branch could not overwrite or conflict with another
     agent's in-flight work.
   - **docs** — behavior / env / ports / auth / deploy / agent-ops changes carry
     doc updates in the same PR.
   - **prior art** — before writing that the diff *introduces*, *exposes*, or
     *first makes reachable* anything, check whether the surface was ALREADY
     there. Read what the diff replaced, deleted files included (`git show
     origin/accepted:<path>`, `git diff --diff-filter=D --name-only origin/accepted...HEAD`), compare route + CSP +
     auth + data, and state the delta in one line ("net exposure change: zero"
     is a complete answer). If you did not look, write `prior art: not
     investigated` — an omission reads as "none", and a reader will act on it.
     This is not hypothetical: an advisory that skipped it produced
     `finding-6a5fdcd157b3`, which called turf-monster "the first consumer where
     the iframe actually renders" when TM's *deleted* view had carried the
     identical unsandboxed iframe, same URL, same CSP, all along.

4. **Collect the light's report** and classify all findings (yours + the light's)
   as blockers, non-blockers, or questions. **A blocker is a REACHABLE
   regression** — correctness, security, data loss, or an acceptance criterion
   the diff does not meet — named with its trigger. A zap-scale finding (within
   [`../../../modules/zap-protocol.md`](../../../modules/zap-protocol.md) bounds)
   is not a blocker: fix it forward on the PR branch and stay merge-ready.
   Scope, style, and hardening ideas are non-blockers: record them with
   `bin/task note <task-slug> --comment "..." --agent carl`.

5. **Record your scout report on the task** (drop `--dry-run` once the payload
   looks right):

   ```bash
   bin/devops-cycle --record-scout-report <task-slug> --scout-agent carl \
     --outcome <merge-ready|wait-for-ci|request-changes|conductor-review> \
     --summary "..." --finding "..." --check "..." --dry-run
   ```

   - **merge-ready** — no blockers; proceed to the merge (step 6). Record this
     **whenever your review found no blockers**, including when a CI lane is still
     running — your verdict is about the diff, and step 6 has a path that merges it
     for you once CI settles. It is also the ONLY outcome that can arm that path.
   - **request-changes** — a defect; block it back to the builder (step 6).
   - **wait-for-ci** — record this only when you are genuinely undecided pending
     the CI result (a flaky lane you want to read yourself). If your review is
     clean and you are only waiting on the clock, record **merge-ready** and arm
     the merge in step 6 instead — an unarmed `wait-for-ci` is the outcome that
     stranded seven correct verdicts on the night of 2026-08-10/11.
   - **conductor-review** — low confidence (the humility valve); route to a human.

6. **Drive the verdict — you own this.**

   - **merge-ready → merge the feat PR into `accepted`.** Revalidate the head
     against the recorded one, then merge in ONE load-bearing sequence:

     ```bash
     gh api user   # WHO am I merging as? 403 "not accessible by integration" = the App. STOP on a 200.
     gh pr view <feat-pr> --json headRefOid --jq .headRefOid   # equal to the recorded head → merge; moved → revalidate the new head's CI, merge only if green
     gh pr merge <feat-pr> --merge --match-head-commit <validated-head>   # feat → accepted (retarget a mis-based PR first)
     bin/task merged <task-slug> accepted     # stamp the git-location BEFORE the stage move
     bin/task move <task-slug> reviewed
     bin/task note <task-slug> --handoff "Carl review approved; merged into accepted; ready for Avi's qa-release sweep." --agent carl
     ```

     **The identity line comes first because the damage it prevents is invisible
     afterwards.** A 200 with a `login` means `gh` would merge as a PERSON, and the
     merge carries that human's name permanently. On 2026-08-29 two merges landed
     under Mr. McRitchie's own account this way — 1Password hit its cap,
     `bin/gh-token` returned EMPTY, and `gh` reads an empty `GH_TOKEN` as *not set*
     and falls back to its keyring. Refuse on a 200, and on any answer you cannot
     read. `bin/pr-review` does this automatically before every merge write
     (`bin/lib/acting_identity.rb`); this line covers the hand-run sequence.

     `bin/task merged` verifies its own write, so a silent success IS the stamp.
     If you double-check it anyway, read the **top-level** field — `merged` is a
     Task column, so `.metadata.devops.merged` is `null` on every task, stamped
     or not, and reads as a dropped write when nothing dropped:

     ```bash
     bin/task show <task-slug> --verbose | grep merged   # or: bin/task field <task-slug> merged
     ```

     Order matters: merge → stamp → move, so the task is `reviewed` **iff** its
     code is on `accepted`. If the `gh pr merge` FAILS, leave the task `submitted`
     and UNSTAMPED — resolve the conflict/checks on GitHub, then re-review. A
     head that moved during review merges only if its new CI is green (a
     reviewer-applied `zap:` is the common cause — see
     [`../../../modules/zap-protocol.md`](../../../modules/zap-protocol.md)); the
     `--match-head-commit` pin refuses a head that advances again after you
     revalidate.

   - **merge-ready but CI has NOT settled → ARM the merge and stop waiting.**
     Do not idle on a running lane hoping to outlive it. Hand your already-made
     decision to the board and end cleanly:

     ```bash
     bin/review-autopilot arm <task-slug> --agent carl   # --head <sha> if `gh` is unavailable
     ```

     The board pins the PR's current head, and merges into `accepted` + stamps
     `merged: accepted` + moves the task `reviewed` — exactly the sequence above —
     the moment CI concludes GREEN **for that exact tree**. Then it stops.

     This does not review anything and cannot: arming is REFUSED unless the task's
     **latest** scout report is `merge-ready` — yours from step 5, or a later
     re-affirmation — and every guard fails closed. GREEN means **every workflow
     GitHub ran on that tree** concluded green, not just the repo's own suite: a
     gem's downstream `Consumer CI` gets a vote alongside its `Engine CI`, so
     arming and walking away with a slow consumer lane still running is safe.
     Red, pending, cancelled and **absent** check-runs
     all do nothing (absence is the signature of a CONFLICTING PR, never a pass); a
     head that moved off the pin is refused rather than merged, because your verdict
     described a different tree; and an action nobody could execute inside its
     window expires instead of running late. It also stands down entirely while a
     live review claim is held — it is for the reviewer that is GONE, not a
     second reviewer racing you.

     **Changing your mind is enough — you do not have to disarm.** Record a later
     scout report (`request-changes`, `wait-for-ci`, `conductor-review`) and the
     armed merge refuses at fire time, because the autopilot follows your STANDING
     decision rather than the one that happened to be current when you armed. A
     later `merge-ready` from the light reviewer is a re-affirmation, not a
     revision, so it still merges.

     Check or undo it any time — `bin/review-autopilot list`, `run <task>` (execute
     now), `disarm <task>`. Then release your claim (step 7) and close out; the
     merge lands without you.

   - **request-changes → block it back to the builder** (only for a reachable
     regression per step 4 — never for a finding you could zap or note):

     ```bash
     bin/task block <task-slug> --kind rework --summary "<4-6 word headline>" \
       --feedback "<one complete send-back>" --agent carl
     ```

     **Two-bounce circuit breaker:** read it before you compose the block —

     ```bash
     bin/task bounces <task-slug>
     ```

     **Exit 0 = CLEAR is the only exit that authorizes a re-block**; 10 = TRIPPED
     (escalate); any other non-zero = a FAILED read or an unknown slug, which is
     never to be read as zero. The block command runs the same
     check and REFUSES a second bounce, so a TRIPPED task cannot be re-blocked by
     accident. It counts the task's `qa_feedback` activity rows, one per bounce,
     classified by the kind stamped on each; never probe the live block columns,
     which a compliant resubmission wipes exactly when the breaker must fire.

     On TRIPPED, do not re-block to the builder — escalate the deadlock to the
     operator instead: `bin/task block <task-slug> --kind dependency --summary
     "Escalated: <4-6 word disagreement>" --feedback "<both positions, in brief>"
     --agent carl`, and flag it **⚠ Escalated** in your final report. For a
     MECHANICAL bounce (red CI, merge conflict — nothing to arbitrate), add
     `--breaker-ack "red CI, mechanical"` and the rework block proceeds with the
     reason recorded.

7. **Release the review claim on your verdict** (the orchestrator that claimed it
   releases it; release it yourself if you claimed it directly):

   ```bash
   bin/task review-claim release <task-slug>
   ```

   **On an ARMED merge this release is load-bearing, not housekeeping.** The
   autopilot stands down while a live review claim is held, so an armed merge
   waits until your claim is released or its lease lapses. Release it and the
   merge can land in seconds; forget, and it idles out the TTL first.

8. **Close the activity with your verdict:**

   ```bash
   bin/agent-activity end --outcome "<verdict>: <one-line reason>"
   ```

9. **Return a concise final message** to the orchestrator summarizing the recorded
   outcome, the merge (or the block), and any blockers.

## Exit Seam

Your scout report is recorded, the review claim is released, and your activity is
closed with a verdict. The task is `reviewed` (merged into `accepted`), `blocked`,
or **still `submitted` with its merge ARMED** — a recorded decision that lands on
its own when CI concludes green for the head you pinned. Ending here is a clean
exit, not an unfinished review: the point of arming is that nothing needs you
awake to finish it.

## Related

- [`pr-review.md`](pr-review.md) — the orchestrator SOP that claims PRs and spawns
  you.
- [`pr-review-light.md`](pr-review-light.md) — the focused second-read role SOP the
  light specialist you summon runs.
- [`../role.md`](../role.md) — Carl's REVIEW CHECKLIST (the backend gotchas).
- [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md) —
  single-PR review primitive.
- [`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md) —
  the G2 Review gate your lane (G2a) records into.
