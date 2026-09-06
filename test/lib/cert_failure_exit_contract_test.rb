# frozen_string_literal: true

# [integration] THE EXIT-CODE CONTRACT of the handoff lane, executed.
#
# The rule, stated once: **a step that failed must never yield exit 0.** A caller
# that trusts the exit status — a harness, a background task notification, the
# next command in a chain — has nothing else to go on, and a silent success is
# the one failure nobody investigates, because nothing asks them to.
#
# WHAT THIS FILE IS, AND IS NOT. `bin/ship` and `bin/fast-check` were reported on
# 2026-08-29 to exit 0 after failing at step 2/8 in a repo with no `bin/rails`.
# Re-measured on this tree they BOTH exit 1, and the paths that made them exit
# correctly are dated: `b4f8fce8` (2026-08-25) turned an unlaunchable lane from an
# unrescued Errno::ENOENT into a red lane with a diagnosis. So these are not tests
# for a bug being fixed here — they are the regression net that was never under
# the contract, which is why the contract could be reported broken with no test to
# consult. There is no other executable statement of it anywhere in the repo.
#
# AND EVERY TEST HERE HAS A CONTROL. A file asserting "the exit code is 1" passes
# just as happily against a command that can only ever exit 1, and would then
# prove the opposite of what it claims. Each failure case is paired with a real
# success path through the same binary.
#
# READ `$?` BARE. The reported exit-0 could not be reproduced, and the likeliest
# explanation is the measurement: `bin/ship ... | tail -20` reports TAIL's status,
# which is 0 for every command on earth. These cases run the binary with no pipe.

require "bundler/setup"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "json"

class CertFailureExitContractTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SHIP = File.join(ROOT, "bin/ship")
  FAST_CHECK = File.join(ROOT, "bin/fast-check")

  # ------------------------------------------------------------- bin/ship ----

  def test_ship_exits_nonzero_when_the_cert_is_red
    out, code = ship(cert_exit: 1)

    assert_equal 1, code,
                 "ship stopped at 2/8 with a RED cert. Exiting 0 here tells every caller the task " \
                 "reached `submitted` when it is still [building] with nothing pushed."
    # PINNED ON THE DIE LINE, not on the word "failed". bin/fast-check now has TWO
    # non-zero verdicts — a RED lane, and a REFUSAL to certify a diff that would
    # execute no test (capped-cert-reports-green) — so ship's message names the step
    # and the verdict rather than asserting a red lane it cannot know about. Matching
    # a bare /bin\/fast-check/ would be satisfied by the "2/8 cert — running
    # bin/fast-check" line even if ship had actually died downstream, which is the
    # exact confusion the sibling case below was written to catch.
    assert_match(/bin\/fast-check did NOT certify/, out, "and it must say which step died")
  end

  # The OTHER shape of the same failure, and the one that reads as success most
  # easily: `system` returns nil (not false) when the command cannot be spawned at
  # all, and `nil` is falsey only if the caller tests it rather than rescuing.
  def test_ship_exits_nonzero_when_the_cert_runner_does_not_exist
    out, code = ship(cert_exit: :missing)

    assert_equal 1, code,
                 "a cert binary that cannot even be spawned certified nothing — that is a failure, " \
                 "not a skipped step"
    # NAMES THE STEP, not merely nonzero. Without this the case passes against a
    # ship that ignored the cert entirely and died later at the push instead —
    # measured: that mutation survived here while the sibling case caught it.
    assert_match(/bin\/fast-check did NOT certify/, out,
                 "the cert step must be what stopped the run, not something downstream of it")
  end

  # THE CONTROL. Without it, both assertions above are satisfied by a `bin/ship`
  # that exits 1 unconditionally. This drives a real exit-0 path through the same
  # binary: a task already past the seam is a no-op handoff, and a no-op is a
  # success.
  def test_ship_exits_zero_on_a_genuine_no_op
    out, code = ship(cert_exit: 1, stage: "shipped")

    assert_equal 0, code, "a task already past `submitted` is nothing to ship — that is not a failure"
    assert_match(/nothing to ship/, out)
  end

  # -------------------------------------------------------- bin/fast-check ----

  # The reported case, generalised: the cert's first lane names a command this
  # checkout does not carry (turf-vault is Anchor/Rust and has no bin/rails).
  def test_fast_check_exits_nonzero_when_the_prepare_runner_is_absent
    out, code = fast_check("FAST_CHECK_TEST_PREPARE_CMD" => "bin/rails db:test:prepare")

    assert_equal 1, code, "nothing was certified, so the cert must not report success"
    assert_match(/COULD NOT RUN/, out)
  end

  # THE DIAGNOSIS, which is the half that wastes an afternoon. "Fix it and re-run"
  # is advice with no fix behind it when the repo has no Rails runner and never
  # will — and "lane(s) RED" would send the reader hunting a regression in code
  # that never executed.
  def test_fast_check_does_not_misdiagnose_an_absent_runner_as_an_env_gap
    out, = fast_check("FAST_CHECK_TEST_PREPARE_CMD" => "bin/rails db:test:prepare")

    refute_match(/USUALLY an ENV gap/, out,
                 "an absent command is not an env gap the reader can close")
    refute_match(/lane\(s\) RED/, out,
                 "no test ran, so no lane is red")
    assert_match(/turf-vault-needs-ci/, out,
                 "and it must name the task that owns what a non-Rails cert lane should be, " \
                 "rather than leaving the reader with a refusal and no next step")
  end

  # Refusing, not skipping — the distinction the whole task turns on. A cert that
  # SKIPPED the lane would exit 0 and certify a repo whose tests never ran.
  def test_fast_check_refuses_rather_than_skipping_the_absent_lane
    out, = fast_check("FAST_CHECK_TEST_PREPARE_CMD" => "bin/rails db:test:prepare")

    refute_match(/fast cert green/, out, "a repo it could not prepare must never come back certified")
  end

  # THE LANE SUMMARY, which is a SECOND place the same misdiagnosis lives and
  # which the prepare-lane cases above never reach — they die one lane earlier. A
  # later lane whose runner is absent used to be folded into "lane(s) RED", which
  # tells the reader their tests failed when no test ever ran.
  def test_a_later_lane_with_an_absent_runner_is_not_reported_as_red
    out, code = fast_check("FAST_CHECK_SKIP_TEST_PREPARE" => "1",
                           "FAST_CHECK_TEST_CMD" => "bin/rails test")

    assert_equal 1, code, "nothing ran, so nothing is certified"
    assert_match(/COULD NOT RUN/, out)
    refute_match(/lane\(s\) RED/, out,
                 "a missing command is not a failing test — sending the reader to fix a regression " \
                 "in code that never executed is the same wrong errand, one lane further down")
  end

  # THE CONTROL for all three: the same binary, the same flags, one lane command
  # swapped for one that exists. If this did not go green, the assertions above
  # would be measuring a cert that cannot pass rather than one that correctly
  # refuses.
  def test_fast_check_exits_zero_when_every_lane_can_run
    out, code = fast_check("FAST_CHECK_SKIP_TEST_PREPARE" => "1")

    assert_equal 0, code, "with every lane runnable and green, the cert must succeed: #{out}"
    assert_match(/fast cert green/, out)
  end

  private

  # Drive the REAL bin/ship with a stubbed board CLI and a stubbed cert runner, in
  # a throwaway git repo. It never reaches the network: it dies at 2/8, or (the
  # control) returns before its first side effect.
  def ship(cert_exit:, stage: "building")
    with_repo do |tmp, repo, bin|
      write(bin, "task", <<~RUBY_STUB)
        #!/usr/bin/env ruby
        require "json"
        if ARGV[0] == "show"
          print JSON.generate({ "id" => 1, "title" => "Probe", "slug" => "probe-slug",
                                "stage" => #{stage.inspect},
                                "metadata" => { "devops" => { "branch" => "feat/probe-slug",
                                                              "checks_run" => [] } } })
        end
        exit 0
      RUBY_STUB
      unless cert_exit == :missing
        write(bin, "fast-check", "#!/bin/sh\necho 'stub cert: red' >&2\nexit #{cert_exit}\n")
      end
      # `gh` must exist but must never succeed: reaching it at all would mean the
      # cert failure did not stop the run.
      write(bin, "gh", "#!/bin/sh\necho 'stub gh should never be reached' >&2\nexit 1\n")

      File.write(File.join(repo, "a.txt"), "changed\n")
      capture(
        { "SHIP_TASK_BIN" => File.join(bin, "task"),
          "SHIP_FAST_CHECK_BIN" => File.join(bin, "fast-check"),
          "SHIP_GH_BIN" => File.join(bin, "gh"),
          "SHIP_ROOT" => repo, "SHIP_CI_WAIT" => "off",
          # bin/ship publishes a presence claim into the session-marker store
          # (bin/lib/presence_claim.rb), so this harness must PIN that store like
          # any other writer. Unpinned it is refused outright under the suite's
          # sandbox — which is the guard working — and, run standalone with the
          # sandbox off, it would write the operator's live .agents instead.
          # Pinned OUTSIDE `repo` on purpose: a marker inside the working tree
          # would be swept into ship's own 1/8 commit.
          "CLAUDE_PROJECTS_DIR" => File.join(tmp, "projects"),
          "CLAUDE_CODE_SESSION_ID" => nil, "CODEX_THREAD_ID" => nil },
        [SHIP, "probe-slug", "-m", "probe"], chdir: tmp
      )
    end
  end

  # Drive the REAL bin/fast-check standalone (`--print`, no task slug) so it runs
  # its lanes and writes NOTHING to the board.
  def fast_check(env)
    with_repo do |tmp, repo, _bin|
      base = { "FAST_CHECK_ROOT" => repo,
               "FAST_CHECK_CHANGED_FILES" => "",
               "FAST_CHECK_TEST_CMD" => "/usr/bin/true",
               "FAST_CHECK_RUBOCOP_CMD" => "/usr/bin/true",
               "FAST_CHECK_SPINE" => write_spine(tmp) }
      capture(base.merge(env), [FAST_CHECK, "--print"], chdir: tmp)
    end
  end

  # A real git repo with one commit — `bin/ship` commits, and `bin/fast-check`
  # fingerprints a git tree.
  def with_repo
    Dir.mktmpdir("exit-contract") do |tmp|
      repo = File.join(tmp, "repo")
      bin = File.join(tmp, "bin")
      FileUtils.mkdir_p([repo, bin])
      git(repo, "init", "-q", "-b", "feat/probe-slug", ".")
      git(repo, "config", "user.email", "test@example.com")
      git(repo, "config", "user.name", "Exit Contract Test")
      File.write(File.join(repo, "a.txt"), "one\n")
      git(repo, "add", "-A")
      git(repo, "commit", "-qm", "init")
      yield(tmp, repo, bin)
    end
  end

  # A spine with ONE REAL ENTRY, and that detail is load-bearing. fast-check skips
  # any spine path missing from the checkout, so an empty (or fictional) spine
  # means the test lane never runs at all — every case below then measures a cert
  # that skipped everything, and the "all lanes green" control would prove nothing
  # but that skipping succeeds. Measured: with an empty spine the absent-runner
  # case exited 0, because no lane ever reached for the runner.
  def write_spine(dir)
    path = File.join(dir, "spine.yml")
    File.write(path, "spine:\n  - a.txt\n")
    path
  end

  def git(repo, *args)
    out, status = Open3.capture2e("git", "-C", repo, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?
  end

  def write(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
    path
  end

  # NO PIPE. The whole reason the contract could be reported broken while holding
  # is that `cmd | tail -20` reports tail's status. capture2e reads the child's
  # own status.
  #
  # HERMETIC, and this cost a red cert to learn. `Open3.capture2e` MERGES its env
  # onto the parent's, and when this file runs as one lane of a real
  # `bin/fast-check` the parent is a `bin/rails test` holding the desk's test
  # database with `DATABASE_URL` exported. The child cert inherited it, resolved
  # the DESK rather than the throwaway repo this test built, and was refused by
  # the orphan guard — "the test DB ... is held by 1 other session(s): pid 44073
  # (bin/rails)", which is this test's own parent. Every fast-check case failed
  # for a reason that had nothing to do with what they assert, and they passed
  # standalone, which is the worst combination: green on the desk, red in the
  # suite. So the child starts from a SCRUBBED env — every FAST_CHECK_*/SHIP_*
  # and the database/Rails vars removed — and receives only what the case sets.
  INHERITED_PREFIXES = %w[FAST_CHECK_ SHIP_].freeze
  # TEST_DATABASE_URL is the one that actually did it: CertOrphanGuard.test_db_url
  # reads it FIRST, so an inherited value points the child cert's orphan check at
  # the DESK's test database — which this test's own parent is holding.
  INHERITED_NAMES = %w[TEST_DATABASE_URL DATABASE_URL RAILS_ENV MCRITCHIE_SESSION_KEY].freeze

  def capture(env, argv, chdir:)
    scrubbed = ENV.keys.select { |k| INHERITED_PREFIXES.any? { |p| k.start_with?(p) } }
    scrubbed.concat(INHERITED_NAMES)
    child = scrubbed.uniq.to_h { |k| [k, nil] }.merge(env)

    out, status = Open3.capture2e(child, *argv, chdir: chdir)
    [out, status.exitstatus]
  end
end
