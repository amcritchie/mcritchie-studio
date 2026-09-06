# frozen_string_literal: true

require "test_helper"
require "rake"

# Regression tier for `releases:refresh_duration_metrics` — the rake the release
# pipeline runs as a post-deploy hook (see Release::PostDeploy), and the one
# docs/agents/system/devops-cycle-design.md RECOMMENDS as the idempotent
# post-deploy hook, so its exit status is the shape other authors copy.
#
# THE BUG THIS FILE EXISTS FOR: the rake printed the slugs it had managed to
# refresh and exited 0 unconditionally. `bin/release` derives the hook's verdict
# purely from the process exit status (`heroku run --exit-code`) and never parses
# stdout — so a run that rewrote NOTHING printed the bare line
# "release duration metrics refreshed: ", exited 0, and the release shipped past
# it with /deployments still serving the stored numbers.
class ReleasesRefreshDurationMetricsRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("releases:refresh_duration_metrics")
    Release.delete_all
  end

  # Invoke the rake and report BOTH halves the pipeline reads: what it printed and
  # what it EXITED. `abort` raises SystemExit, which is not a StandardError — it
  # would otherwise escape this test the same way it escapes rake into the shell.
  # (That SystemExit really does become a non-zero PROCESS exit under both runner
  # spellings production declares, `bin/rails` and `rake`; verified out-of-process
  # against this task, since an in-process rescue cannot prove it.)
  def run_rake
    Rake::Task["releases:refresh_duration_metrics"].reenable
    status = 0
    out, err = capture_io do
      Rake::Task["releases:refresh_duration_metrics"].invoke
    rescue SystemExit => e
      status = e.status
    end
    [out + err, status]
  end

  # A shipped release is all #recent_releases selects on; ordering is shipped_at DESC.
  #
  # The cache columns are BLANKED on the way out, and that is what gives the
  # "did this release actually get refreshed?" assertions something to bite on.
  # Release has `after_commit :refresh_duration_metrics_safely, on: %i[create update]`,
  # so a freshly created release ALREADY carries duration_metrics — asserting they are
  # present after the run would then pass whether or not the run ever touched the row.
  # update_columns skips callbacks, so the gap it opens stays open until the rake
  # itself writes into it. The stamp is `duration_cache_version: 0` (the columns are
  # NOT NULL, so "blank" has to be an out-of-band VALUE rather than nil): only a real
  # DurationCache.refresh! moves it to VERSION, which makes the version the least
  # ambiguous evidence that a given row was rewritten by THIS run.
  def make_releases(count, base: 3.days.ago)
    Array.new(count) do |i|
      release = Release.create!(slug: "duration-probe-#{i}", branch: "release", state: "shipped")
      release.update_columns( # rubocop:disable Rails/SkipsModelValidations
        shipped_at: base + i.hours,
        created_at: base + i.hours,
        duration_metrics: {},
        duration_metrics_cached_at: nil,
        duration_cache_version: 0
      )
      release
    end
  end

  # Raise for exactly the named slugs — the "one poisoned release" shape, as opposed
  # to a systematic all-rows failure — and CALL THROUGH to the real refresh! for the
  # rest. Passing through is load-bearing, not incidental: a stub that returned a bare
  # nil for the survivors would let "the others were refreshed" assert green without
  # a single row being written, which is the assertion these tests exist to make.
  def stub_refresh_failing_for(slugs, &block)
    original = Release::DurationCache.method(:refresh!)
    stub = lambda do |release, **kwargs|
      slug = release.is_a?(Release) ? release.slug : release.to_s
      raise "poisoned release history" if slugs.include?(slug)

      original.call(release, **kwargs)
    end
    Release::DurationCache.stub(:refresh!, stub, &block)
  end

  # --- guard 1: a total no-op can never be green (the filed bug) --------------

  test "aborts non-zero when every refresh raises, so the post-deploy hook goes red" do
    make_releases(3)

    out, status = Release::DurationCache.stub(:refresh!, ->(*, **) { raise "boom" }) { run_rake }

    refute_equal 0, status, "a refresh that rewrote NOTHING must not exit 0 — " \
                            "`heroku run --exit-code` is what turns the post-deploy hook red"
    assert_match(/refreshed 0 of 3/, out, "the abort says how far short the run fell")
  end

  # The no-op guard is unconditional ON PURPOSE, and this is the test that pins it
  # apart from guard 2. At the default allowance of ZERO the two guards are
  # redundant — every no-op is also past the allowance — so only an allowance
  # RAISED above the population can show the no-op guard carrying its own weight.
  test "a total no-op aborts even when the allowance is raised above the population" do
    make_releases(2)

    out, status = with_env("REFRESH_MAX_SKIPPED", "99") do
      Release::DurationCache.stub(:refresh!, ->(*, **) { raise "boom" }) { run_rake }
    end

    refute_equal 0, status, "no allowance may excuse a run that rewrote nothing"
    assert_match(/rewrote NOTHING/, out)
  end

  # --- guard 2: any shortfall aborts at the default zero allowance ------------

  test "aborts when one release of three is skipped, at the default zero allowance" do
    releases = make_releases(3)
    poisoned = [releases.last.slug] # shipped_at DESC ⇒ the most recent

    out, status = stub_refresh_failing_for(poisoned) { run_rake }

    refute_equal 0, status, "one stale release of three is a third of the /deployments sample"
    assert_match(/skipped 1 of 3/, out)
    assert_match(/#{poisoned.first}/, out, "the abort names the release that was skipped")
  end

  # --- the denominator: the SELECTED SET, never the limit ---------------------

  # THE TRAP a naive copy of the sibling backfill falls into. `limit` is a CEILING,
  # not a demand: measuring against it would call a complete two-release board a
  # shortfall and abort a release on a BOARD STATE, on every deploy, forever.
  test "a board holding fewer shipped releases than the limit is a complete run" do
    make_releases(2)

    out, status = with_env("LIMIT", "3") { run_rake }

    assert_equal 0, status, "2 shipped releases under a ceiling of 3 is complete, not short"
    assert_match(/refreshed 2 of 2/, out, "the denominator is what the selection returned, not the limit")
  end

  test "an empty board is not a no-op, but it says so out loud" do
    out, status = run_rake

    assert_equal 0, status, "0 of 0 is a complete run on a board with no shipped releases"
    assert_match(/refreshed 0 of 0/, out)
    assert_match(/no shipped releases were selected/, out,
                 "an empty selection is green, but it must not read like a healthy refresh — " \
                 "that indistinguishability is half of what the old bare line cost us")
  end

  test "a healthy run does not carry the empty-selection note" do
    make_releases(2)

    out, _status = run_rake

    refute_match(/no shipped releases were selected/, out, "the note is for an empty selection only")
  end

  # --- the rescue: a poisoned release must not starve the ones behind it ------

  test "a poisoned most-recent release no longer stops the older ones refreshing" do
    releases = make_releases(3)
    poisoned = releases.last # shipped_at DESC ⇒ selected FIRST
    survivors = releases - [poisoned]

    assert_equal poisoned.slug, Release::DurationCache.recent_releases(limit: 3).first.slug,
                 "premise: the poisoned release is selected FIRST, so it is what used to " \
                 "raise out of the map before anything behind it was attempted"

    _out, status = with_env("REFRESH_MAX_SKIPPED", "1") do
      stub_refresh_failing_for([poisoned.slug]) { run_rake }
    end

    assert_equal 0, status, "one tolerated skip, with the allowance raised for it"
    assert_equal 0, poisoned.reload.duration_cache_version,
                 "premise: the poisoned release really did fail, so its stamp never moved"
    survivors.each do |release|
      assert_equal Release::DurationCache::VERSION, release.reload.duration_cache_version,
                   "#{release.slug} sits BEHIND the poisoned release in shipped_at DESC order — " \
                   "it used to never be attempted at all, because the raise escaped the map"
    end
  end

  # --- the escape hatch, and its refusal to be disarmed by a typo -------------

  test "a raised allowance tolerates an isolated skip and exits 0" do
    releases = make_releases(3)

    out, status = with_env("REFRESH_MAX_SKIPPED", "1") do
      stub_refresh_failing_for([releases.last.slug]) { run_rake }
    end

    assert_equal 0, status, "an operator may step past one known-bad release"
    assert_match(/skipped 1/, out, "a tolerated skip is still named in the deploy log")
  end

  test "a garbled allowance falls back to the strict default rather than disarming" do
    releases = make_releases(3)

    _out, status = with_env("REFRESH_MAX_SKIPPED", "all") do
      stub_refresh_failing_for([releases.last.slug]) { run_rake }
    end

    refute_equal 0, status, "a typo in a deploy env var must never be what lets a shortfall ship"
  end

  # --- the happy path stays green --------------------------------------------

  test "a clean run exits 0 and reports refreshed of attempted" do
    make_releases(3)

    out, status = run_rake

    assert_equal 0, status
    assert_match(/refreshed 3 of 3/, out)
  end
end
