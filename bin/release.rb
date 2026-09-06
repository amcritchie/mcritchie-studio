#!/usr/bin/env ruby
# frozen_string_literal: true

# bin/release — deterministic Deploy-workflow CLI for the McRitchie Studio
# release pipeline. Encodes what used to be hand-run `heroku run rails runner`
# one-liners + ad-hoc git, so the "Prepare release" and "Run Deployment" kickoff
# commands run the same way no matter who (or which agent) runs them.
#
# The record lifecycle lives in the tested Release::Conductor; this CLI owns the
# git + deploy mechanics around it and stops for human judgment on a merge
# conflict (it never auto-resolves).
#
# The integration branch is PERSISTENT: every repo keeps a single `release`
# branch that feature PRs merge INTO. The souls split the pipeline (2026-07-22):
# Carl reviews (review-only, stops at `reviewed`, merges to `accepted`); AVI owns
# the whole middle — his self-healing `prepare` SWEEPS the reviewed queue (+ any
# assembled stragglers) onto the candidate, merges their PRs into `release`,
# deploys QA, and flips members `reviewed → assembled` ONLY on QA-green; STEFFON
# ships. The task's `merged` column ("release"/"main"/nil) is the git-location
# crash-recovery signal: an interrupted Avi run skips re-merging a `merged:
# release` task; an interrupted Steffon run skips re-ff'ing a `merged: main` one.
#
# Usage:
#   bin/release init [--dry-run]
#     One-time (idempotent) per repo: create the persistent `release` branch from
#     `origin/main` in every gem + app repo that doesn't already have one.
#
#   bin/release merge <task-slug> [<task-slug> ...] [--override] [--prod] [--dry-run]
#     The SWEEP primitive (prepare runs this same sweep for the whole queue).
#     ACCEPTED-LADDER SEMANTIC NARROWING: review already merged each feat PR into
#     `accepted`, so `merge <slug>` no longer touches the named task's feat PR — it
#     PROMOTES all of `accepted` onto `release` (ONE batch PR per repo,
#     promote_accepted_to_release!) and records the NAMED slugs' membership in a
#     SINGLE `heroku run` (membership + merged:"release"; the STAGE stays `reviewed`
#     — it flips to `assembled` only on prepare's QA-green). It therefore lands
#     EVERY reviewed change on `accepted`, not just the named one — use it to force
#     a specific reviewed task onto the RC ahead of the sweep. A named task with no
#     code on `accepted` (merged:"") ABORTS (review must land its PR first); a task
#     already `merged: release/main` skips the promote (crash recovery) but still
#     records. Promote is idempotent + fail-closed (accepted level with release →
#     skip the PR, still record).
#     REVIEW-GATE GUARD: before the promote, every requested task must be sweepable
#     (`reviewed`, or an `assembled` straggler) — anything else ABORTS the whole run
#     (naming which task is in which stage). `--override` is the explicit escape
#     hatch: it sweeps the task anyway AND records a `review_bypassed` event on the
#     task's audit spine (the same spine `bin/task move` writes) — never silent.
#
#   bin/release prepare [--task SLUG ...] [--slug rel-YYYY-MM-DD-name] [--prod] [--dry-run]
#     Avi's SELF-HEALING qa-deploy — the whole middle of the pipeline:
#       1. DETECT the work: every `reviewed` task + any `assembled` straggler not
#          riding the current RC (nothing + no active release → idempotent no-op).
#       2. Ensure a candidate exists (Release.current_or_open!).
#       3. PROMOTE + RECORD: review already merged each feat PR into `accepted`, so
#          the sweep PROMOTES all of `accepted` onto `release` via ONE batch PR per
#          repo (promote_accepted_to_release!; a `reviewed` member with no code on
#          `accepted` is a HELD anomaly, warned + left behind), then records
#          membership + merged:"release" in ONE `heroku run`. Stages stay `reviewed`.
#       4c. MERGE-FORWARD: make origin/release CONTAIN origin/main in every app
#          AND gem repo (a hotfix pushed straight to main must never be reverted
#          by the release). Merged in a detached workspace, never the primary,
#          BEFORE the gate — so the SHA the gate certifies is the SHA that
#          deploys — and BEFORE the gem publish, so gems publish the post-merge
#          tree. Aborts loudly on a conflict or a push that did not take.
#       4d. GEM MEMBERS (publish-gems-before-qa) — two phases, because a RubyGems
#          push is irreversible: preflight EVERY swept gem (fail-closed fetch,
#          version bumped, stranded-work guard, a swept consumer declares it;
#          ANY failure aborts with ZERO gems published), THEN publish each to
#          RubyGems + commit each consumer's lock bump onto origin/release —
#          BEFORE the gate and QA (ship's publish stays the idempotent verify).
#       5. PRE-QA GATE: run each app's registry `qa_test_cmd` (the integration +
#          e2e-smoke tier) on origin/release BEFORE deploying; a regression aborts
#          with eject guidance (`bin/release eject` the offender, keep the rest).
#       6. Deploy origin/release to QA (qa-server deploy → wait-for-boot /up
#          smoke → post_deploy hooks).
#       7. QA-GREEN → flip the swept members `reviewed → assembled`
#          (Release::Conductor.qa_green!; merged stays "release") + assemble the
#          RC. A QA failure leaves them `reviewed` — the next run self-heals.
#     `--task` narrows the sweep to the named slugs (operator curation).
#
#   bin/release eject <task-slug> [--feedback "…"] [--prod] [--dry-run]
#     BLOCK-ON-REGRESSION: pull ONE offending task off the candidate (the pre-QA
#     gate caught it) — detaches it (release_slug + merged cleared) and blocks it
#     for rework with the feedback note, leaving the REST of the RC riding. Then
#     revert its merge commit on `release` (printed guidance) and re-run
#     `bin/release prepare`.
#
#   bin/release ship [--by NAME] [--prod] [--dry-run]
#     Steffon's production-deploy: promotes the QA-green (assembled) RC to production:
#     ff main → release branch per repo, push origin (stamping each repo's members
#     `merged: "main"` — assembled+main = prod-in-flight), deploy to Heroku, smoke
#     /up, run any member's post_deploy_cmd on the PROD app (aborts on non-zero),
#     stamp deployed_sha + flip to shipped (shipped+main = done).
#
#   bin/release archive [--prod] [--dry-run] [--yes]
#     The DevOps loop's CONCLUSION (shipped → archived): archive every shipped
#     task that ISN'T a member of the last shipped release (those members stay
#     `shipped` as the board's read-only "Last Release"), then reclaim the
#     merged/shipped feature worktrees. Idempotent — a re-run archives nothing
#     new and reclaims nothing left. --dry-run previews the archivable plan + the
#     worktree-reclaim list (the reclaim tool's own dry-run), mutating nothing.
#
#   bin/release retro [release-slug] [--worked "…"] [--friction "…"] [--followup "…"]
#                     [--file-tasks] [--yes] [--dry-run]
#     The post-ship "review & learn" step — completely NON-BLOCKING (archive does
#     not depend on it). Defaults to the current/most-recently-shipped release.
#     AUTO-GATHERS the release record (members + kinds, per-member submitted→shipped
#     cycle timing from TaskEvents, rework rounds, reviewers, recorded checks_run)
#     and PROMPTS a few judgment questions (what worked / what caused friction /
#     follow-ups). --worked/--friction/--followup (repeatable) supply answers from
#     args; --yes runs fully non-interactive (no TTY). WRITES a durable doc at
#     docs/agents/audits/retro-<slug>.md. Follow-ups file into the TRIAGE INBOX
#     by default (`bin/triage file`, promoted to tasks only by the operator on
#     /triage); --file-tasks opens board tasks directly instead (explicit opt-in).
#     Writes NO agent-memory store — the doc (+ findings) is the record.
#     --dry-run previews the gathered record + doc path, writing nothing.
#
# Targets:
#   default        record ops run on PRODUCTION via `heroku run rails runner`
#                  (the board IS production). On a non-dry run `prepare` also fires
#                  a REAL `bin/qa-server deploy` and `ship` a REAL prod deploy —
#                  use --dry-run to preview safely.
#   --local        the OLD behavior: record ops run against the local db. That db
#                  is stale, so the board won't reflect production — dev/testing
#                  only.
#   --prod         accepted but a no-op (production is now the default).
#   --dry-run      print the plan; execute nothing
#
# The board is production, so record ops default to production. Git push to
# `heroku` always deploys prod (that IS the deploy), so `ship` asks to confirm
# first.

require "json"
require_relative "../app/models/release/gem_version"
require "base64"
require "open3"
require "yaml"
require "tmpdir"
require "shellwords"
require "fileutils" # primary_checkout_lock_path mkdir_p's the fixed lock dir

# Pure release DECISION logic (adapter dispatch, hub-first ordering, gem
# publish/repin) lives in the unit-tested Release::ShipSequence +
# Release::GemfileRepin models so this CLI stays I/O-only. Both files are
# dependency-free Ruby (no Rails), so they load standalone here — keeping the
# string/version/ordering decisions in one tested place instead of mirrored in
# the shell. GemfileRepin first: ShipSequence references it at call time.
# Release::Cli holds the pure ARGV-parsing helpers (also Rails-free) the flag
# handling below routes through.
require_relative "../app/models/release/ladder"
require_relative "../app/models/release/accepted_certification"
require_relative "../app/models/release/gemfile_repin"
require_relative "../app/models/release/ship_sequence"
require_relative "../app/models/release/engine_migration_install"
require_relative "../app/models/release/post_deploy"
require_relative "../app/models/release/merge_plan"
# SweepPlan is the pure per-task sweep partition (record onto the RC / held anomaly)
# behind prepare's self-healing sweep + merge, plus the batch-PR base assertion.
# Rails-free.
require_relative "../app/models/release/sweep_plan"
require_relative "../app/models/release/artifact_commit"
require_relative "../app/models/release/cli"
# CleanCheck is the pure verdict behind the `deploy-with-task` clean-LADDER GUARD
# (`bin/release status --clean-only`): given BOTH rungs the expedite walks — work
# riding `release` (board + release-ahead-of-main git count) and work parked on
# `accepted` (board + accepted-ahead-of-release git count) — it decides clean vs
# dirty and builds the refusal + `full-cycle` offer. Rails-free → unit-tested.
require_relative "../app/models/release/clean_check"
require_relative "../app/models/release/gh_failure"
# StaleTreeCheck is the pure verdict behind prepare's STALE-TREE GATE (step 3b):
# AFTER the accepted→release promote it asserts that every three-rung repo in the
# candidate's deploy plan has `release` carrying `accepted`, and builds the
# refusal + the filled-in recovery when one does not. It reuses CleanCheck's rung
# comparison (so the two guards can never disagree about "which repos are ahead"),
# so it loads AFTER it. Rails-free → unit-tested.
require_relative "../app/models/release/merge_subject"
require_relative "../app/models/release/stale_tree_check"
# SmokeSeal builds the post-ship 🟢/🔴 verdict + the EXACT rollback guidance the
# red-seal alert prints (step 5c). Rails-free, so the alert comes from the SAME
# source the notes/board read on prod.
require_relative "../app/models/release/smoke_seal"
# ProdSmoke resolves the prod base URL for the seal smoke (bin/prod-smoke shares it).
require_relative "../app/models/release/prod_smoke"
# SealRetry is the seal's ONE caller-side boot-window retry (step 5c): first
# failure waits ~30s, retries once; only a persisting failure seals red.
# Caller-side so bin/prod-smoke stays single-shot. Rails-free → unit-tested.
require_relative "../app/models/release/seal_retry"
# SealRun composes that retry with SmokeSeal into the recorded verdict (+ the
# summary's retry note), so step 5c's behavior is testable on real objects.
require_relative "../app/models/release/seal_run"
# GateRuby pins the LOCAL pre-QA / ship test gates to CI's ruby (mise 3.3.11) so a
# gate host whose shell `ruby` is brew's ruby@3.3 doesn't diverge from CI — the
# gate suite (and the bin/release / bin/dor-check subprocesses its meta-tests
# spawn) runs with mise's ruby bin dir leading PATH, so `env ruby` == CI's ruby.
# Rails-free → unit + integration tested.
require_relative "../app/models/release/gate_ruby"
require_relative "../app/models/release/gate_env"
require_relative "../app/models/release/gate_workspace"
# Deploy-side usage capture: read the conductor's LOCAL session transcript and
# diff it against the per-(session, slug) baseline (shared verbatim with bin/task
# + bin/reviewer-select) so reviewed→assembled / assembled→shipped flips carry
# the model/token/cost the agent actually burned. Plain Ruby (no Rails).
require_relative "../lib/agent_session_usage"
require_relative "../lib/task_usage_baseline"
require_relative "../lib/task_usage_sandbox"
require_relative "lib/session_identity"
# The regenerable-artifact sweep's summary contract — `archive` drives
# bin/clean-artifacts as a step and parses its tagged JSON line for the Exit Seam.
require_relative "lib/artifact_sweep"
# The frozen-doc retirement's summary contract — `archive` drives
# bin/archive-docs as a step and parses its tagged JSON line for the Exit Seam.
# Also its FAILURE contract (DocsArchive.failure_report): the sweep's non-zero exit
# is one bit with four causes, so the beat reports what actually failed instead of
# reading a ledger loss out of it.
require_relative "lib/docs_archive"
# The delete-later ledger's MOVE-NEVER-DELETE invariant. `archive` measures it ITSELF
# when the doc sweep fails, so a ledger-loss claim is backed by a row count rather
# than by the sub-command's exit code. See ledger_verdict.
require_relative "lib/ledger_guard"
# Repo NAME → checkout DIRECTORY. The registry's hyphenated name is not always the
# directory on disk: studio-engine's consumer-ci checks each consumer out at its
# UNDERSCORED matrix label, so `repo_path` looks for the checkout instead of
# assuming its name. See bin/lib/repo_checkout.rb.
require_relative "lib/repo_checkout"
# The per-RELEASE conductor claim (release-conductor-claims) — the assembler
# (prepare) and deployer (ship) locks, on the release record now, spoken over the
# fast HTTP AgentApi. Loaded for its exit-code constants (STOOD_DOWN/OK); the CLI's
# own `$PROGRAM_NAME == __FILE__` guard keeps a plain `require` from dispatching.
require_relative "lib/release_claim_cli"
# The shared lease math (ClaimLease) — only the TTL constant, for the stand-down copy.
require_relative "../lib/claim_lease"
# GitHub CI's verdict for a COMMIT — the same source bin/dor-check reads for a PR,
# asked about the release-tip SHA the pre-QA/ship gate certifies (CiStatus.for_sha).
# Since DevOps v2 Phase 3 CI IS the G3/G4 verdict (ci_pass?), not a cross-check.
require_relative "lib/ci_status"
# The SHARED argument guard (bin/lib/cli_arg_guard.rb) — help from ANY position
# exits without acting, and an argument no subcommand accounts for REFUSES rather
# than being silently dropped into a promote. The dictionary it reads lives in
# Release::Cli::COMMANDS, beside the parsers that consume those same flags.
require_relative "lib/cli_arg_guard"
# The LOCAL presence claim a sweep/ship publishes beside the board claim it already
# takes. The board claim answers "is a release live" REMOTELY; this answers "is this
# machine saturated" LOCALLY, and only the second decides whether a peer may launch a
# suite. Slice 4 of docs/agents/system/agent-presence.md.
require_relative "lib/release_presence"

APP = "mcritchie-studio"
HEROKU_REMOTE = "heroku"

# The self-narration CLI this deploy lane opens+closes role activities through.
# Same bin the session narrates with — which the capture hook drops from raw
# actions, so only the resulting activity shows on the heartbeat.
AGENT_ACTIVITY = File.expand_path("agent-activity", __dir__)

# The persistent per-repo integration branch (same name in every repo). Mirrors
# Release::BRANCH on the record side — feature PRs merge into it, QA deploys from
# it, ship fast-forwards it into main.
RELEASE_BRANCH = "release"

# The accepted-ladder's first rung (same name in every repo). Review MERGES each
# feat PR into `accepted` and stamps merged:"accepted"; the sweep then promotes ALL
# of `accepted` onto `release` via ONE batch PR per repo (promote_accepted_to_release!
# uses this as the `--head`). KEPT — the batch PR's head needs the branch name.
# (Phase 3 Slice 4 retired the release→accepted base-retarget stopgap that used to
# live here; Phase 4 deleted its last remnant.)
ACCEPTED_BRANCH = "accepted"
# How far back down accepted's history to look for a shipped tree when explaining a
# refused advance (tree_absorbed_by_accepted?). The absorbed commit sits a few merges
# back on a live ladder; the bound keeps the read cheap on a deep repo.
ACCEPTED_TREE_SCAN = 200

# The pause between per-task board flips in a BATCH (ship's member flips, archive's
# task-by-task sweep). Purely an operator-facing cadence: each flip is its own commit
# and its own /deployments broadcast, so this is the interval at which a watching
# operator sees the cards move, one after another, down the column. Half a second
# reads as a flow; the batch used to land as a single frame's worth of vanishing cards.
#
# It MIRRORS Release::BOARD_FLIP_CADENCE rather than reading it: the value is
# interpolated into a payload that runs on the DEPLOYED code (heroku run), and a live
# prod that predates the constant would NameError on the ship it is running.
BOARD_FLIP_CADENCE = 0.8

# The producer/consumer repo registry (config/release_repos.yml) — tells the CLI
# which members are gems (published producer-first, no app branch) vs apps. Same
# single source of truth Release::Repos reads on the record side.
# The gem CI map, shared with GithubWorkflowRun::GEM_CI_WORKFLOWS — see
# lib/gem_ci_workflows.rb for why the list lives there rather than on the model.
require_relative "../lib/gem_ci_workflows"

RELEASE_REPOS =
  begin
    YAML.load_file(File.expand_path("../config/release_repos.yml", __dir__)) || {}
  rescue StandardError
    {}
  end

# Every ecosystem repo — gems, apps, AND this hub — is checked out as a SIBLING
# at the projects root. Its DIRECTORY NAME, however, is not guaranteed to be its
# registry name (see repo_path below): studio-engine's consumer lane checks each
# consumer out under the underscored matrix label. `repo_path` resolves that sibling
# path .worktrees-aware, so paths resolve whether bin/release runs from a primary
# checkout (…/projects/mcritchie-studio/bin) or (defensively) a worktree
# (…/projects/mcritchie-studio/.worktrees/<wt>/bin). Mirrors bin/qa-server's
# default_projects_dir, which climbs out of .worktrees to the real projects root.
#
# `projects_root` is pure given its app_root argument (so it's unit-testable for
# both checkout shapes); it defaults to this script's own app root. A PROJECTS_DIR
# env override wins (mirrors bin/qa-server) so a non-default checkout layout can
# point the sibling-repo resolution at the right root.
def projects_root(app_root = File.expand_path("..", __dir__))
  return File.expand_path(ENV["PROJECTS_DIR"]) if ENV["PROJECTS_DIR"].to_s != ""

  parent = File.expand_path("..", app_root)
  # A worktree's app root sits under <hub>/.worktrees/<wt>; climb out of
  # .worktrees/<wt> back to the real projects root that holds the siblings.
  return File.expand_path("../..", parent) if File.basename(parent) == ".worktrees"

  parent
end

# The sibling CHECKOUT PATH for any ecosystem repo (a gem, an app, or the hub).
#
# It RESOLVES the directory rather than naming it. `File.join(projects_root, repo)`
# was right for every layout the operator's machine has, and wrong for the one CI
# uses: studio-engine's consumer-ci checks each consumer out at
# `path: ${{ matrix.consumer }}` — the UNDERSCORED label (`mcritchie_studio`) — so
# the hyphenated registry name pointed at nothing, `bin/archive-docs --repo=` was
# handed the miss, and `git -C` raised DocsArchive::CommandFailed. RepoCheckout
# tries the canonical spelling FIRST and falls back to the canonical name when no
# spelling is on disk, so both the projects-root layout and a genuinely absent
# sibling behave exactly as before.
def repo_path(repo)
  RepoCheckout.resolve(projects_root, repo)
end

# Every registered ecosystem repo — gems AND apps — from the release registry.
# The set `init` seeds the persistent `release` branch in.
def release_repo_slugs
  Release::Ladder.sweepable(RELEASE_REPOS)
end

# A gem's declared version, read locally from its version_file. The authoritative
# read at publish time (member_plan's version can be nil when run via `--prod`,
# where the sibling repo isn't checked out). Returns "" if it can't be resolved.
def gem_version_local(repo)
  meta = RELEASE_REPOS.dig("gems", repo) || {}
  version_file = meta["version_file"].to_s
  return "" if version_file.empty?

  path = File.join(repo_path(repo), version_file)
  return "" unless File.exist?(path)

  File.read(path)[/version\s*=\s*["']([\w.\-]+)["']/i, 1].to_s
end

# URLs come from the QA registry (config/qa_environments.yml) — single source of
# truth, so the CLI doesn't drift from the deploy config. Load the FULL map so
# the per-repo prepare loop can report each app's QA review URL (keyed by the
# qa-server app), not just the hub's.
QA_ENVIRONMENTS =
  begin
    YAML.load_file(File.expand_path("../config/qa_environments.yml", __dir__))
        .fetch("qa_environments", {})
  rescue StandardError
    {}
  end
QA_REGISTRY = QA_ENVIRONMENTS[APP] || {}
PROD_URL = QA_REGISTRY["production_url"] || "https://mcritchie.studio"

# The QA review URL for a qa-server app key (the group's `qa_app`). "" when the
# app isn't registered — the summary just omits a link and falls back to the key.
def qa_url_for(app)
  (QA_ENVIRONMENTS[app] || {})["qa_url"].to_s
end

# Whether an app is registered in config/qa_environments.yml — i.e. has a QA
# target to deploy to. A repo can be a registered app in release_repos.yml yet
# have NO QA env (tax-studio, chain-ops); prepare warns + skips its QA deploy
# rather than aborting the whole release. (validate_members! already aborts on a
# fully-unknown repo; this is the softer "registered app, no QA env" case.)
def qa_registered?(app)
  QA_ENVIRONMENTS.key?(app.to_s)
end

DRY = Release::Cli.take_flag(ARGV, "--dry-run")
# Production is the DEFAULT target now (the board IS production) — pass --local to
# opt into the old, stale-local-db behavior. `--prod` is still consumed so the old
# flag stays a harmless no-op.
Release::Cli.take_flag(ARGV, "--prod")
PROD = !Release::Cli.take_flag(ARGV, "--local")
ASSUME_YES = Release::Cli.take_flag(ARGV, "--yes")
# The FIRST-CLASS override for a ship test gate the operator believes is a false
# negative. It replaces the old registry-blanking trick, which silently DISARMED
# the gate; this one demands `--reason`, confirms, and records a RED gate SOP. See
# test_gate.
SKIP_TEST_GATE = Release::Cli.take_flag(ARGV, "--skip-test-gate")

# THE ARGUMENT GUARD — runs before the dispatcher can reach a single subcommand.
#
# Until 2026-08-31 this CLI accounted for no argument it did not recognise. The
# BARE form was safe by accident: `bin/release --help` shifts "--help", matches no
# `when`, and prints usage. But in SUBCOMMAND position the same flag vanished —
#
#     bin/release prepare --yes --help
#
# shifted "prepare", dispatched, and every parser downstream (take_flag,
# opt_value, opt_values) consumed only the flags it knew, so `--help` matched
# nothing and the REAL sweep ran: `accepted` promoted onto `release` in every
# repo, batch PRs merged, membership written to the PRODUCTION board, QA deployed
# — with ASSUME_YES set, so no prompt stood in the way. `ship` is a rung worse
# still: it pushes `main` and publishes gems, and a RubyGems version can never be
# re-pushed.
#
# The same defect class cost this ecosystem four times before (PR #974, PR #980,
# bin/devops-shift, bin/archive-docs) and each fix was private, so the next script
# inherited nothing. This one is not private: it is the SHARED guard, reading the
# SHARED dictionary in Release::Cli::COMMANDS.
#
# INJECTABLE (out:/err:/exiter:) so the verdict for every subcommand can be proven
# in a unit test WITHOUT running a release. That is not a nicety — the thing under
# test is a command that promotes branches and publishes software when probed, so
# "just run it and see" is the one experiment that must never be performed.
def guard_argv!(argv = ARGV, out: $stdout, err: $stderr, exiter: nil)
  spec = Release::Cli.guard_args(argv.first)
  # Not a subcommand at all (a bare `--help`, a typo, an empty line): fall through
  # to the dispatcher's `else`, which prints usage and exits 1 exactly as before.
  return nil unless spec

  CliArgGuard.guard!(argv.drop(1), out: out, err: err, exiter: exiter, **spec)
end

def abort!(msg) = abort("✗ #{msg}")
def say(msg) = puts(msg)

# A discrete deploy operation: printed to the release log AND — inside a role span
# (prepare/ship) — self-reported as ONE AgentAction so the Remote deploy span shows
# genuine rows. bin/release's real work runs as SUBPROCESSES of a single Bash tool
# call, invisible to the PostToolUse capture hook, so without this the span reads
# "No raw actions attributed". Gated on $role_span_open so steps OUTSIDE a span
# (status/merge reads) don't spawn a report with nothing to attribute to.
def step(msg)
  puts("→ #{msg}")
  agent_action(msg) if $role_span_open
end

# Loud banner printed at the top of prepare/ship when --local opted out of the
# production board. The local db is stale, so a release run against it won't
# reflect production — only useful for dev/testing.
def warn_local!
  return if PROD

  say("⚠ --local: record ops run against the STALE local DB — the board won't reflect production; use the default for real releases.")
end

# Run a shell command. In dry-run, print it and skip. `chdir:` runs it in
# another directory (used for gem-repo builds/tags). `env:` is an optional
# environment overlay merged into the child — the gates pass it so the spawned
# suite/bundle/probe resolve `env ruby` to mise, see NO agent session, and boot
# against the gate's private test DB (see gate_env / Release::GateEnv). A nil
# VALUE in that overlay UNSETS the key in the child (Process.spawn semantics) —
# that is how the session scrub reaches every grandchild the suite spawns. A
# blank/nil overlay leaves the argv exactly as-is. Returns [stdout, ok?].
def sh(*cmd, capture: false, chdir: nil, env: nil)
  printable = "#{chdir ? "(cd #{chdir}) " : ''}#{cmd.join(' ')}"
  if DRY
    puts "  [dry-run] #{printable}"
    return ["", true]
  end
  opts = chdir ? { chdir: chdir } : {}
  # A leading env Hash sets the child's environment WITHOUT touching argv, so a
  # command stub keying on argv[0] still matches (env lands in the trailing opts).
  argv = env && !env.empty? ? [env, *cmd] : cmd
  if capture
    out, status = Open3.capture2e(*argv, opts)
    [out, status.success?]
  else
    ok = system(*argv, opts)
    ["", ok]
  end
end

# Dispatch a GitHub Actions workflow (`gh workflow run`) and WATCH it to
# completion; returns true iff the run concluded SUCCESSFULLY. The DevOps v2
# Phase-2 deploy mechanic for the hub: prepare fires qa-deploy.yml, ship fires
# prod-deploy.yml. The `production` Environment's required-reviewer approval was
# REMOVED (2026-07-20), so a prod run now deploys straight through with no pause;
# the watch still HOLDS on any live status (see run_concluded_success?) should a
# deployment-protection gate ever be re-added. DRY short-circuits before any `gh`.
#
# FINDING THE RUN ID is the one subtlety. `gh workflow run` prints nothing that
# identifies the run it created, and `gh run list --limit 1` alone is a trap: a
# PRIOR concluded run of the same workflow (prod deploys repeat, so one usually
# exists) is the newest until ours registers, and watching THAT would read a
# stale verdict → a false-green deploy. GitHub run ids increase monotonically, so
# we snapshot the newest id BEFORE dispatch and poll (the run takes a couple
# seconds to register) until a run with a STRICTLY GREATER id appears — that run
# is unambiguously ours (Release::ShipSequence.new_run_id owns that pure choice).
#
# FAILS CLOSED on a gh that won't answer. newest_run_id returns nil on a `gh run
# list` FAILURE (distinct from 0 = "no runs exist yet"): a transient failure of
# the PRE-dispatch snapshot must NOT read as before_id=0, or the poll could latch
# a pre-existing run. So we retry the snapshot, ABORT if it never answers, and in
# the poll SKIP a nil read rather than compare it.
def dispatch_and_watch(workflow, inputs = {}, chdir: nil)
  return true if DRY

  before_id = nil
  5.times do
    before_id = newest_run_id(workflow, chdir: chdir)
    break unless before_id.nil?

    sleep 3
  end
  return false if before_id.nil? # gh never answered — do not watch a stale run

  args = ["gh", "workflow", "run", workflow]
  inputs.each { |k, v| args += ["-f", "#{k}=#{v}"] }
  _, dispatched = sh(*args, chdir: chdir)
  return false unless dispatched

  run_id = nil
  20.times do
    # nil (a transient list failure) is SKIPPED, never compared to before_id.
    run_id = Release::ShipSequence.new_run_id(before_id, newest_run_id(workflow, chdir: chdir))
    break if run_id

    sleep 3
  end
  return false unless run_id

  _, watched = sh("gh", "run", "watch", run_id.to_s, "--exit-status", chdir: chdir)
  return true if watched

  # Don't trust the WATCH's exit alone. Seen LIVE (Phase 2 validation, run
  # 29440752482): a transient GitHub HTTP 500 killed `gh run watch` mid-watch while
  # the run itself SUCCEEDED (prod deployed, /up 200). Returning the watch's exit
  # would then ABORT a ship that actually shipped — an operator-facing false
  # negative. So a failed watch is not a verdict: re-query the run's REAL
  # conclusion and let THAT decide (fails closed if the run genuinely failed or
  # becomes unobservable).
  say("  ⚠ `gh run watch` exited non-zero for run #{run_id} — re-querying the run's real conclusion (a transient watcher failure is not a failed deploy)")
  run_concluded_success?(run_id, chdir: chdir)
end

# The run's REAL conclusion, straight from GitHub, for when `gh run watch` could
# not report it (a transient watcher failure — an HTTP 500 mid-watch — must never
# be read as a failed deploy). MIRRORS `gh run watch`: it FOLLOWS the run to its
# GitHub-side conclusion, however long that takes, on `gh run view --json
# status,conclusion`, and lets Release::ShipSequence.run_watch_verdict decide each
# read (:success / :failed / :pending — pure, unit-tested).
#
# WHY IT IS NOT A SHORT WALL-CLOCK BUDGET (the bug this closes, run 29450907913):
# a prod-deploy run can sit in a LIVE non-terminal status — `waiting` (a
# deployment-protection gate), `queued`, or `in_progress` — far longer than a short
# poll budget. (Historically the `production` Environment's required reviewer held a
# run `waiting` for as long as the operator took to click — 3h34m live — before that
# approval was removed on 2026-07-20.) The old fallback polled only 20×5s=100s for
# `completed` and failed the ship CLOSED over a run that was simply still live.
# Reading any live status is affirmative proof the run is alive, so the watcher
# HOLDS on it (unbounded, exactly as `gh run watch` would; GitHub's own job timeout
# concludes a truly hung run).
#
# FAILS CLOSED on exactly two things — a redundant re-verify beats a false green:
#   * a TERMINAL non-success (:failed) → promptly, over one poll.
#   * an UNOBSERVABLE run — `gh run view` erroring or returning no status for
#     `unreadable_limit` CONSECUTIVE polls (a genuine stuck-timeout with no state
#     progress: the "never-appearing" run). A single successful live read resets
#     the streak, so an approval pause of any length never trips it.
def run_concluded_success?(run_id, chdir: nil, poll: 10, unreadable_limit: 30)
  # A CONDUCTOR PARKED ON A GITHUB ACTIONS POLL CONSUMES NOTHING. That distinction is
  # cost #4 of docs/agents/system/agent-presence.md — two idle `bin/ship` processes in a
  # CI wait read as competing certs and nearly held off a launch — and `phase: waiting` is
  # the field the reader already honours for it (weight 0). The claim stays COUNTED, so
  # this sweep's process group is still ATTRIBUTED rather than falling back into the
  # reader's `backstop`; it simply costs a peer nothing while it sleeps.
  ReleasePresence.with_phase(phase: ReleasePresence::PHASE_WAITING,
                             weight: ReleasePresence::WEIGHT_IDLE) do
    poll_until_concluded(run_id, chdir: chdir, poll: poll, unreadable_limit: unreadable_limit)
  end
end

# The poll itself, extracted so the presence transition above wraps ONE call rather than
# re-indenting this loop around a block. `return` inside the block returns from
# `run_concluded_success?` either way, so the verdict semantics are unchanged.
def poll_until_concluded(run_id, chdir:, poll:, unreadable_limit:)
  unreadable = 0
  last_status = nil
  loop do
    out, ok = sh("gh", "run", "view", run_id.to_s, "--json", "status,conclusion",
                 "--jq", "[.status, .conclusion] | @tsv", chdir: chdir, capture: true)
    status, conclusion = ok ? out.strip.split("\t", 2) : [nil, nil]

    # A read we could not make (gh errored) OR that returned no status is an
    # UNOBSERVED poll — it counts toward the stuck-timeout, never toward a verdict.
    if status.to_s.strip.empty?
      unreadable += 1
      if unreadable >= unreadable_limit
        say("  ⚠ run #{run_id} unobservable for #{unreadable} consecutive polls — failing closed")
        return false
      end
      sleep poll
      next
    end
    unreadable = 0

    case Release::ShipSequence.run_watch_verdict(status, conclusion)
    when :success
      say("  run #{run_id} concluded: success")
      return true
    when :failed
      say("  run #{run_id} concluded: #{conclusion} — failing closed")
      return false
    else # :pending — the run is still live; hold, exactly as `gh run watch` would
      if status != last_status
        note = Release::ShipSequence.approval_pause?(status) ?
                 "WAITING on a deployment protection gate — holding (a protection pause is not a failure)" :
                 "#{status} — holding"
        say("  run #{run_id} #{note}")
      end
    end

    last_status = status
    sleep poll
  end
end

# The newest GitHub Actions run id for `workflow` — 0 when none exists yet, or
# nil when `gh run list` FAILED. The nil-vs-0 distinction is load-bearing (see
# dispatch_and_watch): a caller must not read a transient failure as "no runs".
# jq `// empty` yields "" on an empty list, which `to_i` maps to the genuine 0.
def newest_run_id(workflow, chdir: nil)
  out, ok = sh("gh", "run", "list", "--workflow", workflow, "--limit", "1",
               "--json", "databaseId", "--jq", ".[0].databaseId // empty",
               chdir: chdir, capture: true)
  return nil unless ok

  out.strip.to_i
end

# The SHELL-SAFE `rails runner` payload for a conductor snippet. The snippet is
# wrapped (`require 'json'`), Base64-encoded, and shipped as
# `eval(Base64.urlsafe_decode64("<blob>"))` — so the command line carries ONLY a
# url-safe Base64 literal (alphabet [A-Za-z0-9_-]=, zero shell metacharacters,
# zero nested/escaped quotes) the remote runner decodes + evals.
#
# This closes the paren/quote ship-blocker at the SHARED seam, so EVERY conductor
# caller is shell-safe: record_post_deploy_check interpolated `cmd.inspect` into
# the snippet, and a seed-54-style post_deploy_cmd
# (`bin/rails runner "load Rails.root.join(%q(...)).to_s"`) arrived as escaped
# quotes + parens. `heroku run` re-quotes its remote command, and that re-quoting
# ATE the \"-escaping — exposing the `(` as a remote `bash: syntax error near
# unexpected token '('`, which made `conductor` hit abort! ("record op returned
# no JSON") and aborted prepare BEFORE assemble! (and would abort ship after the
# prod-deploy + gem-publish). The Base64 bootstrap is structurally identical to
# the proven-safe `Base64.urlsafe_decode64("…")` literal retro_record_ruby
# already rides through `heroku run`. Pure (no Rails) → unit-tested standalone.
def conductor_payload(ruby)
  wrapper = "require 'json'; #{ruby}"
  blob = Base64.urlsafe_encode64(wrapper)
  "eval(Base64.urlsafe_decode64(#{blob.inspect}))"
end

# This conductor's local SESSION id (Claude or Codex), or nil. Used to tag the
# deployment with the agent working it — see with_conductor_session.
def conductor_session_id
  conductor_session_identity.first
end

def conductor_session_identity
  id, provider = SessionIdentity.identity
  [id, provider || "claude"]
end

# Prefix a conductor snippet with the local session id so the prod `rails runner`
# can stamp the deployment's Pokémon mascot (Release stamps the SESSION's mascot —
# the agent running bin/release). The session lives in THIS shell's env, which does
# NOT cross the `heroku run` boundary, so we pass it in-band. `Current.try(:…=)` so
# an older prod that predates the attribute ignores it instead of erroring mid-ship
# — the stamp is best-effort, never load-bearing for a release op. A session-less
# run (no env var) returns the snippet untouched. Pure → unit-tested standalone.
def with_conductor_session(ruby)
  sid = conductor_session_id
  return ruby unless sid

  "Current.try(:conductor_session_id=, #{sid.inspect}); #{ruby}"
end

# --- deploy-lane self-narration (best-effort) -------------------------------
# Open+close an AgentActivity around a release phase, stamped with the ROLE
# soul the board already attributes that phase to — Avi assembles (prepare),
# Steffon ships — so the heartbeat's deploy activities match the board's stage timeline.
# Narrated through bin/agent-activity (the SAME path the session narrates with,
# which the capture hook DROPS from raw actions, so only the resulting activity
# shows). BEST-EFFORT + NON-FATAL: telemetry must never break a release, so a
# missing bin, a down endpoint, or any error is swallowed. Skipped under
# --dry-run (a preview narrates nothing) and when no conductor session is
# resolvable (nothing to attribute the activity to).

# True while bin/release holds an OPEN role span (open_role_span … close_role_span),
# so step() knows to self-report its actions into it. Off-span steps skip the
# report — there's no span to attribute them to.
$role_span_open = false

# Fire one bin/agent-activity subcommand, best-effort. The command itself always
# exits 0; we still swallow everything and redirect its stdout/stderr so the
# narration never disturbs the release log or aborts the run.
def agent_activity(*args)
  return if DRY
  return unless conductor_session_id # no session → nothing to narrate

  system(AGENT_ACTIVITY, *args, out: File::NULL, err: File::NULL)
rescue StandardError
  nil
end

# Self-report ONE off-box action into the open role span, so the Remote deploy
# span carries real rows for work the PostToolUse hook can't see (git / gh /
# `heroku run` all run as subprocesses of ONE Bash tool call). Thin shell-out to
# the narration CLI's `action` verb — inert under --dry-run and with no conductor
# session (agent_activity guards both), and a no-op when no activity is open (the
# verb self-checks the open-activity marker).
def agent_action(summary, key_method: nil, kind: nil, event_slug: nil, result_slug: nil, duration_ms: nil)
  args = ["action", "--summary", summary.to_s]
  args += ["--key-method", key_method.to_s] if key_method
  # Verdict-only tag fields — a graded test-scope run carries them; a plain step
  # (or a START emit) passes them nil and they never reach the POST body.
  args += ["--kind", kind.to_s] if kind
  args += ["--event-slug", event_slug.to_s] if event_slug
  args += ["--result-slug", result_slug.to_s] if result_slug
  args += ["--duration-ms", duration_ms.to_s] if duration_ms
  agent_activity(*args)
end

def open_role_span(agent, reason)
  $role_span_open = true
  agent_activity("start", "--category", "Remote", "--reason", reason, "--agent", agent)
end

def close_role_span(outcome)
  agent_activity("end", "--outcome", outcome)
  $role_span_open = false
end

# --- per-RELEASE conductor claim (release-conductor-claims) -------------------
# The QA-assemble (`assembler`) and prod-deploy (`deployer`) locks live on the
# RELEASE RECORD now, not on a per-ROLE devops shift (bin/devops-shift acquire
# steffon|avi). Because the lock turns over each release, a stale/ghost claim can
# never strand a global lane again — the anti-stranding property the shift lease
# lacked. It runs through the FAST HTTP AgentApi (bin/lib/release_claim_cli.rb),
# NEVER a per-heartbeat `heroku run`: a ship holds the deployer claim for many
# minutes, so the lease is renewed by a cheap DETACHED renewer over HTTP.
#
# FAIL-OPEN posture (ClaimLease's): a telemetry hiccup (no board, no session id,
# error) NEVER wedges a real release — the run proceeds unclaimed. But a live
# DIFFERENT holder (exit 10) DOES stand us down: that is the collision the claim
# exists to prevent. A same-instance re-acquire is a no-op renew, so an interrupted
# ship re-run RESUMES its deployer claim instead of standing itself down.
RELEASE_CLAIM_CLI = File.expand_path("lib/release_claim_cli.rb", __dir__)

# Shell out to the claim CLI over the fast HTTP path and return its exit code
# (0 held, 10 stood down, else fail-open/nil), echoing its ✅/🛑 line into the
# release log. Best-effort — any error returns nil so the caller fails OPEN.
# Inert under --dry-run (a preview holds no claim).
def conductor_claim(*args)
  return nil if DRY

  out, err, status = Open3.capture3(RbConfig.ruby, RELEASE_CLAIM_CLI, *args)
  msg = [out, err].map(&:to_s).join.strip
  say(msg.gsub(/^/, "  ")) unless msg.empty?
  status&.exitstatus
rescue StandardError => e
  warn("  conductor-claim #{args.first} error (#{e.class}: #{e.message}) — proceeding without a claim (fail-open)")
  nil
end

# The claims this run currently holds — a LIST of { slug:, role: }, not a single slot,
# because a fresh-create prepare briefly holds TWO assembler claims at once: the
# `__forming__` SENTINEL (which guards the accepted→release promote before any release
# record exists) plus the real (rel_slug) claim it hands off to. Each (role, slug) is a
# distinct board row with its own detached renewer, tracked independently here.
def held_conductor_claims
  @conductor_claims ||= []
end

def holding_conductor_claim?(role, slug)
  held_conductor_claims.any? { |c| c[:role] == role && c[:slug] == slug }
end

# Take the role's claim on the release, or ABORT (stand down) if a DIFFERENT live
# instance holds it. Idempotent per (role, slug): a re-acquire of one we already hold
# this run is a no-op (so we never start a second renewer for it), and a same-instance
# re-acquire of one held by an EARLIER run of this session is a renew, never a
# stand-down (an interrupted ship/finalize resumes). A blank slug (no release identity
# resolved yet) is a fail-open skip — there is nothing to guard. On stand-down,
# `span_close` (optional) closes any open role span before aborting so the heartbeat
# activity resolves.
def acquire_conductor_claim!(role, slug, span_close: nil)
  s = slug.to_s.strip
  return if s.empty? # no release identity yet → nothing to guard (fail-open)
  return if holding_conductor_claim?(role, s) # already held this run → no second renewer

  case conductor_claim("acquire", s, "--role", role)
  when ReleaseClaimCli::STOOD_DOWN
    span_close&.call
    abort!("#{role} claim for #{s} is held by another live release conductor — standing down (see the holder " \
           "above). Its lease lapses within ~#{ClaimLease::DEFAULT_TTL_SECONDS}s of that session stopping; re-run then.")
  when ReleaseClaimCli::OK
    held_conductor_claims << { slug: s, role: role }
  end
  # any other code (nil / CANT_RUN) → fail-open: proceed unclaimed
end

# Drop conductor claims this run holds, stopping each one's detached renewer. With NO
# args it drops EVERY held claim (clean completion or an abort rescue — this is what
# frees a still-held sentinel on a mid-prepare abort). With role:/slug: it drops just
# that one — the SENTINEL HAND-OFF: once the real (rel_slug) claim is held, the forming
# sentinel is released by (role, slug) so the real claim is never touched.
# Best-effort + idempotent — nothing matching ⇒ no-op.
def release_conductor_claim!(role: nil, slug: nil)
  targets =
    if role && slug
      s = slug.to_s.strip
      held_conductor_claims.select { |c| c[:role] == role && c[:slug] == s }
    else
      held_conductor_claims.dup
    end
  targets.each do |c|
    conductor_claim("release", c[:slug], "--role", c[:role])
    held_conductor_claims.delete(c)
  end
end

# --- test-scope telemetry (best-effort) --------------------------------------
# Every test scope this CLI runs is a logged, GRADEABLE unit: run_test_scope
# emits one START and one COMPLETED/FAILED AgentAction per run through the same
# self-report path step() uses (agent_action → bin/agent-activity action). The
# scope registry (config/devops_test_suites.yml `release_scopes:`) declares each
# scope's stable key + phase/tier/host/blocks metadata. Telemetry is BEST-EFFORT
# + NON-FATAL by the step()/agent_action contract: gated on $role_span_open
# (outside a role span there is no activity to attribute to), inert under
# --dry-run and without a conductor session (agent_activity guards both), and
# any telemetry error is swallowed — only the COMMAND result is load-bearing.
#
# ReleaseEvent channel note: ReleaseEvent::STEPS whitelists step names
# (inclusion validation), so per-scope telemetry deliberately stays on the
# AgentAction channel — inventing new release-event steps would be rejected by
# the model (and pollute the /deployments tracker if whitelisted). The gates'
# existing release-event pairs (ship_gate, qa_smoke, prod_smoke, …) are
# unchanged.

# The release-scope registry: scope key → {phase, tier, host, blocks, mutates}.
# Missing file / malformed YAML degrades to {} — the registry enriches
# telemetry; it must never break the CLI.
TEST_SCOPES =
  begin
    (YAML.load_file(File.expand_path("../config/devops_test_suites.yml", __dir__)) || {})
      .fetch("release_scopes", {})
  rescue StandardError
    {}
  end

def scope_meta(key) = TEST_SCOPES[key.to_s] || {}

# Lenient result-count parsing — nil when nothing recognizable (that's fine;
# the summary just omits counts):
#   minitest    "141 runs, 320 assertions, 0 failures, 0 errors" — SUMMED across
#               summary lines (`rails test test:system` prints one per lane)
#   playwright  "12 passed" (+ "2 failed" when present)
#   /up probe   a bare 3-digit http code body ("200")
def parse_test_counts(out)
  text = out.to_s
  runs = text.scan(/(\d+) runs?, (\d+) assertions?, (\d+) failures?, (\d+) errors?/)
  if runs.any?
    sums = runs.transpose.map { |col| col.sum(&:to_i) }
    return format("%d runs, %d assertions, %d failures, %d errors", *sums)
  end
  if (passed = text[/(\d+) passed/, 1])
    failed = text[/(\d+) failed/, 1]
    return failed ? "#{passed} passed, #{failed} failed" : "#{passed} passed"
  end
  code = text.strip
  return "http #{code}" if code.match?(/\A\d{3}\z/)

  nil
end

# Emit one test-scope AgentAction, best-effort. Keeps step()'s $role_span_open
# gating; any error is swallowed (agent_action already swallows its own — this
# belt-and-suspenders covers the summary plumbing too).
def scope_action(summary, key_method: nil, kind: nil, event_slug: nil, result_slug: nil, duration_ms: nil)
  if $role_span_open
    agent_action(summary, key_method: key_method, kind: kind, event_slug: event_slug,
                 result_slug: result_slug, duration_ms: duration_ms)
  end
rescue StandardError
  nil
end

# Run ONE registered test scope: emit START, run the command via sh() with the
# call site's exact capture:/chdir: (or the given block — wait_for_boot's /up
# poll is one scope but many curls; a block must return [out, ok]), then emit
# COMPLETED/FAILED carrying {scope key, repo/host, pass|fail, counts, duration,
# command}. Returns [out, ok] exactly like sh(), so call sites keep their exact
# abort!/non-blocking behavior. A command that RAISES (Open3 ENOENT etc.) still
# emits the FAILED action, then RE-RAISES — the call site's rescue semantics
# (production_smoke_seal degrades it to a red seal) stay untouched.
#
# The VERDICT emit (COMPLETED/FAILED only — never START) is TAGGED to make the run
# a first-class GRADEABLE unit in /alex/pipeline: kind="test_scope", event_slug=the
# scope key, result_slug=pass|fail, duration_ms=the wall-clock. These ride the same
# best-effort self-report path; a bare START stays untagged so the pipeline's
# `kind:"test_scope" AND result_slug present` filter never surfaces it.
def run_test_scope(key, *cmd, capture: false, chdir: nil, repo: nil, label: nil, env: nil, &block)
  meta  = scope_meta(key)
  where = repo.to_s.empty? ? meta["host"].to_s : repo.to_s
  printable = (label || cmd.join(" ")).to_s
  scope_action("test scope #{key} START · #{where} · #{printable}")
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  begin
    # Pass `env:` to sh ONLY when the caller set an overlay (the gate ruby pin) —
    # non-gate scopes call sh with the exact original keywords, so a strict sh
    # stub (or any caller that predates env:) is untouched.
    kw = { capture: capture, chdir: chdir }
    kw[:env] = env if env && !env.empty?
    # THE WORKING PHASE, published locally for this scope's exact duration, AT THE COST
    # THE REGISTRY DECLARES. This is the choke point every conductor-run test scope
    # passes through — the G3 pre-QA gate and the ship's frozen-SHA test gate alike — so
    # one wrap covers all of them, and a scope added later is covered without anyone
    # remembering to.
    #
    # THE WEIGHT COMES FROM `meta`, NOT FROM A CONSTANT HERE. Half of these scopes do not
    # run on this machine at all: `qa_up_smoke` and `prod_up_smoke` are curl polls, and
    # `qa_post_deploy`/`prod_post_deploy` are `heroku run` — a remote dyno does the work
    # while this process holds a socket. Publishing `suite` for them told a peer the box
    # was saturated by a `curl`, which is the same class of wrong answer, in the opposite
    # direction, as the silence that made this module necessary. `scope_weight` reads
    # `host`/`tier` off the registry row so the fact lives beside the scope's other
    # metadata; see its comment for why it is not a keyword at this call site.
    out, ok = ReleasePresence.with_phase(phase: ReleasePresence::PHASE_WORKING,
                                         weight: ReleasePresence.scope_weight(meta)) do
      block ? block.call : sh(*cmd, **kw)
    end
  rescue StandardError => e
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    gate_sop(key, printable, false, (elapsed * 1000).round)
    scope_action("test scope #{key} FAILED · #{where} · fail · #{e.class}: #{e.message} · " \
                 "#{format('%.1fs', elapsed)} · #{printable}", key_method: printable,
                 kind: "test_scope", event_slug: key.to_s, result_slug: "fail",
                 duration_ms: (elapsed * 1000).round)
    raise
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  gate_sop(key, printable, ok, (elapsed * 1000).round)
  begin
    parts = ["test scope #{key} #{ok ? 'COMPLETED' : 'FAILED'}", where, ok ? "pass" : "fail"]
    counts = parse_test_counts(out)
    parts << counts if counts
    parts << format("%.1fs", elapsed)
    parts << printable
    scope_action(parts.join(" · "), key_method: printable,
                 kind: "test_scope", event_slug: key.to_s, result_slug: ok ? "pass" : "fail",
                 duration_ms: (elapsed * 1000).round)
  rescue StandardError
    nil # telemetry never breaks a release — the command result below is what matters
  end
  [out, ok]
end

# Invoke a Release::Conductor snippet — locally, or on prod via `heroku run`.
# The snippet must `puts` a single JSON line; we return the parsed Hash. The
# snippet rides as a shell-safe Base64 bootstrap (see conductor_payload) so any
# quotes/parens/&& in it survive heroku's remote re-quoting intact.
#
# WRITES are suppressed in --dry-run (printed, not run). A read_only: query still
# runs in dry-run — a read mutates nothing, so it honors "execute nothing" while
# letting a dry-run PREVIEW the real plan. read_only goes straight to Open3 so
# it bypasses sh's own dry-run gate.
def conductor(ruby, read_only: false)
  payload = conductor_payload(with_conductor_session(ruby))
  cmd = PROD ? ["heroku", "run", "-a", APP, "--no-tty", "rails", "runner", payload]
             : ["bin/rails", "runner", payload]
  if DRY && !read_only
    puts "  [dry-run] #{PROD ? 'heroku run ' : ''}rails runner: #{ruby}"
    return {}
  end
  out, status = Open3.capture2e(*cmd)
  abort!("record op failed:\n#{out}") unless status.success?
  line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
  abort!("record op returned no JSON:\n#{out}") unless line
  JSON.parse(line)
end

# Record a deploy-lane crew-ticker intent on the board — a COSMETIC write that only
# paints the live /deployments "who's on it now" badge; nothing the deploy depends on.
# So it is BEST-EFFORT: conductor() abort!s (→ SystemExit) on ANY non-zero heroku-run
# exit, and a transient prod-board outage (e.g. the documented 2026-06-25 essential-PG
# "too many connections" incidents) on this cosmetic ticker must WARN and CONTINUE —
# it must NEVER abort a real `prepare`/`ship`. Mirrors bin/reviewer-select's best-effort
# review-intent write (rescue SystemExit, StandardError → warn → continue, ~lines 325-326).
# Scoped narrowly to the intent write ONLY — every deploy-critical conductor() call stays
# FATAL, so real deploy errors still abort.
def record_deploy_intent(label, ruby)
  conductor(ruby)
rescue SystemExit, StandardError => e
  say("  ⚠ #{label} not recorded — crew-ticker board write failed (#{e.message}); deploy continues (cosmetic only)")
end

# --- release-grain gate runs (G3 Candidate / G4 Ship) -----------------------
# Attempt-aware GateRun records for the two release-owned testing gates, written
# through the model's open!/close! funnel via conductor snippets. The window is
# bracketed by record_gate_open/record_gate_close; every test SOP run inside it
# is COLLECTED by the one-line gate_sop hook in run_test_scope (zero extra
# round-trips — the sops ride the close payload). ALL gate writes are
# BEST-EFFORT: a board blip must never abort a prepare/ship (mirrors
# record_release_event), and --dry-run suppresses them via conductor's own gate
# (the plan still prints). $gate_sops is nil outside a gate window, so ordinary
# test scopes (e.g. a straggler run) collect nothing.
$gate_sops = nil

# Push one executed-SOP entry onto the open gate window (no-op outside one).
# String keys + scalar values only, so the buffer embeds .inspect-safe in the
# Base64 conductor payload. Never raises — collection must not break the run.
def gate_sop(sop, cmd, ok, duration_ms = nil)
  return unless $gate_sops

  entry = { "sop" => sop.to_s, "cmd" => cmd.to_s, "result" => ok ? "pass" : "fail" }
  entry["duration_ms"] = duration_ms.to_i if duration_ms
  $gate_sops << entry
rescue StandardError
  nil
end

# Open (or re-enter — GateRun.open! reuses the in-flight attempt) the release's
# gate attempt and start collecting SOPs. Best-effort + dry-run-suppressed.
def record_gate_open(release_slug, key, actor: nil)
  $gate_sops = []
  actor_ruby = actor.to_s.empty? ? "nil" : actor.to_s.inspect
  conductor(
    "run = GateRun.open!(subject_type: 'release', subject_slug: #{release_slug.inspect}, " \
    "key: #{key.inspect}, actor: #{actor_ruby}, source: 'conductor'); " \
    "puts({ gate: run.key, attempt: run.attempt }.to_json)"
  )
rescue SystemExit, StandardError => e
  say("  ⚠ gate #{key} not opened — board write failed (#{e.message}); deploy continues")
end

# Close the gate attempt with its verdict + the collected SOPs, and stop
# collecting. Best-effort + dry-run-suppressed: callers in a SystemExit rescue
# MUST still re-raise after this — the close never masks an abort.
def record_gate_close(release_slug, key, success, metadata: {})
  sops = $gate_sops || []
  $gate_sops = nil
  # bin/release runs Rails-FREE, so no ActiveSupport .presence here — normalize
  # the metadata by hand (a non-Hash or nil becomes {}).
  meta = metadata.is_a?(Hash) ? metadata : {}
  conductor(
    "run = GateRun.close!(subject_type: 'release', subject_slug: #{release_slug.inspect}, " \
    "key: #{key.inspect}, success: #{success ? 'true' : 'false'}, sops: #{sops.inspect}, " \
    "source: 'conductor', metadata: #{meta.inspect}); " \
    "puts({ gate: run.key, attempt: run.attempt, success: run.success }.to_json)"
  )
rescue SystemExit, StandardError => e
  say("  ⚠ gate #{key} not closed — board write failed (#{e.message}); deploy continues")
end

def record_release_event(release_slug, step_name, status, attrs = {})
  attrs = attrs.dup
  attrs[:source] ||= "conductor"
  attrs[:idempotency_key] ||= [
    release_slug, step_name, status, attrs[:repo], attrs[:app], attrs[:sha], attrs[:url]
  ].compact.join(":")

  payload = attrs.map { |key, value| "#{key}: #{value.inspect}" }.join(", ")
  conductor(
    "r = Release.find_by!(slug: #{release_slug.inspect}); " \
    "Release::Conductor.record_event!(release: r, step: #{step_name.inspect}, status: #{status.inspect}, #{payload}); " \
    "puts({ release_event: #{step_name.inspect}, status: #{status.inspect} }.to_json)"
  )
rescue SystemExit, StandardError => e
  say("  ⚠ release event #{step_name}:#{status} not recorded (#{e.message}); deploy continues")
end

# --- deploy-side usage capture (best-effort) --------------------------------
# The conductor flips task stages on PROD via `heroku run`, where there is NO
# local transcript — so we capture the per-transition usage delta HERE (locally,
# in the release conductor's own session) and thread model/tokens/cost into the
# conductor snippet, which sets Current.task_event_* before the flip so the
# resulting TaskEvent carries usage. Mirrors bin/task's autofill: diff the
# session's cumulative totals against the baseline seeded at the matching
# `bin/task intent`, then advance the baseline. Resolves the same baseline dir as
# bin/task (honors TASK_USAGE_DIR; else <projects>/.agents/task-usage).
def release_usage_dir
  pinned = ENV["TASK_USAGE_DIR"].to_s.strip
  # Same live-store fallback bin/task carries, so it takes the same fail-closed
  # sandbox guard (lib/task_usage_sandbox.rb): under TASK_USAGE_SANDBOX an
  # unpinned run aborts rather than writing the operator's real cost store. The raw
  # fallback is the guard's ARGUMENT, not a local handed to it afterwards — see
  # bin/task#usage_dir and test/lib/state_store_containment_test.rb.
  TaskUsageSandbox.enforce!(
    pinned.empty? ? File.join(projects_root, ".agents", "task-usage") : pinned,
    store: "task-usage"
  )
end

# The captured per-transition usage for one task slug, or {} when there's no
# session / transcript / delta. String keys + scalar values, so it's safe inside
# the Ruby-literal conductor snippet (Base64-encoded by conductor_payload).
def capture_move_usage(slug)
  session, provider = conductor_session_identity
  return {} if session.to_s.empty?

  capture = TaskUsageBaseline.new(session: session, provider: provider, dir: release_usage_dir).capture_delta(slug)
  return {} unless capture

  usage = {}
  usage["model"] = capture.model if capture.model
  if capture.usage?
    usage["tokens_in"]  = capture.tokens_in
    usage["tokens_out"] = capture.tokens_out
    usage["cost"]       = format("%.4f", capture.cost) if capture.cost
  end
  usage
rescue StandardError
  {}
end

# The { slug => usage } map for a set of slugs (slugs with no capturable usage
# are dropped, keeping the snippet small). A no-op in --dry-run: capture_delta
# ADVANCES the baseline, and a dry-run must mutate nothing.
def move_usage_map(slugs)
  return {} if DRY

  Array(slugs).each_with_object({}) do |slug, map|
    usage = capture_move_usage(slug)
    map[slug] = usage unless usage.empty?
  end
end

# Thin wrappers over the pure, unit-tested Release::Cli parsers — they consume
# from this process's ARGV so the subcommands read the same way as before.
def opt_values(flag) = Release::Cli.opt_values(ARGV, flag)
def opt_value(flag)  = Release::Cli.opt_value(ARGV, flag)

def confirm(prompt)
  return true if ASSUME_YES || DRY

  # A non-interactive shell (no TTY) has no human to answer the prompt. The old
  # code read `$stdin.gets` → nil (EOF) → "" casecmp "y" → FALSE, so callers that
  # `return unless confirm(...)` (prepare) SILENTLY no-op'd — "looked like it ran
  # but nothing deployed", the SOP's flagged "dangerous one". Fail LOUDLY instead:
  # abort with the --yes escape hatch so a hands-off run must OPT IN to skipping
  # the gate rather than silently skipping the ACTION. This makes prepare's confirm
  # path consistent with ship/archive (which already `abort! unless confirm`).
  # --yes/--dry-run returned above, so they never reach here — the bypass is intact.
  abort!("non-interactive shell — pass --yes to run this non-interactively") unless $stdin.tty?

  $stdout.print("#{prompt} [y/N] ")
  answer = $stdin.gets
  # EOF (Ctrl-D) on an otherwise-interactive stdin: still no answer — abort, never
  # fold it into a false that a caller mistakes for a deliberate "no".
  abort!("EOF on stdin — pass --yes to run this non-interactively") if answer.nil?
  answer.strip.casecmp("y").zero?
end

# Poll <url>/up until it returns 200 (the dyno booted) or the attempts run out,
# sleeping `delay`s between tries. Returns true on a 200, false on timeout. This
# closes the /up-smoke race in `prepare`: `bin/qa-server deploy` returns once the
# push is accepted, but a slow dyno may still be booting, so the release would
# record QA + assemble against an app that isn't serving yet.
#
# An empty url (an app with no QA review url) returns true — there's nothing to
# smoke. A dry-run prints the plan and returns true (executes nothing).
def wait_for_boot(url, attempts: 30, delay: 5)
  return true if url.to_s.empty?
  if DRY
    step("wait for boot: poll #{url}/up until 200 (≤ #{attempts}×#{delay}s)")
    return true
  end

  step("wait for boot: #{url}/up (≤ #{attempts}×#{delay}s)")
  attempts.times do |i|
    code, = sh("/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "#{url}/up", capture: true)
    if code.to_s.strip == "200"
      say("  /up → 200 (booted after #{i + 1} poll#{i.zero? ? '' : 's'})")
      return true
    end
    break if i == attempts - 1

    sleep(delay)
  end
  say("  ⚠ /up never returned 200 after #{attempts} polls — dyno may still be booting")
  false
end

# --- post-deploy command hook ----------------------------------------------
# Run each release member's declared `devops.post_deploy_cmd` via `heroku run` on
# the just-deployed app — the QA heroku app on `prepare` (target: :qa), the
# production app on `ship` (target: :prod). The {task, app, cmd} plan + the
# QA-vs-prod target resolution are the unit-tested Release::PostDeploy.plan; this
# CLI owns only the `heroku run` I/O, the abort-on-failure, and the checks_run
# record. Commands are expected IDEMPOTENT, so a re-run after a failure just
# re-runs them (partial-deploy semantics: the release stays recoverable).
#
# Aborts the WHOLE pipeline on the first non-zero exit (so a bad backfill stops
# the release instead of shipping past it). A declared command with no resolvable
# target app (e.g. a gem, or an app missing from qa_environments.yml) is a hard
# abort — a declared command must never silently no-op. --dry-run PRINTS the
# command + target app and executes nothing.
def run_post_deploy(repos, target:)
  plan = Release::PostDeploy.plan(repos, qa_environments: QA_ENVIRONMENTS, target: target)
  return if plan.empty?

  phase  = target == :qa ? "QA" : "prod"
  subcmd = target == :qa ? "prepare" : "ship"
  say("")
  step("post-deploy hooks (#{phase}): #{plan.size} command(s)")
  plan.each do |entry|
    task = entry["task"]
    app  = entry["app"]
    cmd  = entry["cmd"]
    # Members that declared the SAME work (in either the rails or the rake spelling)
    # were folded into this one entry by Release::PostDeploy.dedupe — one dyno, but
    # the [post-deploy] check is still stamped on EVERY one of them below, so a
    # folded member never loses its record.
    tasks = Array(entry["tasks"])
    tasks = [task] if tasks.empty?
    label = tasks.join(", ")
    # Unroutable declared command (a gem, or an app missing from qa_environments)
    # is a HARD abort, never a silent no-op. Intentionally BEFORE the DRY gate: a
    # dry-run must surface this misconfig (it would block the real run) rather than
    # preview past it.
    abort!("task #{label} (#{entry['repo']}) declares a post_deploy_cmd but has no #{phase} app in " \
           "config/qa_environments.yml — register one or clear devops.post_deploy_cmd") if app.empty?

    # One canonical argv drives BOTH the preview and the real run, so --dry-run
    # prints exactly what executes. It is built by the unit-tested
    # Release::PostDeploy.heroku_argv — `--exit-code` (the flag that makes a failing
    # remote command turn this hook red) is asserted there rather than trusted here.
    heroku_argv = Release::PostDeploy.heroku_argv(app: app, cmd: cmd)
    printed = heroku_argv.join(" ")

    if DRY
      say("  [dry-run] post-deploy #{label}: #{printed}")
      next
    end

    step("post-deploy #{label}: #{printed}")
    post_deploy_scope = target == :qa ? "qa_post_deploy" : "prod_post_deploy"
    out, ok = run_test_scope(post_deploy_scope, *heroku_argv, capture: true, repo: app, label: "#{label}: #{cmd}")
    print(out)
    tasks.each { |slug| record_post_deploy_check(task: slug, app: app, cmd: cmd, ok: ok) }
    # In ship, add successful runs to the partial-ship "what's live" trail.
    @ship_live << "post-deploy `#{cmd}` on #{app} (#{label})" if ok && defined?(@ship_live) && @ship_live
    abort!("post-deploy command failed for #{label} on #{app}: `#{cmd}` — fix it, then re-run " \
           "`bin/release #{subcmd}` (the command is idempotent; a re-run resumes)") unless ok
  end
end

# Stamp the [post-deploy] outcome on the member task's checks_run via the board
# conductor (read-merge-write, idempotent — see Release::Conductor). A board WRITE,
# so it routes through `conductor` (suppressed under --dry-run; run_post_deploy
# never reaches here in dry-run, but the gate keeps it safe).
def record_post_deploy_check(task:, app:, cmd:, ok:)
  conductor(
    "c = Release::Conductor.record_post_deploy_check(" \
    "task_slug: #{task.inspect}, app: #{app.inspect}, cmd: #{cmd.inspect}, ok: #{ok.inspect}); " \
    "puts({ task: #{task.inspect}, checks: c.size }.to_json)"
  )
end

# --- gem publishing (producer-first) ---------------------------------------
# Build + push one gem, then tag its repo. Each failure aborts loudly with the
# fix, never swallowed — a half-published release is worse than a stopped one.
def publish_gem(repo, version)
  path = repo_path(repo)
  abort!("gem repo not found at #{path} — clone it as a sibling at the projects root") unless DRY || Dir.exist?(path)

  meta    = RELEASE_REPOS.dig("gems", repo) || {}
  gemspec = meta["gemspec"].to_s.empty? ? "#{repo}.gemspec" : meta["gemspec"]
  artifact = File.join(Dir.tmpdir, "release-#{repo}-#{version}.gem")

  # 1. Gate on the gem's own release-check (--build = syntax + unit + build) when
  #    it ships one, so a red gem never gets pushed.
  if (rc = meta["release_check"]) && (DRY || File.exist?(File.join(path, rc)))
    step("gem check: #{repo} #{rc} --build")
    _, ok = run_test_scope("gem_release_check", rc, "--build", chdir: path, repo: repo, label: "#{rc} --build")
    abort!("#{repo} release-check failed — fix before publishing (nothing pushed)") unless ok || DRY
  end

  # 2. Build the push artifact at a known path.
  step("gem build: #{repo} #{gemspec} → #{artifact}")
  _, built = sh("gem", "build", gemspec, "--output", artifact, chdir: path)
  abort!("gem build failed for #{repo} #{version} — aborting before push") unless built || DRY

  # 3. Push to RubyGems.
  step("gem push: #{artifact}")
  _, pushed = sh("gem", "push", artifact)
  abort!("gem push failed for #{repo} #{version} — already published? The RELEASE owns the version, not any PR: commit an advanced #{meta['version_file']} directly onto #{repo}'s `accepted` (a PR editing it is refused by bin/dor-check), then re-run prepare. Or check `gem signin`. Nothing downstream deployed.") unless pushed || DRY

  # 4. Tag the gem repo so the published version is reproducible from git.
  tag = "v#{version}"
  step("git tag #{tag} in #{repo}")
  sh("git", "-C", path, "tag", "-a", tag, "-m", "Release #{repo} #{tag}")
  _, tagged = sh("git", "-C", path, "push", "origin", tag, capture: true)
  say("  (tag #{tag} push #{tagged ? 'ok' : 'skipped/failed — push it manually if needed'})") unless DRY
end

# --- init ------------------------------------------------------------------
# One-time, idempotent: create the persistent `release` branch from origin/main
# in every gem + app repo that doesn't already have one. Re-runnable — a repo
# that already has origin/release is skipped.
def init
  say("Init the persistent ladder branches — #{Release::Ladder::RUNGS.join(' + ')}#{DRY ? ' — DRY RUN' : ''}")
  release_repo_slugs.each do |repo|
    path = repo_path(repo)
    unless DRY || Dir.exist?(path)
      say("  - #{repo}: SKIP (not checked out at #{path})")
      next
    end

    sh("git", "-C", path, "fetch", "origin", "--quiet")

    # BOTH rungs, not just `release`. This used to create `release` alone, which
    # is the two-rung model the ladder replaced — and it is why an app could be
    # "initialized" and still have nowhere for a feature PR to land (feature PRs
    # target `accepted`). moms-app is the case that surfaced it.
    Release::Ladder::RUNGS.each do |rung|
      # Existence is a read — check it for real outside dry-run; in dry-run we
      # always PREVIEW the push so the plan is visible.
      unless DRY
        _, exists = sh("git", "-C", path, "rev-parse", "--verify", "--quiet", "origin/#{rung}", capture: true)
        if exists
          say("  - #{repo}: origin/#{rung} already exists — skip")
          next
        end
      end

      step("push #{rung} branch in #{repo}: origin/main → origin/#{rung}")
      _, pushed = sh("git", "-C", path, "push", "origin", "origin/main:refs/heads/#{rung}")
      say("  - #{repo}: created origin/#{rung} from origin/main") if pushed || DRY
    end
  end

  # Say what was NOT touched and why. A silently short list is how a repo that
  # needed the ladder got skipped without anyone noticing.
  Release::Ladder.parked(RELEASE_REPOS).each do |repo, ladder|
    say("  - #{repo}: not swept (ladder: #{ladder})")
  end

  say("")
  say("✓ Ladder branches ready#{DRY ? ' (DRY RUN — nothing executed)' : ''}.")
end

# --- merge -----------------------------------------------------------------
# The SWEEP primitive, accepted-ladder edition. Review already merged each feat PR
# into `accepted` (merged:"accepted"), so this no longer merges per-task feat PRs:
# it PROMOTES all of `accepted` onto the persistent `release` branch via ONE batch
# PR per repo (promote_accepted_to_release!) and records the NAMED slugs' membership
# in ONE `heroku run` (membership + merged:"release"; stages don't move — the
# `reviewed`→`assembled` flip is prepare's QA-green step, and an `assembled`
# straggler keeps its stage). A named task with no code on `accepted` (merged:"")
# ABORTS (review must land it first); a task already `merged: release/main` skips
# the promote (crash recovery) but still records.
#
# BATCHED + crash-safe: the resolve is ONE read and the record is ONE write (single
# dyno spin-up). The promote is git-FIRST and fail-closed (a conflict/missing
# checkout aborts before anything is recorded); it's idempotent — accepted level
# with release → skip the PR, and a gh-merge failure falls back to pr_merged? (an
# interrupted prior run merged it), so the half-state self-heals rather than wedging.

# The one-shot read snippet that resolves EVERY merge slug's PR + `merged`
# git-location AND runs the review-gate screen in a SINGLE conductor call (one
# heroku-run spin-up for the whole batch). Pure string builder (slugs are
# alnum/hyphen, safe under .inspect — same as the existing single-slug
# `slug.inspect` literals; `override` is a bare bool literal). The screen is a
# PURE read (Release::Conductor.screen_merge writes nothing), so it's safe inside
# this read-only resolve and previews under --dry-run. Emits ONE JSON line:
#   { "tasks": [ { slug, pr_url, repo, stage, merged, repos, pr_urls } |
#                { slug, missing: true } ],
#     "screen": { rows:[…], blocked:[…], overridden:[…], missing:[…], proceed: } }
#
# `repos`/`pr_urls` are the task's FULL release identity (Task#release_repos /
# #release_pr_urls), emitted here for exactly the reason sweep_detect_ruby emits
# them — and their absence is what made `merge` carry three multi-repo guards
# that could never fire. WITHOUT them Release::SweepPlan.normalize falls back to
# `[row["repo"]]`, repo_coverage_gap's `size < 2` guard passes every row, and
# `plan["blocked"]` is permanently empty. `repo`/`pr_url` remain the primary, for
# the sweep line and crash recovery.
#
# The active release (`Release.current`) rides this same read so `merge` can take its
# assembler claim on the SAME slug `prepare` would, BEFORE its promote — the real
# rel_slug isn't known until sweep! records. (A comment must NOT interrupt the
# backslash-continued string literal below, or only the last fragment survives.)
def batch_resolve_ruby(slugs, override: false)
  "slugs = #{slugs.inspect}; " \
  "rows = slugs.map { |s| t = Task.find_by(slug: s); " \
  "t ? { slug: t.slug, pr_url: t.devops_url('pr').to_s, repo: t.release_repo.to_s, stage: t.stage, " \
  "merged: t.merged.to_s, kind: t.release_kind.to_s, repos: t.release_repos, pr_urls: t.release_pr_urls } " \
  ": { slug: s, missing: true } }; " \
  "screen = Release::Conductor.screen_merge(slugs, override: #{override ? 'true' : 'false'}); " \
  "cur = Release.current; " \
  "puts({ tasks: rows, screen: screen, release: (cur ? { slug: cur.slug } : nil) }.to_json)"
end

# The one-shot write snippet that sweeps EVERY slug in a SINGLE `heroku run` — N
# membership writes on one dyno, instead of a cold `heroku run` per PR. sweep! is
# idempotent/crash-safe (see Release::Conductor: an already-`merged` member is
# untouched, never regressed), so a re-run is safe. `override` threads the
# audited review-gate bypass through to sweep! — harmless for already-sweepable
# members (records no skip); an unreviewed member is flipped to `reviewed` with
# the `review_bypassed` audit event stamped on that transition. No usage map:
# the sweep writes NO stage transition (the reviewed→assembled flip — and its
# usage capture — happens at prepare's QA-green step).
#
# TRANSACTIONAL, and it runs validate_members! — the same shape
# batch_sweep_with_plan_ruby has always had, for the same reason. `merge` records
# straight into the release without prepare's repo plan, so before this it was the
# ONE write path with no member validation behind it: an unknown repo, or a
# multi-repo member with an incomplete PR record, was recorded unchallenged. A
# validate_members! raise rolls the whole sweep back, so a refusal leaves the
# members exactly as it found them (the gh promote above already landed; the next
# run self-heals through pr_merged?).
# Emits ONE JSON line: { "swept": [...], "slug": <last release>, "state" }.
def batch_sweep_ruby(slugs, override: false)
  "out = Release.transaction { slugs = #{slugs.inspect}; " \
  "results = slugs.map { |s| r = Release::Conductor.sweep!(Task.find_by!(slug: s), override: #{override ? 'true' : 'false'}); " \
  "{ task: s, release: r.slug, state: r.state } }; " \
  "last = results.last; " \
  "Release::Conductor.validate_members!(Release.find_by!(slug: last[:release])) if last; " \
  "{ swept: results, slug: (last && last[:release]), state: (last && last[:state]) } }; " \
  "puts(out.to_json)"
end

# Is this PR already merged on GitHub? The gh-side crash-recovery read: when a
# prior run merged the PR but died before the record write (so `merged` is still
# nil), the next run's `gh pr merge` fails — this read distinguishes "already
# merged, carry on" from a genuine merge failure. Read-only; goes straight to
# Open3 (runs even in --dry-run).
def pr_merged?(pr_url)
  out, status = Open3.capture2e("gh", "pr", "view", pr_url, "--json", "state", "-q", ".state")
  status.success? && out.strip == "MERGED"
end

# Review-gate guard for the sweep (`bin/release merge` + `prepare`). The
# DECISION (which slugs are blocked vs overridden) is
# Release::Conductor.screen_merge's — this only renders it: it ABORTS the whole
# run when any requested task isn't sweepable (`reviewed`, or an `assembled`
# straggler) and no --override was given, naming exactly which task is in which
# stage and how to override; or prints a loud OVERRIDE banner for the bypassed
# tasks (whose skip sweep! records on the audit spine). A `nil`/empty screen
# (e.g. a stub-less dry preview) is a no-op. Both lists carry the offending
# task's actual stage, pulled from screen rows, so the operator sees "task X is
# in stage Y" without re-reading the board.
def enforce_review_gate!(screen)
  rows  = Array(screen["rows"])
  stage = ->(slug) { (rows.find { |r| r["slug"] == slug } || {})["stage"] || "unknown" }

  blocked = Array(screen["blocked"])
  if blocked.any?
    named = blocked.map { |slug| "#{slug} (#{stage.call(slug)})" }.join(", ")
    abort!("review gate: #{named} #{blocked.size == 1 ? 'is' : 'are'} not sweepable (`reviewed`/`assembled`) — " \
           "get the PR(s) through review first, or pass --override to sweep anyway " \
           "(the skip is recorded as a `review_bypassed` audit event).")
  end

  overridden = Array(screen["overridden"])
  return if overridden.empty?

  named = overridden.map { |slug| "#{slug} (#{stage.call(slug)})" }.join(", ")
  say("  ⚠ OVERRIDE: sweeping #{named} past the review gate — recording a `review_bypassed` audit event per task.")
end

# The repo column of a sweep/task transcript line. A single-repo row renders
# EXACTLY as it always did (its one repo); a MULTI-repo row names every repo it
# carries, comma-separated. The operator reading a transcript is the last human
# who can catch a half-ship before it is recorded, and printing only the primary
# is what made the 2026-08-13 run look complete: the line said "mcritchie-studio"
# for a task that also carried turf-monster. Falls back to the singular when the
# plural is absent (an older/stubbed read).
def sweep_line_repos(row)
  repos = row["repos"]
  repos = [] unless repos.is_a?(Array)
  repos = repos.map(&:to_s).reject(&:empty?).uniq
  repos.size > 1 ? repos.join(", ") : row["repo"].to_s
end

# The merged-stamp value review writes when a feat PR lands on `accepted` — the
# git-location "code is on accepted" ticket the sweep promotes. Same string as the
# branch name, kept as its own const so the merged-state compare reads as intent.
ACCEPTED_MERGED = "accepted"

# Promote each repo's `accepted` branch onto its `release` branch — the accepted-
# ladder's SECOND rung (it replaces the sweep's N per-feat-PR merges). Review already
# merged each feat PR into `accepted` and stamped merged:"accepted"; this lands ALL
# of that accumulated work onto `release` via ONE batch PR PER REPO (a single-repo
# release is exactly one PR, not N per task). Git-side + fail-closed PER repo:
#   * `git -C <path> fetch`, then ahead = rev-list origin/release..origin/accepted.
#   * ahead == 0 (accepted level with release — nothing new, or a prior run already
#     promoted): SKIP the PR. The caller STILL records membership + deploys — the
#     reviewed members must ride THIS RC even when the code already landed.
#   * ahead > 0: reuse an OPEN accepted→release PR or open one (`--base release
#     --head accepted`), `gh pr merge` it. A gh-merge failure falls back to
#     pr_merged? (an interrupted prior run merged it, its record write died) →
#     treat as promoted; otherwise ABORT (fail-closed — nothing recorded, members
#     stay `reviewed` for a clean re-run). A missing local checkout ABORTS too
#     (never record members whose code was not promoted).
# A DRY run PREVIEWS the one-batch-PR-per-repo plan without any git/gh call (so the
# preview is hermetic and prints exactly ONE promote line per repo). `label` names
# the RC in the PR title when known (the --slug option; nil → a generic title).
def promote_accepted_to_release!(repos, label: nil)
  targets = Array(repos).map(&:to_s).reject(&:empty?).uniq
  # THE GUARD LIVES HERE, NOT AT A CALL SITE — and that placement is the whole fix.
  #
  # It was originally wired in front of ONE of this function's two callers. The other
  # one (the plan path, which is what `bin/release prepare` actually takes) promoted
  # without it, and the very first sweep after it shipped proved the point: the
  # guard's step line never appeared. A gate on a path nobody takes is not a gate.
  #
  # This file has already learned this lesson once — validate_members! carries a
  # comment naming all three of its live callers for exactly this reason. Guarding the
  # FUNCTION means both existing callers and every future one inherit it, and there is
  # no call site left to forget.
  refuse_red_accepted!(targets) unless DRY
  # The companion guard, and it runs SECOND on purpose: an asserted RED is a fact about
  # this candidate and outranks a fact about the repo's plumbing, so the operator sees
  # the broken tree first when both are true.
  refuse_blind_accepted!(targets) unless DRY
  targets.each do |repo|
    if DRY
      step("promote #{ACCEPTED_BRANCH} → #{RELEASE_BRANCH} in #{repo}: open/reuse ONE " \
           "`gh pr create --base #{RELEASE_BRANCH} --head #{ACCEPTED_BRANCH}` batch PR and merge it")
      next
    end

    path = repo_path(repo)
    abort!("app repo not found at #{path} — clone it as a sibling to promote #{ACCEPTED_BRANCH} → #{RELEASE_BRANCH} " \
           "(nothing recorded; members stay `reviewed`)") unless Dir.exist?(path)

    sh("git", "-C", path, "fetch", "origin", RELEASE_BRANCH, ACCEPTED_BRANCH, "--quiet", capture: true)
    ahead_out, ahead_ok = sh("git", "-C", path, "rev-list", "--count",
                             "origin/#{RELEASE_BRANCH}..origin/#{ACCEPTED_BRANCH}", capture: true)
    abort!("could not compare origin/#{RELEASE_BRANCH}..origin/#{ACCEPTED_BRANCH} in #{repo} " \
           "(`git rev-list` failed) — fetch, then re-run `bin/release prepare`.") unless ahead_ok
    ahead = ahead_out.strip.to_i
    if ahead.zero?
      step("#{repo}: `#{ACCEPTED_BRANCH}` is level with `#{RELEASE_BRANCH}` — nothing to promote " \
           "(skip the batch PR; membership still records)")
      next
    end

    pr_url = accepted_release_pr_url(repo, label: label)
    step("gh pr merge #{pr_url} --merge — promote #{ACCEPTED_BRANCH} → #{RELEASE_BRANCH} in #{repo} " \
         "(#{ahead} commit#{ahead == 1 ? '' : 's'})")
    # capture: true so a FAILURE can quote gh. Unlike the sibling `gh pr create`
    # above — which already captured and merely discarded the text — this call had
    # NOTHING to quote: it streamed to the terminal and kept none of it, so the
    # abort below could only ever guess.
    #
    # TWO CONSEQUENCES, both wanted here. The live stream is replaced by an echo on
    # success, so the run log keeps what it used to show. And gh's stdout is now a
    # pipe rather than a TTY, which puts gh in non-interactive mode — for an
    # automated conductor that is the correct posture: a `gh` that would have
    # stopped to ask now fails with a message we print, instead of hanging a
    # release on a prompt nobody is watching.
    merge_out, ok = sh("gh", "pr", "merge", pr_url, "--merge", capture: true)
    # The echo of gh's words is decided AFTER the recovery, never before it. It
    # used to sit above this branch gated on `ok` — still false while the fallback
    # was deciding — so the interrupted-run path printed NOTHING, and that is the
    # path where gh's line ("… is already merged") is the EVIDENCE for continuing.
    # The two arms are exclusive, so the ordering trap cannot come back.
    if !ok && pr_merged?(pr_url)
      say(Release::GhFailure.recovery_message(
            headline: "  ↷ #{pr_url} already merged (interrupted prior run) — continuing to the record step",
            output: merge_out
          ))
      ok = true
    elsif ok && !merge_out.strip.empty?
      say(merge_out.strip)
    end
    unless ok
      abort!(Release::GhFailure.abort_message(
               headline: "gh pr merge failed for the #{ACCEPTED_BRANCH}→#{RELEASE_BRANCH} batch PR " \
                         "in #{repo} (#{pr_url}).",
               output: merge_out,
               fallback: "Resolve it on GitHub (conflicts/checks), then re-run " \
                         "`bin/release prepare`; it resumes."
             ))
    end
  end
end

# Find the OPEN accepted→release batch PR for a repo, or open one — idempotent
# across interrupted runs (reuse, never a duplicate). Scoped to the repo via
# `--repo owner/name` so it needs no chdir; aborts fail-closed if the PR can't be
# opened. (Live gh — only reached in a non-DRY promote.)
def accepted_release_pr_url(repo, label: nil)
  nwo = repo_name_with_owner(repo)
  repo_args = nwo.empty? ? [] : ["--repo", nwo]

  existing, ok = sh("gh", "pr", "list", *repo_args, "--base", RELEASE_BRANCH, "--head", ACCEPTED_BRANCH,
                    "--state", "open", "--json", "url", "-q", ".[0].url", capture: true)
  return existing.strip if ok && !existing.strip.empty?

  title = label.to_s.empty? ? "Promote #{ACCEPTED_BRANCH} → #{RELEASE_BRANCH}" \
                            : "Promote #{ACCEPTED_BRANCH} → #{RELEASE_BRANCH} (#{label})"
  body = "Batch promotion of the accepted-ladder: lands every reviewed change already merged onto " \
         "`#{ACCEPTED_BRANCH}` onto `#{RELEASE_BRANCH}` for QA. Opened by `bin/release prepare`."
  out, created = sh("gh", "pr", "create", *repo_args, "--base", RELEASE_BRANCH, "--head", ACCEPTED_BRANCH,
                    "--title", title, "--body", body, capture: true)
  # `out` already carries gh's stderr (sh → Open3.capture2e), so the reason this
  # failed is in hand — QUOTE IT rather than replacing it with a guess. See
  # Release::GhFailure for the recovery this cost during rel-20260812-3f1f9b.
  unless created
    abort!(Release::GhFailure.abort_message(
             headline: "could not open the #{ACCEPTED_BRANCH}→#{RELEASE_BRANCH} batch PR in #{repo} " \
                       "(`gh pr create` failed) — nothing was promoted.",
             output: out,
             fallback: "Open it by hand (`gh pr create --base #{RELEASE_BRANCH} " \
                       "--head #{ACCEPTED_BRANCH}`), then re-run `bin/release prepare`; it resumes."
           ))
  end
  out.strip
end

def merge
  # `--override` is the audited review-gate escape hatch — consume it BEFORE
  # positional_slugs reads the rest (take_flag deletes it from ARGV so it's never
  # mistaken for a slug).
  override = Release::Cli.take_flag(ARGV, "--override")
  slugs = Release::Cli.positional_slugs(ARGV)
  abort!("usage: bin/release merge <task-slug> [<task-slug> ...] [--override]") if slugs.empty?

  say("Sweep #{slugs.join(', ')} onto `#{RELEASE_BRANCH}`#{PROD ? ' (PROD board)' : ' (local)'}#{override ? ' (OVERRIDE)' : ''}#{DRY ? ' — DRY RUN' : ''}")

  # 1. Resolve ALL the tasks' PRs + `merged` git-location AND run the review-gate
  #    screen in ONE read (one heroku-run spin-up for the whole batch; a read —
  #    runs even in dry-run).
  step("record (read-only): resolve #{slugs.size} task PR(s)")
  resolved = conductor(batch_resolve_ruby(slugs, override: override), read_only: true)
  infos = resolved["tasks"] || []

  missing = infos.select { |i| i["missing"] }.map { |i| i["slug"] }
  abort!("task(s) not found on the board: #{missing.join(', ')}") if missing.any?
  infos.each do |i|
    at = i["merged"].to_s.empty? ? "" : " · merged: #{i['merged']}"
    say("  task #{i['slug']} (#{i['stage']}#{at}) · #{sweep_line_repos(i)} · #{i['pr_url']}")
  end

  # 1b. REVIEW-GATE GUARD (the decision lives in Release::Conductor.screen_merge;
  #     this only prints + aborts). Runs BEFORE the accepted→release promote: an
  #     unsweepable task ABORTS the whole run unless --override is given. With --override,
  #     the offending tasks proceed but the skip is recorded as a
  #     `review_bypassed` audit event when sweep! flips them to `reviewed`.
  enforce_review_gate!(resolved["screen"] || {})

  # 2. The SWEEP PLAN (pure: Release::SweepPlan): partition the named tasks into the
  #    members to RECORD (code on accepted/release/main) and HELD anomalies (a task
  #    with no merged stamp — review never landed its feat PR on `accepted`). For
  #    this EXPLICIT command a held task is a HARD abort: the operator named it and
  #    there is no code on `accepted` to promote — silently dropping it would lie.
  plan = Release::SweepPlan.compute(infos)

  # 2a. MULTI-REPO COVERAGE REFUSAL — prepare's step 3a, on the path prepare itself
  #     routes operators to (`prepare has NO --override — use bin/release merge
  #     --override`). It must come FIRST, before the held check: SweepPlan.compute
  #     removes blocked rows before it splits record/held, so a blocked task is in
  #     NEITHER list — without this abort `merge` would silently drop the exact task
  #     the operator named, promote the repos it could see, and print a tick.
  if plan["blocked"].any?
    named = plan["blocked"].map { |row| "#{row['slug']} (names #{row['repos'].join(', ')}; no PR url for #{row['missing'].join(', ')})" }
    abort!("merge refused #{plan['blocked'].size} multi-repo task(s) with an incomplete PR record: " \
           "#{named.join('; ')}. Promoting now would carry only the repo(s) with a PR and still stamp " \
           "the task assembled/shipped for the rest — the 2026-08-13 half-ship. NOTHING was promoted " \
           "or recorded. Record the missing PR " \
           "(`bin/task update <slug> --pr-url-for <repo>=<url>`), or drop the repo from the task's " \
           "devops.repositories if it carries no work, then re-run `bin/release merge`.")
  end

  if plan["held"].any?
    abort!("task(s) have no code on `#{ACCEPTED_BRANCH}` (merged:\"\") — review must land the feat PR on " \
           "`#{ACCEPTED_BRANCH}` first: #{plan['held'].join(', ')}")
  end
  plan["record"].reject { |row| row["merged"] == ACCEPTED_MERGED }.each do |row|
    step("skip promote for #{row['slug']} — already merged: #{row['merged']} (crash recovery); membership still records")
  end

  # ASSEMBLER CLAIM — `merge` runs the SAME promote (accepted→release) + `sweep!` that
  # `prepare` guards: the assembler-lane mutation. `prepare` even routes operators HERE
  # (`bin/release merge --override`), so an unguarded merge is a THIRD seam that breaks
  # the "no two assemblers on one release" invariant — a concurrent merge/prepare would
  # double-assemble. Guard it with the SAME per-release assembler claim. The real
  # rel_slug isn't known until `sweep!` records, so claim the ACTIVE release slug when
  # one exists (contending with prepare's active-path claim), else the `__forming__`
  # sentinel (contending with prepare's fresh-create sentinel + other merges); hand off
  # to the real slug after sweep! — acquire the real claim BEFORE freeing the sentinel,
  # so ownership is CONTINUOUS across the promote+sweep. A live DIFFERENT holder stands
  # us down (abort!). merge, like finalize, is a discrete op, so the begin/ensure frees
  # the claim on EVERY exit. Inert under --dry-run (conductor_claim no-ops).
  active = resolved["release"]
  assembler_slug = (active && active["slug"]).to_s.strip
  assembler_slug = ReleaseClaimCli::FORMING_SLUG if assembler_slug.empty?
  acquire_conductor_claim!("assembler", assembler_slug)
  begin
    # 3. PROMOTE accepted → release (the accepted-ladder's SECOND rung). SEMANTIC
    #    NARROWING (accepted-ladder): `merge <slug>` no longer merges the named task's
    #    ONE feat PR — review already merged it into `accepted`. It now promotes ALL of
    #    `accepted` onto `release` via ONE batch PR per repo and records the NAMED
    #    slugs' membership. So it lands EVERY reviewed change on `accepted`, not just
    #    the named one — use it to force a specific reviewed task onto the RC ahead of
    #    the sweep. Idempotent + fail-closed (accepted level with release → skip the
    #    PR, still record). Git-FIRST (the irreversible step), then the record write.
    #    Promote EVERY repo each landed task NAMES (`repos`), not just its primary —
    #    the same fan-out prepare does, and the same reason: reading the singular
    #    `repo` here is what promoted the hub alone for a task carrying
    #    [mcritchie-studio, turf-monster] on 2026-08-13. This path is worse than
    #    prepare's, not better: prepare's own abort message ROUTES operators here for
    #    the override, so the singular form meant the documented escape hatch was
    #    also the one that half-shipped. (Rails-FREE file — no `.presence`.)
    promote_repos = infos.select { |i| i["merged"].to_s == ACCEPTED_MERGED }
                         .flat_map { |i| (i["repos"].is_a?(Array) && !i["repos"].empty?) ? i["repos"] : [ i["repo"] ] }
                         .map(&:to_s).reject(&:empty?).uniq
    promote_accepted_to_release!(promote_repos) if promote_repos.any?

    # 4. BATCHED record: ALL named members in ONE `heroku run` (single dyno spin-up,
    #    N membership writes; conductor suppresses the write under --dry-run). Stages
    #    don't move here — prepare's QA-green flips `reviewed` members to `assembled`;
    #    a swept straggler is already there.
    swept = plan["sweep"]
    if swept.any?
      step("record: Release::Conductor.sweep! ×#{swept.size} in ONE run (#{swept.join(', ')})")
      @merge_result = conductor(batch_sweep_ruby(swept, override: override))
    end

    result = @merge_result || {}

    # HAND-OFF — the real rel_slug is known now; take it, then free the sentinel (a
    # no-op for the active/named path, which already holds the real slug). Guarded to a
    # real recorded slug so a --dry-run (no record) never claims a bogus slug.
    if result["slug"].to_s.strip != ""
      acquire_conductor_claim!("assembler", result["slug"])
      release_conductor_claim!(role: "assembler", slug: ReleaseClaimCli::FORMING_SLUG)
    end

    say("")
    say("✓ Swept #{swept.join(', ')} onto `#{RELEASE_BRANCH}`#{DRY ? ' (DRY RUN — nothing executed)' : ''} — stages don't move: `reviewed` members flip `assembled` at QA-green (assembled stragglers keep their stage).")
    say("  release #{result['slug']} (#{result['state']}) — `bin/release prepare` deploys QA and flips members `assembled` on green.") unless DRY || result.empty?
  ensure
    release_conductor_claim!
  end
end

# --- prepare (Avi's self-healing qa-deploy) ------------------------------

# The one-shot DETECTION read: every `reviewed` task + any `assembled` straggler
# off the current RC — each with its PR url, repo, and `merged` git-location —
# plus the review-gate screen over exactly those slugs and the current release.
# `only_slugs` (from --task) narrows the sweep to the named tasks. A PURE read
# (sweep_candidates + screen_merge write nothing), so it previews under
# --dry-run. Emits ONE JSON line:
#   { "tasks": [{slug, stage, merged, pr_url, repo, repos, pr_urls}], "release": …,
#     "screen": { rows:[…], blocked:[…], … } }
#
# `repos`/`pr_urls` are the task's FULL release identity (Task#release_repos /
# #release_pr_urls); `repo`/`pr_url` remain the primary, for the sweep line and
# crash recovery. The plural pair is what the promote list and
# Release::SweepPlan's coverage refusal read — deriving either from the singular
# is what promoted one repo of a two-repo task and shipped the other blind.
def sweep_detect_ruby(only_slugs)
  only = only_slugs.empty? ? "nil" : only_slugs.inspect
  "only = #{only}; " \
  "c = Release::Conductor.sweep_candidates; " \
  "tasks = c['reviewed'] + c['stragglers']; " \
  "tasks = tasks.select { |t| only.include?(t.slug) } if only; " \
  "rows = tasks.map { |t| { slug: t.slug, stage: t.stage, merged: t.merged.to_s, " \
  "pr_url: t.devops_url('pr').to_s, repo: t.release_repo.to_s, kind: t.release_kind.to_s, " \
  "repos: t.release_repos, pr_urls: t.release_pr_urls } }; " \
  "screen = Release::Conductor.screen_merge(rows.map { |x| x[:slug] }); " \
  "r = Release.current; " \
  "puts({ tasks: rows, release: (r ? { slug: r.slug, state: r.state } : nil), screen: screen }.to_json)"
end

# The one-shot SWEEP write for prepare: open the candidate if none is active
# (honoring an explicit --slug), sweep! every landed slug (membership +
# merged:"release"; stages don't move), validate the members, and return the
# per-repo deploy plan — ONE `heroku run` for the whole batch. TRANSACTIONAL: a
# validate_members! raise rolls the whole sweep back; the gh merges already
# landed, but the next run self-heals (the gh-merge failure falls back to
# pr_merged?). Emits ONE JSON line: { slug, state, swept, repos }.
def batch_sweep_with_plan_ruby(slugs, release_slug = nil)
  open_ruby = release_slug ? "Release.open!(slug: #{release_slug.inspect}) if Release.current.nil?; " : ""
  "result = Release.transaction { #{open_ruby}" \
  "slugs = #{slugs.inspect}; " \
  "slugs.each { |s| Release::Conductor.sweep!(Task.find_by!(slug: s)) }; " \
  "r = Release.current_or_open!; " \
  "Release::Conductor.validate_members!(r); " \
  "{ slug: r.slug, state: r.state, swept: slugs, repos: Release::Conductor.repo_plan(r) } }; " \
  "puts(result.to_json)"
end

# The pre-QA gate command an app registers in config/release_repos.yml
# (`qa_test_cmd`) — the tier prepare owns (Release::STEP_TEST_TIERS["prepare"]):
# satellites register their integration subset; the HUB registers its FULL
# suite (the G3 batch certification that lets ship's test_gate self-gate an
# unchanged SHA). "" = not registered → the repo self-gates (its suite runs at
# ship's test_cmd / its own deploy) and the gate skips it.
def qa_gate_cmd(repo) = app_meta_for(repo)["qa_test_cmd"].to_s

# Parse a registry test command (`test_cmd` / `qa_test_cmd`) into the argv `sh`
# execs — Shellwords, not String#split, so quoted/spaced args survive as single
# elements (same policy as the heroku-run payload seam above). Identical to a
# plain split for the flag-style commands the registry carries today, so the
# switch is behavior-preserving. A malformed value (unbalanced quote) aborts
# NAMING the string instead of executing a garbled command.
def test_cmd_argv(cmd)
  Shellwords.split(cmd)
rescue ArgumentError => e
  abort!("unparseable test command #{cmd.inspect} (#{e.message}) — fix it in config/release_repos.yml")
end

# --- primary-checkout lock ---------------------------------------------------
# Serializes what STILL flips the primary's HEAD. As of 2026-07-12 that is ONE
# caller: the artifact-commit dance (commit_artifact_to_release), which checks out
# `release` to commit a generated doc and returns to `main`.
#
# The gate suites moved to the gate workspace, and the SHIP moved to its own
# workspace + ref pushes (push_frozen_main / repin_consumers / deploy_app) — so
# neither takes this lock any more, and neither can be blocked by it. The one
# remaining ship-side read of a primary is the GEM artifact build
# (checkout_detached), which is guarded by the ship preflight instead.
#
# ROOT CAUSE it guards against (rel-20260708-496cd8): the pre-QA gate ran its
# full suite in the primary hub checkout on `release` (~6-min critical section)
# while a concurrent `bin/release archive`/`retro` artifact dance flipped that
# same checkout main↔release five times — the suite's lazily-loaded routes/views
# then resolved against PRE-merge code → 7 false failures → a false-negative G3.
#
# flock, not a mkdir lock: the OS releases it when the holder dies, so a killed
# holder can never wedge the next conductor run. Per-repo (keyed by repo name) so
# a hub run never blocks a satellite's artifact commit.
#
# The lock dir is FIXED at <projects_root>/.agents/locks (the dir that already
# anchors cross-checkout state like the worktree registry) — NOT Dir.tmpdir:
# two conductors launched with different TMPDIR values must still contend on
# the SAME file. MCR_PRIMARY_LOCK_DIR overrides it; every test that exercises
# this lock MUST point it at a per-test tmpdir — the real dir belongs to the
# live conductor, and a test flocking it while a G3 gate (which holds it for
# its whole suite run) executes that test would deadlock the gate against
# itself.
# The lock dir RESOLVED — pure: no guard, no IO. Split out from the seam below so a
# test can assert the DEFAULT shape (<projects>/.agents/locks) without asking the code
# to mkdir_p the operator's real store in order to prove where it is. It used to do
# exactly that: the two "defaults to" tests deleted MCR_PRIMARY_LOCK_DIR and called
# the seam, so every suite run created the live <projects>/.agents/locks.
def primary_checkout_lock_dir
  dir = ENV["MCR_PRIMARY_LOCK_DIR"].to_s
  dir.empty? ? File.join(projects_root, ".agents", "locks") : dir
end

# THE CHOKE POINT for the lock store — guard, then create. Committed to creating a
# file from here (both callers flock it with File::CREAT), so the guard comes BEFORE
# mkdir_p, the same seam bin/task's write_feature_marker guards at. Under
# TASK_USAGE_SANDBOX an unpinned MCR_PRIMARY_LOCK_DIR aborts instead of falling back
# onto the LIVE conductor's lock dir — a test that flocks the real file can deadlock a
# running G3 gate against itself (that gate holds the lock for its whole suite run).
# The comment above has always SAID every test must pin it; this makes the pin a
# guarantee rather than a request.
def guarded_lock_dir
  dir = TaskUsageSandbox.enforce!(primary_checkout_lock_dir, store: "agent-locks")
  FileUtils.mkdir_p(dir)
  dir
end

def primary_checkout_lock_path(repo)
  File.join(guarded_lock_dir, "mcr-primary-checkout-#{repo}.lock")
end

# --- the workspace locks (gate + ship) ---------------------------------------
# A workspace is PRIVATE to the conductor, not to a PROCESS: its path
# (<repo>/.worktrees/_gate, <repo>/.worktrees/_ship) and its DB
# (<repo>_gate_test, <repo>_ship_test) are FIXED. So while no agent session or
# hand-run command can touch it, ANOTHER `bin/release` can — and two concurrent
# conductors are a documented occurrence here (two QA-release sessions have
# raced). Unlocked, conductor B's `reset --hard` would move the tree and its
# `db:test:prepare` would PURGE the DB under conductor A's live, lazily-autoloading
# suite: the exact two root causes the gate workspace exists to close, relocated
# one directory over (plus the parallel-full-suite SIGSEGV class).
#
# So each workspace takes its OWN lock, PER ROLE (gate / ship) and per repo, held
# across pin → prepare → use. Per role because the DEPLOY must never queue behind a
# concurrent conductor's G3 suite — or worse, reset the tree under it.
#
# PRECISELY (the ship is not wholly free of the gate lock, and the claim should not
# be overstated — jasper, PR #517): the ship's own TEST GATE (test_gate) runs its
# suite in the GATE workspace under the GATE lock, so it CAN queue behind a
# concurrent conductor's G3 suite. That is correct and deliberate — it is the same
# suite on the same tree, and it is pre-authority, so a wait costs nothing
# irreversible. What must never queue is everything AFTER ship authority — the
# re-pin, the deploys — and none of it touches the gate lock.
#
# Deliberately NOT the primary-checkout lock: the primary must stay FREE (feature
# sessions use it, and monopolising it for the length of a suite was half of what
# made the old gate hostile). Never nested inside the primary lock, so the two
# can't deadlock.
#
# NOTE on MCR_PRIMARY_LOCK_DIR: despite its name it overrides the lock DIRECTORY,
# not the primary lock alone — every bin/release lock lives there, and the tests
# isolate ALL of them by pointing it at a tmpdir. Do not "fix" the naming by giving
# a lock its own dir: a split would silently un-isolate one of them.
def gate_workspace_lock_path(repo, role: "gate")
  File.join(guarded_lock_dir, "mcr-#{Release::GateWorkspace.role!(role)}-workspace-#{repo}.lock")
end

# Run the block holding `repo`'s WORKSPACE lock for `role`. Always waits: a queued
# run is correct (the other conductor is using the same tree), where proceeding
# concurrently is guaranteed corruption.
def with_gate_workspace(repo, role: "gate")
  File.open(gate_workspace_lock_path(repo, role: role), File::RDWR | File::CREAT, 0o644) do |f|
    unless f.flock(File::LOCK_EX | File::LOCK_NB)
      holder = role == "ship" ? "another bin/release is deploying from that checkout" \
                              : "another bin/release is running its gate suite"
      say("  waiting on the #{repo} #{role}-workspace lock (#{holder})…")
      f.flock(File::LOCK_EX)
    end
    yield
  end
end

# The SHIP workspace's lock — the deploy's own checkout. Same flock discipline,
# a DIFFERENT file from the gate's, so a prod deploy never queues behind (or races)
# a concurrent conductor's G3 gate suite.
def with_ship_workspace(repo, &block)
  with_gate_workspace(repo, role: "ship", &block)
end

# Run the block holding `repo`'s primary-checkout lock.
#   wait: true  — queue behind the current holder (flips are seconds; the one
#                 long holder is the gate suite, and callers that MUST proceed
#                 — the gate itself, ship's ff — are correct to wait).
#   wait: false — best-effort: return :busy WITHOUT yielding when another
#                 invocation holds the checkout (the artifact dance skips
#                 rather than stall an archive/retro behind a ~6-min suite).
def with_primary_checkout(repo, wait: true)
  File.open(primary_checkout_lock_path(repo), File::RDWR | File::CREAT, 0o644) do |f|
    unless f.flock(File::LOCK_EX | File::LOCK_NB)
      return :busy unless wait

      say("  waiting on the #{repo} primary-checkout lock (another bin/release invocation is flipping it)…")
      f.flock(File::LOCK_EX)
    end
    yield
  end
end

# --- gate suite ruby pin: run the gate suite under CI's ruby -----------------
# The gates spawn `bin/rails test`; that suite's deploy-tooling meta-tests spawn
# bin/release / bin/dor-check subprocesses (`#!/usr/bin/env ruby`) that resolve
# `ruby` off PATH. On this gate host PATH's ruby is brew's (the app ruby, by
# design), whose gem home DIVERGES from mise's → a `Gem::Platform::JAVA already
# initialized` collision at subprocess boot → FALSE gate failures (CI, on mise
# 3.3.11, is green). So we run every gate subprocess — the suite, plus the bundle
# check/install + suite-ruby probe below — with mise's ruby bin dir leading PATH
# (an env overlay via `env:`, NOT an argv wrap, so command stubs keying on argv[0]
# still match): mise's `env ruby` wins the shebang lookup for the command AND its
# children, so local == CI. Degrades to the shell ruby (empty overlay) + a loud
# note, ONCE, when the pinned ruby isn't installed. See Release::GateRuby.
#
# Memoized so the note prints once per run, not once per repo. The empty-Hash
# overlay ({}) is a valid memo — an mise-less host still short-circuits after one note.
def gate_ruby_bin_dir
  return @gate_ruby_bin_dir if defined?(@gate_ruby_bin_dir)

  @gate_ruby_bin_dir = Release::GateRuby.resolve_ruby_bin_dir
  if @gate_ruby_bin_dir
    say("  gate ruby: mise #{Release::GateRuby::RUBY_PIN} (#{@gate_ruby_bin_dir}) leads PATH — matches CI")
  else
    say("  ⚠ gate ruby: mise #{Release::GateRuby::RUBY_PIN} not installed (#{Release::GateRuby.install_dir}) — " \
        "the gate suite runs under the shell ruby (#{RbConfig.ruby}). On a host whose `ruby` isn't mise this can " \
        "diverge from CI (deploy-tooling meta-tests hit a brew/mise gem-home split). Install it: " \
        "mise install ruby@#{Release::GateRuby::RUBY_PIN}")
  end
  @gate_ruby_bin_dir
end

# The FULL gate overlay for a repo: the mise ruby pin + the agent-session scrub +
# the gate's private TEST_DATABASE_URL (Release::GateEnv). Every gate subprocess —
# the suite, its bundle check/install, the db:test:prepare, and every grandchild
# they spawn — runs under this, so `local == CI` on all three axes. Memoized per
# repo (the ruby note prints once per run, from gate_ruby_bin_dir).
def gate_env(repo, role: "gate")
  @gate_env ||= {}
  @gate_env[[repo, role]] ||= Release::GateEnv.env(
    ruby_bin_dir: gate_ruby_bin_dir.to_s,
    # nil for a SQLite app (rolio): its test DB is a file INSIDE the workspace,
    # already private — and handing it a postgres URL would be a live trap.
    test_database_url: gate_database_url(repo, role: role)
  )
end

# --- suite-toolchain guard: bundle check/install under the SUITE ruby --------
# The gate boots its suite via the repo's binstubs (`#!/usr/bin/env ruby`), so
# the ruby that matters is the one `ruby` resolves to FROM THE REPO DIR — on
# this machine mise's pinned 3.3.11 (mise shims are directory-sensitive). The
# conductor/operator shell's own `bundle` can resolve a DIFFERENT ruby (brew's
# ruby@3.3) with a DIVERGENT gem home, so a shell-side `bundle check` LIES
# about the suite's env. ROOT CAUSE (rel-20260708-32701b): PR #456's
# studio-engine 0.11→0.12 bump was "satisfied" in brew's gem home but missing
# from mise's (the one the suite boots) → Bundler::GemNotFound at suite boot →
# the gate aborted TWICE with eject/revert regression guidance for a pure env
# problem. So the check/install run through the repo's `bin/bundle` binstub —
# the SAME env-resolved ruby that boots the suite — and a still-broken bundle
# aborts NAMING the toolchain divergence (env diagnosis), never the eject path.

# The bundle ARGV that resolves ruby EXACTLY like the suite's own binstubs — so
# the check reads the SAME gem home the suite boots against, for EVERY
# qa-registered app, not only ones carrying a checked-in bin/bundle. Two forms:
#   * ["bin/bundle"]        — the repo's binstub (`#!/usr/bin/env ruby` → the
#     env-resolved ruby, i.e. mise's directory pin); every Rails app checkout
#     ships one.
#   * ["ruby", "-S", "bundle"] — the fallback when a registered repo has NO
#     bin/bundle binstub. Run with chdir: path, the bare `ruby` ALSO resolves
#     through the mise shim's directory pin, so `-S bundle` runs the bundler
#     that ruby's OWN gem home ships. This is the fix carl + shannon flagged on
#     PR #480: the old bare-`bundle` fallback did a shell PATH lookup that
#     re-picked the conductor's ruby — the exact brew-vs-mise divergence the
#     guard exists to close, so no-binstub apps had NO real same-ruby coverage.
def suite_bundle_argv(path)
  File.exist?(File.join(path, "bin", "bundle")) ? ["bin/bundle"] : ["ruby", "-S", "bundle"]
end

# The ruby the suite will boot with — probed under the SAME gate env overlay the
# suite runs through (mise's pinned 3.3.11 when available; see gate_env), so
# the diagnosis below names the ruby the suite ACTUALLY boots, not the conductor
# shell's. Degrades to "unknown" (never aborts) on a failed probe: this string
# only enriches the mismatch diagnosis below.
def suite_ruby(repo, path)
  out, ok = sh("ruby", "-e", "print RbConfig.ruby", chdir: path, capture: true, env: gate_env(repo))
  ok && !out.strip.empty? ? out.strip : "unknown (ruby probe failed)"
end

# Verify the GATE WORKSPACE's bundle under the suite ruby BEFORE burning a
# multi-minute suite run: check → self-heal with install → abort as ENV.
# Runs in the isolated gate workspace, INSIDE the gate-workspace lock (another
# bin/release CAN reach that tree — see with_gate_workspace),
# AFTER it is pinned at the SHA under test, so it reads the exact Gemfile.lock the
# suite will load.
def ensure_suite_bundle!(repo, path, role: "gate")
  # No Gemfile in the release tree → nothing bundler-managed to verify
  # (self-gating, like an app with no qa_test_cmd).
  return unless File.exist?(File.join(path, "Gemfile"))

  # Verify under the gate-ruby env pin so the bundle is checked against the SAME
  # ruby the suite now boots (mise's pin) — otherwise a brew-satisfied /
  # mise-missing gem (the exact rel-20260708-32701b failure) would slip past the
  # check and only blow up mid-suite as a raw GemNotFound. argv is unchanged; the
  # pin rides as the env overlay (gate_env), so bin/bundle's shebang resolves
  # to mise.
  bundle = suite_bundle_argv(path)
  label  = bundle.join(" ")
  _, ok = sh(*bundle, "check", chdir: path, capture: true, env: gate_env(repo, role: role))
  return if ok

  say("  #{repo}: bundle unsatisfied under the suite ruby — #{label} install")
  _, ok = sh(*bundle, "install", chdir: path, env: gate_env(repo, role: role))
  return if ok

  boot_ruby = suite_ruby(repo, path)
  here_ruby = RbConfig.ruby
  divergence =
    if boot_ruby == here_ruby
      ""
    else
      " Toolchain mismatch: the suite boots #{boot_ruby} but this conductor runs #{here_ruby} — " \
      "divergent gem homes (brew-vs-mise), so a shell-side `bundle check` can lie about the suite's env."
    end
  abort!("#{role} workspace #{repo}: the bundle is unsatisfied under the SUITE ruby (#{boot_ruby}) and " \
         "`#{label} install` failed.#{divergence} This is an ENV/toolchain issue, NOT a release " \
         "regression — nothing to eject or revert. Fix the bundle (cd #{path} && #{label} install), " \
         "then re-run.")
end

# --- the isolated gate workspace --------------------------------------------
# Materialize the PRIVATE checkout a gate suite runs in, pinned (detached) at
# `sha`, and return its path. See Release::GateWorkspace for the full why; the
# short version: the gate used to run its multi-minute, LAZILY-AUTOLOADING suite
# on the SHARED primary, so any concurrent `git checkout` (another agent session,
# a hand-run command — the flock only binds other bin/release invocations) tore
# the code snapshot mid-run and the gate false-failed on green code. A worktree
# nobody else knows about cannot be flipped underneath the suite.
#
# The workspace PERSISTS between runs (reset --hard onto the new SHA) so the
# bundle and the test DB stay warm; it is rebuilt from scratch when it's missing
# or its git metadata went stale (e.g. someone removed it by hand).
def gate_workspace!(repo, sha, role: "gate")
  primary = repo_path(repo)
  path    = Release::GateWorkspace.path(primary, role: role)
  sha     = sha.to_s.strip
  abort!("#{role} #{repo}: no SHA to pin the isolated #{role} checkout at") if sha.empty?

  if File.exist?(File.join(path, ".git"))
    # Reuse: hard-reset the worktree onto the SHA under test. `reset --hard` (not
    # `checkout`) so a half-written tree from a killed run can't refuse the move;
    # detached HEAD means we never contend with the primary or an agent worktree
    # for a branch name.
    _, ok = sh("git", "-C", path, "reset", "--hard", sha, capture: true)
    unless ok
      say("  #{repo}: the #{role} workspace is stale — rebuilding it")
      sh("git", "-C", primary, "worktree", "remove", "--force", path, capture: true)
      sh("git", "-C", primary, "worktree", "prune", capture: true)
    end
  end

  unless File.exist?(File.join(path, ".git"))
    FileUtils.mkdir_p(File.dirname(path))
    # ALWAYS prune first: a workspace dir deleted by hand stays REGISTERED in
    # .git/worktrees, and `worktree add` then refuses the path as already in use.
    # Pruning drops those orphan registrations; it never touches a live worktree.
    sh("git", "-C", primary, "worktree", "prune", capture: true)
    _, ok = sh("git", "-C", primary, "worktree", "add", "--detach", path, sha, capture: true)
    unless ok
      abort!("#{role} #{repo}: could not create the isolated #{role} checkout at #{path} " \
             "(`git worktree add --detach #{short(sha)}`). This is an ENV issue, NOT a release " \
             "regression — nothing to eject or revert.")
    end
  end

  # Drop untracked leftovers from the previous SHA — a since-deleted test file
  # would otherwise still be collected by the runner and fail on a missing
  # constant. NO `-x`, so GITIGNORED paths are kept untouched by definition: the
  # warm caches this workspace exists to preserve (tmp/ bootsnap, node_modules,
  # app/assets/builds) and the .env below are all gitignored, so they survive
  # without needing `-e` excludes (which would be pure no-ops here).
  sh("git", "-C", path, "clean", "-fd", capture: true)

  # The suite reads dotenv's `.env`, which is GITIGNORED — so a virgin worktree
  # has none and the suite would boot with a different env than the primary's
  # (and than CI's, which supplies its own). bin/agent-worktree copies it into
  # every worktree it creates for exactly this reason; the gate workspace is no
  # different. MIRRORED (copy, else delete) rather than merely copied: if the
  # primary drops its .env, a stale copy here would otherwise outlive it forever
  # and the gate would keep certifying against an env nothing else has.
  env_source = File.join(primary, ".env")
  env_target = File.join(path, ".env")
  if File.exist?(env_source)
    FileUtils.cp(env_source, env_target)
  elsif File.exist?(env_target)
    FileUtils.rm_f(env_target)
  end

  # …but NEVER a worktree-style `.env.test.local`. dotenv auto-loads it for
  # RAILS_ENV=test and it sets TEST_DATABASE_URL — which the hub's database.yml
  # renders into an explicit `url:`, BEATING the gate's own DATABASE_URL overlay.
  # A stray one here would silently point the gate's suite (and its PURGING
  # db:test:prepare) at some worktree's database. The privacy assertion would
  # catch it and abort, but the gate should not depend on that: remove it.
  FileUtils.rm_f(File.join(path, ".env.test.local"))

  path
end

# Bring the gate workspace to a runnable state: the right gems, a test DB that is
# the GATE'S OWN (never the primary's shared `<app>_test`, which a concurrent suite
# can pollute mid-run — the third false-negative mechanism), and a PREPARED TEST ENV
# (`test:prepare` — the hook that builds gitignored assets). Both rake tasks in ONE
# boot: `db:test:prepare` is exactly what CI runs before its suite
# (.github/workflows/ci.yml), so the gate's setup and CI's stay one command.
#
# WHY `test:prepare` MUST BE THE GATE'S JOB and not Rails' (regression, 2026-07-12):
# Rails runs `test:prepare` itself — the hook `tailwindcss-rails` enhances to build
# the gitignored app/assets/builds/tailwind.css — ONLY when no argument looks like a
# PATH (railties test_command.rb: `run_prepare_task if args.none?(EXACT_TEST_ARGUMENT_PATTERN)`).
# `db:test:prepare` does NOT build it. The satellites register a PATH-ARG gate command
# (`bin/rails test test/integration`), and this workspace is made by `git worktree add
# --detach` — which does NOT copy gitignored files, so it is VIRGIN. Result: the asset
# was never built, every view-rendering test died with `The asset "tailwind.css" is not
# present in the asset pipeline`, and the gate went RED on GREEN code while handing out
# EJECT/REVERT guidance. (Driven on turf-monster: 86 runs, 43 errors, all that one.)
#
# So the GATE prepares the env, for ANY registered command shape — argless or path-arg.
# The alternative (rewrite each satellite's registry command to be argless) leaves the
# gate silently assuming a shape, which is a trap for the next person to register a
# lane — and is precisely how this bug got in. Preparing an argless lane's env too is
# idempotent; one code path beats a shape-aware one. (The ship role reuses this same
# prep — same reasoning, its own workspace.)
def prepare_gate_workspace!(repo, path, role: "gate")
  ensure_suite_bundle!(repo, path, role: role)

  # PROVE the DB is private BEFORE db:test:prepare — that task PURGES and reloads
  # the schema, so running it against a database we merely ASSUME is ours would
  # destroy a concurrent suite's data. Assert first, destroy second.
  assert_private_gate_db!(repo, path, role: role)

  out, ok = sh("bin/rails", "db:test:prepare", "test:prepare", chdir: path, capture: true, env: gate_env(repo, role: role))
  return if ok

  # An env-class abort — NEVER a red suite. A workspace that cannot build its assets
  # would fail every view-rendering test, and routing that into the "a regression is
  # riding origin/release" path is how a good PR (#498) nearly got ejected.
  #
  # But be honest in BOTH directions: `tailwindcss:build` also fails on a broken
  # stylesheet IN the release's own diff (a bad `@apply`, an unknown utility, a
  # malformed `@theme`). So this reports a LIKELIHOOD, not a verdict — and prints the
  # captured output, which is the only thing that actually tells the two apart.
  abort!("#{role} #{repo}: `bin/rails db:test:prepare test:prepare` failed in the isolated #{role} workspace " \
         "(#{path}, #{gate_database_url(repo, role: role) || 'file-backed test DB inside the workspace'}). The #{role} " \
         "never reached the suite, so this is NOT a release regression — nothing to eject or revert.\n" \
         "This is USUALLY an ENV gap (Postgres down; a missing asset toolchain) — BUT `test:prepare` " \
         "builds the app's stylesheet, so a BROKEN STYLESHEET in the release's own diff (a bad `@apply`, " \
         "an unknown utility, a malformed `@theme`) fails here too. Read the output below to tell which: " \
         "an env gap needs a fix on this host, a broken stylesheet needs a fix on `#{RELEASE_BRANCH}`.\n" \
         "#{indent_output(out)}")
end

# The tail of a failed command's captured output, indented so it reads as evidence
# under an abort rather than as more prose. Capped: the abort should show the operator
# the error, not replay an entire rake log at them.
def indent_output(out, lines: 25)
  text = out.to_s.strip
  return "  (no output captured)" if text.empty?

  kept = text.lines.last(lines).map { |l| "  #{l.rstrip}" }.join("\n")
  text.lines.size > lines ? "  … (#{text.lines.size - lines} earlier lines omitted)\n#{kept}" : kept
end

# Boot the app in the gate workspace and read back the database it ACTUALLY
# connects to in the test env — then REFUSE to run unless that DB is private to
# this gate (Release::GateWorkspace.private_db?).
#
# WHY, and why asserting the DB NAME STRING would not do: the "private test DB" is
# delivered by an ENV overlay, and an env var only lands if the app's
# config/database.yml actually reads it. `TEST_DATABASE_URL` is a HAND-ROLLED seam
# — the hub renders `url: <%= ENV["TEST_DATABASE_URL"] %>`; turf-monster does NOT
# (bare `database: turf_monster_test`). So for turf the overlay was silently
# INERT: the gate would have run — and `db:test:prepare` would have PURGED — the
# SHARED primary test DB. `DATABASE_URL` (a Rails builtin) now covers every app,
# but a guarantee that rests on every future app's config being right is a
# CONVENTION, not an invariant. This makes it an invariant: ask the booted app,
# and treat a shared DB as a hard abort — never a silent stomp.
def assert_private_gate_db!(repo, path, role: "gate")
  probe = 'print "GATEDB=#{ActiveRecord::Base.connection_db_config.database}"'
  out, ok = sh("bin/rails", "runner", probe, chdir: path, capture: true, env: gate_env(repo, role: role))
  # capture: true merges stderr (bundler/rubygems warnings), so pluck the token
  # instead of trusting the whole stream.
  resolved = out.to_s[/GATEDB=(.*)$/, 1].to_s.strip

  if !ok || resolved.empty?
    abort!("#{role} #{repo}: could not resolve the test database in the #{role} workspace (#{path}) — " \
           "`bin/rails runner` failed to boot. This is an ENV issue, NOT a release regression — " \
           "nothing to eject or revert.")
  end

  if Release::GateWorkspace.private_db?(resolved: resolved, repo: repo, workspace: path, role: role)
    say("  #{repo}: #{role} test DB #{resolved} (private to this #{role})")
    return
  end

  abort!("#{role} #{repo}: the suite would run against `#{resolved}` — a SHARED test database, NOT this " \
         "#{role}'s own (#{Release::GateWorkspace.test_database_name(repo, role: role)}). REFUSING: the next step " \
         "(`db:test:prepare`) PURGES it, which would destroy a concurrent suite's data, and a shared " \
         "DB re-opens the cross-talk the isolated workspace exists to close. CAUSE: #{repo}'s " \
         "config/database.yml is not honouring the workspace's DATABASE_URL/TEST_DATABASE_URL overlay for " \
         "the test env. This is an ENV/config issue, NOT a release regression — nothing to eject or revert.")
end

# The gate DB URL for this repo, or nil when its test DB is already file-backed
# INSIDE the workspace (SQLite — private by construction, and a postgres URL would
# be a live trap). Memoized: it reads the app's config/database.yml.
def gate_database_url(repo, role: "gate")
  @gate_database_url ||= {}
  key = [repo, role]
  return @gate_database_url[key] if @gate_database_url.key?(key)

  @gate_database_url[key] = Release::GateWorkspace.database_url_for(repo, repo_path(repo), role: role)
end

# --- system-tier browser guard ----------------------------------------------
# The hub's gate command carries the SYSTEM tier (`test:system` — see
# config/release_repos.yml), and system tests drive a real headless Chrome. On a
# host with no Chrome, Selenium fails INSIDE the suite: the runner exits non-zero
# with a driver error, which the gate would otherwise read as a RED SUITE and hand
# the operator eject/revert guidance — ejecting a perfectly good PR for a missing
# browser. That misattribution is the exact class of failure the isolated gate was
# rebuilt to end, so the browser is asserted UP FRONT and, when absent, fails in
# the ENV class with the same wording as the bundle/DB guards.
#
# Only asserted when the registered command actually runs the tier, so the
# integration-subset satellites never need a browser on the gate host.
#
# "owner/repo" for a repo's origin remote (the gh api path), or "" when the remote
# isn't GitHub — which CiStatus reads as no data, never as a red.
def repo_name_with_owner(repo)
  out, ok = sh("git", "-C", repo_path(repo), "remote", "get-url", "origin", capture: true)
  ok ? CiStatus.name_with_owner(out) : ""
end

# GitHub CI's verdict for ONE commit. RELEASE_CI_STATUS injects it (a bare token or
# a raw check-runs payload), so the meta-tests never touch the network — and an
# injected verdict skips the remote lookup entirely. Best-effort by construction:
# an auditor that RAISES must never fail a gate that passed.
def ci_verdict(repo, sha)
  injected = ENV["RELEASE_CI_STATUS"].to_s
  nwo = injected.empty? ? repo_name_with_owner(repo) : ""
  CiStatus.for_sha(nwo, sha, injected)
rescue StandardError => e
  { state: :unverified, reason: e.message.to_s[0, 140] }
end

# The G3 CREDIT probe (task dedupe-hub-release-suite): does this exact SHA already
# carry a COMPLETED green conclusion that the still-pending runs merely duplicate?
# Green-with-source when it does (CiStatus.credit_for_sha), nil for everything
# else. Same injection seam as ci_verdict; only consulted after
# fast_forward_promote? proved origin/#{RELEASE_BRANCH} IS the accepted head CI
# already built. Best-effort BY DESIGN and fail-CLOSED into the NORMAL path: nil —
# including any read/parse fault — sends the caller to poll_ci_verdict, so a probe
# that cannot see never certifies and never blocks.
def ci_credit_verdict(repo, sha)
  injected = ENV["RELEASE_CI_STATUS"].to_s
  nwo = injected.empty? ? repo_name_with_owner(repo) : ""
  CiStatus.credit_for_sha(nwo, sha, injected)
rescue StandardError
  nil
end

# The G3 TREE credit (task dedupe-hub-release-suite, rounds 2 + 3): the LIVE promote
# is a batch-PR `gh pr merge --merge`, which mints a NEW merge-commit SHA — so the
# same-SHA credit never fires on the normal path. But that merge commit usually
# SNAPSHOTS THE IDENTICAL TREE as the accepted head (true whenever `accepted` was not
# behind `release` — e.g. promotion #582: accepted 5b10402d / release cf93bab6 share
# tree 5b1c78e0), and GitHub CI checks out CONTENT, not history: a green earned on the
# accepted head certifies the exact tree the release merge re-runs. tree_identical_promote
# having proved the trees equal, this reads the accepted head's verdict and decides FOR
# THE IDENTICAL TREE:
#
#   green (already, or after the wait) -> CREDIT it; the duplicate release run is skipped
#                                         (the whole point of the dedupe).
#   pending (round 3 — the MEASURED bug on rel-20260720-1fc111) -> the accepted run is
#                                         IN FLIGHT. In a fast pipeline (review merges
#                                         into `accepted`, the sweep runs minutes later)
#                                         accepted CI is essentially NEVER settled at gate
#                                         time, so the completed-green credit systematically
#                                         MISSED precisely when the pipeline was moving —
#                                         and the hub ran the identical suite TWICE. So WAIT
#                                         on that in-flight run instead of falling through:
#                                         same wall-clock, the duplicate release run skipped.
#   red / none (missing or vanished) / unverified / unreadable / a wait that TIMES OUT ->
#                                         FALL THROUGH. No credit; return a DIAGNOSTIC and
#                                         let the caller poll the release SHA's OWN run
#                                         exactly as today. A red/missing accepted verdict
#                                         never credits and never shortcuts the fail-closed
#                                         poll (do not weaken any red/missing path).
#
# Returns {credit:, diagnostic:}: `credit` is a green ci Hash to gate on (skip the poll)
# or nil; `diagnostic` is the one-line reason the credit fired or did not — the gate now
# LOGS it, because this bug was invisible without hand-forensics. The accepted-head poll
# SHARES the caller's `deadline`, so a wait that times out and falls through does NOT then
# spend a SECOND full poll window on the release SHA. Best-effort: a probe that raises
# credits nothing and hands the caller back to the poll.
def tree_identical_ci_outcome(repo, release_sha, promote, deadline:)
  accepted_sha = promote[:accepted_sha]
  tree         = promote[:tree]
  interval     = ci_poll_interval
  waited       = false

  loop do
    ci = ci_verdict(repo, accepted_sha)
    state = ci.is_a?(Hash) ? ci[:state] : nil

    if ci_pass?(ci)
      return { credit: tree_credit_note(ci, release_sha, promote), diagnostic: nil }
    elsif state == :pending
      remaining = deadline - monotonic_s
      if remaining <= 0
        return { credit: nil,
                 diagnostic: "waited on the in-flight #{ACCEPTED_BRANCH} head #{short(accepted_sha)} " \
                             "(identical tree #{short(tree)}) but it did not conclude before the poll budget " \
                             "elapsed — polling #{RELEASE_BRANCH}'s own run" }
      end
      unless waited
        say("  #{repo}: #{ACCEPTED_BRANCH} head #{short(accepted_sha)} CI PENDING on the identical tree " \
            "#{short(tree)} — waiting on it instead of re-running the duplicate (up to ~#{remaining.to_i}s)")
      end
      waited = true
      sleep([interval, remaining].min)
    else
      # red / none (no run or vanished) / unverified / unreadable / no_pr / … — nothing to
      # credit and nothing to wait on. Fall through to the poll on the release SHA, which
      # OWNS the fail-closed verdict (a red aborts, a missing verdict holds then times out).
      return { credit: nil,
               diagnostic: "#{ACCEPTED_BRANCH} head #{short(accepted_sha)} gives no green to credit " \
                           "(#{ci_detail(ci)}) — polling #{RELEASE_BRANCH}'s own run" }
    end
  end
rescue StandardError => e
  { credit: nil, diagnostic: "tree-credit probe errored (#{e.message.to_s[0, 80]}) — polling #{RELEASE_BRANCH}'s own run" }
end

# The credited-green note for a tree-identical promote: names BOTH full SHAs + the shared
# tree so the audit trail shows precisely which accepted-head run vouched for which release
# merge commit. Carries CI's count when GitHub gave one.
def tree_credit_note(ci, release_sha, promote)
  { state: :green, count: ci[:count],
    credited: "tree-identical promote — #{ACCEPTED_BRANCH} head #{promote[:accepted_sha]} concluded green and " \
              "shares tree #{promote[:tree]} with #{RELEASE_BRANCH} #{release_sha}; the release-push run " \
              "re-executes an identical tree" }.compact
end

# Was the accepted→release promote a FAST-FORWARD — origin/#{RELEASE_BRANCH}
# resting on the SAME commit as origin/#{ACCEPTED_BRANCH}? Only then may the
# pre-QA gate credit an existing conclusion: the release tip IS the accepted head
# whose check-runs the PR/accepted seam already produced, so a green there proves
# THIS tree. (The batch-PR promote mints a merge commit — a NEW SHA with fresh
# check-runs — and never satisfies this.) The same-SHA discipline mirrors
# Release::ShipSequence.ship_gate_skip?, which self-skips G4 only against G3's
# record for the identical frozen SHA. An unresolvable accepted ref answers false
# (no credit, normal poll) — never an abort.
def fast_forward_promote?(path, release_sha)
  return false if release_sha.to_s.empty?

  out, ok = sh("git", "-C", path, "rev-parse", "origin/#{ACCEPTED_BRANCH}", capture: true)
  ok && out.strip == release_sha.to_s
end

# Did the batch-PR promote mint a merge commit whose TREE is the accepted head's
# tree — a different SHA snapshotting IDENTICAL content? That is the LIVE promote
# shape (`gh pr merge --merge`), and it holds whenever `accepted` was not behind
# `release` at merge time — the common case. It BREAKS whenever release carries
# commits accepted lacks: above all the consumer lock-bump commits `bin/release
# prepare` lands on `release` when a gem rides (publish-gems-before-qa, PR #588 —
# its step 4d commits the bump BEFORE pre_qa_gate resolves origin/release, so the
# SHA read here is the post-bump one and its tree no longer matches accepted's).
# Then this answers nil, the credit refuses, and the gate polls the post-bump SHA
# exactly as today — the cross-PR contract pinned on #588, asserted by the
# lock-bump interaction test in release_cli_test.
#
# Answers {accepted_sha:, tree:} ONLY when both trees resolve and match and the
# SHAs DIFFER (the same-SHA case is fast_forward_promote?'s, checked first).
# Every git fault — an unresolvable ref, a failed rev-parse — answers nil: no
# credit, normal poll, never an abort.
def tree_identical_promote(path, release_sha)
  return nil if release_sha.to_s.empty?

  accepted, ok = sh("git", "-C", path, "rev-parse", "origin/#{ACCEPTED_BRANCH}", capture: true)
  return nil unless ok

  accepted = accepted.strip
  return nil if accepted.empty? || accepted == release_sha.to_s

  release_tree, rel_ok = sh("git", "-C", path, "rev-parse", "#{release_sha}^{tree}", capture: true)
  accepted_tree, acc_ok = sh("git", "-C", path, "rev-parse", "#{accepted}^{tree}", capture: true)
  return nil unless rel_ok && acc_ok

  release_tree = release_tree.strip
  return nil if release_tree.empty? || release_tree != accepted_tree.strip

  { accepted_sha: accepted, tree: release_tree }
end

# The verdict pair, persisted: what CI said about the SHA the gate certified.
# `credited` names the credited source when the G3 gate credited an existing green
# conclusion instead of awaiting a duplicate run (ci_credit_verdict) — absent on
# every polled verdict, so the audit trail distinguishes the two.
def ci_gate_record(ci)
  record = { "state" => ci[:state].to_s }
  checks = (Array(ci[:failing]) + Array(ci[:pending])).map(&:to_s)
  record["checks"] = checks if checks.any?
  record["count"] = ci[:count].to_i if ci[:count]
  record["reason"] = ci[:reason].to_s if ci[:reason]
  record["credited"] = ci[:credited].to_s if ci[:credited]
  record
end

# THE GATE VERDICT, fail-CLOSED. Since DevOps v2 Phase 3 (promote-ci-to-gate-verdict)
# GitHub CI's conclusion for a SHA IS the G3/G4 verdict — no longer an auditor's
# footnote beside a local suite. So this passes on EXACTLY ONE state (:green) and
# fails closed on every other, red AND every no-data/pending state alike
# (none/pending/unverified/unreadable/no_pr/closed/merged) — there is deliberately
# NO second "unknown ⇒ pass" branch. A false green here would deploy an untested SHA
# to QA (G3) or ship it to production (G4), so an absent/unknown/red verdict must
# never read as certified. nil or a non-Hash is green-less ⇒ false.
def ci_pass?(ci)
  ci.is_a?(Hash) && ci[:state] == :green
end

# The poll DECISION for the pre-QA CI gate, factored PURE so it is unit-testable on
# its own — the CI-verdict analogue of Release::ShipSequence.run_watch_verdict. Given
# ONE ci_verdict Hash it says whether the gate can decide now or must keep polling:
#   :pass  — a GREEN conclusion certifies the SHA (the ONLY pass; ci_pass? green).
#   :abort — a TERMINAL non-green that waiting can NEVER turn green, so the gate stops
#            polling and fails closed at once:
#              * :red        — a regression is riding origin/#{RELEASE_BRANCH} (the
#                              eject/revert recovery), and
#              * :unreadable — a token/credential fault; polling a refused token only
#                              burns the whole timeout and never heals it mid-sweep, and
#              * :ci_less    — GitHub will run NO CI for this subject at all (a stale
#                              base it cannot compute a merge commit for), so there is
#                              no run to wait for; the remedy is a rebase, not patience.
#   :wait  — CI has NOT concluded yet: :none (no run registered), :pending (the push
#            run is still building — the raw queued/in_progress/waiting statuses all
#            fold to :pending), :unverified (a transient read miss), or anything else
#            not-yet-green. THIS is the just-merged-SHA case that used to abort the
#            sweep's first run: the caller HOLDS and re-reads until green, a terminal
#            abort, or the timeout — then it fails CLOSED on the last verdict read.
def ci_poll_action(ci)
  return :pass if ci_pass?(ci)

  state = ci.is_a?(Hash) ? ci[:state] : nil
  # :ci_less is DEFENSIVE here, not a fix for an observed release-path stall: the only
  # producer of :ci_less is CiStatus.combine, reached solely from evaluate(pr_url), and
  # this gate is SHA-addressed (for_sha) — so today it can arrive only via an injected
  # RELEASE_CI_STATUS token. Classified anyway, because if a future PR-scoped caller
  # does reach this poll, "GitHub will never run CI for this subject" is terminal for
  # the same reason :unreadable is: polling is the one thing that cannot help.
  return :abort if %i[red unreadable ci_less].include?(state)

  :wait
end

# A one-line CI verdict detail for a gate message: "state" or "state: reason".
def ci_detail(ci)
  state  = ci.is_a?(Hash) ? ci[:state].to_s : ""
  reason = ci.is_a?(Hash) ? ci[:reason].to_s : ""
  reason.empty? ? state : "#{state}: #{reason}"
end

# Stamp what the G3 pre-QA gate actually CERTIFIED for a repo: the SHA it ran on
# and the command it ran. G4's ship gate skips its own suite ONLY against this
# record (Release::ShipSequence.ship_gate_skip?) — never against the registry or
# the deployed SHA, neither of which proves a suite ever ran.
#
# It also carries the CI verdict for the same SHA (`ci: {state, checks}`, plus
# `count`/`reason` when GitHub gave them). Since DevOps v2 Phase 3 that verdict is no
# longer a footnote beside a local suite — it is what `ok` was DERIVED from
# (ci_pass?), so the pair is the whole audit: what CI concluded, and the gate result
# it produced.
#
# `ok` is now a PARAMETER (was hardcoded true): a GREEN CI records ok:true and lets
# G4 self-skip (ship_gate_skip?); a non-green G3 records ok:FALSE — a red gate must
# be recorded as failed, never silently un-stamped — and then aborts (fail-closed).
#
# Best-effort like the other record steps: a board hiccup must not fail a GREEN
# gate. A missing green record makes G4 re-derive the verdict from CI on the frozen
# SHA (never a self-skip), so the worst case of a lost stamp is a redundant CI read,
# never an unguarded ship.
def record_qa_gate(rel_slug, repo, sha, cmd, ci = nil, ok = true)
  return if rel_slug.to_s.empty? || DRY

  ci_arg = ci ? ", ci: #{ci_gate_record(ci).inspect}" : ""
  conductor(
    "r = Release.find_by(slug: #{rel_slug.to_s.inspect}); " \
    "Release::Conductor.record_qa_gate(release: r, repo: #{repo.to_s.inspect}, " \
    "sha: #{sha.to_s.inspect}, cmd: #{cmd.to_s.inspect}, ok: #{ok ? 'true' : 'false'}#{ci_arg}) if r; " \
    "puts({ qa_gate: #{repo.to_s.inspect} }.to_json)"
  )
rescue SystemExit, StandardError => e
  say("  ⚠ G3 certification not recorded for #{repo} (#{e.message}) — the ship gate will re-run the " \
      "suite on the frozen SHA rather than skip it (fail-open)")
end

# The G3 fail-closed abort text, chosen by the state the gate STOPPED on:
#   * :red        — a regression riding origin/#{RELEASE_BRANCH}: the eject/revert recovery.
#   * :unreadable — a credential/token fault the gate did NOT poll (a refused token never
#                   heals mid-sweep), so it aborts on the first read with the remedy.
#   * else        — a :pending/:none/:unverified verdict that never reached green before
#                   the poll timed out: let CI finish and re-run. None is ever a pass.
def pre_qa_ci_abort(repo, sha, ci)
  case ci[:state]
  when :red
    named = Array(ci[:failing]).join(", ")
    "pre-QA gate FAILED for #{repo}: GitHub CI called #{short(sha)} RED#{named.empty? ? '' : " (#{named})"} — a " \
      "regression is riding origin/#{RELEASE_BRANCH}. Identify the offending task, eject it " \
      "(`bin/release eject <task> --feedback \"…\"`), revert its merge commit on `#{RELEASE_BRANCH}` " \
      "(git revert -m 1 <merge-sha>; push), then re-run `bin/release prepare` — the sweep self-heals and the " \
      "REST of the RC rides on."
  when :unreadable
    # `cert_route: :retired` — STATED, never defaulted. The default is `true`, which
    # ends the shared remedy with "certify in full instead: bin/full-suite-check
    # <task>": an offer this gate cannot honour, and a placeholder it cannot fill.
    # Nothing in this file consults a local certification — ci_pass? (:green) is the
    # only pass above, and the suite was DEMOTED at Phase 3 — so a full cert run on
    # the operator's machine changes this verdict by exactly nothing, and G3 is
    # RELEASE-grain, so there is no `<task>` to name either.
    "pre-QA gate FAILED for #{repo}: GitHub CI is UNREADABLE for #{short(sha)} (#{ci_detail(ci)}). CI is the G3 " \
      "verdict now and FAILS CLOSED — an :unreadable verdict is a credential/token fault, NOT a missing or still-" \
      "running CI, so the gate does NOT poll it (a refused token never heals mid-sweep). " \
      "#{CiStatus.unreadable_remedy(repo_name_with_owner(repo), cause: ci[:cause], cert_route: :retired)}"
  else
    "pre-QA gate HELD for #{repo}: GitHub CI reached NO green verdict for #{short(sha)} (#{ci_detail(ci)}) before " \
      "the poll timed out. CI is the G3 verdict now and FAILS CLOSED on anything but green — a still-pending or " \
      "absent verdict never certifies a SHA. The gate POLLED origin/#{RELEASE_BRANCH} until ~#{ci_poll_timeout}s " \
      "elapsed; let CI conclude (or widen RELEASE_CI_POLL_TIMEOUT), then re-run `bin/release prepare`."
  end
end

# Seconds between CI verdict re-reads, and the outer wall-clock bound on the whole
# poll. The defaults cover a full release-CI run (the same suite PR CI runs) with
# headroom; BOTH are ENV-overridable so an operator can widen the window on a slow
# runner — or a test collapse it to a single read (timeout 0) — without touching code.
def ci_poll_interval = ENV.fetch("RELEASE_CI_POLL_INTERVAL", "15").to_i
def ci_poll_timeout  = ENV.fetch("RELEASE_CI_POLL_TIMEOUT", "1200").to_i

def monotonic_s = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# POLL GitHub CI's verdict for `sha` until it CONCLUDES, mirroring
# dispatch_and_watch / run_concluded_success?. Since DevOps v2 Phase 3 Slice 3 made CI
# the G3 verdict, reading it ONCE aborted every sweep's first run: the sweep merges to
# origin/#{RELEASE_BRANCH}, CI STARTS on that fresh SHA, and the gate read it :pending and
# held — forcing a manual "wait for release CI to conclude, then re-run bin/release
# prepare" round-trip (observed @ 015241f and @ f05cdf5). So a :wait verdict now HOLDS
# and re-reads every ci_poll_interval seconds until CI concludes (:green/:red) or
# ci_poll_timeout elapses, instead of failing closed on the first pending read.
#
# STILL FAIL-CLOSED, exactly as the single read was (ci_poll_action owns the split): a
# :red or :unreadable verdict returns AT ONCE — a regression riding the branch, or a
# token fault polling cannot fix — and a timeout returns the LAST still-pending verdict,
# never a fabricated green. The caller runs ci_pass? on the returned Hash, so ONLY a
# genuine :green certifies; every other outcome aborts the gate.
def poll_ci_verdict(repo, sha, deadline: monotonic_s + ci_poll_timeout)
  timeout    = ci_poll_timeout
  interval   = ci_poll_interval
  last_state = nil
  ci = nil
  loop do
    ci = ci_verdict(repo, sha)
    return ci unless ci_poll_action(ci) == :wait

    remaining = deadline - monotonic_s
    if remaining <= 0
      say("  #{repo}: CI still #{ci[:state]} for #{short(sha)} after ~#{timeout}s — poll timed out, failing closed")
      return ci
    end
    if ci[:state] != last_state
      say("  #{repo}: CI #{ci[:state].to_s.upcase} for #{short(sha)} — holding for it to conclude " \
          "(re-reading every #{interval}s, up to ~#{timeout}s; set RELEASE_CI_POLL_TIMEOUT to widen)")
    end
    last_state = ci[:state]
    sleep([interval, remaining].min)
  end
end

# Resolve GitHub CI's verdict for `repo`'s origin/#{RELEASE_BRANCH} `sha`,
# applying the G3 dedupe credits (fast-forward / tree-identical) and otherwise
# polling — the repo-generic core the APP and SELF-GATED-GEM gate lanes share.
# It is repo-generic BY DESIGN, which is exactly why a self-gated gem can reuse
# it: both an app and a gem promote accepted→release via a batch PR, and that
# promote PR is a `pull_request` event that BOTH ci.yml (hub) and engine-ci.yml
# (gem) run — so the accepted head carries a green, and the tree-identical credit
# certifies the identical release tree the same way for either kind (there is no
# `push:[release]` CI run for either; the credit is the whole mechanism).
# Returns [ci_hash, credited_bool] — the caller runs ci_pass? on ci and prints
# `(credited)` from the flag. Behavior-identical to the block it was lifted from,
# so the app gate is byte-for-byte the same verdict.
def resolve_release_ci_verdict(repo, path, sha)
  # ONE shared poll budget: the tree credit may spend part of it WAITING on the
  # in-flight accepted run, and a wait that times out then falls through must not
  # spend a SECOND full window polling the release SHA.
  deadline = monotonic_s + ci_poll_timeout
  credit = nil
  diagnostic = nil
  if fast_forward_promote?(path, sha)
    credit = ci_credit_verdict(repo, sha)
    if credit
      credit[:credited] = "#{credit[:credited]}; fast-forward promote — " \
                          "origin/#{RELEASE_BRANCH} is the #{ACCEPTED_BRANCH} head CI already built"
    else
      diagnostic = "origin/#{RELEASE_BRANCH} IS the #{ACCEPTED_BRANCH} head (fast-forward) but it carries no " \
                   "completed green to credit yet — polling its own run"
    end
  elsif (promote = tree_identical_promote(path, sha))
    # SAME-TREE: credit an accepted-head green, or WAIT on it while it is in flight —
    # the round-3 fix (credit-waits-accepted-ci). Whatever the outcome, it LOGS why.
    outcome = tree_identical_ci_outcome(repo, sha, promote, deadline: deadline)
    credit = outcome[:credit]
    diagnostic = outcome[:diagnostic]
  else
    # No credit is even possible: the release tip is neither the accepted head (fast-forward)
    # nor a tree-identical promote of it (a diverged tree — e.g. a consumer lock-bump commit
    # riding #{RELEASE_BRANCH}). Say so, rather than falling through silently — every non-credit
    # now names its condition (a mismatch this gate used to leave to hand-forensics).
    diagnostic = "#{short(sha)} shares neither SHA nor tree with the #{ACCEPTED_BRANCH} head — no credit " \
                 "possible; polling its own run"
  end
  say("  #{repo}: #{diagnostic}") if diagnostic && !credit
  if credit
    say("  #{repo}: crediting the existing green conclusion for #{short(sha)} — no duplicate run awaited " \
        "(#{credit[:credited]})")
  end

  # THE VERDICT: GitHub CI's conclusion for the SHA under test, POLLED until it
  # concludes (poll_ci_verdict) and fail-CLOSED via ci_pass? — only :green certifies.
  # A red (a regression riding origin/#{RELEASE_BRANCH}) or an :unreadable token fault
  # aborts at once; a still-:pending/:none/:unverified verdict is HELD — a just-merged
  # SHA's CI is still building — until it goes green, red, or the poll times out. This
  # replaces the single read that aborted every sweep's first run on a pending CI. The
  # poll shares the gate's deadline (see above) so the tree-credit wait + this poll
  # never exceed one window together.
  ci = credit || poll_ci_verdict(repo, sha, deadline: deadline)
  [ci, !credit.nil?]
end

# The pre-QA gate (G3 candidate). `app_groups` gate on their registered
# qa_test_cmd's CI; `gem_groups` (keyword — old positional callers keep the
# (app_groups, rel_slug) arity) adds the SELF-GATED-GEM pass for a GEM-ONLY
# release, so a gem publishing as its own candidate gets a first-class G3 verdict
# on its own suite's CI. A gem RIDING an app (a consumer bundles it) is unchanged:
# the gem pass runs ONLY when there is no app member, so that release is QA'd
# through its consumer's bumped lock exactly as before.
def pre_qa_gate(app_groups, rel_slug = nil, gem_groups: [])
  say("")
  # The banner names what THIS step does now (DevOps v2 Phase 3): it reads GitHub
  # CI's verdict for each app's origin/#{RELEASE_BRANCH} SHA. The local suite that
  # used to run in an isolated gate workspace is DEMOTED — CI is the verdict — so the
  # registered qa_test_cmd is still RECORDED for the G4 drift check, just not executed.
  step("pre-QA gate: GitHub CI's verdict for each app's origin/#{RELEASE_BRANCH} SHA " \
       "(before any QA deploy)")
  app_groups.each do |group|
    repo = group["repo"]
    cmd  = qa_gate_cmd(repo)
    if cmd.empty?
      say("  #{repo}: no qa_test_cmd registered — self-gates (suite runs at ship / its own deploy); skip")
      next
    end
    # Validate the registry command even though the suite is DEMOTED (Phase 3): a
    # malformed value must still abort a preview, and it is recorded for the G4 drift
    # check below, so it may not be garbage. test_cmd_argv aborts on an unbalanced quote.
    test_cmd_argv(cmd)
    if DRY
      say("  [dry-run] pre-QA gate #{repo}: GitHub CI verdict for origin/#{RELEASE_BRANCH} " \
          "(#{cmd} recorded for the G4 drift check, not run)")
      next
    end

    path = repo_path(repo)
    abort!("app repo not found at #{path} — clone it as a sibling at the projects root") unless Dir.exist?(path)
    sh("git", "-C", path, "fetch", "origin", "--quiet")
    out, ok = sh("git", "-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}", capture: true)
    abort!("could not resolve origin/#{RELEASE_BRANCH} in #{repo} for the pre-QA gate — fetch, then re-run") unless ok
    sha = out.strip

    # DevOps v2 Phase 3+4: the pre-QA suite no longer runs on the conductor's machine.
    # GitHub CI's verdict for this exact origin/#{RELEASE_BRANCH} SHA IS the gate now
    # (poll_ci_verdict -> ci_pass?), so the whole local-cert flakiness class (a lazily-
    # autoloaded suite torn by a concurrent checkout) retired with it.
    #
    # G3 DEDUPE (task dedupe-hub-release-suite): the hub registers the same full
    # suite at the accepted seam (the batch PR's pull_request run on the accepted
    # head) and again on the release push (the promote's merge commit), so the
    # verdict resolution below credits the IDENTICAL TREE already earned instead of
    # re-running it — fail-closed into the poll on any non-credit. Repo-generic; see
    # resolve_release_ci_verdict.
    ci, credited = resolve_release_ci_verdict(repo, path, sha)
    ok = ci_pass?(ci)
    step("pre-QA gate #{repo}: GitHub CI #{ci[:state].to_s.upcase}#{credited ? ' (credited)' : ''} @ #{short(sha)} " \
         "(#{cmd} recorded for the G4 drift check, not run here)")

    # Certify — the ONLY evidence G4 accepts for skipping its own gate. Recorded for
    # GREEN and non-green alike: a red G3 records ok:FALSE (it must not silently skip
    # recording), carrying CI's verdict for the audit trail.
    record_qa_gate(rel_slug, repo, sha, cmd, ci, ok)
    next if ok

    abort!(pre_qa_ci_abort(repo, sha, ci))
  end

  # SELF-GATED GEM pass — a GEM-ONLY release's own G3 verdict. A self-gated gem
  # (registry `release_check`) publishing as its own candidate has no consuming
  # app to gate it, so it gets a first-class G3 verdict here on its OWN suite's
  # CI, resolved by the SAME repo-generic path the apps use
  # (resolve_release_ci_verdict): the gem's accepted→release promote PR is a
  # `pull_request` event engine-ci.yml runs, so the accepted-head green credits
  # the identical release tree — there is no `push:[release]` CI run to poll.
  #
  # SCOPED TO app_groups.empty? — a GEM-ONLY release. A gem RIDING an app is
  # QA'd through its consumer's bumped lock (the app gate above), and this pass
  # must not add a new gate to that path, so the gem-riding-app release behaves
  # exactly as before. Non-self-gated gems never reach here (a non-self-gated
  # gem-only candidate already aborted at validate_gems_for_qa).
  if app_groups.empty?
    gem_groups.each do |group|
      repo = group["repo"]
      next unless self_gated_gem?(repo)

      cmd = gem_meta_for(repo)["release_check"].to_s
      # Validate the registry command the same way the app lane does (a malformed
      # value aborts a preview); the gem's own suite ran it in CI already.
      test_cmd_argv(cmd)
      if DRY
        say("  [dry-run] pre-QA gate #{repo} (self-gated gem): GitHub CI verdict for origin/#{RELEASE_BRANCH} " \
            "(#{cmd} is the gem's own release gate — greened in its CI, recorded here)")
        next
      end

      path = repo_path(repo)
      abort!("gem repo not found at #{path} — clone it as a sibling at the projects root") unless Dir.exist?(path)
      sh("git", "-C", path, "fetch", "origin", "--quiet")
      out, ok = sh("git", "-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}", capture: true)
      abort!("could not resolve origin/#{RELEASE_BRANCH} in #{repo} for the pre-QA gate — fetch, then re-run") unless ok
      sha = out.strip

      ci, credited = resolve_release_ci_verdict(repo, path, sha)
      ok = ci_pass?(ci)
      step("pre-QA gate #{repo} (self-gated gem): GitHub CI #{ci[:state].to_s.upcase}#{credited ? ' (credited)' : ''} " \
           "@ #{short(sha)} (#{cmd} greened the gem in its own CI)")

      record_qa_gate(rel_slug, repo, sha, cmd, ci, ok)
      next if ok

      abort!(pre_qa_ci_abort(repo, sha, ci))
    end
  end
end

def prepare
  task_slugs = opt_values("--task")
  slug = opt_value("--slug")
  # `--expedite` is `deploy-with-task`'s promote-time GUARD (step 3), and it is
  # the one that actually protects production. `status --clean-only` answers "is
  # it safe to START?" 15-25 minutes earlier, before review and CI; by the time
  # the promote runs, `bin/review-autopilot` may have merged another task onto
  # `accepted`. The promote is the irreversible moment — it lands ALL of
  # `accepted` on `release`, whatever `--task` curation says about MEMBERSHIP —
  # so the ladder has to be re-proven clean HERE, seconds before it, in the same
  # command that does the promoting. Opt-in: a bare `prepare` (the normal
  # full-queue sweep, where promoting all of `accepted` is exactly the intent) is
  # completely unaffected.
  expedite = Release::Cli.take_flag(ARGV, "--expedite")
  if expedite && task_slugs.size != 1
    abort!("--expedite guards a SINGLE expedited task — pass exactly one `--task <slug>` " \
           "(got #{task_slugs.size}). Nothing was merged or deployed.")
  end

  say("Prepare release — Avi qa-deploy (self-healing)#{PROD ? ' (PROD board)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # LOCAL PRESENCE — the twin of the board `assembler` claim taken further down, and it
  # answers a DIFFERENT question. The board claim says "a release is live" to every
  # machine; this says "a sweep is consuming THIS machine" to the peer standing next to
  # it, which is the only fact that decides whether that peer may launch a suite. Cost #3
  # of docs/agents/system/agent-presence.md is what its absence bought: a 45-minute
  # full-suite run SIGTERMed at its 2700s ceiling, 11% complete, killed by a sweep no
  # status command reported. Opened HERE — before the first gh/git/board call — so the
  # claim covers the WHOLE run, not just its suite. Best-effort and non-fatal.
  ReleasePresence.open!(kind: ReleasePresence::SWEEP, root: File.expand_path("..", __dir__),
                        lane: "release:prepare", session_id: conductor_session_id)
  # On the prod default a non-dry prepare fires a REAL accepted→release batch merge +
  # a REAL `bin/qa-server deploy`, so gate it like `ship` does. confirm returns true
  # under --yes (hands-off) and --dry-run (previews nothing-executed).
  return unless confirm("Prepare the current release — sweep reviewed work onto `#{RELEASE_BRANCH}` + deploy QA?")

  # Deploy-lane narration: Avi owns the whole middle — sweep, QA deploy, and
  # the QA-green flip. Open a role activity so the heartbeat attributes this phase to
  # him (matching the board's stage timeline). Best-effort — see the narrate
  # helpers. `avi_span` gates the close in the rescue so an abort BEFORE this
  # point never emits a stray `end`.
  open_role_span("avi", "sweep → deploy RC to QA")
  avi_span = true

  # 1. DETECT (a read — runs even in --dry-run): the reviewed queue + assembled
  #    stragglers with their PR/merged state, the review-gate screen, and the
  #    current release. `--task` narrows the sweep (operator curation).
  step("record (read-only): Release::Conductor.sweep_candidates + screen")
  detect = conductor(sweep_detect_ruby(task_slugs), read_only: true)
  cands  = detect["tasks"] || []
  active = detect["release"]

  # 1b. --task is operator CURATION: every NAMED slug must survive detection. A
  #     typo'd or ineligible slug (not `reviewed`, not an `assembled` straggler)
  #     is filtered out BEFORE the screen ever sees it, so without this check it
  #     would drop silently and the run could still end "✓" — a false success.
  #     Fail loudly BEFORE anything merges or deploys.
  if task_slugs.any?
    missing = task_slugs - cands.map { |c| c["slug"] }
    if missing.any?
      abort!("--task slug(s) not sweepable: #{missing.join(', ')} — not in the reviewed queue or the " \
             "assembled stragglers (typo? not yet `reviewed`?). Nothing was merged or deployed; " \
             "fix the slug (or review the task), then re-run `bin/release prepare`.")
    end
  end

  # 2. IDEMPOTENT NO-OP: nothing to sweep and nothing in flight → report + stop
  #    (exit 0), never fabricate work. An ACTIVE release with no new candidates
  #    falls through — that's the self-healing re-run (deploy + flip what's
  #    already swept).
  if cands.empty? && active.nil?
    say("")
    say("✓ Nothing to prepare — no reviewed work, no assembled stragglers, no active release (idempotent no-op).")
    close_role_span("qa-deploy no-op — nothing to prepare")
    return
  end
  cands.each do |c|
    at = c["merged"].to_s.empty? ? "" : " · merged: #{c['merged']}"
    say("  sweep #{c['slug']} (#{c['stage']}#{at}) · #{sweep_line_repos(c)} · #{c['pr_url']}")
  end

  # 2b. Review gate over the sweep list — defense-in-depth. Auto-detected
  #     candidates are sweepable by construction (reviewed/assembled), and a
  #     --task slug that ISN'T a candidate already failed loudly at 1b (the
  #     screen only ever sees surviving slugs, so it can't catch a dropped one).
  #     prepare has NO --override — use `bin/release merge --override` for an
  #     audited bypass, then re-run prepare.
  enforce_review_gate!(detect["screen"] || {}) if cands.any?

  # 2c. ASSEMBLER CLAIM — take the per-RELEASE `assembler` lock (release-conductor-claims)
  #     BEFORE the irreversible promote below, so two concurrent qa-release sessions
  #     can't both sweep/promote and race the candidate N-behind (the parallel-conductor
  #     race). This replaces the old `bin/devops-shift acquire steffon` shift lease: the
  #     lock is on the release record, which turns over each release, so a stale claim
  #     can never strand the whole lane.
  #
  #     For an ACTIVE/named release the slug is known here (its own slug / --slug), so we
  #     claim it directly. For a BRAND-NEW release the slug does NOT exist yet — the
  #     promote CREATES the release — so we claim the reserved `__forming__` SENTINEL
  #     instead. Either way, EXCLUSIVE OWNERSHIP IS HELD BEFORE THE PROMOTE: two
  #     concurrent fresh sessions contend on the sentinel's composite-unique CAS, and the
  #     loser stands down (exit 10) rather than double-promoting. A telemetry hiccup fails
  #     open. The sentinel is handed off to the real claim (and freed) once `rel_slug`
  #     resolves below, so ownership is continuous across the promote.
  stood_down = -> { close_role_span("stood down — another session is assembling this release") }
  assembler_slug = ((active && active["slug"]) || slug).to_s.strip
  assembler_slug = ReleaseClaimCli::FORMING_SLUG if assembler_slug.empty?
  acquire_conductor_claim!("assembler", assembler_slug, span_close: stood_down)

  # 3. SWEEP PLAN (pure: Release::SweepPlan): partition the candidates into the
  #    members to RECORD onto the RC (code on accepted/release/main) and the HELD
  #    anomalies (a `reviewed` member with no merged stamp — review's feat→accepted
  #    merge never landed). Unlike the explicit `merge` command, a held member here
  #    is WARNED + left `reviewed` (it self-heals on re-review) — the self-healing
  #    sweep never aborts on it.
  plan = Release::SweepPlan.compute(cands)

  # 3a. MULTI-REPO COVERAGE REFUSAL — fail-closed, and the earliest seam that can
  #     see it: nothing has been claimed, promoted, recorded or deployed yet. A
  #     candidate naming several repos with a PR url for only some of them is the
  #     2026-08-13 shape: the promote below derives its repos from the candidates,
  #     so the repo with no PR simply never appears, and every stage after it —
  #     pre-QA gate, QA deploy, ship — inherits the omission and stamps the task
  #     shipped anyway. Refusing here is what turns that silent half-ship into a
  #     stop, at the first prepare, with the repo named.
  if plan["blocked"].any?
    named = plan["blocked"].map { |row| "#{row['slug']} (names #{row['repos'].join(', ')}; no PR url for #{row['missing'].join(', ')})" }
    abort!("sweep refused #{plan['blocked'].size} multi-repo task(s) with an incomplete PR record: " \
           "#{named.join('; ')}. Promoting now would carry only the repo(s) with a PR and still stamp " \
           "the task assembled/shipped for the rest — the 2026-08-13 half-ship. NOTHING was promoted, " \
           "recorded or deployed. Record the missing PR " \
           "(`bin/task update <slug> --pr-url-for <repo>=<url>`), or drop the repo from the task's " \
           "devops.repositories if it carries no work, then re-run `bin/release prepare`.")
  end

  held = plan["held"]
  held.each do |s|
    say("  ⚠ #{s}: `reviewed` but merged:\"\" — review never landed its feat PR on `#{ACCEPTED_BRANCH}`; " \
        "left `reviewed` (re-review to heal)")
  end
  plan["record"].reject { |row| row["merged"] == ACCEPTED_MERGED }.each do |row|
    step("skip promote for #{row['slug']} — already merged: #{row['merged']} (crash recovery); membership still records")
  end

  # 4. PROMOTE accepted → release (the accepted-ladder's SECOND rung). Review already
  #    merged each feat PR into `accepted` (merged:"accepted"), so the sweep no longer
  #    merges N per-task feat PRs — it lands ALL of `accepted` onto `release` via ONE
  #    batch PR per repo (a single-repo release = exactly one PR). Git-FIRST (the
  #    irreversible step); the record write follows. Idempotent + fail-closed:
  #    accepted level with release → skip the PR but still record + deploy; a promote
  #    conflict / missing checkout ABORTS (members stay `reviewed` for a clean re-run).
  # 4a. EXPEDITE GUARD (opt-in, `deploy-with-task` step 3). The promote below
  #     lands the WHOLE `accepted` branch on `release` — `--task` curates which
  #     tasks are RECORDED as members, never which COMMITS ride along — so an
  #     expedite is only safe if `accepted` still carries nothing but the
  #     expedited task. Re-derive the same verdict `status --clean-only` printed
  #     at step 1, now, immediately before the irreversible git op: that is the
  #     only placement that survives the review window, during which
  #     `bin/review-autopilot` can merge another task onto `accepted`. Fail-closed
  #     and BEFORE the promote, so a refusal leaves members `reviewed` and the
  #     branches untouched.
  if expedite
    step("guard: re-prove the `accepted → release → main` ladder carries only #{task_slugs.first}")
    guard = ladder_clean_verdict(expedited: task_slugs.first)
    say("")
    say(guard["message"])
    unless guard["clean"] || DRY
      abort!("--expedite refused: the ladder no longer carries only `#{task_slugs.first}` — " \
             "promoting now would ship the work listed above. NOTHING was promoted, recorded, or " \
             "deployed. Ship the whole release instead: run the `Alex Heartbeat` `full-cycle` launcher.")
    end
  end

  # Promote EVERY repo each landed candidate names (`repos`), not just its primary.
  # This one line is where turf-monster was lost on 2026-08-13: it read `c["repo"]`,
  # the singular Task#release_repo, so a task carrying [mcritchie-studio,
  # turf-monster] promoted the hub alone — and nothing downstream could tell the
  # difference between "turf wasn't in this release" and "turf was silently dropped".
  # NOTE: this file is Rails-FREE (it runs standalone, and only require_relative's
  # the pure Release::* modules) — no ActiveSupport, so no `.presence`.
  promote_repos = cands.select { |c| c["merged"].to_s == ACCEPTED_MERGED }
                       .flat_map { |c| (c["repos"].is_a?(Array) && !c["repos"].empty?) ? c["repos"] : [ c["repo"] ] }
                       .map(&:to_s).reject(&:empty?).uniq

  # 4a-bis. ACCEPTED-COVERAGE HARD STOP — the git read gets a vote on the promote
  #     list, immediately before the irreversible op.
  #
  #     `bin/release status` ALREADY knew about 2026-08-13. It printed, in plain
  #     words: "the two `accepted` signals DISAGREE: git says `accepted` carries
  #     commits (turf-monster (+2)) … Trust the git read and reconcile the board."
  #     NO GATE CONSULTED IT — so three prepares ran straight past a repo whose work
  #     sat on `accepted`, and the fourth still did not QA it.
  #
  #     The same measurement (Release::CleanCheck.ahead_repos, via
  #     ladder_clean_verdict — one call, both rungs, no new mechanism) is consulted
  #     HERE and compared against what this run is about to promote. A repo whose
  #     `accepted` is ahead of `release` and is NOT in the promote list is a repo
  #     this sweep leaves behind while stamping its tasks assembled and shipped.
  #
  #     PER-REPO rather than the coarse existential sentence `status` prints,
  #     deliberately: the coarse form compares "any repo ahead" against "any task
  #     stamped merged:accepted", so it goes quiet the moment ANY other task on the
  #     board carries that stamp — which is most of the time, and was true during
  #     the incident's later runs. This form names the repo, and fires every time.
  #
  #     Scoped to runs that actually promote: a self-healing re-run with nothing to
  #     sweep carries nothing onto `release`, so it has no promote list to be wrong
  #     about (and `bin/release status` remains the read for that state).
  #
  #     AND SCOPED TO THIS RUN'S OWN MEMBERS — the git read is ecosystem-wide and
  #     the promote list is not, so comparing them raw asks a global question of a
  #     local answer. `ladder_ahead_states` spans every registered repo, while
  #     `--task` deliberately NARROWS the sweep: Avi's documented per-app hold-back
  #     (qa-release.md, "sweep only the included apps") is exactly a --task run, and
  #     `included_in_release` is only a board marker the release path never reads,
  #     so --task is the ONLY mechanism that shapes a hold-back. A held-back repo is
  #     ahead BY CONSTRUCTION — that is what holding it back means — so the raw
  #     comparison refused every hold-back sweep, with no --override and an abort
  #     message whose two suggested causes did not apply and whose prescribed fixes
  #     would have undone the hold-back.
  #
  #     So the guard judges only the repos THIS RUN'S MEMBERS NAME (`member_repos`,
  #     over plan["sweep"] — the rows about to be recorded). That keeps the whole
  #     bite: 2026-08-13's candidate NAMED turf-monster, so turf is in scope and a
  #     promote list without it still aborts. What it drops is the part that was
  #     never this guard's business — a repo no member of this release mentions.
  #     A HELD row (merged:"") names nothing here on purpose: it is not being
  #     recorded, so it has no claim on the promote list. `bin/release status`
  #     remains the ecosystem-wide read.
  member_repos = cands.select { |c| plan["sweep"].include?(c["slug"]) }
                      .flat_map { |c| (c["repos"].is_a?(Array) && !c["repos"].empty?) ? c["repos"] : [ c["repo"] ] }
                      .map(&:to_s).reject(&:empty?).uniq
  if promote_repos.any? && !DRY
    step("guard: every repo this release's members name whose `accepted` is ahead must ride this promote")
    coverage = ladder_clean_verdict
    ahead = (coverage["accepted_ahead_repos"] || []).map { |r| r["repo"].to_s }.reject(&:empty?)
    uncovered = (ahead & member_repos) - promote_repos
    if uncovered.any?
      abort!("prepare refused — git says `accepted` carries commits for #{uncovered.join(', ')}, a repo this " \
             "release's members NAME, but this sweep would promote only #{promote_repos.join(', ')}. That " \
             "work would stay on `accepted` while the tasks carrying it are stamped assembled and shipped " \
             "— the 2026-08-13 half-ship, where turf-monster sat +2 and production ran the unpatched code. " \
             "NOTHING was promoted, recorded or deployed. A member names #{uncovered.join(', ')} but is not " \
             "landing it: either its `merged` stamp says its code is already past `accepted` when that " \
             "repo's is not (a PARTIAL earlier promote — land it with `bin/release merge <slug>`, which " \
             "now fans out over every repo a task names), or the task should not name " \
             "#{uncovered.join(', ')} at all (drop it from devops.repositories). `bin/release status` " \
             "prints both signals side by side. NOTE: a repo NO member names is out of scope here by " \
             "design — that is what keeps a `--task` hold-back sweep legal.")
    end
  end

  promote_accepted_to_release!(promote_repos, label: slug) if promote_repos.any?

  # 5. Record membership for every member whose code is on accepted/release/main
  #    (plan["sweep"]) + the repo plan, in ONE `heroku run`. A `held` member is NOT
  #    in plan["sweep"], so it is never recorded onto the RC. Suppressed under
  #    --dry-run (the promotion previewed above; nothing recorded).
  landed = plan["sweep"]
  left_reviewed = held
  result = {}
  if landed.any? && !DRY
    step("record: Release::Conductor.sweep! ×#{landed.size} + repo plan in ONE run (#{landed.join(', ')})")
    result = conductor(batch_sweep_with_plan_ruby(landed, slug))
  end

  # 4b. No sweep write happened (dry-run, or a pure re-run with nothing new) →
  #     read the current release's plan read-only so the deploy half still runs.
  if (result["repos"] || []).empty?
    step("record (read-only): Release::Conductor.repo_plan(Release.current)")
    result = conductor(
      "r = Release.current; " \
      "puts((r ? { slug: r.slug, state: r.state, branch: r.branch, repos: Release::Conductor.repo_plan(r) } : {}).to_json)",
      read_only: true
    )
  end

  rel_slug = result["slug"] || slug || "rel-pending"

  # ASSEMBLER CLAIM HAND-OFF — the INSTANT a REAL release exists (result["slug"]
  # present, not the "rel-pending" fallback), take the real (rel_slug, assembler) claim
  # and free the forming sentinel — BEFORE the repos.empty? check, the "release …"
  # print, and ALL rel_slug work. This closes the fresh-create window carl flagged: as
  # soon as rel_slug names a real release, a session keying on rel_slug DIRECTLY is
  # excluded (the differently-keyed __forming__ sentinel didn't exclude it). Ordering is
  # load-bearing: acquire the real claim FIRST, then release the sentinel, so ownership
  # is CONTINUOUS across the hand-off. For the active/named path the real claim was
  # already taken at 2c (idempotent no-op) and no sentinel was held (the release-by-slug
  # is a no-op). Guarded to a real created slug so the "rel-pending" fallback (a dry
  # sweep with nothing recorded) never claims a bogus slug.
  if result["slug"].to_s.strip != ""
    acquire_conductor_claim!("assembler", rel_slug,
                             span_close: -> { close_role_span("stood down — another session is assembling this release") })
    release_conductor_claim!(role: "assembler", slug: ReleaseClaimCli::FORMING_SLUG)
  end

  repos = result["repos"] || []
  if repos.empty?
    # Nothing to deploy → free any claim held (the forming sentinel from 2c, or the
    # real claim just taken above) before the early return so it never leaks.
    release_conductor_claim!
    if DRY && cands.any?
      say("")
      say("✓ Dry run: #{cands.size} task(s) would sweep onto a fresh candidate — the repo plan (and the QA deploy preview) " \
          "becomes available once the sweep records; re-run without --dry-run.")
      close_role_span("qa-deploy dry-run — sweep previewed")
      return
    end
    say("")
    say("✓ Nothing to deploy — the release has no members yet" \
        "#{left_reviewed.any? ? " (#{left_reviewed.join(', ')} left `reviewed` — no code on `#{ACCEPTED_BRANCH}`)" : ''}.")
    close_role_span("qa-deploy no-op — no members to deploy")
    return
  end

  app_groups = repos.select { |g| g["kind"] == "app" }
  gem_groups = repos.select { |g| g["kind"] == "gem" }
  say("  release #{rel_slug} (#{result['state']}) · #{repos.size} repo(s): #{app_groups.size} app, #{gem_groups.size} gem")

  # 3b. STALE-TREE GATE — the deploy half's entry condition, and the one check
  #     that makes this command's own `✓ Assembled` a true sentence. The promote
  #     at step 4 is driven by BOARD STAMPS, so a commit that reached `accepted`
  #     with no task behind it is invisible to it and the promote is skipped;
  #     everything below then succeeds on the OLD tree and prints ✓ over it
  #     (measured live 2026-08-11 — see verify_release_carries_accepted!).
  #     So ASSERT THE EFFECT here, from git, over exactly the repos about to be
  #     deployed: `release` must already carry `accepted`. Placed FIRST in the
  #     deploy half on purpose — above the merge-forward, above the IRREVERSIBLE
  #     gem publish, above the gate and every QA deploy — so a refusal costs
  #     nothing and leaves member stages untouched for a clean re-run. A normal
  #     sweep just promoted, so it measures level and rides straight through.
  verify_release_carries_accepted!(repos, rel_slug, result["state"])

  record_release_event(rel_slug, "assemble_release", "started")

  # 4c. MERGE-FORWARD — `release` must contain `main` BEFORE the gate reads it,
  #     and BEFORE the irreversible gem publish (4d). The gate half: this used
  #     to live inside the QA-deploy loop (step 6), which put it AFTER the gate —
  #     when it did land it moved origin/release PAST the SHA the gate had just
  #     certified, so QA deployed a tree G3 never verified and ship's frozen SHA
  #     was one the gate never saw. Running it here means the gate, QA, and prod
  #     all read the same post-merge tree. The publish half: GEM repos keep the
  #     same release branch + ship workspace, so they ride the guard too — and
  #     they must ride it FIRST, because a gem published from a PRE-merge
  #     release tree would lack a main hotfix FOREVER (a RubyGems version can
  #     never be re-pushed, and ship's publish is an idempotent verify that
  #     skips an already-live version) — and a merge conflict in ANY repo now
  #     aborts with ZERO gems published.
  merge_forward_release_branches(app_groups, gem_groups: gem_groups)

  # 4d. PRODUCER-FIRST GEM PUBLISH + CONSUMER LOCK BUMP — AFTER the merge-forward
  #     (4c), so every gem publishes the post-merge release tree, and BEFORE the
  #     pre-QA gate and any QA deploy (publish-gems-before-qa). TWO PHASES,
  #     because a RubyGems push can never be re-pushed: phase 1 VALIDATES every
  #     swept gem (fail-closed fetch, version parses, stranded-work guard, a
  #     swept consumer declares it) and aborts on ANY failure with ZERO gems
  #     published; only then does phase 2 publish and commit each consumer's
  #     Gemfile.lock bump onto its release branch. Ordering is load-bearing:
  #     the lock commits land BEFORE pre_qa_gate resolves origin/release, so
  #     the CI verdict targets the post-bump SHA, QA bundles the new lock, and
  #     prod ships the exact tree QA tested. Ship's publish stays as the
  #     idempotent verify (already-live → skip).
  #
  #     PHASE 0 leads: ALLOCATE each swept gem's version from its members and
  #     commit it (with its Gemfile.lock) onto origin/release. It runs above
  #     phase 1 because phase 1's stranded-work guard is the BACKSTOP for
  #     allocation not happening — the guard stays armed and still aborts when
  #     the version has not advanced, it just has nothing left to catch on the
  #     happy path. Ordering is the same fail-closed rule as everything else
  #     here: the version must be settled and pushed BEFORE the first
  #     irreversible `gem push`, never after.
  allocate_gem_versions!(gem_groups)
  gem_plan = validate_gems_for_qa(gem_groups, app_groups)
  # BIND the publish map. It is the authoritative record of what each gem actually
  # published (or was already live at), and the member-provenance line below needs
  # it — that line used to re-derive the version from the primary checkout, which
  # sits on `main` and is a release behind by construction. See
  # Release::GemVersion.reported_version.
  published_gems = publish_gems_for_qa(gem_plan)
  bump_consumer_locks_for_qa(app_groups, published_gems)

  # 5. PRE-QA GATE — the prepare-owned test tier on origin/release, BEFORE any
  #    QA deploy. A regression aborts with eject guidance while every member is
  #    still `reviewed`; the rest of the RC rides on the re-run.
  #
  #    G3 CANDIDATE opens HERE (replacing the old review_tests started/completed
  #    bracket — prepare co-opting that stage bracket is what made the Tested
  #    column start AFTER Assembled on /deployments). The gate window spans the
  #    pre-QA suite, the QA deploys + boot smokes, and the post-deploy hooks;
  #    every test SOP inside it rides the close via the run_test_scope collector.
  #    Closed success beside qa_green!, failed at the boot-failure branch, and
  #    failed by the SystemExit wrapper below when anything in the window aborts.
  record_gate_open(rel_slug, "g3_candidate", actor: "avi")
  g3_gate = :open
  pre_qa_gate(app_groups, rel_slug, gem_groups: gem_groups)

  # 5b. Record the Avi assembled QA intent for every member so /deployments shows
  #     him QA-ing the RC live the moment the deploy half starts — the Deploy mirror
  #     of bin/reviewer-select's review intent (no more hand-run `bin/task intent
  #     --to assembled --actor avi`). Swept members are still `reviewed` (the
  #     flip waits for QA-green), so record_deploy_intents! records the plain
  #     toward-`assembled` intent, superseded when qa_green! lands the flip; an
  #     already-`assembled` member (straggler/re-run) gets the qa-marked
  #     toward-`shipped` intent instead (see Release::Conductor#record_qa_intent).
  #     Append-only + idempotent. A board WRITE → suppressed in --dry-run
  #     (conductor prints the plan). BEST-EFFORT (record_deploy_intent): this
  #     cosmetic ticker write must never abort the QA deploy on a transient
  #     prod-board failure — it warns and continues.
  step("record: Avi assembled QA intent (live crew ticker)")
  record_deploy_intent(
    "Avi assembled QA intent",
    "r = Release.current; n = Release::Conductor.record_deploy_intents!(r, to_stage: 'assembled', actor: 'avi'); " \
    "puts({ intent: 'assembled', actor: 'avi', members: n.size }.to_json)"
  )

  # 6. Per-app: deploy origin/release to that app's QA. The branch is populated
  #    by PR merges, so there's NO branch-cut/member-merge here — and no
  #    merge-forward either: that moved to step 4c, above the gate, so this loop
  #    deploys exactly the tree the gate certified. Gems are NOT deployed — they
  #    ride the release as a record, already published at 4d above (ship
  #    re-verifies idempotently).
  deployed = [] # [{repo, qa_app, qa_url, sha, ok}]
  qa_shas = {}  # { repo => sha } deployed to QA
  qa_smoke_started = false
  record_release_event(rel_slug, "deploy_qa", "started") if app_groups.any?
  repos.each do |group|
    repo    = group["repo"]
    members = group["members"] || []

    if group["kind"] == "gem"
      members.each do |m|
        member_version = Release::GemVersion.reported_version(published_gems, repo, gem_version_local(repo))
        step("gem member #{m['slug']} (#{repo} #{member_version}) — rides the release; published BEFORE this QA deploy (step 4d), QA'd via its consuming app's bumped lock")
      end
      # Freeze the gem's origin/release HEAD into qa_shas, exactly like apps do at
      # the bottom of this loop. Without an entry the gem gets NO frozen SHA, so
      # at ship time frozen_sha_for falls back to resolving origin/release HEAD —
      # which can DRIFT if a PR merges into the gem's release branch after prepare.
      # Recording it here ships the exact commit QA froze. (Gems aren't QA-
      # deployed, but their release branch is still the source ship publishes from;
      # the frozen_sha_for fallback stays as defense for un-prepared repos.)
      sha = ""
      path = repo_path(repo)
      if !DRY && Dir.exist?(path)
        sh("git", "-C", path, "fetch", "origin", "--quiet")
        out, ok = sh("git", "-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}", capture: true)
        sha = out.strip if ok
      end
      qa_shas[repo] = sha
      next
    end

    # --- app repo: all branch ops happen in THAT repo via `git -C path` ---
    path   = repo_path(repo)
    qa_app = group["qa_app"]

    # Eligibility: a repo can be a registered app (passes validate_members!) yet
    # have NO QA env (tax-studio, chain-ops). Warn + skip its QA deploy rather
    # than firing a `bin/qa-server deploy` that has no target — it still ships at
    # `ship` via its prod_deploy adapter; it just can't be QA-reviewed here.
    unless qa_registered?(qa_app)
      say("")
      say("  ⚠ #{repo}: no QA environment registered (qa_environments.yml) — skipping QA deploy")
      next
    end

    say("")
    step("repo #{repo} → #{RELEASE_BRANCH} · #{members.size} member(s) · QA #{qa_app}")
    abort!("app repo not found at #{path} — clone it as a sibling at the projects root") unless DRY || Dir.exist?(path)

    # a. fetch the repo's origin. (The merge-forward guard that used to sit here
    #    ran AFTER the pre-QA gate and inside the primary checkout; it now runs
    #    at step 4c, before the gate, in a detached workspace —
    #    merge_forward_release_branches.)
    sh("git", "-C", path, "fetch", "origin", "--quiet")

    # c. deploy origin/release to the repo's own QA app. The github_actions apps
    #    (the hub — DevOps v2 Phase 2) dispatch ONE qa-deploy.yml run at the swept
    #    release tip: qa-deploy.yml is workflow_dispatch, not push:[release], so the
    #    N PR-merge pushes of the sweep never fire N QA deploys — the conductor
    #    fires exactly one. Every other app keeps the local qa-server force-push
    #    (qa-server resolves origin/release in the sibling and pushes its SHA — no
    #    local checkout/branch-cut). The /up boot poll (c2) gates the flip EITHER way.
    if (group["prod_deploy"] || {})["strategy"].to_s == "github_actions"
      tip = ""
      unless DRY
        out, tip_ok = sh("git", "-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}", capture: true)
        tip = out.strip if tip_ok
        abort!("could not resolve origin/#{RELEASE_BRANCH} in #{repo} for the QA deploy dispatch") if tip.empty?
      end
      step("qa deploy: gh workflow run qa-deploy.yml -f sha=#{short(tip)} — GitHub Actions QA deploy of the release tip")
      qa_ok = dispatch_and_watch("qa-deploy.yml", { "sha" => tip }, chdir: path)
    else
      step("qa deploy: bin/qa-server deploy #{qa_app} origin/#{RELEASE_BRANCH} --yes")
      _, qa_ok = sh("bin/qa-server", "deploy", qa_app, "origin/#{RELEASE_BRANCH}", "--yes", capture: false)
    end

    # c2. wait for the dyno to actually BOOT before treating the deploy as done.
    #     `bin/qa-server deploy` returns once the push is accepted, but a slow dyno
    #     may still be booting — recording QA + assembling against it is the
    #     /up-smoke race that left the RC stuck `assembling`. Poll <qa_url>/up
    #     until 200 (or timeout); a non-200 marks the app NOT ok so step 4 leaves
    #     the release `assembling` for a clean re-run.
    if qa_ok && !qa_smoke_started
      record_release_event(rel_slug, "qa_smoke", "started")
      qa_smoke_started = true
    end
    # Route the /up boot poll through the telemetry wrapper (one scope, many
    # curls → block returns [out, ok]). `.last` keeps qa_ok a BOOLEAN (the raw
    # [out, ok] array is always truthy and would poison the ok flag downstream);
    # `&&=` still short-circuits, so a failed earlier step never runs the poll.
    qa_ok &&= run_test_scope("qa_up_smoke", repo: qa_app) do
      booted = wait_for_boot(qa_url_for(qa_app))
      [booted ? "200" : "", booted]
    end.last

    # d. capture the deployed SHA (origin/release after any merge-forward).
    sha = ""
    unless DRY
      out, ok = sh("git", "-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}", capture: true)
      sha = out.strip if ok
    end
    qa_shas[repo] = sha
    deployed << { "repo" => repo, "qa_app" => qa_app, "qa_url" => qa_url_for(qa_app),
                  "sha" => sha, "ok" => (qa_ok || DRY) }
  end

  # 7. Record the QA URL + per-repo deployed SHAs on the release (the board's
  #    current-release header links straight to QA; the SHAs give provenance).
  #    WRITES → suppressed in dry-run; recorded BEFORE the QA-green flip (step 8)
  #    but AFTER wait_for_boot, so the board links a booted QA dyno. This records
  #    the URL ONLY — the stage-advancing `deploy_qa:completed` stamp ("Live on
  #    QA" green) is deferred to qa_green! (step 8b) so it lands atomic with the
  #    member flip, never a step early.
  primary = deployed.find { |d| d["repo"] == APP } || deployed.first
  if primary && !primary["qa_url"].empty?
    step("record: qa_url #{primary['qa_url']}")
    conductor("Release::Conductor.record_qa_url(release: Release.current, qa_url: #{primary['qa_url'].inspect}); puts({qa_url: #{primary['qa_url'].inspect}}.to_json)")
  end
  unless qa_shas.empty?
    step("record: qa_shas #{qa_shas.map { |r, s| "#{r}@#{s.to_s[0, 7]}" }.join(', ')}")
    conductor("Release::Conductor.record_qa_shas(release: Release.current, shas: #{qa_shas.inspect}); puts({qa_shas: true}.to_json)")
  end

  # 8. QA-GREEN FLIP — the flip lands only AFTER every QA app booted
  #    (wait_for_boot returned 200) AND every post-deploy hook ran green:
  #    Release::Conductor.qa_green! flips the swept members `reviewed →
  #    assembled` (merged stays "release") and the RC assembling→assembled. A QA
  #    failure flips NOTHING — members stay `reviewed` (+ merged "release"), the
  #    RC stays `assembling`, and the next self-healing run picks them back up
  #    (skipping the already-done merges). WRITE → suppressed in dry-run.
  boot_failures = deployed.reject { |d| d["ok"] }
  qa_green = boot_failures.empty?
  # Close the qa_smoke release event opened above (it recorded `started` but never
  # a terminal status — the started-without-completed gap). `qa_smoke` IS a
  # whitelisted ReleaseEvent::STEP, so this closes the existing pair, not a new
  # step. Fired ONCE (matching the single `started`), guarded on qa_smoke_started.
  # `failed` lands here on a boot failure; `completed` is DEFERRED into the else
  # branch — it must land only after QA is ACTUALLY green through the BLOCKING
  # post-deploy hook, never a premature green (same reason 8b defers
  # deploy_qa:completed to the flip — "never a step early"). Best-effort.
  if boot_failures.any?
    record_release_event(rel_slug, "qa_smoke", "failed",
                         message: "#{boot_failures.size} app(s) never returned /up 200") if qa_smoke_started
    # G3 verdict: the candidate FAILED this attempt (a QA app never booted).
    # Attempt-aware — the re-run opens attempt n+1, so repeated QA failures
    # become visible signal instead of collapsing into one silent window.
    record_gate_close(rel_slug, "g3_candidate", false,
                      metadata: { "reason" => "#{boot_failures.size} app(s) never returned /up 200" })
    g3_gate = :closed
    say("")
    say("  ⚠ #{boot_failures.size} app(s) never returned /up 200 — QA is NOT green: leaving the release `assembling`,")
    say("    swept members stay `reviewed` (merged: release). Re-run `bin/release prepare` once they boot")
    say("    (the sweep skips the already-merged PRs): #{boot_failures.map { |d| d['repo'] }.join(', ')}")
  else
    # 8a. Post-deploy hooks on the booted QA app(s): run each member's declared
    #     post_deploy_cmd against its QA app, record the [post-deploy] outcome, and
    #     ABORT prepare on a non-zero exit (so the RC stays `assembling`, members
    #     stay `reviewed`, re-run resumes). dry-run prints the plan; nothing executes.
    run_post_deploy(repos, target: :qa)

    # QA is ACTUALLY green now — every app booted (/up 200) AND the blocking
    # post-deploy hook passed (run_post_deploy abort!s on failure, so REACHING
    # this line means it's green). Only NOW close qa_smoke `completed`; a
    # post-deploy abort must never leave a premature `completed` behind.
    record_release_event(rel_slug, "qa_smoke", "completed",
                         message: "all QA apps booted (/up 200) + post-deploy hooks green") if qa_smoke_started

    # 8b. QA is green — flip the swept members + the RC, and stamp Live-on-QA
    #     (deploy_qa:completed) in the SAME conductor call so the /deployments
    #     tracker reaches "Live on QA" atomic with the flip (never a step early).
    #     The reviewed→assembled usage (captured locally; the flip runs on prod,
    #     transcript-less) rides each member's assembled TaskEvent.
    unless DRY
      flip_slugs = cands.select { |c| c["stage"] == "reviewed" }.map { |c| c["slug"] }
      usage = move_usage_map(flip_slugs)
      live_qa_url = primary && !primary["qa_url"].to_s.empty? ? primary["qa_url"] : nil
      step("record: Release::Conductor.qa_green!(Release.current) — QA green, flip swept members `assembled` + stamp Live-on-QA")
      conductor(
        "r = Release.current; " \
        "Release::Conductor.qa_green!(r, usage_by_slug: #{usage.inspect}, qa_url: #{live_qa_url.inspect}) if r; " \
        "puts({ state: r&.reload&.state }.to_json)"
      )
    end

    # G3 verdict: the candidate PASSED — every app booted (/up 200), the
    # blocking post-deploy hooks ran green, and the QA-green flip landed.
    # Close the attempt with the collected SOPs (pre_qa_gate / qa_up_smoke /
    # qa_post_deploy). Best-effort, like every gate write.
    record_gate_close(rel_slug, "g3_candidate", true)
    g3_gate = :closed
  end

  # 9. Per-repo summary of what was swept + QA'd.
  say("")
  say("✓ #{qa_green ? 'Assembled' : 'Prepared (NOT assembled — QA not green)'} #{rel_slug}#{DRY ? ' (DRY RUN — nothing executed)' : ''}.")
  gem_groups.each do |g|
    g["members"].each { |m| say("  gem #{g['repo']} (#{m['slug']}) — rides the release; published before QA (ship re-verifies idempotently).") }
  end
  deployed.each do |d|
    loc = d["qa_url"].empty? ? d["qa_app"] : d["qa_url"]
    at  = d["sha"].to_s.empty? ? "" : " @ #{d['sha'][0, 7]}"
    if d["ok"]
      say("  app #{d['repo']} → #{RELEASE_BRANCH} → QA #{loc}#{at}")
    else
      say("  app #{d['repo']} → #{RELEASE_BRANCH} — QA deploy FAILED, retry `bin/qa-server deploy #{d['qa_app']} origin/#{RELEASE_BRANCH}`")
    end
  end
  say("  #{left_reviewed.join(', ')} left `reviewed` — no code on `#{ACCEPTED_BRANCH}` (re-review to heal), or `bin/task block` them.") if left_reviewed.any?
  # The Steffon handoff exists only on QA-green — a NOT-green prepare hands off to
  # NOBODY (the step-8 warning already said: re-run prepare once QA boots).
  if qa_green
    say("")
    say("  Review the QA app(s) above, then hand off to Steffon: `bin/release ship`.")
  end
  # Drop the assembler claim (clean completion, whether or not QA went green) so the
  # next conductor can pick this release up immediately; a crash self-heals via the
  # lease TTL. Best-effort — see release_conductor_claim!.
  release_conductor_claim!
  close_role_span(qa_green ? "assembled #{rel_slug} → QA" : "prepared #{rel_slug} — QA not green, members stay reviewed")
rescue SystemExit
  # G3 close-fail wrapper: an abort INSIDE the gate window (a red pre_qa_gate,
  # a QA-deploy/checkout abort, a post-deploy hook failure) IS the gate failing —
  # close the attempt `failed` with whatever SOPs were collected. record_gate_close
  # is itself best-effort (it can never raise), and the `raise` below ALWAYS
  # re-raises: the gate write must never mask the abort.
  record_gate_close(rel_slug, "g3_candidate", false, metadata: { "aborted" => true }) if g3_gate == :open
  # Drop the assembler claim on an aborted prepare too (best-effort): a re-run is
  # same-instance and simply re-acquires (renews), so freeing it now — rather than
  # waiting out the TTL — lets a different conductor take over sooner if this session
  # is truly done. A stand-down abort never acquired, so this is a no-op there.
  release_conductor_claim!
  # An abort mid-prepare closes the Steffon activity with the abort outcome
  # (best-effort) before re-raising, so the heartbeat activity resolves instead of
  # hanging open.
  close_role_span("prepare aborted before QA-green") if avi_span
  # WHAT IS ALREADY IRREVERSIBLE — the prepare-side twin of the ship's
  # "Already live this run" (@ship_live). By the time a mid-sweep abort fires, the
  # batch accepted→release PRs may be merged, earlier repos may have merged their
  # merge-forward onto origin/release, gems may be PUBLISHED to RubyGems (which
  # can never be un-pushed), and consumer lock bumps may be committed onto
  # origin/release. Without this the abort message
  # is the operator's last word, and a message that says "nothing was committed"
  # invites a "just reset release" cleanup that would drop the batch merge and
  # strand a published gem. Ship prints this and prepare did not; now both do.
  if @prepare_live&.any?
    warn("")
    warn("✗ Prepare ABORTED partway — these are ALREADY DONE and are NOT undone by the abort:")
    @prepare_live.each { |line| warn("    ✓ #{line}") }
    warn("  Re-run `bin/release prepare` to resume: published gems skip, merges are idempotent,")
    warn("  and an already-correct lock commits nothing. Do NOT reset `release` to undo them.")
  end
  raise
ensure
  # A raw StandardError (not a SystemExit) raised after the assembler claim was
  # acquired would escape BOTH the success path and the rescue-SystemExit arm above with
  # the agent-anchored renewer still holding the claim. The ensure frees it on EVERY
  # exit — idempotent with the releases above (a no-op once nothing is held), matching
  # finalize's begin/ensure posture. Crash/SIGKILL still relies on the TTL.
  release_conductor_claim!
  # The LOCAL presence claim closes exactly where the BOARD claim does. THIS IS AN
  # OPTIMIZATION, NOT THE CORRECTNESS STORY: a SIGKILLed conductor runs no ensure and
  # leaves its claim file behind ON PURPOSE, and the reader grades it a corpse against the
  # process table on the very next read — no timeout to elapse, no renewal to miss, so the
  # wedge window is ZERO rather than one TTL. Clearing here just keeps the report tidy.
  ReleasePresence.close!
end

# --- eject (block-on-regression) ---------------------------------------------
# Pull ONE offending task off the release candidate — the pre-QA gate (or QA
# itself) caught a regression it owns. The record side
# (Release::Conductor.eject!) detaches it (release_slug + merged cleared) and
# blocks it for rework with the feedback as a qa_feedback note; the REST of the
# RC rides on untouched. The git side stays with the operator (printed guidance):
# revert the member's merge commit on `release` — never a force-push — then
# re-run `bin/release prepare`.
def eject
  feedback = opt_value("--feedback")
  slug = Release::Cli.positional_slugs(ARGV).first
  abort!("usage: bin/release eject <task-slug> [--feedback \"…\"]") unless slug

  say("Eject #{slug} from the release train#{PROD ? ' (PROD board)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # Resolve the ACTIVE release with a MINIMAL, STABLE read (just slug/state) so we can
  # claim its assembler lane BEFORE the membership mutation. A read — runs even under
  # --dry-run.
  step("record (read-only): resolve the active release for the assembler claim")
  active = conductor(
    "r = Release.current; puts((r ? { slug: r.slug, state: r.state } : {}).to_json)",
    read_only: true
  )

  # ASSEMBLER CLAIM — eject! MUTATES release-candidate membership (release_slug + `merged`
  # cleared: a member is detached off the RC), the SAME assembler-lane write `prepare`/`merge`
  # guard. A concurrent eject DURING a `prepare` sweep would race that membership write, so
  # take the SAME per-release `assembler` claim first: the active release's real slug when one
  # exists (contending with prepare/merge's active-path claim), else the `__forming__`
  # sentinel (a fresh-create prepare's guard). A live DIFFERENT holder stands us down
  # (acquire_conductor_claim! aborts). eject is a discrete op (like merge/finalize), so the
  # begin/ensure frees the claim on EVERY exit. Inert under --dry-run (conductor_claim no-ops).
  assembler_slug = (active && active["slug"]).to_s.strip
  assembler_slug = ReleaseClaimCli::FORMING_SLUG if assembler_slug.empty?
  acquire_conductor_claim!("assembler", assembler_slug)
  begin
    # Free-text feedback is safe to embed via .inspect: the whole snippet rides
    # `heroku run` as a url-safe Base64 blob (conductor_payload), so quotes/parens
    # survive the remote re-quoting intact.
    feedback_ruby = feedback.to_s.empty? ? "nil" : feedback.inspect
    step("record: Release::Conductor.eject!(#{slug}) — detach + block for rework")
    result = conductor(
      "t = Task.find_by!(slug: #{slug.inspect}); " \
      "Release::Conductor.eject!(t, feedback: #{feedback_ruby}); " \
      "puts({ slug: t.slug, stage: t.reload.stage, merged: t.merged }.to_json)"
    )
    say("  #{slug} → blocked (rework)#{feedback ? ' — feedback noted' : ''}") unless DRY || result.empty?

    say("")
    say("Now unwind its code from the branch (the record is detached; git is yours):")
    say("  1. find its merge commit:  git log origin/#{RELEASE_BRANCH} --oneline --merges | head")
    say("  2. revert it (never force-push): git revert -m 1 <merge-sha> && git push origin #{RELEASE_BRANCH}")
    say("  3. re-run `bin/release prepare` — the sweep self-heals and the REST of the RC rides on.")
  ensure
    release_conductor_claim!
  end
end

# --- ship (multi-repo, producer-first) -------------------------------------
# "Run Deployment": promote the assembled RC to production across EVERY member
# repo in a producer-first, hub-before-satellites loop —
#   gems (publish to RubyGems) → auto-re-pin consumers → hub app → satellites.
# It ships the QA-FROZEN SHA per repo (the commit QA deployed, from
# release.metadata["qa_shas"]) — NOT origin/release HEAD — so a PR merged after
# `prepare` can never ride out un-QA'd. ONE confirm authorizes the whole train
# (turf included; its own bin/deploy keeps smoke + rollback), so there is no
# per-satellite re-prompt. Partial-ship: abort on the first failure; ship!/notes
# run LAST so a partial leaves the record `assembled` (recoverable) and a re-run
# is idempotent (published gems skip, ff no-ops, re-pins are idempotent).
#
# bin/release does only git/gh/gem/bundle I/O here; the string/version/ordering
# DECISIONS live in the unit-tested Release::ShipSequence (+ GemfileRepin).

# --- the clean-LADDER GUARD (`deploy-with-task` runs this FIRST) ------------
# `bin/release status` reports whether the whole `accepted → release → main`
# ladder is clean — i.e. whether the only thing an expedite would carry to prod
# is ONE named task, or whether OTHER work is already parked on a rung beneath
# it. Avi's `deploy-with-task` act runs `bin/release status --clean-only --task
# <slug>`; `--clean-only` turns the report into a GATE — it exits nonzero
# (aborting the expedite) on a dirty ladder, after printing the refusal + the
# `full-cycle` offer. `--task` names the expedited task so the guard does not
# refuse on the operator's OWN work when the act is re-run after review already
# merged it onto `accepted`.
#
# BOTH rungs, because the expedite walks both: the sweep promotes ALL of
# `accepted` onto `release`, and the ship fast-forwards `release → main`.
# Reading only the release rung is what let a reviewed-but-unswept task ride to
# production with the guard fully green. The pure verdict + message live in
# Release::CleanCheck; this owns only the live reads.
def status
  clean_only = Release::Cli.take_flag(ARGV, "--clean-only")
  expedited  = opt_value("--task").to_s.strip

  say("Release status#{PROD ? ' (PROD board)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  verdict = ladder_clean_verdict(expedited: expedited, report_release: true)
  say("")
  say(verdict["message"])

  # --clean-only is the GATE: a dirty ladder aborts the expedite (non-zero exit)
  # so `deploy-with-task` refuses instead of dragging the pending work to prod.
  # A --dry-run previews the verdict without aborting (nothing is executed).
  if clean_only && !verdict["clean"] && !DRY
    abort!("the `accepted → release → main` ladder is not clean — `deploy-with-task` refused " \
           "(ship the whole release with the `full-cycle` launcher)")
  end
end

# Gather BOTH clean-ladder signals on BOTH rungs and return the CleanCheck
# verdict. Split out of `status` because it is consulted at TWO moments, and the
# second one is the one that actually protects production:
#   * `status --clean-only` at the START of `deploy-with-task` (is it safe to
#     begin?), and
#   * `prepare --expedite` immediately BEFORE the promote (is it STILL safe?).
# The gap between them is 15-25 minutes of review and CI, and `bin/review-autopilot`
# can land another task on `accepted` inside it. A guard consulted only at the
# start would be answering a question about a world that has since changed, so
# the same verdict has to be re-derivable in one call at the mutating seam.
#
# `expedited` is the slug the act is expediting (from `--task`), excluded from
# the accepted rung's board signal — see Release::CleanCheck for what that
# exclusion does and does not prove.
# PURE. The repos whose `accepted` verdict is an ASSERTED failure, out of the probe
# Ci::BranchGate returns.
#
# ONLY :red and :conflicted count. :pending and :none are deliberately NOT failures
# here — a sweep routinely races a run it can wait for, or credit downstream at the
# pre-QA gate, and refusing on "no verdict yet" would wedge the release lane for a
# fact nobody asserted. That is the same rule the review gate-zero uses for base
# drift: refuse on an asserted problem, never on an absent reassurance.
#
# An unrecognised state is treated as NOT-red on purpose. This guard's job is to stop
# a KNOWN-broken tree; inventing a refusal from a state it cannot classify would make
# every future CiStatus state a release outage until somebody taught this line about
# it. The pre-QA gate downstream still fails closed on anything it cannot credit.
def red_accepted_repos(verdicts)
  (verdicts || {}).select { |_repo, v| %w[red conflicted].include?(v.to_h[:state].to_s) }
end

# The refusal itself: one board read over the repos about to be promoted, then abort
# if any carries an asserted failure. The I/O lives here and the DECISION lives in
# red_accepted_repos above, so the rule stays pure and unit-testable while this half
# stays a thin shell around a conductor call.
#
# Called from inside promote_accepted_to_release!, never from a call site — see the
# comment there for why that placement is the point.
def refuse_red_accepted!(repos)
  return if repos.empty?

  step("guard: `accepted` must not be RED in any repo this promote carries")
  # ci_verdict, NOT a board read. Every other CI gate in this file asks GitHub about a
  # SHA directly (the pre-QA gate, the credit probe), and it matters here for a reason
  # the tests caught: a conductor call is a PROD BOARD CONNECTION, and the merge flow
  # asserts it resolves in exactly ONE read. Adding a second round-trip to every
  # promote spends the board's connection budget — the same budget a heavy fan-out
  # once exhausted — to learn something GitHub will answer for free. It also inherits
  # the RELEASE_CI_STATUS injection seam, so the meta-tests never touch the network.
  verdicts = repos.to_h do |repo|
    sha, ok = sh("git", "-C", repo_path(repo), "rev-parse", "origin/#{ACCEPTED_BRANCH}", capture: true)
    [repo, ok ? ci_verdict(repo, sha.to_s.strip) : { state: :unverified }]
  end
  red = red_accepted_repos(verdicts)
  if red.any?
    named = red.map { |repo, v| "#{repo} (#{v[:state]})" }.join(", ")
    abort!("promote refused — `accepted` CI is RED in #{named}. That branch is the candidate this sweep " \
           "would promote onto `release`, so promoting now ships a tree GitHub has already told us is " \
           "broken, and the failure would resurface at the pre-QA gate after the promote — where fixing " \
           "it means unwinding a release instead of a branch. NOTHING was promoted, recorded or deployed. " \
           "Fix forward on `accepted` (or revert the offending merge), let CI go green, then re-run " \
           "`bin/release prepare` — it resumes. A repo whose verdict is PENDING or absent does not block " \
           "here: only an asserted failure does.")
  end
  say("  ✓ `accepted` carries no RED verdict in #{repos.join(', ')}")
end

# Every workflow file a repo ships ON THE BRANCH BEING PROMOTED, as
# { path => yaml_text }. nil (not {}) when the tree could not be read at all, so the
# caller can tell "no workflows" from "no answer" — collapsing those is the same shape
# of bug as the silence this guard exists to remove.
#
# Read from `origin/accepted`, never the working tree. GitHub evaluates the workflow
# file AS IT EXISTS ON THE PUSHED REF, so that ref IS the question; the sibling's
# working tree is whatever branch that checkout happens to sit on, and an agent editing
# ci.yml on a feature branch three repos away must not decide a promote.
def accepted_workflow_sources(repo)
  path = repo_path(repo)
  return nil unless Dir.exist?(path)
  # No `.git` means this is not a checkout we can resolve a ref in — an UNREAD repo,
  # not a finding. File.exist? rather than Dir.exist? on purpose: a git worktree's
  # `.git` is a FILE, and treating a worktree as unreadable would be its own blindness.
  #
  # This does NOT soften the guard where it matters. A real checkout that has DELETED
  # its suite workflow still answers the ls-tree with an empty listing, and an empty
  # listing IS blind — the repo is named. Only "we cannot read the tree at all" is
  # tolerated here.
  return nil unless File.exist?(File.join(path, ".git"))

  listing, ok = sh("git", "-C", path, "ls-tree", "--name-only",
                   "origin/#{ACCEPTED_BRANCH}", ".github/workflows/", capture: true)
  return nil unless ok

  listing.to_s.lines.map(&:strip).reject(&:empty?)
         .select { |file| file.end_with?(".yml", ".yaml") }
         .to_h do |file|
           content, cok = sh("git", "-C", path, "show", "origin/#{ACCEPTED_BRANCH}:#{file}", capture: true)
           [file, cok ? content.to_s : ""]
         end
end

# THE SECOND HALF OF THE GUARD ABOVE — "was that verdict even POSSIBLE?"
#
# refuse_red_accepted! refuses on an ASSERTED failure and, correctly, on nothing else.
# But a repo whose suite workflow never builds `accepted` produces no runs at all, so
# its verdict is absent, absent does not refuse, and the guard's success line named it
# as though it had been checked. Measured 2026-08-18: three of the four swept repos
# were in exactly that state, and the guard had passed over all three in the release
# that shipped the day before. A guard that covers a quarter of the fleet while
# reporting on all of it is worse than no guard — it manufactures the confidence.
#
# THIS ONE REFUSES, and the asymmetry with the wedge-guards above is deliberate. Those
# tolerate `pending`/`none` because a MISSING verdict is usually a race — wait a minute
# and it resolves. This is not a race: a trigger list either names the branch or it does
# not, the answer is identical on every re-run, and the fix is one line in one file. So
# refusing here can never wedge the lane on timing, and passing here would ship a
# release whose candidate rung nothing ever built.
#
# UNREADABLE ≠ BLIND. A repo whose tree could not be read is REPORTED and does not
# refuse, mirroring `:unverified` above: a failed read is not a finding, and turning an
# I/O hiccup into a release outage is its own false alarm.
def refuse_blind_accepted!(repos)
  return if repos.empty?

  step("guard: every repo this promote carries must be ABLE to certify `accepted`")
  sources    = {}
  unreadable = []
  repos.each do |repo|
    files = accepted_workflow_sources(repo)
    files.nil? ? unreadable << repo : sources[repo] = files
  end

  say("  … could not read .github/workflows on origin/#{ACCEPTED_BRANCH} in " \
      "#{unreadable.join(', ')} — reported, not refused (an unread repo is not a finding)") if unreadable.any?

  blind = Release::AcceptedCertification.blind(sources, RELEASE_REPOS)
  if blind.any?
    named = blind.map do |repo|
      "#{repo} (suite workflow #{Release::AcceptedCertification.workflow_for(repo, RELEASE_REPOS).inspect})"
    end.join(", ")
    abort!("promote refused — #{named} cannot certify `accepted`. That repo's declared suite workflow has " \
           "no push trigger for `accepted` on origin/#{ACCEPTED_BRANCH}, so GitHub never builds the rung " \
           "this sweep is about to promote: the RED guard above passed over it without ever having been " \
           "capable of failing, and every task in it would ride to `release` uncertified. NOTHING was " \
           "promoted, recorded or deployed. Fix it by adding `accepted` to that workflow's " \
           "`on.push.branches` (mcritchie-studio's .github/workflows/ci.yml is the reference, and its " \
           "comment explains why there is deliberately NO concurrency block), merge that onto `accepted`, " \
           "then re-run `bin/release prepare` — it resumes.")
  end
  say("  ✓ `accepted` is built by the declared suite workflow in #{sources.keys.join(', ')}")
end

def ladder_clean_verdict(expedited: nil, report_release: false)
  # 1. Board signal, BOTH rungs, in ONE conductor call (read-only, runs even in
  #    --dry-run; a read mutates nothing, and one call keeps the prod board's
  #    connection budget intact):
  #      pending  — code already ON `release`, not shipped: `assembled` (QA-green,
  #                 waiting on Avi) plus `reviewed` with merged:"release" (swept,
  #                 QA in flight). The ff to `main` would carry these.
  #      accepted — `reviewed` with merged:"accepted": code on `accepted`, not yet
  #                 swept. The PROMOTE would carry these onto `release`, and the
  #                 ff from there to `main`. This is the rung the guard used to be
  #                 blind to.
  #    Deliberately UNSCOPED by repo: `prepare` run bare sweeps every `reviewed`
  #    task and derives its promote repos from them, so other-REPO parked work
  #    rides out too — a per-repo git read alone would never see it.
  step("read (read-only): tasks riding `release` + tasks parked on `accepted` + Release.current")
  board = conductor(
    "pending = Task.where(stage: 'assembled').or(Task.where(stage: 'reviewed', merged: 'release'))" \
    ".order(:position).map { |t| { slug: t.slug, title: t.title } }; " \
    "accepted = Task.where(stage: 'reviewed', merged: 'accepted')" \
    ".order(:position).map { |t| { slug: t.slug, title: t.title } }; " \
    "r = Release.current; " \
    "puts({ pending: pending, accepted: accepted, " \
    "release: (r ? { slug: r.slug, state: r.state } : nil) }.to_json)",
    read_only: true
  )
  pending  = board["pending"] || []
  accepted = board["accepted"] || []
  if report_release
    rel = board["release"]
    say("  current release: #{rel ? "#{rel['slug']} (#{rel['state']})" : 'none active'}") if rel || !DRY
  end

  # 2. Git signal, BOTH rungs, from ONE fetch per repo. Skipped under --dry-run
  #    (fetches touch the network); the board signal alone drives the previewed
  #    verdict then.
  git = ladder_ahead_states

  Release::CleanCheck.evaluate(
    pending_tasks: pending,
    repo_states: git["release"],
    accepted_tasks: accepted,
    accepted_states: git["accepted"],
    unreadable_repos: git["unreadable"],
    # The scope the git read was asked to cover. Without it the verdict can only
    # see absences something recorded, and a skipped repo records none.
    expected_repos: git["expected"],
    expedited: expedited
  )
end

# The git signal for the clean check, BOTH rungs, from ONE fetch per repo:
#   "release"  — commits origin/release is ahead of origin/main (0 ⇒ release == main)
#   "accepted" — commits origin/accepted is ahead of origin/release (0 ⇒ accepted == release)
#   "unreadable" — [{ "repo" =>, "rung" => }] for a count that could NOT be read
# ONE fetch is load-bearing, not just cheaper: both rungs are then measured
# against the SAME remote snapshot, so a disagreement between the board and git
# signals is real rather than an artifact of two fetches straddling a push.
#
# Every repo is reported at ahead == 0 too, because an EMPTY list is how the
# caller learns the read did not run at all (--dry-run) — filtering to the
# positive counts happens in Release::CleanCheck. A failed rev-list is recorded
# as unreadable rather than skipped: a read that failed is not a read that came
# back clean, and silently dropping the repo is the same shape of bug as never
# reading the rung. `release_repo_slugs` is already three-rung-only, so every
# repo it yields is declared to HAVE both branches.
#
# TWO CALLERS, one implementation — deliberately. The clean-ladder guard reads
# the WHOLE ecosystem ("is it safe to expedite?"); prepare's stale-tree gate
# reads ONE candidate's deploy plan ("does the tree I am about to deploy carry
# `accepted`?"). Same rungs, same fail-closed rule, so they share this reader
# instead of each growing their own rev-list — a second implementation of the
# same comparison is how the two would drift.
#   repos:            which repos to measure (default: every three-rung repo).
#   require_checkout: what a MISSING sibling checkout means. The ecosystem guard
#     SKIPS one (false) — a repo nobody cloned is not evidence of pending work.
#     The deploy-plan gate cannot afford that (true): a repo it is about to
#     DEPLOY whose rung it could not measure is unverified, and unverified is
#     stale, so it lands in `unreadable` and refuses.
#
# AND IT REPORTS ITS OWN SCOPE back as "expected". A SKIPPED repo (the `false`
# case above) leaves NO trace: no state row on either rung and no `unreadable`
# row, so a reader comparing those two lists cannot tell a repo that came back
# level from a repo nobody opened. Release::CleanCheck graded that silence
# `:complete` and went on to state that the operator's code "may ALREADY BE IN
# PRODUCTION" over a ladder holding an unread repo. Handing back the list this
# loop actually iterated is what lets the verdict measure what it covered
# against what it was asked to cover — and it is derived HERE, from the same
# `repos`, so the scope and the reading cannot drift apart.
# This is the I/O seam the tests stub, the way they stub `conductor`.
def ladder_ahead_states(repos: release_repo_slugs, require_checkout: false)
  # --dry-run takes no fetch, so nothing was expected OR read: an empty scope is
  # what keeps CleanCheck grading it `:unmeasured` rather than partial.
  return { "release" => [], "accepted" => [], "unreadable" => [], "expected" => [] } if DRY

  release_states = []
  accepted_states = []
  unreadable = []

  repos.each do |repo|
    path = repo_path(repo)
    unless Dir.exist?(path)
      next unless require_checkout

      unreadable << { "repo" => repo, "rung" => "#{ACCEPTED_BRANCH} (no checkout at #{path})" }
      next
    end

    sh("git", "-C", path, "fetch", "origin", "--quiet")
    rel = rung_ahead(path, "origin/main", "origin/#{RELEASE_BRANCH}")
    acc = rung_ahead(path, "origin/#{RELEASE_BRANCH}", "origin/#{ACCEPTED_BRANCH}")
    rel.nil? ? unreadable << { "repo" => repo, "rung" => RELEASE_BRANCH }
             : release_states << { "repo" => repo, "ahead" => rel }
    acc.nil? ? unreadable << { "repo" => repo, "rung" => ACCEPTED_BRANCH }
             : accepted_states << { "repo" => repo, "ahead" => acc }
  end

  { "release" => release_states, "accepted" => accepted_states, "unreadable" => unreadable,
    "expected" => Array(repos).map(&:to_s) }
end

# Commits `head` is ahead of `base` in a checkout, or nil when the count could
# not be read (a missing ref, a failed rev-list). nil is the FAILURE signal the
# caller records as unreadable — never a 0.
def rung_ahead(path, base, head)
  out, ok = sh("git", "-C", path, "rev-list", "--count", "#{base}..#{head}", capture: true)
  ok ? out.strip.to_i : nil
end

# The COMMITS behind a positive `rung_ahead` — newest first — for the stale-tree
# refusal. `rung_ahead` answers "how many", which is enough to REFUSE but not
# enough to ACT on: a refusal that says "1 commit behind" makes the operator go
# look it up, and the tool already knows. Only ever called on the failure path
# (a repo the gate is about to refuse), so the happy path pays nothing.
# A failed read degrades to [] — the refusal still stands and simply prints the
# `git log` to run by hand; it must never turn a refusal into a crash.
def rung_stranded_commits(path, base, head, limit: 20)
  out, ok = sh("git", "-C", path, "log", "--format=%h %s", "-n", limit.to_s,
               "#{base}..#{head}", capture: true)
  return [] unless ok

  out.to_s.lines.filter_map do |line|
    sha, subject = line.strip.split(" ", 2)
    next if sha.to_s.empty?

    { "sha" => sha, "subject" => subject.to_s }
  end
end

# prepare's STALE-TREE GATE (step 3b) — the check that makes prepare's own `✓
# Assembled` a true sentence. Runs AFTER the promote and BEFORE the merge-forward,
# the irreversible gem publish, the pre-QA gate, and any QA deploy.
#
# THE DEFECT IT CLOSES: `promote_repos` is derived from BOARD STAMPS (candidates
# stamped merged:"accepted"), so a commit that reached `accepted` with no task
# behind it — a conductor zap, a hand-merge, a review whose stamp never landed —
# is invisible to the promote, which is then SKIPPED for that repo. Every step
# after it still succeeds on the OLD tree and prepare prints `✓ Assembled`.
# Measured live on 2026-08-11: `accepted` ed4d16a, `release` b032e58, one commit
# stranded, QA serving the previous tree, both printed sentences true of a tree
# that did not contain the fix.
#
# WHY IT SITS AFTER THE PROMOTE, NOT BEFORE. Before, it could only re-derive the
# promote's own decision — the proxy. After, it measures what actually LANDED, so
# one check covers every cause at once: a repo the promote never considered, a
# `gh pr merge` that reported success without landing, a stamp nobody wrote, an
# assembled candidate no promote was attempted for. It is also why a normal sweep
# is unaffected: the promote runs first, `accepted` goes level, the gate passes.
# THAT is the resumability half — a genuinely up-to-date candidate (the common
# re-run after an interrupted sweep) measures 0 ahead and rides straight through.
#
# It REFUSES rather than promoting; Release::StaleTreeCheck carries the argument
# and the operator-facing recovery. Fail-closed at a seam where a refusal costs
# nothing: nothing has been published, gated, or deployed, member stages have not
# moved, and a re-run after the hand-landed batch PR resumes cleanly.
# The stage + merged stamp for every task a stranded commit NAMES. Slug recovery
# is pure (Release::MergeSubject reads the branch out of the merge subject), so
# this spends a board read only when at least one commit actually resolves — and
# it is called only from the stale-tree gate, which is already refusing.
#
# A failed read returns {} rather than raising: attribution is a DIAGNOSTIC
# nicety and must never turn a clear refusal into a crash. With {} the abort
# prints exactly what it printed before.
def stranded_task_index(stranded)
  slugs = Release::MergeSubject.slugs_from_commits(stranded)
  return {} if slugs.empty?

  rows = conductor(
    "slugs = #{slugs.inspect}; " \
    "rows = Task.where(slug: slugs).map { |t| [t.slug, { 'stage' => t.stage, " \
    "'merged' => t.merged.to_s }] }.to_h; " \
    "puts({ tasks: rows }.to_json)",
    read_only: true
  )
  rows["tasks"] || {}
# `conductor` fails by calling abort!, which raises SystemExit — NOT a
# StandardError. Rescuing only StandardError here would let a transient prod-board
# blip (the essential-PG too-many-connections shape, 2026-07) replace this gate's
# precise refusal and its recovery commands with "record op failed" and exit 1 —
# the diagnostic eating the diagnosis it exists to produce. record_deploy_intent
# and record_gate_open/close rescue the same pair for the same reason.
rescue SystemExit, StandardError => e
  say("  (attribution unavailable: #{e.message}; the refusal below is unchanged)")
  {}
end

def verify_release_carries_accepted!(repo_groups, rel_slug, rel_state)
  plan_repos = Array(repo_groups).map { |g| g["repo"].to_s }.reject(&:empty?).uniq
  # Only a THREE-RUNG repo has an `accepted` rung it can fall behind. A registry-
  # parked two-rung repo in the plan is out of scope by construction (there is no
  # `accepted` branch to compare), not silently skipped.
  scope = plan_repos & release_repo_slugs
  if scope.empty?
    step("verify: no three-rung repo in the deploy plan — no `#{ACCEPTED_BRANCH}` rung to fall behind")
    return
  end
  if DRY
    step("verify: would check `#{RELEASE_BRANCH}` carries `#{ACCEPTED_BRANCH}` in #{scope.join(', ')} — " \
         "a dry run takes no fetch, so the gate runs live only")
    return
  end

  step("verify: `#{RELEASE_BRANCH}` carries `#{ACCEPTED_BRANCH}` in #{scope.join(', ')} (post-promote) — " \
       "the candidate must deploy the tree its record describes")
  git   = ladder_ahead_states(repos: scope, require_checkout: true)
  stale = Release::CleanCheck.ahead_repos(git["accepted"])

  # Enrich ONLY the repos already known stale: the commit list and the remote
  # name are for the refusal text, so the happy path never pays for them.
  stranded = stale.to_h do |s|
    [s["repo"], rung_stranded_commits(repo_path(s["repo"]),
                                      "origin/#{RELEASE_BRANCH}", "origin/#{ACCEPTED_BRANCH}")]
  end
  nwo = stale.to_h { |s| [s["repo"], repo_name_with_owner(s["repo"])] }

  # ATTRIBUTION, fetched LAZILY. The slugs come out of the merge subjects with no
  # I/O at all; only if some resolve do we spend one board read, and only on a
  # path that is already aborting. The happy path pays nothing, exactly like the
  # commit-list enrichment above.
  task_index = stranded_task_index(stranded)

  verdict = Release::StaleTreeCheck.evaluate(
    accepted_states: git["accepted"],
    unreadable_repos: git["unreadable"],
    stranded_commits: stranded,
    repo_nwo: nwo,
    release_slug: rel_slug,
    release_state: rel_state,
    task_index: task_index
  )
  if verdict["fresh"]
    say(verdict["message"])
    return
  end

  say("")
  say(verdict["message"])
  behind = (verdict["stale_repos"].map { |s| s["repo"] } +
            verdict["unreadable_repos"].map { |u| u["repo"] }).uniq.join(", ")
  abort!("stale tree: `#{RELEASE_BRANCH}` does not carry `#{ACCEPTED_BRANCH}` in #{behind} — prepare REFUSED " \
         "rather than deploying and reporting `✓ Assembled` over a tree missing that work. Nothing was " \
         "published, gated, or deployed. Land the stranded work as shown above, then re-run `bin/release prepare`.")
end

SHORT = 7
def short(sha) = sha.to_s.empty? ? "(frozen)" : sha.to_s[0, SHORT]

# A git read that runs EVEN in dry-run (a read mutates nothing) — mirrors how
# `conductor(read_only:)` lets a dry-run preview real state. Returns [out, ok?].
def git_capture(*args)
  out, status = Open3.capture2e("git", *args)
  [out, status.success?]
end

def gem_meta_for(repo) = RELEASE_REPOS.dig("gems", repo) || {}
def app_meta_for(repo) = RELEASE_REPOS.dig("apps", repo) || {}

# A gem is SELF-GATED when the registry gives it its own pre-publish gate
# (a non-empty `release_check`): its own suite IS the release-candidate verdict,
# so it can be its OWN release candidate with no consuming app to QA it through.
# Mirrors Release::Repos.self_gated_gem? on the RECORD side — bin/release reads
# the registry through RELEASE_REPOS (no Rails), so it can't call the model. Keep
# the two in step.
def self_gated_gem?(repo) = !gem_meta_for(repo)["release_check"].to_s.strip.empty?

# A gem's declared version AT a git ref — `git show <ref>:<version_file>`, parsed
# the same way as the local read. This is the read that fixes the publish-skip:
# ship BUILDS + PUBLISHES the gem from the QA-frozen commit, so the version that
# decides "already live? skip : publish" MUST come from THERE — not the pre-ff
# local checkout, which still sits on stale `main` and reports the PREVIOUS version
# (the 0.10.0/0.11.0 skip that shipped a release without ever publishing the bumped
# gem). A pure read (git_capture) so it runs even in --dry-run, letting the dry-run
# plan + label show the version that will actually publish. Returns "" when the ref
# or version_file is blank, the repo isn't checked out, or git can't read the blob.
def gem_version_from_ref(repo, ref)
  version_file = gem_meta_for(repo)["version_file"].to_s
  return "" if version_file.empty? || ref.to_s.empty?

  out, ok = git_capture("-C", repo_path(repo), "show", "#{ref}:#{version_file}")
  return "" unless ok

  out[/version\s*=\s*["']([\w.\-]+)["']/i, 1].to_s
end

# A gem's publish version, resolved from the version that will ACTUALLY build at
# ship — read at the QA-frozen SHA (`frozen_ref`), NOT the pre-ff local checkout.
# Reading the frozen ref is the fix for the publish-skip bug; member_plan's recorded
# version and the local checkout stay as fallbacks for when there's no ref to read
# (a release prepared before SHA recording, or an un-frozen preview).
def gem_version_for(repo, group, frozen_ref = nil)
  from_ref = gem_version_from_ref(repo, frozen_ref)
  return from_ref unless from_ref.empty?

  member = (group["members"] || []).find { |m| !m["version"].to_s.empty? }
  return member["version"].to_s if member

  gem_version_local(repo)
end

# The QA-frozen SHA to ship for a repo — the value `prepare` recorded under
# release.metadata["qa_shas"] (apps AND gems both freeze it now). The PURE
# present?/which-SHA decision lives in Release::ShipSequence.frozen_sha so this
# stays thin; only the live-git fallback (resolve origin/release HEAD when a repo
# was never frozen — e.g. a release prepared before SHA recording) is I/O and
# stays here. Resolved live only (DRY returns "").
def frozen_sha_for(repo, qa_shas)
  frozen = Release::ShipSequence.frozen_sha(qa_shas, repo)
  return frozen if frozen
  return "" if DRY

  out, ok = git_capture("-C", repo_path(repo), "rev-parse", "origin/#{RELEASE_BRANCH}")
  ok ? out.strip : ""
end

# The RubyGems versions listing for the idempotency check: the parsed
# /api/v1/versions/<gem>.json — an array of { "number" => ... } entries, all LIVE
# (RubyGems excludes yanked versions from the listing entirely; there is no
# `yanked` field). 404 (never published) or any error → [] (publish needed). A
# live-only read.
def rubygems_versions(gem_name)
  out, status = Open3.capture2e("/usr/bin/curl", "-sf",
                                "https://rubygems.org/api/v1/versions/#{gem_name}.json")
  return [] unless status.success? && !out.strip.empty?

  JSON.parse(out)
rescue JSON::ParserError
  []
end

# --- THE PUBLISH → INSTALL WINDOW ---------------------------------------------
#
# `gem push` returns before RubyGems can SERVE the version. prepare publishes the
# gem, immediately commits the consumer lock bump, and that commit triggers CI —
# whose `Set up Ruby` step runs `bundle install` against a lock pinning a version
# the index does not carry yet. Bundler exits 7, a lane reds, and the pre-QA gate
# aborts the release.
#
# THAT COSTS MORE THAN A RE-RUN. The publish is already irreversible by then, so an
# abort here strands a permanently published version. Measured on 2026-08-15: the
# race reddened scan_ruby on one attempt and lint on the next — the same bundler
# exit 7 both times, never a code regression — and 0.48.0 was left stranded.
#
# ASKED OF THE COMPACT INDEX, not the versions API, because that is the surface
# BUNDLER actually reads. The two do not agree during the window: the same minute
# the JSON API still listed 0.48.0 as newest, the .gem file for 0.49.0 already
# answered 200. Waiting on the wrong surface would be a wait that proves nothing.
GEM_INDEX_URL = "https://index.rubygems.org/info/%s"
GEM_POLL_INTERVAL = Integer(ENV.fetch("RELEASE_GEM_POLL_INTERVAL", "5"))
GEM_POLL_TIMEOUT  = Integer(ENV.fetch("RELEASE_GEM_POLL_TIMEOUT", "300"))

# Is `version` of `gem_name` visible on the compact index bundler resolves from?
#
# RELEASE_GEM_INDEXED is the test seam, mirroring RELEASE_CI_STATUS: "yes"/"no" so
# the meta-tests never touch the network.
def gem_version_indexed?(gem_name, version)
  injected = ENV["RELEASE_GEM_INDEXED"].to_s
  return injected == "yes" unless injected.empty?

  out, status = Open3.capture2e("/usr/bin/curl", "-sf", format(GEM_INDEX_URL, gem_name))
  return false unless status.success?

  # Compact-index lines are "<version> <deps>|<checksums>"; the version is field one.
  out.lines.any? { |line| line.split(" ", 2).first.to_s.strip == version.to_s }
end

# PURE. Whether to keep waiting, given elapsed time and a timeout.
def gem_wait_expired?(elapsed, timeout = GEM_POLL_TIMEOUT)
  elapsed >= timeout
end

# Block until every just-published gem is installable, or ABORT before anything
# commits. Refusing here is strictly better than letting CI discover it: nothing
# has been bumped yet, so a re-run resumes cleanly instead of stranding a version.
def await_published_gems!(published_gems)
  return if published_gems.nil? || published_gems.empty?

  step("await: each published gem must be FETCHABLE on the index before the lock bump triggers CI")
  published_gems.each do |gem_name, version|
    elapsed = 0
    until gem_version_indexed?(gem_name, version)
      if gem_wait_expired?(elapsed)
        abort!("published #{gem_name} #{version} but it is still not on the RubyGems compact index after " \
               "#{GEM_POLL_TIMEOUT}s. NOTHING was bumped, recorded or deployed — the consumer locks are " \
               "untouched, so `bin/release prepare` resumes cleanly once the index catches up. Bumping now " \
               "would commit a lock CI cannot install (bundler exits 7 in `Set up Ruby`), redding a lane and " \
               "aborting the release AFTER the publish became irreversible.")
      end

      sleep(GEM_POLL_INTERVAL)
      elapsed += GEM_POLL_INTERVAL
    end
    say("  ✓ #{gem_name} #{version} is on the index — safe to bump consumer locks")
  end
end

# Detached checkout of a repo at a SHA so the gem artifact builds from the
# QA-frozen commit. Aborts on a failed checkout (never build from the wrong tree).
def checkout_detached(repo, sha)
  path = repo_path(repo)
  abort!("gem repo not found at #{path} — clone it as a sibling at the projects root") unless Dir.exist?(path)
  sh("git", "-C", path, "fetch", "origin", "--quiet")
  _, ok = sh("git", "-C", path, "checkout", sha, capture: true)
  abort!("could not checkout #{short(sha)} in #{repo} to build the gem — fetch it or re-run prepare") unless ok
end

# Advance a repo's `main` to the QA-FROZEN SHA — the release → main collapse that
# `main` deploys from. A pure REF PUSH:
#
#   git -C <repo> push origin <frozen>:refs/heads/main
#
# WHAT THIS REPLACED, and why (2026-07-12). It used to be `ff_main_local` +
# `push_origin_main`: check out `main` in the SHARED PRIMARY, `pull`, `merge
# --ff-only <frozen>`, then push the local branch. That made the deploy depend on
# the primary's WORKING TREE — so ship's preflight had to refuse a dirty primary,
# and a concurrent feature session's staged work ABORTED a production ship after
# the gems had published. But advancing a remote branch never needed a working
# tree at all: a ref push reads the shared OBJECT STORE and nothing else. It does
# not move HEAD, does not touch the index, and runs happily while a feature agent
# has half a feature staged one directory over.
#
# It keeps every safety property of the old ff:
#   * FAILS CLOSED on divergence — git rejects a non-fast-forward ref update
#     without --force (verified), exactly as `merge --ff-only` did. We NEVER pass
#     --force here; a rejected push must abort the ship, not rewrite prod's history.
#   * SHIPS THE FROZEN SHA — the pushed ref is the SHA itself, not "whatever the
#     local main happened to be after an ff", so there is no window in which a
#     stale/raced local branch could be pushed instead.
#   * IDEMPOTENT — a re-run of a completed ship pushes an already-current ref
#     ("Everything up-to-date"), the same no-op the ff was.
# The local `main` in the primary is deliberately left alone; `restore_primaries`
# fast-forwards it afterwards, best-effort, and nothing in the ship reads it.
# WHY A REJECTED PUSH IS NOT AUTOMATICALLY A DIVERGENCE.
#
# Measured 2026-08-29, twice, on a real production ship. `git push` failed on
# CREDENTIALS — `remote: Invalid username or token` — and push_frozen_main
# answered with the only failure it knew about:
#
#   could not fast-forward ... origin/main has diverged from the frozen SHA
#   (someone pushed to main). Reconcile main, re-run `bin/release prepare` ...
#
# Nothing had diverged. `main` was strictly BEHIND `release` and a dry-run
# fast-forward succeeded. The prescribed remedy — reconcile a branch that needed
# no reconciling, then re-freeze the whole release — was pure waste, and it was
# waste delivered with total confidence at the most expensive moment there is.
# git had already said the true cause three lines above; the code threw those
# lines away and asserted a cause instead of reading one.
#
# So: classify, and never claim more than the output supports. A cause we cannot
# recognise is reported AS unrecognised, with git's own words attached — an
# honest "I don't know, here is what it said" beats a confident wrong answer,
# which is the whole lesson of this function.
#
# ORDER MATTERS. `error: failed to push some refs to ...` appears in BOTH
# failures, so it can never be the discriminator; auth is checked first because
# it is the one that was being misread.
PUSH_AUTH_SIGNS = [
  /invalid username or token/i,
  /authentication failed/i,
  /could not read (?:username|password)/i,
  /terminal prompts disabled/i,
  /permission denied \(publickey\)/i,
  /remote: permission to .* denied/i,
  /support for password authentication was removed/i,
  /remote: repository not found/i,
  /\b(?:401|403) (?:unauthorized|forbidden)\b/i
].freeze

# The genuine non-fast-forward. `[rejected]` alone is not enough — a rejection
# carries its REASON in parentheses, and that reason is the fact we need.
PUSH_DIVERGED_SIGNS = [
  /non-fast-forward/i,
  /\[rejected\][^\n]*\((?:fetch first|stale info)\)/i,
  /updates were rejected because/i,
  /tip of your current branch is behind/i
].freeze

# => [:auth, :diverged, :unknown]
def classify_push_failure(output)
  text = output.to_s
  return :auth if PUSH_AUTH_SIGNS.any? { |re| text.match?(re) }
  return :diverged if PUSH_DIVERGED_SIGNS.any? { |re| text.match?(re) }

  :unknown
end

# The operator-facing sentence for each cause. Kept beside the classifier so a
# new cause cannot be classified without also being explained.
def push_failure_message(repo, sha, cause)
  case cause
  when :auth
    "could not push #{repo} origin/main to #{short(sha)} — git was REFUSED ON CREDENTIALS, not on the ref. " \
      "main has NOT diverged and nothing needs reconciling; the push never got far enough to find out. " \
      "This is the SHIP lane, which pushes as the DEPLOYER identity, so it needs " \
      "OP_ADMIN_SERVICE_ACCOUNT_TOKEN to read github.mcritchie-deployer from the studio-agents-admin vault. " \
      "On a provisioned machine that is SELF-SERVICE — the token is already on disk, just not in " \
      "this shell:\n" \
      "    source ~/.zprofile.admin\n" \
      "    export GH_APP_ITEM=github.mcritchie-deployer\n" \
      "Export GH_APP_ITEM BEFORE the push; the credential helper reads it at MINT TIME, so setting it " \
      "afterwards yields the AGENT token — a wrong-identity success, which is harder to notice than a " \
      "refusal. Those two lines are the whole fix: the deployer is never cached (bin/gh-token\'s " \
      "CACHEABLE_IDENTITIES), so the next push mints fresh through the helper on its own — there is no " \
      "token to refresh by hand, and nothing further to run. Only if this machine has no " \
      "~/.zprofile.admin at all does it need installing once with `bin/setup-1pass-token --admin`. " \
      "Then re-run `bin/release ship` — it resumes; do NOT re-run `prepare`, the freeze is still good."
  when :diverged
    "could not fast-forward #{repo} origin/main to #{short(sha)} — git REFUSED the ref update as a " \
      "NON-FAST-FORWARD, which means origin/main has diverged from the frozen SHA (someone pushed to " \
      "main). NOT forcing. Reconcile main, re-run `bin/release prepare` to re-freeze, then re-run " \
      "`bin/release ship`."
  else
    "could not push #{repo} origin/main to #{short(sha)} — git refused, and the reason is NOT one this " \
      "script recognises. Read git's output above before acting: it is neither a credential refusal nor a " \
      "non-fast-forward, so BOTH standard remedies (refresh the deployer token / reconcile main) may be " \
      "the wrong errand. NOT forcing."
  end
end

def push_frozen_main(repo, sha)
  sha = sha.to_s.strip
  step("push #{repo} origin main → frozen #{short(sha)} (ref push — no checkout, no working tree)")
  return if DRY

  abort!("no frozen SHA to push for #{repo} — re-run `bin/release prepare`") if sha.empty?

  path = repo_path(repo)
  abort!("repo not found at #{path} — clone it as a sibling at the projects root") unless Dir.exist?(path)

  # CAPTURED, because the diagnosis below is READ from git rather than assumed.
  # It is echoed either way, so the operator still sees exactly what an uncaptured
  # push would have shown them.
  out, ok = sh("git", "-C", path, "push", "origin", "#{sha}:refs/heads/main", capture: true)
  say(out.to_s.rstrip) unless out.to_s.strip.empty?
  abort!(push_failure_message(repo, sha, classify_push_failure(out))) unless ok

  # THE PER-REPO SHIP EVIDENCE, recorded at the only chokepoint that can't lie
  # about it: this repo's `main` now points at this SHA, because git just accepted
  # the ref update. Collected here and written onto the release beside
  # Conductor.ship! (step 6), where Release#ship! reads it to decide which members
  # may be stamped `shipped`. Before it existed a run that ff'd three repos and
  # skipped a fourth left the same record as one that shipped everything.
  ship_evidence[repo] = sha

  # main is advanced — now re-baseline this repo's origin/accepted onto it
  # (guarded, idempotent, NON-FATAL). See advance_accepted.
  advance_accepted(repo, path, sha)
end

# { repo => sha } for every repo whose `main` this process has advanced (or, in
# finalize, proven already live). Written to release.metadata["shipped_shas"] in
# the same conductor call that ships the members.
def ship_evidence
  @ship_evidence ||= {}
end

# After push_frozen_main advances a repo's `main`, re-baseline that repo's
# persistent `accepted` integration branch onto the same frozen SHA. This retires
# the manual post-ship chore the conductor has run by hand after every ship —
# `git push origin origin/main:refs/heads/accepted` — because `accepted` (feature
# branches are cut from and PR into it) is left STALE behind `main` after a ship
# and nothing else re-baselines it. DevOps v2 Phase 3, Slice 1: a step toward
# Phase 3 fully automating accepted-maintenance; a later slice restructures the
# ladder and retires the manual chore entirely.
#
# Three properties, each load-bearing:
#
#   * GUARDED — advance ONLY a repo that HAS an origin/accepted, queried LIVE
#     against the remote with `ls-remote` (not the primary's remote-tracking ref,
#     which can be stale or missing here and would false-negative the guard into
#     never advancing). A repo without an accepted branch (rolio/turf, pre-Phase-5)
#     is a clean NO-OP. The yes/no is the pure ShipSequence.advance_accepted?.
#
#   * FAIL-CLOSED — no --force. `accepted` trails `main`, so the advance is
#     normally a fast-forward; a non-ff means `accepted` has DIVERGED (someone
#     pushed to it), and forcing would silently discard that. git refuses the
#     non-ff and we leave it for a human.
#
#   * NON-FATAL — `main` is already advanced and the deploy is landing, so a failed
#     accepted push (a divergence, a transient git error) must NEVER abort a live
#     ship. Warn with the manual command and CONTINUE — the same best-effort
#     contract as the merged:main stamp (record_merged_main).
def advance_accepted(repo, path, sha)
  _, exists = sh("git", "-C", path, "ls-remote", "--exit-code", "--heads", "origin", "accepted", capture: true)
  return unless Release::ShipSequence.advance_accepted?(sha: sha, accepted_exists: exists)

  step("advance #{repo} origin/accepted → #{short(sha)} (ref push — accepted trails main)")
  _, ok = sh("git", "-C", path, "push", "origin", "#{sha}:refs/heads/accepted")
  return if ok

  report_refused_advance(repo, path, sha)
rescue SystemExit, StandardError => e
  say("  ⚠ #{repo}: origin/accepted advance failed (#{e.message}); deploy continues (maintenance only)")
end

# Explain a REFUSED (non-fast-forward) accepted advance — correctly.
#
# REGRESSION (rel-20260720-1fc111): this used to call every refusal "DIVERGED" and
# suggest `git push origin <sha>:refs/heads/accepted`. On that ship accepted was
# merely AHEAD — a concurrent review pass had merged two PRs into it mid-ship — and
# the suggested command would have DESTROYED both. accepted was missing nothing.
#
# So classify BEFORE advising, on CONTENT and not just topology. The sweep merges
# accepted INTO release, so the frozen main is a MERGE COMMIT whose tree equals the
# accepted head it came from, and that merge commit never appears in accepted's
# history — `merge-base --is-ancestor` is FALSE even when nothing is missing. The
# second signal (main's tree already present in accepted's history) is what catches
# that case. Verdict: Release::ShipSequence.accepted_relation.
#
# BEST-EFFORT like its caller: a signal we cannot READ reports :unknown rather
# than a confident verdict, and NO branch ever suggests a bare ref push.
def report_refused_advance(repo, path, sha)
  # FETCH FIRST — the whole classification below reads `origin/#{ACCEPTED_BRANCH}`,
  # and it is STALE here. The advance push we just made was REFUSED (non-fast-
  # forward), and a rejected push does not update the remote-tracking ref; nor did
  # anything earlier on the app-repo ship path fetch `accepted` (the only fetch is
  # gem-only, in checkout_detached). In production the concurrent review merge that
  # caused the refusal landed on the remote from ANOTHER clone, so this clone has
  # never seen it. Classifying against the stale ref is the very mistake the guard
  # in advance_accepted's header warns about ("not the primary's remote-tracking
  # ref, which can be stale... and would false-negative") — read a ref we could not
  # trust, then print a confident verdict, which is this PR's own bug one layer
  # down. It printed "AHEAD by 0 commits" against a truth of 13. Non-fatal like the
  # rest of this path: a failed fetch just leaves the ref as stale as before.
  sh("git", "-C", path, "fetch", "origin", ACCEPTED_BRANCH, "--quiet", capture: true)

  relation = Release::ShipSequence.accepted_relation(
    main_is_ancestor: ancestor_signal(path, sha),
    main_tree_absorbed: tree_absorbed_signal(path, sha)
  )

  if relation == :ahead
    count, ok = sh("git", "-C", path, "rev-list", "--count", "#{sha}..origin/#{ACCEPTED_BRANCH}", capture: true)
    count = ok ? count.strip : "?"
    say("  ✓ #{repo}: origin/accepted NOT advanced to #{short(sha)} — accepted is AHEAD of main by " \
        "#{count} commit#{'s' unless count == '1'} (work merged while the ship ran) and already contains " \
        "everything that shipped. Nothing to do.")
    return
  end

  if relation == :unknown
    say("  ⚠ #{repo}: origin/accepted NOT advanced to #{short(sha)} — git refused the ref update, and the " \
        "accepted/main relation could NOT be read, so this is reported as UNDETERMINED rather than guessed. " \
        "The ship is NOT forcing. Deploy continues.")
    say("    CHECK FIRST, and READ THE DIFF THIS WAY: " \
        "git -C #{path} fetch origin && git -C #{path} diff origin/accepted origin/main")
    say("    Any ADDITION or MODIFICATION means accepted is missing shipped content — reconcile below. " \
        "DELETIONS ONLY usually means accepted merely gained files after the freeze — but a shipped file " \
        "DELETION looks identical in this diff, so when in doubt, reconcile: the merge is non-destructive either way.")
    say_reconcile_recipe(repo, path)
    return
  end

  say("  ⚠ #{repo}: origin/accepted NOT advanced to #{short(sha)} — main's content was NOT found in accepted's " \
      "recent history, so accepted appears to be missing shipped content; the ship is NOT forcing. " \
      "Deploy continues.")
  say_reconcile_recipe(repo, path)
end

# The one reconcile recipe, shared by the :diverged and :unknown branches.
#
# ROUND-2 fixed WHERE the merge is based (the round-1 `checkout accepted` landed on
# the primary's stale LOCAL branch, so the push was refused non-fast-forward).
# ROUND-3 fixes WHERE the merge HAPPENS, because basing it correctly was not enough:
#
#   * It was an `&&` chain, and `git merge` exits non-zero on CONFLICT. The chain
#     HALTED at the merge, so neither the push nor the trailing `checkout main` ran
#     and the operator was left on a branch they had never seen, mid-conflict.
#   * That is not an exotic path. This very file documents :diverged as the ROUTINE
#     outcome on a gem-carrying release (post-#588), and the mechanism is
#     bump_consumer_locks_for_qa writing Gemfile.lock — the file most likely to have
#     been touched on accepted too. THE ROUTINE PATH AND THE CONFLICT PATH ARE THE
#     SAME PATH.
#   * Worst of all on a gem repo: a conflicted merge leaves MODIFIED TRACKED FILES in
#     the primary, and a gem repo in that state ABORTS the next ship. Advice printed
#     to unblock one release could wedge the following one.
#
# So the merge no longer happens in the primary at all. It happens in a THROWAWAY
# WORKTREE, which is also the house rule (worktrees are desks; primaries are loading
# docks). Walked on a throwaway clone with a genuinely conflicting Gemfile.lock: the
# merge still stops — every recipe must — but the primary stays on `main` and CLEAN,
# origin/accepted is untouched, the conflict is contained in the scratch checkout,
# and BOTH exits (finish it, or bail out) are printed rather than left to invention.
# A conflict is now a labeled decision point instead of a stranding.
#
# Printed as discrete labeled steps, never one `&&` chain: a chain implies all-or-
# nothing, and this procedure genuinely has a branch in the middle.
def reconcile_scratch_path(repo) = "/tmp/reconcile-#{ACCEPTED_BRANCH}-#{repo}"

def say_reconcile_recipe(repo, path)
  scratch = reconcile_scratch_path(repo)
  say("    RECONCILE with a MERGE (keeps accepted's own commits) in a SCRATCH WORKTREE, " \
      "so a conflict can never dirty your primary or wedge the next ship:")
  say("      git -C #{path} fetch origin")
  say("      git -C #{path} worktree add --detach #{scratch} origin/#{ACCEPTED_BRANCH}   " \
      "# if this says 'already exists', an old recovery was abandoned — see BAIL OUT below to clear it")
  say("      git -C #{scratch} merge origin/main   # can stop here on a conflict; see IF THE MERGE CONFLICTS below")
  say("      git -C #{scratch} push origin HEAD:#{ACCEPTED_BRANCH}")
  say("      git -C #{path} worktree remove #{scratch}")
  say("    IF THE MERGE CONFLICTS (expect Gemfile.lock on a gem-carrying release) the " \
      "merge step STOPS and prints the conflicted files. Your primary is untouched. Either:")
  say("      FINISH IT — resolve the files in #{scratch}, then: " \
      "git -C #{scratch} add -A && git -C #{scratch} commit --no-edit " \
      "&& git -C #{scratch} push origin HEAD:#{ACCEPTED_BRANCH} " \
      "&& git -C #{path} worktree remove #{scratch}")
  say("      BAIL OUT — discard everything, leaving no residue: " \
      "git -C #{path} worktree remove --force #{scratch}")
end

# Is `main` reachable from accepted? TRI-STATE (:affirmed/:refuted/:unknown).
#
# `merge-base --is-ancestor` exits 1 for "no" and non-zero for a FAULT too, and our
# `sh` reports only success/failure — so a bad ref would masquerade as a confident
# "not an ancestor". Resolve both refs first: only when both READ can a non-zero
# exit honestly mean :refuted.
def ancestor_signal(path, sha)
  return :unknown unless rev_parse_ok?(path, sha) && rev_parse_ok?(path, "origin/#{ACCEPTED_BRANCH}")

  _, ok = sh("git", "-C", path, "merge-base", "--is-ancestor", sha, "origin/#{ACCEPTED_BRANCH}", capture: true)
  ok ? :affirmed : :refuted
end

def rev_parse_ok?(path, ref)
  out, ok = sh("git", "-C", path, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}", capture: true)
  ok && !out.strip.empty?
end

# Is the frozen SHA's TREE already present somewhere in accepted's history?
# TRI-STATE (:affirmed/:refuted/:unknown).
#
# The content test behind the AHEAD verdict. A sweep-merge main carries the very
# tree of the accepted head it came from, so that tree shows up on an accepted
# ancestor even though the merge commit itself does not. Bounded to the recent
# history (the absorbed commit is always a few merges back on a live ladder) so
# this stays one cheap read on a large repo.
#
# A git read that FAILS answers :unknown, never :refuted — "I could not look" is
# not "it is not there".
#
# TWO DELIBERATE IMPRECISIONS, both named here because each is a mild instance of
# the very bug shape this file exists to fix, and a silent tradeoff is how that
# shape survives a review:
#
#   1. THE SCAN BOUND. A tree absorbed further back than ACCEPTED_TREE_SCAN answers
#      :refuted — absence of evidence reported as refutation. Kept because the
#      alternative (:unknown past the bound) would report UNDETERMINED on every
#      deep history, drowning the signal; and because :refuted degrades toward the
#      :diverged branch, whose advice is a non-destructive merge.
#   2. EQUALITY, NOT CONTAINMENT. The real invariant is "accepted CONTAINS main's
#      content"; this tests "some accepted commit has main's EXACT tree". Equality
#      implies containment, so an :affirmed is always sound — the imprecision is
#      one-directional and can only UNDER-claim :ahead, never over-claim it.
#
# Both therefore fail toward warning too much rather than too little, which is the
# safe direction when the wrong call costs merged work. If :diverged verdicts ever
# start arriving where :ahead is plainly right, this is the first thing to revisit.
#
# Since #588 a gem-carrying release legitimately :refutes this: bump_consumer_locks_for_qa
# commits consumer lock bumps onto `release` during prepare, so the frozen tree is
# genuinely not accepted's. That is a true refutation, not a fault.
def tree_absorbed_signal(path, sha)
  tree, ok = sh("git", "-C", path, "rev-parse", "#{sha}^{tree}", capture: true)
  return :unknown unless ok

  tree = tree.strip
  return :unknown if tree.empty?

  trees, listed = sh("git", "-C", path, "log", "--max-count=#{ACCEPTED_TREE_SCAN}", "--format=%T",
                     "origin/#{ACCEPTED_BRANCH}", capture: true)
  return :unknown unless listed

  trees.split("\n").any? { |candidate| candidate.strip == tree } ? :affirmed : :refuted
end

# Put a GEM repo's primary checkout back on `main` after the artifact build left it
# DETACHED at the frozen SHA (checkout_detached). Gems are the one place the ship
# still builds from the primary — `gem build` packages what is on disk — so it is
# the one place that has to tidy up after itself.
#
# BEST-EFFORT (warn, never abort): by the time this runs the gem is PUBLISHED and
# origin/main is pushed. A checkout that can't be restored is a cosmetic
# inconvenience in the operator's sibling; aborting the train over it would strand
# a half-shipped release for no safety gain.
def restore_gem_primary(repo)
  return if DRY

  path = repo_path(repo)
  _, co = sh("git", "-C", path, "checkout", "main", capture: true)
  unless co
    say("  ⚠ #{repo}: left on a detached HEAD (couldn't check out main) — `git -C #{path} checkout main` when free")
    return
  end
  _, ff = sh("git", "-C", path, "merge", "--ff-only", "origin/main", capture: true)
  say("  ⚠ #{repo}: main not fast-forwarded to origin/main — `git -C #{path} pull` when free") unless ff
end

# The SHIP WORKSPACE: the private, detached checkout a release WRITES in, pinned at
# the SHA the caller hands it. Same primitive as the gate's (Release::GateWorkspace), a
# different role — so it is a different directory (.worktrees/_ship), a different
# test DB (<app>_ship_test) and a different lock, and a prod deploy can never queue
# behind, or reset the tree under, a concurrent conductor's G3 gate suite.
#
# NOT the deploy's alone — BOTH conductors work here, and reading it as "the tree the
# deploy works in" is what let a `cleanup --reclaim` reclaim both repos' `_ship` desks
# mid-prepare on 2026-08-14 (bin/agent-worktree's guard asked only about the `deployer`
# claim). The tree-needing steps, by conductor:
#   * PREPARE (assembler): merge_forward_release_branches, and bump_consumer_locks_for_qa
#     — `bundle lock --update <gem> --conservative` writes each consumer's Gemfile.lock;
#   * SHIP (deployer): the auto-re-pin commit (repin_consumers — `bundle lock` again),
#     and a `repo_script` app's deploy (deploy_app — turf's bin/deploy runs its own
#     suite, reads config/*.idl.json, and pushes from the checkout it runs in).
# Everything else either conductor does to git is a ref push (push_frozen_main), which
# needs no tree at all.
def ship_workspace!(repo, sha)
  gate_workspace!(repo, sha, role: "ship")
end

# Bring a ship workspace to a runnable state for a repo whose own deploy script
# runs a SUITE there (the repo_script satellites — turf's bin/deploy runs `bin/rails
# test` before it pushes). Same preparation as a gate's: the bundle under the suite
# ruby, and a test DB PROVEN private to this workspace before `db:test:prepare`
# purges it. Without it, turf's pre-prod suite would run against the SHARED
# `turf_monster_test` — the cross-talk that false-fails green code, here at the
# worst possible moment (mid-ship, after the gems published).
#
# These are the CONDUCTOR'S OWN commands (bundle check, the DB probe,
# db:test:prepare), so they correctly run under the full gate overlay — RAILS_ENV
# =test and all. The DEPLOY SCRIPT does not (see ship_deploy_env).
def prepare_ship_workspace!(repo, path)
  prepare_gate_workspace!(repo, path, role: "ship")
end

# The env for a repo's OWN deploy script — deliberately NOT the gate overlay.
#
# It hands over exactly ONE var: DATABASE_URL, pointing at the workspace's private
# test DB, so the suite the script runs pre-prod (turf's `bin/rails test`) can't be
# poisoned by — or poison — a concurrent suite on the shared `turf_monster_test`.
# VERIFIED before shipping this: turf's FULL suite (1404 runs) is green in a fresh
# detached workspace under exactly this invocation, with no built assets and no
# node_modules.
#
# It must NOT be gate_env(), even though that would be the obvious reuse.
# Release::GateEnv sets RAILS_ENV=test (right for a gate, which runs nothing but
# test commands) — and this is a PRODUCTION DEPLOY SCRIPT. Handing it RAILS_ENV
# =test changes a contract it never agreed to: turf's bin/deploy happens to run
# only `bin/rails test`, but the next repo_script app (tax-studio, chain-ops) could
# precompile assets or run a rails task in its deploy, and doing that under
# RAILS_ENV=test would build the WRONG artifact and ship it. The ruby pin is out
# for the same reason: the script's toolchain is the script's business. The change
# this task makes to a satellite deploy is its CWD — a clean, pinned tree instead
# of a shared primary — and nothing else.
#
# KNOWN CONSTRAINT, for whoever registers the NEXT repo_script app: DATABASE_URL is
# a Rails BUILTIN and is not test-scoped — Rails merges it into the resolved config
# of WHATEVER env is current. It lands on the test DB here only because the one
# rails command turf's bin/deploy runs is `bin/rails test`. A deploy script that
# also ran a DEVELOPMENT-env rails command would silently connect it to
# <app>_ship_test. Harmless today (it is a scratch test DB, and nothing in a deploy
# script has business reading a local dev DB), but a repo_script deploy must not
# assume its dev database. Registry contract: config/release_repos.yml.
#
# {} for an app whose test DB is file-backed inside the workspace (SQLite) — it is
# private already, and `sh` drops an empty overlay.
def ship_deploy_env(repo)
  url = gate_database_url(repo, role: "ship")
  url.to_s.empty? ? {} : { "DATABASE_URL" => url }
end

# Stamp `merged: "main"` on a repo's member tasks right after that repo's
# `release → main` fast-forward lands on origin — the git-location signal
# (matrix: assembled+main = ff'd, prod-deploy in flight) an interrupted Avi run
# reads to skip re-ff'ing. BEST-EFFORT (warn + continue): the ffs are git no-ops
# on a re-run and Task#ship! re-stamps "main" at the record step, so a board blip
# here must never abort a mid-train prod deploy. A board WRITE → suppressed in
# --dry-run (conductor prints the plan).
def record_merged_main(slugs)
  slugs = Array(slugs).compact
  return if DRY || slugs.empty?

  step("record: merged:main for #{slugs.join(', ')} (release → main ff landed)")
  conductor(
    "Release::Conductor.record_merged!(slugs: #{slugs.inspect}, merged: 'main'); " \
    "puts({ merged_main: #{slugs.inspect} }.to_json)"
  )
rescue SystemExit, StandardError => e
  say("  ⚠ merged:main not recorded for #{slugs.join(', ')} (#{e.message}); deploy continues — ship! re-stamps it")
end

# The conductor's pre-prod test gate: run the registry `test_cmd` at the repo's
# frozen SHA before the irreversible deploy; scoped-abort on red. repo_script
# apps SELF-GATE (their own deploy runs tests) → no test_cmd → skipped.
#
# G4 SELF-GATING (the 90/10 policy): the full suite runs ONCE per release batch,
# at G3 — so this gate may skip, but ONLY on PROOF that G3 actually ran and
# passed. That proof is G3's OWN RECORDED VERDICT,
# release.metadata["qa_gates"][repo] = {sha, cmd, ok}, which pre_qa_gate writes
# only after a green suite. Same command + same frozen SHA + green => skip.
#
# It deliberately does NOT infer the proof from the registry + release.metadata
# ["qa_shas"] (the old rule): qa_shas is stamped by the QA DEPLOY LOOP, so it
# records what was DEPLOYED, never what was CERTIFIED — which let a SKIPPED G3
# still satisfy the skip and silently disarm this gate. No record, a red record,
# a different command, or a drifted/straggler SHA all FAIL OPEN and run the gate.
# The skip is recorded as a visible SOP on the g4_ship gate run, never a silent
# omission. (The pure decision lives in Release::ShipSequence.ship_gate_skip?,
# unit-tested.)
#
# A G3 whose AUDITOR went RED also fails open — G3 called the SHA green, GitHub CI
# called the SAME SHA broken, so the batch certification is exactly what must not
# be trusted. Without this the skip would fire (the frozen SHA *is* the certified
# SHA) and G3's alarm would be the ONLY thing between a CI-red commit and prod.
# FAIL-OPEN ONLY: a red auditor causes MORE checking, never a block, and no-data
# (none/pending/unverified) changes nothing.
# The G4 fail-closed abort text. A RED CI is a broken frozen commit — it must not
# ship. Any OTHER non-green (none/pending/unverified/unreadable) is CI without a
# green verdict for the frozen SHA yet (a just-pushed re-pin may still be pending):
# hold and re-run, or take the first-class --skip-test-gate override. Never a pass.
def ship_test_gate_ci_abort(repo, frozen_sha, ci)
  if ci[:state] == :red
    named = Array(ci[:failing]).join(", ")
    "test gate FAILED for #{repo}: GitHub CI called frozen #{short(frozen_sha)} " \
      "RED#{named.empty? ? '' : " (#{named})"} — aborting BEFORE the irreversible prod deploy. A red frozen SHA " \
      "must not ship: read the failing check, fix on `#{RELEASE_BRANCH}` + re-run `bin/release ship`."
  else
    "test gate HELD for #{repo}: GitHub CI has NO green verdict for frozen #{short(frozen_sha)} (#{ci_detail(ci)}). " \
      "The ship gate is CI now and FAILS CLOSED on anything but green — a just-pushed re-pin may still be PENDING, " \
      "and an :unreadable state is a token fault. Wait for CI to conclude on the frozen SHA, then re-run " \
      "`bin/release ship`. To ship past a verdict you believe is a false negative, use " \
      "`bin/release ship --skip-test-gate --reason \"…\"` (records a RED gate)."
  end
end

def test_gate(repo, frozen_sha: nil, qa_gate: nil)
  cmd = app_meta_for(repo)["test_cmd"].to_s
  if cmd.empty?
    step("test gate: #{repo} self-gates (no conductor test_cmd; its deploy runs tests) — skip")
    return
  end

  # Say WHY the batch certification is being ignored — a gate that silently
  # re-derives teaches the operator nothing, and this is the one signal that says
  # "G3's record and CI disagreed about this exact commit".
  #
  # DevOps v2 Phase 3: a red-auditor G3 record is now DEFENSIVE — G3 derives ok from CI
  # (ci_pass?), so a red CI aborts prepare and never produces a green ok:true record.
  # A stale or hand-built record can still carry this shape, and it must still be
  # re-gated, never trusted. G4 re-derives the verdict from GitHub CI on the FROZEN SHA
  # below — which, unlike the demoted local suite, CAN see every lane — and fails the
  # ship CLOSED if that SHA is not green.
  #
  # Name the SHA G3's record CERTIFIED (record["sha"]), not the frozen ship SHA: when
  # the RC was re-pinned the two differ, and "G3 certified <frozen_sha>" would be a
  # second false claim printed by the very code that exists to kill one.
  if Release::ShipSequence.auditor_red?(qa_gate)
    audited_sha = (qa_gate["sha"] || qa_gate[:sha]).to_s
    say("  ⚠ #{repo}: G3's record certified #{short(audited_sha)} GREEN but GitHub CI called that SHA RED — the " \
        "batch certification is NOT trusted, so G4 does not self-skip on it. It RE-DERIVES the verdict from " \
        "GitHub CI on frozen #{short(frozen_sha)} below, and CI fails this gate closed if that SHA is not green.")
  end

  if Release::ShipSequence.ship_gate_skip?(test_cmd: cmd, frozen_sha: frozen_sha, qa_gate: qa_gate)
    step("test gate: #{repo} self-gates — `#{cmd}` already CERTIFIED green on frozen #{short(frozen_sha)} " \
         "by the G3 pre-QA gate this run; skip (a drifted SHA, a G3 that never ran, or a RED CI auditor " \
         "re-triggers)")
    gate_sop("ship_test_gate", "skipped — #{cmd} certified green @ #{short(frozen_sha)} at G3 (recorded pre-QA verdict)", true)
    return
  end

  # THE OPERATOR ESCAPE HATCH — explicit, confirmed, and LOUD.
  #
  # The old way to ship past a gate you believed was a false negative was to blank
  # the registry's test_cmd/qa_test_cmd. That is now closed (it SILENTLY DISARMED
  # this gate — see ship_gate_skip?), and closing it without a replacement would
  # WEDGE the operator: a G4 false negative with no clean override, and a config
  # edit is not one (it is un-reviewed drift in the registry the gate reads). So the
  # override is
  # first-class: it demands a reason, it asks before it skips, and it records a RED
  # gate SOP — a skipped gate is now visible in the release record forever, where
  # the old trick left one that read "already green".
  if SKIP_TEST_GATE
    reason = opt_value("--reason").to_s.strip
    abort!("--skip-test-gate requires --reason \"…\" (it is recorded on the release as a red gate)") if reason.empty?
    unless confirm("⚠ SKIP the #{repo} ship test gate (`#{cmd}`) on frozen #{short(frozen_sha)}? " \
                   "The suite will NOT run before the irreversible prod deploy. Reason: #{reason}")
      abort!("ship aborted — test gate not skipped")
    end
    step("⚠ test gate: SKIPPED BY OPERATOR for #{repo} (--skip-test-gate) — #{reason}")
    gate_sop("ship_test_gate",
             "⚠ SKIPPED BY OPERATOR (--skip-test-gate): #{reason} — `#{cmd}` did NOT run on #{short(frozen_sha)}",
             false)
    return
  end

  # Validate the registry command even though the suite is DEMOTED (Phase 3): a
  # malformed value must still abort a preview. test_cmd_argv aborts on an unbalanced quote.
  test_cmd_argv(cmd)
  step("test gate: #{repo} — GitHub CI verdict for frozen #{short(frozen_sha)} " \
       "(#{cmd} recorded, not run; before prod)")
  return if DRY

  # DevOps v2 Phase 3+4: the frozen SHA's last gate before prod is GitHub CI's
  # conclusion for that exact commit (ci_pass?), not a re-run of the local suite.

  # THE VERDICT, fail-CLOSED before the irreversible prod deploy: ci_pass? passes on
  # ONLY :green. A red (a broken frozen commit) and every no-data/pending state
  # (none/pending/unverified/unreadable — e.g. a just-pushed re-pin whose CI has not
  # concluded) all FAIL the gate. A false green is the one error that ships untested
  # code to production. CI's conclusion is recorded as this gate's Tier-3 SOP.
  ci = ci_verdict(repo, frozen_sha)
  ok = ci_pass?(ci)
  gate_sop("ship_test_gate",
           "GitHub CI #{ci[:state].to_s.upcase} @ #{short(frozen_sha)} — #{cmd} " \
           "(Tier-3 Actions conclusion; local suite demoted)", ok)
  abort!(ship_test_gate_ci_abort(repo, frozen_sha, ci)) unless ok
end

# `bundle lock --update <gem>` with a bounded retry/backoff for RubyGems
# propagation lag (a just-pushed version isn't always instantly resolvable).
# `conservative:` adds bundler's --conservative so a SINGLE-gem bump can't float
# the rest of the dependency graph — the prepare-side consumer bump passes it
# (the lock lands on `release` and ships; only the published gem may move).
# `bundle lock --update <gem>`, with ONE propagation ladder covering BOTH ways it
# can fail to land.
#
# `expect:` is the version the caller just published and requires to be resolved.
# Pass it and a run that EXITS ZERO WITH THE OLD VERSION STILL RESOLVED is treated
# as retryable, exactly like a non-zero exit.
#
# WHY (rel-20260809-3b8f3d, 2026-08-09): this ladder already existed, but it only
# ever retried on a non-zero exit — and the propagation bug's entire signature is
# exit 0 with the old version resolved, because the RubyGems index had not caught
# up in the seconds since our own `gem push`. So the ladder was structurally blind
# to the one condition it was written for, and the caller's read-back would abort
# on FIRST observation with zero waiting, moments after an IRREVERSIBLE push. That
# turns an ordinary, self-curing delay into a manual stop on a sweep whose whole
# posture is self-healing. One ladder, both conditions, abort only when it is
# exhausted.
def bundle_lock(path, gem, attempts: 3, conservative: false, expect: nil)
  args = ["bundle", "lock", "--update", gem]
  args << "--conservative" if conservative
  lockfile = File.join(path, "Gemfile.lock")
  # The propagation backoff's base, in seconds. Overridable ONLY so the tests can
  # drive the real ladder (including its exhaustion abort) without sleeping 15s;
  # nothing in the pipeline sets it, so every real run gets 5s → 10s.
  delay = Integer(ENV.fetch("RELEASE_BUNDLE_LOCK_BACKOFF", "5"))
  reason = nil

  attempts.times do |i|
    step("#{args.join(' ')} (cd #{path}) [#{i + 1}/#{attempts}]")
    _, ok = sh(*args, chdir: path)

    if !ok
      reason = "bundle exited non-zero"
    elsif expect.nil?
      return
    else
      # File.read can raise if bundler never wrote a lock; treat a missing lock as
      # "not landed" so it rides the ladder instead of escaping as a backtrace.
      text     = File.exist?(lockfile) ? File.read(lockfile) : ""
      resolved = Release::ShipSequence.locked_version(text, gem)
      return if Release::ShipSequence.lock_bump_landed?(text, gem, expect)

      reason = "bundle succeeded but the lock resolves #{resolved || 'nothing'}, wanted #{expect}"
    end

    break if i == attempts - 1

    say("  #{reason} — RubyGems may not have propagated #{gem} #{expect} yet; retrying in #{delay}s")
    sleep(delay)
    delay *= 2
  end

  # WAIT ON THE SURFACE BUNDLER READS — not the one this script's idempotency
  # check reads. What just failed is `bundle lock`, a BUNDLER resolution, and
  # bundler resolves through the COMPACT INDEX at index.rubygems.org/info/<gem>.
  # The versions JSON API (rubygems_versions, which answers only "already
  # published, so skip the push?") and the HTML gem page are separate services
  # with their own CDN caching: a version visible on either is not proof bundler
  # can resolve it. Send the operator to either and the false green sends them
  # back into the publish branch, where `gem push` is refused as already-live and
  # the advice becomes "bump the version" — burning a number for nothing.
  abort!("#{args.join(' ')} did not land in #{path} after #{attempts} tries (#{reason}). " \
         "This is normally RubyGems index propagation. Wait until " \
         "`curl -sS https://index.rubygems.org/info/#{gem} | tail -5` shows " \
         "#{expect || 'the published version'} — that compact index is what bundler " \
         "resolves through — then re-run; it resumes.")
end

# --- prepare-side gem publish (producer-first, BEFORE the pre-QA gate + QA) ----
#
# WHY AT PREPARE (publish-gems-before-qa): ship used to be the first publish, so
# QA never tested what prod would build — the consumer's QA deploy bundled its
# COMMITTED Gemfile.lock (the OLD gem), ship then published the new gem and
# repinned, and prod built a tree QA never saw. Worse, an unbumped version_file
# made the ship publish silently self-skip (publish_needed? false), STRANDING
# gem commits with every gate green. prepare now mirrors ship's producer-first
# sequence up front: publish each swept gem member's origin/release version,
# then commit each consumer's lock bump onto its release branch — BEFORE the
# pre-QA gate reads CI's verdict and BEFORE any QA deploy, so the gate's SHA,
# the QA tree, and the prod tree are the SAME tree.
#
# THE ACCEPTED COST: a publish is irreversible (RubyGems forbids re-pushing a
# number), so a QA bounce can orphan a published version — the next fix bumps
# PAST it and the dead number just sits on RubyGems, harmless. That trade is
# deliberate: an occasional dead version buys QA testing the real artifact.
#
# Ship's publish stays, now as the idempotent VERIFY: on the happy path every
# version is already live (skip), and it remains the backstop for a release
# prepared before this change. Everything here is idempotent for the
# self-healing re-run: already-live versions skip, an already-bumped lock
# commits nothing.

# PHASE 0 — ALLOCATE THE VERSION. The release owns the version, so THIS is where
# it gets written; every phase below only reads it.
#
# WHY IT RUNS FIRST, above phase 1's stranded-work guard: that guard exists
# BECAUSE nothing allocated. Until this landed, the conductor hand-edited
# `lib/studio/version.rb`, hand-ran `bundle lock`, and hand-committed both onto
# the gem's `accepted` before re-running prepare — the recipe qa-release.md's
# STRANDED GEM WORK row spells out, run in full for rel-20260811-573804. The
# guard was the net for the times he forgot.
#
# THE GUARD STAYS ARMED. This does not replace it and must not: allocation is
# skippable (--dry-run), refusable (below), and — like anything new — capable of
# being wrong. Phase 1 still independently re-reads the version at
# origin/release and still aborts when it has not advanced past the last tag. On
# the happy path the guard now finds nothing, which is the point; the moment
# allocation does not happen, it fires exactly as before.
#
# REFUSING IS THE FEATURE. A RubyGems number can NEVER be re-pushed, so every
# ambiguity here aborts the sweep with ZERO gems published rather than guessing:
# an unreadable `gem_bump` override, an unparseable last version, a version_file
# that declares its version twice, a `bundle lock` that did not land the number
# we just wrote. A refusal costs a re-run; a wrong allocation costs the number
# forever. The decision itself is pure and unit-tested (Release::GemVersion
# .allocation) — the shell here only supplies the git + RubyGems reads.
def allocate_gem_versions!(gem_groups)
  return if gem_groups.empty?

  say("")
  step("gem version allocation (the RELEASE owns the version, not any PR): derive each swept gem's next version " \
       "from its members, commit it WITH its Gemfile.lock onto origin/#{RELEASE_BRANCH} — before the publish")

  if DRY
    gem_groups.each do |group|
      step("  gem #{group['repo']}: last published (last v* tag ∪ RubyGems) + the members' bump → rewrite " \
           "#{gem_meta_for(group['repo'])['version_file']} → `bundle lock` → ONE commit of both onto " \
           "origin/#{RELEASE_BRANCH} (skips when already advanced; REFUSES rather than guess)")
    end
    return
  end

  # TWO PHASES, for the same reason phase 1 below has two: DECIDE for every swept
  # gem before WRITING to any of them. Deciding is a pure read; writing pushes a
  # commit onto origin/release. Interleaving them would let gem A's version land
  # while gem B's decision is still unknown — the "mutate before validate"
  # objection that got allocation descoped when the module first shipped
  # (finding-d0621629719b). Splitting the loop answers it: a refusal anywhere
  # aborts with NOTHING written anywhere.
  #
  # And the residual risk is bounded by design. What phase 0 writes is a git
  # commit, which is REVERSIBLE; the irreversible act — `gem push` — still
  # happens only after phase 1 has validated every gem. A write-phase failure on
  # a later gem therefore leaves an earlier gem's version commit on `release`,
  # and that is self-healing rather than stranded: the next run reads it as
  # "already advanced", skips it, and publishes it once the sweep completes.
  failures = []
  plan = gem_groups.filter_map { |group| gem_allocation_plan(group, failures) }
  abort_allocation!(failures)

  plan.each { |entry| commit_gem_version!(entry["repo"], entry["tip"], entry["decision"], failures) }
  abort_allocation!(failures)
end

def abort_allocation!(failures)
  return if failures.empty?

  abort!("gem version allocation FAILED — NOTHING was published or deployed (a RubyGems version can never be " \
         "re-pushed, so allocation refuses rather than guesses):\n  - " + failures.join("\n  - "))
end

# PHASE 0a — DECIDE, WRITE NOTHING. One gem's git + RubyGems reads and the pure
# decision they feed. Returns the write plan for an `allocate`, nil for a `skip`
# or a `refuse`. Appends to `failures` instead of aborting so every swept gem is
# judged before the run stops.
def gem_allocation_plan(group, failures)
  repo = group["repo"]
  path = repo_path(repo)
  unless Dir.exist?(path)
    failures << "gem repo not found at #{path} — clone it as a sibling at the projects root"
    return
  end

  # FAIL-CLOSED FETCH, and `--tags` is load-bearing here in a way it is not for a
  # plain read: the last v* tag is half the baseline this version is derived from,
  # so a stale tag list would allocate a number that is already published.
  _, fetched = sh("git", "-C", path, "fetch", "origin", "--tags", "--quiet")
  unless fetched
    failures << "git fetch failed in gem #{repo} — a stale origin/#{RELEASE_BRANCH} or tag list must never drive " \
                "an irreversible version allocation (fail closed); fix the remote, then re-run `bin/release prepare`"
    return
  end

  out, ok = git_capture("-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}")
  unless ok
    failures << "could not resolve origin/#{RELEASE_BRANCH} in #{repo} for the version allocation — fetch, then re-run"
    return
  end
  tip = out.strip

  tag_out, tag_ok = git_capture("-C", path, "describe", "--tags", "--abbrev=0", "--match", "v*", tip)
  tag = tag_ok ? tag_out.strip : nil

  # The same range the stranded-work guard reads, capped: allocation only needs to
  # know whether ANY work sits past the last tag, not to list it. With no tag yet
  # the range is the whole history, and the decision falls through to its
  # first-publish skip.
  ahead_out, ahead_ok = git_capture("-C", path, "log", "--oneline", "--max-count=20", tag ? "#{tag}..#{tip}" : tip)
  unless ahead_ok
    failures << "could not read #{repo} #{tag ? "#{tag}..origin/#{RELEASE_BRANCH}" : RELEASE_BRANCH} for the " \
                "version allocation — fetch, then re-run `bin/release prepare`"
    return
  end

  decision = Release::GemVersion.allocation(
    current: gem_version_from_ref(repo, tip),
    tag_version: tag&.delete_prefix("v"),
    live_versions: rubygems_versions(repo),
    ahead_commits: ahead_out.lines.map(&:chomp).reject { |l| l.strip.empty? },
    members: gem_version_members(group)
  )

  if decision.refuse?
    failures << "gem #{repo}: REFUSING to allocate a version — #{decision.reason}. Fix what that names, then " \
                "re-run `bin/release prepare`; it resumes"
    return nil
  end

  unless decision.allocate?
    say("  gem #{repo}: #{decision.reason} — nothing allocated")
    return nil
  end

  { "repo" => repo, "tip" => tip, "decision" => decision }
end

# The member descriptors Release::GemVersion derives the bump from. The repo plan
# carries `task_kind` (feature/bug/chore) beside its own `kind` (gem/app); this
# renames it to the key the module reads, so the two kinds can never be confused
# at the point a version is computed from one of them.
def gem_version_members(group)
  (group["members"] || []).map do |m|
    { "slug" => m["slug"], "kind" => m["task_kind"], "risk_tags" => m["risk_tags"], "gem_bump" => m["gem_bump"] }
  end
end

# PHASE 0b — THE WRITE. version_file + Gemfile.lock in ONE commit, pushed onto
# origin/release by ref, fast-forward-checked. Built in the gem's ship workspace
# pinned at the release tip — the same never-touch-the-primary mechanics as the
# consumer lock bump below, which matters more than usual for a gem, because the
# artifact `gem build` packages is read from that primary checkout.
def commit_gem_version!(repo, tip, decision, failures)
  version      = decision.version
  version_file = gem_meta_for(repo)["version_file"].to_s

  with_ship_workspace(repo) do
    workspace  = ship_workspace!(repo, tip)
    ws_version = File.join(workspace, version_file)
    unless File.exist?(ws_version)
      failures << "gem #{repo}: #{version_file} is missing at origin/#{RELEASE_BRANCH} — check its `version_file` " \
                  "in config/release_repos.yml"
      next
    end

    rewritten = Release::GemVersion.rewrite_version(File.read(ws_version), version)
    if rewritten.nil?
      failures << "gem #{repo}: #{version_file} does not declare EXACTLY ONE version literal — refusing to " \
                  "rewrite it blind; set it to #{version} by hand and commit it onto #{RELEASE_BRANCH}, then re-run"
      next
    end
    File.write(ws_version, rewritten)

    next unless relock_gem_workspace!(repo, workspace, version, failures)

    sh("git", "-C", workspace, "add", "--", *[version_file, lock_tracked?(workspace) ? "Gemfile.lock" : nil].compact)
    _, committed = sh("git", "-C", workspace, "commit", "-m", "Release #{version}", capture: true)
    unless committed
      failures << "gem #{repo}: could not commit #{version} in the ship workspace"
      next
    end

    # Fast-forward-checked (no --force): a release branch that moved under us
    # fails closed HERE, before anything is published against a version this
    # commit is not part of.
    _, pushed = sh("git", "-C", workspace, "push", "origin", "HEAD:refs/heads/#{RELEASE_BRANCH}", capture: true)
    unless pushed
      failures << "gem #{repo}: could not push #{version} to origin/#{RELEASE_BRANCH} (did #{RELEASE_BRANCH} move?)"
      next
    end

    step("  gem #{repo}: allocated #{version} — #{decision.reason}; committed with its lockfile onto " \
         "origin/#{RELEASE_BRANCH}")
  end
end

# TRAP, and the reason the lock is not optional: studio-engine bundles ITSELF as
# a path gem, so its OWN Gemfile.lock names its OWN version (`PATH / remote: . /
# studio-engine (0.38.0)`), and CI installs FROZEN (`bundler-cache: true`). A
# version commit whose lockfile stayed behind therefore dies in `bundle install`
# before a single test runs — and it is INVISIBLE locally, because a local
# `bundle install` quietly regenerates the lock and hides the omission.
#
# So the lock is regenerated and READ BACK in the same breath. Plain `bundle
# lock` (not `--update <gem>`): bundler re-reads a path gemspec on every resolve,
# so this rewrites the PATH spec and nothing else — MEASURED on studio-engine
# 0.38.0 → 0.39.0, a one-line diff.
#
# ASSERT, DO NOT INFER — the lesson `bundle_lock` above was rewritten for. Note
# WHICH read: `locked_version` scans GEM sections ONLY and answers nil for a gem
# in its own lock, so asserting through it would have looked like a guard and
# checked nothing. `path_locked_version` reads the PATH spec; both are tried so
# this also covers a gem that does not self-bundle.
#
# Returns true when the lock is settled (including "this repo tracks no lock" —
# solana-studio does not), false when it failed and the reason is recorded.
def relock_gem_workspace!(repo, workspace, version, failures)
  return true unless lock_tracked?(workspace)

  _, locked = sh("bundle", "lock", chdir: workspace)
  unless locked
    failures << "gem #{repo}: `bundle lock` failed after writing #{version} — the version commit must carry its " \
                "Gemfile.lock (CI installs frozen), so nothing was committed"
    return false
  end

  text     = File.read(File.join(workspace, "Gemfile.lock"))
  resolved = Release::ShipSequence.path_locked_version(text, repo) ||
             Release::ShipSequence.locked_version(text, repo)
  return true if resolved == version

  failures << "gem #{repo}: `bundle lock` left Gemfile.lock resolving #{resolved.inspect}, wanted #{version} — " \
              "refusing to commit a version its own lockfile contradicts (CI installs frozen and would fail " \
              "before running a test)"
  false
end

def lock_tracked?(workspace)
  _, ok = sh("git", "-C", workspace, "ls-files", "--error-unmatch", "--", "Gemfile.lock", capture: true)
  ok
end

# PHASE 1 — VALIDATE EVERY GEM, PUBLISH NOTHING. A RubyGems push can never be
# re-pushed, so every check THIS PHASE OWNS runs for EVERY swept gem BEFORE the
# first push: repo cloned, buildable primary (the artifact builds from disk),
# FAIL-CLOSED fetch (a stale origin/release must never drive an irreversible
# decision), version_file parses, stranded-work guard (ORDERING — the version
# must be strictly newer than the last published tag; equal, backward, and
# unparseable all block), and a consuming app IN THIS SWEEP whose
# origin/release Gemfile declares the gem — without one the published gem would
# assemble QA-green with QA never bundling it (the gem-only bypass). ANY
# failure aborts with every finding named and ZERO gems published. Returns the
# validated publish plan phase 2 executes.
#
# WHAT PHASE 1 DOES **NOT** COVER (be precise — an overclaim here is exactly the
# kind of green badge on wrong behavior this PR exists to remove):
#   * The gem's own `release_check`/`gem build` runs inside publish_gem, in
#     PHASE 2 (see :1019-1028). So a gem whose BUILD is red is caught only when
#     its turn to publish arrives — with an earlier gem already pushed. Phase 1
#     shrinks the multi-gem blast radius to build failures alone; it does not
#     eliminate it. Closing that fully means building every gem artifact up
#     front (a real cost for the rare multi-gem sweep) — deliberately deferred,
#     and NOT claimed here.
#   * `already_live` is read from RubyGems in phase 1 and consumed in phase 2 —
#     a TOCTOU on a network read. Worst case is a redundant push that RubyGems
#     rejects and publish_gem aborts on, loudly. Fail-closed, so it is a wasted
#     run, never a wrong publish.
def validate_gems_for_qa(gem_groups, app_groups)
  return [] if gem_groups.empty?

  say("")
  step("gem publish (producer-first, BEFORE the pre-QA gate + any QA deploy): " \
       "preflight EVERY swept gem, then publish from origin/#{RELEASE_BRANCH}, then bump consumer locks")

  if DRY
    gem_groups.each do |group|
      step("  gem #{group['repo']}: preflight (fail-closed fetch → version parses → stranded-work guard " \
           "(commits past the last tag with an unbumped version_file ABORT) → a swept consumer declares " \
           "the gem) — ALL swept gems validate BEFORE the first irreversible push → then publish the " \
           "origin/#{RELEASE_BRANCH} version to RubyGems (skip if already live) → tag v<version>")
    end
    return gem_groups.map { |g| { "repo" => g["repo"], "version" => "", "dry" => true } }
  end

  failures = []
  # GEM-ONLY candidate. A self-gated gem (its registry `release_check` is its own
  # release-candidate verdict) MAY be its own release: it gates at G3 on its OWN
  # suite's CI (pre_qa_gate's gem pass), and the RubyGems publish is its prod
  # deploy — no consuming app is required. So skip this abort when EVERY swept gem
  # is self-gated. A NON-self-gated gem-only sweep (e.g. solana-studio, no
  # release_check) still aborts exactly as before: with no consumer it would
  # publish and assemble QA-green with nothing ever exercising the gem.
  if app_groups.empty? && !gem_groups.all? { |g| self_gated_gem?(g["repo"]) }
    non_self_gated = gem_groups.reject { |g| self_gated_gem?(g["repo"]) }.map { |g| g["repo"] }
    failures << "the sweep carries #{gem_groups.map { |g| g['repo'] }.join(', ')} but NO app member, and " \
                "#{non_self_gated.join(', ')} #{non_self_gated.size == 1 ? 'is' : 'are'} not self-gated " \
                "(no `release_check` in config/release_repos.yml) — a non-self-gated gem-only candidate would " \
                "publish with no consumer lock bump, no pre-QA gate, and no QA deploy, then assemble QA-green " \
                "untested; enroll the consuming app in the sweep (or eject the gem member). A self-gated gem " \
                "may release alone."
  end
  consumers = validated_consumer_gemfiles(app_groups, failures)

  plan = []
  gem_groups.each do |group|
    repo = group["repo"]
    path = repo_path(repo)
    unless Dir.exist?(path)
      failures << "gem repo not found at #{path} — clone it as a sibling at the projects root"
      next
    end

    # The artifact is BUILT from the gem's primary checkout (`gem build` packages
    # what is ON DISK) — ship_preflight's one surviving primary hazard.
    dirt = Release::ShipSequence.gem_build_offenders([repo_git_state(repo, path)])
    if dirt.any?
      failures << Release::ShipSequence.gem_build_message(dirt, root: projects_root)
      next
    end

    _, fetched = sh("git", "-C", path, "fetch", "origin", "--tags", "--quiet")
    unless fetched
      failures << "git fetch failed in gem #{repo} — a stale origin/#{RELEASE_BRANCH} must never drive an " \
                  "irreversible publish (fail closed); fix the remote, then re-run `bin/release prepare`"
      next
    end

    out, ok = git_capture("-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}")
    unless ok
      failures << "could not resolve origin/#{RELEASE_BRANCH} in #{repo} for the gem publish — " \
                  "fetch, then re-run `bin/release prepare`"
      next
    end
    tip = out.strip

    version = gem_version_from_ref(repo, tip)
    if version.empty?
      failures << "could not resolve a version for gem #{repo} at origin/#{RELEASE_BRANCH} — " \
                  "check #{repo}/#{gem_meta_for(repo)['version_file']}"
      next
    end

    # The clean-env verdict, collected like every other gem precondition so a bad
    # one aborts with ZERO gems published rather than after the first push.
    if (ci_failure = gem_ci_failure(repo, tip, version))
      failures << ci_failure
    end

    if (stranded = stranded_gem_failure(repo, path, tip, version))
      failures << stranded
      next
    end

    # Per-gem no-consumer guard. A self-gated gem does NOT need a consuming app to
    # be QA'd — its own suite is its verdict (pre_qa_gate's gem pass) — so skip
    # this check for it. A non-self-gated gem still requires a swept consumer that
    # bundles it, or the published gem would assemble QA-green with QA never
    # exercising it.
    if app_groups.any? && !self_gated_gem?(repo) &&
       consumers.none? { |_, text| Release::ShipSequence.consumer_bump_action(text, repo, version) != :absent }
      failures << "gem #{repo} #{version} has no consuming app in this sweep (checked: " \
                  "#{consumers.keys.join(', ')}) — the published gem would assemble QA-green with QA never " \
                  "bundling it; enroll the consuming app (or eject the gem member)"
      next
    end

    plan << { "repo" => repo, "tip" => tip, "version" => version,
              "already_live" => !Release::ShipSequence.publish_needed?(version, rubygems_versions(repo)) }
  end

  if failures.any?
    abort!("gem publish preflight FAILED — NOTHING was published (every swept gem validates before the " \
           "first irreversible push):\n  - " + failures.join("\n  - "))
  end
  plan
end

# Phase 1's consumer read: each swept app's Gemfile AT origin/release, behind a
# FAIL-CLOSED fetch (the same stale-ref discipline as the gems). An app with no
# Gemfile at the tip simply cannot consume — that alone is not a failure; the
# per-gem coverage check above decides.
def validated_consumer_gemfiles(app_groups, failures)
  app_groups.each_with_object({}) do |group, gemfiles|
    repo = group["repo"]
    path = repo_path(repo)
    unless Dir.exist?(path)
      failures << "app repo not found at #{path} — clone it as a sibling at the projects root"
      next
    end
    _, fetched = sh("git", "-C", path, "fetch", "origin", "--quiet")
    unless fetched
      failures << "git fetch failed in #{repo} — refusing to preflight gem consumers against a " \
                  "possibly-stale origin/#{RELEASE_BRANCH} (fail closed)"
      next
    end
    text, ok = git_capture("-C", path, "show", "origin/#{RELEASE_BRANCH}:Gemfile")
    gemfiles[repo] = ok ? text : ""
  end
end

# PHASE 2 — the irreversible loop, run ONLY after phase 1 validated every swept
# gem. No new decisions here: the plan carries the tip, version, and live-state
# phase 1 resolved. Idempotent for the self-healing re-run: already-live
# versions skip.
# THE CLEAN-ENV VERDICT FOR A GEM'S TIP — the check in front of the one
# irreversible step in this whole pipeline.
#
# WHAT IT CLOSES. publish_gem authorised itself from a LOCAL `bin/release-check
# --build` — whatever bundle, whatever Ruby, whatever half-installed state the
# conductor's laptop happens to carry — and then pushed to RubyGems, which can
# NEVER be un-pushed. Every other shippable tip here earns a clean-env verdict
# before it moves; the gem's did not, and the gem is the one artifact with no
# rollback. The verdict already EXISTED and was simply never read.
#
# IT RUNS IN PHASE 1 (validate_gems_for_qa), NOT beside the push. That placement
# is the fix for a defect review found in the first version: with the check in the
# publish loop, a studio-engine + solana-studio sweep pushed studio-engine to
# RubyGems and THEN aborted on the second gem — a partial publish of the
# unrecoverable artifact, which is precisely what this task exists to prevent.
# validate_gems_for_qa holds exactly one invariant and says so in its own abort
# text: EVERY swept gem validates before the FIRST irreversible push.
#
# A DECLARED CI-LESS GEM IS SKIPPED, not waited on — a gem GemCiWorkflows maps to
# an explicit nil. No registered gem is in that state today: solana-studio was the
# live example until 2026-08-20, when it shipped a "Gem CI" lane with its Rails
# engine and the map was repointed. The branch stays for the next such gem, and it
# earns its keep — before this exemption the
# gate folded its absent verdict to :none, polled the FULL 1200s window, then told
# the operator to go and watch a run that does not and never will exist. A gate
# that can never pass is not a gate, it is an outage.
#
# AN UNMAPPED GEM IS NOT EXEMPT. Absence of a declaration is not a declaration of
# absence: a gem nobody added to the map is BLIND, and blind must fail closed, or
# the next gem to arrive inherits a silent bypass.
def gem_ci_failure(repo, sha, version)
  return nil if DRY

  if GemCiWorkflows.declared_ci_less?(repo)
    say("  gem CI gate: #{repo} declares no suite workflow (GemCiWorkflows) — skipping the clean-env " \
        "verdict for #{short(sha)}; its own release-check is the only gate it has")
    return nil
  end

  say("  gem CI gate: GitHub's verdict for #{repo}@#{short(sha)} — the tip this publish would push")
  ci = poll_ci_verdict(repo, sha)
  return nil if ci_pass?(ci)

  gem_ci_abort(repo, sha, version, ci)
end

# The refusal text, factored out so it is unit-testable and so the operator is
# told what to DO rather than only what failed. A publish that stops here has
# pushed NOTHING — the whole point of gating in phase 1.
def gem_ci_abort(repo, sha, version, ci)
  "#{repo} #{version}: GitHub CI is #{ci_detail(ci)} for #{short(sha)}, the exact tip this " \
    "publish would push. NOTHING WAS PUBLISHED — the version is still free and this run can be " \
    "re-run once CI is green. A gem push cannot be undone, so this gate will not credit a local " \
    "release-check alone: that run proves the tree is good ON THIS MACHINE, and the class of " \
    "failure it cannot see is exactly the one that reaches every consumer. Watch the run, fix or " \
    "re-run it, then re-run this sweep."
end

def publish_gems_for_qa(gem_plan)
  return {} if gem_plan.empty?

  published = {}
  gem_plan.each do |gem|
    repo = gem["repo"]
    if gem["dry"]
      published[repo] = ""
      next
    end

    if gem["already_live"]
      say("  gem #{repo} #{gem['version']} already live on RubyGems — skip publish (idempotent re-run)")
    else
      step("  gem #{repo} #{gem['version']}: publish from origin/#{RELEASE_BRANCH} (#{short(gem['tip'])}) — " \
           "QA must test consumers against the REAL published artifact")
      checkout_detached(repo, gem["tip"]) # build from the exact release tree
      publish_gem(repo, gem["version"])   # reused: release-check → build → push → tag
      restore_gem_primary(repo)
      # IRREVERSIBLE: a RubyGems version can never be re-pushed. Record it so a
      # later abort can tell the operator what is already live (see prepare's
      # rescue arm) instead of implying the run left nothing behind.
      (@prepare_live ||= []) << "gem #{repo} #{gem['version']} PUBLISHED to RubyGems (cannot be un-pushed)"
    end
    published[repo] = gem["version"]
  end
  published
end

# The STRANDED-WORK guard for one gem repo (the pure decision + message live in
# Release::ShipSequence): origin/release ahead of the last published v* tag with
# an UNBUMPED version_file is the silent-skip hazard that stranded engine
# commits behind a green pipeline. Returns the loud failure message (naming the
# commits) for phase 1 to collect, or nil. A repo with no v* tag yet has
# nothing published to strand behind → no guard.
def stranded_gem_failure(repo, path, tip, version)
  tag_out, tag_ok = git_capture("-C", path, "describe", "--tags", "--abbrev=0", "--match", "v*", tip)
  return nil unless tag_ok # no published tag — first publish; nothing to strand behind

  tag = tag_out.strip
  ahead_out, ahead_ok = git_capture("-C", path, "log", "--oneline", "#{tag}..#{tip}")
  unless ahead_ok
    return "could not read #{repo} #{tag}..origin/#{RELEASE_BRANCH} for the stranded-work guard — " \
           "fetch, then re-run `bin/release prepare`"
  end

  commits = ahead_out.lines.map(&:chomp).reject { |l| l.strip.empty? }
  return nil unless Release::ShipSequence.stranded_gem_work?(
    ahead_commits: commits, version: version, tag_version: tag.delete_prefix("v")
  )

  Release::ShipSequence.stranded_gem_message(
    repo, ahead_commits: commits, version: version,
    version_file: gem_meta_for(repo)["version_file"],
    tag_version: tag.delete_prefix("v")
  )
end

# Install any migrations the just-published engines ship into this consumer's
# workspace, and leave db/schema.rb consistent with them.
#
# The DECISIONS — which task, what a probe's answer means, which database, whether
# a schema dump is committable — live in Release::EngineMigrationInstall, where a
# test can hold them. This is the half that runs commands. See that file for why
# the split exists (a fail-open probe skipped this step silently on every live
# sweep, which is the review finding that produced this shape).
def install_engine_migrations!(workspace, repo, gem_names)
  return if DRY

  # THE BUNDLE FIRST, and this is the line the first cut was missing. `bundle
  # lock` resolves without INSTALLING, and nothing else in the sweep installs the
  # version publish_gem pushed seconds ago — so `bin/rails` in this workspace
  # raises Bundler::GemNotFound and every probe below reads as "not an engine".
  ensure_suite_bundle!(repo, workspace, role: "ship")

  installable = gem_names.select { |gem_name| workspace_engine_task(workspace, repo, gem_name) }
  return if installable.empty?

  before, = git_capture("-C", workspace, "status", "--porcelain", "--", "db/migrate")

  installable.each do |gem_name|
    task = Release::EngineMigrationInstall.install_task(gem_name)
    _, ok = sh("bin/rails", task, chdir: workspace, capture: true, env: gate_env(repo, role: "ship"))
    abort!("#{repo}: `bin/rails #{task}` failed in the ship workspace — the consumer cannot receive " \
           "#{gem_name}'s migrations, and shipping without them reddens its suite after the gem is published") unless ok
  end

  after, = git_capture("-C", workspace, "status", "--porcelain", "--", "db/migrate")
  if after.to_s == before.to_s
    say("  #{repo}: no new #{installable.join(', ')} migrations to install")
    return
  end

  copied = after.to_s.lines.map(&:strip).reject { |line| before.to_s.include?(line) }
  step("  #{repo}: installed #{copied.length} engine migration(s) — #{copied.join(', ')}")

  dump_consumer_schema!(workspace, repo)
end

# Does this workspace's app define the engine installer for `gem_name`?
#
# ASKED, and the answer DISCRIMINATED. A non-zero `bin/rails -T` means the app did
# not boot — a broken bundle, a missing master.key — and in a fail-closed function
# "I could not tell" must never read as "nothing to do". An absent task exits 0
# with no match, which is the only silent skip there is.
def workspace_engine_task(workspace, repo, gem_name)
  task = Release::EngineMigrationInstall.install_task(gem_name)
  return false if task.nil?

  out, ok = sh("bin/rails", "-T", task, chdir: workspace, capture: true, env: gate_env(repo, role: "ship"))
  case Release::EngineMigrationInstall.probe_verdict(ok: ok, output: out, task: task)
  when :present then true
  when :absent  then false
  else
    abort!("#{repo}: could not boot the app in the ship workspace to ask whether #{gem_name} ships " \
           "migrations (`bin/rails -T` exited non-zero). Refusing to skip the install on an answer " \
           "nobody got — a consumer missing an engine migration reddens after the gem is published.\n#{out}")
  end
end

# Run the workspace's migrations against a throwaway database so the dumper
# rewrites db/schema.rb, then drop it. The URL comes from the same helper the gate
# uses, so a SQLite app (rolio) is handed nil and stays on its own workspace file
# rather than a postgres:// URL it cannot use.
def dump_consumer_schema!(workspace, repo)
  base = gate_database_url(repo, role: "ship")
  url = Release::EngineMigrationInstall.throwaway_database_url(base_url: base, repo: repo, pid: Process.pid)

  # FAIL CLOSED on the one combination that would be dangerous: a Postgres app
  # whose throwaway URL could not be derived. gate_env already carries the GATE's
  # own TEST database in DATABASE_URL/TEST_DATABASE_URL, so proceeding here would
  # run db:create + db:schema:load against a database a concurrent conductor may
  # be mid-suite on. A SQLite app has no base URL at all and is meant to fall
  # through to its own workspace file.
  # Plain Ruby, not `present?`: bin/release is a SCRIPT that requires a handful of
  # models directly, with no ActiveSupport core_ext loaded — an ActiveSupport-ism
  # here dies at runtime, on the sweep, right after an irreversible publish.
  abort!("#{repo}: could not derive a throwaway database from #{base.inspect} — refusing to refresh " \
         "db/schema.rb against the gate's own database") if !base.to_s.strip.empty? && url.nil?

  # RAILS_ENV=development, and DATABASE_URL replaced rather than inherited: the
  # dumper writes db/schema.rb from the dev environment, and the database it
  # touches must be the throwaway one this function named.
  env = gate_env(repo, role: "ship").merge("RAILS_ENV" => "development")
  env = url ? env.merge("DATABASE_URL" => url, "TEST_DATABASE_URL" => url) : env.merge("DATABASE_URL" => nil, "TEST_DATABASE_URL" => nil)

  begin
    _, created = sh("bin/rails", "db:create", "db:schema:load", "db:migrate", chdir: workspace, env: env, capture: true)
    abort!("#{repo}: could not migrate a throwaway database to refresh db/schema.rb — the migration would " \
           "otherwise land unrun and every suite would fail on a pending migration") unless created

    diff, = git_capture("-C", workspace, "diff", "--", "db/schema.rb")
    unless Release::EngineMigrationInstall.schema_dump_safe?(diff)
      abort!("#{repo}: refreshing db/schema.rb removed or rewrote existing schema, not just the new table. " \
             "That means this repo's committed schema was already behind its own migrations; fix that in the " \
             "repo, then re-run `bin/release prepare`.\n#{diff}")
    end
  ensure
    # Only a database WE named gets dropped. With no URL the app is on its own
    # workspace file, which dies with the workspace.
    sh("bin/rails", "db:drop", chdir: workspace, env: env, capture: true) if url
  end
end

# Bump each consumer's Gemfile.lock (and, only when the new version ESCAPES the
# existing constraint, its Gemfile pin) to the just-published gem versions —
# COMMITTED onto the consumer's origin/release, BEFORE the pre-QA gate and the
# QA deploy. That one commit is what makes the whole move sound: the pre-QA CI
# verdict targets the post-bump release SHA, QA bundles the new lock, and prod
# ships the exact tree QA tested (ship's repin then finds nothing to do).
#
# Built in the repo's ship workspace pinned at origin/release's tip (the same
# never-touch-the-primary mechanics as ship's repin_consumers), pushed by ref
# fast-forward-checked. Idempotent: a lock already at the published versions
# commits nothing; a consumer whose Gemfile never declares the gems is skipped.
def bump_consumer_locks_for_qa(app_groups, published_gems)
  return if published_gems.empty?

  # HERE, not at the call site. This commit is the thing that triggers CI, so the
  # wait belongs to the function that makes it — every caller inherits it and there
  # is no call site left to forget. (bin/release.rb learned that exact lesson one
  # task earlier: a guard wired in front of ONE of two callers never ran.)
  #
  # `unless DRY` IS LOAD-BEARING, not politeness. A dry run PREVIEWS the plan without
  # any git/gh call so the preview stays hermetic — and this wait reaches the network.
  # Without the guard a `--dry-run` polls the live RubyGems index for up to
  # RELEASE_GEM_POLL_TIMEOUT seconds per gem: the meta-tests that drive `--dry-run`
  # hung for an HOUR on exactly that before this line was added.
  await_published_gems!(published_gems) unless DRY

  gem_names = published_gems.keys
  step("bump consumer locks for #{gem_names.join(', ')} on origin/#{RELEASE_BRANCH} — " \
       "the pre-QA gate, QA, and prod must all build this SAME committed lock")
  app_groups.each do |group|
    repo = group["repo"]

    if DRY
      step("  #{repo}: bundle lock --update <gem> --conservative in the ship workspace @ origin/#{RELEASE_BRANCH} " \
           "(rewrite the Gemfile pin only if the new version escapes it) → install any new engine migrations " \
           "(<gem>:install:migrations + db:migrate on a throwaway database, so db/schema.rb lands with them) → " \
           "commit + push origin #{RELEASE_BRANCH} (idempotent; no-op when already current)")
      next
    end

    path = repo_path(repo)
    abort!("app repo not found at #{path} — clone it as a sibling at the projects root") unless Dir.exist?(path)
    _, fetched = sh("git", "-C", path, "fetch", "origin", "--quiet")
    abort!("git fetch failed in #{repo} — refusing to bump the consumer lock against a possibly-stale " \
           "origin/#{RELEASE_BRANCH} (fail closed); fix the remote, then re-run `bin/release prepare`") unless fetched
    out, ok = git_capture("-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}")
    abort!("could not resolve origin/#{RELEASE_BRANCH} in #{repo} for the consumer lock bump") unless ok
    tip = out.strip

    with_ship_workspace(repo) do
      workspace = ship_workspace!(repo, tip)
      ws_gemfile = File.join(workspace, "Gemfile")
      next unless File.exist?(ws_gemfile)

      text    = File.read(ws_gemfile)
      touched = gem_names.select do |gem_name|
        Release::ShipSequence.consumer_bump_action(text, gem_name, published_gems[gem_name]) != :absent
      end
      if touched.empty?
        say("  #{repo}: Gemfile does not declare #{gem_names.join(', ')} — no lock bump")
        next
      end

      expected = text.dup
      touched.each { |gem_name| expected = Release::ShipSequence.bumped_gemfile(expected, gem_name, published_gems[gem_name]) }
      File.write(ws_gemfile, expected) if expected != text
      # ASSERT THE LOCK, DO NOT INFER IT FROM THE DIFF — and RIDE THE LADDER while
      # doing it. `bundle lock --update` exits 0 whether or not it could SEE the
      # version we just published, so its exit status proves nothing about which
      # version landed. `expect:` makes bundle_lock re-read the lock and retry the
      # whole command on a stale resolution, aborting only once its propagation
      # backoff is exhausted (see bundle_lock).
      #
      # THE BUG (rel-20260809-3b8f3d, 2026-08-09): the unchanged-tree check below
      # used to run FIRST and report "lock already at <gem> <version>" — a version
      # it had never read. RubyGems had not propagated in the seconds since our own
      # `gem push`, the resolver kept the OLD version, the tree therefore did not
      # change, and the sweep announced 0.31.0 over a 0.30.0 lock. turf-monster
      # then rode QA on the old engine while the release record asserted the new
      # one, and — because its tree was unchanged — the pre-QA gate CREDITED its
      # identical-tree green, so no CI run contradicted it either. Nothing
      # downstream could catch it: a stale lock and a genuine no-op are identical
      # in the diff and trivially different in the lockfile.
      touched.each do |gem_name|
        bundle_lock(workspace, gem_name, conservative: true, expect: published_gems[gem_name])
      end

      # THE MIGRATIONS RIDE WITH THE LOCK. A consumer whose engine gained a
      # migration must receive it in the SAME commit that bumps its lock —
      # otherwise the pre-QA gate, which runs after the publish, reddens on a
      # migration nobody can now un-publish. See install_engine_migrations!.
      install_engine_migrations!(workspace, repo, touched)

      status, = git_capture("-C", workspace, "status", "--porcelain", "--",
                            "Gemfile", "Gemfile.lock", "db/migrate", "db/schema.rb")
      if status.to_s.strip.empty?
        # Now this claim is EARNED: the lock was read back above and genuinely
        # resolves the published version, so an unchanged tree really is a no-op.
        say("  #{repo}: lock verified at #{touched.map { |g| "#{g} #{published_gems[g]}" }.join(', ')} — nothing to commit (idempotent re-run)")
        next
      end

      bumps = touched.map { |g| "#{g} #{published_gems[g]}" }
      sh("git", "-C", workspace, "add", "Gemfile", "Gemfile.lock")
      # `--` and the existence check: a consumer with no db/ at all (a gem-only
      # repo in the app group) must not abort the sweep on a pathspec.
      %w[db/migrate db/schema.rb].each do |path_spec|
        sh("git", "-C", workspace, "add", "--", path_spec) if File.exist?(File.join(workspace, path_spec))
      end
      _, committed = sh("git", "-C", workspace, "commit", "-m", "bump #{bumps.join(', ')} for QA", capture: true)
      abort!("could not commit the consumer lock bump in #{repo}'s ship workspace") unless committed

      # Push the detached commit onto `release` BY REF, fast-forward-checked (no
      # --force) — a release branch that moved under us fails closed here,
      # before the gate reads a SHA this bump isn't part of.
      _, pushed = sh("git", "-C", workspace, "push", "origin", "HEAD:refs/heads/#{RELEASE_BRANCH}", capture: true)
      abort!("could not push the consumer lock bump to origin/#{RELEASE_BRANCH} in #{repo} (did #{RELEASE_BRANCH} move?)") unless pushed

      step("  #{repo}: committed #{bumps.join(', ')} onto origin/#{RELEASE_BRANCH} — " \
           "the pre-QA gate + QA deploy now read the post-bump SHA")
      # PUSHED to a shared branch. A later repo's abort must not imply this was
      # rolled back — it wasn't (see prepare's rescue arm).
      (@prepare_live ||= []) << "#{repo}: lock bump #{bumps.join(', ')} committed + pushed to origin/#{RELEASE_BRANCH}"
    end
  end
end

# MERGE-FORWARD: every app's `release` must CONTAIN `main` before the gate reads
# it. `main` moves outside the cycle — an emergency hotfix pushed straight to it —
# and a `release` that lags cannot ship.
#
# WHAT ACTUALLY GOES WRONG (stated precisely, because this paragraph is the
# operator's mental model): a lagging `release` does NOT revert the hotfix.
# push_frozen_main pushes `<sha>:refs/heads/main` WITHOUT --force, so git refuses
# the non-fast-forward and the SHIP IS BLOCKED. The cost is the whole cycle
# upstream of that refusal: a candidate gated, QA'd, and assembled without a fix
# that is already live in production, and a ship that dead-ends at the last gate.
# (Only a forced push could revert it, and nothing here forces.)
#
# THE INCIDENT THIS REWRITES (rel-20260809-3b8f3d, 2026-08-09). The old guard sat
# inside the QA-deploy loop and did its merge in the SHARED PRIMARY CHECKOUT:
#
#     sh("git", "-C", path, "checkout", RELEASE_BRANCH)     # result DISCARDED
#     _, fwd = sh("git", "-C", path, "merge", "origin/main", capture: true)
#
# Three defects compounded:
#   1. THE PRIMARY. The hub primary had an uncommitted delete-later.md (the ledger
#      bin/agent-worktree remove appends to), so git refused the checkout outright.
#   2. THE UNCHECKED CHECKOUT. Only the MERGE's result was tested. With the
#      checkout failed the primary was still on `main`, so `git merge origin/main`
#      ran against main and succeeded as "Already up to date" — a green no-op on
#      the WRONG BRANCH — and the push then sent the stale LOCAL release branch,
#      which origin rejected as non-fast-forward. The step was non-fatal, so the
#      sweep carried on and assembled a candidate whose release branch was MISSING
#      a hotfix already live in production.
#   3. THE PLACEMENT (fixed at the call site, step 4c). Running after the pre-QA
#      gate meant a merge that DID land moved origin/release past the certified SHA.
#
# So: merge in a DETACHED WORKSPACE (the primary is never touched and its dirt is
# irrelevant), CHECK EVERY STEP, and ABORT rather than continue non-fatally. A
# guard that cannot fail loudly is not a guard.
def merge_forward_release_branches(app_groups, gem_groups: [])
  groups = app_groups + gem_groups
  return if groups.empty?

  step("merge-forward guard: origin/#{RELEASE_BRANCH} must CONTAIN origin/main in every app + gem repo " \
       "(before the pre-QA gate certifies a SHA, and before any irreversible gem publish)")
  groups.each do |group|
    repo = group["repo"]

    if DRY
      step("  #{repo}: if origin/main isn't an ancestor of origin/#{RELEASE_BRANCH}, merge it forward " \
           "in a detached workspace → push origin #{RELEASE_BRANCH} (no-op when already contained)")
      next
    end

    path = repo_path(repo)
    unless Dir.exist?(path)
      abort!("repo not found at #{path} — clone it as a sibling at the projects root")
    end

    # Fail closed on the fetch: a stale origin/main would make the containment
    # check answer from a ref that no longer describes production.
    _, fetched = sh("git", "-C", path, "fetch", "origin", "--quiet")
    abort!("git fetch failed in #{repo} — refusing to judge merge-forward against a possibly-stale " \
           "origin/main (fail closed); fix the remote, then re-run `bin/release prepare`") unless fetched

    # PROVE origin/main EXISTS before asking whether it is contained.
    # `merge-base --is-ancestor` exits 1 for "not an ancestor" but 128 for "no
    # such ref", and both are merely non-zero here — so a missing or renamed
    # origin/main would fall through to the merge path and the operator would be
    # told to hand-resolve a conflict that does not exist. `--verify --quiet`
    # answers the existence question on its own.
    _, main_ok = sh("git", "-C", path, "rev-parse", "--verify", "--quiet", "origin/main", capture: true)
    abort!("could not resolve origin/main in #{repo} — the merge-forward cannot judge containment " \
           "without it (does the branch exist on the remote?)") unless main_ok

    _, in_sync = sh("git", "-C", path, "merge-base", "--is-ancestor", "origin/main", "origin/#{RELEASE_BRANCH}",
                    capture: true)
    next if in_sync

    tip, ok = git_capture("-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}")
    abort!("could not resolve origin/#{RELEASE_BRANCH} in #{repo} for the merge-forward") unless ok
    tip = tip.strip

    step("  merge-forward: origin/main → #{RELEASE_BRANCH} in #{repo} (main moved ahead)")

    with_ship_workspace(repo) do
      workspace = ship_workspace!(repo, tip)

      _, merged = sh("git", "-C", workspace, "merge", "origin/main", "-m",
                     "Merge main into #{RELEASE_BRANCH} (merge-forward)", capture: true)
      unless merged
        # Leave no half-merged workspace behind for the next run to trip over.
        sh("git", "-C", workspace, "merge", "--abort", capture: true)
        # SCOPE THE CLAIM TO THIS REPO. "Nothing was pushed" is false at sweep
        # grain and dangerously so: by the time this runs the batch
        # accepted→release PRs have merged, earlier repos in THIS loop may
        # already have merged and pushed their own merge-forward, and a RESUMED
        # sweep may carry a prior run's gem publish (unrepeatable) and consumer
        # lock bumps on origin/release. An operator told "nothing was pushed"
        # may reach for a `reset release` cleanup that would drop the batch
        # merge and strand a published gem. prepare's rescue arm prints the
        # @prepare_live already-done ledger (which every landed merge-forward
        # below feeds); this message only speaks for the repo it failed in.
        abort!("merge-forward CONFLICT in #{repo}: origin/main → #{RELEASE_BRANCH}. Nothing was pushed " \
               "FOR #{repo} and no primary checkout was touched. This is mid-sweep, though, so earlier " \
               "steps HAVE already landed and are NOT undone by this abort — the accepted→release batch " \
               "merges, any earlier repo's merge-forward, and on a RESUMED sweep a prior run's gem " \
               "publish (a RubyGems version can never be un-pushed) or lock bump. Do NOT `reset` " \
               "#{RELEASE_BRANCH} to 'clean up': that would drop the batch merge and strand a published " \
               "gem. Resolve the conflict on a branch off origin/#{RELEASE_BRANCH}, merge origin/main " \
               "into it, push to #{RELEASE_BRANCH}, then re-run `bin/release prepare` — it resumes.")
      end

      # Fast-forward-checked ref push (no --force): a release branch that moved
      # under us fails closed here rather than clobbering it.
      _, pushed = sh("git", "-C", workspace, "push", "origin", "HEAD:refs/heads/#{RELEASE_BRANCH}", capture: true)
      abort!("could not push the merge-forward to origin/#{RELEASE_BRANCH} in #{repo} (did #{RELEASE_BRANCH} " \
             "move?) — re-run `bin/release prepare`, it resumes") unless pushed
    end

    # READ BACK the property we came for. The push reported success; that is not
    # the same as containment holding, and the whole point of this rewrite is to
    # stop trusting a step's exit status in place of its effect.
    #
    # THE FETCH MUST BE CHECKED, or the read-back is a TAUTOLOGY. The push came
    # from a worktree that SHARES this repo's .git, so it already advanced the
    # local `refs/remotes/origin/<release>` ref. If this fetch silently fails
    # (network, auth), the containment check below reads the ref OUR OWN PUSH just
    # wrote — and it holds by construction, because we merged origin/main into it
    # moments ago. The assertion would degrade into exactly the "trust the exit
    # status" it exists to replace.
    _, refetched = sh("git", "-C", path, "fetch", "origin", "--quiet")
    abort!("could not re-fetch origin in #{repo} to VERIFY the merge-forward landed. The push reported " \
           "success, but the local origin/#{RELEASE_BRANCH} ref was written by that push, so checking it " \
           "now would prove nothing (fail closed). Fix the remote, then re-run `bin/release prepare`.") unless refetched

    _, contained = sh("git", "-C", path, "merge-base", "--is-ancestor", "origin/main",
                      "origin/#{RELEASE_BRANCH}", capture: true)
    unless contained
      abort!("merge-forward containment STILL does not hold in #{repo}: origin/main is not contained in " \
             "origin/#{RELEASE_BRANCH} after the push. Either the push did not take, or origin/main MOVED " \
             "AGAIN mid-sweep (another commit landing on main while this ran) — the read-back cannot tell " \
             "the two apart, and neither is safe to gate: the candidate would leave production's own " \
             "commits out. Re-run `bin/release prepare` — it resumes and merges the newer origin/main " \
             "forward.")
    end

    # Feed the already-done ledger prepare's rescue arm prints on a later abort:
    # this push is real remote state a "reset release" cleanup would destroy.
    (@prepare_live ||= []) << "#{repo}: merge-forward origin/main merged + pushed to origin/#{RELEASE_BRANCH}"

    step("  #{repo}: origin/#{RELEASE_BRANCH} now contains origin/main — the gate + QA read the merged tree")
  end
end

# Best-effort: commit a generated doc (a `retro` doc or the `delete-later.md`
# ledger `archive` updates) onto `release` so it stops piling up as uncommitted dirt
# in the primary. NON-FATAL — any problem leaves the doc uncommitted (which no
# longer blocks anything: the ship deploys from its own workspace and only ADVISES
# on a dirty primary) and never aborts retro/archive. The IO seam around the pure
# Release::ArtifactCommit:
#   - commit ONLY when the doc is the SOLE uncommitted change (never sweep up dirt),
#   - build on origin/release's tip (ff-only) so the push fast-forwards and the NEXT
#     ship's `main` ref push carries it — no main/release divergence,
#   - ALWAYS restore the checkout to `main` (ensure), even on failure,
#   - SKIP (doc stays uncommitted) when another invocation holds the primary
#     checkout — never flip HEAD under a running pre-QA gate suite
#     (with_primary_checkout, wait: false).
# `abs_path` takes one path OR many — many for the archive beat's docs sweep,
# which retires a batch of frozen snapshots and rewrites the ledger as ONE
# logical change. All of them must be named here, or the safety check reads the
# rest as unrelated work and strands the batch as dirt on the primary.
def commit_artifact_to_release(repo, abs_path, message)
  return if DRY

  path = repo_path(repo)
  rels = Array(abs_path).map { |p| p.to_s.delete_prefix("#{path}/") }
  rel  = rels.length == 1 ? rels.first : "#{rels.length} doc(s)"

  status, ok = git_capture("-C", path, "status", "--porcelain")
  unless ok && Release::ArtifactCommit.safe_to_commit?(status, rels)
    step("left #{rel} uncommitted (#{ok ? 'other changes present' : 'git status failed'}) — commit it via a docs PR")
    return
  end

  sh("git", "-C", path, "fetch", "origin", RELEASE_BRANCH, "--quiet", capture: true)

  # BEST-EFFORT lock (wait: false): if another invocation holds the primary
  # checkout, SKIP rather than stall archive/retro behind it, and NEVER flip HEAD
  # under a running suite (the rel-20260708-496cd8 false-negative G3). The doc
  # simply stays uncommitted — a non-fatal fallback that costs nothing now: a dirty
  # primary no longer blocks a ship, it only earns an advisory.
  done = false
  res = with_primary_checkout(repo, wait: false) do
    _, co = sh("git", "-C", path, "checkout", RELEASE_BRANCH, capture: true)
    if co
      _, ff = sh("git", "-C", path, "merge", "--ff-only", "origin/#{RELEASE_BRANCH}", capture: true)
      if ff
        sh("git", "-C", path, "add", "--all", "--", *rels, capture: true)
        _, committed = sh("git", "-C", path, "commit", "-m", message, capture: true)
        _, done = sh("git", "-C", path, "push", "origin", RELEASE_BRANCH, capture: true) if committed
      end
    end
  ensure
    sh("git", "-C", path, "checkout", "main", capture: true)
  end
  if res == :busy
    step("left #{rel} uncommitted (primary checkout busy — a concurrent bin/release gate/ship holds #{repo}) — commit it via a docs PR")
    return
  end

  step(done ? "committed #{rel} to #{RELEASE_BRANCH} (ships on the next release)" \
            : "left #{rel} uncommitted (commit/push failed) — commit it via a docs PR")
end

# Publish (or idempotently skip) one gem, then collapse its release → main at the
# frozen SHA. Skip when the version is already LIVE. Yank safety is delegated to
# `gem push` failing closed: a yanked number isn't in the listing → publish_needed?
# is true → we try to push → RubyGems rejects re-pushing it → publish_gem aborts,
# BEFORE any app deploys. Records the gem as live for the partial report.
# `member_slugs` are the gem's release members — stamped `merged: "main"` once the
# ff lands on origin (the interrupted-Avi crash-recovery signal).
def ship_gem(repo, version, frozen, member_slugs = [])
  abort!("could not resolve a version for gem #{repo} — check #{repo}/#{gem_meta_for(repo)['version_file']}") if version.empty? && !DRY

  if DRY
    step("gem #{repo} #{version}: publish to RubyGems from #{short(frozen)} " \
         "(skip if already live) → tag v#{version} → push #{repo} origin main → #{short(frozen)}")
    return
  end

  remote = rubygems_versions(repo)
  if !Release::ShipSequence.publish_needed?(version, remote)
    say("  gem #{repo} #{version} already live on RubyGems — skip publish (idempotent)")
  else
    # No listing-based yank check: the versions API omits yanked versions entirely
    # (no `yanked` field), so yank protection is delegated to `gem push` failing
    # closed — RubyGems forbids re-pushing a yanked number, so publish_gem aborts
    # loudly here (BEFORE any app deploy) if `version` was yanked.
    checkout_detached(repo, frozen) # build the artifact from the QA-frozen commit
    publish_gem(repo, version)      # reused: release-check → build → push → tag
  end
  @ship_live << "gem #{repo} #{version} live on RubyGems"
  push_frozen_main(repo, frozen)
  # The artifact build left the primary DETACHED at the frozen SHA (checkout_detached
  # — gems are the one repo class still built from their primary). Put it back on
  # main, best-effort: the gem is already published, so a checkout that won't restore
  # must never abort the train.
  restore_gem_primary(repo)
  record_merged_main(member_slugs)
end

# Is origin/release's head THIS RUN'S OWN re-pin of `frozen`, already pushed by a
# ship that died partway (so the retry must REUSE it, not mint a rival)? The I/O seam
# for Release::ShipSequence.resumable_repin? — it gathers the three facts and the
# pure model decides. All three reads run in the SHIP WORKSPACE, which shares the
# primary's object store, so the just-fetched origin/release commit resolves there.
#
# Any read that fails answers FALSE — never "probably fine". The caller then aborts
# as un-QA'd drift, which is the correct fail-closed direction: refusing a resumable
# ship costs a conversation, completing an unresumable one costs production.
def resumable_repin?(repo, workspace, frozen:, head:, expected_gemfile:)
  # 1. ANCESTRY — head is frozen PLUS something, not a divergent line.
  _, ancestor = sh("git", "-C", workspace, "merge-base", "--is-ancestor", frozen, head, capture: true)
  return false unless ancestor

  # 2. SHAPE — that something touches ONLY Gemfile/Gemfile.lock (no code rides out).
  diff, diff_ok = git_capture("-C", workspace, "diff", "--name-only", frozen, head)
  return false unless diff_ok

  # 3. IDENTITY — its Gemfile is byte-identical to what this run would write.
  gemfile, gemfile_ok = git_capture("-C", workspace, "show", "#{head}:Gemfile")
  return false unless gemfile_ok

  Release::ShipSequence.resumable_repin?(
    ancestor: true,
    changed_files: diff.to_s.lines,
    head_gemfile: gemfile,
    expected_gemfile: expected_gemfile
  )
end

# Auto-re-pin (D1): after ALL gems are live, before any app deploys, re-pin each
# consumer's branch-ref'd gem line to the published `~> x.y` so prod builds
# against the release, not a branch. Idempotent (already-pinned → no-op). One
# pass per consumer; the re-pin commit ships on TOP of the frozen SHA (so only
# frozen + the mechanical re-pin reach prod — guarded against un-QA'd drift).
#
# It builds that commit in the SHIP WORKSPACE, not the primary. It used to
# `git checkout release` in the shared primary, write the Gemfile there, commit and
# push — a checkout flip plus a commit in a tree a feature session may be using,
# which is why the ship had to refuse a dirty primary in the first place. The
# workspace is already pinned (detached) at the frozen SHA — exactly the base this
# commit must sit on — so the commit is built there and pushed by ref
# (`HEAD:refs/heads/release`, fast-forward-checked). The primary is never touched
# and never even read.
def repin_consumers(app_groups, published_gems, ship_sha)
  return if published_gems.empty?

  gem_names = published_gems.keys
  step("auto-repin consumers of #{gem_names.join(', ')} → ~> x.y (after all gems live, before any deploy)")
  app_groups.each do |group|
    repo = group["repo"]
    path = repo_path(repo)

    if DRY
      step("  #{repo}: re-pin any branch-ref'd published gem in Gemfile (ship workspace @ frozen) → " \
           "bundle lock --update → commit + push origin #{RELEASE_BRANCH} (idempotent; no-op if already pinned)")
      next
    end

    with_ship_workspace(repo) do
      workspace = ship_workspace!(repo, ship_sha[repo])

      # The workspace HEAD must BE the frozen SHA. It is by construction (it was
      # just reset --hard onto it), so this asserts the pin actually took rather
      # than trusting it: EVERY decision and edit below reads this tree, commits on
      # this HEAD, and pushes it to `release`, so a wrong HEAD here would ship
      # un-QA'd code. (The old check was the same invariant on the primary's local
      # `release` branch, where an un-pushed local commit could sit.)
      local_head, local_ok = git_capture("-C", workspace, "rev-parse", "HEAD")
      abort!("could not read the ship workspace HEAD in #{repo} for re-pin") unless local_ok
      if local_head.strip != ship_sha[repo]
        abort!("#{repo} ship workspace HEAD (#{short(local_head.strip)}) is not the QA-frozen SHA " \
               "(#{short(ship_sha[repo])}) — REFUSING to build the re-pin on the wrong base")
      end

      # DECIDE FROM THE FROZEN TREE — never from the primary.
      #
      # This read used to come from the PRIMARY's Gemfile, and it was safe only
      # because of two things this change removed: the ship ff'd the primary's `main`
      # to the frozen SHA, and the preflight refused a dirty/off-main primary. With
      # the invariant gone, a primary read is a silent, prod-affecting lie in BOTH
      # directions (carl, PR #517):
      #   * The primary's `main` is now one release behind BY DEFINITION (nothing
      #     ff's it). If the FROZEN tree branch-refs a gem while the primary's stale
      #     main still carries the previous `~> x.y` pin, the decision comes back
      #     EMPTY, prints a reassuring "already pinned", and the app DEPLOYS A FROZEN
      #     SHA WHOSE GEMFILE STILL POINTS AT A GIT BRANCH — prod building the gem
      #     from a branch instead of the published version, which is the exact hazard
      #     auto-re-pin exists to prevent. It FAILS GREEN.
      #   * The mirror: a dirty/feature-branch primary that branch-refs a gem the
      #     frozen tree already pinned would make the rewrite a no-op, stage nothing,
      #     and abort at the commit — AFTER THE GEMS PUBLISHED.
      # The tree the re-pin is built ON is the only tree entitled to decide whether
      # it is needed.
      ws_gemfile = File.join(workspace, "Gemfile")
      next unless File.exist?(ws_gemfile)

      frozen  = ship_sha[repo]
      text    = File.read(ws_gemfile)
      pending = Release::ShipSequence.gems_to_repin(gem_names, text)
      if pending.empty?
        say("  #{repo}: Gemfile at the frozen SHA is already pinned for #{gem_names.join(', ')} — no re-pin")
        next
      end

      # EXACTLY what this run would write — computed up front, because it is both the
      # content we are about to commit AND the identity a prior partial ship's re-pin
      # must match to be reusable (see below).
      expected = text.dup
      pending.each { |gem| expected = Release::GemfileRepin.rewrite(expected, gem, published_gems[gem]) }

      # The re-pin must build on the QA-frozen SHA. Fetch first so the origin check
      # reads the TRUE remote (not a stale local origin/release ref), then require
      # origin/release == frozen so a post-prepare merge to origin can't sneak out
      # un-QA'd under cover of the re-pin. (A ref read + a fetch — no working tree.)
      _, fetched = sh("git", "-C", path, "fetch", "origin", "--quiet")
      abort!("could not fetch origin in #{repo} for re-pin — check the remote, then re-run `bin/release ship`") unless fetched

      head, ok = git_capture("-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}")
      abort!("could not read origin/#{RELEASE_BRANCH} in #{repo} for re-pin") unless ok
      head = head.strip

      if head != frozen
        # origin/release MOVED. Before calling that un-QA'd drift, ask the only
        # question that matters: IS IT THIS RUN'S OWN RE-PIN, already pushed by a
        # ship that published the gems and then died? (Release::ShipSequence —
        # ancestry + Gemfile/Gemfile.lock-only + a BYTE-IDENTICAL Gemfile.) If it is,
        # the act is already done: ship THAT commit rather than mint a rival with the
        # same tree, which is what wedged the retry — its push is non-fast-forward
        # against the re-pin already on the branch, and the ship could never complete.
        if resumable_repin?(repo, workspace, frozen: frozen, head: head, expected_gemfile: expected)
          say("  #{repo}: the re-pin for #{short(frozen)} is ALREADY on origin/#{RELEASE_BRANCH} " \
              "(#{short(head)}) — a prior partial ship pushed it. REUSING that commit (minting a second " \
              "one would be a non-fast-forward and could never land).")
          @ship_live << "re-pin already live on origin/#{RELEASE_BRANCH} in #{repo} (#{short(head)})"
          ship_sha[repo] = head
          next
        end

        abort!("#{repo} origin/#{RELEASE_BRANCH} (#{short(head)}) drifted past the QA-frozen SHA " \
               "(#{short(frozen)}), and the drift is NOT this run's own re-pin (it changes more than " \
               "Gemfile/Gemfile.lock, or its Gemfile is not what this ship would write) — so code would " \
               "reach production un-QA'd. Re-run `bin/release prepare` to re-QA before re-pinning.")
      end

      File.write(ws_gemfile, expected)
      text = expected
      # Same read-back the prepare-side bump does, for the same reason: a
      # `bundle lock --update` that cannot see the version resolves the old one
      # and still exits 0. `expect:` puts that check INSIDE bundle_lock's
      # propagation ladder, so a slow index is waited out rather than aborting a
      # ship that has already published gems and fast-forwarded mains. Propagation
      # lag is far less likely here (these gems published back at prepare, not
      # seconds ago), but "less likely" is not a guarantee, and this commit is the
      # last thing between the frozen SHA and a production deploy.
      pending.each { |gem| bundle_lock(workspace, gem, expect: published_gems[gem]) }

      pins = pending.map { |gem| "#{gem} #{Release::GemfileRepin.pessimistic_constraint(published_gems[gem])}" }
      sh("git", "-C", workspace, "add", "Gemfile", "Gemfile.lock")
      _, committed = sh("git", "-C", workspace, "commit", "-m", "repin #{pins.join(', ')}", capture: true)
      abort!("could not commit the re-pin in #{repo}'s ship workspace") unless committed

      # Push the detached commit onto `release` BY REF. Fast-forward-checked (no
      # --force), so a release branch that moved under us fails closed here — before
      # any app deploys.
      _, pushed = sh("git", "-C", workspace, "push", "origin", "HEAD:refs/heads/#{RELEASE_BRANCH}", capture: true)
      abort!("could not push the re-pin to origin/#{RELEASE_BRANCH} in #{repo} (did #{RELEASE_BRANCH} move?)") unless pushed

      new_head, = git_capture("-C", workspace, "rev-parse", "HEAD")
      ship_sha[repo] = new_head.strip # ship the re-pin commit (frozen + re-pin)
      @ship_live << "re-pinned #{pins.join(', ')} in #{repo}"
    end
  end
end

# "What's already live" pre-flight (live-only reads): per repo, is the gem
# version already on RubyGems / is the app's main already at the frozen SHA?
# Informational — the single confirm follows. A dry-run prints the plan instead.
def whats_live(repos, qa_shas)
  return if DRY

  say("")
  say("  Pre-flight — what's already live:")
  repos.each do |group|
    repo = group["repo"]
    if group["kind"] == "gem"
      version = gem_version_for(repo, group, frozen_sha_for(repo, qa_shas))
      live    = !Release::ShipSequence.publish_needed?(version, rubygems_versions(repo))
      say("    gem #{repo} #{version}: #{live ? 'LIVE on RubyGems — will skip' : 'not published — will publish'}")
    else
      # The LAST-KNOWN origin/main — the ref the ship actually advances
      # (push_frozen_main). Reading the LOCAL `main` here would report on a branch
      # nothing in the deploy depends on any more (the ship stopped ff'ing it).
      #
      # Deliberately NOT fetched. Nothing else in the ship path fetches now (the old
      # ff_main_local did), so this ref can be stale — but this is an INFORMATIONAL
      # pre-flight report, and a fetch here would put network I/O into a line that
      # decides nothing. If it is stale the report merely says "will ff" for a repo
      # already at the frozen SHA; the push itself is a harmless no-op. The
      # AUTHORITATIVE check is push_frozen_main, which is fast-forward-checked
      # server-side and fails closed on a genuinely diverged main.
      frozen        = qa_shas[repo].to_s
      main_sha, ok  = git_capture("-C", repo_path(repo), "rev-parse", "origin/main")
      at            = ok && !frozen.empty? && main_sha.strip == frozen
      say("    app #{repo}: origin/main (last known) #{at ? "already at #{short(frozen)}" : "will ff → #{short(frozen)}"}")
    end
  end
end

# Steffon's ship gate: run each app's full local suite (registry `test_cmd` — the
# full-suite tier, Release::STEP_TEST_TIERS["ship"]) on the FROZEN ship SHA —
# the exact code that ships — BEFORE the ship-authority gate, so approval can
# never authorize untested code (§1.2 "fixes shipped ≠ tested"). A red gate
# scoped-aborts before the confirm. Satellites self-gate (their own deploy runs
# their suite) → no `test_cmd` → skipped; a repo whose frozen SHA the G3 gate
# already certified with the same command self-gates too (see test_gate),
# recording the skip as a gate SOP.
#
# IT MUTATES NOTHING. It used to fast-forward each app's `main` in the primary
# first, so the suite could run on the frozen tree — but the suite MOVED to the
# isolated gate workspace (pinned at the frozen SHA, its own test DB), which is a
# strictly better tree to certify, so the ff became vestigial: it took the
# primary-checkout lock, flipped a shared checkout, and no longer fed anything.
# Dropping it means NOTHING in the ship — not a ref, not a checkout, not a lock —
# is touched before ship authority. A red gate or a declined confirm now leaves
# the entire machine exactly as it found it.
def run_ship_gate(app_groups, ship_sha, qa_gates)
  say("")
  step("Steffon ship gate: full suite (registry test_cmd) on the FROZEN ship SHA " \
       "(isolated workspace, before ship authority — nothing is mutated yet)")
  app_groups.each do |group|
    repo = group["repo"]
    test_gate(repo, frozen_sha: ship_sha[repo],
                    qa_gate: Release::ShipSequence.qa_gate(qa_gates, repo))
  end
end

# Deploy one app to prod via its registry adapter. Common prelude: advance
# origin/main to the frozen SHA (a ref push — the test gate already ran in
# run_ship_gate, before ship authority). Then the strategy-specific mechanic +
# smoke policy.
#
# NOTHING HERE READS THE PRIMARY'S WORKING TREE. That is the whole point of this
# region (2026-07-12): ask what the deploy actually NEEDS, and the answer splits
# cleanly in two.
#
#   * git_push_heroku (hub, rolio) needs NO WORKING TREE. "Deploy" is: hand a
#     commit to a git remote. So it is a ref push straight out of the shared object
#     store — `git push <remote> <frozen>:refs/heads/<branch>` — which is also
#     STRICTER than what it replaced: the old `git push heroku main` shipped
#     whatever the local `main` branch pointed at (correct only because an ff had
#     just moved it, in a checkout any concurrent session could disturb); this
#     ships the frozen SHA BY VALUE. Non-fast-forward is still refused by git (no
#     --force, ever), so a diverged remote fails closed exactly as before.
#
#   * repo_script (turf-monster) DOES need a working tree — its bin/deploy runs
#     the repo's own suite, hashes config/*.idl.json for the IDL pin, and pushes
#     from the checkout it runs in. It gets the SHIP WORKSPACE: a private detached
#     worktree pinned at the frozen SHA, prepared like a gate (bundle + a test DB
#     proven private), under the ship-workspace lock.
#
#     VERIFIED, not assumed (this is the assumption class that caused the bug being
#     fixed here): turf's bin/deploy computes `BRANCH=$(git rev-parse --abbrev-ref
#     HEAD)`, which in a DETACHED worktree is the literal "HEAD", and then pushes
#     `PUSH_SPEC="$BRANCH:main"` → `git push heroku-mainnet HEAD:main` — i.e. it
#     pushes the frozen commit to the Heroku app's main. Its `git remote get-url`
#     resolves because a linked worktree SHARES the repo config (no
#     extensions.worktreeConfig anywhere here), its `git diff-index --quiet HEAD`
#     clean-tree preflight passes (a freshly reset workspace is clean — where a
#     shared primary might not be), and the IDL files it hashes are TRACKED, so
#     they are present in the workspace. The one cosmetic difference is a "Not on
#     main (current: HEAD)" warn, which does not affect its exit status.
# --- resumable ship: is a group's frozen SHA ALREADY live on prod? -----------
# The I/O half of Release::ShipSequence.deploy_already_succeeded? — it gathers the
# live signals a killed watcher lost and hands them to the pure decision. Two
# callers: deploy_app skips a redundant re-dispatch on a `ship` RE-RUN, and
# `finalize` GUARDS against marking `shipped` a release that never deployed.
#
# All READS (they mutate nothing), so they run for real even in --dry-run — the
# same "a read previews without mutating" contract as git_capture / conductor
# (read_only:). They deliberately DO NOT go through `sh` (which would print
# "[dry-run]" and skip), so a dry-run finalize can preview the real verdict.
#   * origin/main via `git ls-remote` — the AUTHORITATIVE remote ref (never a
#     local branch: the ship no longer moves the primary's local main).
#   * prod /up via curl.
#   * github_actions ONLY: the deploy workflow's recent runs, scanned for a
#     completed+success run AT the frozen SHA (prod_run_succeeded?).
def origin_main_sha(repo)
  out, ok = git_capture("-C", repo_path(repo), "ls-remote", "origin", "refs/heads/main")
  ok ? out.to_s.split(/\s+/).first.to_s.strip : ""
end

def prod_up_ok?(base_url)
  url = base_url.to_s.strip
  return false if url.empty?

  out, status = Open3.capture2e("/usr/bin/curl", "-s", "-o", "/dev/null",
                                "-w", "%{http_code}", "#{url}/up")
  status.success? && out.strip == "200"
end

def deploy_workflow_runs(workflow, path)
  wf = workflow.to_s.strip
  return [] if wf.empty?

  out, status = Open3.capture2e("gh", "run", "list", "--workflow", wf, "--limit", "20",
                                "--json", "databaseId,headSha,status,conclusion", chdir: path)
  return [] unless status.success?

  JSON.parse(out)
rescue JSON::ParserError
  []
end

# The prod smoke URL for a group: the adapter's smoke_url, or the hub's PROD_URL
# for github_actions (its adapter keeps smoke_url for the board, and the hub IS
# PROD_URL). Blank → prod_up_ok? returns false (fail closed).
def group_smoke_url(group)
  adapter = group["prod_deploy"] || {}
  smoke = adapter["smoke_url"].to_s.strip
  return smoke unless smoke.empty?

  group["repo"] == APP ? PROD_URL.to_s : ""
end

# Decide — over live signals — whether `group`'s frozen SHA is genuinely deployed.
# Fails closed on any unreadable signal. deployed_at_sha (the repo_script marker)
# is left nil for now: turf's mainnet-release marker read is a future tightening,
# so a repo_script re-run re-dispatches (safe — its bin/deploy self-gates).
def deploy_already_live?(group, frozen)
  frozen = frozen.to_s.strip
  return false if frozen.empty?

  adapter  = group["prod_deploy"] || {}
  strategy = adapter["strategy"].to_s
  run_success =
    if strategy == "github_actions"
      Release::ShipSequence.prod_run_succeeded?(
        deploy_workflow_runs(adapter["workflow"], repo_path(group["repo"])), frozen
      )
    end

  Release::ShipSequence.deploy_already_succeeded?(
    strategy: strategy,
    up_ok: prod_up_ok?(group_smoke_url(group)),
    main_at_sha: origin_main_sha(group["repo"]) == frozen,
    run_success: run_success
  )
end

def deploy_app(group, frozen)
  @ship_live ||= [] # ship() seeds this; never let a nil deref be the way a deploy fails
  repo    = group["repo"]
  path    = repo_path(repo)
  adapter = group["prod_deploy"] || {}
  target  = Release::ShipSequence.deploy_target?(adapter)
  handler =
    if target
      begin
        Release::ShipSequence.strategy_handler(adapter["strategy"])
      rescue ArgumentError => e
        abort!(e.message)
      end
    end

  say("")
  step(if target
         "app #{repo} → prod via #{adapter['strategy']} @ frozen #{short(frozen)}"
       else
         "app #{repo} → main @ frozen #{short(frozen)} (no production deploy target — nothing to dispatch)"
       end)

  push_frozen_main(repo, frozen)
  # The ff landed on origin — stamp this repo's members merged:"main" (matrix:
  # assembled+main = prod-in-flight; an interrupted re-run reads it as "ff done").
  record_merged_main(Array(group["members"]).map { |m| m["slug"] })

  # NO DEPLOY TARGET — a registered app with no `prod_deploy` (chain-ops). Its
  # main is advanced and its members stamped merged:"main" above; there is simply
  # nothing to dispatch. Ship continues to the NEXT app instead of aborting, and
  # the record says what actually happened — never "deployed to production".
  # This is the honest half of the 2026-08-22 wedge fix; the other half is the
  # registry telling the truth (config/release_repos.yml).
  unless target
    step("deploy: #{repo} has NO production deploy target — nothing dispatched (main advanced only)")
    gate_sop("deploy:#{repo}", "no prod_deploy declared — nothing dispatched", true, 0)
    @ship_live << "app #{repo} main advanced to #{short(frozen)} (no production deploy target — nothing dispatched)"
    return
  end

  # RESUMABLE SHIP (fix option b): on a RE-RUN after a watcher-process kill left the
  # deploy landed but the ship stranded, skip re-dispatching a deploy that ALREADY
  # concluded success — a re-dispatch would re-run the whole deploy for nothing.
  # Only skips on affirmative, strategy-appropriate proof (deploy_already_live? →
  # ShipSequence.deploy_already_succeeded?, which fails closed); anything less falls
  # through to a normal deploy. Gated on !DRY so a dry-run preview always shows the
  # full dispatch plan.
  if !DRY && deploy_already_live?(group, frozen)
    step("deploy: #{repo} ALREADY live at frozen #{short(frozen)} (prod-deploy previously concluded success) — skipping re-dispatch")
    gate_sop("deploy:#{repo}", "skip re-dispatch (already deployed @ #{short(frozen)})", true, 0)
    @ship_live << "app #{repo} already deployed to production (resumed — re-dispatch skipped)"
    return
  end

  case handler
  when :git_push_heroku
    remote = adapter["remote"] || HEROKU_REMOTE
    branch = adapter["branch"] || "main"
    step("deploy: git -C #{repo} push #{remote} #{short(frozen)}:refs/heads/#{branch} (ref push — no checkout)")
    deploy_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _, ok = DRY ? [nil, true] : sh("git", "-C", path, "push", remote, "#{frozen}:refs/heads/#{branch}", capture: false)
    # The G4 gate's per-app deploy SOP — recorded BEFORE the abort so a failed
    # push still shows on the gate run the SystemExit wrapper closes.
    gate_sop("deploy:#{repo}", "git push #{remote} #{short(frozen)}:refs/heads/#{branch}", ok || DRY,
             ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - deploy_started) * 1000).round)
    abort!("Heroku deploy failed for #{repo}") unless ok || DRY

    smoke = adapter["smoke_url"].to_s
    if smoke.empty?
      say("  (no smoke_url for #{repo} — smoke skipped)")
    else
      step("smoke: GET #{smoke}/up")
      # Block form so the emitted pass/fail reflects the HTTP code, not curl's
      # exit (curl exits 0 even on a 500 with -o/-w); abort semantics unchanged.
      code, = run_test_scope("prod_up_smoke", repo: repo, label: "curl #{smoke}/up") do
        out, = sh("/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "#{smoke}/up", capture: true)
        [out, out.strip == "200"]
      end
      say("  /up → #{code}") unless DRY
      abort!("smoke failed for #{repo} (#{smoke}/up != 200)") if !DRY && code.strip != "200"
    end
  when :repo_script
    command = adapter["command"].to_s
    args    = Array(adapter["args"])
    abort!("repo_script adapter for #{repo} has no `command`") if command.empty? && !DRY
    step("deploy: (cd #{repo} ship workspace @ frozen #{short(frozen)}) #{command} #{args.join(' ')} " \
         "— repo owns its smoke + rollback")
    if DRY
      gate_sop("deploy:#{repo}", "#{command} #{args.join(' ')}".strip, true, 0)
      @ship_live << "app #{repo} deployed to production"
      return
    end

    deploy_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ok = false
    # Under the SHIP-workspace lock (never the gate's, never the primary's): the
    # path is fixed, so a concurrent conductor could otherwise reset the tree — or
    # purge its DB — under a live production deploy.
    with_ship_workspace(repo) do
      workspace = ship_workspace!(repo, frozen)
      prepare_ship_workspace!(repo, workspace)
      # Refresh the index's stat cache before handing the tree to the repo's deploy
      # script. Our OWN prep dirties the stat cache without changing content: the
      # `reset --hard` writes files + index in the same clock-second (racy git), and
      # `db:test:prepare`/`bundle` bump tracked files' mtimes (a byte-identical
      # Gemfile.lock rewrite; a rails-boot touch). A deploy script that gates on
      # `git diff-index --quiet HEAD` (turf's bin/deploy) then misreads the stat-stale
      # tree as "uncommitted changes" and refuses a legitimate ship. `update-index
      # --refresh` re-hashes ONLY the stat-dirty entries and clears those whose content
      # is unchanged — a genuine content diff stays dirty (and is reported), so this
      # corrects the false positive without hiding real dirt. Never reset/checkout here.
      #
      # THE DEPLOY BELOW IS WRAPPED AT SUITE WEIGHT, EXPLICITLY, because it does NOT pass
      # through `run_test_scope` — it is a deploy, not a registered test scope, so no
      # registry row can reach it and it published only the conductor's ambient `light`
      # for its entire duration. That is the single worst place in this CLI to
      # under-report: turf-monster's `bin/deploy` runs `bin/rails test` INSIDE this call,
      # so the heaviest local workload the ship ever creates was the one telling peers the
      # machine was three-quarters free.
      #
      # The rationale sits HERE, above the refresh, rather than beside the wrap: the
      # refresh must stay within a few lines of the deploy it protects (pinned by
      # test/models/release/ship_index_refresh_test.rb), and a long comment between them
      # is exactly the drift that guard exists to catch. It caught this one.
      sh("git", "-C", workspace, "update-index", "-q", "--refresh", capture: true)
      # ship_deploy_env, NOT gate_env: a production deploy script gets its private
      # test DB and nothing else — no RAILS_ENV=test, no ruby pin. See ship_deploy_env.
      _, ok = ReleasePresence.with_phase(phase: ReleasePresence::PHASE_WORKING,
                                         weight: ReleasePresence::WEIGHT_SUITE) do
        sh(command, *args, chdir: workspace, env: ship_deploy_env(repo))
      end
    end
    # The G4 gate's per-app deploy SOP (see the git_push_heroku twin above).
    gate_sop("deploy:#{repo}", "#{command} #{args.join(' ')}".strip, ok,
             ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - deploy_started) * 1000).round)
    abort!("#{repo} deploy script failed (#{command}) — its own rollback applies; fix + re-run `bin/release ship`") unless ok
  when :github_actions
    # DevOps v2 Phase 2 (the hub): the Heroku push AND the hard /up smoke run
    # INSIDE the dispatched workflow, so there is NO separate conductor curl-smoke
    # here — dispatch_and_watch's success return already means "deployed AND
    # smoked green". push_frozen_main above still advanced origin/main by ref; the
    # workflow deploys the frozen SHA it is handed, independent of that push (which
    # is exactly why prod-deploy.yml is workflow_dispatch, not push:[main]).
    workflow = adapter["workflow"].to_s
    abort!("github_actions adapter for #{repo} has no `workflow`") if workflow.empty? && !DRY
    step("deploy: gh workflow run #{workflow} -f sha=#{short(frozen)} — GitHub Actions does the Heroku push + hard /up smoke")
    deploy_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ok = dispatch_and_watch(workflow, { "sha" => frozen }, chdir: path)
    gate_sop("deploy:#{repo}", "gh workflow run #{workflow} -f sha=#{short(frozen)}", ok || DRY,
             ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - deploy_started) * 1000).round)
    abort!("GitHub Actions prod deploy failed for #{repo} (#{workflow}) — check the run; fix + re-run `bin/release ship`") unless ok || DRY
  end
  @ship_live << "app #{repo} deployed to production"
end

# --- ship preflight: prove the ship can build its own trees -----------------
# WHAT THIS USED TO BE, and why it changed (2026-07-12). ship ff'd each app repo's
# `main` in the SHARED PRIMARY and ran the satellites' bin/deploy there, so the
# preflight REFUSED any app primary that was dirty or off `main`. That refusal
# ABORTED a production ship — after the gems had already published — because a
# concurrent feature session had staged work in the primary. The work could not be
# discarded (it was a live session's), so recovery meant a delicate
# stash-to-a-labeled-branch rescue at the worst possible moment.
#
# The deploy no longer reads those trees (push_frozen_main is a ref push;
# repo_script runs in the ship workspace), so an app primary's state is simply not
# input any more, and refusing on it would be theatre. What this step does now:
#
#   1. MATERIALIZE each app's ship workspace at the frozen SHA — the tree the
#      deploy will actually use — BEFORE anything is published or pushed. If a
#      worktree can't be created or pinned, the ship aborts HERE, where nothing is
#      live yet, instead of mid-train.
#   2. GATE the gem repos: a gem artifact is built from its primary and `gem build`
#      packages what is ON DISK, so a modified TRACKED file there would be
#      PUBLISHED. That is the one primary-state hazard left, and it is genuinely
#      unrecoverable (RubyGems forbids re-pushing a version) — so it aborts, and
#      the abort PRINTS THE RESCUE (commit the stranded work to a labeled branch;
#      never stash, never discard).
#   3. ADVISE on any dirty/off-main app primary — a note plus the same rescue,
#      never a blocker.
# The PURE decisions (offenders, advisory, rescue) live in Release::ShipSequence;
# this owns only the git reads. A dry-run prints the plan and runs NO git (so a
# preview never aborts on a legitimately-dirty dev sibling).

# The current branch + dirty-file list for a checkout (live git reads). Split out
# as the I/O seam ship_preflight calls per repo (stubbed in tests).
#
# `tracked_dirty` is the subset that would be PACKAGED by `gem build` — porcelain
# lines that are NOT "??" (untracked). Untracked files are invisible to the
# gemspec's `git ls-files`, so they are not a publish hazard and must not gate a
# ship; a modified tracked file is both.
def repo_git_state(repo, path)
  branch, = git_capture("-C", path, "rev-parse", "--abbrev-ref", "HEAD")
  status, = git_capture("-C", path, "status", "--porcelain")
  lines   = status.to_s.lines.map(&:chomp).reject { |l| l.strip.empty? }
  files   = lines.map { |l| l[3..].to_s.strip }.reject(&:empty?)
  tracked = lines.reject { |l| l.start_with?("??") }.map { |l| l[3..].to_s.strip }.reject(&:empty?)
  { "repo" => repo, "branch" => branch.to_s.strip, "dirty" => files.any?,
    "dirty_files" => files, "tracked_dirty" => tracked }
end

def ship_preflight(app_groups, gem_groups = [], ship_sha = {})
  say("")
  step("ship preflight: pin each app's ship workspace at its frozen SHA; check the gem builds")
  if DRY
    gem_groups.each { |g| say("  [dry-run] check #{g['repo']} (#{repo_path(g['repo'])}) has no modified tracked files (it is BUILT from its primary)") }
    app_groups.each { |g| say("  [dry-run] pin #{g['repo']} ship workspace (#{Release::GateWorkspace.path(repo_path(g['repo']), role: 'ship')}) at the frozen SHA") }
    return
  end

  # 1. The GEM gate — the one primary-state hazard that survives, because a gem is
  #    built from its primary checkout. Aborts BEFORE anything is published.
  gem_states = gem_groups.map { |g| repo_git_state(g["repo"], repo_path(g["repo"])) }
  gem_dirt   = Release::ShipSequence.gem_build_offenders(gem_states)
  abort!(Release::ShipSequence.gem_build_message(gem_dirt, root: projects_root)) if gem_dirt.any?

  # 2. Prove every app's ship workspace materializes at the frozen SHA NOW — an
  #    env failure (no disk, a wedged worktree registration) aborts here, where the
  #    release is still fully recoverable, rather than after the gems went out.
  app_groups.each do |group|
    repo = group["repo"]
    with_ship_workspace(repo) { ship_workspace!(repo, ship_sha[repo]) }
  end
  say("  ✓ #{app_groups.size} app ship workspace(s) pinned at the frozen SHA — the deploy runs from these, " \
      "not from the primaries")

  # 3. The app primaries: a NOTE, never a blocker. The ship does not read them.
  app_states = app_groups.map { |g| repo_git_state(g["repo"], repo_path(g["repo"])) }
  advisory   = Release::ShipSequence.advisory_message(
    Release::ShipSequence.preflight_offenders(app_states), root: projects_root
  )
  say(advisory) if advisory
end

# --- step 5c: production smoke SEAL -----------------------------------------
# AFTER every app deployed + the existing `/up` hard-gate passed (deploy_app), run
# the read-only @qa-readonly suite against PROD (bin/prod-smoke) and record a
# 🟢/🔴 SEAL on the release. A SEAL, NOT a gate: the deploy already happened, so a
# red seal ALERTS + prints the EXACT rollback but NEVER aborts the ship or
# auto-rolls-back — the operator stays the gate. Smokes the HUB only (the
# @qa-readonly spec is the hub's; turf owns its own bin/post_deploy_smoke).
#
# Runs BEFORE step 6's post_release_notes so the notes/Discord/board all read the
# SAME verdict (the seal write commits here; step 6 reloads the release by slug). The
# WRITE is best-effort: a prod-board blip on the seal record warns + continues —
# the red alert still prints from the LOCAL verdict, independent of the write.
#
# Returns the seal status ("passed"/"failed"), or nil when there was nothing to
# seal — the G4 gate close records it as metadata.seal (the seal is G4's
# NON-blocking closing beat: a red seal rides in sops + metadata but never
# flips the gate's success, exactly as it never aborts the ship).
def production_smoke_seal(app_groups, ship_sha, rel_slug)
  step("production smoke seal: bin/prod-smoke #{APP} (@qa-readonly vs prod) — post-ship SEAL, non-blocking")

  # Seal what we DEPLOYED: only when the hub (mcritchie-studio, whose @qa-readonly
  # spec this is) was actually part of this ship. A gem-only / satellite-only ship
  # changes nothing on the hub, so there is nothing to seal.
  unless app_groups.any? { |g| g["repo"] == APP }
    say("  (#{APP} not deployed in this ship — nothing to seal; skipped)")
    return nil
  end
  unless PROD
    say("  (local ship — the seal smokes the LIVE prod host only; skipped)")
    return nil
  end
  if DRY
    say("  [dry-run] bin/prod-smoke #{APP} → record 🟢/🔴 seal on #{rel_slug} (non-blocking)")
    return nil
  end

  record_release_event(rel_slug, "prod_smoke", "started")
  # ANCHOR the script to the hub checkout: bin/prod-smoke is cwd-relative, and a
  # ship run from outside the hub (rel-20260705-8fe04b ran from the projects
  # root) made Open3 raise Errno::ENOENT — aborting AFTER the prod deploy but
  # BEFORE step 6's Conductor.ship!, stranding the board at `assembled`. Every
  # other repo-scoped command resolves via repo_path; so does the seal now.
  # And because the seal is non-blocking BY CONTRACT (see above), an
  # unresolvable/missing script DEGRADES to a red seal instead of raising —
  # Open3 raises SystemCallError on a bad path, it never returns ok=false.
  # BOOT-WINDOW RETRY (rel-20260720-c06235): this seal runs seconds after the
  # Actions deploy, and a smoke landing inside the dyno boot/restart window can
  # fail against a HEALTHY prod (GET /tasks non-OK; 5/5 green on re-run). So on
  # a first failure Release::SealRetry waits ~30s and retries ONCE — only a
  # PERSISTING failure seals red, and a first-attempt pass never sleeps. The
  # retry is CALLER-SIDE so bin/prod-smoke stays an honest single-shot tool;
  # the seal's contract is unchanged — non-blocking, never auto-rolls-back.
  # The VERDICT composition (retry + seal + summary) lives in Release::SealRun so
  # it is testable on real objects; this script keeps the IO — chdir, capture,
  # telemetry, and the ship-log narration.
  smoke_error = nil
  result = Release::SealRun.call(
    host: PROD_URL,
    error: -> { smoke_error },
    on_retry: ->(delay) { say("  🔁 first smoke attempt failed — waiting #{delay}s for the dyno boot window, retrying once") }
  ) do |_attempt|
    smoke_error = nil # the FINAL attempt's error is the one the summary reports
    begin
      # Routed through the telemetry wrapper WITHOUT changing the seal's semantics:
      # same chdir + capture, and run_test_scope RE-RAISES a raised SystemCallError
      # (bad/missing script path) after emitting its FAILED action, so the rescue
      # below still degrades it to a red seal (never ok=false from Open3 raising).
      out, ok = run_test_scope("prod_smoke_seal", "bin/prod-smoke", APP,
                               capture: true, chdir: repo_path(APP), repo: APP)
    rescue SystemCallError => e
      out, ok, smoke_error = "", false, e.message
    end
    print out unless out.to_s.empty? # each attempt's output prints as it lands
    [out, ok]
  end
  ok      = result.ok
  seal    = result.seal
  summary = seal.summary
  host    = PROD_URL
  smoke_status = ok ? "completed" : "failed"

  # Record the seal on prod (best-effort). conductor() abort!s on a heroku-run
  # failure → SystemExit; the deploy already happened, so a board blip on this
  # write must NOT abort the ship. The verdict + rollback below stand regardless.
  begin
    conductor(
      "r = Release.find_by!(slug: #{rel_slug.inspect}); " \
      "r.record_smoke_seal!(Release::SmokeSeal.from_result(" \
      "passed: #{ok ? 'true' : 'false'}, summary: #{summary.inspect}, checked_at: Time.current)); " \
      "Release::Conductor.record_event!(release: r, step: 'prod_smoke', status: #{smoke_status.inspect}, " \
      "source: 'conductor', message: #{summary.inspect}, idempotency_key: \"\#{r.slug}:prod_smoke:#{smoke_status}\"); " \
      "puts({ sealed: r.smoke_seal&.status }.to_json)"
    )
    say("  seal recorded on #{rel_slug}: #{seal.badge} #{seal.status}")
  rescue SystemExit, StandardError => e
    say("  ⚠ seal not recorded — board write failed (#{e.message}); the verdict below still stands")
  end

  return seal.status if ok

  # RED SEAL — alert + the EXACT rollback. NON-BLOCKING: no abort, no auto-rollback.
  # Release.current is still `assembled` here (step 6 ships it next), so
  # Release#abandon! is still valid.
  say("")
  say("🔴 PRODUCTION SMOKE SEAL FAILED — #{host}")
  say("   The deploy already landed; this is a post-ship SEAL, so the ship is NOT aborted.")
  say("   Roll back ONLY if you decide to (the seal never auto-rolls-back):")
  seal.rollback_commands(repo: APP, heroku_app: APP, deployed_sha: ship_sha[APP]).each { |c| say("     #{c}") }
  say("")
  seal.status
end

# --- ship -------------------------------------------------------------------
def ship
  # RESUMABLE SHIP: `--finalize-only [<release>]` runs ONLY the record+seal+install
  # steps a watcher-process kill skipped, against an already-deployed frozen SHA.
  # It NEVER deploys — it guards that the SHA is genuinely live first, then records.
  # `bin/release finalize <release>` is the same path with its own verb.
  return finalize(Release::Cli.positional_slugs(ARGV).first) if Release::Cli.take_flag(ARGV, "--finalize-only")

  by = opt_value("--by") || ENV["USER"] || "operator"
  @ship_live = [] # the "what's live this run" trail for the partial-ship report
  steffon_span = false # set once the Steffon deploy-lane activity opens (gates its close)
  g4_gate = nil    # :open once the G4 Ship gate opens; :closed once a verdict lands

  say("Run Deployment#{PROD ? ' (PROD)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # LOCAL PRESENCE — see the twin in `prepare`. A ship runs its own test gate in the gate
  # workspace and then deploys, so it saturates this machine exactly as a sweep does and
  # publishes the same claim. Opened before the first read so it covers the whole run.
  # Best-effort and non-fatal.
  ReleasePresence.open!(kind: ReleasePresence::SHIP, root: File.expand_path("..", __dir__),
                        lane: "release:ship", session_id: conductor_session_id)

  # 1a. MINIMAL, STABLE read — resolve WHICH release ships + its slug, BEFORE the claim.
  #     If the prior run already promoted the release card but did not finish member flips,
  #     this resolves that shipped release by slug (Release.current || Release.last_shipped).
  #     A release's existence/slug don't change under a concurrent ship — only its member
  #     stages / state do — so this is safe pre-claim. read_only bypasses the dry gate.
  step("record (read-only): resolve the release to ship")
  head = conductor(
    "r = Release.current || Release.last_shipped; " \
    "abort('no active release to ship') unless r; " \
    "puts({slug: r.slug}.to_json)",
    read_only: true
  )
  rel_slug = head["slug"].to_s
  abort!("no active release to ship") if rel_slug.empty?

  # 1b. DEPLOYER CLAIM — take it BEFORE the MUTABLE decision snapshot below (carl: "ship
  #     snapshots mutable state before claiming"). The per-RELEASE `deployer` lock replaces
  #     the old `bin/devops-shift acquire avi` shift lease. A second concurrent `bin/release
  #     ship` on this release STANDS DOWN (exit 10) instead of double-shipping; a
  #     same-instance re-acquire is a no-op renew, so an INTERRUPTED ship re-run RESUMES its
  #     claim; a telemetry hiccup fails open. Released on EVERY exit via the rescue-SystemExit
  #     arm + the method-level ensure. Inert under --dry-run. No role span is open yet.
  acquire_conductor_claim!("deployer", rel_slug)

  # 1c. The MUTABLE decision snapshot — read UNDER the claim, addressed by the resolved
  #     rel_slug (no longer re-resolving current/last_shipped, which could drift). state /
  #     member stages / repo_plan / qa_shas drive resuming_member_ship + the assembled gate,
  #     so a concurrent ship/finalize must not be able to change them between the read and the
  #     deploy — hence under the claim.
  step("record (read-only): repo_plan + qa_shas + member/ship state")
  result = conductor(
    "r = Release.find_by!(slug: #{rel_slug.inspect}); " \
    "unfinished = r.tasks.where.not(stage: 'shipped').count; " \
    "abort('no active release to ship') unless r.active? || unfinished.positive?; " \
    "puts({slug: r.slug, state: r.state, branch: r.branch, " \
    "resuming_member_ship: (!r.active? && unfinished.positive?), unfinished_members: unfinished, " \
    "repos: Release::Conductor.repo_plan(r), qa_shas: (r.metadata['qa_shas'] || {}), " \
    "qa_gates: (r.metadata['qa_gates'] || {})}.to_json)",
    read_only: true
  )
  abort!("no active release to ship") if result["slug"].to_s.empty?
  state    = result["state"]
  repos    = result["repos"] || []
  qa_shas  = result["qa_shas"] || {}
  # What the G3 pre-QA gate CERTIFIED this run (repo => {sha, cmd, ok}) — the only
  # grounds on which G4 may skip its own suite. See Release::ShipSequence.
  qa_gates = result["qa_gates"] || {}
  resuming_member_ship = !!result["resuming_member_ship"]
  # Don't ship a candidate that hasn't been assembled + QA'd (the model would
  # otherwise allow assembling→shipped, bypassing the QA gate). The only
  # exception is retrying the final member flips for a release already marked
  # shipped by a prior production deploy record step.
  if !DRY && state != "assembled" && !resuming_member_ship
    abort!("release is '#{state}', not assembled — `bin/release prepare` + QA it first")
  end

  gem_groups = repos.select { |g| g["kind"] == "gem" } # already producer-first
  app_groups = Release::ShipSequence.ordered_app_groups(repos.select { |g| g["kind"] == "app" }) # hub first
  say("  shipping #{rel_slug} (#{state}): #{gem_groups.size} gem(s) → hub → #{[app_groups.size - 1, 0].max} satellite(s)")
  say("  resuming final member flips: #{result['unfinished_members']} unfinished") if resuming_member_ship
  say("  partial-ship: abort on first failure; re-run resumes (gems skip, ref pushes no-op, re-pins idempotent)")

  # The QA-frozen SHA to ship per repo (advanced by a re-pin commit in step 4).
  # Resolved BEFORE the preflight, which pins each app's ship workspace at it.
  ship_sha = {}
  repos.each { |g| ship_sha[g["repo"]] = frozen_sha_for(g["repo"], qa_shas) }

  # PREFLIGHT — before ANYTHING is published, pushed, or deployed: materialize the
  # ship workspaces at the frozen SHA (so an env failure aborts while the release is
  # still fully recoverable) and refuse a gem repo whose primary would publish
  # uncommitted tracked changes. A dirty APP primary is now only a note — the deploy
  # does not read it.
  ship_preflight(app_groups, gem_groups, ship_sha)

  # 2. "What's already live" pre-flight, then Steffon's ship gate, then explicit
  #    ship authority — turf included (its bin/deploy keeps its own smoke + rollback).
  whats_live(repos, qa_shas)

  # 2a. Steffon's ship gate (§1.2): run the FULL local suite (registry test_cmd) on
  #     the FROZEN ship SHA — the exact prod code — BEFORE ship authority, so
  #     "shipped" can never mean "untested". A red gate scoped-aborts here,
  #     before the confirm and before any push, leaving origin untouched.
  #     (Browser-level verification is the post-deploy prod smoke SEAL — the old
  #     "full e2e" wording here overstated what test_cmd runs.)
  #
  #     G4 SHIP opens HERE, spanning the frozen-SHA gate, the prod deploys,
  #     /up smokes, post-deploy hooks, and the smoke seal; the ship_gate
  #     ReleaseEvents STAY (they light the pizza tracker's stage stamps — gates
  #     record verdicts, never replace stamps). Closed success after the seal
  #     records, failed by the SystemExit wrapper below on any abort.
  record_release_event(rel_slug, "ship_gate", "started", actor: by)
  record_gate_open(rel_slug, "g4_ship", actor: by)
  g4_gate = :open
  run_ship_gate(app_groups, ship_sha, qa_gates)
  record_release_event(rel_slug, "ship_gate", "completed", actor: by)

  # 2a-bis. DEPLOY-TARGET PREFLIGHT — refuse BEFORE anything moves.
  #
  # Every registered `repo_script` deploy command must exist on disk. chain-ops
  # declared one that never did (2026-08-22): ship ran it, it failed, and the
  # abort landed AFTER push_frozen_main had advanced chain-ops' origin/main —
  # wedging G4 and blocking turf-monster from shipping in the same release. This
  # asks the question while the answer is still free. Placed BEFORE the ship
  # authority prompt so a bogus registry never even gets confirmed.
  # Probed at the FROZEN SHA, not in the primary working tree. The deploy runs in
  # a ship workspace checked out at that commit, so the frozen tree is the FACT
  # and the primary — whatever branch a session left it on — is only a proxy.
  bad_targets = Release::ShipSequence.missing_deploy_commands(app_groups) do |repo, command|
    _out, status = Open3.capture2e("git", "-C", repo_path(repo), "cat-file", "-e",
                                   "#{ship_sha[repo]}:#{command}")
    status.success?
  end
  if bad_targets.any?
    reasons = bad_targets.join("; ")
    # A DRY RUN previews the plan against a world it does not own (its SHAs are
    # placeholders, and its sibling repos may be fixtures), so it SAYS this
    # rather than aborting — the same `&& !DRY` convention the repo_script
    # adapter's own empty-command check already follows.
    if DRY
      say("  (dry-run) deploy target(s) unreadable at the frozen SHA: #{reasons}")
      say("  (dry-run) a real ship REFUSES here, before anything moves")
    else
      abort!("deploy target(s) missing: #{reasons}. Nothing has moved. Add the real " \
             "script, or drop `prod_deploy` if the app has no production target (ship then advances " \
             "main and dispatches nothing). Do NOT add a no-op deploy script.")
    end
  end

  # 2b. The ship-authority gate — explicit, AFTER Steffon's test confirmation and
  #     BEFORE any deploy. confirm() honors --yes (hands-off) + --dry-run (previews).
  step("ship authority: Steffon's ship gate passed on the frozen SHA — confirming production deploy")
  record_release_event(rel_slug, "ship_authorized", "started", actor: by)
  abort!("aborted — production deploy not confirmed") unless confirm("Deploy this release to production?")
  record_release_event(rel_slug, "ship_authorized", "completed", actor: by)

  # Deploy-lane narration: the ship is authorized — Steffon is shipping to prod. Open a
  # role activity (best-effort) so the heartbeat attributes the deploy to him, matching
  # the board's Steffon→shipped intent recorded just below. Opened AFTER ship authority
  # so a declined ship never shows Steffon shipping.
  open_role_span("steffon", "ship → prod")
  steffon_span = true

  # 2c. The ship is now authorized + proceeding — record the Steffon → shipped intent for
  #     every member so /deployments shows him shipping LIVE (a green ticking timer)
  #     through the deploy, instead of an empty dashed ship slot until `ship!` lands
  #     (the 2026-06-25 unfilled-ship-slot incident). Recorded AFTER ship authority
  #     so a declined ship never shows Steffon shipping. Append-only + idempotent
  #     (record_intent_event reuses the open intent; `ship!` supersedes it). On a
  #     partial-ship abort the intent stays open — correct (Steffon is still shipping) and
  #     a re-run reuses it. A board WRITE → suppressed in --dry-run. BEST-EFFORT
  #     (record_deploy_intent): a transient prod-board failure on this cosmetic ship-slot
  #     write must never abort the production deploy — it warns and continues.
  step("record: Steffon shipped intent (live crew ticker)")
  record_deploy_intent(
    "Steffon shipped intent",
    "r = Release.current; n = Release::Conductor.record_deploy_intents!(r, to_stage: 'shipped', actor: 'steffon'); " \
    "puts({ intent: 'shipped', actor: 'steffon', members: n.size }.to_json)"
  )
  record_release_event(rel_slug, "deploy_prod", "started", actor: by)

  # 3. Gems FIRST (producer-first): publish (skip-if-live; yank safety = `gem push`
  #    fails closed on a yanked number) + ff. On the happy path prepare already
  #    published every gem member BEFORE QA (publish_gems_for_qa), so this is the
  #    idempotent VERIFY — and the backstop for a release prepared before that.
  published_gems = {} # repo => version — every gem now live; consumers re-pin to these
  gem_groups.each do |group|
    repo    = group["repo"]
    version = gem_version_for(repo, group, ship_sha[repo])
    ship_gem(repo, version, ship_sha[repo], Array(group["members"]).map { |m| m["slug"] })
    published_gems[repo] = version
  end

  # 4. Auto-re-pin consumers (after ALL gems live, before any app deploy).
  repin_consumers(app_groups, published_gems, ship_sha)

  # 5. Apps hub-first, then satellites: test gate → prod adapter.
  app_groups.each { |group| deploy_app(group, ship_sha[group["repo"]]) }

  # 5b. Post-deploy hooks on PROD — after every app deployed + smoked, run each
  #     member's declared post_deploy_cmd against its PRODUCTION app, record the
  #     [post-deploy] outcome, and ABORT ship on a non-zero exit. Aborting here (a
  #     post-deploy failure) lands BEFORE the ship! record (step 6), so the release
  #     stays `assembled` (recoverable) and a re-run resumes (the command is
  #     idempotent). dry-run prints the plan.
  run_post_deploy(repos, target: :prod)

  # 5c. Post-ship production smoke SEAL — run the read-only @qa-readonly suite
  #     against PROD and record a 🟢/🔴 seal on the release. NON-BLOCKING (a red
  #     seal alerts + prints the rollback but never aborts the ship). BEFORE step 6
  #     so post_release_notes reads the SAME verdict. See production_smoke_seal.
  seal_status = production_smoke_seal(app_groups, ship_sha, rel_slug)

  # G4 verdict: every repo deployed, /up green, post-deploy hooks green — the
  # gate PASSED. The seal is G4's non-blocking closing beat: its result already
  # rides the sops (run_test_scope collector) and lands in metadata.seal here,
  # but a red seal does NOT flip success (the deploy landed; the operator stays
  # the gate on rollback, exactly as the seal never aborts the ship).
  record_gate_close(rel_slug, "g4_ship", true, metadata: seal_status ? { "seal" => seal_status } : {})
  g4_gate = :closed

  # 6. Record LAST — only after EVERY repo deployed. Stamp the hub's shipped SHA,
  #    promote the release card to Last Release immediately, then flip member
  #    tasks to `shipped` one second apart so live viewers see the deployment land
  #    before the task cards walk across the board. Address the release by slug:
  #    Release.current becomes nil as soon as the release is marked shipped.
  deployed_sha = ship_sha[APP].to_s
  # Fallback: read the ref the ship ACTUALLY advanced (origin/main), never the
  # primary checkout's HEAD. The ship no longer moves the primary's local branch, so
  # its HEAD may sit on a feature branch or a stale main — recording that as the
  # deployed SHA would put a commit on the release card that never went to prod.
  deployed_sha = git_capture("-C", repo_path(APP), "rev-parse", "origin/main").first.strip if deployed_sha.empty? && !DRY
  # Best-effort per-member usage for the assembled→shipped flips, captured from
  # the conductor's LOCAL transcript (the flips run on prod, transcript-less).
  ship_usage = move_usage_map(repos.flat_map { |g| Array(g["members"]).map { |m| m["slug"] } }.compact.uniq)
  step("record: Release::Conductor.ship! + post_release_notes")
  # record_shipped_shas FIRST, in the same call: it is what each repo's `main`
  # actually landed, and Release#ship! refuses to stamp a member spanning a repo
  # with no entry there (2026-08-13: turf's main never moved, the task said
  # otherwise).
  shipped = conductor(
    "r = Release.find_by!(slug: #{rel_slug.inspect}); " \
    "Release::Conductor.record_shipped_shas(release: r, shas: #{ship_evidence.inspect}); " \
    "Release::Conductor.ship!(release: r, deployed_sha: #{deployed_sha.inspect}, by: #{by.inspect}, production_url: #{PROD_URL.inspect}, usage_by_slug: #{ship_usage.inspect}, member_pause: #{BOARD_FLIP_CADENCE}); " \
    "Release::DurationCache.refresh_recent!(limit: 3); " \
    "notes = Release::Conductor.post_release_notes(release: r); " \
    "puts({slug: r.slug, state: r.reload.state, sha: r.deployed_sha.to_s[0,7], notes_delivered: notes[:delivered]}.to_json)"
  )

  say("")
  say("🚀 Shipped #{rel_slug} → production#{DRY ? ' (DRY RUN — nothing executed)' : " (#{short(deployed_sha)})"}.")
  say("  release notes: #{shipped['notes_delivered'] ? 'posted' : 'not delivered (webhook unset?)'}") unless DRY

  # 7. Restore each app's PRIMARY checkout to a clean `main`, now fast-forwarded to
  #    what shipped — the COMPLEMENT of ship_preflight's ADVISORY. The ship itself
  #    never touches these trees any more, so this is pure courtesy for the next
  #    session (a review/QA cycle can leave a primary on a leftover branch, and the
  #    next session would otherwise integrate from the wrong floor —
  #    retro-rel-20260623 line 54). Best-effort + non-fatal: the ship has already
  #    succeeded, and a primary carrying uncommitted/unpushed work is REFUSED and
  #    left exactly as its owner left it.
  restore_primaries(app_groups)

  # 7b. Sync the installed agent docs from the tree that just shipped — the OWNED
  #     pipeline run of bin/install-agent-docs (task name-install-agent-docs-owner).
  #     It must be POST-SHIP, not post-merge: the installer syncs from its own root,
  #     and only the hub's SHIP WORKSPACE (pinned at the shipped SHA) is guaranteed
  #     to hold exactly what shipped — the primary may be a release behind, or busy
  #     with a live session's work (a qa-release-time prepare run would install
  #     main's STALE docs and leave the drift in place). See sync_agent_docs.
  sync_agent_docs
  # Drop the deployer claim on a clean ship so the release frees immediately. Best-effort.
  release_conductor_claim!
  close_role_span("shipped #{rel_slug} → prod")
rescue SystemExit => e
  # G4 close-fail wrapper: an abort inside the gate window (a red frozen-SHA
  # gate, a failed deploy//up smoke, a post-deploy hook failure) IS the gate
  # failing — close the attempt `failed` with the collected SOPs. Best-effort
  # (record_gate_close can never raise) and the abort ALWAYS proceeds below
  # (raise in dry-run, exit(status) otherwise) — the close never masks it.
  record_gate_close(rel_slug, "g4_ship", false, metadata: { "aborted" => true }) if g4_gate == :open
  # Drop the deployer claim on an aborted ship (best-effort). A re-run is same-instance
  # and re-acquires (renews) to RESUME, so releasing here — rather than waiting out the
  # TTL — lets the release free sooner if this session is genuinely done. A stand-down
  # abort never acquired, so this is a no-op there.
  release_conductor_claim!
  # Close the Steffon activity on a partial-ship abort too (best-effort) so the
  # heartbeat activity resolves instead of hanging open. Gated by steffon_span so an
  # abort BEFORE the activity opened (e.g. no active release) never emits a stray
  # `end`.
  close_role_span("ship aborted partway") if steffon_span
  # Partial-ship recovery: abort! (Kernel#abort) raised SystemExit mid-train. The
  # abort message already printed; add what's live + the idempotent re-run path.
  raise if DRY # a dry-run abort (e.g. no active release) surfaces as-is

  if @ship_live&.any?
    warn("")
    warn("✗ Ship ABORTED partway — the release record is recoverable; re-run finishes unfinished deploy/member steps.")
    warn("  Already live this run:")
    @ship_live.each { |line| warn("    ✓ #{line}") }
    warn("  Re-run `bin/release ship` to resume: published gems skip, fast-forwards no-op, re-pins are idempotent.")
  end
  exit(e.respond_to?(:status) && e.status ? e.status : 1)
ensure
  # A raw StandardError (not a SystemExit) raised after the deployer claim was acquired
  # would escape BOTH the success path and the rescue-SystemExit arm above with the
  # renewer still holding the claim. The ensure frees it on EVERY exit — idempotent with
  # the releases above. Crash/SIGKILL still relies on the TTL; the same-session resume is
  # unchanged (a re-run re-acquires either way).
  release_conductor_claim!
  # The LOCAL presence claim closes exactly where the BOARD claim does. THIS IS AN
  # OPTIMIZATION, NOT THE CORRECTNESS STORY: a SIGKILLed conductor runs no ensure and
  # leaves its claim file behind ON PURPOSE, and the reader grades it a corpse against the
  # process table on the very next read — no timeout to elapse, no renewal to miss, so the
  # wedge window is ZERO rather than one TTL. Clearing here just keeps the report tidy.
  ReleasePresence.close!
end

# --- finalize: record the steps a KILLED ship skipped ------------------------
# `bin/release finalize <release>` (also `bin/release ship --finalize-only <release>`).
#
# THE STRAND IT HEALS. The github_actions hub ship WATCHES prod-deploy.yml as a
# long-lived process; GitHub Actions owns the Heroku push + /up smoke INDEPENDENTLY,
# so a harness/OS kill of the watcher (IOError, stream-closed) leaves the deploy
# LANDED but the board at `assembled` — Conductor.ship!, the smoke seal, and
# install-agent-docs never ran. This finishes exactly those steps, IDEMPOTENTLY,
# and REFUSES to run against a SHA that did not actually deploy. It replaces the
# fragile hand-run `heroku run` recovery recipe with one guarded command; the
# deploy mechanics (push_frozen_main, deploy_app) are untouched — this only wraps
# the record+seal+install tail.
#
# It is IDEMPOTENT: the pure Release::ShipSequence.finalize_pending? decides which
# of {seal, ship, notes} still need running from the release's own state, so a
# re-run on an already-finalized release is a clean NO-OP (no double Discord notes,
# no double records). install-agent-docs + primary-restore ride along (idempotent
# file ops) whenever any step is pending.
def finalize(slug = nil)
  by = opt_value("--by") || ENV["USER"] || "operator"
  @ship_live = []
  say("Finalize release (record the steps a killed ship skipped)#{PROD ? ' (PROD)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # 1. Resolve rel_slug with a MINIMAL, STABLE read FIRST — just `r.slug`. A release's
  #    existence and slug do NOT change under a concurrent finalize, so this is safe to
  #    read BEFORE the deployer claim. Address by the given slug, else the last
  #    shipped/active release (a strand sits at either `assembled` (nothing recorded) or
  #    `shipped` (a partial finalize)). read_only bypasses the dry gate, so it runs in a
  #    dry-run too.
  slug = slug.to_s.strip
  slug = opt_value("--slug").to_s.strip if slug.empty?
  step("record (read-only): resolve the release to finalize")
  lookup = slug.empty? ? "Release.current || Release.last_shipped" : "Release.find_by(slug: #{slug.inspect})"
  head = conductor(
    "r = #{lookup}; " \
    "abort('no release to finalize' + (#{slug.inspect}.empty? ? '' : \" for slug #{slug}\")) unless r; " \
    "puts({slug: r.slug}.to_json)",
    read_only: true
  )
  rel_slug = head["slug"].to_s
  abort!("no release to finalize") if rel_slug.empty?

  # 2. DEPLOYER CLAIM — take it BEFORE the MUTABLE decision snapshot below, so the
  #    snapshot (state/sealed/notes/members → finalize_pending?) is read UNDER the claim.
  #    Reading it before the claim is the bug jasper flagged: a concurrent finalizer
  #    could complete the pending steps in the gap and leave us replaying stale work.
  #    Two concurrent finalizes (or a finalize racing a fresh ship) now can't both
  #    proceed — one stands down. A same-instance re-acquire RENEWS, so a `ship →
  #    finalize` in one session, or a resumed finalize, resumes rather than standing
  #    down; a telemetry hiccup fails open. Inert under --dry-run (conductor_claim
  #    no-ops). finalize has NO outer rescue, so the claim is released on EVERY exit —
  #    the pending-empty/DRY `return`s, the guard/confirm `abort!`s, and clean
  #    completion — via the ensure (Ruby runs ensure on return AND on abort's SystemExit).
  acquire_conductor_claim!("deployer", rel_slug)
  begin
    # 3. The MUTABLE decision snapshot — read UNDER the claim, addressed by the resolved
    #    rel_slug (no longer re-resolving current/last_shipped, which could drift). It
    #    drives finalize_pending?, so it must be inside the claim: no concurrent
    #    finalizer can change these between the read and the mutations.
    step("record (read-only): release state + repo_plan + qa_shas + finalize state")
    result = conductor(
      "r = Release.find_by!(slug: #{rel_slug.inspect}); " \
      "puts({slug: r.slug, state: r.state, sealed: r.smoke_sealed?, " \
      "notes_completed: r.event_completed?('release_notes'), " \
      "members_all_shipped: r.tasks.where.not(stage: 'shipped').empty?, " \
      "repos: Release::Conductor.repo_plan(r), qa_shas: (r.metadata['qa_shas'] || {})}.to_json)",
      read_only: true
    )
    abort!("no release to finalize") if result["slug"].to_s.empty? # defensive (a --local dry with no DB)
    state   = result["state"]
    repos   = result["repos"] || []
    qa_shas = result["qa_shas"] || {}
    sealed  = !!result["sealed"]
    notes_completed = !!result["notes_completed"]
    members_all_shipped = result.fetch("members_all_shipped", true)

    # A release must be `assembled` (the strand) or `shipped` (a partial finalize) —
    # never finalize something still in QA (that would mark shipped a release the
    # deploy never even started).
    unless %w[assembled shipped].include?(state)
      abort!("release #{rel_slug} is '#{state}', not assembled/shipped — nothing to finalize (run `bin/release ship` to deploy it first)")
    end

    app_groups = Release::ShipSequence.ordered_app_groups(repos.select { |g| g["kind"] == "app" })
    ship_sha   = {}
    repos.each { |g| ship_sha[g["repo"]] = frozen_sha_for(g["repo"], qa_shas) }

    # 4. GUARD — REFUSE unless the frozen SHA is genuinely LIVE on prod for EVERY app.
    #    finalize records, it never deploys, so it must never mark shipped a release
    #    that did not deploy. deploy_already_live? fails closed on any unreadable /
    #    unconfirmed signal (per strategy — see Release::ShipSequence).
    say("")
    step("finalize guard: prove every app's frozen SHA is already live on prod")
    not_live = app_groups.reject { |g| deploy_already_live?(g, ship_sha[g["repo"]]) }
    if not_live.any?
      names = not_live.map { |g| "#{g['repo']} @ #{short(ship_sha[g['repo']])}" }.join(", ")
      # A DRY preview REPORTS the guard verdict but does not abort (so the plan still
      # prints); a real finalize REFUSES — it records an already-deployed release and
      # must never mark shipped a deploy that did not land.
      abort!("refusing to finalize — NOT confirmed live on prod: #{names}. " \
             "finalize records an already-deployed release; it never deploys. " \
             "If the deploy really did not land, run `bin/release ship` to deploy it.") unless DRY
      say("  ⚠ [dry-run] would REFUSE: NOT confirmed live on prod: #{names}")
    else
      say("  ✓ #{app_groups.size} app(s) confirmed live on prod at the frozen SHA")
    end
    # This guard is per-repo ship evidence, MEASURED against prod rather than
    # remembered from a push — so record it, exactly as a live ship records what it
    # pushed. Without it a resumed ship (whose push_frozen_main already ran, in a
    # process that is gone) would find no shipped_shas and Release#ship! would
    # correctly refuse to stamp its members — a jam where finalize already holds
    # the stronger proof. Gem groups ride the same record; ship evidence exempts
    # them, so a missing entry costs nothing.
    (app_groups - not_live).each { |g| ship_evidence[g["repo"]] = ship_sha[g["repo"]].to_s }

    # 5. What did the killed ship skip? (pure, from the release's own state.)
    pending = Release::ShipSequence.finalize_pending?(state: state, sealed: sealed,
                                                      notes_completed: notes_completed,
                                                      members_all_shipped: members_all_shipped)
    say("")
    if pending.empty?
      say("✓ #{rel_slug} is already finalized (state=#{state}, sealed, notes delivered) — nothing to do (clean no-op).")
      return
    end
    say("  pending finalize steps: #{pending.join(', ')}")

    # DRY stops here: the guard verdict + the pending plan are shown, nothing mutated.
    if DRY
      say("")
      say("✓ Finalize plan previewed (DRY RUN — nothing executed). Re-run without --dry-run to record #{pending.join('/')}.")
      return
    end

    abort!("aborted — finalize not confirmed") unless confirm("Finalize #{rel_slug} — record #{pending.join('/')} + install docs?")

    # 6. Run ONLY the skipped steps, in the live-ship order (seal 5c → ship! 6 →
    #    notes 6 → restore/install 7). Each is idempotent; finalize_pending? gates
    #    the two non-idempotent-by-nature ones (notes' Discord delivery; the ship!
    #    member cadence) so a re-run never double-fires.
    seal_status = production_smoke_seal(app_groups, ship_sha, rel_slug) if pending.include?(:seal)

    if pending.include?(:ship)
      deployed_sha = ship_sha[APP].to_s
      deployed_sha = git_capture("-C", repo_path(APP), "rev-parse", "origin/main").first.strip if deployed_sha.empty?
      step("record: Release::Conductor.ship! + DurationCache.refresh_recent!")
      # The live-on-prod verdict above IS this run's per-repo ship evidence — record
      # it before the member stamps read it (see the guard block).
      conductor(
        "r = Release.find_by!(slug: #{rel_slug.inspect}); " \
        "Release::Conductor.record_shipped_shas(release: r, shas: #{ship_evidence.inspect}); " \
        "Release::Conductor.ship!(release: r, deployed_sha: #{deployed_sha.inspect}, by: #{by.inspect}, production_url: #{PROD_URL.inspect}, usage_by_slug: {}, member_pause: #{BOARD_FLIP_CADENCE}); " \
        "Release::DurationCache.refresh_recent!(limit: 3); " \
        "puts({slug: r.slug, state: r.reload.state, sha: r.deployed_sha.to_s[0,7]}.to_json)"
      )
    end

    if pending.include?(:notes)
      step("record: Release::Conductor.post_release_notes")
      notes = conductor(
        "r = Release.find_by!(slug: #{rel_slug.inspect}); " \
        "n = Release::Conductor.post_release_notes(release: r); " \
        "puts({notes_delivered: n[:delivered]}.to_json)"
      )
      say("  release notes: #{notes['notes_delivered'] ? 'posted' : 'not delivered (webhook unset?)'}")
    end

    # 7. The idempotent tail: restore each app primary to a clean `main`, then sync
    #    the installed agent docs from the shipped hub tree (the install-agent-docs
    #    the killed ship skipped). Both best-effort + non-fatal.
    restore_primaries(app_groups)
    sync_agent_docs

    say("")
    say("✓ Finalized #{rel_slug} — recorded #{pending.join(', ')}. The board now reflects the shipped release.")
  ensure
    # Drop the deployer claim on EVERY finalize exit (the pending-empty/DRY returns, the
    # guard/confirm aborts, a conductor failure, or clean completion) — the anti-leak the
    # missing outer rescue would otherwise cause.
    release_conductor_claim!
  end
end

# Return each app's PRIMARY checkout to a clean `main` after a ship — the
# COMPLEMENT of ship_preflight's offender DETECTION (Release::ShipSequence). A
# review/QA cycle can leave a primary on a leftover `pr-NNN` branch, so the next
# session integrates/deploys from the wrong floor (retro-rel-20260623 line 54).
# Shells the same `bin/agent-worktree restore-primary` an operator runs by hand —
# which REFUSES (non-zero) any primary with uncommitted/unpushed work — so this is
# best-effort: a refusal is reported but NEVER fails an already-completed ship.
# No-op under --dry-run (the ship deployed nothing to restore around).
def restore_primaries(app_groups)
  return if DRY

  say("")
  step("restore primaries: return each app checkout to a clean `main` for the next session")
  Array(app_groups).each do |group|
    repo = group["repo"]
    out, status = Open3.capture2e("bin/agent-worktree", "restore-primary", repo)
    print(out)
    say("  ⚠ #{repo}: primary left as-is (uncommitted/unpushed work) — restore by hand") unless status.success?
  end
end

# Post-ship agent-docs sync — the OWNED pipeline step that runs
# bin/install-agent-docs after every prod ship, so adapter/skill/SOP merges stop
# leaving the installed docs (~/.claude + ~/.codex skills, the projects-root
# AGENTS.md/CLAUDE.md) drifted until someone happens to run the installer by hand
# (previously the only owned run was Alex's share-insights act).
#
# It installs from the hub's SHIP WORKSPACE — the tree pinned at the exact SHA that
# just shipped — falling back to the primary if there is no workspace (a ship that
# resolved no hub member). The installer syncs from its own $ROOT, so the tree it
# runs in IS the docs it installs, and the workspace is the only tree GUARANTEED to
# hold what shipped: the ship no longer fast-forwards the primary's local `main`
# (restore_primaries does, best-effort, and it correctly REFUSES a primary carrying
# a live session's work) — so reading the primary could install docs from a `main`
# that is one release behind. Runs unconditionally (idempotent file copies — a ship
# with no docs changes is a cheap no-op that also heals prior drift), and is
# NON-FATAL by construction (rescue-and-warn, like the merged:main stamps): a
# docs sync must never abort or fail an already-completed ship. Under --dry-run,
# `sh` prints the command and skips. Steffon owns this step; the warn line hands
# the by-hand fix to whoever is watching the ship.
def sync_agent_docs
  say("")
  step("sync installed agent docs: bin/install-agent-docs from the shipped hub tree")
  root = Release::GateWorkspace.path(repo_path("mcritchie-studio"), role: "ship")
  root = repo_path("mcritchie-studio") unless File.exist?(File.join(root, "bin", "install-agent-docs"))
  installer = File.join(root, "bin", "install-agent-docs")
  out, ok = sh(installer, capture: true)
  print(out)
  say("  ⚠ agent-docs install failed — run `#{installer}` by hand (the ship already succeeded)") unless ok
rescue StandardError => e
  say("  ⚠ agent-docs install skipped (#{e.message}) — run `bin/install-agent-docs` by hand (the ship already succeeded)")
end

# --- archive (the DevOps loop's conclusion) --------------------------------
# Run the worktree-reclaim batch. PREVIEW (apply: false) runs the reclaim tool's
# OWN dry-run (no --yes) — it only LISTS reclaimable worktrees, mutating nothing —
# so it runs for real even under bin/release --dry-run (a read, like
# conductor(read_only:), it bypasses sh's dry-run gate). With apply: true it adds
# --yes to actually stop each stack, flush its Redis DB, remove the worktree +
# branch, and refresh the registry (reclaims squash-merged legacy worktrees too).
# Streams the tool's output and returns [output, ok?] so the caller can count
# reclaimed worktrees for the summary.
def reclaim_worktrees(apply:)
  cmd = ["bin/agent-worktree", "cleanup", "--reclaim"]
  cmd << "--yes" if apply
  out, status = Open3.capture2e(*cmd)
  print(out)
  [out, status.success?]
end

# Parse the "reclaimed N worktree(s)" summary bin/agent-worktree prints after a
# --reclaim --yes teardown; 0 when nothing was reclaimed / the line is absent.
def reclaimed_count(out)
  out.to_s[/reclaimed (\d+) worktree/, 1].to_i
end

# The regenerable-artifact sweep, run exactly like the worktree reclaim above:
# apply: false is the tool's own --dry-run (report only, mutates nothing, so it
# runs for real even under bin/release --dry-run); apply: true performs it.
#
# It sweeps EVERY managed Rails repo and EVERY worktree under them, and boots
# each app to check whether a real log rotation cap is installed. That audit is
# the self-healing half: add a satellite that never inherits studio-engine's cap
# and the next archive run NAMES it, instead of it surfacing at 400 MB in six
# months.
#
# MACHINE-LOCAL. Unlike everything else in archive, this reads and writes THIS
# machine's disk — never the board. A fresh Mac's first archive sweeps almost
# nothing, and that is correct, not an anomaly.
def sweep_artifacts(apply:)
  cmd = ["bin/clean-artifacts"]
  cmd << "--dry-run" unless apply
  out, status = Open3.capture2e(*cmd)
  print(out)
  [out, status.success?]
end

# Pull the sweep's tagged JSON summary out of its output. Returns an empty hash
# when the line is absent, so a sweep hiccup degrades the archive's summary
# rather than aborting a run whose board work already succeeded.
def sweep_summary(out)
  ArtifactSweep.parse_summary(out) || {}
end

# The DOC sweep, driven the same way as the log sweep: apply: false is the tool's
# own --dry-run. It `git mv`s frozen snapshots — dated audits, release retros,
# misfiled dated designs — out of the LIVE doc tree into docs/agents/archive/,
# and rolls the delete-later ledger's resolved rows over.
#
# NOTHING IS EVER DELETED, and a snapshot something still cites is left exactly
# where it is and NAMED in the report: a referenced snapshot is someone's live
# citation, and the referrer gets fixed first, deliberately.
#
# Unlike the log sweep this touches TRACKED files, so its output is staged and
# then committed to `release` with the ledger, in one artifact commit — leaving
# the primary checkout clean rather than carrying a dozen staged renames as dirt.
#
# ITS EXIT STATUS IS LOAD-BEARING, and that is what separates this sweep from the
# two above it. The reclaim and the artifact sweep are MACHINE-LOCAL and
# best-effort: they run after the board write, and a hiccup there just means fewer
# worktrees freed this run, so both call sites take `.first` on purpose. This one
# refuses — and the caller must HONOUR that refusal, because the very next thing the
# beat does is commit the ledger and its archive to `release`. Taking `.first` here
# (which both call sites did until this was fixed) printed the refusal and committed
# the loss anyway. See the two `abort!`s below and
# test/lib/release_archive_docs_refusal_test.rb.
#
# THE EXIT STATUS SAYS "IT FAILED". IT DOES NOT SAY WHY. bin/archive-docs exits
# non-zero for a genuine ledger loss, for an UNREADABLE baseline, for an argument its
# guard does not account for, and for any crash inside the sweep. Reading one cause
# out of that single bit is what put "the delete-later ledger has lost resolved
# row(s)" in front of an operator during a production deploy when a `git mv` had
# simply crashed — see DocsArchive.failure_report, which is why the pieces of the
# answer (the repo swept, the command, the exit status, and stderr SEPARATED from
# stdout) are carried out of here instead of being flattened into one string.
DocsSweep = Struct.new(:repo, :command, :out, :err, :status, keyword_init: true) do
  def ok? = status.success?

  # Printable exit status. A signal death has a nil exitstatus, and printing "exit:"
  # blank there would hide the most interesting failure of the lot.
  def exit_label = status.exitstatus ? status.exitstatus.to_s : "killed by signal #{status.termsig}"
end

def sweep_docs(apply:)
  repo = repo_path("mcritchie-studio")
  cmd = ["bin/archive-docs", "--repo=#{repo}"]
  cmd << "--dry-run" unless apply
  # capture3, not capture2e: the failure report quotes STDERR specifically, and a
  # merged stream cannot say which lines were the complaint. Both are still printed,
  # on their own streams, so a passing run reads exactly as it always did.
  out, err, status = Open3.capture3(*cmd)
  print(out)
  warn(err) unless err.to_s.empty?
  DocsSweep.new(repo: repo, command: cmd.join(" "), out: out, err: err, status: status)
end

# THE LEDGER VERDICT, MEASURED — never inferred from an exit code.
#
# LedgerGuard.lost_against_ref is the same instrument bin/archive-docs refuses on:
# resolved rows counted as a MULTISET across delete-later.md AND its archive, against
# the merge base with HEAD. Counting the union is what makes it the honest test — a
# row that merely MOVED from the ledger into the archive is conserved (that is the
# whole archive beat), and only a row that left BOTH files is a loss. The 2026-09-01
# rollover this defect maligned was 41 out of one file and 41 into the other; this
# check calls that intact, because it is.
#
# Three outcomes, three sentences. `:unreadable` is NOT a pass: a comparison that
# could not run certifies nothing, and collapsing it into `:intact` would rebuild
# this very bug facing the other way. The bare StandardError rescue exists for the
# same reason — if the check itself breaks, the honest answer is "unknown", never
# "intact".
def ledger_verdict(repo)
  losses = LedgerGuard.lost_against_ref(repo, "HEAD")
  return { verdict: :intact } if losses.empty?

  { verdict: :lost,
    missing: losses.sum(&:missing),
    detail: LedgerGuard.report(losses, base_label: "HEAD") }
rescue LedgerGuard::UnreadableBase => e
  { verdict: :unreadable, detail: e.message }
rescue StandardError => e
  { verdict: :unreadable, detail: "#{e.class}: #{e.message}" }
end

def docs_summary(out)
  DocsArchive.parse_summary(out) || {}
end

# "Archive completed tasks": the conclusion of the Deploy lane. Archive every
# shipped task that ISN'T carried by the last shipped release (those stay as the
# board's "Last Release"), then reclaim the merged/shipped feature worktrees.
# Idempotent. The PURE rule lives in the unit-tested
# Release::Conductor.archive_completed! / .archivable_completed_slugs; this CLI
# owns the board WRITE + the worktree-reclaim I/O around it.
def archive
  say("Archive completed tasks#{PROD ? ' (PROD board)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # 1. Plan FIRST — a board READ (read_only:, so it runs even in --dry-run): the
  #    shipped tasks that WOULD archive + the last-release members KEPT shipped.
  step("record (read-only): plan archivable shipped tasks")
  plan = conductor(
    "puts({ archivable: Release::Conductor.archivable_completed_slugs, " \
    "kept: (Release.last_shipped&.tasks&.pluck(:slug) || []) }.to_json)",
    read_only: true
  )
  archivable = plan["archivable"] || []
  kept       = plan["kept"] || []

  sample = archivable.first(8).join(", ")
  sample += ", …(+#{archivable.size - 8})" if archivable.size > 8
  say("  #{archivable.size} shipped task(s) to archive#{archivable.empty? ? '' : ": #{sample}"}")
  say("  #{kept.size} last-release member(s) KEPT shipped#{kept.empty? ? '' : ": #{kept.first(8).join(', ')}"}")

  # 2. Worktree-reclaim PREVIEW — the reclaim tool's own dry-run (no --yes): it
  #    only LISTS reclaimable worktrees, mutating nothing, so it runs for real
  #    even under bin/release --dry-run.
  say("")
  step("worktree reclaim preview: bin/agent-worktree cleanup --reclaim")
  reclaim_worktrees(apply: false)

  # 3. Artifact-sweep PREVIEW — the sweep tool's own --dry-run, same contract as
  #    the reclaim above: it reports reclaimable bytes and names any app missing
  #    a log rotation cap, mutating nothing.
  say("")
  step("artifact sweep preview: bin/clean-artifacts --dry-run")
  sweep_preview = sweep_summary(sweep_artifacts(apply: false).first)

  # 4. Frozen-doc retirement PREVIEW — same contract again: it lists what would
  #    move out of the live doc tree and names anything a live citation pins.
  say("")
  step("docs archive preview: bin/archive-docs --dry-run")
  # A failing PREVIEW is the sweep tool itself being broken, not a lost ledger row:
  # bin/archive-docs' dry run REPORTS a loss and exits 0 by design, so this branch
  # cannot be reached by the invariant it checks. It fires when the preview could
  # not be produced at all — and confirming a sweep you were unable to preview is
  # the worst moment to carry on. Nothing has been mutated yet, so aborting here
  # costs nothing and stops short of the confirm.
  #
  # NO `ledger:` IS PASSED, deliberately. The ledger is not what failed here, and a
  # report that stayed silent about it is the honest one — `failure_report` then says
  # "not measured" rather than guessing in either direction.
  docs_preview_sweep = sweep_docs(apply: false)
  unless docs_preview_sweep.ok?
    abort!(DocsArchive.failure_report(
             command: docs_preview_sweep.command,
             exit_label: docs_preview_sweep.exit_label,
             stderr: docs_preview_sweep.err,
             consequence: "Nothing has been archived, reclaimed, or swept, and the confirm was never reached."
           ))
  end
  docs_preview = docs_summary(docs_preview_sweep.out)

  # 5. --dry-run stops here: the plan + all three previews are shown, nothing mutated.
  if DRY
    say("")
    say("✓ Archive plan previewed (DRY RUN — nothing executed). Re-run without --dry-run to archive + reclaim + sweep.")
    say("  would reclaim #{sweep_preview[:reclaimed_human]} of regenerable artifacts") if sweep_preview[:reclaimed_human]
    if docs_preview[:moved]
      say("  would retire #{docs_preview[:moved]} frozen doc(s) and roll #{docs_preview[:ledger_rolled]} ledger row(s)")
    end
    return
  end

  # 6. ONE confirm authorizes the board write, the worktree teardown, the
  #    artifact sweep, and the doc retirement (--yes skips).
  abort!("aborted — archive not confirmed") unless confirm("Archive #{archivable.size} shipped tasks + reclaim worktrees + sweep artifacts + retire #{docs_preview[:moved] || 0} frozen doc(s)?")

  # 7. Archive on the board (shipped → archived). A board WRITE.
  step("record: Release::Conductor.archive_completed!")
  # BOARD_FLIP_CADENCE: archive one task every beat, from the top of the
  # Shipped column down, so /deployments plays the sweep instead of blinking it.
  result = conductor(
    "r = Release::Conductor.archive_completed!(pause: #{BOARD_FLIP_CADENCE}); " \
    "puts({ archived: r[:archived], kept: r[:kept], count: r[:count] }.to_json)"
  )
  archived_count = result["count"] || (result["archived"] || []).size
  kept_count     = (result["kept"] || kept).size

  # 8. Reclaim the merged/shipped feature worktrees (--yes = real teardown,
  #    squash-merged legacy worktrees included). The board archive already
  #    succeeded, so a reclaim hiccup just means fewer worktrees freed this run.
  say("")
  step("worktree reclaim: bin/agent-worktree cleanup --reclaim --yes")
  reclaim_out, = reclaim_worktrees(apply: true)
  reclaimed = reclaimed_count(reclaim_out)

  # 9. Sweep the regenerable artifacts — AFTER the reclaim, so the worktrees that
  #    just went away are not swept first and counted twice. Machine-local, and
  #    best-effort for the same reason as the reclaim: the board write is done.
  say("")
  step("artifact sweep: bin/clean-artifacts")
  sweep = sweep_summary(sweep_artifacts(apply: true).first)

  # 10. Retire the frozen docs + roll the ledger. This STAGES tracked changes
  #     (git mv + the ledger rewrite), which the commit below then carries to
  #     `release` as ONE artifact commit.
  say("")
  step("docs archive: bin/archive-docs")
  docs_sweep = sweep_docs(apply: true)
  # THE REFUSAL, HONOURED — AND DIAGNOSED. The commit below git-adds the ledger AND its
  # archive and pushes them to `release`, so continuing past a non-zero exit is what
  # turns a recoverable working-tree loss into committed history. Stop here: the board
  # archive, the reclaim, and the artifact sweep have already succeeded and are all
  # idempotent, so a re-run picks up exactly where this left off.
  #
  # HALTING WAS ALWAYS RIGHT. THE EXPLANATION WAS NOT. This branch used to announce
  # "the delete-later ledger has lost resolved row(s)" for EVERY non-zero exit, having
  # checked no such thing — and on 2026-09-01 it said exactly that when a `git mv` had
  # crashed, mid production deploy, over a ledger that was perfectly conserved (41 rows
  # out of one file, 41 into the other). Data loss in an audit trail is the most
  # alarming thing this beat can say; saying it on a hunch cost the deploying agent a
  # detour at the worst possible moment.
  #
  # So the halt stays and the claim is MEASURED: ledger_verdict counts the rows itself
  # against the same repo the sweep was pointed at, and failure_report says only what
  # that count supports — while always naming the command, its exit status and its
  # stderr, which is what an operator actually needed to read.
  unless docs_sweep.ok?
    abort!(DocsArchive.failure_report(
             command: docs_sweep.command,
             exit_label: docs_sweep.exit_label,
             stderr: docs_sweep.err,
             ledger: ledger_verdict(docs_sweep.repo)
           ))
  end
  docs = docs_summary(docs_sweep.out)

  # The doc retirement moved frozen snapshots and rolled the ledger's resolved rows into
  # the archive — commit ALL of it to `release` so it rides the next ship instead of
  # becoming ship-preflight dirt. (The RECLAIM no longer writes here: since
  # `ledger-writes-to-primary`, `bin/agent-worktree` files desk records on the board, and
  # these two files are tracked history the archive beat still rolls.)
  # (best-effort). Every path must be named: the safety check refuses when
  # anything ELSE is dirty, so omitting the retirements would strand them.
  hub = repo_path("mcritchie-studio")
  artifact_paths = [File.join(hub, DocsArchive::LEDGER), File.join(hub, DocsArchive::LEDGER_ARCHIVE)]
  artifact_paths += docs[:moved_paths].to_a.map { |rel| File.join(hub, DocsArchive.archive_path_for(rel)) }
  commit_artifact_to_release(
    "mcritchie-studio",
    artifact_paths,
    "ledger: delete-later after archive (#{archived_count} archived, #{reclaimed} reclaimed, " \
    "#{docs[:moved] || 0} doc(s) retired)"
  )

  # 11. Summary. The disk numbers are MACHINE-LOCAL, not board state — say so in
  #     the Exit Seam report rather than filing them as pipeline facts.
  say("")
  say("✓ Archived #{archived_count} tasks; reclaimed #{reclaimed} worktrees; SHIPPED → #{kept_count}")
  say("✓ Swept #{sweep[:reclaimed_human] || '0 B'} of regenerable artifacts " \
      "across #{sweep[:repos]} repo(s) / #{sweep[:worktrees]} worktree(s) (this machine only)")
  if sweep[:rotation_missing].to_a.any?
    say("⚠ MISSING LOG ROTATION: #{sweep[:rotation_missing].join(', ')} — " \
        "these apps have not adopted the studio-engine cap; their local logs grow to Rails' 100 MB default")
  end
  if sweep[:rotation_unknown].to_a.any?
    say("⚠ Logger audit inconclusive (could not boot): #{sweep[:rotation_unknown].join(', ')}")
  end
  say("✓ Retired #{docs[:moved] || 0} frozen doc(s) into #{DocsArchive::ARCHIVE_DIR}/ " \
      "and rolled #{docs[:ledger_rolled] || 0} ledger row(s) — moved, never deleted")
  if docs[:skipped].to_a.any?
    say("⚠ Left in place, still referenced (fix the referrer first, then they retire on the next run):")
    docs[:skipped].each { |s| say("    #{s[:path]} — cited by #{s[:referrers].join(', ')}") }
  end
end

# --- retro -----------------------------------------------------------------
# Where the durable retro doc lands. Defaults next to the other agent audits in
# THIS checkout (so a worktree run writes into the worktree); RETRO_DOCS_DIR
# overrides it (the test points it at a tmpdir). Mirrors Release::Retro::AUDITS_DIR.
def retro_docs_dir
  return File.expand_path(ENV["RETRO_DOCS_DIR"]) if ENV["RETRO_DOCS_DIR"].to_s != ""

  File.expand_path("../docs/agents/audits", __dir__)
end

# --- retro follow-up identity + idempotency ---------------------------------
# Two compounding defects put 38 byte-identical "fix flake" findings (45% of the
# open inbox) in front of the operator, and fixing either alone leaves the noise:
#
#   1. NO IDEMPOTENCY — every run filed every follow-up again, so re-running a
#      retro, or running one per release, refiled the same text indefinitely.
#   2. TITLE COLLAPSE — the title was literally the follow-up's first 8 words, so
#      every short/generic follow-up ("fix flake") collapsed to the SAME title.
#
# The guard below matches VERBATIM (title AND body, byte-for-byte) and never
# fuzzily. A fuzzy match would silently swallow genuinely distinct findings —
# strictly worse than a duplicate, because a duplicate is VISIBLE at /triage and
# a swallowed finding is not. Nothing here dismisses or dedupes what is already
# filed: dismissal is the operator's admin-gated lane (TriageController), and the
# existing 38 stay theirs to clear. This stops the bleeding, not the wound.

# Words below which a follow-up cannot identify itself. "fix flake" (2) is the
# measured floor case; five words is roughly "verb + object + where".
RETRO_FOLLOWUP_MIN_WORDS = 5
# How many leading words become the finding title (the board path uses 5 — see
# retro's --file-tasks branch — because Task titles validate to 3-5 words).
RETRO_FOLLOWUP_TITLE_WORDS = 8

def retro_followup_words(text) = text.to_s.split(/\s+/).reject(&:empty?)

# A follow-up too short to identify itself. It is still FILED (see retro) — this
# only decides whether it gets warned about and slug-tagged.
def retro_followup_vague?(text) = retro_followup_words(text).size < RETRO_FOLLOWUP_MIN_WORDS

# The finding title for a follow-up. A vague one carries its RELEASE SLUG so it
# is self-identifying: two real "fix flake" occurrences from different releases
# stay distinguishable, while one occurrence refiled twice stays byte-identical
# and is caught by the verbatim guard. A long one is truncated with an ellipsis
# so the operator can SEE that the title is a prefix, not the whole finding.
def retro_followup_title(text, release_slug, words: RETRO_FOLLOWUP_TITLE_WORDS)
  parts = retro_followup_words(text)
  return "#{parts.join(' ')} (#{release_slug})" if retro_followup_vague?(text)

  parts.size > words ? "#{parts.first(words).join(' ')}…" : parts.join(" ")
end

# The finding body. Unchanged wording — an existing open finding filed by the old
# code still matches verbatim, so this fix does not orphan what is already there.
def retro_followup_body(text, release_slug) = "Retro follow-up from #{release_slug}: #{text}"

# VERBATIM duplicate test — title AND body, byte-for-byte, over OPEN findings
# only. Deliberately not fuzzy, not title-only: two different long follow-ups can
# share their first 8 words (identical titles, different bodies) and both are
# real, so the body is what keeps them.
def retro_finding_open?(rows, title, body)
  rows.any? { |r| r["title"].to_s == title && r["body"].to_s == body }
end

# Read the OPEN inbox through bin/triage (no new API — index already exists).
# Returns [rows, ok?]. Fails OPEN: on a read failure the caller files anyway and
# says so, because the retro is non-blocking by contract and a duplicate finding
# is cheaper than a lost one.
def retro_open_findings(triage_bin)
  out, ok = sh(triage_bin, "list", "--status", "open", "--json", capture: true)
  return [[], false] unless ok

  parsed = JSON.parse(out)
  parsed.is_a?(Array) ? [parsed, true] : [[], false]
rescue JSON::ParserError
  [[], false]
end

# Prompt for a repeatable free-text answer: read lines until a blank one, return
# the collected non-blank entries. Used for the interactive judgment questions.
def prompt_list(question)
  say("#{question} (one per line; blank line to finish)")
  items = []
  loop do
    $stdout.print("  - ")
    line = $stdin.gets
    break if line.nil?

    line = line.strip
    break if line.empty?

    items << line
  end
  items
end

# Build the read-only conductor snippet that gathers + renders the retro on the
# board. The retro answers are operator FREE TEXT — they can carry quotes,
# parens, &&, pipes, backticks. Earlier this raw-interpolated `answers.to_json`
# as a \"-escaped string literal into the `rails runner "<code>"` command, but
# `heroku run`'s remote re-quoting EATS that escaping: parens triggered a remote
# `bash: syntax error near unexpected token '('` and even EMPTY answers arrived
# corrupted (`JSON::ParserError ... got 'worked:[],riction:[],ollowups:'`). So
# the payload now rides as a url-safe Base64 blob (alphabet [A-Za-z0-9_-]=, zero
# shell metacharacters) that the remote runner decodes — as quote-free as the
# bare `slug.inspect` literal the other conductor callers already pass safely.
# Pure (no Rails) so it's unit-tested standalone in test/lib/release_cli_test.rb.
def retro_record_ruby(slug, answers)
  answers_b64 = Base64.urlsafe_encode64(answers.to_json)
  "rel = Release::Retro.resolve(#{slug.inspect}); " \
  "answers = JSON.parse(Base64.urlsafe_decode64(#{answers_b64.inspect})); " \
  "puts((rel ? { slug: rel.slug, markdown: Release::Retro.render(Release::Retro.gather(rel), answers: answers) } : {}).to_json)"
end

# The post-ship "review & learn" step. NON-BLOCKING by construction: it only
# READS the board (gather/render via a read_only conductor) and WRITES a doc to
# the local tree — nothing in the pipeline (archive included) depends on it.
def retro
  # Optional positional release-slug (default = current/last-shipped). Guard so a
  # flag isn't mistaken for the slug when retro is run with no slug.
  slug = (ARGV.first && !ARGV.first.start_with?("--")) ? ARGV.shift : nil
  worked    = opt_values("--worked")
  friction  = opt_values("--friction")
  followups = opt_values("--followup")
  file_tasks = Release::Cli.take_flag(ARGV, "--file-tasks")

  say("Release retro#{slug ? " #{slug}" : ' (current/last-shipped)'}#{PROD ? ' (PROD board)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # 1. Gather + render server-side (a pure READ → runs even in --dry-run). The
  #    operator's free-text answers ride as a Base64 blob (see retro_record_ruby)
  #    so quotes/parens/&& survive the `heroku run` round-trip. Returns
  #    { slug, markdown } (or {} when no release resolves).
  interactive = !(ASSUME_YES || DRY)
  if interactive
    say("")
    worked    += prompt_list("What worked well?")
    friction  += prompt_list("What caused friction?")
    followups += prompt_list("Follow-up tasks to file?")
    say("")
  end
  answers = { "worked" => worked, "friction" => friction, "followups" => followups }

  step("record (read-only): gather + render retro for #{slug || 'the current/last-shipped release'}")
  result = conductor(retro_record_ruby(slug, answers), read_only: true)
  resolved = result["slug"].to_s
  abort!("no release to retro (no active release and nothing shipped yet)") if resolved.empty?

  markdown = result["markdown"].to_s
  path = File.join(retro_docs_dir, "retro-#{resolved}.md")

  # 2. Write the durable doc to the LOCAL tree (skipped in --dry-run).
  if DRY
    say("")
    step("would write retro doc: #{path} (#{markdown.lines.size} lines)")
    say("✓ Retro previewed for #{resolved} (DRY RUN — nothing written).")
    return
  end

  require "fileutils"
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, markdown)
  say("✓ wrote #{path}")

  # Commit the retro doc to `release` so it ships next round instead of becoming
  # ship-preflight dirt (best-effort, non-fatal; see commit_artifact_to_release).
  commit_artifact_to_release("mcritchie-studio", path, "retro: #{resolved}")

  # 3. File the follow-ups. DEFAULT: the TRIAGE inbox (bin/triage) — a finding
  #    costs nothing sitting there, and only an operator promote mints a task
  #    (the slop-damping rule: retro discoveries are not board tasks by default).
  #    --file-tasks keeps the old behavior as an explicit opt-in. The doc is
  #    already written, so a filing hiccup just means fewer entries filed.
  if followups.any?
    say("")
    # WARN, never refuse, on a follow-up too short to identify itself — and warn
    # BEFORE the branch, because the defect is in the INPUT and both destinations
    # inherit it. Refusing would discard text the operator just typed at the end
    # of a ship, turning a low-value finding into a LOST one and handing the
    # retro a failure mode its own contract disclaims ("NON-BLOCKING"). A warning
    # puts the pressure on the person who can still fix it, right when they can.
    followups.select { |f| retro_followup_vague?(f) }.each do |f|
      say("  ⚠ vague follow-up #{f.inspect} — under #{RETRO_FOLLOWUP_MIN_WORDS} words, so it cannot identify " \
          "itself. Filing it anyway, tagged with #{resolved}; re-run with a fuller sentence for a better record.")
    end

    if file_tasks
      step("file #{followups.size} follow-up task(s) via bin/task create (--file-tasks)")
      task_bin = File.expand_path("../bin/task", __dir__)
      followups.each do |f|
        # NOT slug-tagged like the triage title: Task titles validate to 3-5
        # words (Task::TITLE_WORD_RANGE), so a "(rel-…)" suffix would push every
        # title out of range and the create would 422. The release stays in
        # agent_context below, which is where task detail belongs anyway. A vague
        # follow-up is REJECTED here by that same validation — loudly, by the
        # board, which is the right place for it; the warning above says why.
        title = f.split(/\s+/).first(5).join(" ")
        # --no-claim: filing a retro follow-up must not repoint the conductor's
        # active-feature marker (and its live build-claim) onto each fresh task.
        _, ok = sh(task_bin, "create", "--no-claim", "--title", title, "--kind", "chore",
                   "--agent-context", retro_followup_body(f, resolved), capture: true)
        say("  - #{ok ? '✓' : '✗'} #{title}")
      end
    else
      step("file #{followups.size} follow-up finding(s) into the triage inbox (default; --file-tasks opens tasks instead)")
      triage_bin = File.expand_path("../bin/triage", __dir__)
      open_findings, read_ok = retro_open_findings(triage_bin)
      say("  ⚠ could not read the open inbox — filing without the duplicate check (a duplicate beats a lost finding)") unless read_ok

      followups.each do |f|
        title = retro_followup_title(f, resolved)
        body  = retro_followup_body(f, resolved)
        if retro_finding_open?(open_findings, title, body)
          say("  - ↻ #{title} (already open — skipped)")
          next
        end

        _, ok = sh(triage_bin, "file", "--title", title, "--source", "release-retro",
                   "--body", body, capture: true)
        say("  - #{ok ? '✓' : '✗'} #{title}")
        # Count it as open for the REST of this run too, so the same follow-up
        # passed twice in one invocation files once, not twice.
        open_findings << { "title" => title, "body" => body } if ok
      end
    end
  end

  say("")
  say("✓ Retro for #{resolved} written to #{path}. NON-BLOCKING — `bin/release archive` is unaffected.")
end

# Guarded so the file can be `require`d (helper coverage) without dispatching.
if __FILE__ == $PROGRAM_NAME
  # BEFORE the dispatcher, always. Every mutation this CLI can perform is reached
  # through the `case` below, so this is the one line that has to run first: it
  # answers `--help` from any position and REFUSES an argument no subcommand
  # accounts for, instead of shifting the subcommand and letting the flag fall on
  # the floor. Unknown subcommands still fall through to the `else`.
  guard_argv!
  case ARGV.shift
  when "init"    then init
  when "merge"   then merge
  when "prepare"  then prepare
  when "eject"    then eject
  when "ship"     then ship
  when "finalize" then finalize(Release::Cli.positional_slugs(ARGV).first)
  when "status"   then status
  when "archive"  then archive
  when "retro"    then retro
  else
    # The usage string moved to Release::Cli::USAGE so the guard's per-subcommand
    # help and this fall-through print the SAME text from one place.
    warn Release::Cli::USAGE
    exit 1
  end
end
