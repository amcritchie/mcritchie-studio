# frozen_string_literal: true

namespace :releases do
  desc "Refresh cached duration metrics for the most recent shipped releases"
  # The release pipeline runs this as a post-deploy hook (Release::PostDeploy), and a
  # hook's verdict is its EXIT STATUS — `heroku run --exit-code` propagates it, and
  # bin/release's run_post_deploy abort!s the release on a non-zero.
  #
  # So this task must exit non-zero when the refresh fell short. It used to print the
  # slugs it managed to refresh and exit 0 unconditionally: a run that rewrote NOTHING
  # printed the bare line "release duration metrics refreshed: " and exited 0, and the
  # pipeline recorded the hook GREEN over a /deployments dashboard still serving the
  # stored numbers. The list of winners is not the verdict — the comparison of refreshed
  # against ATTEMPTED is (Release::DurationCache::RefreshResult#shortfall).
  #
  # `docs/agents/system/devops-cycle-design.md` recommends this task as THE idempotent
  # post-deploy hook, so its exit status is copied by every author who follows that
  # advice; it had better mean something.
  task refresh_duration_metrics: :environment do
    limit = ENV.fetch("LIMIT", "3").to_i
    limit = 3 if limit <= 0

    result = Release::DurationCache.refresh_recent!(limit: limit)
    allowance = Release::DurationCache.refresh_skip_allowance

    puts "release duration metrics #{result.summary}"

    # An EMPTY SELECTION stays green — 0 of 0 is a complete run on a board with no
    # shipped releases (a young board, a QA database, an app's first-ever release),
    # and redding it would abort a release mid-deploy over a board state. But it is
    # said out loud, because "nothing was selected" is exactly what the old bare
    # "refreshed: " line made indistinguishable from a healthy run.
    if result.attempted.zero?
      puts "[release-duration-metrics] NOTE: no shipped releases were selected, so there " \
           "was nothing to refresh. On a board that HAS shipped releases, the selection " \
           "itself is the thing to investigate."
    end

    shortfall = result.shortfall(allowance: allowance)
    next unless shortfall

    abort "[release-duration-metrics] refresh FAILED: #{shortfall}. " \
          "The cached duration_metrics were NOT rewritten, so /deployments and the " \
          "per-release read views are still serving the stored values. Fix the cause " \
          "and re-run — the refresh is idempotent. To ship past a known-bad release, " \
          "raise the allowance: REFRESH_MAX_SKIPPED=<n>."
  end
end
