require "shellwords"

class Release
  # Pure decision logic for the release pipeline's post-deploy command hook —
  # the seam behind `bin/release prepare`/`ship` that runs a release member's
  # declared `devops.post_deploy_cmd` against the just-deployed app (the QA heroku
  # app on prepare, the production app on ship).
  #
  # Like Release::ShipSequence + Release::GemfileRepin this is deliberately IO-free:
  # no heroku, no git, no network. It takes the repo plan + the qa_environments
  # registry in and returns an ordered list of { task, repo, app, cmd } commands
  # out, so the `heroku run` orchestration + the abort-on-failure + the
  # checks_run recording all stay in bin/release and the target-resolution +
  # filtering decisions stay HERE, unit tested. (bin/release `require`s this file
  # directly — it has no Rails deps.)
  #
  # WHY a member declares this: a deploy sometimes needs a one-off command run on
  # the dyno AFTER the code is live (a backfill, a cache warm, a data migration).
  # Before this hook those lived only in PR prose (e.g. backfill-pokemon-mascots's
  # `heroku run rake pokemon:backfill_mascots`) and had to be run by hand on QA and
  # again on prod. Declaring it on the task makes the pipeline run it on both,
  # record the outcome, and abort the release if it fails.
  module PostDeploy
    module_function

    # The two pipeline targets a post-deploy command can run against: :qa (the
    # repo's QA heroku app, run during `prepare`) and :prod (its production app,
    # run during `ship`).
    TARGETS = %i[qa prod].freeze

    # Build the ordered post-deploy command plan for a release.
    #
    # `repos`           — the repo_plan output as the CLI sees it (JSON-parsed →
    #                     STRING keys). Each group carries "repo", "qa_app" (the
    #                     qa-server key), and "members" (each member may carry a
    #                     non-blank "post_deploy_cmd").
    # `qa_environments` — config/qa_environments.yml's "qa_environments" map
    #                     (qa-server key → { "heroku_app", "production_app", … }).
    # `target`          — :qa (run on the QA heroku app) or :prod (run on prod).
    #
    # Returns one entry per DISTINCT PIECE OF WORK, in plan (producer-first) order.
    # A blank/whitespace-only command is skipped, as is the literal "none" — the
    # no-op sentinel the dor-check gate hands authors of schema-only migrations (so
    # the sentinel honored on the gate side is honored end-to-end here, not run as
    # `heroku run none`). Members declaring the same work on the same app FOLD into
    # one entry (see #dedupe).
    #   { "task" => slug, "tasks" => [slug, ...], "repo" => repo,
    #     "app" => heroku-app, "cmd" => command }
    # "task" is the first (producer-first) member and stays for callers that want a
    # single label; "tasks" is every member the entry runs on behalf of, so the CLI
    # can stamp the [post-deploy] check on ALL of them and a folded member never
    # silently loses its record. `app` is "" when the repo has no registered target
    # for `target` — the CLI treats a blank app as a hard abort (a declared command
    # with nowhere to run), so a misdeclared command never silently no-ops.
    def plan(repos, qa_environments:, target:)
      raise ArgumentError, "target must be one of #{TARGETS.inspect}, got #{target.inspect}" unless TARGETS.include?(target)

      entries = Array(repos).flat_map do |group|
        app = target_app(qa_environments, group["qa_app"], target)
        Array(group["members"]).filter_map do |member|
          cmd = member["post_deploy_cmd"].to_s.strip
          # "none" is the explicit no-op sentinel the dor-check gate hands authors
          # of schema-only migrations — honor it here too, or `bin/release` would
          # run `heroku run none` and abort the whole release on the common path.
          next if cmd.empty? || cmd.casecmp?("none")

          slug = member["slug"].to_s
          { "task" => slug, "tasks" => [slug], "repo" => group["repo"].to_s,
            "app" => app, "cmd" => cmd }
        end
      end

      dedupe(entries)
    end

    # Fold entries that do the SAME WORK on the SAME APP into one command.
    #
    # WHY: `plan` emitted one entry per MEMBER, and two members can declare one job
    # in two spellings. A real release carried block-blind-duration-readers with
    # `bin/rails tasks:backfill_testing_phases` and review-phase-lacks-ordering-guard
    # with `rake tasks:backfill_testing_phases` — one job, two `heroku run` dynos.
    # The commands are idempotent so the RESULT was right, but the redundant run
    # doubles a multi-minute deploy window and, under `--exit-code`, a dropped
    # connection on the second dyno aborts the whole release for work already done.
    #
    # The FIRST entry survives: producer-first order is load-bearing (a gem's backfill
    # must precede its consumer's), and folding must never reorder the plan. Every
    # folded member's slug rides along in "tasks" so the CLI still records the
    # [post-deploy] check on each of them.
    #
    # A blank app is deliberately NOT folded. "" is the ABSENCE of a target, not an
    # app identity, so folding on it would merge across REPOS: two unroutable
    # declarations in different repos key alike and collapse into the first one's
    # entry. bin/release's abort names a single entry["repo"], so the operator would
    # be sent to studio-engine for a command solana-studio declared. Not folding keeps
    # every misdeclaration attributed to the repo that made it.
    #
    # It does NOT save the operator a second round trip, and this comment used to
    # claim it did. `abort!` is Kernel#abort, so the release stops at the FIRST blank
    # app whether or not the rest are folded, and the next one surfaces on the next
    # run either way.
    def dedupe(entries)
      entries.each_with_object([]) do |entry, kept|
        prior = entry["app"].empty? ? nil : kept.find { |e| same_work?(e, entry) }
        prior ? prior["tasks"] |= entry["tasks"] : kept << entry
      end
    end

    def same_work?(left, right)
      left["app"] == right["app"] && work_key(left["cmd"]) == work_key(right["cmd"])
    end

    # The interchangeable ways to spell "run this rake task on the dyno". Case-folded
    # like the "none" sentinel above, because the RUNNER is a synonym, not an argument.
    RUNNER_PREFIX = %r{\A(?:bundle\s+exec\s+)?(?:\./)?(?:bin/)?(?:rails|rake)\s+}i

    # The dedupe compares WORK, not strings: drop the interchangeable runner prefix,
    # and nothing else.
    #
    # Everything AFTER the runner is compared VERBATIM — case AND whitespace — on
    # purpose. The two ways to be wrong here are not symmetric: a false SPLIT runs an
    # idempotent command twice (merely slow), while a false MERGE silently skips
    # declared work and still stamps that member's [post-deploy] check green. So the
    # bias is toward splitting.
    #
    # This used to collapse runs of whitespace before comparing, and the collapse
    # reached INSIDE quoted arguments: `runner 'B.run("a  b")'` and `runner 'B.run("a b")'`
    # keyed alike, so the second was folded away UNRUN and still stamped green — the
    # exact failure class named above, committed by the guard against it. Nothing
    # needed the collapse: RUNNER_PREFIX carries its own `\s+` and already absorbs any
    # spacing in the runner itself, so `  bundle  exec   rake   x` still folds onto
    # `rake x`. Deleting it splits only commands whose ARGUMENTS differ, which is the
    # cheap way to be wrong.
    #
    # `Shellwords.split(cmd).join(" ")` normalises argv properly but RAISES on an
    # unbalanced quote, and `plan` builds the whole release's command list — including
    # for `--dry-run`. One malformed declaration would blow up the very preview that
    # exists to surface it. Comparing verbatim cannot raise.
    def work_key(cmd)
      cmd.to_s.strip.sub(RUNNER_PREFIX, "")
    end

    # The canonical argv for running one planned entry, in ONE place so --dry-run
    # prints exactly what executes and the flags can be asserted in a test.
    #
    # `--exit-code` is the load-bearing one: without it `heroku run` returns 0 the
    # instant the dyno LAUNCHES, whatever the remote command then did, and a failing
    # post-deploy command would be recorded GREEN. `--` stops heroku parsing a
    # task-declared cmd as its own flags; Shellwords.split keeps quoted args intact.
    def heroku_argv(app:, cmd:)
      ["heroku", "run", "-a", app, "--no-tty", "--exit-code", "--", *Shellwords.split(cmd)]
    end

    # The heroku app a post-deploy command runs on for `target`, resolved from the
    # qa_environments registry by qa-server key: :qa → "heroku_app" (the QA app),
    # :prod → "production_app". "" when the key isn't registered (a gem group, or
    # an app with no QA env) — the caller aborts on a declared-but-unroutable cmd.
    def target_app(qa_environments, qa_app, target)
      env = (qa_environments || {}).fetch(qa_app.to_s, nil) || {}
      (target == :qa ? env["heroku_app"] : env["production_app"]).to_s
    end
  end
end
