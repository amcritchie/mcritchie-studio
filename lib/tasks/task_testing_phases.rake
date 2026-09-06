# frozen_string_literal: true

namespace :tasks do
  desc "Backfill/refresh the per-task testing-phase projection (Task::TestingPhases) for every task"
  # The release pipeline runs this as a post-deploy hook (Release::PostDeploy), and
  # a hook's verdict is its EXIT STATUS — `heroku run --exit-code` propagates it,
  # bin/release records the check red on a non-zero, and aborts the release.
  #
  # So this task must exit non-zero when the backfill fell short. It used to print a
  # success count and exit 0 unconditionally: a systematic failure printed
  # "refreshed for 0 task(s)", exited 0, and the pipeline recorded GREEN over a
  # backfill that rewrote nothing. The count is not the verdict — the comparison of
  # refreshed against attempted is (Task::TestingPhases::BackfillResult#shortfall).
  task backfill_testing_phases: :environment do
    result = Task::TestingPhases.backfill!
    allowance = Task::TestingPhases.backfill_skip_allowance

    puts "testing-phase projection #{result.summary}"

    shortfall = result.shortfall(allowance: allowance)
    next unless shortfall

    abort "[task-testing-phases] backfill FAILED: #{shortfall}. " \
          "The projection was NOT fully rewritten, so any version-blind reader " \
          "(Review::DurationRoll reads the jsonb directly in SQL) is still serving the " \
          "stored values. Fix the cause and re-run — the backfill is idempotent. " \
          "To ship past a known-bad row, raise the allowance: BACKFILL_MAX_SKIPPED=<n>."
  end
end
