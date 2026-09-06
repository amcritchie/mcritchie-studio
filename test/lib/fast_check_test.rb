# frozen_string_literal: true

# Harness tests for bin/fast-check — the G1 FAST cert runner (diff-mapped tests
# + core spine + rubocop on changed files, recording "[fast-cert@<fp>]"
# fingerprint-bound evidence). Mirrors test/lib/full_suite_check_test.rb's seam
# pattern: the script is shelled with its lanes stubbed via FAST_CHECK_* env vars
# against throwaway git repos, so the ORCHESTRATION is exercised without a real
# Rails run; the board/gate CLIs are stubbed via FAST_CHECK_TASK_BIN /
# FAST_CHECK_GATE_BIN so the durable-record writes are asserted without a board.
# Selection logic itself is unit-tested in test/lib/fast_cert_test.rb.
# Run directly:
#   ruby -Itest test/lib/fast_check_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "shellwords"
require_relative "../support/session_env"
require_relative "../../bin/lib/full_suite_gate"

class FastCheckTest < Minitest::Test
  BIN = File.expand_path("../../bin/fast-check", __dir__)
  DOR = File.expand_path("../../bin/dor-check", __dir__)

  # THE CHILD CERT HAS NO DATABASE. Say so, or it inherits ours.
  #
  # Every test here spawns the REAL bin/fast-check against a THROWAWAY git repo in a
  # tmpdir — a repo with no database anywhere near it. But the child inherits this
  # process's env, and a worktree's `bin/rails test` exports TEST_DATABASE_URL (from
  # .env.test.local) AND holds an open connection to that database the moment anything
  # in the run loads test_helper. So the child cert resolved the DB from the INHERITED
  # env (test_db_url reads ENV before the root's dotenv), probed OUR worktree's test DB,
  # found one foreign backend holding it — THE TEST RUNNER THAT SPAWNED IT — and did
  # exactly what it is built to do: REFUSED. Exit 1.
  #
  #   fast-check: REFUSING — the test DB mcritchie_studio_test_<worktree> is held by 1
  #   other session(s): pid 505 (bin/rails).            # ← pid 505 IS the test runner
  #
  # 27 tests across this file and full_suite_check_test.rb went red that way under
  # `bin/rails test test/lib/` (the whole dir in ONE process), and stayed green when run
  # alone — because a bare minitest file opens no AR connection and there is then nothing
  # holding the DB. That difference reads as a spooky "inter-file interaction"; it is
  # only ever this, and it will red-light the cert's own mapped lane for anyone whose
  # diff touches these files alongside an AR-touching test.
  #
  # The fix is to stop lying to the child: this tmpdir repo has NO database. Unset the
  # inherited URL (test_db_url → nil → foreign_backends → [], no probe at all) and point
  # the probe at a psql that does not exist. cert_orphan_guard_reaper_test.rb already
  # carried this defence (its NO_DB_ENV); it simply never reached the two harness files.
  # The DB backstop is covered on its own terms there and in cert_orphan_guard_test.rb.
  NO_AMBIENT_DB = { "TEST_DATABASE_URL" => nil, "CERT_GUARD_PSQL" => "/nonexistent/psql" }.freeze

  # THE one place a child env is built in this file. Both scrubs — the agent session
  # (SessionEnv) and the ambient database (above) — are applied HERE, so a new spawn
  # site cannot quietly acquire either leak; patching five call sites one at a time is
  # how the fifth gets missed. Same discipline the guard itself now follows: ONE
  # predicate, not a rule repeated wherever someone remembers it.
  def child_env(overrides = {})
    SessionEnv.neutralized(NO_AMBIENT_DB.merge(overrides))
  end

  # --- [unit] the harness's own child env --------------------------------------------

  def test_child_env_never_hands_the_child_our_database
    env = child_env("FAST_CHECK_ROOT" => "/tmp/whatever")

    assert env.key?("TEST_DATABASE_URL"), "the key must be PRESENT and nil — that is what UNSETS it"
    assert_nil env["TEST_DATABASE_URL"],
              "a child cert rooted at a throwaway repo must not inherit THIS suite's test DB: it would " \
              "probe our database, find the test runner that spawned it holding a connection, and refuse"
    assert_nil env["CLAUDE_CODE_SESSION_ID"], "…and it still must not inherit the live agent session"
    assert_equal "/tmp/whatever", env["FAST_CHECK_ROOT"], "overrides still pass through"
  end

  def test_evaluate_grades_the_fast_lane_alongside_the_full_lanes
    checks = ["[fast-cert@abc1234] fast green"]
    assert_equal :fresh, FullSuiteGate.lane_status(checks, FullSuiteGate::FAST_LANE, "abc1234")
    assert_equal :stale, FullSuiteGate.lane_status(checks, FullSuiteGate::FAST_LANE, "fffffff")
    assert_equal :missing, FullSuiteGate.lane_status([], FullSuiteGate::FAST_LANE, "abc1234")
  end

  # --- fixtures --------------------------------------------------------------------

  # A temp git repo shaped like an app: a changed model + its convention test, a
  # spine test + spine config, and one committed baseline. Yields the dir.
  # `subpath:` puts the repo somewhere specific under the temp dir — e.g.
  # ".worktrees/<slug>", which is what makes it read as an agent DESK (DeskGuard).
  def with_repo(subpath: nil)
    Dir.mktmpdir do |tmp|
      dir = subpath ? File.join(tmp, subpath) : tmp
      FileUtils.mkdir_p(dir)
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      write = lambda do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      write.call("app/models/base.rb", "class Base; end\n")
      write.call("test/models/widget_test.rb", "widget test\n")
      write.call("test/models/spine_core_test.rb", "spine test\n")
      write.call("spine.yml", "spine:\n  - test/models/spine_core_test.rb\n")
      write_repo_shape(dir, subpath) if subpath
      # The harness writes its stub CLIs and their log INTO the repo dir, so without
      # this they read as untracked dirt to the dirty-tree guard (cert_tree_guard.rb)
      # — test tooling, not uncommitted work. Ignoring them keeps the fixture's dirt
      # HONEST: the only uncommitted file is the branch diff itself (widget.rb below).
      # stub.log* also covers the TASK stub's read-back sentinel (stub.log.updated).
      write.call(".gitignore", "stub.log*\n*-stub\n")
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("add -A")
      git.call("commit -q -m init")
      # The branch diff: a changed model that maps to test/models/widget_test.rb.
      write.call("app/models/widget.rb", "class Widget; end\n")
      yield dir, write
    end
  end

  # Make the fixture REPO-SHAPED, because the desk guard does not read a file — it BOOTS THE
  # APP and reads back the database it actually connects to (bin/lib/desk_guard.rb). A desk
  # fixture therefore needs the two things a real desk has:
  #
  #   * the REPO's config/database.yml — one level up from <repo>/.worktrees/<slug> — which
  #     is where the SHARED test database name is read from (ERB-stripped, so no env var can
  #     rewrite the value the resolution is compared against); and
  #   * a `bin/rails` to boot. The shim answers with DESK_DB_STUB, so each test STATES what
  #     the booted app would resolve to, and defaults to the SHARED name — the hazard.
  #
  # DESK FIXTURES ONLY. A plain `with_repo` (no subpath) is not under .worktrees/, so the
  # guard returns before it would boot anything and the shape buys nothing — while a
  # `bin/rails` it does not need would quietly rewrite two OTHER fixtures: the turf-monster
  # one asserts CiTestCommand still REFUSES a repo with no ci.yml, and the studio-engine one
  # asserts a gem has "no bin/rails to purge one with". Both would keep passing for the
  # wrong reason, or stop passing at all.
  def write_repo_shape(dir, subpath)
    repo_root = File.expand_path("../..", dir)
    FileUtils.mkdir_p(File.join(repo_root, "config"))
    File.write(File.join(repo_root, "config", "database.yml"), <<~YAML)
      default: &default
        adapter: postgresql
      test:
        <<: *default
        database: studio_test
    YAML

    FileUtils.mkdir_p(File.join(dir, "bin"))
    shim = File.join(dir, "bin", "rails")
    File.write(shim, "#!/bin/sh\necho \"DESKDB=${DESK_DB_STUB:-studio_test}\"\n")
    File.chmod(0o755, shim)
  end

  # A stub CLI: appends "<MARKER>\t<argv...>" to STUB_LOG_<MARKER>; exits 1 when
  # FAIL_TOKEN is set and appears in its argv, else 0. For the TASK stub, `show`
  # prints TASK_SHOW_JSON so the runner's read-then-write can be exercised.
  #
  # It is minimally STATEFUL so the cert's read-back is exercised end to end —
  # crucially INCLUDING the fresh evidence line, whose runtime fingerprint no
  # fixture can spell, so the only faithful way to model "the write landed" is to
  # reflect the ACTUAL written line back:
  #   * `update` drops a sentinel beside STUB_LOG and CAPTURES the --checks VALUES
  #     it stored (to .written), so a later `show` can echo them — the real board
  #     makes a write readable, which is the whole premise of the read-back.
  #   * `show` after an update serves TASK_SHOW_JSON_AFTER_UPDATE (else
  #     TASK_SHOW_JSON) with the captured lines merged in, so the read-back sees
  #     the evidence line the cert actually wrote. Overrides:
  #       - STUB_READBACK_DROP_WRITTEN=1 → do NOT merge the written lines (models a
  #         write that never landed — e.g. the evidence line vanished).
  #       - FAIL_SHOW_AFTER_UPDATE=1 → the post-write read itself fails (a blip).
  #     TASK_SHOW_JSON_AFTER_UPDATE with a line DROPPED still models a lost
  #     pre-existing line: the written evidence is merged back, that line is not.
  def write_stub(dir, name, marker)
    stub = File.join(dir, name)
    File.write(stub, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      log = ENV.fetch("STUB_LOG")
      File.open(log, "a") { |f| f.puts(["#{marker}", *ARGV].join("\\t")) }
      sentinel = log + ".updated"
      written  = log + ".written"
      if ARGV.first == "update"
        File.write(sentinel, "1")
        vals = []
        i = 0
        while i < ARGV.length
          if ARGV[i] == "--checks" then vals << ARGV[i + 1].to_s; i += 2 else i += 1 end
        end
        File.open(written, "a") { |f| vals.each { |v| f.puts(v) } }
      end
      if ARGV.first == "show"
        exit 1 if ENV["FAIL_SHOW_AFTER_UPDATE"] == "1" && File.exist?(sentinel)
        after = ENV["TASK_SHOW_JSON_AFTER_UPDATE"].to_s
        base  = (!after.empty? && File.exist?(sentinel)) ? after : ENV["TASK_SHOW_JSON"].to_s
        unless base.empty?
          doc = JSON.parse(base)
          if File.exist?(sentinel) && File.exist?(written) && ENV["STUB_READBACK_DROP_WRITTEN"] != "1"
            dv = ((doc["metadata"] ||= {})["devops"] ||= {})
            checks = Array(dv["checks_run"])
            File.readlines(written, chomp: true).each { |w| checks << w unless checks.include?(w) }
            dv["checks_run"] = checks
          end
          puts JSON.generate(doc)
        end
      end
      token = ENV["FAIL_TOKEN"].to_s
      exit(!token.empty? && ARGV.join(" ").include?(token) ? 1 : 0)
    RUBY
    FileUtils.chmod("+x", stub)
    stub
  end

  # Run bin/fast-check against `dir` with every seam stubbed. Returns
  # [stdout, exitcode, log_lines] where log_lines is the parsed stub log
  # ([[marker, argv...], ...] in call order).
  #
  # implicit_root: true drops the FAST_CHECK_ROOT override and runs the script
  # WITH `dir` as its cwd instead — the root resolves from the cwd git toplevel,
  # exercising the task-root guard (which an explicit override bypasses). stderr
  # is merged into stdout there so the refusal message is assertable.
  # A repo fixture that IDENTIFIES as a given slug. cert_repo comes from the
  # checkout's origin remote (CertRootGuard.repo_of_checkout), so a registry-driven
  # test cannot be written without one — a temp repo otherwise answers with its
  # random tmpdir name and matches no registry row.
  def with_repo_named(slug, release_check: nil)
    with_repo do |dir|
      assert system("git -C #{dir} remote add origin " \
                    "https://github.com/McRitchie-Studio/#{slug}.git >/dev/null 2>&1"),
             "could not name the fixture repo #{slug}"
      if release_check
        # The registry names bin/release-check for a gem; the fixture must carry one
        # or the lane is legitimately unlaunchable and the test proves nothing.
        FileUtils.mkdir_p(File.join(dir, "bin"))
        File.write(File.join(dir, "bin/release-check"), release_check)
        File.chmod(0o755, File.join(dir, "bin/release-check"))
      end
      yield dir
    end
  end

  GEM_GATE_OK = "#!/bin/sh\nexit 0\n"

  # --- gem repos on the BUILDER DEFAULT path -----------------------------------
  #
  # bin/full-suite-check learned to certify a gem repo; this script — the one
  # builders actually run — did not, and every lane died on an unrescued
  # Errno::ENOENT for `bin/rails` before a single test ran. These execute that path.

  def test_a_gem_repo_runs_its_registry_gate_and_no_rails_lane
    with_repo_named("studio-engine", release_check: GEM_GATE_OK) do |dir|
      log = File.join(dir, "stub.log")
      # NO FAST_CHECK_TEST_CMD: the unaided path is the whole point. The prepare
      # command is a tripwire — a gem has no test DB, so it must never run.
      # `nil` UNSETS the variable for the child. Omitting the key instead would leave
      # run_check's own stub command in place and the registry path would never run —
      # the first version of this test did exactly that and passed for no reason.
      out, code = run_check(dir, extra_env: {
        "FAST_CHECK_TEST_CMD" => nil,
        "FAST_CHECK_TEST_PREPARE_CMD" => "sh -c 'echo PREPARE >> #{log.shellescape}'"
      })

      assert_equal 0, code, "an unaided gem cert must complete:\n#{out}"
      refute_match(/PREPARE/, File.exist?(log) ? File.read(log) : "",
        "a gem has no test database and no bin/rails to prepare one with — the " \
        "prepare lane must not APPLY, not merely be skippable")
      refute_match(/Errno::ENOENT|cert_process\.rb:\d+:in/, out,
        "the crash this fixes must not resurface as a backtrace:\n#{out}")
    end
  end

  def test_a_gem_cert_line_names_the_command_it_actually_ran
    with_repo_named("studio-engine", release_check: GEM_GATE_OK) do |dir|
      out, = run_check(dir, extra_env: { "FAST_CHECK_TEST_CMD" => nil })

      # THE EVIDENCE MUST DESCRIBE WHAT RAN. The app wording counts diff-mapped
      # paths, all zero for a gem — so the first working version of this fix emitted
      # "0 mapped + 0 spine test path(s), rubocop on 0 changed file(s)" after running
      # the repo's ENTIRE gate. Every number true, the sentence false.
      refute_match(/0 mapped \+ 0 spine/, out,
        "a cert that ran the whole gate must not read as one that tested nothing:\n#{out}")
      assert_match(/whole registry gate/, out,
        "the line must name what was actually executed:\n#{out}")
    end
  end

  # A GEM RUNS NO RUBOCOP LANE — asserted by whether the lane's stub was INVOKED,
  # not by scanning output for a string fast-check never emits.
  #
  # The first version of this test checked `refute_match(/\[rubocop@/)`, which is
  # vacuous: fast-check emits ONE [fast-cert@...] line and no per-lane evidence at
  # all, so that assertion was true no matter what ran. A mutation proved it — and
  # then proved something better, that the lint-waiver branch it was written for was
  # unreachable code, since the only lint_lane:none repo is also a gem.
  def test_a_gem_repo_invokes_no_rubocop_lane_at_all
    with_repo_named("studio-engine", release_check: GEM_GATE_OK) do |dir|
      # fail_token makes the rubocop stub FAIL if it is ever invoked, so a lane that
      # sneaks through reddens the cert rather than passing quietly.
      _, code, lines = run_check(dir, fail_token: "RUBOCOP",
                                      extra_env: { "FAST_CHECK_TEST_CMD" => nil })

      assert_equal 0, code
      assert_empty lane_calls(lines, "RUBOCOP"),
        "a gem ships no rubocop; the lane must never be invoked for one"
    end
  end

  def test_an_app_repo_is_unchanged_by_the_gem_path
    with_repo_named("turf-monster") do |dir|
      out, code = run_check(dir)

      assert_equal 0, code, "no app repo may regress:\n#{out}"
      assert_match(/mapped/, out,
        "an app still reports its diff-mapped selection — the registry path must not " \
        "quietly become the answer for every repo:\n#{out}")
    end
  end

  GEM_GATE_RED = "#!/bin/sh\nexit 1\n"

  # --- the gem lane must be able to FAIL ---------------------------------------
  #
  # This script is the cert WRITER for the whole pipeline, so a cert that cannot
  # fail is worse than a missing one. Every other gem test here asserts a GREEN
  # gem or the app control; nothing guarded the gem lane's place in the verdict
  # hash, and dropping mapped_res from it would certify a gem GREEN over a RED
  # gate with all of them still passing.

  def test_a_gem_whose_gate_FAILS_certifies_nothing
    with_repo_named("studio-engine", release_check: GEM_GATE_RED) do |dir|
      out, code, lines = run_check(dir, args: ["task-x"], merge_stderr: true,
                                        extra_env: { "FAST_CHECK_TEST_CMD" => nil,
                                                     "TASK_SHOW_JSON" => SHOW_JSON })

      refute_equal 0, code, "a red gem gate must fail the cert:\n#{out}"
      refute_match(/\[fast-cert@/, out, "and must record NO evidence:\n#{out}")

      closes = lines.select { |l| l[0] == "GATE" && l.include?("close") }
      assert_equal 1, closes.length, "exactly one gate close, not zero and not two"
      assert_includes closes.flatten, "--failed", "and the verdict must be failed"
    end
  end

  # A gem whose registry row names bin/release-check but whose checkout does not
  # carry it must stay RED. A silent skip here would be the worst outcome of all:
  # a repo that certifies green having run nothing.
  def test_a_gem_missing_its_declared_gate_stays_red
    with_repo_named("studio-engine") do |dir|
      out, code = run_check(dir, args: ["task-x"], merge_stderr: true,
                                 extra_env: { "FAST_CHECK_TEST_CMD" => nil,
                                              "TASK_SHOW_JSON" => SHOW_JSON })

      refute_equal 0, code, "a declared gate that is absent is RED, never skipped:\n#{out}"
      refute_match(/\[fast-cert@/, out)
      assert_match(/COULD NOT RUN/, out,
        "and it must name the COMMAND as the problem, not the diff:\n#{out}")
    end
  end

  # --- acceptance 3: the attempt closes on a crash path ------------------------
  #
  # Every other test here runs --print, where gate_slug is nil and the at_exit
  # block never executes — so this criterion shipped untested the first time.
  # This copies the script, injects a raise where a lane crash would land, and
  # reads the gate ledger.

  def test_an_unrescued_crash_closes_the_g1_attempt_failed
    with_repo do |dir, _|
      # BESIDE the real script, not in the fixture dir: bin/fast-check does
      # `require_relative "lib/..."`, so a copy anywhere else dies on a LoadError
      # before it ever opens the attempt — which is a different failure than the
      # one under test, and reads exactly like "the attempt never opened".
      crashing = File.join(File.dirname(BIN), "fast-check-crash-fixture")
      src = File.read(BIN).sub("unless skip_test_prepare", "raise \"boom\"\nunless skip_test_prepare")
      File.write(crashing, src)
      File.chmod(0o755, crashing)

      _, code, lines = run_check(dir, args: ["task-x"], merge_stderr: true, bin: crashing,
                                      extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })

      refute_equal 0, code
      gate = lines.select { |l| l[0] == "GATE" }
      assert gate.any? { |l| l.include?("open") }, "the attempt must have opened"
      closes = gate.select { |l| l.include?("close") }
      assert_equal 1, closes.length,
        "a crash must close the attempt exactly once — leaving it open reads as " \
        "STALLED on the board, and closing twice creates a spurious extra attempt " \
        "whose --failed row becomes the verdict"
      assert_includes closes.flatten, "--failed"
    ensure
      FileUtils.rm_f(crashing) if crashing
    end
  end

  # THE GUARD THAT WOULD HAVE CAUGHT THE DOUBLE-CLOSE. A happy path must emit
  # exactly ONE close, and it must be --success.
  def test_a_passing_cert_closes_exactly_once_and_succeeds
    with_repo do |dir, _|
      _, code, lines = run_check(dir, args: ["task-x"],
                                      extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })

      assert_equal 0, code
      closes = lines.select { |l| l[0] == "GATE" && l.include?("close") }
      assert_equal 1, closes.length, "a second close would create attempt n+1, and " \
                                     "latest_by_key takes the LAST — so a spurious " \
                                     "--failed row becomes the verdict over a PASSING cert"
      assert_includes closes.flatten, "--success"
    end
  end

  def run_check(dir, args: ["--print"], fail_token: "", extra_env: {}, implicit_root: false, merge_stderr: false, bin: BIN)
    log = File.join(dir, "stub.log")
    lane = write_stub(dir, "lane-stub", "LANE")
    gate = write_stub(dir, "gate-stub", "GATE")
    task = write_stub(dir, "task-stub", "TASK")
    # child_env: the child must name NO agent session (bin/fast-check shells to bin/task
    # and the gate — test/support/session_env.rb) and must not inherit our test DB
    # (NO_AMBIENT_DB). Both scrubs live in child_env; never build a child env by hand.
    env = child_env({
      "FAST_CHECK_ROOT" => dir,
      "FAST_CHECK_DIFF_BASE" => "HEAD",
      "FAST_CHECK_SPINE" => File.join(dir, "spine.yml"),
      "FAST_CHECK_TEST_PREPARE_CMD" => "true",
      "FAST_CHECK_TEST_CMD" => "#{lane.shellescape} TEST",
      "FAST_CHECK_RUBOCOP_CMD" => "#{lane.shellescape} RUBOCOP",
      "FAST_CHECK_GATE_BIN" => gate,
      "FAST_CHECK_TASK_BIN" => task,
      "STUB_LOG" => log,
      "FAIL_TOKEN" => fail_token
    }.merge(extra_env))
    cmd = "#{bin.shellescape} #{args.map(&:shellescape).join(' ')}"
    out =
      if implicit_root
        env.delete("FAST_CHECK_ROOT")
        IO.popen(env, "#{cmd} 2>&1", chdir: dir, &:read)
      elsif merge_stderr
        IO.popen(env, "#{cmd} 2>&1", &:read)
      else
        IO.popen(env, "#{cmd} 2>/dev/null", &:read)
      end
    code = $?.exitstatus
    lines = File.exist?(log) ? File.readlines(log, chomp: true).map { |l| l.split("\t") } : []
    [out, code, lines]
  end

  def lane_calls(lines, first_arg)
    lines.select { |l| l[0] == "LANE" && l[1] == first_arg }.map { |l| l[2..] }
  end

  # --- [unit] lanes + selection wiring ----------------------------------------------

  def test_green_run_prints_fingerprint_bound_fast_cert_evidence
    with_repo do |dir, _|
      out, code, = run_check(dir)
      assert_equal 0, code, out
      assert_match(/\A\[fast-cert@[0-9a-f]{7,64}(?::[^\]\s]+)?\]/, out)
      assert_match(/full suite runs on CI/, out)
    end
  end

  def test_mapped_lane_gets_the_diff_mapped_test_and_spine_lane_gets_the_spine
    with_repo do |dir, _|
      _, code, lines = run_check(dir)
      assert_equal 0, code
      tests = lane_calls(lines, "TEST")
      assert_equal 2, tests.size, "one mapped-tests run + one spine run: #{lines.inspect}"
      assert_equal ["test/models/widget_test.rb"], tests[0], "mapped lane runs the diff-mapped test"
      assert_equal ["test/models/spine_core_test.rb"], tests[1], "spine lane runs the configured spine"
    end
  end

  # --- the mapped cap -----------------------------------------------------------
  #
  # A FAST LANE THAT CAN SILENTLY BECOME A FULL SUITE is worse than a slow one:
  # the builder cannot tell which they are in. Observed live 2026-08-15 — a diff
  # touching config/initializers/studio.rb mapped to 45 test files and this script
  # was still running at 39m34s against a lane g1-cert.md budgets at ~1 minute,
  # which bin/ship runs by DEFAULT.
  #
  # Driven through the script rather than the module because the decision is only
  # half the fix: the other half is that the mapped lane does not RUN, the spine
  # still does, and the builder is told why.

  # A file with no convention target falls back to a word-boundary grep of its
  # camelized name; this fixture makes that grep match many test files, which is
  # the real shape of the defect.
  def with_wide_mapping_repo
    with_repo do |dir, write|
      write.call("app/models/widget.rb", "class Widget; end\n")
      (1..20).each { |i| write.call("test/lib/wide_#{i}_test.rb", "Widget.reset\n") }
      assert system("git", "-C", dir, "add", "-A", out: File::NULL, err: File::NULL)
      assert system("git", "-C", dir, "commit", "-qm", "wide", out: File::NULL, err: File::NULL)
      # The branch diff: an initializer, which has NO convention candidate.
      write.call("config/initializers/widget.rb", "Widget.configure\n")
      yield dir, write
    end
  end

  def test_a_wide_mapping_skips_the_mapped_lane_and_still_runs_the_spine
    with_wide_mapping_repo do |dir, _|
      out, code, lines = run_check(dir, merge_stderr: true)

      assert_equal 0, code, "the cap is not a failure — it is a narrower cert"
      tests = lane_calls(lines, "TEST")
      assert_equal 1, tests.size, "the mapped lane must not run: #{lines.inspect}"
      assert_equal ["test/models/spine_core_test.rb"], tests[0],
                   "the spine still runs — capped means narrower, not uncertified"
      assert_match(/MAPPED LANE CAPPED/, out)
    end
  end

  # THE BUILDER IS TOLD WHAT TRIPPED IT AND WHAT TO DO. A silently skipped lane is
  # how a cert stops meaning anything, and "too many files" without a culprit
  # sends them through their whole diff.
  def test_the_capped_run_names_the_cap_the_culprit_and_the_way_out
    with_wide_mapping_repo do |dir, _|
      out, = run_check(dir, merge_stderr: true)

      assert_match(/exceeds the cap of 15/, out, "the cap it applied is printed")
      assert_match(%r{widest mapping: config/initializers/widget\.rb}, out, "the culprit is named")
      assert_match(/bin\/full-suite-check/, out, "the command that DOES cover this diff is offered")
      assert_match(/FAST_CHECK_MAPPED_CAP/, out, "the deliberate override is discoverable")
    end
  end

  # AND THE SKIP REASON IS DURABLE, not just console noise — it lands on the lane
  # record, so the task shows WHY the mapped lane did not run rather than an
  # unexplained gap.
  def test_the_cap_reason_is_recorded_on_the_skipped_lane
    with_wide_mapping_repo do |dir, _|
      out, = run_check(dir, merge_stderr: true)

      assert_match(/mapped file\(s\) over the cap of 15/, out)
      assert_match(/spine only; use bin\/full-suite-check/, out)
    end
  end

  # THE RECORDED EVIDENCE MUST SAY CAPPED. checks_run gets exactly ONE line, and
  # mapped_only.size counts what MAPPED, not what RAN — so a capped run recorded
  # "20 mapped" for zero mapped tests, reading identically to a real pass.
  def test_the_capped_run_records_the_cap_in_the_evidence_line
    with_wide_mapping_repo do |dir, _|
      out, = run_check(dir, merge_stderr: true)

      assert_match(/fast cert green: 0 mapped \(CAPPED: \d+ mapped path\(s\) over the cap of 15/, out)
      refute_match(/fast cert green: [1-9]\d* mapped \+/, out,
                   "the recorded evidence claims mapped tests ran when the lane was skipped")
    end
  end

  # A RAISED CAP MUST LET IT THROUGH, or the override is decoration.
  def test_raising_the_cap_runs_the_mapped_lane
    with_wide_mapping_repo do |dir, _|
      _, code, lines = run_check(dir, extra_env: { "FAST_CHECK_MAPPED_CAP" => "500" })

      assert_equal 0, code
      assert_equal 2, lane_calls(lines, "TEST").size,
                   "with the cap raised the mapped lane runs again"
    end
  end

  # THE CAP READS THE POST-SPINE SET, asserted AT THE CALL SITE. The unit test
  # proves cap_decision counts what it is handed; this proves bin/fast-check hands
  # it the right thing, which is a separate claim and the one a mutation walked
  # straight through — swapping `mapped_only` for `mapped` reddened nothing.
  #
  # WHY IT MATTERS: the cap is about how much EXTRA work this lane does. A mapped
  # test the spine already runs costs it nothing, so a diff whose mapping is
  # entirely spine-covered must not be refused — capping the raw union would
  # punish exactly the diffs the spine already covers best.
  def test_a_wide_mapping_that_the_spine_already_covers_is_not_capped
    with_repo do |dir, write|
      write.call("app/models/widget.rb", "class Widget; end\n")
      wide = (1..20).map { |i| "test/lib/wide_#{i}_test.rb" }
      wide.each { |rel| write.call(rel, "Widget.reset\n") }
      # The spine covers all but TWO, so the raw union is 20 (over the cap of 15)
      # while the post-spine set is 2 (well under it).
      #
      # NOT all 20: leaving the post-spine set EMPTY makes this test unable to
      # fail. `mapped_only.empty?` is checked BEFORE the cap, so an empty set takes
      # the "covered by the spine" skip either way and the mutation walks through.
      # The set has to be non-empty and small for the two behaviours to differ.
      spined = wide.first(18)
      write.call("spine.yml", "spine:\n#{spined.map { |r| "  - #{r}" }.join("\n")}\n")
      assert system("git", "-C", dir, "add", "-A", out: File::NULL, err: File::NULL)
      assert system("git", "-C", dir, "commit", "-qm", "wide-spine", out: File::NULL, err: File::NULL)
      write.call("config/initializers/widget.rb", "Widget.configure\n")

      out, code, lines = run_check(dir, merge_stderr: true)

      assert_equal 0, code
      refute_match(/MAPPED LANE CAPPED/, out,
                   "the cap tripped on the RAW mapping (20) instead of the post-spine set (2) — " \
                   "this lane had 2 files of extra work, nowhere near the cap")
      tests = lane_calls(lines, "TEST")
      assert_equal 2, tests.size, "the mapped lane runs its two uncovered files, plus the spine"
      assert_equal wide.last(2).sort, tests[0].sort,
                   "only the mapped files the spine does NOT already run"
    end
  end

  # AND THE NORMAL CASE IS UNTOUCHED. The cap is worthless if it changes the lane
  # every builder actually gets.
  def test_a_narrow_diff_is_unaffected_by_the_cap
    with_repo do |dir, _|
      out, code, lines = run_check(dir, merge_stderr: true)

      assert_equal 0, code
      assert_equal 2, lane_calls(lines, "TEST").size
      refute_match(/MAPPED LANE CAPPED/, out)
    end
  end

  # --- [integration] the zero-evidence guard --------------------------------------
  #
  # THE DEFECT, live on turf-monster PR #549 (2026-09-05) and reproduced against this
  # binary before the fix, verbatim:
  #
  #   fast cert green: 0 mapped (CAPPED: 20 mapped path(s) over the cap of 15; spine
  #   only — bin/full-suite-check covers this diff) + 0 spine test path(s), rubocop on
  #   1 changed file(s) (0.7s; full suite runs on CI)      exit 0, 0 test lanes invoked
  #
  # The mapped lane was capped, so it announced a fallback to the spine; the spine then
  # resolved to ZERO paths. The cert reported GREEN having run no test at all — rubocop
  # was the only executed lane, and a linter cannot observe behaviour. It is not an
  # exotic shape: config/fast_cert_spine.yml is anchored in the HUB, and none of its
  # entries exist in turf-monster or rolio (verified 2026-09-05, all five absent in
  # both), so on either satellite the mapped lane is the ONLY lane that can run a test.
  #
  # Driven through the script, not the module, because the module decision is half the
  # fix: the other half is that NOTHING runs, NOTHING is recorded, and the exit code
  # says so. bin/ship reads output rather than exit codes, so both are asserted.

  # A repo whose spine config resolves to NOTHING — the satellite shape.
  def with_empty_spine(dir, write)
    write.call("spine.yml", "spine: []\n")
    [dir, write]
  end

  # WHAT PR #1226 ESTABLISHED, KEPT: this run still does not certify, still emits no
  # "[fast-cert@" line, and still runs no test. WHAT CHANGED: the verdict is DEFERRED
  # rather than refused, because the refusal landed at ship step 2 of 8 — before the
  # push, before the PR, before any CI — and its only remedy was a ~30-minute local
  # suite against CI's ~9 for the identical command. The evidence moves to CI; the
  # demand for evidence does not move at all (bin/dor-check requires the GREEN).
  def test_a_capped_lane_over_an_empty_spine_DEFERS_instead_of_certifying
    with_wide_mapping_repo do |dir, write|
      with_empty_spine(dir, write)

      out, code, lines = run_check(dir, merge_stderr: true)

      assert_equal 2, code, "a deferral is NOT success — it must stay falsy to every system() caller:\n#{out}"
      assert_match(/NOT CERTIFIED — DEFERRING to GitHub CI/, out)
      refute_match(/fast cert green/, out,
                   "the exact defect this must never become: a green cert over zero executed tests:\n#{out}")
      refute_match(/\[fast-cert@/, out,
                   "no CERT line may be emitted — nothing was certified")
      assert_match(/\[cert-deferred@[0-9a-f]{7,64}(?::[^\]\s]+)?\]/, out,
                   "a RECEIPT is emitted instead, fingerprint-bound like every other lane")
      assert_empty lane_calls(lines, "TEST"), "no test lane ran, which is still the point"
    end
  end

  # THE RECEIPT IS THE DEFERRAL, so it has to REACH THE BOARD — dor-check grades the
  # record, not the message. Recorded through the same `--checks` funnel the green path
  # uses (bin/task merges client-side against the board's current state, so the write
  # cannot clobber the builder's tier lines even on a board that predates this lane).
  def test_a_deferred_run_records_its_receipt_on_the_board
    with_wide_mapping_repo do |dir, write|
      with_empty_spine(dir, write)

      out, code, lines = run_check(dir, args: ["some-task"], merge_stderr: true,
                                   extra_env: { "TASK_SHOW_JSON" => SHOW_JSON,
                                                "FAST_CHECK_SKIP_ORPHAN_GUARD" => "1" })

      assert_equal 2, code, out
      update = lines.find { |l| l[0] == "TASK" && l[1] == "update" }
      refute_nil update, "the receipt must be RECORDED, or the deferral is a shrug: #{lines.inspect}"
      recorded = update[update.index("--checks") + 1]
      assert_match(/\A\[cert-deferred@[0-9a-f]{7,64}/, recorded, "recorded as the DEFERRAL lane: #{recorded}")
      assert_match(/CAPPED/, recorded, "and the record carries the cause")
      assert_match(/read-back confirms/, out, "the write is VERIFIED, never declared")
      assert_empty lines.select { |l| l[0] == "GATE" },
                   "still no g1_cert attempt — no lane ran, so there is no testing window to report"
    end
  end

  # A RECEIPT THAT DID NOT LAND IS WORSE THAN A REFUSAL: ship would push, open the PR,
  # wait out CI, and dor-check would then refuse for want of the receipt — the same
  # 30 minutes, spent later and less legibly. So an unrecordable deferral REFUSES.
  def test_a_deferral_that_cannot_be_recorded_refuses_instead
    with_wide_mapping_repo do |dir, write|
      with_empty_spine(dir, write)

      out, code, = run_check(dir, args: ["some-task"], merge_stderr: true, fail_token: "update",
                             extra_env: { "TASK_SHOW_JSON" => SHOW_JSON,
                                          "FAST_CHECK_SKIP_ORPHAN_GUARD" => "1" })

      assert_equal 1, code, "an unrecordable deferral is a REFUSAL, not a deferral:\n#{out}"
      assert_match(/FAILED to record the receipt/, out)
    end
  end

  # THE REFUSAL IS ACTIONABLE OR IT IS JUST A NEW WAY TO BE STUCK. It names what
  # tripped it, the culprit file, and the ONE command that covers a diff this broad.
  def test_the_refusal_names_the_cap_the_culprit_and_the_remedy
    with_wide_mapping_repo do |dir, write|
      with_empty_spine(dir, write)

      out, code, = run_check(dir, merge_stderr: true)

      assert_equal 2, code, out
      assert_match(/CAPPED/, out, "what tripped it")
      assert_match(%r{config/initializers/widget\.rb}, out, "the culprit file")
      assert_match(%r{bin/full-suite-check}, out, "the remedy is named")
      assert_match(/FAST_CHECK_MAPPED_CAP=20/, out, "the deliberate override stays discoverable")
    end
  end

  # NOTHING IS RECORDED AND NO G1 ATTEMPT IS STAMPED for a run that truly REFUSES. The
  # guard is a precondition on the SELECTION, decided before any lane — like the root,
  # desk, and dirty-tree guards — so a refused run leaves the board exactly as it found
  # it. An attempt that ran no lane would otherwise report a window that measured
  # nothing. (Driven on the UNMAPPED diff, which is the door that still refuses; the
  # capped door now writes its receipt, asserted above.)
  def test_a_refused_run_writes_nothing_to_the_board_or_the_gate
    with_wide_mapping_repo do |dir, write|
      with_empty_spine(dir, write)
      # UNMAPPED, not capped: drop the branch diff's initializer (whose generic grep
      # token is what maps wide) and leave prose, which maps to nothing at all.
      FileUtils.rm_f(File.join(dir, "config/initializers/widget.rb"))
      write.call("docs/note.md", "prose only\n")

      _, code, lines = run_check(dir, args: ["some-task"], merge_stderr: true,
                                 extra_env: { "FAST_CHECK_SKIP_ORPHAN_GUARD" => "1" })

      assert_equal 1, code
      assert_empty lines.select { |l| l[0] == "TASK" && l[1] == "update" },
                   "a refused cert must record no evidence: #{lines.inspect}"
      assert_empty lines.select { |l| l[0] == "GATE" },
                   "and must stamp no g1_cert attempt: #{lines.inspect}"
    end
  end

  # THE OTHER DOOR INTO THE SAME ROOM, and why this guard is keyed on ZERO EXECUTED
  # TESTS rather than on the cap. Keyed on the cap, a satellite diff mapping to 20 test
  # files would be refused while one mapping to NONE — strictly LESS evidence — would
  # still certify green on rubocop alone. Before the fix this printed
  # "fast cert green: 0 mapped + 0 spine test path(s), rubocop on 0 changed file(s)".
  def test_a_diff_that_maps_to_nothing_over_an_empty_spine_is_refused_too
    with_repo do |dir, write|
      write.call("spine.yml", "spine: []\n")
      FileUtils.rm_f(File.join(dir, "app/models/widget.rb"))
      write.call("docs/note.md", "prose only\n")

      out, code, lines = run_check(dir, merge_stderr: true)

      assert_equal 1, code, "zero evidence is zero evidence however it was reached:\n#{out}"
      assert_match(/maps to NO test file/, out, "the reason given is the REAL one")
      refute_match(/CAPPED/, out, "no cap tripped — saying so would misdirect the builder")
      refute_match(/fast cert green/, out)
      assert_empty lane_calls(lines, "TEST")
    end
  end

  # --- and the half that MUST NOT MOVE ---------------------------------------------

  # THE ANY-CAP-DEGRADES RULING, REJECTED AND PINNED. A capped run whose SPINE still ran
  # executed real tests. It is a NARROWER cert, already labelled honestly by the
  # "0 mapped (CAPPED: ...)" evidence and the loud MAPPED LANE CAPPED narration — which
  # is exactly what the cap was designed to produce. Degrading it too would refuse builds
  # that legitimately certified.
  def test_a_capped_run_that_still_runs_a_spine_certifies_exactly_as_before
    with_wide_mapping_repo do |dir, _|
      out, code, lines = run_check(dir, merge_stderr: true)

      assert_equal 0, code, "the cap alone is not a refusal — it is a narrower cert:\n#{out}"
      assert_match(/fast cert green: 0 mapped \(CAPPED: \d+ mapped path\(s\) over the cap of 15/, out)
      refute_match(/REFUSING TO CERTIFY/, out)
      assert_equal [["test/models/spine_core_test.rb"]], lane_calls(lines, "TEST"),
                   "the spine still runs, and it is what makes this run certifiable"
    end
  end

  # THE ORDINARY BUILD IS UNTOUCHED — the regression that matters. An over-broad guard
  # that degraded normal certs would be worse than the bug it fixes.
  def test_an_ordinary_diff_certifies_exactly_as_before
    with_repo do |dir, _|
      out, code, lines = run_check(dir, merge_stderr: true)

      assert_equal 0, code, out
      assert_match(/fast cert green: 1 mapped \+ 1 spine test path\(s\)/, out)
      refute_match(/REFUSING TO CERTIFY/, out)
      assert_equal [["test/models/widget_test.rb"], ["test/models/spine_core_test.rb"]],
                   lane_calls(lines, "TEST"), "both lanes run, unchanged"
    end
  end

  # THE OVERRIDE IS NOT A DEAD END. A builder who deliberately raises the cap runs the
  # mapped lane, executes tests, and certifies — so the refusal always has a way through
  # that does not require a second command.
  def test_raising_the_cap_clears_the_refusal_on_an_empty_spine
    with_wide_mapping_repo do |dir, write|
      with_empty_spine(dir, write)

      out, code, lines = run_check(dir, merge_stderr: true,
                                   extra_env: { "FAST_CHECK_MAPPED_CAP" => "500" })

      assert_equal 0, code, "with the mapped lane running there IS evidence:\n#{out}"
      refute_match(/REFUSING TO CERTIFY/, out)
      assert_equal 1, lane_calls(lines, "TEST").size, "the mapped lane ran"
    end
  end

  # A GEM IS EXEMPT, and the exemption has to be exercised on a diff that WOULD trip the
  # guard — mapping to nothing, over an empty spine. A gem's registry command IS its
  # suite and runs as the mapped lane, so reading `mapped_only` for one would refuse the
  # repo that runs the MOST. Written against a mapping diff first, this test passed
  # vacuously: `mapped_only` was non-empty and no guard was ever consulted.
  def test_a_gem_repo_is_never_refused_by_the_zero_evidence_guard
    with_repo_named("studio-engine", release_check: GEM_GATE_OK) do |dir|
      File.write(File.join(dir, "spine.yml"), "spine: []\n")
      FileUtils.rm_f(File.join(dir, "app/models/widget.rb"))
      FileUtils.mkdir_p(File.join(dir, "docs"))
      File.write(File.join(dir, "docs/note.md"), "prose only\n")

      out, code = run_check(dir, merge_stderr: true, extra_env: { "FAST_CHECK_TEST_CMD" => nil })

      assert_equal 0, code, "a gem runs its whole registry gate — there is nothing to refuse:\n#{out}"
      refute_match(/REFUSING TO CERTIFY/, out)
      assert_match(/whole registry gate/, out, "and it certifies on the gate it actually ran")
    end
  end

  def test_rubocop_lane_is_scoped_to_changed_lintable_files_only
    with_repo do |dir, _|
      _, code, lines = run_check(dir)
      assert_equal 0, code
      lint = lane_calls(lines, "RUBOCOP")
      assert_equal 1, lint.size
      assert_equal ["app/models/widget.rb"], lint[0],
                   "rubocop runs on the CHANGED file only — never the whole repo"
    end
  end

  def test_mapped_tests_already_covered_by_the_spine_run_once
    with_repo do |dir, write|
      # The diff now ALSO touches the spine-covered model: its mapped test is the
      # spine test itself, so the mapped lane must not re-run it.
      write.call("app/models/spine_core.rb", "class SpineCore; end\n")
      _, code, lines = run_check(dir)
      assert_equal 0, code
      tests = lane_calls(lines, "TEST")
      assert_equal ["test/models/widget_test.rb"], tests[0], "spine-covered mapped test dropped from the mapped lane"
      assert_equal ["test/models/spine_core_test.rb"], tests[1]
    end
  end

  def test_red_test_lane_exits_nonzero_and_records_nothing
    with_repo do |dir, _|
      out, code, = run_check(dir, fail_token: "widget_test")
      assert_equal 1, code, out
      refute_match(/\[fast-cert@/, out, "a red lane must not certify")
    end
  end

  def test_red_rubocop_lane_exits_nonzero_and_records_nothing
    with_repo do |dir, _|
      out, code, = run_check(dir, fail_token: "RUBOCOP")
      assert_equal 1, code, out
      refute_match(/\[fast-cert@/, out)
    end
  end

  def test_a_timed_out_runner_is_named_as_hung_never_as_a_red_suite
    with_repo do |dir, _|
      slow_runner = "#{RbConfig.ruby.shellescape} -e #{"sleep 30".shellescape} --"
      out, code, = run_check(
        dir,
        extra_env: {
          # fast-check appends selected test paths; `--` makes this stub ignore them.
          "FAST_CHECK_TEST_CMD" => slow_runner,
          "FAST_CHECK_LANE_TIMEOUT" => "1"
        },
        merge_stderr: true
      )

      assert_equal 1, code, out
      assert_match(/RUNNER HUNG/, out)
      assert_match(/NOT a test failure/, out)
      assert_match(/FAST_CHECK_LANE_TIMEOUT/, out)
      refute_match(/lane\(s\) RED/, out,
                   "a runner that produced no verdict must never be reported as red tests")
      refute_match(/\[fast-cert@/, out, "a timed-out runner must never certify")
    end
  end

  def test_doc_only_diff_skips_test_and_rubocop_lanes_but_still_runs_the_spine
    with_repo do |dir, write|
      write.call("docs/notes.md", "notes\n")
      env = { "FAST_CHECK_CHANGED_FILES" => "docs/notes.md" }
      out, code, lines = run_check(dir, extra_env: env, fail_token: "RUBOCOP")
      # rubocop's stub would FAIL if invoked — a doc-only diff must skip it.
      assert_equal 0, code, out
      assert_empty lane_calls(lines, "RUBOCOP"), "no lintable files → rubocop lane skipped"
      assert_equal [["test/models/spine_core_test.rb"]], lane_calls(lines, "TEST"),
                   "the spine still runs when nothing maps"
      assert_match(/\[fast-cert@/, out)
    end
  end

  def test_test_prepare_failure_aborts_before_any_lane
    with_repo do |dir, _|
      out, code, lines = run_check(dir, extra_env: { "FAST_CHECK_TEST_PREPARE_CMD" => "false" })
      assert_equal 1, code, out
      assert_empty lane_calls(lines, "TEST"), "no lane runs against an unprepared test env"
      refute_match(/\[fast-cert@/, out)
    end
  end

  # --- [unit] the virgin-tree bundled-asset regression -------------------------------
  #
  # A fake `bin/rails` that models the two Rails behaviours this cert depends on:
  #
  #   1. `test:prepare` is the hook a CSS/JS bundler enhances to BUILD its artifact
  #      (tailwindcss-rails: `Rake::Task["test:prepare"].enhance(["tailwindcss:build"])`).
  #      NOTHING else builds it -- `db:test:prepare` does not (tailwindcss enhances it
  #      only as a FALLBACK, when test:prepare is undefined).
  #   2. Propshaft raises "The asset ... is not present in the asset pipeline" when a
  #      view's stylesheet_link_tag target was never built.
  #
  # The fake fails its `test` lane ONLY on the missing artifact -- never on the paths --
  # so the test reproduces the exact production symptom (a virgin worktree, where the
  # gitignored app/assets/builds/ holds nothing but .keep) and nothing else.
  def write_fake_rails(dir)
    rails = File.join(dir, "bin", "rails")
    FileUtils.mkdir_p(File.dirname(rails))
    File.write(rails, <<~RUBY)
      #!#{RbConfig.ruby}
      require "fileutils"
      built = File.join(Dir.pwd, "app/assets/builds/tailwind.css")
      File.open(ENV.fetch("STUB_LOG"), "a") { |f| f.puts(["RAILS", *ARGV].join("\\t")) }
      if ARGV.include?("test:prepare")
        FileUtils.mkdir_p(File.dirname(built))
        File.write(built, "/* built by the test:prepare hook */")
      end
      if ARGV.first == "test" && !File.exist?(built)
        warn 'The asset "tailwind.css" is not present in the asset pipeline.'
        exit 1
      end
      exit 0
    RUBY
    FileUtils.chmod("+x", rails)
  end

  # Regression (build-assets-on-worktree-bringup): fast-check's test lanes pass EXPLICIT
  # FILE PATHS, and Rails SKIPS its own test:prepare whenever an argument looks like a
  # path -- Rails::Command::TestCommand runs it only `if self.args.none?(
  # EXACT_TEST_ARGUMENT_PATTERN)`. So the bundler hook that an ARGLESS `bin/rails test`
  # fires for free (CI, bin/full-suite-check -- all green; the release gate workspaces
  # prep their own env since gate-workspace-skips-test-prepare, PR #522) never fires
  # here, and on a virgin worktree every
  # view-rendering test errored with
  # `The asset "tailwind.css" is not present in the asset pipeline`: ~77 red on a
  # ci.yml-only or docs-only diff. A G1 cert that reports an ENV GAP as a test
  # regression is lying, so the cert must run test:prepare ITSELF.
  #
  # Note this deliberately does NOT stub FAST_CHECK_TEST_PREPARE_CMD / FAST_CHECK_TEST_CMD
  # (a nil value UNSETS the var for the child): the DEFAULT lane commands are the thing
  # under test — the bug lived in the default.
  def test_prepare_lane_builds_bundled_assets_before_the_path_arg_test_lanes
    with_repo do |dir, _|
      write_fake_rails(dir)
      out, code, lines = run_check(dir, extra_env: {
                                     "FAST_CHECK_TEST_PREPARE_CMD" => nil, # use the real default
                                     "FAST_CHECK_TEST_CMD" => nil,         # use the real default
                                     "FAST_CHECK_RUBOCOP_CMD" => "true"
                                   })
      rails = lines.select { |l| l[0] == "RAILS" }.map { |l| l[1..] }

      assert_equal ["db:test:prepare", "test:prepare"], rails[0],
                   "the prepare lane must run Rails' test:prepare hook (which builds the bundled " \
                   "CSS) as well as the test DB prepare — the path-arg test lanes below will not"
      assert_path_exists File.join(dir, "app/assets/builds/tailwind.css"),
                         "prepare must leave the bundled asset on disk for the lanes that follow"
      assert_equal ["test", "test/models/widget_test.rb"], rails[1], "mapped lane still runs by path"
      assert_equal ["test", "test/models/spine_core_test.rb"], rails[2], "spine lane still runs by path"
      assert_equal 0, code, "a virgin tree must certify GREEN, not red on a missing asset:\n#{out}"
      assert_match(/\A\[fast-cert@/, out)
    end
  end

  def test_list_mode_prints_the_selection_without_running_anything
    with_repo do |dir, _|
      out, code, lines = run_check(dir, args: ["--list"])
      assert_equal 0, code, out
      assert_match(%r{mapped\s+test/models/widget_test\.rb}, out)
      assert_match(%r{spine\s+test/models/spine_core_test\.rb}, out)
      assert_match(%r{lint\s+app/models/widget\.rb}, out)
      assert_empty lines, "--list must not run lanes or emit gate/task writes"
    end
  end

  def test_fingerprint_matches_dor_check_view
    # The writer and the reader must agree, or fast-cert evidence never validates.
    with_repo do |dir, _|
      out, = run_check(dir)
      runner_fp = out[/@([0-9a-f]{7,64})[:\]]/, 1]
      dor_fp = IO.popen(child_env("DOR_CHECK_DIFF_ROOT" => dir),
                        "#{DOR} --suite-fingerprint 2>/dev/null", &:read).strip
      assert_equal dor_fp, runner_fp
    end
  end

  # --- [integration] durable-record writes: task evidence + G1 gate markers ---------

  SHOW_JSON = JSON.generate(
    "metadata" => { "devops" => { "checks_run" => [
      "[unit] bin/rails test test/models/widget_test.rb",
      "[full-suite@fullfp] tests green",
      "[fast-cert@oldfp] prior fast cert"
    ] } }
  )

  # The cert records its evidence and NOTHING else. Preservation of the author's
  # tier tags and the other lanes is the WRITE FUNNEL's job, not the writer's —
  # asserting it on the writer's argv is asserting the wrong layer, and the
  # writer-side "merge" it used to do is exactly what let a stale snapshot replace
  # newer tier lines (round-3). The preservation half is covered where it lives:
  # lib/cert_evidence.rb (test/lib/cert_evidence_test.rb), the board funnel
  # (test/models/task_cert_evidence_test.rb), and the real CLI end-to-end
  # (test/lib/task_cli_test.rb). The END STATE is asserted here by the read-back
  # tests below.
  def test_recording_records_the_fresh_evidence_line
    with_repo do |dir, _|
      out, code, lines = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code, out

      update = lines.find { |l| l[0] == "TASK" && l[1] == "update" }
      refute_nil update, "green run records evidence via task update: #{lines.inspect}"
      checks = update.each_cons(2).select { |a, _| a == "--checks" }.map(&:last)
      assert(checks.any? { |c| c =~ /\A\[fast-cert@[0-9a-f]{7,64}(?::[^\]\s]+)?\]/ }, "fresh fast-cert line recorded")
      refute_includes checks.join("\n"), "[fast-cert@oldfp]",
                      "the stale fast-cert line is never resent — the funnel supersedes this lane"
    end
  end

  # --- [integration] read-back: "preserved" is VERIFIED, never declared -------------
  # The 2026-07-20 wipe (fast-check-preserves-checks): the script printed "tier
  # tags preserved" over a write whose result it never looked at. The claim is now
  # backed by a post-write read of the board.

  def test_lost_preexisting_lines_after_the_write_fail_the_cert_loudly
    with_repo do |dir, _|
      after = JSON.generate("metadata" => { "devops" => { "checks_run" => [] } })
      out, code, = run_check(dir, args: ["task-x"], merge_stderr: true,
                             extra_env: { "TASK_SHOW_JSON" => SHOW_JSON,
                                          "TASK_SHOW_JSON_AFTER_UPDATE" => after })
      assert_equal 1, code, "a write whose read-back lost pre-existing checks lines must fail loudly: #{out}"
      assert_match(/MISSING/, out)
      assert_match(%r{\[unit\] bin/rails test test/models/widget_test\.rb}, out,
                   "the lost lines are named so the builder can re-record them")
      refute_match(/tier tags preserved/, out, "no blanket claim over a write that lost lines")
    end
  end

  # Round-3 regression (review block, 2026-07-20 — Carl): the cert used to resend
  # the WHOLE merged list (its snapshot of the author's lines + its evidence).
  # That is an AUTHOR write, so the funnel replaces the author namespace with the
  # SNAPSHOT — and any tier line the board gained after the snapshot was read (a
  # builder recording checks during a multi-minute cert, a concurrent writer) is
  # replaced by stale content. The cert owns exactly one namespace, so it now
  # sends ONLY its evidence line: a PURE-EVIDENCE write, which the funnel merges
  # against the board's CURRENT state at write time. No snapshot, no window.
  def test_recording_sends_only_evidence_never_the_author_snapshot
    with_repo do |dir, _|
      _, code, lines = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code
      update = lines.find { |l| l[0] == "TASK" && l[1] == "update" }
      refute_nil update
      checks = update.each_cons(2).select { |a, _| a == "--checks" }.map(&:last)
      assert_equal 1, checks.size,
                   "the cert must send ONE line — its own evidence. Resending its snapshot of the author's " \
                   "lines lets a stale read replace newer tier lines: #{checks.inspect}"
      assert_match(/\A\[fast-cert@[0-9a-f]{7,64}(?::[^\]\s]+)?\]/, checks.first)
    end
  end

  # The property the pure-evidence write buys: tier lines the board gained AFTER
  # the cert's read still survive, because the funnel merges at write time.
  def test_tier_lines_added_during_the_cert_are_not_replaced_by_the_stale_snapshot
    with_repo do |dir, _|
      # The board gained a newer tier line after the cert's pre-write read.
      newer = JSON.generate("metadata" => { "devops" => { "checks_run" => [
        "[unit] bin/rails test test/models/widget_test.rb",
        "[full-suite@fullfp] tests green",
        "[integration] recorded DURING the cert run"
      ] } })
      out, code, lines = run_check(dir, args: ["task-x"], merge_stderr: true,
                                   extra_env: { "TASK_SHOW_JSON" => SHOW_JSON,
                                                "TASK_SHOW_JSON_AFTER_UPDATE" => newer })
      assert_equal 0, code, out
      update = lines.find { |l| l[0] == "TASK" && l[1] == "update" }
      sent = update.each_cons(2).select { |a, _| a == "--checks" }.map(&:last)
      refute_includes sent, "[unit] bin/rails test test/models/widget_test.rb",
                      "a stale author snapshot must never be resent — that is what replaces newer tier lines"
      refute(sent.any? { |l| l.start_with?("[full-suite@") },
             "the cert does not own another lane's evidence either: #{sent.inspect}")
    end
  end

  # Round-5 regression (review block, 2026-07-20 — light lane): the cert must
  # verify the ONE line it OWNS. If the fresh [fast-cert@…] evidence line does not
  # land on the board, the cert cannot tell "my evidence landed" from "my evidence
  # vanished" — the missing-signal-read-as-success shape this PR exists to kill,
  # turned on the cert's own output. A read-back missing the evidence line must
  # exit NONZERO and say "re-run the cert" (NOT the author re-record remedy — a
  # hand-written evidence line forges the certification).
  def test_evidence_line_missing_from_the_read_back_fails_the_cert
    with_repo do |dir, _|
      # DROP_WRITTEN models the evidence write never landing; the pre-existing
      # lines are all still present, so ONLY the cert's own line is missing.
      out, code, lines = run_check(dir, args: ["task-x"], merge_stderr: true,
                                   extra_env: { "TASK_SHOW_JSON" => SHOW_JSON,
                                                "STUB_READBACK_DROP_WRITTEN" => "1" })
      assert_equal 1, code, "a read-back missing the fresh evidence line must FAIL the cert: #{out}"
      assert_match(/MISSING/, out)
      assert_match(/re-run the cert: bin\/fast-check task-x/, out,
                   "the remedy for a lost evidence line is a re-run, never a hand-written evidence line")
      refute_match(/read-back confirms/, out, "a vanished evidence line must not report a confirmed cert")
      # The G1 attempt must close FAILED, not success-while-exit-1.
      close = lines.select { |l| l[0] == "GATE" && l[1] == "close" }.last
      refute_nil close
      assert_includes close, "--failed", "the durable gate must not read success when the command exits 1"
    end
  end

  # Round-3 regression (review block, 2026-07-20 — Shannon): the recovery command
  # is meant to be PASTED into a shell, so every line must be SHELL-quoted.
  # `String#inspect` is a RUBY literal: it leaves $(…), backticks and friends live
  # inside double quotes, so pasting the remedy would execute them.
  def test_recovery_command_is_shell_safe_not_ruby_inspect
    with_repo do |dir, _|
      pwned = File.join(dir, "pwned")
      # A tier line carrying live shell syntax. `$(…)` and the backticks EXECUTE
      # inside double quotes, which is exactly what a Ruby-inspect command emits.
      nasty = %([integration] cost $(touch #{pwned}) and `touch #{pwned}` "quoted")
      before = JSON.generate("metadata" => { "devops" => { "checks_run" => [nasty] } })
      after = JSON.generate("metadata" => { "devops" => { "checks_run" => [] } })
      out, code, = run_check(dir, args: ["task-x"], merge_stderr: true,
                             extra_env: { "TASK_SHOW_JSON" => before,
                                          "TASK_SHOW_JSON_AFTER_UPDATE" => after })
      assert_equal 1, code, out
      remedy = out.lines.find { |l| l.include?("bin/task update task-x") }
      refute_nil remedy, out
      command = remedy[/bin\/task update task-x.*/].strip

      # The DECISIVE check: run the remedy through a REAL shell (Shellwords.split
      # would not model command substitution and passes even for a Ruby-inspect
      # command — a false green). A stub `bin/task` on PATH records the argv it
      # actually received; the shell must hand it the line VERBATIM and must not
      # execute the embedded substitution.
      argv_log = File.join(dir, "remedy-argv.log")
      bindir = File.join(dir, "remedy-bin")
      FileUtils.mkdir_p(bindir)
      File.write(File.join(bindir, "task"), <<~SH)
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "$a" >> #{argv_log.shellescape}; done
      SH
      FileUtils.chmod("+x", File.join(bindir, "task"))
      system({ "PATH" => "#{bindir}:#{ENV.fetch('PATH')}" },
             "/bin/sh", "-c", command.sub(%r{\Abin/task}, "task"),
             out: File::NULL, err: File::NULL)

      refute File.exist?(pwned),
             "the remedy EXECUTED embedded shell syntax when pasted: #{command}"
      received = File.exist?(argv_log) ? File.readlines(argv_log, chomp: true) : []
      assert_equal nasty, received.last,
                   "the shell must hand bin/task the line VERBATIM: #{received.inspect} from #{command}"
    end
  end

  # Round-2 regression (review block, 2026-07-20): on a PARTIAL loss the printed
  # recovery must re-record the UNION — the surviving lines AND the lost ones.
  # `--checks` replaces the author namespace, so a remedy listing only the lost
  # lines would itself drop the survivors when the builder runs it.
  def test_partial_loss_recovery_re_records_survivors_and_lost_alike
    with_repo do |dir, _|
      before = JSON.generate("metadata" => { "devops" => { "checks_run" => [
        "[unit] surviving unit line",
        "[integration] lost integration line"
      ] } })
      after = JSON.generate("metadata" => { "devops" => { "checks_run" => [
        "[unit] surviving unit line"
      ] } })
      out, code, = run_check(dir, args: ["task-x"], merge_stderr: true,
                             extra_env: { "TASK_SHOW_JSON" => before,
                                          "TASK_SHOW_JSON_AFTER_UPDATE" => after })
      assert_equal 1, code, out
      remedy = out.lines.find { |l| l.include?("bin/task update task-x") }
      refute_nil remedy, "the loud failure prints a runnable re-record command: #{out}"
      # Assert the PROPERTY (what a shell parses out of the command), not the
      # spelling — the lines are shell-quoted, so a raw substring match would be
      # asserting the quoting style rather than the recovery content.
      recorded = Shellwords.split(remedy[/bin\/task update task-x.*/].strip)
                           .each_cons(2).select { |a, _| a == "--checks" }.map(&:last)
      assert_includes recorded, "[integration] lost integration line", "the lost line is re-recorded"
      assert_includes recorded, "[unit] surviving unit line",
                      "the SURVIVING line must be in the remedy too — --checks replaces the author " \
                      "namespace, so a lost-lines-only remedy would drop the survivors"
    end
  end

  def test_green_run_reports_read_back_verified_preservation
    with_repo do |dir, _|
      out, code, = run_check(dir, args: ["task-x"], merge_stderr: true,
                             extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code, out
      assert_match(/read-back confirms the evidence line landed/, out,
                   "the confirmed claim names the evidence line the cert verified")
      assert_match(/all 2 pre-existing checks line\(s\) kept/, out,
                   "…and states the pre-existing count that was verified")
    end
  end

  def test_green_run_with_no_prior_checks_claims_no_preservation
    with_repo do |dir, _|
      empty = JSON.generate("metadata" => { "devops" => { "checks_run" => [] } })
      out, code, = run_check(dir, args: ["task-x"], merge_stderr: true,
                             extra_env: { "TASK_SHOW_JSON" => empty })
      assert_equal 0, code, out
      assert_match(/no pre-existing checks lines to preserve/, out)
      refute_match(/tier tags preserved/, out, "never claim preservation when nothing pre-existed")
    end
  end

  def test_unverifiable_read_back_reports_unverified_without_failing_the_cert
    with_repo do |dir, _|
      out, code, = run_check(dir, args: ["task-x"], merge_stderr: true,
                             extra_env: { "TASK_SHOW_JSON" => SHOW_JSON,
                                          "FAIL_SHOW_AFTER_UPDATE" => "1" })
      assert_equal 0, code, "a read-back blip must not fail a recorded green cert: #{out}"
      assert_match(/UNVERIFIED/, out)
      refute_match(/tier tags preserved/, out, "an unverified write must not claim preservation")
    end
  end

  def test_green_run_opens_g1_appends_one_sop_per_lane_and_self_closes_success
    with_repo do |dir, _|
      _, code, lines = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code
      gate = lines.select { |l| l[0] == "GATE" }
      assert_equal %w[open] + (%w[sop] * 8) + %w[close], gate.map { |l| l[1] },
                   "open + TWO sops per lane (running, then the verdict) + a self-close on " \
                   "green (cert owns g1_cert now, not dor-check): #{gate.inspect}"
      sops = gate.select { |l| l[1] == "sop" }
      sop_names = sops.map { |l| l[l.index("--sop") + 1] }
      assert_equal %w[test-prepare test-prepare mapped-tests mapped-tests spine spine
                      rubocop-changed rubocop-changed], sop_names

      # Each lane ANNOUNCES ITSELF BEFORE IT RUNS, then reports its verdict. The
      # board reads that leading `running` row to name the lane a building task is
      # inside — the whole point of the local-check indicator. A lane that only
      # emitted on completion would leave the slowest lane (the one an operator is
      # actually staring at) permanently unnamed.
      results = sops.map { |l| l[l.index("--result") + 1] }
      assert_equal %w[running pass running pass running pass running pass], results,
                   "every lane must emit running BEFORE its verdict: #{results.inspect}"

      # The running row carries the command, so the card's tooltip can show exactly
      # what is executing without opening the session.
      first_running = sops.find { |l| l[l.index("--result") + 1] == "running" }
      assert_includes first_running, "--cmd"
      close = gate.find { |l| l[1] == "close" }
      assert_includes close, "--success", "the green cert closes g1_cert success itself"
      assert(gate.all? { |l| l[2] == "task" && l[3] == "task-x" && l[4] == "g1_cert" })
    end
  end

  def test_red_lane_closes_g1_failed
    with_repo do |dir, _|
      _, code, lines = run_check(dir, args: ["task-x"], fail_token: "widget_test",
                                      extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 1, code
      close = lines.find { |l| l[0] == "GATE" && l[1] == "close" }
      refute_nil close, "a red lane closes the G1 attempt: #{lines.inspect}"
      assert_includes close, "--failed"
    end
  end

  def test_print_mode_emits_no_gate_or_task_writes
    with_repo do |dir, _|
      out, code, lines = run_check(dir, args: ["task-x", "--print"], extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code, out
      assert_empty(lines.select { |l| %w[GATE TASK].include?(l[0]) },
                   "--print is a dry run — no durable-record writes: #{lines.inspect}")
      assert_match(/\[fast-cert@/, out, "the evidence line still prints")
    end
  end

  def test_cert_checkpoints_bound_the_run_in_non_print_mode
    with_repo do |dir, _|
      _, code, lines = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => SHOW_JSON })
      assert_equal 0, code
      checkpoints = lines.select { |l| l[0] == "TASK" && l[1] == "checkpoint" }
      assert_equal [%w[started], %w[completed]],
                   checkpoints.map { |l| [l[l.index("--status") + 1]] },
                   "a cert checkpoint opens and closes the Local Certification window"
    end
  end

  def test_unreadable_task_checks_aborts_without_writing
    with_repo do |dir, _|
      # TASK stub fails on `show` → the runner must NOT blind-write --checks.
      out, code, lines = run_check(dir, args: ["task-x"],
                                        extra_env: { "TASK_SHOW_JSON" => "", "FAIL_TOKEN" => "show" })
      assert_equal 1, code, out
      refute(lines.any? { |l| l[0] == "TASK" && l[1] == "update" },
             "a blind --checks write would wipe tier tags — abort instead")
    end
  end

  # --- [integration] task-root guard: the cert must root at the TASK's tree ---------
  # Regression for the 2026-07-12 fail-GREEN: run from the hub primary (on main),
  # the cert rooted at the cwd's git toplevel and green-certified MAIN's tree for
  # an unrelated task. With a task slug and an IMPLICIT root (cwd, no
  # FAST_CHECK_ROOT), the cert must verify the root IS the task's tree —
  # its checked-out branch is the task's branch, or it is the task's
  # .worktrees/<worktree_slug> dir — and REFUSE otherwise (bin/lib/cert_root_guard.rb).

  GUARD_JSON = JSON.generate(
    "metadata" => { "devops" => {
      "branch" => "feat/task-x", "worktree_slug" => "task-x", "checks_run" => []
    } }
  )

  # --- [integration] desk guard: a desk that does not own its test DB may not certify ---
  # Right root, but is it a WHOLE desk? A desk whose test env resolves to the SHARED base
  # <app>_test certifies against the database the primary checkout and the release gate
  # workspaces are using — silently. bin/agent-worktree's bringup is atomic now and cannot
  # leave such a desk behind; this is the second lock, because desks half-built by the OLD
  # tool are still on disk and .env.test.local can be deleted by hand. bin/lib/desk_guard.rb.
  #
  # These drive the guard END TO END, through the shelled runner and a real `bin/rails`
  # boot (the fixture's shim — see write_repo_shape): DESK_DB_STUB is what the booted app
  # answers, and the verdict must follow THAT, never a declared string.

  def test_a_desk_with_no_isolated_test_db_is_refused_before_any_lane_runs
    with_repo(subpath: ".worktrees/half-built") do |dir, _|
      # The shim defaults to the SHARED name: bringup never gave this desk a DB of its own.
      out, code, lines = run_check(dir, implicit_root: true)

      assert_equal 1, code, "a desk with no isolated test DB must refuse, not certify: #{out}"
      assert_match(/no isolated test DB/, out)
      assert_match(/SHARED base test database/, out, "the refusal says WHY it matters")
      assert_match(/ENV issue/, out, "and names it as an env issue, not a regression in the diff")
      assert_empty lane_calls(lines, "TEST"), "the refusal fires BEFORE any lane runs"
      refute_match(/\[fast-cert@/, out, "nothing certified against a shared database")
    end
  end

  # THE INERT-PIN VECTOR, end to end. The desk PINS an isolated test DB and the app IGNORES
  # the pin (turf-monster, whose database.yml had no `url:` key) — so it resolves to the
  # SHARED database anyway. A presence-checking guard certifies this. It must refuse, and it
  # must say the pin is inert rather than send the operator back to bringup, which would
  # faithfully rewrite the very same inert pin.
  def test_a_desk_whose_pin_is_ignored_by_the_app_is_refused
    with_repo(subpath: ".worktrees/inert-pin") do |dir, write|
      write.call(".env.test.local", "TEST_DATABASE_URL=postgresql://localhost/studio_test_inert_pin\n")
      out, code, lines = run_check(dir, implicit_root: true) # shim still answers SHARED

      assert_equal 1, code, "a pin the app ignores is not isolation: #{out}"
      assert_match(/SHARED test database/, out)
      assert_match(/IGNORES it/, out, "the refusal must name the app's config, not the desk")
      assert_empty lane_calls(lines, "TEST"), "the refusal fires BEFORE any lane runs"
    end
  end

  # The control. Same desk layout, and the booted app really does land on its own DB. The
  # guard must not refuse a properly-provisioned worktree — that is where every cert
  # legitimately runs, so a guard that fails this one is worse than no guard.
  def test_a_desk_that_resolves_to_its_own_test_db_certifies_normally
    with_repo(subpath: ".worktrees/whole-desk") do |dir, write|
      write.call(".env.test.local", "TEST_DATABASE_URL=postgresql://localhost/studio_test_whole_desk\n")
      out, code, lines = run_check(dir, implicit_root: true,
                                   extra_env: { "DESK_DB_STUB" => "studio_test_whole_desk" })

      assert_equal 0, code, out
      refute_empty lane_calls(lines, "TEST"), "the lanes must run in a whole desk"
    end
  end

  # A SQLite desk (rolio) has NO TEST_DATABASE_URL by design — its test DB is a FILE inside
  # the desk, private by construction. Demanding the pin refused a perfectly isolated tree.
  def test_a_sqlite_desk_certifies_with_no_pin_at_all
    with_repo(subpath: ".worktrees/rolio-desk") do |dir, _|
      out, code, lines = run_check(dir, implicit_root: true,
                                   extra_env: { "DESK_DB_STUB" => "storage/test.sqlite3" })

      assert_equal 0, code, "a SQLite desk's test DB is a file inside it — allow: #{out}"
      refute_empty lane_calls(lines, "TEST")
    end
  end

  def test_wrong_root_cert_is_refused_before_any_lane_runs
    with_repo do |dir, _|
      # cwd = a tree on its default branch (main/master) — NOT task-x's tree.
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })
      assert_equal 1, code, "a wrong-root cert must refuse, not green-certify: #{out}"
      assert_match(/not task-x's tree/, out, "the refusal names the task")
      assert_match(%r{feat/task-x}, out, "the refusal names the expected branch")
      refute_match(/\[fast-cert@/, out, "no evidence for a tree the task never touched")
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
      refute(lines.any? { |l| l[0] == "GATE" }, "no G1 attempt opens for a refused run: #{lines.inspect}")
      refute(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "nothing recorded for a refused run")
    end
  end

  # A desk is written two ways on this machine, and the guard knew one:
  #
  #   <repo>/.worktrees/<slug>   the MANAGED layout bin/agent-worktree builds
  #   <repo>.worktrees/<slug>    the SIBLING tree the gem repos use
  #
  # bin/agent-worktree manages only the registered Rails apps, so a studio-engine or
  # solana-studio desk is cut with a plain `git worktree add` and lands beside the
  # repo. Shelled, because this is the seam the operator actually meets: the refusal
  # below is the text bin/fast-check, bin/full-suite-check and bin/ship all die! with,
  # and answering it by hand — export DOR_CHECK_DIFF_ROOT and re-run — is what taught
  # reviewers to override the guard on every engine review.
  def test_a_sibling_tree_desk_certifies_on_its_physical_vouch
    with_repo(subpath: "studio-engine.worktrees/task-x") do |dir, _|
      # COMMIT first: the cert is the LAST build step, so the dirty-tree guard would
      # otherwise refuse before the root guard is ever consulted (and this test would
      # pass for the wrong reason). Diffing from HEAD~1 keeps widget.rb in the lane.
      commit_all(dir)
      # Default branch, NOT feat/task-x: the branch axis cannot vouch, so ONLY the
      # physical desk vouch can save this run — which is what makes it a layout test
      # rather than a branch test that would pass either way.
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON,
                                                "FAST_CHECK_DIFF_BASE" => "HEAD~1" })

      assert_equal 0, code, "standing IN the task's desk must certify, whatever the layout: #{out}"
      refute_match(/not task-x's tree/, out, "the builder was standing in the desk it named")
      assert_match(/\[fast-cert@/, out, "the cert must actually be stamped")
      refute_empty lane_calls(lines, "TEST"), "the lanes must run in the task's own desk"
    end
  end

  # The control, and the half a second glob must not cost: the sibling tree is a desk
  # LAYOUT, not a blanket exemption. A tree that merely lives in one, under the wrong
  # name, is still not this task's tree and must still refuse.
  def test_a_sibling_tree_directory_that_is_not_the_tasks_desk_still_refuses
    with_repo(subpath: "studio-engine.worktrees/some-other-task") do |dir, _|
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })

      assert_equal 1, code, "another task's desk is not this task's tree: #{out}"
      assert_match(/not task-x's tree/, out)
      refute_match(/\[fast-cert@/, out, "no evidence for a tree the task never touched")
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
    end
  end

  def test_task_branch_checkout_certifies_without_a_root_override
    with_repo do |dir, _|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      # COMMIT the branch diff first — the dirty-tree guard below now enforces what
      # was previously only a house rule, so the cert is the LAST build step. Diffing
      # from HEAD~1 keeps widget.rb in the mapped lane now that it is committed.
      commit_all(dir)
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON,
                                                "FAST_CHECK_DIFF_BASE" => "HEAD~1" })
      assert_equal 0, code, "the task's own tree certifies from cwd with no override: #{out}"
      assert_match(/\[fast-cert@/, out)
      assert(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "evidence recorded: #{lines.inspect}")
      assert_includes lane_calls(lines, "TEST").flatten, "test/models/widget_test.rb",
                      "the mapped lane still selects off the diff once it is committed"
    end
  end

  # --- [integration] dirty-tree guard: certify only a fully-committed HEAD ----------
  # The cert fingerprint is a git TREE hash of the WORKING tree, so a cert taken with
  # edits uncommitted stamps GREEN evidence for code the PR never receives — live on
  # 2026-07-14, when a worktree's 146 lines of finished, tested work were certified
  # and then never reached PR #537. The refusal must land BEFORE any lane runs or any
  # gate/checkpoint/evidence write, exactly like the root guard above
  # (bin/lib/cert_tree_guard.rb).

  def test_dirty_tree_cert_is_refused_before_any_lane_runs
    with_repo do |dir, _|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      # The RIGHT tree (task-x's branch) — but widget.rb is still uncommitted.
      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })

      assert_equal 1, code, "an uncommitted tree must refuse, not green-certify: #{out}"
      assert_match(/DIRTY/, out)
      assert_match(%r{app/models/widget\.rb}, out, "the refusal NAMES the uncommitted file")
      assert_match(/commit/i, out, "the refusal states the fix")
      refute_match(/\[fast-cert@/, out, "no evidence for a tree that is not on the PR")
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
      refute(lines.any? { |l| l[0] == "GATE" }, "no G1 attempt opens for a refused run: #{lines.inspect}")
      refute(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "nothing recorded for a refused run")
    end
  end

  def test_stale_mtime_tree_still_certifies
    # THE FALSE POSITIVE the guard must not become. A tracked file rewritten with
    # IDENTICAL content has a fresh mtime, leaving git's stat cache stale — which the
    # cheap dirty reads (git diff-index) call MODIFIED. On the CERT path a false
    # refusal blocks every handoff, so the guard refreshes the index before reading
    # it. Unit-level proof, including the index-refresh mechanism itself, lives in
    # test/lib/cert_tree_guard_test.rb.
    with_repo do |dir, _|
      assert system("git", "-C", dir, "checkout", "-qb", "feat/task-x", out: File::NULL, err: File::NULL)
      commit_all(dir)

      tracked = File.join(dir, "app/models/widget.rb")
      body = File.read(tracked)
      File.write(tracked, body)                                       # byte-identical rewrite
      FileUtils.touch(tracked, mtime: Time.now + (10 * 365 * 24 * 3600))
      refute system("git", "-C", dir, "diff-index", "--quiet", "HEAD", out: File::NULL, err: File::NULL),
             "fixture check: the index must actually BE stat-stale, else this proves nothing"

      out, code, lines = run_check(dir, args: ["task-x"], implicit_root: true,
                                   extra_env: { "TASK_SHOW_JSON" => GUARD_JSON,
                                                "FAST_CHECK_DIFF_BASE" => "HEAD~1" })

      assert_equal 0, code, "a stat-stale index is a CLEAN tree — it must still certify: #{out}"
      refute_match(/DIRTY/, out, "a file nobody edited must never be reported as uncommitted work")
      assert_match(/\[fast-cert@/, out)
      assert(lines.any? { |l| l[0] == "TASK" && l[1] == "update" }, "evidence recorded: #{lines.inspect}")
    end
  end

  # --- [integration] the TIMEOUT-ORPHAN regression ------------------------------------
  #
  # Live bug, 2026-07-13. bin/fast-check outran the harness's 120s Bash timeout (a
  # diff that maps to ~120 test files runs 7+ minutes). The timeout killed the cert
  # PARENT — and the `bin/rails test` grandchild SURVIVED it, reparented to launchd
  # (PPID 1), still holding an open PG connection to the worktree's test DB:
  #
  #   41578  1  41538  R  ruby bin/rails test test/models/task_test.rb ...
  #   pid 41763 | idle in transaction | bin/rails
  #
  # Every retry then died in the test-prepare lane with
  #
  #   PG::ObjectInUse: database "..._test_..." is being accessed by other users
  #   DETAIL: There is 1 other session using the database.
  #   Tasks: TOP => db:test:load_schema => db:test:purge
  #
  # which fast-check reported as "USUALLY an ENV gap ... NOT a regression in your
  # diff" — never NAMING the orphan. So the agent retried blindly: three cert
  # attempts, 35 minutes, zero board progress, while its ClaimLease heartbeat kept
  # the task looking healthy on the board.
  #
  # Root cause: `system(env, cmd, chdir: root)` runs the lane in the cert's OWN
  # process group and installs no signal handler, so a signal aimed at the cert
  # never reaches the suite. The cert must (a) put each lane in its own process
  # GROUP and reap that group when it dies, and (b) detect an orphan it could not
  # prevent and say its name.

  # A lane stub that records its pid and then hangs — stands in for `bin/rails test`
  # holding the test DB. Returns the path; the pid lands in <dir>/lane.pid.
  def write_hanging_lane(dir)
    lane = File.join(dir, "hanging-lane")
    File.write(lane, <<~RUBY)
      #!#{RbConfig.ruby}
      File.write(File.join(#{dir.inspect}, "lane.pid"), Process.pid.to_s)
      sleep 120
    RUBY
    FileUtils.chmod("+x", lane)
    lane
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  # Has a process WE spawned actually exited? `kill(0)` cannot answer this for our own
  # children: a killed child lingers as a ZOMBIE whose pid still answers signal 0 until
  # its parent reaps it. (A real orphan is reparented to launchd, which reaps it at once
  # — the zombie is an artefact of the test owning the process.) So we wait on it.
  def exited?(pid, timeout: 10)
    deadline = Time.now + timeout
    loop do
      return true if Process.waitpid(pid, Process::WNOHANG)
      return false if Time.now > deadline

      sleep 0.1
    end
  rescue Errno::ECHILD
    true # already reaped
  end

  def wait_until(timeout: 10)
    deadline = Time.now + timeout
    sleep 0.1 until yield || Time.now > deadline
    yield
  end

  # THE regression: kill the cert the way a harness timeout does, and the suite it
  # spawned must not outlive it. Before the fix the lane survived as an orphan
  # holding the test DB; after it, the cert reaps its whole process group.
  def test_a_killed_cert_does_not_orphan_the_suite_it_spawned
    with_repo do |dir, _|
      lane = write_hanging_lane(dir)
      env = child_env(
        {
          "FAST_CHECK_ROOT" => dir,
          "FAST_CHECK_DIFF_BASE" => "HEAD",
          "FAST_CHECK_SPINE" => File.join(dir, "spine.yml"),
          "FAST_CHECK_TEST_PREPARE_CMD" => "true",
          "FAST_CHECK_TEST_CMD" => lane.shellescape,
          "FAST_CHECK_RUBOCOP_CMD" => "true",
          "FAST_CHECK_SKIP_ORPHAN_GUARD" => "1" # the guard is tested separately below
        }
      )
      cert = Process.spawn(env, BIN, "--print", chdir: dir, out: File::NULL, err: File::NULL)
      pid_file = File.join(dir, "lane.pid")
      assert wait_until { File.exist?(pid_file) }, "the lane never started"
      lane_pid = File.read(pid_file).to_i
      assert alive?(lane_pid), "the lane should be running before we kill the cert"

      # The harness timeout: signal the cert PROCESS, not the group.
      Process.kill("TERM", cert)
      Process.waitpid(cert)

      reaped = wait_until(timeout: 10) { !alive?(lane_pid) }
      assert reaped,
             "ORPHAN: the suite (pid #{lane_pid}) outlived the cert that spawned it. It keeps the " \
             "worktree test DB open, and every retry dies on PG::ObjectInUse blaming 'an ENV gap'."
    ensure
      Process.kill("KILL", lane_pid) if lane_pid && alive?(lane_pid)
    end
  end

  # --- [integration] the guard: an orphan we could NOT prevent must be NAMED ----------
  #
  # A SIGKILLed cert runs no handler, so prevention alone can never be complete. The
  # next cert therefore reads the runlock the previous one left. A dead cert pid whose
  # process group is still alive is NOT, by itself, proof of an abandoned suite: a pgid
  # is a recyclable integer and this lock is repo-relative (it outlives reboots), so the
  # number may since have been handed to a stranger. The lock therefore records the OS's
  # start time for the group leader, and the guard reaps only what that identity proves
  # is ours. Anything else is refused or discarded — never killed, never silently
  # blocked.

  # The OS's own start-time record, read independently of the code under test — a
  # fixture that builds itself with the implementation it is checking proves nothing.
  def os_start_time(pid)
    # 2>/dev/null: the dead-cert fixtures name pids like 999_999 on purpose, and `ps`
    # grumbles "process id too large" onto stderr. A cert log is a signal; do not
    # teach anyone to read past noise in it.
    out = `ps -p #{pid.to_i} -o lstart= 2>/dev/null`.strip.squeeze(" ")
    out.empty? ? nil : out
  end

  # The runlock as CertProcess writes it: WHO, and — the whole point — WHEN.
  # `pgid_started_at:` overrides the identity, to forge the two locks that matter:
  # a recycled pgid (a start time that is not this process's) and a legacy lock
  # (`nil` — written before the guard recorded identity at all).
  # The runlock lives in the GIT DIR, never in the working tree — a lock inside the tree
  # is untracked dirt in any repo that does not ignore `tmp/`, and the cert now refuses a
  # dirty tree (see bin/lib/cert_orphan_guard.rb#lock_path). Resolved here by asking git
  # DIRECTLY, not by calling CertOrphanGuard: a fixture that builds itself with the
  # implementation it is checking proves nothing.
  def git_dir(dir)
    out = `git -C #{dir.shellescape} rev-parse --absolute-git-dir 2>/dev/null`.strip
    refute_empty out, "the fixture repo must be a git repo"
    out
  end

  def write_lock(dir, cert_pid:, pgid:, pgid_started_at: :real, cert_started_at: :real)
    started = pgid_started_at == :real ? os_start_time(pgid) : pgid_started_at
    cert_started = cert_started_at == :real ? os_start_time(cert_pid) : cert_started_at
    lock = File.join(git_dir(dir), "cert-run.json")
    FileUtils.mkdir_p(File.dirname(lock))
    File.write(lock, JSON.generate("cert_pid" => cert_pid, "cert_started_at" => cert_started,
                                   "pgid" => pgid, "pgid_started_at" => started, "lane" => "spine",
                                   "db" => "studio_test_x", "started_at" => "2026-07-13T05:00:00Z"))
    lock
  end

  def test_a_leftover_orphan_group_is_named_and_reaped_before_the_lanes_run
    with_repo do |dir, _|
      # An orphan: a live process group whose cert parent is long dead.
      orphan = Process.spawn("sleep 120", pgroup: true)
      orphan_pgid = Process.getpgid(orphan)
      write_lock(dir, cert_pid: 999_999, pgid: orphan_pgid) # 999999 = a pid that is not running

      # implicit_root: runs from `dir` with stderr merged, so the guard's message is assertable.
      out, code, lines = run_check(dir, implicit_root: true)

      assert_equal 0, code, "reaping our own orphan is self-healing — the cert proceeds: #{out}"
      assert_match(/#{orphan_pgid}/, out, "the cert must NAME the orphan it reaped, not swallow it")
      assert_match(/NOT a regression in your diff/, out, "an ENV-class condition must say so")
      assert exited?(orphan),
             "the orphan (pgid #{orphan_pgid}) must be REAPED — it is what holds the test DB"
      refute_empty lane_calls(lines, "TEST"), "after reaping, the cert runs normally"
    ensure
      begin
        if orphan
          Process.kill("KILL", orphan)
          Process.waitpid(orphan)
        end
      rescue Errno::ESRCH, Errno::ECHILD
        nil # already reaped by the guard — which is the point of the test
      end
    end
  end

  def test_a_live_concurrent_cert_is_refused_and_never_killed
    with_repo do |dir, _|
      # NOT an orphan: another cert is genuinely running in this tree. Killing it
      # would be hostile, and running beside it is the known two-suites-on-one-test-DB
      # hazard (it SIGSEGVs Ruby). Refuse — and leave it alone.
      sibling = Process.spawn("sleep 120", pgroup: true)
      write_lock(dir, cert_pid: sibling, pgid: Process.getpgid(sibling))

      out, code, lines = run_check(dir, implicit_root: true)

      assert_equal 1, code, "a concurrent cert in the same tree must be refused: #{out}"
      assert_match(/#{sibling}/, out, "the refusal names the running cert")
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
      assert alive?(sibling), "a LIVE cert must never be killed by the guard"
      refute_match(/\[fast-cert@/, out, "nothing is certified against a contended test DB")
    ensure
      Process.kill("KILL", sibling) if sibling && alive?(sibling)
    end
  end

  def test_a_stale_lock_from_a_fully_dead_cert_never_blocks_a_cert
    with_repo do |dir, _|
      # Nothing survived — the lock is a corpse. It must not refuse a healthy cert.
      write_lock(dir, cert_pid: 999_998, pgid: 999_999)
      out, code, = run_check(dir)
      assert_equal 0, code, "a stale lock must be cleared, not treated as a live claim: #{out}"
      assert_match(/\[fast-cert@/, out)
    end
  end

  def test_a_runlock_whose_pgid_was_RECYCLED_never_kills_the_bystander
    with_repo do |dir, _|
      # THE BLOCKING BUG, end to end through the real bin/fast-check. The lock is days
      # old, its cert is long dead, and the OS has since handed its pgid to an unrelated
      # process. Grading that "alive, therefore mine" made the cert TERM/KILL an innocent
      # bystander and print "ORPHAN REAPED" (caught in review, 2026-07-14).
      #
      # The recorded start time is the tell: it names an instant before this process
      # existed, so the group is provably NOT ours.
      bystander = Process.spawn("sleep 120", pgroup: true)
      bygid = Process.getpgid(bystander)
      write_lock(dir, cert_pid: 999_999, pgid: bygid, pgid_started_at: "Mon Jul  6 18:40:11 2026")

      out, code, lines = run_check(dir, implicit_root: true)

      # NOT `alive?`: a child we killed lingers as a zombie whose pid still answers
      # signal 0, so kill(0) would report a murdered bystander as alive and pass this
      # test on a regression. `exited?` waitpid()s — it cannot be fooled.
      refute exited?(bystander, timeout: 2),
             "THE BLOCKING BUG: fast-check KILLED an innocent process (pid #{bystander}) whose only " \
             "crime was being handed the recycled pgid #{bygid}"
      assert_equal 0, code, "and a stranger's process must not wedge the cert either: #{out}"
      assert_match(/NOT killing it/i, out, "the cert must say out loud that it refused to kill")
      refute_empty lane_calls(lines, "TEST"), "it discards the stale lock and runs normally"
    ensure
      begin
        if bystander
          Process.kill("KILL", bystander)
          Process.waitpid(bystander)
        end
      rescue Errno::ESRCH, Errno::ECHILD
        nil # already gone — which would mean the regression this test exists to catch
      end
    end
  end

  def test_a_legacy_runlock_with_no_identity_refuses_rather_than_killing_on_a_guess
    with_repo do |dir, _|
      # A lock written before the guard recorded identity (this is what is on disk in
      # every worktree today). Something is alive under that pgid. It might be our
      # stranded suite; it might be the operator's editor. We cannot tell — and a reaper
      # that guesses is worse than no reaper, so a human decides.
      unknown = Process.spawn("sleep 120", pgroup: true)
      ungid = Process.getpgid(unknown)
      write_lock(dir, cert_pid: 999_999, pgid: ungid, pgid_started_at: nil)

      out, code, lines = run_check(dir, implicit_root: true)

      refute exited?(unknown, timeout: 2), "never kill what you cannot prove is yours"
      assert_equal 1, code, "an unprovable claim on the test DB is refused, not walked into: #{out}"
      assert_match(/#{ungid}/, out, "the refusal NAMES what it found")
      assert_match(/rm .*cert-run\.json/, out, "and hands over the way to clear a lock that is not yours")
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
    ensure
      begin
        if unknown
          Process.kill("KILL", unknown)
          Process.waitpid(unknown)
        end
      rescue Errno::ESRCH, Errno::ECHILD
        nil # already gone — which would mean the regression this test exists to catch
      end
    end
  end

  # THE SECOND BUG, end to end through the real bin/fast-check (review, 2026-07-14).
  #
  # A truncated runlock names process group 1. pid 1 (launchd/init) is always alive, so the
  # guard finds live members under that number and REFUSES — correctly. The bug was what it
  # PRINTED while refusing:
  #
  #   If it IS a stranded suite:  kill -TERM -1
  #
  # POSIX defines `kill -TERM -1` as EVERY process the caller may signal. The cert would not
  # fire it — `signalable?` saw to that — and then handed it to a human to paste, in the
  # house's authoritative "here is how to clear it" voice, at the exact moment (35 minutes
  # into a wedge) that a human pastes without reading. The code path was hardened and the
  # COPY path was not, and the copy path is the one with a human on the end of it.
  #
  # This asserts it where an operator actually meets it: on the real cert's real stdout.
  def test_a_runlock_naming_group_1_refuses_without_ever_printing_kill_TERM_minus_1
    with_repo do |dir, _|
      write_lock(dir, cert_pid: 999_999, pgid: 1, pgid_started_at: nil)

      out, code, lines = run_check(dir, implicit_root: true)

      assert_equal 1, code, "a runlock naming group 1 is garbage — refuse, never run beside it: #{out}"
      refute_match(/kill\s+(?:-\w+\s+)*-?[01]\b/, out,
                   "THE BUG: the cert refused to FIRE `kill -TERM -1` and then PRINTED it for a human " \
                   "to paste. It signals every process the caller owns. Full output:\n#{out}")
      assert_match(/rm .*cert-run\.json/, out,
                   "a lock naming group 1 is garbage by construction; the only remediation is to discard it")
      assert_empty lane_calls(lines, "TEST"), "refusal fires BEFORE any lane runs"
    end
  end

  def test_explicit_root_override_bypasses_the_dirty_tree_guard
    # Same contract as the root guard: an EXPLICIT FAST_CHECK_ROOT is the deliberate
    # CI/test seam, so it bypasses. (run_check's default path sets it — that is why
    # every other test in this file certifies against the fixture's uncommitted diff.)
    with_repo do |dir, _|
      out, code, = run_check(dir, args: ["task-x"], extra_env: { "TASK_SHOW_JSON" => GUARD_JSON })
      assert_equal 0, code, "an explicitly-declared root still certifies: #{out}"
      refute_match(/DIRTY/, out)
    end
  end

  # Commit everything in `dir` — the fixture's uncommitted branch diff — so the cert
  # runs against a fully-committed HEAD, which the dirty-tree guard now requires.
  def commit_all(dir)
    assert system("git", "-C", dir, "add", "-A", out: File::NULL, err: File::NULL)
    assert system("git", "-C", dir, "commit", "-qm", "widget", out: File::NULL, err: File::NULL)
  end
end
