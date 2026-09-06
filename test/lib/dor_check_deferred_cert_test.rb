# frozen_string_literal: true

# THE FENCE. bin/dor-check's DEFERRED cert route — the half of
# capped-cert-blocks-the-pr that decides whether the change is a fix or a hole.
#   ruby -Itest test/lib/dor_check_deferred_cert_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# WHAT MOVED, AND WHY THE MOVE NEEDS A FENCE. bin/fast-check runs at ship step 2 of
# 8 — before the push, before the PR, before any CI exists. So its (correct) refusal
# of a diff it cannot certify left the builder with no PR, no CI, and one remedy: a
# local full suite, MEASURED at ~30 minutes against CI's ~9 for the identical
# command. A build paid that in full on 2026-09-06.
#
# THE REPO IS turf-monster, AND THAT IS NOT DECORATION. The refusal is a SATELLITE
# condition, not a cap condition, and the fixture has to be able to tell them apart.
# config/fast_cert_spine.yml has five entries and ALL FIVE exist only in the hub
# (measured 2026-09-06: turf-monster 0 of 5, rolio 0 of 5). So the same capped diff
# splits two ways, and both halves were observed the same day:
#
#   HUB  (release-offers-retired-cert): 51 paths over the cap → mapped lane skipped →
#        the SPINE still ran → certified green, accepted against a green CI. The cap
#        cost coverage, not the PR. This path must not change, and does not.
#   SATELLITE (empty-solana-network-fails-open, turf-monster): 29 paths over the cap →
#        mapped lane skipped → spine resolves to NOTHING → zero executed tests →
#        REFUSED, and the builder paid the ~30 minutes.
#
# So the condition being fixed is "this run will execute ZERO test files, and the only
# reason is a cap we imposed" — which on today's spine means the six non-hub repos.
#
# The remedy is to let a CAPPED diff push, open its PR, and let a GREEN CI carry the
# suite — so bin/fast-check now records a fingerprint-bound "[cert-deferred@<fp>]"
# receipt and exits 2 instead of dying, and THIS file is what stops that from being
# a fail-green one rung further along than the one PR #1226 closed.
#
# DEFERRING IS NOT SKIPPING, and these tests are the sentence that means:
#
#   green CI    → the gate is satisfied (the mapped tests ran; CI is where)
#   RED CI      → REFUSED
#   NO CI       → REFUSED  ← the designed-against failure: a capped diff that pushes,
#                            gets no CI at all, and submits on nothing
#   pending CI  → REFUSED (there is NO provisional twin for a deferral, deliberately:
#                          a fast cert may be credited against a pending CI because a
#                          real local run stands underneath it; a deferral has nothing)
#   stale receipt → REFUSED even on green (the CI graded a tree that is not this one)
#
# Standalone (no Rails): FullSuiteGate is `load`ed for the fingerprint, and
# bin/dor-check is shelled with --file fixtures.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

load File.expand_path("../../bin/lib/full_suite_gate.rb", __dir__)

class DorCheckDeferredCertTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  SLUG = "capped-cert-blocks-the-pr"
  BRANCH = "feat/#{SLUG}"
  # A SATELLITE, deliberately: the hub keeps a live spine under a cap and never reaches
  # this route at all. Grading the deferral against a hub fixture would test the repo
  # that does not need it.
  REPO = "turf-monster"

  # What bin/fast-check writes as the receipt's detail. Shaped like the real one so a
  # reader of a failure here sees what the board actually carries.
  DETAIL = "cert DEFERRED to GitHub CI: the mapped lane was CAPPED — 26 mapped path(s) over the " \
           "cap of 15 (widest: app/services/solana/config.rb → 24 test file(s)) — over a spine " \
           "this checkout resolves NONE of, so NO local lane could certify this tree."

  def git!(dir, *args)
    assert system("git", "-C", dir, *args, out: File::NULL, err: File::NULL), "git #{args.join(' ')}"
  end

  def write(dir, rel, body)
    full = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  # The task's own desk — …/<projects>/<repo>/.worktrees/<slug>, carrying an `origin`
  # for the repo (CertRootGuard reads the repo axis off the remote) and checked out on
  # the task branch. dor-check roots HERE, so the cert verdict under test is the
  # PRIMARY one and the fingerprint is this tree's.
  def with_desk
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      desk = File.join(projects, REPO, ".worktrees", SLUG)
      FileUtils.mkdir_p(desk)
      git!(desk, "init", "-q")
      git!(desk, "config", "user.email", "t@t.co")
      git!(desk, "config", "user.name", "T")
      write(desk, "README.md", "#{REPO}\n")
      git!(desk, "add", "-A")
      git!(desk, "commit", "-qm", "init")
      git!(desk, "remote", "add", "origin", "https://github.com/x/#{REPO}.git")
      git!(desk, "checkout", "-q", "-b", BRANCH)
      # A diff wide enough to be the real case: the file measured tripping the cap.
      write(desk, "app/services/solana/config.rb", "module Solana; class Config; end; end\n")
      git!(desk, "add", "-A")
      git!(desk, "commit", "-qm", "widen")
      yield projects, desk
    end
  end

  # The receipt bin/fast-check would have written for `desk`'s CURRENT tree.
  def receipt_for(desk)
    fp = FullSuiteGate.fingerprint(desk)
    refute_nil fp, "the fixture desk must fingerprint"
    FullSuiteGate.evidence_line(FullSuiteGate::DEFER_LANE, fp, DETAIL, repo: REPO)
  end

  # A backend task naming ONE repo, with a PR. Spec, tiers and acceptance are all
  # satisfied, so the ONLY thing these tests grade is the cert route.
  def task_json(checks)
    {
      "slug" => SLUG,
      "title" => "Capped Cert Blocks The PR",
      "metadata" => { "devops" => {
        "kind" => "bug",
        "shape" => "backend",
        "branch" => BRANCH,
        "worktree_slug" => SLUG,
        "pr_url" => "https://github.com/x/#{REPO}/pull/1",
        "repositories" => [REPO],
        "acceptance" => ["a capped diff still reaches its PR"],
        "risk_tags" => ["devops"],
        "test_plan" => ["[unit] a capped cert defers to CI"],
        "checks_run" => ["[unit] bin/rails test test/lib/dor_check_deferred_cert_test.rb",
                         "[integration] the deferred route refuses a red or absent CI"] + checks
      } }
    }
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, [ENV.key?(k), ENV[k]]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, (had, val)| had ? ENV[k] = val : ENV.delete(k) }
  end

  # Shell bin/dor-check --file, rooted at the desk. Suite-evidence injection is forced
  # OFF so the REAL fingerprint + evidence-grading path runs — the receipt under test
  # is graded exactly as a builder's would be. Only CI is injected.
  def dor_check(task, desk, projects, ci:, extra: {})
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      File.write(path, JSON.generate(task))
      env = {
        "DOR_CHECK_DIFF_ROOT" => desk,
        "DOR_CHECK_PROJECTS_DIR" => projects,
        "DOR_CHECK_SUITE_EVIDENCE" => nil,
        "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_DIFF_BASE" => nil,
        "DOR_CHECK_PR_FILES" => "",
        "DOR_CHECK_CI_STATUS" => ci
      }.merge(extra)
      out = nil
      with_env(env) do
        out = IO.popen(SessionEnv.neutralized, "#{BIN} --file #{path} --json 2>/dev/null", &:read)
      end
      [JSON.parse(out), $?.exitstatus]
    end
  end

  def defer_refusal(verdict)
    Array(verdict["errors"]).find { |e| e.include?("DEFERRED") || e.include?("DEFERRAL") }
  end

  # --- [integration] the route the change exists to open ---------------------------

  # ACCEPTANCE 2. A green CI satisfies G1 for a diff no local lane could certify —
  # the mapped tests DID run, on this exact tree, in the run the PR triggered anyway.
  def test_a_deferred_receipt_and_a_GREEN_ci_satisfy_the_suite_gate
    with_desk do |projects, desk|
      verdict, code = dor_check(task_json([receipt_for(desk)]), desk, projects, ci: "green")

      assert verdict["ready"], "a fresh deferral beside a GREEN CI is the whole remedy: #{verdict['errors']}"
      assert_equal 0, code
      assert_equal "deferred", verdict.dig("full_suite", "route"),
                   "it must be credited as DEFERRED, never quietly as a fast or full cert"
    end
  end

  # THE CONTROL. Strip the receipt and NOTHING else changes — same tree, same green
  # CI. Without this, every test above could be passing because green CI alone is
  # enough, which would be the hole rather than the fence.
  def test_a_GREEN_ci_with_NO_receipt_is_still_refused
    with_desk do |projects, desk|
      verdict, code = dor_check(task_json([]), desk, projects, ci: "green")

      refute verdict["ready"], "a green CI alone must never certify a diff — the receipt is what defers"
      assert_equal 1, code
      assert_nil verdict.dig("full_suite", "route")
    end
  end

  # --- [integration] ACCEPTANCE 3 — the fence -------------------------------------

  # A RED CI. The evidence the deferral pointed at came back negative; there is no
  # local run to fall back on, so the submit is refused.
  def test_a_deferred_receipt_with_a_RED_ci_refuses_the_submit
    with_desk do |projects, desk|
      verdict, code = dor_check(task_json([receipt_for(desk)]), desk, projects, ci: "red")

      refute verdict["ready"], "a deferral is not a skip — a RED CI must refuse"
      assert_equal 1, code
      refusal = defer_refusal(verdict)
      refute_nil refusal, "the refusal must name the DEFERRAL, not read as a missing cert: #{verdict['errors']}"
      assert_includes refusal, "RED"
      refute_includes refusal, "bin/fast-check #{SLUG})",
                      "re-running the cert re-defers — offering it as the remedy is a loop"
    end
  end

  # THE ONE THIS WHOLE FILE IS FOR. A capped diff that pushes, gets NO CI at all, and
  # would otherwise submit on nothing — recreating PR #1226's fail-green one rung
  # along. There is no evidence anywhere for this diff, and the gate says so.
  def test_a_deferred_receipt_with_NO_ci_at_all_refuses_the_submit
    with_desk do |projects, desk|
      verdict, code = dor_check(task_json([receipt_for(desk)]), desk, projects, ci: "none")

      refute verdict["ready"],
             "a deferral with NO CI has NO evidence anywhere — submitting on it is the fail-green this closes"
      assert_equal 1, code
      refusal = defer_refusal(verdict)
      refute_nil refusal, "expected a deferral refusal: #{verdict['errors']}"
      assert_includes refusal, "NO CI on this PR"
      assert_includes refusal, "NO evidence"
    end
  end

  # NO PROVISIONAL TWIN, and the asymmetry is deliberate. Submit-side, a fresh FAST
  # cert IS credited against a pending CI — because a real local run stands underneath
  # it. A deferral has nothing underneath it, so the same CI state must refuse.
  def test_a_deferred_receipt_is_never_credited_provisionally_on_a_pending_ci
    with_desk do |projects, desk|
      verdict, code = dor_check(task_json([receipt_for(desk)]), desk, projects, ci: "pending")

      refute verdict["ready"], "the fast lane's provisional credit must NOT extend to a deferral"
      assert_equal 1, code
      refute_equal "fast-provisional", verdict.dig("full_suite", "route")
      assert_includes defer_refusal(verdict).to_s, "still RUNNING"
    end
  end

  # A RECEIPT FOR A DIFFERENT TREE IS NOT A RECEIPT FOR THIS ONE. Edit after
  # deferring and the CI run the receipt points at graded code that is not what
  # would merge — the same staleness rule every other lane obeys, on the lane whose
  # whole content is a promise about a tree.
  def test_a_STALE_deferred_receipt_refuses_even_on_a_green_ci
    with_desk do |projects, desk|
      stale = receipt_for(desk)
      write(desk, "app/services/solana/config.rb", "module Solana; class Config; VERSION = 2; end; end\n")

      verdict, code = dor_check(task_json([stale]), desk, projects, ci: "green")

      refute verdict["ready"], "the code moved after the deferral — CI graded another tree"
      assert_equal 1, code
      refusal = defer_refusal(verdict)
      refute_nil refusal, "expected a STALE-deferral refusal: #{verdict['errors']}"
      assert_includes refusal, "STALE"
      assert_includes refusal, "bin/fast-check #{SLUG}",
                      "here re-running the cert IS the remedy — it re-defers against the new tree"
    end
  end

  # --- [unit] role independence ----------------------------------------------------

  # THE REVIEW GATE-ZERO GRADES IT THE SAME WAY, which is what keeps a deferred task
  # from dead-ending one rung later: review enforces the settled green, and a settled
  # green is precisely what this route already requires. Driven through the injected
  # verdict seam so the role is the only variable.
  def test_the_review_role_credits_a_deferred_receipt_on_green_and_refuses_without_it
    with_desk do |projects, desk|
      ready, = dor_check(task_json([]), desk, projects, ci: "green",
                                                        extra: { "DOR_CHECK_SUITE_EVIDENCE" => "deferred_fresh",
                                                                 "DOR_CHECK_PR_HEAD" => nil })
      assert_equal "deferred", ready.dig("full_suite", "route"),
                   "submit-side, an injected fresh deferral routes deferred: #{ready['errors']}"

      blocked, = dor_check(task_json([]), desk, projects, ci: "red",
                                                          extra: { "DOR_CHECK_SUITE_EVIDENCE" => "deferred_fresh" })
      refute blocked["ready"], "and a red CI refuses it in the same lane"
      assert_nil blocked.dig("full_suite", "route")
    end
  end

  # --- [unit] the injected tokens the seam above depends on ------------------------

  def test_the_injected_deferred_tokens_grade_only_the_defer_lane
    fresh = FullSuiteGate.injected_verdict("deferred_fresh")
    stale = FullSuiteGate.injected_verdict("deferred_stale")

    refute fresh[:ok], "a deferral is never a FULL cert — ok must stay false"
    assert_equal :fresh, fresh.dig(:lanes, FullSuiteGate::DEFER_LANE)
    assert_equal :missing, fresh.dig(:lanes, FullSuiteGate::FAST_LANE),
                 "the deferral must not masquerade as a fast cert"
    assert_equal :stale, stale.dig(:lanes, FullSuiteGate::DEFER_LANE)
  end

  # The lane has to be MACHINE-OWNED or an author `--checks` update wipes the receipt
  # and strands the build. Asserted against the shipped list, not assumed.
  def test_the_defer_lane_is_part_of_the_machine_owned_evidence_namespace
    assert_includes FullSuiteGate::EVIDENCE_LANES, FullSuiteGate::DEFER_LANE
    refute_includes FullSuiteGate::LANES, FullSuiteGate::DEFER_LANE,
                    "it must NOT be a lane the FULL cert waits on — that would demand it of every shape"
  end
end
