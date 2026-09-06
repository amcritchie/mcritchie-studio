# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"
require_relative "gh_auth_retry"

# The REAL GitHub CI state of a PR, reduced to one verdict so bin/dor-check's merge
# gate can refuse to hand a red PR to review — the #1 blocker class (a PR green
# LOCALLY but red on CI, because bin/full-suite-check certifies `bin/rails test` and
# NOT the browser `test:system` lane GitHub also runs). Reads
# `gh pr checks <pr> --json name,state,bucket` and folds gh's normalized `bucket`
# (pass/fail/pending/skipping/cancel) into one state:
#   :red            — a check failed/cancelled          → BLOCK the gate
#   :pending        — a check running, none failed yet   → BLOCK (not green YET)
#   :conflicted     — mergeStateStatus DIRTY: the PR has merge conflicts against its
#                     base, so GitHub CANNOT compute the merge commit and the
#                     pull_request workflow NEVER fires — the PR has NO CI, not a
#                     pending one → BLOCK, with "merge the PR's base in and resolve" as the fix.
#                     Folding this into :none is the PR-#509 stall (2026-07-12): the
#                     review wave deferred it forever while the board looked healthy.
#   :ci_less        — ZERO check-runs AND GitHub AFFIRMATIVELY reports the merge is
#                     refused (`mergeable CONFLICTING`). GitHub cannot compute a merge
#                     commit, so it runs NO CI AT ALL → BLOCK, remedy "bring the base
#                     in and resolve". NOT reachable via `mergeStateStatus DIRTY`,
#                     which view_verdict always resolves to :conflicted first, and NOT
#                     via an UNDETERMINED mergeability, which is only ever a wait.
#                     See the THIRD STATE section below.
#   :closed/:merged — the PR is not OPEN                  → BLOCK (its green checks are
#                     HISTORICAL, not a live review target — a stale/abandoned pr_url)
#   :green          — every check passed/skipped         → pass
#   :none           — the PR reports no checks yet        → note SUBMIT-side
#   :no_pr          — no pr_url yet                       → silent SUBMIT-side
#   :unreadable     — the TOKEN cannot read CI (401/403)  → note SUBMIT-side, and it
#                     NAMES the cause and the repo. See the blindness section below.
#   :unverified     — gh/network error                    → note SUBMIT-side (don't
#                     trade a flaky CI lane for a flaky gate)
#
# THE LAST FOUR ARE SUBMIT-SIDE VERDICTS. Read this module as describing what the
# BUILDER's gate does; the REVIEW role is a different question and answers it in
# bin/dor-check, which allow-lists (:green advances, everything else refuses, and
# only the no-verdict family can be cleared by a full local cert). That asymmetry is
# deliberate — the review gate-zero IS the authoritative CI verdict, so it cannot be
# authoritative about a CI nobody read — and it does NOT relax anything here: the
# builder's provisional handoff is untouched, which is what keeps a flaky read from
# blocking every submit.
#
# A BLIND GATE MUST SAY WHY IT IS BLIND (task dor-check-misses-rolio-ci, 2026-07-13).
# :unreadable and :unverified are BOTH "no verdict", and neither hard-blocks the
# builder — but they are not the same fact, and collapsing them was a real bug:
#   * :none / :unverified say "CI has nothing to tell you YET" → the fix is to WAIT.
#   * :unreadable says "CI has plenty to tell you and this TOKEN may not hear it" →
#     waiting is futile; the fix is a CREDENTIAL, and no amount of re-running helps.
# Told the first story, a rolio builder pushes, re-runs dor-check, reads "push the
# branch and open the PR" for a PR that is already open and already GREEN, and
# learns to ignore the gate. That is how a gate stops being read at all — and an
# ignored gate is exactly how a genuinely RED CI ships. Honesty, not leniency:
# :unreadable is NOT easier to pass than :unverified. It unlocks nothing (notably
# not the fast-cert credit); it only tells the truth about why it cannot see.
#
# `injected` is dor-check's DOR_CHECK_CI_STATUS seam: a bare token
# (green/red/pending/none/unreadable/unverified/no_pr), "state:<name>" for a state
# that does not exist (see INJECTED_STATE_PREFIX), OR the raw `gh pr checks --json`
# array — so the tests never shell out to gh (mirrors DOR_CHECK_SUITE_EVIDENCE).
#
# TWO SUBJECTS, ONE VOCABULARY. `evaluate` asks about a PR (the merge gate's
# subject); `for_sha` asks about a COMMIT (the G3 release-gate's subject — the
# release tip belongs to no PR). Both fold into the states above. See the
# SHA-addressed section below.
module CiStatus
  TOKENS = %w[green red pending none unverified unreadable no_pr closed merged conflicted ci_less].freeze

  # THE SEAM'S ESCAPE HATCH: "state:<name>" injects an ARBITRARY verdict state,
  # including one this module has never emitted and never will. It exists so a gate
  # can be probed against the state that DOES NOT EXIST YET — which is the only way
  # to prove a gate allow-lists (defaults to refuse) rather than deny-listing the
  # spellings it happens to know. Testing only the real TOKENS can never distinguish
  # those two shapes, and the difference is a live false-pass: bin/dor-check's review
  # gate-zero passed a blank pr_url for exactly that reason.
  #
  # Deliberately OUTSIDE TOKENS, not an extension of it: TOKENS stays the vocabulary
  # of real states, so a typo'd real token ("greeen") still falls through to the
  # payload parser and fails loudly instead of quietly becoming a novel state.
  INJECTED_STATE_PREFIX = "state:"

  # The `gh pr view` fields evaluate needs. `mergeable` and `baseRefName` joined
  # state+mergeStateStatus for the THIRD STATE below: mergeStateStatus alone cannot
  # separate "GitHub is still computing" from "GitHub gave up", and the remedy has to
  # NAME the branch to rebase onto or the reader must go derive it.
  # headRefOid rides along for ReviewTreeGuard's seam-1 check (is the tree this review
  # grades the tree that will merge?). It is a FIELD ON A CALL THIS GATE ALREADY MAKES,
  # not a second round-trip — the read is `gh pr view --json <these>` either way.
  VIEW_FIELDS = "state,mergeStateStatus,mergeable,baseRefName,headRefOid"

  # --- THE THIRD STATE: a PR that will NEVER get CI ---------------------------
  #
  # A CI verdict has always had two "not green yet" shapes — :red (it ran, it failed)
  # and :pending (it is running). Task detect-ci-less-stale-prs (2026-07-20) named a
  # THIRD: CI is never going to run at all.
  #
  # When a PR's base drifts far enough that GitHub cannot compute a merge commit,
  # GitHub does not queue the `pull_request` workflow — the head SHA gets ZERO
  # check-runs and mergeStateStatus reads UNKNOWN/DIRTY. Read through the checks
  # alone that is indistinguishable from a slow CI, so every watcher in the fleet
  # folds it into :none/"pending" and waits forever on checks that will never exist.
  # That burned a full rework cycle: a watcher armed at 05:47Z on a commit that never
  # got checks, and the cure was a rebase, which triggered CI green 8/8 immediately.
  #
  # :pending and :ci_less demand OPPOSITE actions — one says wait, one says act — so
  # collapsing them is not a cosmetic loss. :ci_less is deliberately neither: not
  # green (nothing was verified), not red (nothing failed), not pending (nothing is
  # coming).
  #
  # THE CONJUNCTION IS LOAD-BEARING. Zero checks ALONE is not ci-less — a PR GitHub
  # affirms is mergeable simply has not started its run yet, and that IS a wait. Only
  # "no checks AND a REFUTED merge" is the third state. Likewise a PR that HAS checks
  # is never ci-less however ugly its merge state: the checks prove CI ran.
  #
  # --- ABSENCE OF SIGNAL IS NOT NEGATIVE SIGNAL (round 2) ---------------------
  #
  # The round-1 predicate asked a YES/NO question — "is the merge confirmed?" — and a
  # two-valued answer cannot represent "GitHub has not decided yet". It also answered
  # that question INCONSISTENTLY: an ABSENT `mergeable` counted as confirmed while an
  # explicit "UNKNOWN" did not, though both mean the same thing.
  #
  # That was not cosmetic. GitHub computes mergeability ASYNCHRONOUSLY after every
  # push, answering UNKNOWN until it lands, and a brand-new head SHA has zero
  # check-runs in that SAME window — so both halves of the conjunction go true at once
  # for a perfectly HEALTHY PR. That window is exactly when builders run these tools
  # ("push, open a PR, then run bin/dor-check"), and PRs #588/#601/#602 were all
  # observed flipping to UNKNOWN within seconds of an unrelated merge and settling
  # back with NO push. The harm is not the stale verdict — it is the INSTRUCTION the
  # verdict carries, "rebase and --force-with-lease", which a compliant agent obeys,
  # force-pushing a healthy branch and cancelling its in-flight CI.
  #
  # So mergeability is THREE-VALUED — :affirmed / :refuted / :unknown — and :unknown
  # is NEVER converted into an actionable negative. It is REPORTED (the verdict
  # carries `mergeability: :unknown`) so a reader can tell "GitHub has not decided"
  # from "checks are running", and there it stops.
  #
  # FAIL DIRECTION: uncertainty about GITHUB'S KNOWLEDGE falls toward wait; only an
  # affirmative negative blocks. The asymmetry justifies it — a wrong block
  # force-pushes a healthy branch, a wrong wait costs a bounded timeout.
  #
  # RUNNING OUT OF PATIENCE IS NOT EVIDENCE (round 3). Round 2 honoured that rule on
  # the first read and then broke it on the second: a bounded re-read let an
  # undetermined mergeability "settle" into a hard :ci_less, so the SAME payload this
  # module correctly called :none became a confident block five seconds later —
  # round 1's harm on a timer, and a direct contradiction of the paragraph above.
  #
  # The discriminator was never sound. ONE 5s retry against an ASYNCHRONOUS GitHub
  # computation that publishes no SLA cannot separate "still computing" from "will
  # never compute"; it only measures how long we were willing to wait. Licensing a
  # block on a stable unknown would need a live PR observed staying UNKNOWN
  # indefinitely, a bound sized to GitHub's real settling time, and a test of the
  # re-read loop itself. None of those existed, and the loop was untested — so the
  # bound is GONE, along with the sleep it put on a hot path that both dor-check and
  # pr-review call.
  #
  # :ci_less therefore has EXACTLY ONE PRODUCER: an affirmative negative (:refuted).
  # If a future change wants a stable-unknown to block, it has to bring that evidence.

  # mergeStateStatus values that prove GitHub COMPUTED the merge commit. Their
  # presence is settlement, whatever `mergeable` says: DIRTY is the computed NEGATIVE
  # (handled as :refuted / :conflicted), and UNKNOWN is the only "still computing"
  # answer. Keying off this field rather than `mergeable` is what makes {CLEAN +
  # mergeable UNKNOWN} — a self-contradictory input that round 1 called ci-less —
  # resolve correctly to "GitHub computed it; the run just has not started".
  SETTLED_MERGE_STATES = %w[CLEAN BLOCKED BEHIND UNSTABLE HAS_HOOKS DRAFT].freeze

  # PURE. What does GitHub say about this PR's mergeability — :affirmed, :refuted, or
  # :unknown?
  #
  # ORDER IS LOAD-BEARING, and getting it wrong was round 3's blocker 2 — round 1's
  # defect in mirror image. `mergeable` is computed asynchronously and LAGS, while
  # mergeStateStatus reports settlement, so a stale CONFLICTING must never outrank a
  # settled merge state: {CLEAN + CONFLICTING} classified :refuted and fired an
  # immediate force-push instruction at a healthy PR. Each rung, in order:
  #   1. DIRTY      — the settled NEGATIVE, and NOT a member of SETTLED_MERGE_STATES
  #                   (so rung 2 never matches it — do not add it there). It is tested
  #                   first because a LAGGING `mergeable` would otherwise mask it: a
  #                   DIRTY PR still reporting a stale `mergeable: MERGEABLE` would
  #                   reach rung 4 and be affirmed, and `mergeable: UNKNOWN` would fall
  #                   to :unknown — both wrong for a PR GitHub has settled as
  #                   unmergeable.
  #   2. SETTLED    — GitHub computed the merge. This is settlement, WHATEVER
  #                   `mergeable` says (the docstring the old order contradicted).
  #   3. CONFLICTING— an affirmative negative, but only once settlement is silent.
  #   4. MERGEABLE  — an affirmative positive, same rung logic.
  #   5. otherwise  — :unknown. Never a verdict; see the section above.
  def self.mergeability(view_raw)
    data = parse_view(view_raw)
    return :unknown unless data

    merge_state = data["mergeStateStatus"].to_s.upcase
    mergeable = data["mergeable"].to_s.upcase
    return :refuted if merge_state == "DIRTY"
    return :affirmed if SETTLED_MERGE_STATES.include?(merge_state)
    return :refuted if mergeable == "CONFLICTING"
    return :affirmed if mergeable == "MERGEABLE"

    :unknown
  end

  # PURE. The `gh pr view` payload as a Hash, or nil when it is not JSON.
  def self.parse_view(raw)
    data = begin
      JSON.parse(raw)
    rescue StandardError
      nil
    end
    data.is_a?(Hash) ? data : nil
  end

  # PURE. The WHOLE PR verdict: the view payload's early verdict, else the checks
  # fold, with the ci-less upgrade applied to a bare :none. This is the seam the unit
  # vectors drive (pending / ci-less / green / red) without touching the network.
  #
  # There is NO second-look parameter, deliberately — see "running out of patience is
  # not evidence" above. One read, one verdict.
  # PURE. Has this PR's BASE moved out from under the run that produced its checks?
  #
  # :behind — GitHub says the head branch is behind its base. `gh pr checks` answers
  #           for the HEAD COMMIT, and .github/workflows/ci.yml triggers on
  #           pull_request and on pushes to main/release ONLY — a merge into
  #           `accepted` moves the base WITHOUT re-running anything. So a green here
  #           is a true statement about a tree that is no longer the tree the merge
  #           would produce. That is not branch-protection colour; it is an expired
  #           verdict, and it is the shape that passed a review gate on 2026-08-13
  #           reading a green dated three days earlier against a base 30+ commits on.
  # :current — the base has not moved; the checks answer for the merge as it stands.
  # :unknown — GitHub has not computed mergeability yet, or sent nothing. NEVER
  #           reported as :current: "we could not tell" and "we checked, it's fine"
  #           are different facts, and collapsing them is how a stale verdict gets
  #           credited by default.
  def self.base_drift(view_raw)
    data = parse_view(view_raw)
    return :unknown unless data

    case data["mergeStateStatus"].to_s.upcase
    when "BEHIND" then :behind
    when "", "UNKNOWN" then :unknown
    else :current
    end
  end

  # PURE. The PR's head commit, as GitHub sees it RIGHT NOW. Carried so a caller can
  # ask whether the tree it is about to grade is that commit — the question the cert
  # fingerprint cannot answer on its own, because it hashes a LOCAL ref that a zap
  # pushed from another checkout never touched. "" when GitHub sent nothing: an absent
  # head is not a matching head, and ReviewTreeGuard treats it as unobservable.
  def self.head_oid(view_raw)
    data = parse_view(view_raw)
    return "" unless data

    data["headRefOid"].to_s
  end

  def self.combine(view_raw, checks_raw)
    early = view_verdict(view_raw)
    return early if early

    # Carried on EVERY checks-derived verdict, green included — especially green,
    # since that is the only state a gate credits.
    verdict = parse(checks_raw).merge(base_drift: base_drift(view_raw), head_oid: head_oid(view_raw))
    return verdict unless verdict[:state] == :none

    case mergeability(view_raw)
    when :refuted
      # An affirmative negative: GitHub says it cannot merge, so no CI is coming.
      # The ONLY producer of :ci_less.
      ci_less_verdict(view_raw)
    when :affirmed
      # GitHub computed the merge — the workflow just has not started. A real wait.
      verdict
    else
      # Undetermined: still a wait, but the uncertainty is NAMED rather than swallowed
      # into a bare :none, so a reader can tell "GitHub has not decided" from "checks
      # are running". `mergeability`, not `merge_state` — what is undetermined is
      # GitHub's ANSWER, and naming it after the raw mergeStateStatus field would
      # report a value GitHub may never have sent.
      verdict.merge(mergeability: :unknown)
    end
  end

  # PURE. The :ci_less verdict with the evidence a reader needs to act: what GitHub
  # reported, and the base to rebase onto.
  def self.ci_less_verdict(view_raw)
    data = parse_view(view_raw) || {}
    {
      state: :ci_less,
      merge_state: data["mergeStateStatus"].to_s.upcase,
      mergeable: data["mergeable"].to_s.upcase,
      base: data["baseRefName"].to_s
    }
  end

  # A `base` we can SAFELY interpolate into a runnable `git merge origin/<base>`.
  #
  # base is GitHub's `baseRefName` — an EXTERNAL value that pr-review and dor-check
  # write VERBATIM into task feedback a human then pastes into a shell. So the only
  # question that matters is a PROPERTY, not a set of known-bad spellings: is this a
  # plain git ref and NOTHING else? Assert the property (a placeholder must NEVER
  # reach a runnable command as a live shell token); a blocklist of "; $() ` |" would
  # miss the next metacharacter GitHub or an attacker picks.
  #   \A\w         — must START with a word char, so a leading `-` can never make git
  #                  or ssh read the ref as an OPTION (e.g. `--upload-pack=…`).
  #   [\w.\-/]*\z  — thereafter ONLY word chars, dot, dash, slash — the whole alphabet
  #                  a real branch/tag name draws from. EVERY shell-active character
  #                  (whitespace, ; | & $ ` ( ) < > quotes, glob) is excluded, so
  #                  nothing in a validated ref can open a second command, a
  #                  substitution, or a second argument.
  # `\w` is ASCII-only in Ruby by default ([A-Za-z0-9_]) — no Unicode look-alikes.
  # `..` is rejected separately: it satisfies the char class (`a..b`) yet is a range /
  # parent-traversal refspec, never a branch name, and never a safe merge target.
  SAFE_GIT_REF = %r{\A\w[\w.\-/]*\z}.freeze

  def self.safe_git_ref?(ref)
    ref = ref.to_s
    SAFE_GIT_REF.match?(ref) && !ref.include?("..")
  end

  # THE ONE REMEDY STRING for :ci_less. dor-check, pr-review and session-preflight all
  # CALL this (session-preflight requires this file for exactly that reason — round 2
  # caught it hand-rolling a rival message), so one PR cannot collect three cures.
  # Names (a) that no CI is coming, (b) why, and (c) the exact command — because
  # "pending" taught the reader to wait, and only a named action unteaches it.
  # ADVICE MUST FAIL SAFELY, NOT MERELY SUCCEED (round 3, blocker 3). The old text was
  # `git fetch origin && git rebase origin/<base> && git push --force-with-lease`.
  # But :ci_less fires on an affirmative negative — GitHub reporting REAL conflicts —
  # so the rebase halts, the `&&` chain stops silently, the push never runs, and the
  # operator is stranded mid-rebase with no next instruction and no mention of
  # resolving anything. So: no chaining past a step that can pause, the conflict work
  # named, and a way back stated (bin/dor-check's :conflicted wording gets this right;
  # this follows it, and prefers `merge` over `rebase` because a halted merge leaves
  # the branch itself untouched).
  #
  # AND NO PLACEHOLDER MAY REACH A RUNNABLE COMMAND (blocker 4): interpolating a
  # human-readable fallback produced `git rebase origin/the base branch`, which
  # pr-review then wrote into real task feedback. With no base resolved the commands
  # are OMITTED — an honest gap beats a command that cannot run.
  #
  # AND NO UNSAFE BASE MAY REACH A RUNNABLE COMMAND (round 5): base is GitHub's
  # baseRefName, an EXTERNAL string, and this remedy is pasted into a shell. A base
  # that is not a plain git ref (safe_git_ref?) is treated as UNRESOLVABLE and takes
  # the SAME omit path as an empty one — an honest gap beats an injectable command.
  # When a validated base IS interpolated it is still Shellwords.escape'd, so even if
  # the predicate is ever loosened nothing can inject (belt and suspenders).
  def self.ci_less_remedy(verdict = nil)
    v = verdict.is_a?(Hash) ? verdict : {}
    base = v[:base].to_s.strip
    detail = [v[:merge_state], v[:mergeable]].map(&:to_s).reject(&:empty?).join("/")
    detail = detail.empty? ? "" : " (GitHub reports #{detail})"
    diagnosis =
      "NO CI WILL RUN on this PR#{detail}: GitHub cannot compute a merge commit for it, so it never queues " \
      "the pull_request workflow and the head SHA has ZERO check-runs. This is NOT a slow CI — waiting can " \
      "never clear it."
    unless safe_git_ref?(base)
      return "#{diagnosis} The base branch could not be resolved to a safe git ref from the PR, so no commands " \
             "are given here: read the PR's base on GitHub, then bring it into the branch and resolve any conflicts."
    end

    "#{diagnosis} Fix — run these ONE AT A TIME, because the merge stops if it finds conflicts:\n" \
      "  git fetch origin\n" \
      "  git merge origin/#{Shellwords.escape(base)}\n" \
      "If it reports conflicts: resolve them, then `git add -A` and `git commit`. To return the branch to " \
      "exactly where it started instead, run `git merge --abort`. Once the tree is clean and committed, " \
      "`git push` and re-run this check — GitHub can then compute the merge commit and CI fires."
  end

  # THE ONE REMEDY STRING for :conflicted (mergeStateStatus DIRTY) — the twin of
  # ci_less_remedy. dor-check and pr-review both CALL this, so a conflicted PR
  # collects ONE cure, not two hand-rolled ones that drift. It reads the PR's ACTUAL
  # base (conflict-remedy-names-wrong-branch): the old wording hardcoded `git merge
  # origin/release`, but feature PRs target `accepted` under the accepted→release→main
  # ladder, so following it merged unreviewed release-only content into the branch.
  # Same failure-safe shape as ci_less_remedy: one command at a time (a DIRTY PR IS a
  # real conflict, so the merge halts), merge over rebase (a halted merge leaves the
  # branch untouched), a way back stated, and — with no base resolvable — the commands
  # OMITTED rather than a placeholder interpolated into a runnable `origin/<...>`. And,
  # because base is GitHub's baseRefName pasted into a shell, an UNSAFE base (not a
  # plain git ref) takes that same omit path, and a validated base is still
  # Shellwords.escape'd (round 5 — see ci_less_remedy's note).
  def self.conflicted_remedy(verdict = nil)
    v = verdict.is_a?(Hash) ? verdict : {}
    base = v[:base].to_s.strip
    diagnosis =
      "This PR is merge-CONFLICTED against its base (mergeStateStatus DIRTY): GitHub cannot compute a merge " \
      "commit for it, so it never queues the pull_request workflow and the head SHA has ZERO check-runs. This " \
      "is NOT pending CI — waiting can never clear it."
    unless safe_git_ref?(base)
      return "#{diagnosis} The base branch could not be resolved to a safe git ref from the PR, so no commands " \
             "are given here: read the PR's base on GitHub, then bring it into the branch and resolve the conflicts."
    end

    "#{diagnosis} Fix — run these ONE AT A TIME, because the merge stops when it finds conflicts:\n" \
      "  git fetch origin\n" \
      "  git merge origin/#{Shellwords.escape(base)}\n" \
      "If it reports conflicts: resolve them, then `git add -A` and `git commit`. To return the branch to " \
      "exactly where it started instead, run `git merge --abort`. Once the tree is clean and committed, " \
      "`git push` and re-run this check — GitHub can then compute the merge commit and CI fires."
  end

  # An AUTH/PERMISSION denial — the token is understood and REFUSED, as opposed to a
  # 404 (ambiguous: a force-pushed SHA answers 404 too) or a transport error. Matched
  # against the RAW gh output, because `gh api` prints the JSON error body on stdout
  # and its own "gh: … (HTTP 403)" line on stderr: we capture 2>&1, so the two arrive
  # CONCATENATED and JSON.parse rejects the result — a parsed-`message`-only check
  # would miss the very case that motivated this state.
  #
  # Deliberately NARROW. A state that cried "fix your token" at every missing SHA
  # would be its own species of lie, so 404/timeouts/`gh: command not found` keep
  # their old :unverified meaning.
  #
  # ORDER IS LOAD-BEARING — first match wins, and the patterns OVERLAP. GitHub
  # answers a rate limit with an HTTP 403, so :rate_limit MUST precede :forbidden;
  # reverse them and "API rate limit exceeded (HTTP 403)" prescribes a scope grant
  # for a token whose scopes are fine. Each cause and what it catches:
  #   :rate_limit     — "rate limit" / "abuse detection"; a 403 that is NOT a denial
  #   :credentials    — "bad credentials", an expired/revoked token, HTTP 401
  #   :authentication — "requires authentication"; no token presented at all
  #   :permissions    — "resource not accessible by …" (a fine-grained PAT or GitHub
  #                     App refused the scope — the rolio case, REST and GraphQL
  #                     alike) / "must have admin rights" (the branch-protection read)
  #   :forbidden      — a bare HTTP 403 with no stated cause. AMBIGUOUS ON PURPOSE:
  #                     the remedy REFUSES to guess a scope here (see unreadable_remedy).
  UNREADABLE_CAUSES = [
    [:rate_limit, /(?:api|secondary)?\s*rate limit|abuse detection/i],
    [:credentials, /bad credentials|token[^\n]*(?:expired|revoked)|\bHTTP 401\b|"status"\s*:\s*"?401"?/i],
    [:authentication, /requires authentication|authentication required/i],
    [:permissions, /resource not accessible by|must have admin rights/i],
    [:forbidden, /\bHTTP 403\b|"status"\s*:\s*"?403"?|\bforbidden\b/i]
  ].freeze

  def self.unreadable_cause(raw)
    text = raw.to_s
    UNREADABLE_CAUSES.each do |cause, pattern|
      return cause if pattern.match?(text)
    end
    nil
  end

  # Does this raw gh body say "your token was refused"?
  def self.permission_denied?(raw)
    !unreadable_cause(raw).nil?
  end

  # The :unreadable verdict, carrying the cause. `reason` is the first line of the
  # denial, trimmed — enough for the gate to print WHAT was refused, while the gate
  # itself supplies WHICH repo and WHICH scope to grant.
  def self.unreadable(raw)
    data = JSON.parse(raw) rescue nil
    reason = data.is_a?(Hash) ? data["message"].to_s : raw.to_s.lines.first.to_s.strip
    { state: :unreadable, cause: unreadable_cause(raw), reason: reason[0, 140] }
  end

  # PURE. "owner/repo" out of a PR URL (https://github.com/McRitchie-Studio/rolio/pull/23),
  # so a gate can NAME the repo whose CI it could not read. name_with_owner is
  # anchored at the end of the string and matches a REMOTE, not a PR URL.
  def self.repo_from_pr_url(pr_url)
    match = pr_url.to_s.strip.match(%r{github\.com[:/]+([^/\s]+)/([^/\s]+)/pull/\d+}i)
    match ? "#{match[1]}/#{match[2]}" : ""
  end

  # THE ONE REMEDY STRING, so dor-check, pr-review, and the release auditor all tell
  # the operator the same thing. A gate that cannot see must name (a) that it is a
  # CREDENTIAL fault, (b) the repo, (c) the exact grant, and (d) the verify command —
  # otherwise the reader's only move is to re-run it, which can never help.
  #
  # `cert_route:` PICKS THE LAST SENTENCE, and nothing else. The credential half of
  # this string is identical everywhere; only the ROUTE OUT differs, because only
  # some callers can honour a cert. It stays ONE string with a parameter rather than
  # two strings, for the reason the header gives: a second copy is a second thing to
  # forget, and the halves that must agree are then held apart by nothing.
  #
  #   cert_route: true  — the GATED path. A fresh full cert stands in for the unread
  #                       verdict, so naming bin/full-suite-check is an instruction
  #                       the gate goes on to honour (bin/dor-check's
  #                       full_cert_stands_in_for_ci?).
  #   cert_route: false — the EXEMPT (doc-only) path, where nothing stands in. Saying
  #                       "certify in full instead" there was a remedy the gate could
  #                       not honour: adding the cert produced a BYTE-IDENTICAL
  #                       refusal, so an operator who followed it burned a full-suite
  #                       run for nothing (/tasks/exempt-refusal-prints-dead-remedy).
  #
  # WHY THE DEFAULT IS `true`, SAID ACCURATELY. The parameter was added for the
  # CI-VERDICT callers, where a full cert has always stood in — so `true` preserves
  # what every pre-existing caller already printed. It is NOT a claim that every such
  # caller is on the gated path. The first draft of this comment said "every caller
  # that predates the parameter is on the gated path", and that was FALSE at two of
  # them on the day it was typed (bin/dor-check's pr_read_alert, which reached the
  # exempt path, and bin/release.rb's G3 gate). In a change whose entire subject is a
  # comment outrunning its behaviour, that was the same defect, newly written — so the
  # replacement below is a list of FACTS, and it does not hold itself honest:
  # test/lib/dor_check_exempt_ci_test.rb's CALL-SITE REGISTRY reads the SOURCE of every
  # production caller and fails when one appears, vanishes, or changes route. Add a
  # caller and the suite makes you classify it.
  #
  # THE CALL SITES AND THE ROUTE EACH IS ACTUALLY ON:
  #
  #   bin/lib/ci_gate.rb        FORWARDED — unread_ci_refusal's own cert_route:, which
  #                                         BOTH CiGate.verdict callers state (neither
  #                                         rides a default).
  #   bin/dor-check pr_read_alert
  #                             FORWARDED — four printing callers, each explicit, none
  #                                         on the default: the EXEMPT path passes
  #                                         false (nothing stands in once the tier gate
  #                                         is waived — this task's fix); the gated
  #                                         path and the two "could not be proven
  #                                         doc-only" branches pass true. Those three
  #                                         `true`s are ACCURATE ABOUT THE SUITE GATE
  #                                         and stale about themselves: in the REVIEW
  #                                         role a refused PR read is an ERROR no cert
  #                                         clears, so the offer is not honoured on
  #                                         those branches either. Pre-existing,
  #                                         unchanged here, and not flippable — `false`
  #                                         prints the doc-only denial, which is untrue
  #                                         on a code diff. What it wants is a THIRD
  #                                         route ("this refusal is not the suite
  #                                         gate's"), shared with the release.rb site
  #                                         below. Measured and left as a handle in
  #                                         test/lib/dor_check_exempt_ci_test.rb's
  #                                         honour-the-remedy property.
  #   bin/dor-check suite gate  true      — gated path; the cert it names is the cert
  #                                         full_cert_stands_in_for_ci? then credits.
  #   bin/dor-check submit note true      — gated path suggestion; suppressed when the
  #                                         review allow-list already refused.
  #   bin/pr-review             COMPUTED  — cert_route: !maybe_exempt, so the pre-review
  #                                         banner promises about the CI VERDICT exactly
  #                                         what the primary's gate-zero goes on to do
  #                                         with a cert on that same PR.
  #   bin/release.rb G3 pre-QA  DEFAULT   — and it SHOULD NOT BE. The local-cert route
  #                                         was deliberately retired at G3 (CI's verdict
  #                                         for the release SHA is the gate; there is no
  #                                         cert to substitute) and the line prints a
  #                                         literal `<task>` placeholder besides.
  #                                         Pre-existing, release-grain, unchanged by
  #                                         this task and out of its scope — named here,
  #                                         and filed as its own follow-up, so the next
  #                                         reader inherits the finding instead of
  #                                         rediscovering it.
  #
  # Both branches are pinned — a default that nobody asserts is how the wrong half goes
  # quietly stale.
  def self.unreadable_remedy(repo = nil, cause: nil, cert_route: true)
    where = repo.to_s.strip.empty? ? "this repo" : repo.to_s.strip
    fix = case cause&.to_sym
          when :permissions
            "The GitHub token cannot read check runs on #{where}. Fix: grant the `mcritchie-agent` GitHub App " \
              "`Checks: Read` (App settings → Permissions & events), approve the updated permissions on the " \
              "McRitchie-Studio installation, and confirm the installation covers #{where}. " \
              "Verify: gh pr checks <pr> --repo #{where}."
          when :credentials
            # REACHING THIS MEANS THE AUTOMATIC RETRY ALREADY FAILED. gh_read mints a
            # fresh App token and retries once on exactly this refusal, so by the time
            # an operator reads this line, a re-mint has already been tried and the
            # fault is upstream of the token — say that, instead of prescribing the
            # step that just ran.
            "GitHub rejected the active credential for #{where}, and the automatic App-token retry could not " \
              "replace it. Installation tokens live ~1h, and `gh`'s keyring is a SEPARATE store from " \
              "bin/gh-token's cache — nothing refreshes it, so the ambient login goes stale mid-session. Fix: " \
              "confirm 1Password is unlocked (`op whoami`), then run `eval \"$(bin/gh-auth-refresh --export)\"` " \
              "and retry the exact check read. That command refreshes BOTH stores for THIS session's lane " \
              "(agent, or deployer when GH_APP_ITEM says so) and reports the identity it installed; do NOT pipe " \
              "bin/gh-token into `gh auth login`, which `gh` refuses outright whenever GH_TOKEN is set. Verify " \
              "with `gh api rate_limit` — NOT `gh api user`, which an App installation token cannot call at " \
              "all, so a 403 there CONFIRMS App auth rather than diagnosing it."
          when :authentication
            "No accepted GitHub credential reached #{where}, and no App token could be minted to replace it. " \
              "Fix: confirm 1Password is unlocked (`op whoami`), then run " \
              "`eval \"$(bin/gh-auth-refresh --export)\"` (it refreshes this session's lane identity and prints " \
              "what it installed, never the token) and retry the exact check read. Verify with " \
              "`gh api rate_limit`."
          when :rate_limit
            "GitHub refused the read because its API rate limit was exhausted. Fix: inspect `gh api rate_limit`, " \
              "wait for the named reset or use an authorized credential with remaining quota, then retry."
          else
            "GitHub returned a forbidden response for #{where} without identifying a missing permission. Do not " \
              "guess a scope: confirm the credential is live with `gh api rate_limit` (`gh api user` cannot " \
              "answer — App tokens are forbidden from it by design), reproduce the exact check read, and use " \
              "GitHub's response to choose the credential or permission fix."
          end
    route = if cert_route
              "certify in full instead: bin/full-suite-check <task>."
            else
              # NO ROUTE IS NAMED because none exists here, and inventing one is the
              # defect. On the exempt path the tier gate is ALREADY waived, so there
              # is no suite whose result could be substituted for the verdict — the
              # cert would certify nothing and clear nothing.
              # "no local cert stands in" is the CONTRACT CLAUSE, spelled the same
              # here and in ci_gate.rb's :none/:unverified branch, because
              # test/lib/dor_check_exempt_ci_test.rb reads the printed refusal to
              # decide what the gate PROMISED and then executes that promise. One
              # spelling for one meaning is what lets the pin be a property instead
              # of a list of cases.
              "and no local cert stands in for it on a doc-only diff either: the shape/test-tier gate is " \
                "already waived, so there is no suite left to substitute. Fixing the credential is the only " \
                "route — this gate advances on a GREEN CI and nothing else."
            end
    "This is a CREDENTIAL fault or API limit, NOT a missing CI — re-running will never clear it. #{fix} " \
      "Until the check read works, the FAST-cert route cannot be credited on this repo (a fast cert needs a " \
      "GREEN CI it can actually read) — #{route}"
  end

  def self.gate_evidence(verdict, repo: nil)
    return {} unless verdict && verdict[:state] == :unreadable

    {
      "state" => "unreadable",
      "cause" => verdict[:cause].to_s,
      "reason" => verdict[:reason].to_s,
      "repo" => repo.to_s
    }
  end

  # --- THE ONE AUTHENTICATED GITHUB READ --------------------------------------
  #
  # EVERY gh read in this file goes through `gh_read`, for one reason: the ambient
  # `gh` credential goes stale MID-SESSION. The 2026-07-29 org migration replaced
  # PATs with GitHub App installation tokens that live ~1 hour, and `gh`'s KEYRING is
  # a SEPARATE store from bin/gh-token's cache with nothing refreshing it — so a gate
  # that read CI fine at 10:00 reports a CREDENTIAL fault at 11:05 on the same PR.
  #
  # That degradation is not cosmetic. :unreadable withholds the fast-cert credit from
  # the builder, and — worse — it is the REVIEW gate's AUTHORITATIVE CI verdict going
  # blind in the one place nobody re-reads. On 2026-08-13 it hit both review Carls in
  # a single wave and every dor-check run that day.
  #
  # THE RECOVERY ALREADY EXISTED. bin/ship and bin/pr-review both mint-once-and-retry
  # through GhAuthRetry; this file never opted in — the module's own warning ("N
  # scripts meant N chances to forget") coming true — so the fix is WIRING, not a
  # third copy. ACQUISITION STAYS IN bin/gh-token: one shared two-slot on-disk cache
  # at <projects>/.agents/github-tokens.json, so sibling agent processes reuse one
  # token instead of each minting its own.
  #
  # NARROW ON PURPOSE, in three ways the tests pin:
  #   * A NON-AUTH FAILURE IS RETURNED UNTOUCHED. This is the load-bearing one here,
  #     and it is why "retry on failure" would be wrong: `gh pr checks` exits
  #     NON-ZERO on a RED or PENDING PR while printing perfectly good JSON. Retrying
  #     on exit status alone would mint a token on every red PR in the fleet — and a
  #     404 or a merge conflict re-run with a fresh token just fails again, slower.
  #     Only the SHAPE of the refusal (GhAuthRetry.auth_failure?) may trigger a mint.
  #   * ONE mint per process, memoized — not one per call.
  #   * A mint that cannot happen returns gh's ORIGINAL refusal. The gate then prints
  #     what GitHub actually said, which is the honest thing to show.
  #
  # THE TOKEN IS NEVER PRINTED. It rides the retried child's environment and is never
  # echoed, logged, or written to disk by this file.
  #
  # A SHELL NO LONGER RUNS. These were backticks with `2>&1`; they are now argv-form
  # subprocesses, so a PR URL or API path can no longer reach a shell at all.
  #
  # AND THE SEAM IS SHARED, NOT COPIED. bin/dor-check's PR file-list read (the diff the
  # merge gate reasons about) had its own `gh api ... err: File::NULL` call, so the
  # SAME hourly expiry degraded it silently to the local git diff — the wrong artifact,
  # graded with no signal that a substitution happened. It now calls gh_read_status
  # below, which is why that variant exists.

  # The `gh` binary. CI_STATUS_GH_BIN is the TEST SEAM: it points the reads at a stub
  # so the stale-credential branch is reachable without a network, a real token, or a
  # wall clock. That branch is exactly the kind that shipped unwired for weeks
  # precisely because nothing safe could reach it.
  def self.gh_bin
    override = ENV["CI_STATUS_GH_BIN"].to_s.strip
    override.empty? ? "gh" : override
  end

  # Forget any minted token. Test seam (module state outlives one example) and a
  # deliberate hook for a long-lived process that wants to re-mint.
  def self.reset_gh_auth!
    @gh_token = nil
  end

  # The authenticated read, WITH ITS OUTCOME: [body, ok].
  #
  # Every reader inside THIS file classifies the BODY (gh prints its JSON error body
  # on stdout, so the payload itself says what went wrong) and never needs `ok` — but
  # a caller OUTSIDE it can, and bin/dor-check's PR file list is the case that proves
  # it. That read asks for `--jq '.[] | .filename'`, whose SUCCESSFUL output is a bare
  # list of paths and whose FAILED output is empty: body alone cannot tell "the PR
  # changed nothing" from "GitHub refused the token". Handing back the exit status is
  # what lets that gate refuse instead of silently grading the local working tree.
  def self.gh_read_status(*args)
    body, ok = gh_capture(args)
    return [body, ok] if ok || @gh_token || !GhAuthRetry.auth_failure?(body)

    @gh_token = GhAuthRetry.mint
    return [body, false] unless @gh_token

    gh_capture(args)
  end

  def self.gh_read(*args)
    gh_read_status(*args).first
  end

  # BOTH STREAMS, joined — the contract the old `2>&1` backticks established and that
  # every reader below depends on: `gh api` prints the JSON error body on STDOUT and
  # its status line on STDERR, and unreadable_cause classifies against the pair.
  # Handing back stdout alone would leave a 403 unclassifiable, turning a named
  # credential fault back into an anonymous :unverified.
  def self.gh_capture(args)
    env = @gh_token ? { "GH_TOKEN" => @gh_token } : {}
    out, err, status = Open3.capture3(env, gh_bin, *args)
    [[out, err].map(&:to_s).reject { |s| s.strip.empty? }.join("\n").strip, status.success?]
  rescue StandardError => e
    # gh missing or not executable. NOT an auth failure, and it must not be made to
    # look like one: it reaches the caller as the :unverified it has always been.
    ["#{e.class}: #{e.message}", false]
  end

  def self.evaluate(pr_url, injected = nil)
    pr = pr_url.to_s.strip
    raw = injected.to_s.strip
    return { state: raw.delete_prefix(INJECTED_STATE_PREFIX).to_sym } if raw.start_with?(INJECTED_STATE_PREFIX)
    return { state: raw.to_sym, failing: ["ci"], pending: ["ci"] } if TOKENS.include?(raw)

    if raw.empty?
      return { state: :no_pr } if pr.empty?

      # Verify the PR is OPEN and MERGEABLE before trusting its checks:
      #   * `gh pr checks` returns the HEAD commit's checks even for a CLOSED/MERGED
      #     PR, so a stale/abandoned pr_url with green historical checks would
      #     otherwise pass as a live green (carl's review catch);
      #   * a merge-CONFLICTED PR (mergeStateStatus DIRTY) gets NO checks at all —
      #     GitHub cannot compute the merge commit, so reading only the checks folds
      #     it into :none and the PR stalls forever (PR #509). One gh call reads both.
      #   * a PR whose base drifted past GitHub's merge computation gets no checks
      #     EITHER, without ever reading DIRTY — the ci-less third state, which needs
      #     `mergeable` + `baseRefName` from this same call to name its remedy.
      view = gh_read("pr", "view", pr, "--json", VIEW_FIELDS)
      verdict = view_verdict(view)
      return verdict if verdict

      raw = gh_read("pr", "checks", pr, "--json", "name,state,bucket")
      # combine, not parse: a bare :none here may be the THIRD STATE (no CI will ever
      # run), and only the view payload can tell the difference.
      return combine(view, raw)
    end
    parse(raw)
  end

  # PURE. The `gh pr view --json state,mergeStateStatus` payload → an EARLY verdict
  # (:closed / :merged / :conflicted / :unverified), or nil when the PR is OPEN and
  # mergeable — "no verdict here, go read the checks". Closed/merged outrank DIRTY:
  # "rebase and resubmit" is the wrong instruction for a dead review target. Only
  # DIRTY means conflicts — BEHIND/UNSTABLE/BLOCKED are CI/branch-protection colour
  # the checks read already covers, and UNKNOWN is GitHub still computing
  # mergeability (never invented as a conflict).
  def self.view_verdict(raw)
    data = begin
      JSON.parse(raw)
    rescue StandardError
      nil
    end
    state = data.is_a?(Hash) ? data["state"].to_s : ""
    unless %w[OPEN CLOSED MERGED].include?(state)
      # `gh pr view` is the FIRST gh call evaluate makes, so on a repo the token
      # cannot read we fail HERE — and must already name the cause.
      return unreadable(raw) if permission_denied?(raw)

      return { state: :unverified, reason: raw.to_s.lines.first.to_s.strip[0, 140] }
    end
    return { state: state.downcase.to_sym } unless state == "OPEN"
    # Carry the PR's base so conflicted_remedy can name the RIGHT branch to merge —
    # feature PRs target `accepted`, not a hardcoded `release`
    # (conflict-remedy-names-wrong-branch). Same field ci_less_verdict surfaces.
    if data["mergeStateStatus"].to_s.upcase == "DIRTY"
      return { state: :conflicted, merge_state: "DIRTY", base: data["baseRefName"].to_s }
    end

    nil
  end

  # gh's --json array → verdict. A non-array (an error message like "no checks
  # reported on the 'X' branch", or a `gh: command not found`) can't be a red gate,
  # so it degrades to :none / :unverified rather than blocking.
  def self.parse(raw)
    data = begin
      JSON.parse(raw)
    rescue StandardError
      nil
    end
    unless data.is_a?(Array)
      # ORDER MATTERS: the permission check runs BEFORE the "no checks" match. The
      # denial body is the rolio case verbatim (a GraphQL statusCheckRollup refusal),
      # and reading it as :none would tell the builder to wait for a CI that is
      # already green.
      return unreadable(raw) if permission_denied?(raw)
      return { state: :none } if raw.to_s =~ /no checks|no commit statuses/i

      return { state: :unverified, reason: raw.to_s.lines.first.to_s.strip[0, 140] }
    end

    fold(data)
  end

  # PURE. The verdict fold, shared by BOTH payload shapes: an array of checks
  # carrying a normalized `bucket` (pass/fail/pending/skipping/cancel). A failure
  # OUTRANKS a still-running check — a known-bad tree is never "not yet".
  # THE INVARIANT IS POSITIVE: :green iff EVERY check AFFIRMATIVELY passed or skipped.
  # It is NOT "nothing failed and nothing is pending" — that greens a bucket we do not
  # recognize (gh vocabulary drift, a malformed row), inventing a pass from the absence of
  # a known-bad reading. So an unrecognized bucket is UNSETTLED → :pending (no verdict yet),
  # exactly as the SHA path's check_run_bucket fail-safes an unknown conclusion to pending.
  def self.fold(checks)
    return { state: :none } if checks.empty?

    name = ->(c) { c["name"].to_s.empty? ? c["state"].to_s : c["name"].to_s }
    failing = checks.select { |c| %w[fail cancel].include?(c["bucket"].to_s) }.map(&name)
    return { state: :red, failing: failing } if failing.any?

    # Every remaining check must prove out as pass/skip. A pending run — or ANY bucket that
    # is neither a pass/skip nor a known fail — is "no verdict yet", never a green.
    unsettled = checks.reject { |c| %w[pass skipping].include?(c["bucket"].to_s) }.map(&name)
    return { state: :pending, pending: unsettled } if unsettled.any?

    { state: :green, count: checks.size }
  end

  # --- SHA-addressed CI: G3's AUDITOR ----------------------------------------
  #
  # `evaluate` above is PR-scoped, and a PR is the wrong subject for the release
  # tip: the SHA the G3 pre-QA gate certifies (`origin/release`) belongs to no PR.
  # So the gate asks GitHub about the COMMIT instead —
  # `gh api repos/{owner}/{repo}/commits/{sha}/check-runs` — and folds the answer
  # through the SAME verdict states above, so both callers speak one language.
  #
  # The payloads differ, hence the shim: `gh pr checks` hands back gh's normalized
  # `bucket`, while the check-runs API hands back the RAW GitHub pair
  # `status` (queued|in_progress|completed) + `conclusion` (success|failure|
  # neutral|cancelled|skipped|timed_out|action_required|stale|startup_failure|null).
  # CHECK_RUN_BUCKETS maps conclusion → bucket exactly as gh's own bucketing does;
  # anything not yet `completed` (and any conclusion GitHub adds later that we
  # don't know) is `pending` — never invented as a pass or a fail.
  #
  # NO CI DATA IS NOT A FAILURE. A release-tip SHA with no workflow run answers
  # `{"total_count":0,"check_runs":[]}` → `:none`. That is the state of the world
  # TODAY: ci.yml triggers on `pull_request` + `push: main`, so `release` builds
  # nothing until task `run-ci-on-release-branch` adds it. `:none` (and
  # `:unverified`, and `:pending` — a push-triggered run that has not settled) are
  # "no data", and no-data NEVER blocks a local gate.
  CHECK_RUN_BUCKETS = {
    "success" => "pass",
    "neutral" => "skipping",
    "skipped" => "skipping",
    "cancelled" => "cancel",
    "failure" => "fail",
    "timed_out" => "fail",
    "action_required" => "fail",
    "startup_failure" => "fail",
    "stale" => "fail"
  }.freeze

  # GitHub CI's verdict for ONE COMMIT. `nwo` is the "owner/repo" name-with-owner
  # (see name_with_owner); `injected` is the RELEASE_CI_STATUS seam — a bare token
  # (green/red/pending/none/unverified) or a raw check-runs payload — so the tests
  # never shell out to gh (mirrors DOR_CHECK_CI_STATUS / PR_REVIEW_CI_STATUS).
  def self.for_sha(nwo, sha, injected = nil)
    raw = injected.to_s.strip
    if TOKENS.include?(raw)
      return { state: :red, failing: ["ci"] } if raw == "red"
      return { state: :pending, pending: ["ci"] } if raw == "pending"

      return { state: raw.to_sym }
    end

    if raw.empty?
      repo = nwo.to_s.strip
      commit = sha.to_s.strip
      return { state: :unverified, reason: "no GitHub owner/repo resolved" } if repo.empty?
      return { state: :unverified, reason: "no SHA to query" } if commit.empty?

      raw = check_runs_raw(repo, commit)
    end
    parse_check_runs(raw)
  end

  # The ONE check-runs read, shared by the verdict fold (for_sha) and the G3 credit
  # probe (credit_for_sha). NO --paginate. This endpoint returns an OBJECT
  # ({total_count, check_runs}), and past page 1 gh emits CONCATENATED JSON
  # documents, which JSON.parse rejects → :unverified. The auditor would go
  # SILENTLY BLIND on exactly the biggest suites (>30 runs) — the opposite of its
  # job. One page of 100 covers every suite in this ecosystem, and parse_check_runs
  # cross-checks the count it read against `total_count`, so a truncated read
  # reports itself instead of folding a partial list into a false green.
  def self.check_runs_raw(repo, commit)
    path = "repos/#{repo}/commits/#{commit}/check-runs?per_page=100"
    # Through the SAME authenticated seam as the PR reads. This one serves the G3
    # release gate, which reads a release tip belonging to no PR — the read least
    # likely to have a human watching when the credential goes stale.
    gh_read("api", path)
  end

  # PURE. A check-runs API payload → verdict. Accepts the API's envelope
  # (`{"total_count":…, "check_runs":[…]}`) or a bare array of runs, and degrades
  # a 404 / gh error / non-JSON body to :unverified — an auditor that cannot read
  # the record reports that it cannot read it, and never invents a red.
  def self.parse_check_runs(raw)
    data = begin
      JSON.parse(raw)
    rescue StandardError
      nil
    end
    runs = data.is_a?(Hash) ? data["check_runs"] : data
    unless runs.is_a?(Array)
      reason = data.is_a?(Hash) ? data["message"].to_s : raw.to_s.lines.first.to_s.strip
      # A 401/403 is a REFUSED token, not an absent record — say so. Checked against
      # the raw body (gh's stdout JSON + stderr line arrive concatenated under 2>&1),
      # then reported with the clean `message` when there was one to parse.
      return unreadable(raw).merge(reason: reason.strip[0, 140]) if permission_denied?(raw)

      return { state: :unverified, reason: reason.strip[0, 140] }
    end

    verdict = fold(runs.map do |run|
      { "name" => run["name"].to_s, "state" => check_run_state(run), "bucket" => check_run_bucket(run) }
    end)

    # A PARTIAL read can only be trusted when it found a FAILURE (a fail outranks
    # everything, so more runs cannot un-fail it). Any other fold over a truncated
    # list could be hiding a red on the page we never read — so report that we
    # could not see the whole record rather than manufacture a green.
    total = data.is_a?(Hash) && data["total_count"] ? data["total_count"].to_i : runs.size
    if runs.size < total && verdict[:state] != :red
      return { state: :unverified, reason: "read only #{runs.size} of #{total} check-runs" }
    end

    verdict
  end

  # PURE. status + conclusion → gh's bucket vocabulary. Not-yet-`completed` (and
  # any unknown conclusion) is `pending`: a run still in flight is not a verdict.
  def self.check_run_bucket(run)
    return "pending" unless run["status"].to_s.downcase == "completed"

    CHECK_RUN_BUCKETS.fetch(run["conclusion"].to_s.downcase, "pending")
  end

  # The fallback label for an unnamed run (fold names a check by its `state` when
  # `name` is blank) — the raw GitHub word, so the alarm text stays diagnosable.
  def self.check_run_state(run)
    conclusion = run["conclusion"].to_s
    conclusion.empty? ? run["status"].to_s : conclusion
  end

  # --- G3 CREDIT: an existing green conclusion for the SAME SHA ---------------
  #
  # The dedupe read for the pre-QA gate (task dedupe-hub-release-suite). When the
  # accepted→release promote FAST-FORWARDED, origin/release IS the accepted head
  # GitHub CI already built and greened at the PR/accepted seam — but the release
  # push queues a DUPLICATE run of the same checks on the same SHA, so `for_sha`
  # folds the commit :pending and the gate would wait out a suite that already
  # concluded. This probe answers ONE narrow question: does this exact SHA already
  # carry a COMPLETED green conclusion that the still-pending runs merely re-run?
  #
  # It returns a GREEN verdict carrying the credited source (`:credited`), or nil
  # ("no credit — take the normal path"). The caller asserts the fast-forward
  # itself (bin/release's pre_qa_gate); this half only reads the check-run record.
  #
  # The injection seam mirrors for_sha (RELEASE_CI_STATUS): a RAW check-runs
  # payload exercises the credit fold; a BARE token names a folded state, not
  # runs — no evidence of an existing conclusion, so it NEVER credits.
  def self.credit_for_sha(nwo, sha, injected = nil)
    raw = injected.to_s.strip
    return nil if TOKENS.include?(raw)

    if raw.empty?
      repo = nwo.to_s.strip
      commit = sha.to_s.strip
      return nil if repo.empty? || commit.empty?

      raw = check_runs_raw(repo, commit)
    end
    credited_verdict(raw)
  end

  # PURE. A check-runs payload → a credited GREEN verdict, or nil. Credits ONLY
  # when ALL of the following hold — anything else falls through to the normal
  # poll (pending still waits, red still aborts, missing checks still fail closed):
  #   * the read saw the WHOLE record (a truncated page could hide a red);
  #   * NO run failed or was cancelled — a red is never re-read as anything else;
  #   * at least one completed run PASSED (an all-skipped set certifies nothing);
  #   * something IS still pending (else the plain fold is already green — nothing
  #     to credit, the normal read passes on its own); and
  #   * every pending run re-runs a check NAME that already holds a completed
  #     pass/skip conclusion for this SHA. A pending check with NO completed
  #     counterpart (or no name to match on) is the ORIGINAL suite still running —
  #     a genuine wait, not a duplicate — so NO credit.
  def self.credited_verdict(raw)
    data = begin
      JSON.parse(raw)
    rescue StandardError
      nil
    end
    runs = data.is_a?(Hash) ? data["check_runs"] : data
    return nil unless runs.is_a?(Array)

    total = data.is_a?(Hash) && data["total_count"] ? data["total_count"].to_i : runs.size
    return nil if runs.size < total

    folded = runs.map { |run| { name: run["name"].to_s, bucket: check_run_bucket(run) } }
    return nil if folded.any? { |run| %w[fail cancel].include?(run[:bucket]) }

    concluded = folded.select { |run| %w[pass skipping].include?(run[:bucket]) }
    passed    = concluded.select { |run| run[:bucket] == "pass" }
    pending   = folded.select { |run| run[:bucket] == "pending" }
    return nil if passed.empty? || pending.empty?

    covered = concluded.map { |run| run[:name] }.reject(&:empty?)
    return nil unless pending.all? { |run| !run[:name].empty? && covered.include?(run[:name]) }

    { state: :green, count: concluded.size,
      credited: "#{concluded.size} completed check-run#{concluded.size == 1 ? '' : 's'} already green " \
                "(#{passed.size} passed); the #{pending.size} pending run#{pending.size == 1 ? '' : 's'} " \
                "duplicate#{pending.size == 1 ? 's' : ''} them" }
  end

  # PURE. A git remote URL → "owner/repo" for the gh api path, or "" when the
  # remote is not GitHub (a fork host, a local path). Handles the SSH
  # (git@github.com:owner/repo.git), HTTPS, and ssh:// forms.
  def self.name_with_owner(remote_url)
    match = remote_url.to_s.strip.match(%r{github\.com[:/]+([^/\s]+)/([^/\s]+?)(?:\.git)?/?\z})
    return "" unless match

    "#{match[1]}/#{match[2]}"
  end
end
