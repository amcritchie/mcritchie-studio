# frozen_string_literal: true

# CiGate — the REVIEW GATE-ZERO's CI decision, as a pure function.
#
# Two callers in bin/dor-check ask it: the ordinary gated path, and the EXEMPT
# (doc-only) path, which until /tasks/gate-zero-skips-docs-ci never asked anything
# at all — its short-circuit `exit 0` sat above the allow-list, so a docs PR
# advanced a review on a CI nobody read. The fix gave the exempt path the same
# question to ask; putting the answer HERE is what stops the two from drifting into
# two allow-lists, which is a deny-list with extra steps.
#
# PURE ON PURPOSE. It shells nothing, reads no ENV and touches no board, so the
# gate's decision table is unit-testable without spawning bin/dor-check against a
# fixture — see test/lib/dor_check_exempt_ci_test.rb.
require_relative "ci_status"

module CiGate
  # The states that mean "CI HAS NO VERDICT TO GIVE" — as opposed to a verdict that is
  # bad (:red), settled-negative (:conflicted / :ci_less), still coming (:pending), or
  # not about a live review target (:closed / :merged). This is the ONLY family a full
  # local cert may stand in for, and membership is deliberately explicit: a state that
  # is not listed here cannot be excused by evidence, it can only be classified.
  CI_NO_VERDICT_STATES = %i[none unreadable unverified].freeze

  # The review role's refusal for a non-green CI → [message, cert_clears]. Never called
  # for :green (the allow-list's only pass) nor for a state `verdict`'s case below
  # already wrote a remedy for. `cert_clears` marks the no-verdict family, whose refusal a FULL
  # local cert clears — resolved after the suite gate, where suite_eval is known.
  #
  # ==== THE MESSAGE AND THE FLAG COME FROM ONE PARAMETER =======================
  #
  # `cert_route:` decides BOTH what this refusal offers and what the caller is then
  # allowed to accept. That coupling is the fix, not a convenience: the two used to be
  # decided in different files, and they drifted the moment the exempt path arrived.
  #
  # THE DEFECT (/tasks/exempt-refusal-prints-dead-remedy). The exempt caller asked for
  # this refusal, was handed `cert_clears = true` with it, and DISCARDED the flag —
  # correctly, because nothing stands in on that path. But the message it printed had
  # already promised the route the discarded flag was the only thing that could honour.
  # So the gate told the operator "certify in full instead: bin/full-suite-check
  # <slug>", and adding that cert produced a BYTE-IDENTICAL refusal. A remedy the gate
  # cannot honour is worse than a plain no: it teaches people the gate is noise, and an
  # ignored gate is how a genuinely RED CI ships.
  #
  # It cannot recur silently now. `cert_route: false` makes `cert_clears` false AT THE
  # SOURCE, so the caller has nothing to discard, and the same false flows into the
  # text. Changing one without the other means changing this one parameter — and
  # test/lib/dor_check_exempt_ci_test.rb re-derives the promise from the PRINTED
  # refusal and then executes it, in both paths, so a message that outruns its
  # behaviour reddens rather than shipping.
  # `also_refused:` is FORWARDED, NOT DECIDED HERE, for the same reason `cert_route:`
  # is: only the caller knows what ELSE is refusing the verdict this refusal joins.
  # It carries the OTHER live refusals as noun phrases, and the exempt closings below
  # name them instead of promising that a green CI alone would carry the path. See
  # CiStatus.unreadable_remedy's header for why that promise went stale (PR #1225).
  def self.unread_ci_refusal(ci, pr_url, slug, cert_route: true, also_refused: [])
    # THE SHARED FENCE, and it has to be here as well as in CiStatus. This method
    # FORWARDS the route to unreadable_remedy on one branch and BRANCHES ON IT on
    # another (`:none`/`:unverified`) that never reaches that method at all — so a
    # fence living only downstream would leave this branch open to exactly the
    # misspelled symbol it exists to catch. One list, one raise, both entry points.
    CiStatus.validate_cert_route!(cert_route)

    case ci[:state]
    when :unreadable
      # ONE remedy string, not one-and-a-half. unreadable_remedy ALREADY opens with
      # "This is a CREDENTIAL fault or API limit, NOT a missing CI — re-running will
      # never clear it", and ci_status.rb calls it THE ONE REMEDY STRING. Hand-writing
      # that sentence here printed it twice AND dropped the deliberate "or API limit"
      # hedge — which is not a nicety: :rate_limit also produces :unreadable, and a
      # reader told "CREDENTIAL fault" goes and rotates a credential that was fine.
      ["GitHub CI is UNREADABLE (#{ci[:reason]}) — the review gate-zero IS the authoritative CI verdict, and it " \
       "cannot be authoritative about a CI it could not read. " +
       CiStatus.unreadable_remedy(CiStatus.repo_from_pr_url(pr_url), cause: ci[:cause], cert_route: cert_route,
                                  also_refused: also_refused),
       cert_route == true]
    when :none, :unverified
      # WAITING IS THE REMEDY, and it is no longer half of one. This branch used to add
      # "or — if this repo has NO workflows at all, where no check will ever appear —
      # certify in full instead", on the premise that solana-studio and turf-vault
      # carried zero workflows. That premise is FALSE and was already corrected in
      # docs/agents/modules/gates/dor.md and pr-review-primary.md (PR #1128); this was
      # the third copy. Re-derived at source 2026-09-05 on `origin/accepted` AND
      # `origin/main`: solana-studio ships .github/workflows/gem-ci.yml, turf-vault
      # ships .github/workflows/ci.yml. "No check will ever appear" is not a property
      # of a repo in this ecosystem — when a check genuinely never arrives it is the
      # PR's MERGE STATE, which ci_status.rb classifies as :conflicted or :ci_less,
      # each with its own remedy and neither clearable by a cert.
      #
      # The cert route survives here only where it is honoured (cert_route), and it is
      # offered as the escape for a wedged verdict, never justified by a repo that has
      # no CI.
      #
      # `== true`, NOT TRUTHINESS, and that is finding (2) of this task's review. While
      # the route was true/false/nil, truthiness and equality agreed. `:retired`
      # (PR #1235) is a TRUTHY value whose entire meaning is that the cert route was
      # retired — so a plain `if cert_route` would offer `bin/full-suite-check` on the
      # one gate that can never honour it, and the tuple below would mark the refusal
      # cert-CLEARABLE besides. Unreachable today (both `verdict` callers pass
      # literals), which is exactly when it is cheap to close.
      cert_escape = if cert_route == true
                      " If checks genuinely cannot settle for this PR, certify in full instead: " \
                        "`bin/full-suite-check #{slug}`, which runs ci.yml's own command (test:system " \
                        "included) locally, and the gate advances on that cert."
                    else
                      # NAME NO SECOND ROUTE. On the exempt path there is none — see
                      # the header. Say what does not work, so nobody spends a
                      # full-suite run discovering it. "no local cert stands in" is
                      # the CONTRACT CLAUSE, spelled identically in
                      # CiStatus.unreadable_remedy's cert_route: false branch: the
                      # regression reads the PRINTED refusal to decide what was
                      # promised, then executes that promise, so the denial needs one
                      # spelling across every state that can carry it.
                      #
                      # THE SUFFICIENCY CLAUSE IS DERIVED for the same reason
                      # unreadable_remedy's is: "Green is the only thing that advances
                      # it" is the SAME promise PR #1225 falsified, in the same role,
                      # on the same path — it is simply reached with a different CI
                      # state. Fixing one closing line and leaving its twin two
                      # branches away would leave this method contradicting itself,
                      # which is the defect family the whole file is about. Empty
                      # prints the original, to the byte.
                      no_verdict_close = if also_refused.empty?
                                           "Green is the only thing that advances it."
                                         else
                                           "Green is NECESSARY AND NOT SUFFICIENT here: this verdict is " \
                                             "ALSO refused by #{also_refused.join(' AND ')}, which green " \
                                             "does not clear."
                                         end
                      " But no local cert stands in for it here: this is the doc-only path, where the " \
                        "shape/test-tier gate is already waived, so there is no suite to substitute — " \
                        "`bin/full-suite-check #{slug}` would leave this refusal unchanged. " \
                        "#{no_verdict_close}"
                    end
      ["GitHub CI has produced no verdict yet (#{ci[:state]}) — the review gate-zero IS the authoritative CI " \
       "verdict, so it must not advance on a CI it has not read. Defer this review until checks appear " \
       "and settle (the supervisor's defer machinery re-queries; a red finish bounces the task back).#{cert_escape}",
       cert_route == true]
    when :no_pr
      # NOT the no-verdict family, and a cert cannot stand in for it: the missing thing
      # is not the evidence, it is the SUBJECT. Review's job is to merge a PR; with a
      # blank pr_url there is nothing to read a verdict from and nothing to merge.
      ["devops.pr_url is BLANK, so the review gate-zero has no PR to read a CI verdict from — and review has " \
       "nothing to merge. Submit-side this is silent on purpose (the gate re-runs after the push); a REVIEW that " \
       "cannot name its PR must not advance the task, which is why this refuses rather than passing quietly. " \
       "Record it: `bin/task update #{slug} --pr-url <url>`.", false]
    else
      # THE POINT OF THE ALLOW-LIST. A state nobody has classified is not evidence of
      # health; it is evidence that this gate is out of date with ci_status.rb.
      ["GitHub CI reported #{ci[:state].to_s.upcase}, a state this gate does not classify — the review gate-zero " \
       "advances on a GREEN CI and nothing else, so an unclassified verdict REFUSES rather than falling through " \
       "to `ready`. Falling through is the bug this allow-list exists to prevent: a blank pr_url once exited 0 " \
       "with no CI line at all. Classify #{ci[:state].inspect} in bin/dor-check's CI gate and in " \
       "bin/lib/ci_status.rb's header, then re-run.", false]
    end
  end

  # THE CI VERDICT, RESOLVED IN ONE PLACE — for the gated path AND the exempt one.
  #
  # It lived inline in bin/dor-check's merge gate, which put it BELOW the exempt-kind
  # short-circuit's `exit 0`: a doc-only diff reached `ready` having never read CI at
  # all (/tasks/gate-zero-skips-docs-ci). Copying the case into the exempt branch
  # would have made two allow-lists to keep in step, and an allow-list that drifts is
  # a deny-list wearing the other one's comments. So both callers ask THIS.
  #
  # Returns [ci_error, cert_clears, notes]:
  #   ci_error    the refusal, or nil to advance
  #   cert_clears whether a FULL local cert may stand in for it (CI_NO_VERDICT_STATES
  #               only, and only where the caller can honour one) — resolved by the
  #               caller, which owns the evidence
  #   notes       non-blocking suggestions the caller folds into its own list
  #
  # `cert_route:` is the CALLER'S OWN ANSWER to "can I honour a cert?", and it governs
  # the refusal TEXT as well as `cert_clears` — see unread_ci_refusal's header. The
  # gated caller passes true; the exempt caller passes false, and gets a refusal that
  # promises nothing it will then refuse. It defaults to true so that adding a third
  # caller cannot silently weaken the gate: `true` is the permissive-message /
  # strict-enough-anyway side, and a caller that cannot honour a cert must say so.
  def self.verdict(ci, review_role:, pr_url:, slug:, cert_route: true, also_refused: [])
    ci_error = nil
    ci_error_cert_clears = false
    notes = []

    # THE CASE BELOW CHOOSES THE REMEDY. THE ALLOW-LIST AFTER IT CHOOSES THE VERDICT.
    # Keep that split: it is the whole fix. This case used to do both, and a case that
    # decides the verdict by naming bad states is a DENY-LIST — unbounded by
    # construction, because every state added to bin/lib/ci_status.rb afterwards
    # defaults to PASS, silently. That is not a hypothetical failure mode; it is how
    # :no_pr got here (see the allow-list's note). So the case now only picks the most
    # specific remedy text we have for a state, and `ready` is decided in exactly one
    # place, by asking for GREEN.
    case ci[:state]
    when :red
      ci_error = "GitHub CI is RED for the PR (#{Array(ci[:failing]).join(", ")}) — a red PR handed to review is the " \
        "#1 blocker class (the local cert doesn't run the browser test:system lane CI does). Fix, push, and re-run " \
        "dor-check once CI is green."
    when :conflicted
      # HARD blocker in BOTH roles, distinct from :pending/:none ("CI still coming",
      # genuinely deferrable): a conflicted PR's CI is never coming, so anything
      # softer strands the task in submitted forever (the PR-#509 stall).
      ci_error = "review's gate-zero would defer this forever while the board looks healthy. " +
        CiStatus.conflicted_remedy(ci)
    when :ci_less
      # The SAME hard-blocker shape as :conflicted, for the case that never reads DIRTY:
      # zero check-runs plus a merge GitHub will not confirm. Softer treatment strands
      # the task exactly like the PR-#509 stall — see the THIRD STATE section in
      # bin/lib/ci_status.rb.
      ci_error = CiStatus.ci_less_remedy(ci)
    when :pending
      if review_role
        ci_error = "GitHub CI is still RUNNING for the PR (#{Array(ci[:pending]).join(", ")}) — not green YET. The " \
          "review gate-zero is the authoritative CI verdict, so defer this review until CI settles (the supervisor's " \
          "defer machinery re-queries); a red finish bounces the task back."
      else
        notes << "GitHub CI is still RUNNING for the PR (#{Array(ci[:pending]).join(", ")}) — not green YET, " \
          "but submit-side this NO LONGER blocks: hand off now. The review gate-zero (bin/pr-review's supervisor + " \
          "the primary's dor-check --gate-role review) holds the authoritative verdict — a red CI bounces the task " \
          "back with the failing checks named, so expect that round-trip if CI fails."
      end
    when :closed, :merged
      ci_error = "the PR is #{ci[:state].to_s.upcase}, not an OPEN review target — `gh pr checks` returns the head " \
        "commit's HISTORICAL checks even on a closed/merged PR, so a green here is NOT a live pass. Reconcile " \
        "devops.pr_url (a stale or already-merged PR?) before advancing to review."
    when :green
      nil # THE ONLY PASS. Named explicitly so the allow-list below reads as exhaustive.
    else
      nil # Every remaining state — named or not — is the allow-list's to refuse.
    end

    # ==== THE REVIEW GATE-ZERO IS AN ALLOW-LIST =================================
    #
    # :green is the ONLY state that advances a review, and the no-verdict family is
    # the ONLY state that a full local cert may stand in for. Everything else
    # refuses — INCLUDING a state this gate has never heard of.
    #
    # WHY THE SHAPE AND NOT JUST THE STATES. The gate used to decide `ready` from a
    # deny-list of spellings (:red, :conflicted, :ci_less, :pending, :closed,
    # :merged) and let everything else fall through to a pass. A deny-list defaults
    # to PASS, so it is unbounded: the reader cannot tell "this state was considered
    # safe" from "nobody updated the list", and each new state silently joins the
    # safe side. That is exactly how :no_pr got here — a blank devops.pr_url resolves
    # to :no_pr, which had no branch and no `else`, so --gate-role review exited 0
    # printing "ready to advance" with NO CI LINE AT ALL: more silent than the
    # unread-verdict bug this gate was written to close. An allow-list defaults to
    # REFUSE, which is what a gate is for; adding a state to ci_status.rb now blocks
    # review until somebody classifies it deliberately.
    #
    # THE THREE TIERS:
    #   1. :green                → advance.
    #   2. CI_NO_VERDICT_STATES  → refuse, UNLESS the task carries a FULL cert AND the
    #                              caller can honour one (`cert_route`). On the exempt
    #                              path it cannot, so tier 2 collapses into tier 3 —
    #                              and the refusal SAYS so rather than offering a cert
    #                              it will not accept.
    #   3. everything else       → refuse, unconditionally.
    if review_role && ci_error.nil? && ci[:state] != :green
      ci_error, ci_error_cert_clears = unread_ci_refusal(ci, pr_url, slug, cert_route: cert_route,
                                                                          also_refused: also_refused)
    end

    [ci_error, ci_error_cert_clears, notes]
  end

  # The CI row the gates card shows for this run. Shared by both paths for the same
  # reason `verdict` is: the exempt path records a gate attempt now, and a second
  # copy of this case is a second thing to forget.
  def self.gate_row(ci, review_role:, review_refused:)
    return nil unless ci

    case ci[:state]
    when :green then "pass"
    when :pending then review_role ? "fail" : "pending"
    when :red, :conflicted, :ci_less, :closed, :merged then "fail"
    else
      # A FAILED dor_review must name CI as the failing SOP when CI is why it failed.
      # Leaving the no-verdict family on a flat "unverified" recorded the card's sole
      # cause as a NOTE — the same asymmetry :pending avoids one line above.
      # "unverified" stays right where CI genuinely only noted: any builder-side run,
      # and a review run whose FULL cert stood in for the unread verdict.
      review_refused ? "fail" : "unverified"
    end
  end
end
