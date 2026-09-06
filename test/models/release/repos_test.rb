require "test_helper"
require "shellwords"
require "open3"
# The seam that answers "what does CI's Ruby suite amount to, as one command?" — a
# bin/lib module, not an autoloaded app constant, so it is required explicitly.
require Rails.root.join("bin", "lib", "ci_test_command").to_s

class Release::ReposTest < ActiveSupport::TestCase
  test "classifies registered gems as :gem" do
    assert_equal :gem, Release::Repos.kind("studio-engine")
    assert_equal :gem, Release::Repos.kind("solana-studio")
    assert Release::Repos.gem?("studio-engine")
    assert Release::Repos.gem?("solana-studio")
  end

  test "classifies registered apps as :app" do
    assert_equal :app, Release::Repos.kind("mcritchie-studio")
    assert_equal :app, Release::Repos.kind("turf-monster")
    assert_equal :app, Release::Repos.kind("rolio")
    assert Release::Repos.app?("turf-monster")
    assert Release::Repos.app?("rolio")
    assert_not Release::Repos.gem?("turf-monster")
  end

  test "classifies anything outside the registry as :unknown" do
    assert_equal :unknown, Release::Repos.kind("not-a-real-repo")
    assert_equal :unknown, Release::Repos.kind(nil)
    assert_equal :unknown, Release::Repos.kind("")
    assert_not Release::Repos.gem?("not-a-real-repo")
    assert_not Release::Repos.app?("not-a-real-repo")
  end

  test "gem_repos and app_repos read the registry" do
    assert_includes Release::Repos.gem_repos, "studio-engine"
    assert_includes Release::Repos.gem_repos, "solana-studio"
    assert_includes Release::Repos.app_repos, "mcritchie-studio"
    assert_not_includes Release::Repos.gem_repos, "mcritchie-studio"
  end

  test "gem_meta returns the gem's publish metadata" do
    meta = Release::Repos.gem_meta("studio-engine")
    assert_equal "lib/studio/version.rb", meta["version_file"]
    assert_equal "studio-engine.gemspec", meta["gemspec"]
    assert_equal "bin/release-check", meta["release_check"]
  end

  test "gem_meta is nil for a non-gem" do
    assert_nil Release::Repos.gem_meta("turf-monster")
    assert_nil Release::Repos.gem_meta("nope")
  end

  test "self_gated_gem? is true only for a gem carrying a non-empty release_check" do
    # Both registered gems declare release_check: bin/release-check → self-gated.
    # solana-studio joined on 2026-08-20, when it grew a suite runner alongside
    # its Rails engine; it was the standing "not self-gated" example before that.
    assert Release::Repos.self_gated_gem?("studio-engine")
    assert Release::Repos.self_gated_gem?("solana-studio")
    # apps and unknowns are never self-gated gems.
    assert_not Release::Repos.self_gated_gem?("mcritchie-studio")
    assert_not Release::Repos.self_gated_gem?("turf-monster")
    assert_not Release::Repos.self_gated_gem?("not-a-real-repo")
    assert_not Release::Repos.self_gated_gem?(nil)
    assert_not Release::Repos.self_gated_gem?("")
  end

  # The gem-without-a-release_check branch, which no registered gem exercises
  # any more. STUBBED rather than pointed at a live repo: the branch still runs
  # for the next gem onboarded without a runner, and a test that could only work
  # while some real gem happened to lack one was testing the registry, not the
  # rule. Covers blank and whitespace-only alongside absent — `.strip.present?`
  # is what makes an empty declaration read as "no gate" rather than as one.
  test "self_gated_gem? is false for a gem whose release_check is absent or blank" do
    [nil, "", "   "].each do |declared|
      meta = { "ladder" => "three-rung", "gemspec" => "x.gemspec" }
      meta["release_check"] = declared unless declared.nil?

      Release::Repos.stub(:gem_meta, ->(_repo) { meta }) do
        assert_not Release::Repos.self_gated_gem?("some-gem"),
                   "release_check #{declared.inspect} must not count as a gate"
      end
    end
  end

  test "extract_version parses a VERSION constant assignment" do
    assert_equal "0.7.0", Release::Repos.extract_version(%(module Studio\n  VERSION = "0.7.0"\nend\n))
  end

  test "extract_version parses a gemspec version assignment" do
    assert_equal "0.4.7", Release::Repos.extract_version(%(  spec.version = "0.4.7"\n))
  end

  test "extract_version returns nil when no version is present" do
    assert_nil Release::Repos.extract_version("no version here")
    assert_nil Release::Repos.extract_version(nil)
  end

  test "gem_version is nil for a non-gem repo" do
    assert_nil Release::Repos.gem_version("turf-monster")
  end

  # --- apps as a hash: app_meta / prod_deploy / qa_app ---

  test "app_repos lists the registry's app hash keys" do
    assert_equal %w[mcritchie-studio turf-monster turf-vault mcritchie-industries rolio tax-studio
                    chain-ops].sort,
                 Release::Repos.app_repos.sort
  end

  test "app? matches the app hash keys" do
    assert Release::Repos.app?("mcritchie-studio")
    assert Release::Repos.app?("rolio")
    assert Release::Repos.app?("tax-studio")
    assert Release::Repos.app?("chain-ops")
    assert_not Release::Repos.app?("studio-engine") # a gem
    assert_not Release::Repos.app?("not-a-real-repo")
  end

  test "app_meta returns the app's registry metadata" do
    meta = Release::Repos.app_meta("turf-monster")
    assert_kind_of Hash, meta
    assert meta.key?("prod_deploy")
  end

  test "app_meta is nil for a non-app" do
    assert_nil Release::Repos.app_meta("studio-engine") # a gem
    assert_nil Release::Repos.app_meta("nope")
  end

  test "prod_deploy returns the github_actions adapter for mcritchie-studio" do
    # DevOps v2 Phase 2: the hub deploys through GitHub Actions (prod-deploy.yml),
    # not a local git push. smoke_url stays for the board/deploy record even though
    # the workflow (not the conductor) runs the smoke.
    adapter = Release::Repos.prod_deploy("mcritchie-studio")
    assert_equal "github_actions", adapter["strategy"]
    assert_equal "prod-deploy.yml", adapter["workflow"]
    assert_equal "https://mcritchie.studio", adapter["smoke_url"]
  end

  test "prod_deploy returns the repo_script adapter for turf-monster" do
    adapter = Release::Repos.prod_deploy("turf-monster")
    assert_equal "repo_script", adapter["strategy"]
    assert_equal "bin/deploy", adapter["command"]
    assert_equal ["--yes"], adapter["args"]
  end

  test "prod_deploy returns the Heroku URL adapter for Rolio" do
    adapter = Release::Repos.prod_deploy("rolio")
    assert_equal "git_push_heroku", adapter["strategy"]
    assert_equal "https://git.heroku.com/rolio-prod.git", adapter["remote"]
    assert_equal "main", adapter["branch"]
    assert_equal "https://rolio-prod-82e96784b462.herokuapp.com", adapter["smoke_url"]
  end

  # --- a declared deploy command must actually EXIST (the 2026-08-22 wedge) ----
  #
  # THE REGRESSION GUARD. chain-ops' entry declared `command: bin/deploy` and
  # chain-ops/bin/deploy never existed. Nothing checked, so the lie survived
  # until `bin/release ship` ran it inside rel-20260822-ae1cc1: the deploy
  # failed, the ship aborted, and it aborted AFTER push_frozen_main had already
  # advanced chain-ops' origin/main — wedging G4 and blocking turf-monster from
  # shipping in the same release. A registry entry is a PROMISE about the world;
  # this asserts the promise, for EVERY repo_script app, not just chain-ops.
  #
  # Read from `origin/release`, NOT the working tree — the same rule the ci.yml
  # drift guard follows, and the honest one here too: ship runs the command from
  # a workspace checked out at the FROZEN SHA, which comes off the release
  # branch. A script that exists only on someone's feature branch is not a
  # deploy target.
  # NO `skip` HERE, deliberately. config/rails_lane.yml ratchets the lane's skip
  # count against origin/release, so a new skip site cannot be paid for in the
  # same commit — and it should not be. Instead the test always asserts the half
  # that needs no checkout (the adapter NAMES a command) and adds the on-disk
  # half for whichever siblings are present. On the hub CI runner it still has a
  # real assertion; the load-bearing on-disk check also runs at ship time, in
  # Release::ShipSequence.missing_deploy_commands, BEFORE any main moves.
  test "every declared repo_script deploy command exists on the branch that ships" do
    root = projects_root

    missing = Release::Repos.app_repos.filter_map do |repo|
      adapter = Release::Repos.prod_deploy(repo) || {}
      next unless adapter["strategy"].to_s == "repo_script"

      command = adapter["command"].to_s
      next "#{repo} declares prod_deploy.strategy repo_script with no `command`" if command.empty?
      next if root.nil? # hub CI runner — no siblings to probe; the naming half above still ran

      path = root.join(repo)
      next unless path.join(".git").exist? # planned repo — the ladder guard owns its arrival

      _out, status = Open3.capture2e("git", "-C", path.to_s, "cat-file", "-e", "origin/release:#{command}")
      next if status.success?

      "#{repo} declares prod_deploy.command #{command}, which does not exist at origin/release"
    end

    assert_empty missing,
                 "a registry entry names a deploy command that is not there: #{missing.join('; ')}. " \
                 "Ship would abort on it at G4 — AFTER main has already advanced. Either add the real " \
                 "script or drop prod_deploy (an app with no production target is a first-class case). " \
                 "Do NOT add a no-op deploy script: that makes ship report a deploy that never happened."
  end

  # Guards the guard: if app_repos or the strategy filter ever went empty, the
  # assertion above would pass over nothing — green while checking nothing.
  test "the deploy-command guard actually has a command to check" do
    declared = Release::Repos.app_repos.count do |repo|
      (Release::Repos.prod_deploy(repo) || {})["strategy"].to_s == "repo_script"
    end

    assert_operator declared, :>=, 1, "expected at least one repo_script app for the guard to check"
  end

  # The fix in evidence. chain-ops has no production app, so it declares no
  # adapter — and ship treats that as "advance main, dispatch nothing".
  test "chain-ops declares no prod_deploy because it has no production target" do
    assert_nil Release::Repos.prod_deploy("chain-ops"),
               "chain-ops has no production deployment target; declaring one is what wedged G4"
    assert Release::Repos.app?("chain-ops"), "it is still a registered app — just an undeployed one"
  end

  # --- turf-vault: a registered repo with NO production target -----------------
  #
  # The Anchor program. Registered 2026-08-31 because
  # Release::Conductor#validate_member_repos_known! aborted a live sweep on its
  # absence. These assertions pin the SHAPE of that entry, because the danger here
  # is not an absent entry (which fails loudly) but a WRONG one, which would point
  # the pipeline at a program custodying real USDC.

  test "[unit] turf-vault is a registered app so the conductor can classify a member" do
    assert_equal :app, Release::Repos.kind("turf-vault"),
                 "an :unknown kind is what aborted rel-20260831-6f1ed1 mid-sweep"
    assert Release::Repos.app?("turf-vault")
    assert_not Release::Repos.gem?("turf-vault"),
               "turf-vault has no gemspec — a `gems` row would make the conductor publish it to RubyGems"
  end

  test "[unit] turf-vault declares NO production deploy target" do
    assert_nil Release::Repos.prod_deploy("turf-vault"),
               "turf-vault is an Anchor program upgraded BY HAND through a Squads 2-of-3 multisig " \
               "(scripts/squad-upgrade.js, gated by docs/MAINNET_LAUNCH.md). No automated path has ever " \
               "deployed it. Declaring an adapter makes `bin/release ship` attempt that act against a " \
               "program custodying real USDC — and a no-op script is worse still, because ship then " \
               "REPORTS a deploy that never happened."
    assert Release::Repos.app?("turf-vault"), "it is still a registered app — just an undeployed one"
  end

  test "[unit] turf-vault registers no Rails gate command at either gate" do
    # Both gates run inside a Rails gate workspace, which runs
    # `bin/rails db:test:prepare test:prepare` BEFORE the registered command.
    # turf-vault is Rust/Anchor and ships no bin/rails, so either key arms a gate
    # that cannot run — red at G3 (aborting an unrelated batch) or at G4 AFTER
    # push_frozen_main has already advanced origin/main.
    assert_nil Release::Repos.test_cmd("turf-vault"),
               "a G4 ship gate here would run bin/rails in a repo that has none"
    assert_nil Release::Repos.qa_test_cmd("turf-vault"),
               "a G3 pre-QA gate here would abort the whole batch sweep on ENOENT"
  end

  test "[unit] turf-vault walks the three-rung ladder it actually has" do
    assert_equal Release::Ladder::THREE_RUNG, Release::Repos.ladder("turf-vault"),
                 "anything else strands turf-vault work on `accepted` — Ladder.sweepable is three-rung only"
    assert_includes Release::Repos.three_rung_repos, "turf-vault"
  end

  # --- QA-evidence policy: DECLARED, never inferred ----------------------------

  test "[unit] turf-vault DECLARES itself exempt from QA evidence" do
    assert Release::Repos.qa_evidence_exempt?("turf-vault"),
           "an Anchor program has no dyno, no URL and no deploy — the pre-QA gate and the QA deploy " \
           "loop both skip it BY DESIGN, so a candidate records zero QA evidence for it and every " \
           "member naming it was held at `reviewed` forever (rel-20260905-d6c266, rel-20260906-90c443)"
    assert_equal Release::Repos::QA_EVIDENCE_EXEMPT, Release::Repos.qa_evidence("turf-vault")
  end

  test "[unit] a deployable app is NOT exempt just because someone forgot its QA env" do
    # THE FENCE. The cheap repair for the turf-vault hold — "ignore any repo with
    # no QA config" — would disarm the guard for every repo. Absence must never
    # grant the exemption; only a declaration does.
    %w[mcritchie-studio turf-monster mcritchie-industries].each do |repo|
      assert_not Release::Repos.qa_evidence_exempt?(repo),
                 "#{repo} deploys to a real QA app — its missing evidence must still hold a member"
      assert_equal Release::Repos::QA_EVIDENCE_REQUIRED, Release::Repos.qa_evidence(repo)
    end
  end

  test "[unit] tax-studio and chain-ops are NOT exempt though they too have no QA env" do
    # Both are apps with no qa_test_cmd and no qa_environments entry — the exact
    # config shape turf-vault has. They are NOT exempt, which is the proof that the
    # exemption is read from the declaration rather than inferred from the tree.
    # (Neither can ride a sweep today — tax-studio is `planned`, chain-ops
    # `blocked`, and Ladder.sweepable is three-rung only — so declaring them would
    # be an unmeasured guess. Each owes its own judgement the day it goes live.)
    assert_not Release::Repos.qa_evidence_exempt?("tax-studio")
    assert_not Release::Repos.qa_evidence_exempt?("chain-ops")
  end

  test "[unit] an unregistered repo defaults to REQUIRED, not exempt" do
    assert_not Release::Repos.qa_evidence_exempt?("moms-app"),
               "a repo the registry has never heard of must fail CLOSED"
    assert_equal Release::Repos::QA_EVIDENCE_REQUIRED, Release::Repos.qa_evidence("moms-app")
  end

  test "[unit] an unrecognised qa_evidence value fails CLOSED to required" do
    # A typo (`exmept`) must hold the member — visible and recoverable — rather
    # than silently release it. The declared-values guard below catches the typo
    # at its source; this is what happens in the window before someone does.
    Release::Repos.stub(:meta, ->(_repo) { { "qa_evidence" => "exmept" } }) do
      assert_equal Release::Repos::QA_EVIDENCE_REQUIRED, Release::Repos.qa_evidence("turf-vault")
      assert_not Release::Repos.qa_evidence_exempt?("turf-vault")
    end
  end

  test "[unit] every declared qa_evidence value is one the reader recognises" do
    config = Release::Repos.config
    declared = (config.fetch("gems", {}).to_a + config.fetch("apps", {}).to_a).filter_map do |repo, meta|
      value = meta.is_a?(Hash) ? meta["qa_evidence"] : nil
      [ repo, value ] if value.present?
    end

    declared.each do |repo, value|
      assert_includes Release::Repos::QA_EVIDENCE_VALUES, value,
                      "#{repo} declares qa_evidence: #{value.inspect}, which the reader does not " \
                      "recognise — it would fail closed and hold every member naming #{repo}"
    end
  end

  # THE DECLARATION IS CHECKED, NOT TRUSTED — the same shape as "a planned repo
  # has not quietly been created". An exemption is only honest while the repo
  # genuinely cannot produce QA evidence. The day one gains a gate command or a QA
  # environment, this goes red and the declaration must come out so the guard
  # re-arms, instead of the exemption quietly outliving its reason.
  test "[unit] a QA-evidence-exempt repo really has no QA target to be evidenced by" do
    qa_envs = YAML.load_file(Rails.root.join("config/qa_environments.yml"))
                  .fetch("qa_environments", {}).keys

    Release::Repos.qa_evidence_exempt_repos.each do |repo|
      assert_nil Release::Repos.qa_test_cmd(repo),
                 "#{repo} is declared QA-evidence exempt but registers a qa_test_cmd — the pre-QA " \
                 "gate WOULD record a verdict for it, so the exemption is stale and must be removed"
      assert_not_includes qa_envs, repo,
                          "#{repo} is declared QA-evidence exempt but now has a qa_environments.yml " \
                          "entry — it can be QA-deployed, so it must earn its evidence like any app"
    end
  end

  # Guards the guard: every assertion above would pass vacuously over an empty list.
  test "[unit] the QA-evidence exemption guard actually has a repo to check" do
    assert_includes Release::Repos.qa_evidence_exempt_repos, "turf-vault"
    assert_equal 1, Release::Repos.qa_evidence_exempt_repos.length,
                 "exactly one repo is declared exempt today — a second one arriving unreviewed " \
                 "is what this count is here to surface"
  end

  test "prod_deploy is nil for a gem or an unknown repo" do
    assert_nil Release::Repos.prod_deploy("studio-engine")
    assert_nil Release::Repos.prod_deploy("not-a-real-repo")
  end

  test "qa_app defaults to the repo slug when no qa_deploy override is set" do
    assert_equal "rolio", Release::Repos.qa_app("rolio")
    assert_equal "turf-monster", Release::Repos.qa_app("turf-monster")
    assert_equal "mcritchie-studio", Release::Repos.qa_app("mcritchie-studio")
  end

  # --- test_cmd: the conductor's pre-prod gate ---

  test "test_cmd returns the hub's pre-prod gate command" do
    assert_equal "bin/rails db:test:prepare test test:system", Release::Repos.test_cmd("mcritchie-studio")
  end

  test "test_cmd returns Rolio's pre-prod gate command" do
    # CI's full suite, verbatim — base AND system tiers. Rolio deploys via
    # git_push_heroku (no test step), so this command IS the last gate before
    # rolio production; `bin/rails test` (what it used to be) SKIPS test/system,
    # which left rolio's system tier able to regress straight into prod ungated.
    assert_equal "bin/rails db:test:prepare test test:system", Release::Repos.test_cmd("rolio")
  end

  test "test_cmd is nil for a self-gating repo_script satellite" do
    # Satellites run their own suite in bin/deploy, so they leave test_cmd unset
    # (the conductor skips the gate) to avoid double-testing.
    assert_nil Release::Repos.test_cmd("turf-monster")
    assert_nil Release::Repos.test_cmd("tax-studio")
  end

  test "test_cmd is nil for a gem or an unknown repo" do
    assert_nil Release::Repos.test_cmd("studio-engine")
    assert_nil Release::Repos.test_cmd("not-a-real-repo")
  end

  # --- qa_test_cmd: Steffon's pre-QA gate (G3 Candidate) ---

  test "qa_test_cmd registers the G3 tier per app: full CI suite unless the repo's own deploy tests" do
    # The prepare-owned tier. The split is NOT "hub vs satellite" — it is "does
    # this repo's DEPLOY run the suite?":
    #   * turf-monster's bin/deploy runs the full suite pre-prod, so G3 gates on
    #     the integration SUBSET (review owns base) and ship doesn't double-test.
    #   * the HUB and ROLIO both deploy via git_push_heroku, which has NO test
    #     step — so their registered command is the LAST gate before prod and must
    #     be CI's FULL suite (base AND system tiers). It is also the G3 batch
    #     certification (90/10): ship's test_gate self-gates when the frozen SHA
    #     matches this certified run, so the suite runs once per release batch.
    assert_equal "bin/rails db:test:prepare test test:system",
                 Release::Repos.qa_test_cmd("mcritchie-studio"),
                 "the hub certifies its full suite — base AND system tiers — at G3"
    assert_equal "bin/rails db:test:prepare test test:system", Release::Repos.qa_test_cmd("rolio"),
                 "rolio is git_push_heroku — its gate must certify CI's full suite, base AND system tiers"
    assert_equal "bin/rails test test/integration", Release::Repos.qa_test_cmd("turf-monster"),
                 "turf-monster self-gates the full suite in bin/deploy, so G3 gates on its integration tier"
  end

  # --- rolio's gate must cover what rolio's CI covers (the system-test gap) ---

  test "rolio's gate carries the SYSTEM tier" do
    # THE BUG THIS CLOSES. rolio HAS system tests (test/system/) and its ci.yml
    # runs them, but both registered commands were `bin/rails test` (G4) and
    # `bin/rails test test/integration` (G3) — BOTH of which SKIP test/system. With
    # git_push_heroku carrying no test step, a system-test regression could reach
    # rolio production completely ungated.
    %w[qa_test_cmd test_cmd].each do |field|
      cmd = Release::Repos.public_send(field, "rolio")
      assert_includes cmd, "test:system",
                      "rolio's #{field} must run the system tier — its deploy has no test step, so this " \
                      "command is the last gate before prod"
    end
  end

  test "rolio's ship gate matches its pre-QA gate so G4 can self-gate" do
    # Release::ShipSequence.ship_gate_skip? compares the command STRINGS verbatim
    # against what G3 recorded. If test_cmd drifts from qa_test_cmd, G4 can never
    # credit G3's certified run and the full suite runs a second time every ship.
    assert_equal Release::Repos.qa_test_cmd("rolio"), Release::Repos.test_cmd("rolio"),
                 "rolio's G4 test_cmd and G3 qa_test_cmd must be the same string"
  end

  test "rolio's gate keeps db:test:prepare FIRST so rake runs both tiers" do
    # SHAPE TRAP — do not "simplify" this command. `test` is a real rails COMMAND,
    # so `bin/rails test test:system` parses `test:system` as a PATH and dies with
    # `LoadError: cannot load such file -- <root>/test:system`. Both tiers run only
    # because a leading NON-command (db:test:prepare) routes the line through RAKE,
    # where `test` and `test:system` are two separate tasks.
    argv = Shellwords.split(Release::Repos.qa_test_cmd("rolio"))
    assert_equal %w[bin/rails db:test:prepare test test:system], argv
    assert_equal "db:test:prepare", argv[1],
                 "a rails-COMMAND first arg would parse the later tiers as file paths"
  end

  test "rolio's gate runs rolio's CI test command verbatim" do
    # THE DRIFT GUARD. Asserting against rolio's OWN ci.yml (not a literal) means
    # changing either side alone fails HERE, at the seam. rolio's ci.yml lives in
    # the SIBLING checkout, so this binds locally and in the gate workspace (where
    # G3/G4 actually run) and skips on the hub's GitHub runner, which checks out
    # only this repo. The shape assertions above bind everywhere.
    ci = sibling_ci_test_command("rolio")
    skip "rolio checkout not present (hub CI runner) — shape guards above still bind" if ci.nil?

    assert_equal ci, Release::Repos.qa_test_cmd("rolio"),
                 "rolio's G3 gate must run rolio CI's full suite (base + system tiers), verbatim"
  end

  # --- mcritchie-industries: git_push_heroku, so it gates like rolio ---

  test "mcritchie-industries' prod_deploy is git_push_heroku onto the canonical host" do
    adapter = Release::Repos.prod_deploy("mcritchie-industries")
    assert_equal "git_push_heroku", adapter["strategy"]
    assert_equal "https://git.heroku.com/mcritchie-industries.git", adapter["remote"]
    assert_equal "main", adapter["branch"]
    assert_equal "https://www.mcritchie.industries", adapter["smoke_url"]
  end

  test "mcritchie-industries registers CI's full suite at BOTH gates" do
    # git_push_heroku has NO test step, so the registered command is the last
    # gate before production and must be CI's full suite verbatim — which for
    # this repo is `test test:system`. Same string at both gates so G4 can
    # self-gate on G3.
    %w[test_cmd qa_test_cmd].each do |field|
      assert_equal "bin/rails db:test:prepare test test:system",
                   Release::Repos.public_send(field, "mcritchie-industries"),
                   "#{field} must be mcritchie-industries CI's full suite, verbatim"
    end
  end

  test "mcritchie-industries' gate runs its CI test command verbatim" do
    # THE DRIFT GUARD, rolio-style: asserted against the repo's OWN ci.yml at
    # origin/release, so when its first system test lands and ci.yml grows
    # `test:system`, this fails at the seam until the registry grows it too.
    # Anchored on the suite step (db:test:prepare) because this repo's test job
    # runs `bin/rails tailwindcss:build` BEFORE the suite — the bin/rails
    # anchor would find the asset build, not the gate command.
    ci = sibling_ci_test_command("mcritchie-industries", anchor: "db:test:prepare")
    skip "mcritchie-industries checkout not present (hub CI runner) — shape guards above still bind" if ci.nil?

    assert_equal ci, Release::Repos.qa_test_cmd("mcritchie-industries"),
                 "mcritchie-industries' G3 gate must run its CI suite, verbatim"
  end

  test "turf-monster has no system tests, so its integration subset is the right gate" do
    # Verified, not assumed: turf-monster's test/system holds only a .keep, so
    # there is no system tier to cover and bin/deploy's full suite is sufficient.
    root = projects_root
    skip "turf-monster checkout not present (hub CI runner)" if root.nil?

    system_tests = Dir[root.join("turf-monster", "test", "system", "**", "*_test.rb")]
    assert_empty system_tests,
                 "turf-monster grew system tests — its gate (bin/deploy's suite) must now cover them, the " \
                 "same gap this file closes for rolio"
  end

  # --- the branch ladder ------------------------------------------------------
  #
  # The conductor's rungs are accepted → release → main, and a repo it sweeps
  # needs both persistent branches. moms-app was created with `main` alone, so
  # every change to it reopened the question of where its PR should go — and
  # `bin/release init` could not have fixed that, because it built `release`
  # only. These assert the DECLARATION exists and MATCHES reality, so the gap
  # cannot recur by silence the way it did the first time.

  test "every registered repo declares a ladder" do
    undeclared = Release::Ladder.all(Release::Repos.config).reject do |repo|
      Release::Ladder.valid?(Release::Ladder.ladder(Release::Repos.config, repo))
    end

    assert_empty undeclared,
                 "these registry entries declare no valid `ladder:` " \
                 "(#{Release::Ladder::LADDERS.join(' | ')}): #{undeclared.join(', ')}. " \
                 "An omitted ladder is exactly the silence that let a repo ship without one."
  end

  # The declaration checked against the actual repos. Local refs only — no
  # network — so this runs the same offline everywhere, and reads `origin/*`
  # rather than local branches because the ladder lives on the remote.
  test "every three-rung repo really has both rungs" do
    root = projects_root
    skip "sibling checkouts not present (hub CI runner)" if root.nil?

    missing = Release::Ladder.sweepable(Release::Repos.config).flat_map do |repo|
      path = root.join(repo)
      next [] unless path.join(".git").exist?

      Release::Ladder::RUNGS.reject { |rung| remote_ref?(path, rung) }
                            .map { |rung| "#{repo} has no origin/#{rung}" }
    end

    assert_empty missing,
                 "a swept repo is missing a rung, so a feature PR has nowhere to land: " \
                 "#{missing.join('; ')}. Run `bin/release init` (it creates both)."
  end

  # The expiring exemption. `planned` means the repo does not exist yet; the day
  # it does, this fails and forces the declaration to be revisited — otherwise
  # `planned` quietly becomes a permanent hole, which is the failure mode the
  # whole guard exists to prevent.
  test "a planned repo has not quietly been created" do
    root = projects_root
    skip "sibling checkouts not present (hub CI runner)" if root.nil?

    config  = Release::Repos.config
    arrived = Release::Ladder.parked(config)
                             .select { |_repo, ladder| ladder == Release::Ladder::PLANNED }
                             .keys
                             .select { |repo| root.join(repo, ".git").exist? }

    assert_empty arrived,
                 "these repos are declared `planned` but are checked out now: #{arrived.join(', ')}. " \
                 "Onboard them (bin/release init) and flip the declaration to three-rung."
  end

  # Guards the guard: if the registry ever parsed to nothing, every assertion
  # above would pass over an empty list — green while checking nothing.
  test "the ladder guard actually has repos to check" do
    assert_operator Release::Ladder.sweepable(Release::Repos.config).length, :>=, 3,
                    "expected the sweepable set to hold the live repos"
  end

  private
    # The projects root holding the sibling checkouts. Resolved by ASCENDING from
    # Rails.root until a directory containing the sibling repos appears, so it works
    # from a primary checkout, an agent worktree, AND the gate workspace
    # (.worktrees/_gate), which sit at different depths. nil when absent (hub CI).
    def projects_root
      Rails.root.ascend.find { |dir| dir.join("rolio", ".git").exist? }
    end

    # Does this checkout know a remote-tracking ref for `branch`? A LOCAL read
    # (rev-parse against origin/*), never a network call, so the ladder guard
    # behaves identically on a dev Mac and in CI.
    def remote_ref?(path, branch)
      _out, status = Open3.capture2e("git", "-C", path.to_s,
                                     "rev-parse", "--verify", "--quiet", "origin/#{branch}")
      status.success?
    end

    # The single command a sibling repo's ci.yml `test` job runs. Located by content
    # (`bin/rails` by default; pass anchor: for a repo whose test job runs OTHER
    # bin/rails steps before the suite), not by step name, so renaming the step
    # cannot silently blind the drift guard. nil when the sibling isn't checked out.
    #
    # Read from `origin/release`, NOT the sibling's WORKING TREE. The working tree is
    # whatever branch that checkout happens to sit on — so an agent editing rolio's
    # ci.yml on a feature branch would turn THE HUB's gate red for a change that is
    # nowhere near the release. The registry gates the code that SHIPS, so it is held
    # against the branch that ships.
    def sibling_ci_test_command(repo, anchor: "bin/rails")
      root = projects_root
      return nil if root.nil?

      path = root.join(repo)
      raw, ok = Open3.capture2("git", "-C", path.to_s, "show", "origin/release:.github/workflows/ci.yml")
      return nil unless ok.success?

      ci    = YAML.safe_load(raw, aliases: true)
      steps = ci.dig("jobs", "test", "steps") || []
      run   = steps.filter_map { |s| s["run"] }.find { |c| c.include?(anchor) }
      assert run.present?, "#{repo}'s ci.yml `test` job no longer has a #{anchor} step — the guard is blind"
      run.strip
    end

  test "qa_test_cmd stays flag-style so the argv parse is unambiguous" do
    # Shellwords and String#split agree on these values (no quotes) — pins the
    # behavior-preserving half of the test_cmd_argv switch at the registry.
    %w[mcritchie-studio turf-monster mcritchie-industries rolio].each do |repo|
      cmd = Release::Repos.qa_test_cmd(repo)
      assert_equal cmd.split, Shellwords.split(cmd), "#{repo} qa_test_cmd must parse identically both ways"
    end
  end

  test "qa_test_cmd is nil for planned apps without a runnable integration tier" do
    # tax-studio has no sibling checkout yet; chain-ops' test/integration is
    # empty — both self-gate (the prepare gate skips) until they grow the tier.
    assert_nil Release::Repos.qa_test_cmd("tax-studio")
    assert_nil Release::Repos.qa_test_cmd("chain-ops")
  end

  test "qa_test_cmd is nil for a gem or an unknown repo" do
    assert_nil Release::Repos.qa_test_cmd("studio-engine")
    assert_nil Release::Repos.qa_test_cmd("not-a-real-repo")
  end

  # --- the hub's gate must cover what CI covers (the G3 system-test gap) ---

  test "the hub's G3 gate runs CI's test command verbatim" do
    # THE DRIFT GUARD, and the reason this file now parses ci.yml instead of
    # re-pinning a literal. `bin/rails test` SKIPS test/system — so while the gate
    # ran that and CI ran `db:test:prepare test test:system`, the gate's "full
    # suite" was NOT CI's full suite and a system-test regression rode the release
    # branch into QA ungated. A hard-coded string could drift out from under CI
    # again in silence; asserting against ci.yml itself means changing either side
    # alone fails HERE, at the seam, with the tiers named.
    assert_equal ci_test_command, Release::Repos.qa_test_cmd("mcritchie-studio"),
                 "the hub's G3 gate must run CI's full suite (base + system tiers), verbatim"
  end

  test "the hub's ship gate matches its pre-QA gate so G4 can self-gate" do
    # Release::ShipSequence.ship_gate_skip? compares the command STRINGS verbatim
    # against what G3 recorded. If test_cmd drifts from qa_test_cmd, G4 can never
    # credit G3's certified run and the full suite runs a second time every ship.
    assert_equal Release::Repos.qa_test_cmd("mcritchie-studio"),
                 Release::Repos.test_cmd("mcritchie-studio"),
                 "G4's test_cmd and G3's qa_test_cmd must be the same string"
  end

  test "the hub's gate keeps db:test:prepare FIRST so rake runs both tiers" do
    # SHAPE TRAP — do not "simplify" this command. `test` is a real rails COMMAND,
    # so `bin/rails test test:system` parses `test:system` as a PATH and dies with
    # `LoadError: cannot load such file -- <root>/test:system`. Both tiers run only
    # because a leading NON-command (db:test:prepare) routes the line through RAKE,
    # where `test` and `test:system` are two separate tasks.
    argv = Shellwords.split(Release::Repos.qa_test_cmd("mcritchie-studio"))
    assert_equal %w[bin/rails db:test:prepare test test:system], argv
    assert_equal "db:test:prepare", argv[1],
                 "a rails-COMMAND first arg would parse the later tiers as file paths"
  end

  private
    # WHAT CI'S RUBY SUITE AMOUNTS TO, AS ONE COMMAND — asked through the seam that
    # already answers exactly that question.
    #
    # This used to dig `jobs.test.steps` out of ci.yml itself. That stopped being
    # answerable on 2026-08-20, when the hub's Ruby suite was SHARDED: there is no
    # `test` job any more, and no single step whose `run:` is the suite — the `rails`
    # job runs a 4-way `bin/ci-shard` matrix and the `system` job runs the system tier.
    #
    # Re-pointing the dig at `jobs.rails` would have been the small edit and the wrong
    # one: a shard's command is a SLICE, so the gate would have been asserted equal to a
    # QUARTER of the suite and the release gated on it. CiTestCommand is where the
    # "sharded lane, therefore the DEFAULT superset" argument is written down, checked
    # structurally, and mutation-tested — so ask it, rather than re-deriving a weaker
    # answer here.
    def ci_test_command
      root = Rails.root.to_s

      # NOT VACUOUS. CiTestCommand.resolve falls back to DEFAULT for a repo with no CI
      # suite at all, so a ci.yml that lost its Ruby lane entirely would still return
      # the string this guard compares against and the guard would pass over nothing.
      # Assert first that CI really does carry a Ruby suite this seam can account for.
      assert CiTestCommand.sharded_lane?(root) || CiTestCommand.for_root(root).present?,
             "ci.yml no longer carries a Ruby suite CiTestCommand can account for — the drift guard is blind"

      CiTestCommand.resolve(root)
    end
end
