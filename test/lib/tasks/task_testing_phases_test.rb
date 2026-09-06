require "test_helper"
require "rake"

# Regression tier for `tasks:backfill_testing_phases` — the rake the release
# pipeline runs as a post-deploy hook (see Release::PostDeploy).
#
# THE BUG THIS FILE EXISTS FOR: Task::TestingPhases.backfill! used to return a
# SUCCESS count with a per-task `rescue` that did not increment it, and the rake
# printed that count and exited 0 regardless. So a DB blip mid-run, or a column
# missing after a partial migration, made EVERY refresh raise, printed
# "refreshed for 0 task(s)", exited 0 — and the pipeline recorded the hook GREEN
# and shipped past a backfill that rewrote nothing.
class TasksBackfillTestingPhasesRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("tasks:backfill_testing_phases")
    Task.delete_all
  end

  # Invoke the rake and report BOTH halves the pipeline reads: what it printed and
  # what it exited. `abort` raises SystemExit, which is not a StandardError — it
  # would otherwise escape the test the same way it escapes rake into the shell.
  def run_rake
    Rake::Task["tasks:backfill_testing_phases"].reenable
    status = 0
    out, err = capture_io do
      Rake::Task["tasks:backfill_testing_phases"].invoke
    rescue SystemExit => e
      status = e.status
    end
    [out + err, status]
  end

  def make_tasks(count)
    Array.new(count) { |i| Task.create!(title: "backfill probe task #{i}") }
  end

  # --- guard 1: a total no-op can never be green (the filed bug) --------------

  test "aborts non-zero when every refresh raises, so the hook goes red" do
    make_tasks(3)

    out, status = Task::TestingPhases.stub(:refresh!, ->(*) { raise "boom" }) { run_rake }

    refute_equal 0, status, "a backfill that rewrote NOTHING must not exit 0 — " \
                            "`heroku run --exit-code` is what turns the post-deploy hook red"
    assert_match(/refreshed 0 of 3/, out, "the abort says how far short the run fell")
  end

  # The no-op guard is unconditional ON PURPOSE: the skip allowance exists to keep
  # one poisoned row from wedging the pipeline, and no allowance should be able to
  # excuse a run that rewrote nothing. A 3-row population sits UNDER the allowance,
  # so only this guard can catch it — that is what pins the two guards apart.
  test "a total no-op aborts even when the skip count sits under the allowance" do
    make_tasks(2)
    assert_operator 2, :<=, Task::TestingPhases::BACKFILL_SKIP_ALLOWANCE,
                    "premise: this population is small enough that the allowance would forgive it"

    _out, status = Task::TestingPhases.stub(:refresh!, ->(*) { raise "boom" }) { run_rake }

    refute_equal 0, status
  end

  # --- guard 2: a systematic shortfall aborts even with most rows rewritten ---

  test "aborts non-zero when skips exceed the allowance although most rows refreshed" do
    allowance = Task::TestingPhases::BACKFILL_SKIP_ALLOWANCE
    tasks = make_tasks(allowance + 6)
    poisoned = tasks.first(allowance + 1).map(&:slug)

    out, status = stub_refresh_failing_for(poisoned) { run_rake }

    refute_equal 0, status, "more than the allowance is systematic, not poison"
    assert_match(/#{allowance + 1} of #{tasks.size}/, out)
  end

  # --- the deliberate NON-abort: isolated poison must not wedge the release ---

  test "tolerates skips within the allowance, exits 0, and names the skipped rows" do
    tasks = make_tasks(Task::TestingPhases::BACKFILL_SKIP_ALLOWANCE + 4)
    poisoned = tasks.first(2).map(&:slug)

    out, status = stub_refresh_failing_for(poisoned) { run_rake }

    assert_equal 0, status, "a couple of poisoned histories must not abort a release " \
                            "MID-DEPLOY — the hook runs after the code is already live"
    poisoned.each { |slug| assert_match(slug, out, "a tolerated skip is still named in the deploy log") }
  end

  # --- the ceiling: an override widens the hatch, it cannot remove the floor --

  # THE REGRESSION. BACKFILL_MAX_SKIPPED was unbounded, which made it a DISARM
  # rather than a widening: on a 20-row board, 19 rows could fail with
  # BACKFILL_MAX_SKIPPED=999999, the rake still exited 0, `heroku run --exit-code`
  # reported success, and the release stamped its [post-deploy] check GREEN over a
  # board that had barely been rewritten at all.
  test "a huge override cannot make a mass skip exit 0" do
    tasks = make_tasks(20)
    poisoned = tasks.first(19).map(&:slug)

    out, status = with_env("BACKFILL_MAX_SKIPPED" => "999999") do
      stub_refresh_failing_for(poisoned) { run_rake }
    end

    refute_equal 0, status, "19 of 20 skipped is systematic — no env var may ship that green"
    assert_match(/capped to 10/, out, "the abort names the cap in force, not the number typed")
  end

  # The hatch must SURVIVE the cap, or the fix would have traded an unbounded
  # override for no override at all. 8 skips sits over the default 5 and under this
  # board's ceiling of 10, so only a raised allowance can carry it.
  test "an override still tolerates more than the default below the ceiling" do
    tasks = make_tasks(20)
    poisoned = tasks.first(8).map(&:slug)

    _out, capped = with_env("BACKFILL_MAX_SKIPPED" => "8") do
      stub_refresh_failing_for(poisoned) { run_rake }
    end
    _out, defaulted = stub_refresh_failing_for(poisoned) { run_rake }

    assert_equal 0, capped, "the escape hatch is capped, not removed"
    refute_equal 0, defaulted, "premise: 8 skips DO abort without the override"
  end

  # --- the happy path stays green --------------------------------------------

  test "a clean run exits 0 and reports refreshed of attempted" do
    make_tasks(3)

    out, status = run_rake

    assert_equal 0, status
    assert_match(/refreshed 3 of 3/, out)
  end

  test "an empty board is not a shortfall" do
    out, status = run_rake

    assert_equal 0, status, "0 of 0 is a complete run, not a no-op"
    assert_match(/refreshed 0 of 0/, out)
  end

  private

  # Set env vars for the block and restore exactly what was there — the rake reads
  # BACKFILL_MAX_SKIPPED through Task::TestingPhases.backfill_skip_allowance(env: ENV),
  # so the override has to travel the real path to be worth asserting.
  def with_env(pairs)
    saved = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # Stub refresh! to raise for exactly the named slugs and succeed for the rest —
  # the "one poisoned row" shape, as opposed to the systematic all-rows failure.
  def stub_refresh_failing_for(slugs, &block)
    stub = lambda do |task, **|
      raise "poisoned history" if slugs.include?(task.is_a?(Task) ? task.slug : task.to_s)

      nil # a non-raising refresh is all these tests need; the real write is covered
      # in test/models/task/testing_phases_test.rb
    end
    Task::TestingPhases.stub(:refresh!, stub, &block)
  end
end
