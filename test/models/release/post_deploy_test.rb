require "test_helper"

# Pure decision logic for the release pipeline's post-deploy command hook. Like
# Release::ShipSequence this is IO-free — no heroku, no DB — so the {task, app,
# cmd} plan + the QA-vs-prod target resolution are unit tested here and the
# `heroku run` orchestration stays thin in bin/release.
class Release::PostDeployTest < ActiveSupport::TestCase
  PD = Release::PostDeploy

  # The qa_environments.yml shape the planner reads (qa-server key → apps). Mirrors
  # config/qa_environments.yml: each entry carries the QA heroku_app + the prod
  # production_app, the two targets a post-deploy command resolves to.
  QA_ENVS = {
    "mcritchie-studio" => { "heroku_app" => "mcritchie-studio-qa", "production_app" => "mcritchie-studio" },
    "turf-monster"     => { "heroku_app" => "turf-monster-qa", "production_app" => "turf-monster-mainnet" }
  }.freeze

  # The repo_plan as the CLI sees it (JSON-parsed → STRING keys). turf declares a
  # post_deploy_cmd; the studio member does not; the gem rides along (no qa_app).
  REPOS = [
    { "repo" => "studio-engine", "kind" => "gem", "qa_app" => nil,
      "members" => [{ "slug" => "t-gem", "post_deploy_cmd" => nil }] },
    { "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
      "members" => [{ "slug" => "t-studio", "post_deploy_cmd" => "" }] },
    { "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
      "members" => [{ "slug" => "t-turf", "post_deploy_cmd" => "rake pokemon:backfill_mascots" }] }
  ].freeze

  # --- plan: target resolution (the load-bearing prepare-vs-ship decision) ---

  test "prepare (:qa) targets the member's QA heroku app" do
    plan = PD.plan(REPOS, qa_environments: QA_ENVS, target: :qa)

    assert_equal 1, plan.size, "only the member that declares a post_deploy_cmd is planned"
    entry = plan.first
    assert_equal "t-turf", entry["task"]
    assert_equal "turf-monster", entry["repo"]
    assert_equal "turf-monster-qa", entry["app"], "prepare runs on the QA app"
    assert_equal "rake pokemon:backfill_mascots", entry["cmd"]
  end

  test "ship (:prod) targets the member's production app" do
    plan = PD.plan(REPOS, qa_environments: QA_ENVS, target: :prod)

    assert_equal 1, plan.size
    assert_equal "turf-monster-mainnet", plan.first["app"], "ship runs on the production app"
    assert_equal "rake pokemon:backfill_mascots", plan.first["cmd"]
  end

  # --- plan: which members are included ---

  test "plan skips members with a nil, blank, or whitespace-only post_deploy_cmd" do
    repos = [
      { "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
        "members" => [
          { "slug" => "a", "post_deploy_cmd" => nil },
          { "slug" => "b", "post_deploy_cmd" => "" },
          { "slug" => "c", "post_deploy_cmd" => "   " },
          { "slug" => "d" } # key absent entirely
        ] }
    ]
    assert_empty PD.plan(repos, qa_environments: QA_ENVS, target: :qa)
  end

  # The downstream half of the dor-check "none" escape hatch: the gate lets an
  # author of a schema-only migration declare post_deploy_cmd "none" to opt out,
  # so the CONSUMER must treat "none" as a no-op (skip it) exactly like blank —
  # otherwise bin/release runs `heroku run none` on QA/prod and aborts the whole
  # release on the common (schema-only) path.
  test "plan skips the literal 'none' sentinel but still plans a real command" do
    repos = [
      { "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
        "members" => [
          { "slug" => "schema-only", "post_deploy_cmd" => "none" },
          { "slug" => "needs-none-cased", "post_deploy_cmd" => "  NONE  " },
          { "slug" => "real-backfill", "post_deploy_cmd" => "rake data:backfill" }
        ] }
    ]
    plan = PD.plan(repos, qa_environments: QA_ENVS, target: :qa)

    assert_equal %w[real-backfill], plan.map { |e| e["task"] },
                 "'none' (any case/padding) is a no-op sentinel; only the real command is planned"
    assert_equal "rake data:backfill", plan.first["cmd"]
  end

  test "plan trims surrounding whitespace from the command" do
    repos = [{ "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
               "members" => [{ "slug" => "t", "post_deploy_cmd" => "  rake foo:bar  " }] }]
    assert_equal "rake foo:bar", PD.plan(repos, qa_environments: QA_ENVS, target: :qa).first["cmd"]
  end

  test "plan preserves producer-first member order across repos and within a repo" do
    repos = [
      { "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
        "members" => [{ "slug" => "hub-1", "post_deploy_cmd" => "rake one" }] },
      { "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
        "members" => [{ "slug" => "turf-1", "post_deploy_cmd" => "rake two" },
                      { "slug" => "turf-2", "post_deploy_cmd" => "rake three" }] }
    ]
    assert_equal %w[hub-1 turf-1 turf-2],
                 PD.plan(repos, qa_environments: QA_ENVS, target: :prod).map { |e| e["task"] }
  end

  # --- plan: a declared-but-unroutable command yields a blank app (CLI aborts) ---

  test "plan yields a blank app when the repo has no registered target (gem / unknown)" do
    repos = [{ "repo" => "studio-engine", "kind" => "gem", "qa_app" => nil,
               "members" => [{ "slug" => "g", "post_deploy_cmd" => "rake noop" }] }]
    entry = PD.plan(repos, qa_environments: QA_ENVS, target: :prod).first

    assert_equal "g", entry["task"]
    assert_equal "", entry["app"], "an unroutable command surfaces a blank app so the CLI aborts"
  end

  test "plan yields a blank app for an app missing from the qa_environments registry" do
    repos = [{ "repo" => "chain-ops", "kind" => "app", "qa_app" => "chain-ops",
               "members" => [{ "slug" => "c", "post_deploy_cmd" => "rake noop" }] }]
    assert_equal "", PD.plan(repos, qa_environments: QA_ENVS, target: :qa).first["app"]
  end

  # --- plan: edge cases ---

  test "plan returns [] for an empty release" do
    assert_empty PD.plan([], qa_environments: QA_ENVS, target: :qa)
    assert_empty PD.plan(nil, qa_environments: QA_ENVS, target: :prod)
  end

  test "plan rejects an unknown target rather than silently running nothing" do
    err = assert_raises(ArgumentError) { PD.plan(REPOS, qa_environments: QA_ENVS, target: :staging) }
    assert_match(/target must be one of/, err.message)
    assert_match(/staging/, err.message)
  end

  # --- target_app: the per-key QA/prod resolution ---

  test "target_app resolves :qa to heroku_app and :prod to production_app" do
    assert_equal "turf-monster-qa", PD.target_app(QA_ENVS, "turf-monster", :qa)
    assert_equal "turf-monster-mainnet", PD.target_app(QA_ENVS, "turf-monster", :prod)
  end

  test "target_app returns '' for an unregistered or nil key" do
    assert_equal "", PD.target_app(QA_ENVS, "not-registered", :qa)
    assert_equal "", PD.target_app(QA_ENVS, nil, :prod)
    assert_equal "", PD.target_app(nil, "turf-monster", :qa)
  end

  # --- plan: dedupe by the WORK, not the command string ----------------------
  #
  # THE BUG: `plan` emitted one entry per MEMBER. A real release carried
  # block-blind-duration-readers declaring `bin/rails tasks:backfill_testing_phases`
  # and review-phase-lacks-ordering-guard declaring `rake tasks:backfill_testing_phases`
  # — the SAME job, two spellings, two `heroku run` dynos. The commands are idempotent
  # so correctness held, but the redundant run doubles a multi-minute deploy window
  # and, under `--exit-code`, a dropped connection on the second dyno aborts the whole
  # release for work that was already done.

  test "plan folds the two rails/rake spellings of one job into a single command" do
    repos = [
      { "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
        "members" => [
          { "slug" => "block-blind-duration-readers", "post_deploy_cmd" => "bin/rails tasks:backfill_testing_phases" },
          { "slug" => "review-phase-lacks-ordering-guard", "post_deploy_cmd" => "rake tasks:backfill_testing_phases" }
        ] }
    ]
    plan = PD.plan(repos, qa_environments: QA_ENVS, target: :qa)

    assert_equal 1, plan.size, "one job, one dyno"
    assert_equal "bin/rails tasks:backfill_testing_phases", plan.first["cmd"],
                 "the FIRST spelling in producer-first order is the one that runs"
    assert_equal %w[block-blind-duration-readers review-phase-lacks-ordering-guard],
                 plan.first["tasks"],
                 "every folded member is carried so the CLI still stamps its [post-deploy] check"
    assert_equal "block-blind-duration-readers", plan.first["task"], "the legacy single-task key still resolves"
  end

  test "plan folds bundle-exec, ./bin and case-differing runner prefixes onto the same work" do
    spellings = ["rake data:backfill", "bundle exec rake data:backfill", "bin/rails data:backfill",
                 "./bin/rake  data:backfill", "RAKE data:backfill", "  rails   data:backfill  "]
    repos = [{ "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
               "members" => spellings.each_with_index.map { |c, i| { "slug" => "m#{i}", "post_deploy_cmd" => c } } }]
    plan = PD.plan(repos, qa_environments: QA_ENVS, target: :qa)

    assert_equal 1, plan.size, "the runner prefix is interchangeable; the TASK is the work"
    assert_equal %w[m0 m1 m2 m3 m4 m5], plan.first["tasks"]
  end

  test "plan runs the same command once PER APP, never folding across apps" do
    repos = [
      { "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
        "members" => [{ "slug" => "hub", "post_deploy_cmd" => "rake data:backfill" }] },
      { "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
        "members" => [{ "slug" => "turf", "post_deploy_cmd" => "bin/rails data:backfill" }] }
    ]
    plan = PD.plan(repos, qa_environments: QA_ENVS, target: :qa)

    assert_equal 2, plan.size, "each app needs its own run — same work, different dyno"
    assert_equal %w[mcritchie-studio-qa turf-monster-qa], plan.map { |e| e["app"] }
  end

  # The dedupe is biased toward a FALSE SPLIT (running an idempotent command twice,
  # merely slow) over a FALSE MERGE (silently skipping declared work) — which is the
  # very failure mode this task exists to close. So only the interchangeable runner
  # prefix is case-folded; a command's arguments can be case-significant.
  test "plan does NOT fold two commands that differ after the runner prefix" do
    repos = [{ "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
               "members" => [
                 { "slug" => "a", "post_deploy_cmd" => "bin/rails runner 'Backfill.run(\"Alpha\")'" },
                 { "slug" => "b", "post_deploy_cmd" => "bin/rails runner 'Backfill.run(\"alpha\")'" },
                 { "slug" => "c", "post_deploy_cmd" => "rake data:other" }
               ] }]
    plan = PD.plan(repos, qa_environments: QA_ENVS, target: :qa)

    assert_equal 3, plan.size, "case-differing arguments are DIFFERENT work — never fold them away"
  end

  # The same regression one layer up: two MEMBERS whose commands differ only inside a
  # quoted argument must plan as two dynos. Folded, the second never runs and still
  # collects a green [post-deploy] check.
  test "[unit] plan does NOT fold two members differing only inside a quoted argument" do
    repos = [{ "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
               "members" => [
                 { "slug" => "wide", "post_deploy_cmd" => %q{bin/rails runner 'Backfill.run("a  b")'} },
                 { "slug" => "narrow", "post_deploy_cmd" => %q{bin/rails runner 'Backfill.run("a b")'} }
               ] }]
    plan = PD.plan(repos, qa_environments: QA_ENVS, target: :qa)

    assert_equal 2, plan.size, "different argv is different work — each declaration gets its own dyno"
    assert_equal [%w[wide], %w[narrow]], plan.map { |e| e["tasks"] },
                 "neither member may ride along on the other's run"
    refute_equal(*plan.map { |e| Shellwords.split(e["cmd"]) })
  end

  test "plan keeps each unroutable declaration visible instead of folding them" do
    repos = [{ "repo" => "studio-engine", "kind" => "gem", "qa_app" => nil,
               "members" => [{ "slug" => "g1", "post_deploy_cmd" => "rake noop" },
                             { "slug" => "g2", "post_deploy_cmd" => "bin/rails noop" }] }]
    plan = PD.plan(repos, qa_environments: QA_ENVS, target: :prod)

    assert_equal %w[g1 g2], plan.map { |e| e["task"] },
                 "a blank app is a hard abort — every misdeclaration must reach the operator by name"
  end

  test "every planned entry carries a tasks list, folded or not" do
    plan = PD.plan(REPOS, qa_environments: QA_ENVS, target: :qa)

    assert_equal [%w[t-turf]], plan.map { |e| e["tasks"] }
  end

  # --- work_key: the normalisation the dedupe compares on --------------------

  test "[unit] work_key strips the interchangeable rails/rake runner, spacing and all" do
    key = PD.work_key("rake tasks:backfill_testing_phases")

    assert_equal key, PD.work_key("bin/rails tasks:backfill_testing_phases")
    assert_equal key, PD.work_key("  bundle  exec   rake   tasks:backfill_testing_phases  ")
    assert_equal "tasks:backfill_testing_phases", key,
                 "RUNNER_PREFIX carries its own \\s+, so the runner's own spacing needs no separate collapse"
  end

  # THE REGRESSION. work_key used to `gsub(/\s+/, " ")` before comparing, and that
  # collapse reached INSIDE quoted arguments — so these two, whose argv genuinely
  # differ, keyed alike. The second was folded away UNRUN and still had its
  # [post-deploy] check stamped green: a false MERGE committed by the guard whose
  # whole purpose is preventing one.
  test "[unit] work_key does NOT fold commands differing only inside a quoted argument" do
    two_spaces = %q{bin/rails runner 'Backfill.run("a  b")'}
    one_space  = %q{bin/rails runner 'Backfill.run("a b")'}

    refute_equal Shellwords.split(two_spaces), Shellwords.split(one_space),
                 "the premise: these are different argv, so they are different work"
    refute_equal PD.work_key(two_spaces), PD.work_key(one_space),
                 "argument whitespace is significant — folding these skips declared work silently"
  end

  test "[unit] work_key leaves a non-rails command byte-for-byte alone" do
    assert_equal "./script/warm_cache  --all", PD.work_key("./script/warm_cache  --all"),
                 "nothing but the runner prefix is normalised away"
    refute_equal PD.work_key("rake a"), PD.work_key("rake b")
  end

  # An unbalanced quote must not be able to raise out of `plan` — `--dry-run` builds
  # the same plan, and the preview that exists to surface a malformed declaration
  # must print it rather than blow up on it. (Shellwords.split raises here.)
  test "[unit] work_key survives an unbalanced quote instead of raising" do
    malformed = %q{bin/rails runner 'Backfill.run("a b)}

    assert_raises(ArgumentError) { Shellwords.split(malformed) }
    assert_equal %q{runner 'Backfill.run("a b)}, PD.work_key(malformed)
  end

  # --- heroku_argv: the flag that makes a failing command turn the hook RED ---

  test "heroku_argv passes --exit-code so a failing command propagates its status" do
    argv = PD.heroku_argv(app: "mcritchie-studio-qa", cmd: "bin/rails tasks:backfill_testing_phases")

    assert_equal ["heroku", "run", "-a", "mcritchie-studio-qa", "--no-tty", "--exit-code", "--",
                  "bin/rails", "tasks:backfill_testing_phases"], argv
    assert_includes argv, "--exit-code",
                    "without it `heroku run` returns 0 the instant the dyno LAUNCHES, whatever " \
                    "the command did — and a failing backfill would record GREEN"
  end

  test "heroku_argv terminates flag parsing and keeps quoted args intact" do
    argv = PD.heroku_argv(app: "app", cmd: %(bin/rails runner "puts 'a b'"))

    assert_equal "--", argv[argv.index("--")], "`--` stops heroku reparsing a declared cmd as its own flags"
    assert_equal ["bin/rails", "runner", "puts 'a b'"], argv[(argv.index("--") + 1)..]
  end
end
