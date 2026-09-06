# frozen_string_literal: true

# The EXEMPT (doc-only) path must read CI. Standalone — no Rails; the integration
# tier shells bin/dor-check with --file fixtures:
#   ruby -Itest test/lib/dor_check_exempt_ci_test.rb
#
# THE BUG (/tasks/gate-zero-skips-docs-ci). bin/dor-check's exempt-kind branch ended
# in a bare `exit 0`, and that `exit` sat ABOVE two things: the CI allow-list (whose
# own comment says ":green is the ONLY state that advances a review") and the
# gate-verdict emit. So `--gate-role review` — the run the pipeline calls THE
# AUTHORITATIVE CI VERDICT — never evaluated CI on a doc-only diff. --json returned
# ready=true, exempt=true, errors=[] with no `ci` key at all, and no `dor_review`
# attempt was written. Three doc-shaped PRs cleared gate-zero that way (turf-vault
# #9/#10, mcritchie-studio #1204); every one happened to be green, so the exposure
# was the next one.
#
# THE NULL ATTEMPT WAS THE SAME FACT, TWICE MISREAD. `dor_review` reading null on
# docs-shaped PRs was logged twice and filed as a cosmetic gap in the record. It was
# not a missing record: the gate had not run. So test_the_exempt_verdict_records_a
# _gate_attempt_in_both_directions is not a nicety — it pins the only observable the
# defect ever produced.
#
# WHAT MUST *NOT* CHANGE, and why this is a split rather than a moved block. Two
# unrelated guards lived below that `exit`, and only one of them should be skipped
# here: the shape/TEST-TIER gate is correctly waived (a prose diff owes no unit
# tier), while the CI allow-list never had any business being skipped — this repo's
# CI GRADES PROSE (doc-link checks, generated-doc drift, entry-doc guards, rubocop
# over bin/). "Ships no behavior" is not "cannot fail CI".
# test_the_tier_gate_is_still_waived_on_a_green_exempt_diff and its code-carrying
# control are what hold that line: relocating the CI block above the exit would pass
# every OTHER test in this file and fail those two.
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../../bin/lib/ci_gate"

class DorCheckExemptCiTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  PR_URL = "https://github.com/McRitchie-Studio/myapp/pull/7"
  DOC_DIFF = "docs/agents/modules/deployment.md"
  CODE_DIFF = "app/models/thing.rb"

  # An exempt KIND with a doc-only diff — the shape the gate waives tiers for.
  def devops(overrides = {})
    {
      "kind" => "docs", "pr_url" => PR_URL,
      "acceptance" => ["Runbook names the deploy strategy"],
      "repositories" => ["myapp"], "risk_tags" => ["docs"],
      "test_plan" => ["[unit] n/a"], "post_deploy_cmd" => "none"
    }.merge(overrides)
  end

  # Runs dor-check against an in-memory task, returns [parsed_json, exitcode].
  # STDOUT only: the child inherits bundler's env under `bin/rails test` and emits
  # rubygems warnings on STDERR, which would corrupt the --json parse if merged.
  # `pr_files:` defaults to the SAME list the diff is injected from — the readable
  # world, where the PR read succeeded and the exemption is proven against the PR
  # itself. Pass "unreadable"/"unverified" to drive the FAILED-read worlds, where a
  # non-PR source stands in and the exemption would otherwise be granted against an
  # artifact nobody asked about. It is a separate dimension from `changed:` for the
  # reason refusal()'s header states: a fixture that can only vary them together
  # cannot express the failure it is pinning.
  def check(devops_payload, ci: nil, role: "review", changed: DOC_DIFF, gate_bin: nil, args: "--json",
            pr_files: nil)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate("slug" => "exempt-task", "title" => "T",
                                     "metadata" => { "devops" => devops_payload }))
      env = OutboundSeams.env({
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => changed, "DOR_CHECK_PR_FILES" => pr_files || changed,
        "DOR_CHECK_CI_STATUS" => ci, "DOR_CHECK_GATE_BIN" => gate_bin
      }.compact)
      out = IO.popen(env, "#{BIN} exempt-task --file #{path} #{args} --gate-role #{role} 2>/dev/null", &:read)
      code = $?.exitstatus
      args.include?("--json") ? [JSON.parse(out), code] : [out, code]
    end
  end

  def errors_of(verdict) = Array(verdict["errors"]).join(" | ")

  # A recording stub for the gate CLI: every invocation's argv, one line per call.
  # This is the ONLY way to observe the durable attempt — --json and --file both
  # skip the board write by design, so a gate that records nothing and a gate that
  # records a pass are otherwise indistinguishable from a test.
  def with_gate_stub
    Dir.mktmpdir do |dir|
      log = File.join(dir, "gate-calls.log")
      bin = File.join(dir, "gate-stub")
      File.write(bin, <<~SH)
        #!/bin/sh
        printf '%s\\n' "$*" >> "#{log}"
      SH
      FileUtils.chmod(0o755, bin)
      yield bin, -> { File.exist?(log) ? File.readlines(log, chomp: true) : [] }
    end
  end

  # ── [unit] CiGate — the decision table both paths now share ─────────────────
  #
  # Pure: no subprocess, no ENV, no board. The exempt path's whole fix is that it
  # asks THIS instead of asking nothing, so the states it must refuse are asserted
  # here directly rather than inferred from a verdict's prose.

  def test_unit_green_is_the_only_state_that_advances_a_review
    error, = CiGate.verdict({ state: :green }, review_role: true, pr_url: PR_URL, slug: "t")
    assert_nil error, "green must advance"
  end

  def test_unit_every_non_green_state_refuses_a_review
    %i[red pending conflicted ci_less closed merged none unreadable unverified no_pr].each do |state|
      error, = CiGate.verdict({ state: state }, review_role: true, pr_url: PR_URL, slug: "t")
      refute_nil error, "#{state} must refuse a review"
    end
  end

  # THE ALLOW-LIST PROPERTY, not a longer deny-list: a state this gate has never
  # heard of refuses too. Testing only the real tokens cannot tell an allow-list
  # from a deny-list, and the difference is a live false pass.
  def test_unit_an_unclassified_state_refuses_rather_than_falling_through
    error, clears = CiGate.verdict({ state: :teal }, review_role: true, pr_url: PR_URL, slug: "t")
    assert_includes error.to_s, "does not classify"
    refute clears, "an unclassified state is not the no-verdict family and no cert clears it"
  end

  def test_unit_a_blank_pr_url_refuses_and_no_cert_can_clear_it
    error, clears = CiGate.verdict({ state: :no_pr }, review_role: true, pr_url: "", slug: "t")
    assert_includes error.to_s, "BLANK"
    refute clears, "the missing thing is the SUBJECT, not the evidence"
  end

  # The role split is load-bearing and must survive the extraction: the builder's
  # submit-side run is provisional by construction, so a pending CI is a note there
  # and a refusal in review.
  def test_unit_a_pending_ci_notes_for_the_builder_and_refuses_for_review
    error, _clears, notes = CiGate.verdict({ state: :pending, pending: ["ci"] },
                                           review_role: false, pr_url: PR_URL, slug: "t")
    assert_nil error
    assert_includes notes.join(" "), "NO LONGER blocks"

    review_error, = CiGate.verdict({ state: :pending, pending: ["ci"] },
                                   review_role: true, pr_url: PR_URL, slug: "t")
    assert_includes review_error.to_s, "still RUNNING"
  end

  def test_unit_gate_row_names_ci_as_the_failing_sop_when_ci_is_why_it_failed
    assert_equal "pass", CiGate.gate_row({ state: :green }, review_role: true, review_refused: false)
    assert_equal "fail", CiGate.gate_row({ state: :red }, review_role: true, review_refused: true)
    assert_equal "fail", CiGate.gate_row({ state: :pending }, review_role: true, review_refused: true)
    assert_equal "pending", CiGate.gate_row({ state: :pending }, review_role: false, review_refused: false)
    assert_equal "fail", CiGate.gate_row({ state: :unreadable }, review_role: true, review_refused: true)
    assert_nil CiGate.gate_row(nil, review_role: true, review_refused: false)
  end

  # ── [integration] the exempt path, end to end through bin/dor-check ─────────

  # THE REGRESSION. Written first, and it failed against the old `exit 0`:
  # ready=true, exempt=true, errors=[], no `ci` key.
  def test_a_red_ci_refuses_an_exempt_doc_only_review
    verdict, code = check(devops, ci: "red")

    assert_equal 1, code, "a red CI must refuse an exempt diff"
    refute verdict["ready"], "ready must follow the CI verdict, not the exemption"
    assert verdict["exempt"], "the TIER waiver is unchanged — only the CI verdict refuses"
    assert_includes errors_of(verdict), "GitHub CI is RED"
    assert_equal "red", verdict.dig("ci", "state")
  end

  # THE FIELD WHOSE ABSENCE MADE THE DEFECT INVISIBLE. An exempt verdict carried no
  # `ci` key at all, so no monitor could tell a green from a gate that never looked.
  def test_an_exempt_pass_still_publishes_the_ci_verdict_it_read
    verdict, code = check(devops, ci: "green")

    assert_equal 0, code
    assert verdict["ready"]
    assert verdict["exempt"]
    assert_equal "green", verdict.dig("ci", "state")
    assert_equal "pass", verdict["ci_gate_result"]
    assert_empty Array(verdict["errors"])
  end

  # THE NEIGHBOURS, not just red. The documented allow-list refuses each of these,
  # and an exempt task is no different.
  def test_pending_unreadable_and_unclassified_ci_all_refuse_an_exempt_review
    {
      "pending" => "still RUNNING",
      "unreadable" => "UNREADABLE",
      "unverified" => "no verdict yet",
      "none" => "no verdict yet",
      "conflicted" => "gate-zero",
      "closed" => "not an OPEN review target",
      "state:teal" => "does not classify"
    }.each do |injected, expected|
      verdict, code = check(devops, ci: injected)

      assert_equal 1, code, "#{injected} must refuse"
      assert_includes errors_of(verdict), expected
      assert_equal "fail", verdict["ci_gate_result"], "#{injected} must record CI as the failing sop"
    end
  end

  # A BLANK pr_url resolves to :no_pr WITHOUT any injection — the real path, and the
  # state whose silent fall-through is what the allow-list was written to close.
  def test_a_blank_pr_url_refuses_an_exempt_review
    verdict, code = check(devops("pr_url" => ""))

    assert_equal 1, code
    assert_includes errors_of(verdict), "devops.pr_url is BLANK"
    assert_equal "no_pr", verdict.dig("ci", "state")
  end

  # The builder's submit-side run stays provisional: review re-reads it, so a
  # pending CI is a note and a missing PR is silent. A fix that blocked BOTH roles
  # would stall every docs handoff on an hour-old token.
  def test_the_builder_role_keeps_its_provisional_treatment
    pending, code = check(devops, ci: "pending", role: "builder")
    assert_equal 0, code, "submit-side pending must not block"
    assert_includes Array(pending["suggestions"]).join(" "), "NO LONGER blocks"

    no_pr, no_pr_code = check(devops("pr_url" => ""), role: "builder")
    assert_equal 0, no_pr_code, "submit-side runs before the PR exists"
    assert_empty Array(no_pr["errors"])

    red, red_code = check(devops, ci: "red", role: "builder")
    assert_equal 1, red_code, "a RED CI blocks in BOTH roles"
    assert_includes errors_of(red), "GitHub CI is RED"
  end

  # ── the exempt path must CONFIRM that it IS exempt ─────────────────────────
  #
  # THE HOLE (/tasks/exempt-path-trusts-local-tree). The gated path role-splits a
  # failed PR-file read — ERROR for review, SUGGESTION for the builder — because the
  # reviewer's checkout is deliberately NOT the task's tree, so grading a substitute
  # there is the false pass gate-zero exists to refuse. The EXEMPT path had no such
  # split: `pr_read_alert` landed in `suggestions` for BOTH roles, so a doc-only
  # exemption could be earned from whatever tree the reviewer happened to be standing
  # in while the PR itself went unread. Measured on this branch before the fix: the
  # review and builder verdicts came back byte-identical, both `✓ … → ready to
  # advance submitted → reviewed`, off `[source: git working tree]`.
  #
  # SISTER DEFECT TO /tasks/gate-zero-skips-docs-ci, one door out. That one was "the
  # exempt path never asks CI"; this is "the exempt path never confirms it IS exempt."
  # Both let a review gate pass on evidence it did not actually read.
  #
  # BOTH FAILED-READ STATES, because only one of them was ever closed. A REVIEW-role
  # `:unreadable` is caught upstream in resolve_branch_diff (diff_source
  # :pr_unreadable → nothing observed → the "could not be proven doc-only" refusal),
  # but `:unverified` — gh missing, a 404, a transport error, an API outage — is a
  # FAILED read too, and it was never in that guard: it fell through to the local
  # working tree and reached the grant. Pinning only the credential state would
  # re-close the door that was already shut and leave the open one open.
  FAILED_PR_READS = %w[unreadable unverified].freeze

  def test_a_failed_pr_file_read_refuses_the_review_exemption
    # THE CONTROL FIRST, so this test cannot pass by refusing everything: the same
    # task, the same green CI, a READABLE PR file list — still exempt, still ready.
    readable, readable_code = check(devops, ci: "green", role: "review")
    assert_equal 0, readable_code, "a readable PR read must still earn the exemption:\n#{readable}"
    assert readable["ready"], "the control must pass, or the assertions below prove nothing"

    FAILED_PR_READS.each do |state|
      verdict, code = check(devops, ci: "green", role: "review", pr_files: state)

      assert_equal 1, code, "review + pr_files:#{state} must REFUSE the exemption:\n#{verdict}"
      refute verdict["ready"], "pr_files:#{state} — a gate that did not read the PR is not ready"
      assert_includes errors_of(verdict), ALERT_MARK,
                      "pr_files:#{state} — the refusal must be an ERROR, not a suggestion"
      assert_empty Array(verdict["suggestions"]).grep(/#{ALERT_MARK}/),
                   "pr_files:#{state} — the alert must MOVE to errors, not be printed twice"
    end
  end

  # THE FENCE (acceptance 2). The builder's local-tree fallback is DELIBERATE: they
  # stand in the task's own worktree, where the local view is the honest near-twin of
  # the PR, and their verdict is provisional by design. A fix that refused both roles
  # would stall every docs handoff behind an hour-old App token and buy no integrity.
  # Same unreadable input as the test above — only the role differs.
  def test_the_builder_role_keeps_its_local_tree_fallback_on_a_failed_pr_read
    FAILED_PR_READS.each do |state|
      verdict, code = check(devops, ci: "green", role: "builder", pr_files: state)

      assert_equal 0, code, "submit-side pr_files:#{state} must stay provisional:\n#{verdict}"
      assert verdict["ready"], "pr_files:#{state} — the builder's exemption still stands"
      assert_empty Array(verdict["errors"]), "pr_files:#{state} — nothing is an error submit-side"
      assert_includes Array(verdict["suggestions"]).join(" "), ALERT_MARK,
                      "pr_files:#{state} — but the substitution is NAMED, never silent"
    end
  end

  # THE RECEIPT SURVIVES THE PROMOTION. `pr_read` is how a monitor asks "was the PR
  # actually read?" of a verdict after the fact, and it used to be keyed off the
  # SUGGESTION list — so promoting the alert to an error would have blanked the field
  # in exactly the role where it matters most. Keyed off the refusal itself now.
  # THE BUILD GATE STAYS LENIENT, review role or not — the clause that says so must
  # not be inert. Measured: removing `gate != "build"` from the role split left every
  # other test in this file green, which is precisely the half-inert guard this task's
  # own discipline warns about. The build gate resolves no diff and must not shell
  # `gh`, so a PR read that failed there is not evidence of anything; line 2356's
  # gated-path twin carries the same clause for the same reason.
  def test_the_build_gate_never_refuses_on_a_failed_pr_read
    FAILED_PR_READS.each do |state|
      verdict, code = check(devops, role: "review", pr_files: state, args: "--json --gate build")

      assert_equal 0, code, "the build gate has no PR to judge (pr_files:#{state}):\n#{verdict}"
      assert_empty Array(verdict["errors"]), "pr_files:#{state} — nothing is an error at the build gate"
    end
  end

  def test_the_refused_read_is_recorded_on_the_exempt_payload_in_both_roles
    %w[review builder].each do |role|
      verdict, = check(devops, ci: "green", role: role, pr_files: "unverified")
      assert_equal "unverified", verdict.dig("pr_read", "state"),
                   "#{role}: the payload must record WHICH read failed"
    end
  end

  # ── [integration] the world the defect actually lived in ───────────────────
  #
  # Every case above injects the diff (DOR_CHECK_CHANGED_FILES), which is the
  # deterministic seam but NOT the shape of the bug: it short-circuits the resolver
  # before any fallback happens. Here the seam is absent and a REAL git tree stands
  # in — one dirty, unrelated prose file in a checkout that is not the PR. That is
  # the hub PRIMARY on a review night, and the file is the one that actually did it
  # on 2026-08-08: docs/agents/maintenance/delete-later.md.
  DIRTY_PROSE = "docs/agents/maintenance/delete-later.md"

  # A checkout whose only change is one unrelated prose file — no injected diff, so
  # the gate must fall back to (or refuse) the working tree. The task file lives
  # OUTSIDE the repo: inside, it reads as a code diff and the exemption never applies.
  def with_prose_only_checkout(role:, pr_files:)
    Dir.mktmpdir do |dir|
      system("git", "-C", dir, "init", "-q", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "config", "user.email", "t@t.t", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "config", "user.name", "T", out: File::NULL, err: File::NULL)
      File.write(File.join(dir, "README.md"), "base\n")
      system("git", "-C", dir, "add", "-A", out: File::NULL, err: File::NULL)
      system("git", "-C", dir, "commit", "-qm", "base", out: File::NULL, err: File::NULL)
      FileUtils.mkdir_p(File.join(dir, File.dirname(DIRTY_PROSE)))
      File.write(File.join(dir, DIRTY_PROSE), "one unrelated dirty note\n")

      Dir.mktmpdir do |taskdir|
        file = File.join(taskdir, "task.json")
        File.write(file, JSON.generate("slug" => "exempt-task", "title" => "T",
                                       "metadata" => { "devops" => devops }))
        env = OutboundSeams.env({
          "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
          "DOR_CHECK_PR_FILES" => pr_files, "DOR_CHECK_CI_STATUS" => "green"
        })
        out = IO.popen(env, "#{BIN} exempt-task --file #{file} --gate-role #{role} 2>/dev/null", &:read)
        yield out, $?.exitstatus
      end
    end
  end

  def test_a_reviewer_standing_in_a_foreign_prose_dirty_checkout_is_refused
    with_prose_only_checkout(role: "review", pr_files: "unverified") do |out, code|
      assert_equal 1, code, "the 2026-08-08 shape must REFUSE in the review role:\n#{out}"
      refute_includes out, "\u2192 ready to advance",
                      "a doc-only exemption earned off an unread PR is the false pass:\n#{out}"
      assert_includes out, ALERT_MARK
      # AND THE CLOSING LINE MUST NAME THE RIGHT REFUSAL. CI is GREEN in this
      # fixture, so a verdict that signs off "this refusal is the CI verdict" is
      # pointing the reader at the one thing that did not fail.
      assert_includes out, "the PR's own file list going unread",
                      "the refusal must say WHICH half refused:\n#{out}"
      refute_includes out, "the CI verdict, which an exempt diff does not escape",
                      "CI is green here — blaming it is the misnamed-refusal defect:\n#{out}"
    end
  end

  # THE SAME TREE, THE SAME REFUSED READ, THE BUILDER ROLE — still granted, and still
  # NAMED. This is the pair that proves the fix is role-scoped rather than a blanket
  # offline refusal, on input identical but for --gate-role.
  def test_the_same_tree_still_earns_the_builders_provisional_exemption
    with_prose_only_checkout(role: "builder", pr_files: "unverified") do |out, code|
      assert_equal 0, code, "the builder's provisional fallback must survive:\n#{out}"
      assert_includes out, "[source: git working tree]",
                       "the fixture must actually exercise the local-tree fallback:\n#{out}"
      assert_includes out, "ready to advance"
      assert_includes out, ALERT_MARK
    end
  end

  # ── the half that must stay skipped ────────────────────────────────────────

  # THE SCOPE GUARD. The task carries NO checks_run and no shape, and still passes on
  # a green CI: the tier gate is waived exactly as before. Relocating the CI block
  # above the exit instead of splitting the path passes the CI tests above and fails
  # this one, because the tier gate would come with it.
  def test_the_tier_gate_is_still_waived_on_a_green_exempt_diff
    verdict, code = check(devops, ci: "green")

    assert_equal 0, code
    assert_empty Array(verdict["missing_tiers"]), "a prose diff owes no unit tier"
    assert_empty Array(verdict["missing_metadata"])
    refute_includes errors_of(verdict), "tier"
  end

  # THE CONTROL for the line above: the exemption is EARNED FROM THE DIFF, so a
  # code-carrying diff under the same exempt kind falls through to the full gate and
  # IS asked for tiers. Without this, "no tier was demanded" could mean the gate is
  # waiving them for everyone.
  def test_a_code_carrying_diff_under_an_exempt_kind_is_still_gated
    verdict, code = check(devops, ci: "green", changed: CODE_DIFF)

    assert_equal 1, code
    refute verdict["exempt"], "code in the diff loses the exemption"
    assert_includes errors_of(verdict), "ships a code diff"
  end

  # ── the durable attempt ────────────────────────────────────────────────────

  # ACCEPTANCE 2. `dor_review` read null on every docs-shaped PR because the exempt
  # path exited above the emit. Both directions are asserted: a gate that only
  # records its refusals leaves the same hole for every green.
  def test_the_exempt_verdict_records_a_gate_attempt_in_both_directions
    with_gate_stub do |stub, calls|
      _out, code = check(devops, ci: "green", gate_bin: stub, args: "")
      assert_equal 0, code
      green_calls = calls.call
      assert(green_calls.any? { |c| c.start_with?("open task exempt-task dor_review") },
             "a green exempt review must OPEN a dor_review attempt — got #{green_calls.inspect}")
      assert(green_calls.any? { |c| c.start_with?("close task exempt-task dor_review --success") },
             "and close it successful — got #{green_calls.inspect}")
    end

    with_gate_stub do |stub, calls|
      _out, code = check(devops, ci: "red", gate_bin: stub, args: "")
      assert_equal 1, code
      red_calls = calls.call
      assert(red_calls.any? { |c| c.start_with?("close task exempt-task dor_review --failed") },
             "a refused exempt review must record a FAILED attempt — got #{red_calls.inspect}")
      assert(red_calls.any? { |c| c.include?('"sop":"ci"') && c.include?('"result":"fail"') },
             "and CI must be named as the failing sop — got #{red_calls.inspect}")
    end
  end

  # The builder's run closes `dor`, not `dor_review` — one verdict per gate. A
  # single emit that always wrote dor_review would make every submit look like a
  # review verdict on the gates card.
  def test_the_builder_role_records_the_dor_gate_not_dor_review
    with_gate_stub do |stub, calls|
      check(devops, ci: "green", role: "builder", gate_bin: stub, args: "")
      recorded = calls.call
      assert(recorded.any? { |c| c.start_with?("open task exempt-task dor ") || c == "open task exempt-task dor" },
             "builder-side must open `dor` — got #{recorded.inspect}")
      refute(recorded.any? { |c| c.include?("dor_review") }, "…and never dor_review — got #{recorded.inspect}")
    end
  end

  # The waiver is SAID OUT LOUD, in the text verdict a human actually reads. The old
  # line named only the skipped tier gate, so "no tier was demanded" and "no CI was
  # read" printed identically.
  def test_the_text_verdict_names_the_ci_state_behind_an_exempt_pass
    out, code = check(devops, ci: "green", args: "")

    assert_equal 0, code
    assert_includes out, "shape/test-tier gate skipped"
    assert_includes out, "GitHub CI: GREEN"
  end

  def test_the_text_refusal_says_the_tier_gate_was_still_waived
    out, code = check(devops, ci: "red", args: "")

    assert_equal 1, code
    assert_includes out, "the shape/test-tier gate IS waived"
    assert_includes out, "GitHub CI is RED"
  end

  # The build gate resolves no diff and must not shell `gh` — so it reads no CI and
  # writes no attempt. Leniency there cannot disarm anything: at design time no code
  # exists yet and the build gate enforces no tiers either way.
  def test_the_build_gate_reads_no_ci_on_an_exempt_task
    verdict, code = check(devops, ci: "red", args: "--json --gate build")

    assert_equal 0, code, "the build gate has no CI verdict to give"
    assert_nil verdict["ci"]
  end

  # ══ THE GATE MUST HONOUR THE REMEDY IT PRINTS — ON BOTH PATHS ════════════════
  #
  # THE DEFECT (/tasks/exempt-refusal-prints-dead-remedy). The exempt path took the
  # GATED path's refusal verbatim — "certify in full instead: `bin/full-suite-check
  # <slug>`" — while bin/dor-check discarded the `cert_clears` flag that was the only
  # thing able to honour it. Measured before the fix: adding that exact cert produced
  # a BYTE-IDENTICAL refusal. The gate printed an instruction it could not honour, and
  # an operator who followed it burned a full-suite run for nothing.
  #
  # WHY A TEST AND NOT A CAREFUL COMMENT. This bug is a MESSAGE that outran its
  # BEHAVIOUR, and the two live in different files. Nothing structural held them
  # together, so they drifted the moment a second caller appeared — and the same class
  # of drift produced five false comments in this ecosystem in one day, several
  # written by people fixing false comments. Prose cannot hold prose honest.
  #
  # HOW THIS PIN WORKS, and why it is a PROPERTY rather than a pair of cases: it does
  # not know which path offers a cert. It READS THE PRINTED REFUSAL, decides from that
  # text alone what the gate promised, and then EXECUTES the promise:
  #
  #   promised a cert     → running with a FULL cert MUST advance (exit 0).
  #   promised no cert    → running with a FULL cert MUST still refuse, and the
  #                         refusal must be BYTE-IDENTICAL — which is the defect's own
  #                         signature, asserted here as the PROOF that the denial is
  #                         accurate rather than as the bug.
  #
  # So neither half can move alone. Re-arm the cert route on the exempt path without
  # rewording, and the identical-refusal branch fails. Reword either message without
  # moving the behaviour, and the executed-promise branch fails. Both are mutated
  # separately in this file's sibling checks (see the task's mutation evidence).

  # THE CONTRACT CLAUSES. Each is spelled ONCE in the source (bin/lib/ci_gate.rb and
  # bin/lib/ci_status.rb) and read here to classify a refusal. They are deliberately
  # the wording an operator acts on, not an internal token: the thing under test IS
  # what the reader is told.
  OFFERS_CERT = "certify in full instead"
  DENIES_CERT = "no local cert stands in"

  # The GATED twin of `devops` — a code diff under a shaped bug, which is the path
  # where a full cert genuinely does stand in. Same states, same binary, opposite
  # answer; that contrast is what makes the property meaningful rather than a
  # restatement of the exempt path.
  GATED_CODE_DIFF = "app/models/thing.rb"

  def gated_devops(overrides = {})
    {
      "kind" => "bug", "shape" => "backend", "pr_url" => PR_URL,
      "acceptance" => ["Gate honours the remedy it prints"],
      "repositories" => ["myapp"], "risk_tags" => ["gates"],
      "test_plan" => ["[unit] x", "[integration] y"], "post_deploy_cmd" => "none",
      "checks_run" => ["[unit] bin/rails test test/x_test.rb",
                       "[integration] ruby -Itest test/lib/y_test.rb"]
    }.merge(overrides)
  end

  # Runs the REAL binary on either path with a stated suite-evidence world, and
  # returns [stdout, exitcode]. `evidence` is named at every call site with no
  # default, for the reason dor_check_test.rb states about its own `evidence:`:
  # accidental coverage of the cert dimension is one refactor from vanishing, and the
  # cert dimension is the entire subject here.
  # `pr_files:` IS A SEPARATE DIMENSION FROM `ci:`, AND THAT IS THE WHOLE POINT.
  # This helper used to pin DOR_CHECK_PR_FILES to the readable diff, which made
  # pr_read_alert nil in every case the property ever saw — so the property could not
  # observe the ONE state where the two halves of a verdict disagreed, and the gate
  # shipped an exempt refusal that DENIED a cert in the CI error and OFFERED one four
  # lines later in the PR-read suggestion. One stale token refuses BOTH reads, so
  # :unreadable co-fires on the PR file list and the check list; a fixture that can
  # only vary one of them cannot express the normal shape of the failure it is pinning
  # (/tasks/exempt-refusal-prints-dead-remedy, bounce 1).
  #
  # DOR_CHECK_CHANGED_FILES stays set: it is what keeps an unreadable PR read on the
  # EXEMPT branch. Without it a review-role run resolves diff_source :pr_unreadable,
  # observes nothing, and refuses at the "could not be proven doc-only" branch instead
  # — a different gate with a different contract, deliberately not this property's
  # subject.
  def refusal(path, ci:, evidence:, pr_files: :readable)
    payload, changed = path == :exempt ? [devops, DOC_DIFF] : [gated_devops, GATED_CODE_DIFF]
    injected_pr_files = pr_files == :readable ? changed : "unreadable"
    Dir.mktmpdir do |dir|
      file = File.join(dir, "task.json")
      File.write(file, JSON.generate("slug" => "remedy-task", "title" => "R",
                                     "metadata" => { "devops" => payload }))
      env = OutboundSeams.env({
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => changed, "DOR_CHECK_PR_FILES" => injected_pr_files,
        "DOR_CHECK_CI_STATUS" => ci, "DOR_CHECK_SUITE_EVIDENCE" => evidence
      })
      out = IO.popen(env, "#{BIN} remedy-task --file #{file} --gate-role review 2>/dev/null", &:read)
      [out, $?.exitstatus]
    end
  end

  FULL_CERT = "ok"              # bin/full-suite-check — ci.yml's own command, locally
  FAST_CERT_ONLY = "fast_fresh" # bin/fast-check — diff-mapped, not a stand-in for CI

  # THE PROPERTY. Read the promise off the printed refusal, then execute it.
  #
  # RUN OVER BOTH PR-READ WORLDS ON THE EXEMPT PATH. `:readable` is the isolated case
  # (only the check read was refused); `:unreadable` is the NORMAL one, where a single
  # stale token refuses the PR file list and the CI in the same run, so a verdict
  # carries the CI gate's refusal AND the PR-read alert together. The second world is
  # what the first cut of this pin could not reach, and it is the world the defect
  # lived in.
  #
  # THE GATED PATH IS RUN ON `:readable` ONLY, AND THE REASON IS A MEASUREMENT, NOT AN
  # OVERSIGHT. Adding gated×:unreadable to this list fails TODAY, and it failed
  # identically before this task touched anything: in the REVIEW role the PR-read alert
  # is an ERROR (grading a substitute for a refused read is the false pass gate-zero
  # exists to refuse), and no cert clears an error about the DIFF — so the verdict
  # names `bin/full-suite-check`, the operator runs it, the CI half duly clears, and
  # the run still exits 1 on the PR-read half. That is a real dead remedy, PRE-EXISTING
  # and unchanged in exposure by this task, and it is not fixable by flipping this
  # caller: `cert_route: false` prints the doc-only denial ("the shape/test-tier gate
  # is already waived"), which is false on a code diff. It wants a THIRD route — "this
  # refusal is not the suite gate's at all" — shared with bin/dor-check's "could not be
  # proven doc-only" branch and bin/release.rb's G3 gate. That is its own task; this
  # comment is the handle, and this line is where the pin extends to when it lands.
  def test_every_no_verdict_refusal_is_honoured_exactly_as_printed
    [%i[exempt readable], %i[exempt unreadable], %i[gated readable]].each do |path, pr_files|
      %w[none unverified unreadable].each do |state|
        label = "#{path}/#{state}/pr_files:#{pr_files}"
        refused, code = refusal(path, ci: state, evidence: FAST_CERT_ONLY, pr_files: pr_files)
        assert_equal 1, code, "#{label} must refuse without a full cert:\n#{refused}"

        offered = refused.include?(OFFERS_CERT)
        denied  = refused.include?(DENIES_CERT)
        # THE ASSERTION THAT CAUGHT THIS. A verdict may promise a cert or deny one; a
        # verdict that does BOTH has two printers disagreeing inside one refusal, and
        # the operator acts on whichever they read first. That is exactly what an
        # unreadable PR file list produced on the exempt path.
        refute_equal offered, denied,
                     "#{label} must either OFFER a cert or DENY one, never both or neither:\n#{refused}"

        certified, cert_code = refusal(path, ci: state, evidence: FULL_CERT, pr_files: pr_files)

        if offered
          assert_equal 0, cert_code,
                       "#{label} PRINTED #{OFFERS_CERT.inspect} — the gate must honour the remedy " \
                       "it prints:\n#{certified}"
          assert_match(/ready to advance/, certified)
        else
          assert_equal 1, cert_code,
                       "#{label} PRINTED #{DENIES_CERT.inspect}, so a full cert must NOT advance " \
                       "it:\n#{certified}"
          # THE DEFECT'S OWN SIGNATURE, now the proof of honesty. Before the fix this
          # sameness sat under a refusal that had just recommended the cert; the
          # denial is only accurate if the cert truly changes nothing.
          assert_equal refused, certified,
                       "#{label} says a cert does not stand in — so adding one must change " \
                       "NOTHING, byte for byte"
        end
      end
    end
  end

  # THE DIRECTION, asserted separately. The property above would still hold if BOTH
  # paths flipped together, which would be a deliberate policy change and must not
  # pass silently. This is the policy: a doc-only diff has no suite left to
  # substitute, so it gets no cert route; a code diff does.
  #
  # ALSO RUN WITH THE PR FILE LIST REFUSED, because that is where the direction was
  # actually broken: the CI half denied the cert and the PR-read half offered it, in
  # one verdict. `refute_includes … OFFERS_CERT` over the WHOLE exempt refusal is what
  # states the property at verdict grain rather than per-printer — a second printer
  # cannot reintroduce the offer without failing here.
  def test_the_exempt_path_denies_the_cert_route_and_the_gated_path_offers_it
    %i[readable unreadable].each do |pr_files|
      %w[none unverified unreadable].each do |state|
        label = "#{state}/pr_files:#{pr_files}"
        exempt_refusal, = refusal(:exempt, ci: state, evidence: FAST_CERT_ONLY, pr_files: pr_files)
        assert_includes exempt_refusal, DENIES_CERT,
                        "the exempt refusal must say plainly that no cert stands in (#{label})"
        refute_includes exempt_refusal, OFFERS_CERT,
                        "NO printer in an exempt verdict may name a route it cannot honour (#{label}):\n" \
                        "#{exempt_refusal}"

        gated_refusal, = refusal(:gated, ci: state, evidence: FAST_CERT_ONLY, pr_files: pr_files)
        assert_includes gated_refusal, OFFERS_CERT,
                        "the gated refusal must still name the cert that clears its CI verdict (#{label})"
        refute_includes gated_refusal, DENIES_CERT,
                        "a full cert DOES stand in for the gated path's unread CI verdict; denying it " \
                        "would be the mirror defect (#{label})"
      end
    end
  end

  # THE CONTROL FOR THE VARIANT ABOVE: prove the new input actually reaches the path.
  # A `pr_files: :unreadable` run that silently behaved like a readable one would make
  # every assertion above pass while testing nothing — the fixture-cannot-express-the-
  # bug failure. So assert the PR-read alert is PRESENT when the read is refused and
  # ABSENT when it is not; that alert is the second printer, and its presence is the
  # precondition for the offer/denial collision this task fixes.
  ALERT_MARK = "so this verdict did NOT read the PR"

  def test_the_unreadable_pr_file_list_variant_actually_reaches_the_second_printer
    with_alert, = refusal(:exempt, ci: "unreadable", evidence: FAST_CERT_ONLY, pr_files: :unreadable)
    assert_includes with_alert, ALERT_MARK,
                    "the pr_files: :unreadable world must actually fire pr_read_alert:\n#{with_alert}"

    without_alert, = refusal(:exempt, ci: "unreadable", evidence: FAST_CERT_ONLY, pr_files: :readable)
    refute_includes without_alert, ALERT_MARK,
                    "the readable world must NOT fire it, or the two worlds are the same test"
  end

  # ── [unit] the flag and the text come from ONE parameter ────────────────────
  #
  # The integration property above proves the two agree through the real binary. This
  # proves they CANNOT disagree at the source: `cert_route` decides the returned
  # `cert_clears` AND the wording, so there is no state in which a caller is handed a
  # clearable refusal whose text denies the cert (or the reverse). That was exactly
  # the defect's shape — bin/dor-check received `cert_clears = true`, discarded it,
  # and printed the offer the discarded flag was the only thing able to honour.
  def test_unit_cert_route_governs_the_flag_and_the_wording_together
    %i[none unverified unreadable].each do |state|
      ci = { state: state, reason: "403", cause: :permissions }

      offered, clears = CiGate.verdict(ci, review_role: true, pr_url: PR_URL, slug: "t", cert_route: true)
      assert clears, "#{state}: the gated path's refusal must be clearable by a full cert"
      assert_includes offered, OFFERS_CERT, "#{state}: a clearable refusal must name the route"
      refute_includes offered, DENIES_CERT

      denied, no_clears = CiGate.verdict(ci, review_role: true, pr_url: PR_URL, slug: "t", cert_route: false)
      refute no_clears, "#{state}: the exempt path's refusal must NOT be clearable"
      assert_includes denied, DENIES_CERT, "#{state}: an unclearable refusal must say so"
      refute_includes denied, OFFERS_CERT, "#{state}: it must not name a route it cannot honour"
    end
  end

  # The states OUTSIDE the no-verdict family never carried a cert route in either
  # direction, and must not grow one from this change: `cert_route` is about which
  # refusals a cert may clear, not about widening the family that may be cleared.
  def test_unit_cert_route_does_not_widen_the_no_verdict_family
    %i[red conflicted closed merged no_pr teal].each do |state|
      _error, clears = CiGate.verdict({ state: state, failing: ["ci"] },
                                      review_role: true, pr_url: PR_URL, slug: "t", cert_route: true)
      refute clears, "#{state} is not the no-verdict family — no cert clears it, whatever cert_route says"
    end
  end

  # THE THIRD COPY of a sentence corrected twice already (PR #1128 fixed
  # pr-review-primary.md and dor.md). "No check will ever appear" was justified by
  # "solana-studio and turf-vault carry zero workflows"; re-derived at source
  # 2026-09-05 on origin/accepted AND origin/main, solana-studio ships
  # .github/workflows/gem-ci.yml and turf-vault ships .github/workflows/ci.yml. The
  # claim is false, so the refusal must not rest on it — when a check genuinely never
  # arrives that is :conflicted / :ci_less, each with its own remedy.
  def test_unit_the_no_verdict_refusal_no_longer_blames_a_repo_without_workflows
    %i[none unverified].each do |state|
      message, = CiGate.verdict({ state: state }, review_role: true, pr_url: PR_URL, slug: "t",
                                                  cert_route: true)
      refute_match(/NO workflows at all/, message,
                   "#{state}: every repo here ships a pull_request workflow — that premise is false")
      refute_match(/no check will ever appear/i, message,
                   "#{state}: 'never' is a property of the PR's merge state (:conflicted/:ci_less), not a repo")
    end
  end

  # ── [unit] THE CALL-SITE REGISTRY — a comment that checks itself ────────────
  #
  # WHY THIS EXISTS. `CiStatus.unreadable_remedy` carries a comment naming every
  # production caller and the route each is on. The first version of that comment said
  # "every caller that predates the parameter is on the gated path", and it was FALSE
  # at two callers on the day it was written — one of which (bin/dor-check's
  # pr_read_alert on the exempt path) was the live defect that bounced this PR. Prose
  # about call sites goes stale the moment someone adds a call site, and nothing in a
  # code review reliably notices.
  #
  # So the list is pinned to the SOURCE. This does not judge whether a route is
  # correct — that is the property test's job, above, which executes the printed
  # promise. It judges only that the set of callers is the set the comment describes:
  # add a caller, delete one, or flip one between "states its route" and "takes the
  # default", and this fails and hands the author the comment to update.
  #
  # THE HASH IS KEYED BY FILE PATH, so on its own it can only ever audit the files
  # someone thought to type. The FILE SET is therefore globbed and asserted
  # separately — see `bin_files` and the set test below, which is what makes "add a
  # caller" true of a caller added in a FILE THIS HASH HAS NEVER HEARD OF.
  #
  # NUMBERS, and the reason for each:
  #   bin/lib/ci_gate.rb  1 stating / 0 default — unread_ci_refusal forwards its own
  #                       cert_route:, and both CiGate.verdict callers state it.
  #   bin/dor-check       1 stating / 2 default — the stating one is pr_read_alert,
  #                       which FORWARDS its callers' route (see below); the two
  #                       defaults are the suite-gate refusal and the submit-side
  #                       note, both on the GATED path where a cert genuinely clears.
  #   bin/pr-review       1 stating / 0 default — cert_route: !maybe_exempt.
  #   bin/release.rb      0 stating / 1 default — the G3 pre-QA gate, where the
  #                       local-cert route was retired. Known-wrong, pre-existing,
  #                       release-grain, filed as its own follow-up; pinned at 1 so
  #                       that fixing it (or adding a second) has to come back here.
  UNREADABLE_REMEDY_CALL_SITES = {
    "bin/lib/ci_gate.rb" => { states_route: 1, takes_default: 0 },
    "bin/dor-check" => { states_route: 1, takes_default: 2 },
    "bin/pr-review" => { states_route: 1, takes_default: 0 },
    "bin/release.rb" => { states_route: 0, takes_default: 1 }
  }.freeze

  # pr_read_alert's OWN callers, counted by route. It prints from four branches and is
  # used as a predicate (`pr_read_alert ? …`) in three more where the string is
  # discarded — the reason the method keeps a default at all.
  #   3 printing callers pass true  — the gated path, and the two "could not be proven
  #                                   doc-only" branches, where nothing is waived and
  #                                   the exempt denial's premise would be false.
  #   1 printing caller passes false — the EXEMPT path. This is the fix.
  PR_READ_ALERT_CALL_SITES = { true => 3, false => 1, predicate: 3 }.freeze

  REPO_ROOT = File.expand_path("../..", __dir__)

  # ONE spelling of the call, shared by both scans below. Two literals of the same
  # marker is exactly the drift this section exists to catch, written into the catcher.
  UNREADABLE_REMEDY_MARKER = "CiStatus.unreadable_remedy("

  # Source with FULL-LINE comments removed, so the registry counts CALLS and never the
  # prose about them — this file's own subject is prose drifting from behaviour, and a
  # checker fooled by a comment would be the joke writing itself.
  def code_of(relative)
    File.readlines(File.join(REPO_ROOT, relative))
        .reject { |line| line.strip.start_with?("#") }.join
  end

  # Every `<marker>(` in `source`, with the argument text of each call. Paren-balanced
  # rather than line- or regex-bounded: three of these calls already wrap across lines,
  # and a checker that missed them would under-count silently.
  def calls_to(source, marker)
    args = []
    offset = 0
    while (index = source.index(marker, offset))
      open = index + marker.length
      depth = 1
      cursor = open
      while depth.positive? && cursor < source.length
        depth += 1 if source[cursor] == "("
        depth -= 1 if source[cursor] == ")"
        cursor += 1
      end
      args << source[open...(cursor - 1)]
      offset = cursor
    end
    args
  end

  # THE CANDIDATE SET — GLOBBED, NEVER LISTED, and the reason is a mutation rather
  # than a tidiness preference. UNREADABLE_REMEDY_CALL_SITES is keyed by file path and
  # the count test iterates it, so for its whole life it opened exactly four files.
  # RE-MEASURED IN REVIEW, at this branch's own base (32 tests) and head (33). The
  # first draft of this paragraph quoted a 26-test head — numbers carried over from the
  # older tree the finding was found on, which is precisely the drift this file exists
  # to catch, written into itself. One probe, two placements: injected into
  # bin/dor-check the COUNT test kills it ("Expected: 2" default-takers, found 3); the
  # IDENTICAL caller in a NEW file, bin/lib/carl_probe.rb, SURVIVED the pre-change
  # test at 32 runs, 310 assertions, 0 failures — and is KILLED by the set test below
  # at 33 runs, 316 assertions, 1 failure naming the file. A fifth file was simply
  # never opened.
  #
  # That is more than a test nit, because bin/lib/ci_status.rb's header tells the next
  # reader this registry "fails when [a caller] appears, vanishes, or changes route.
  # Add a caller and the suite makes you classify it." True of the four listed files,
  # FALSE of a new one — so the hole in the test was a hole in a promise the
  # production code makes in prose. Widening the net here is what makes that sentence
  # honest without touching it.
  #
  # EVERY FILE UNDER bin/ — deliberately not `bin/**/*.rb`. Two of the four callers
  # the registry ALREADY names, bin/dor-check and bin/pr-review, are extensionless
  # scripts, so an extension-based glob is born blind to half the known set. Every
  # narrower rule is a hole of the same shape as the one being closed, and the widest
  # rule costs one `include?` over ~140 small text files.
  def bin_files
    Dir.glob("bin/**/*", base: REPO_ROOT)
       .select { |path| File.file?(File.join(REPO_ROOT, path)) }
       .sort
  end

  # THE FILE SET, asserted against the source — the half the per-file counts cannot
  # see. An unclassified file now FAILS loudly instead of going unread.
  def test_unit_the_registry_names_every_file_under_bin_that_calls_unreadable_remedy
    candidates = bin_files

    # CONTROL FIRST: prove the scan READ what it claims to have read. The set
    # assertion below is not vacuous when the glob matches nothing — but it IS
    # satisfied by any glob that reaches all four registry keys and nothing else,
    # which is the same blindness wearing a glob. `bin/**/*.rb` would drop the two
    # extensionless callers; `bin/*` plus `bin/lib/*.rb` would reach all four keys
    # while never descending into bin/lib/dor/checks/. Pin both properties that
    # narrowing destroys.
    %w[bin/dor-check bin/pr-review].each do |script|
      assert_includes candidates, script,
                      "the candidate glob must reach EXTENSIONLESS bin scripts — two of the four " \
                      "known callers are exactly that, so a glob that misses them was never " \
                      "auditing the set it reports on"
    end
    assert candidates.any? { |path| path.count("/") >= 3 },
           "the candidate glob must recurse BELOW bin/<dir>/ — bin/lib/dor/checks/ holds .rb today, " \
           "and a caller parked one level deeper must not be able to hide"

    callers = candidates.select { |path| code_of(path).include?(UNREADABLE_REMEDY_MARKER) }

    assert_equal UNREADABLE_REMEDY_CALL_SITES.keys.sort, callers,
                 "the SET OF FILES calling CiStatus.unreadable_remedy changed. A caller in a file " \
                 "this registry does not name is an unclassified promise about a remedy — decide " \
                 "its route, then update ci_status.rb's call-site list and the registry above. " \
                 "(A registry-only key means a caller vanished; a source-only file means a new one " \
                 "appeared.)\n" \
                 "registry: #{UNREADABLE_REMEDY_CALL_SITES.keys.sort.inspect}\n" \
                 "source:   #{callers.inspect}"
  end

  def test_unit_the_unreadable_remedy_call_site_registry_matches_the_source
    UNREADABLE_REMEDY_CALL_SITES.each do |file, expected|
      args = calls_to(code_of(file), UNREADABLE_REMEDY_MARKER)
      stating, defaulting = args.partition { |arg| arg.include?("cert_route:") }

      assert_equal expected[:states_route], stating.size,
                   "#{file}: callers STATING cert_route: changed. Update the call-site list in " \
                   "CiStatus.unreadable_remedy's header, then this registry — the comment is the " \
                   "deliverable, this test is only what keeps it true.\n#{stating.join("\n---\n")}"
      assert_equal expected[:takes_default], defaulting.size,
                   "#{file}: callers TAKING the cert_route: default changed. A new default-taker is a new " \
                   "promise nobody classified — decide its route, then update ci_status.rb's list and " \
                   "this registry.\n#{defaulting.join("\n---\n")}"
    end
  end

  def test_unit_every_printing_caller_of_pr_read_alert_states_its_route
    source = code_of("bin/dor-check")
    # The definition is not a call site. Dropped ENTIRELY, not renamed: a rename that
    # keeps the identifier as a prefix still matches the bare-use scan below, which is
    # how the first cut of this counted four predicates where three exist.
    source = source.sub(/^def pr_read_alert\(cert_route: true\)$/, "def PR_READ_ALERT_DEFINITION")

    printing = calls_to(source, "pr_read_alert(")
    assert_equal PR_READ_ALERT_CALL_SITES[true], printing.count { |arg| arg.include?("cert_route: true") },
                 "printing callers on the GATED/enforced branches changed:\n#{printing.join("\n---\n")}"
    assert_equal PR_READ_ALERT_CALL_SITES[false], printing.count { |arg| arg.include?("cert_route: false") },
                 "the EXEMPT caller is the one that must pass false — that is this task's whole fix:\n" \
                 "#{printing.join("\n---\n")}"
    assert_equal printing.size, printing.count { |arg| arg.include?("cert_route:") },
                 "a printing caller of pr_read_alert rode the default. That is exactly how the exempt path " \
                 "came to print an offer it could not honour:\n#{printing.join("\n---\n")}"

    # The predicate uses discard the string, so they are allowed to omit the keyword —
    # counted, not merely tolerated, so that a printing caller can never hide among them.
    predicates = source.scan(/pr_read_alert(?!\()/).size
    assert_equal PR_READ_ALERT_CALL_SITES[:predicate], predicates,
                 "bare `pr_read_alert` uses (predicate only — the string is discarded) changed to #{predicates}"
  end
end
