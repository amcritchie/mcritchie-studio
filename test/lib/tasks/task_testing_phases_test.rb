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
