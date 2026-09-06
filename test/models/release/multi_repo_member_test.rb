# frozen_string_literal: true

require "test_helper"

# THE 2026-08-13 HALF-SHIP, and the guards that close it.
#
# `land-rails-security-patch` named two repos (mcritchie-studio, turf-monster) and
# carried the HUB's PR url — the only PR slot a task had. Every release stage read
# the singular Task#release_repo, which parses that url, so the promote list, the
# member plan, the repo plan, the pre-QA gate, the QA deploy and the ship all saw
# ONE repo. Turf was never promoted. The task was stamped `assembled`, then
# `shipped`, then `merged: "main"` — while turf production still ran the unpatched
# code. The board asserted a security patch reached production on a repo whose
# `main` had not moved.
#
# These tests assert the EFFECT, not the plan. A test that only checks "the repo
# plan is computed" passes against the broken code: the plan WAS computed,
# correctly, from the wrong field. So every guard here is driven by MUTATING the
# release — landing evidence for one repo and not the other — and asserting the
# member's STAGE and `merged` stamp.
class Release::MultiRepoMemberTest < ActiveSupport::TestCase
  HUB  = "mcritchie-studio"
  TURF = "turf-monster"
  HUB_PR  = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/836"
  TURF_PR = "https://github.com/McRitchie-Studio/turf-monster/pull/305"

  # The incident's exact task shape: two repos, a PR url per repo, `reviewed` and
  # ready to ride.
  def two_repo_task(label = "security")
    Task.create!(
      title: "land rails #{label} patch",
      stage: "reviewed",
      metadata: { "devops" => {
        "shape" => "backend",
        "repositories" => [ HUB, TURF ],
        "pr_url" => HUB_PR,
        "pr_urls" => { HUB => HUB_PR, TURF => TURF_PR }
      } }
    )
  end

  def single_repo_task(label = "hub", repo: HUB)
    Task.create!(title: "single repo #{label} task", stage: "reviewed",
                 metadata: { "devops" => { "shape" => "backend", "repositories" => [ repo ] } })
  end

  # Land the per-repo QA record a real `bin/release prepare` writes for each repo it
  # promoted + deployed. Naming ONE repo here is the mutation: it reproduces the
  # candidate that carried the hub and skipped turf.
  def qa_landed(release, *repos)
    Release::Conductor.record_qa_shas(release: release, shas: repos.to_h { |r| [ r, "#{r}-qa-sha" ] })
  end

  # Land the per-repo `release → main` record `bin/release ship` writes as each ff
  # lands on origin.
  def shipped_landed(release, *repos)
    Release::Conductor.record_shipped_shas(release: release, shas: repos.to_h { |r| [ r, "#{r}-prod-sha" ] })
  end

  # --- the task's release identity ---

  test "[unit] release_repos carries EVERY repo the task names, primary first" do
    task = two_repo_task

    assert_equal HUB, task.release_repo, "the primary is unchanged — parsed from pr_url"
    assert_equal [ HUB, TURF ], task.release_repos
  end

  test "[unit] release_repos surfaces a repo known ONLY from its recorded PR url" do
    task = Task.create!(title: "repo from pr only", stage: "reviewed",
                        metadata: { "devops" => { "repositories" => [ HUB ], "pr_url" => HUB_PR,
                                                  "pr_urls" => { TURF => TURF_PR } } })

    assert_includes task.release_repos, TURF, "a recorded PR is proof the repo is in the task"
  end

  test "[unit] release_pr_urls folds the singular pr_url in under the repo it names" do
    task = Task.create!(title: "folds primary pr url", stage: "reviewed",
                        metadata: { "devops" => { "repositories" => [ HUB, TURF ], "pr_url" => HUB_PR } })

    assert_equal({ HUB => HUB_PR }, task.release_pr_urls)
    assert_equal [ TURF ], task.repos_missing_pr_url, "turf's PR has nowhere to live yet — that is the bug"
  end

  test "[unit] the devops normalizer keeps pr_urls a MAP instead of stringifying it" do
    # Every writer funnels through here. The scalar branch would have written
    # '{"turf-monster"=>"https://…"}' and the list branch would have split it on
    # commas — either way the map would be unreadable and the refusal unclearable.
    normalized = Task.normalize_devops_metadata("pr_urls" => { TURF => TURF_PR })

    assert_equal({ "pr_urls" => { TURF => TURF_PR } }, normalized)
  end

  test "[unit] the normalizer keys a bare list of PR urls by the repo each names" do
    normalized = Task.normalize_devops_metadata("pr_urls" => [ HUB_PR, TURF_PR ])

    assert_equal({ "pr_urls" => { HUB => HUB_PR, TURF => TURF_PR } }, normalized)
  end

  test "[unit] the normalizer REFUSES a pr_urls entry that names no repo" do
    # A silently-dropped PR url is exactly the failure this key exists to close.
    error = assert_raises(ArgumentError) do
      Task.normalize_devops_metadata("pr_urls" => [ "https://example.com/not-a-pr" ])
    end
    assert_match(/names no repo/, error.message)
  end

  # --- the plan (necessary, but NOT the proof — see the header) ---

  test "[unit] repo_plan fans a two-repo member out into BOTH repos" do
    task = two_repo_task
    release = Release::Conductor.sweep!(task)

    plan = Release::Conductor.repo_plan(release)

    assert_equal [ HUB, TURF ].sort, plan.map { |g| g[:repo] }.sort
    plan.each do |group|
      assert_includes group[:members].map { |m| m[:slug] }, task.slug,
                      "the member must appear in every repo it names"
    end
  end

  test "[unit] a member's post_deploy_cmd rides ONLY its primary repo's group" do
    task = two_repo_task
    task.update!(metadata: task.metadata.deep_merge("devops" => { "post_deploy_cmd" => "rake hub:backfill" }))
    release = Release::Conductor.sweep!(task)

    plan = Release::Conductor.repo_plan(release).index_by { |g| g[:repo] }

    assert_equal "rake hub:backfill", plan[HUB][:members].first[:post_deploy_cmd]
    assert_nil plan[TURF][:members].first[:post_deploy_cmd],
               "a hub rake task must not be fired at turf's dyno just because the task names turf"
  end

  # --- THE EFFECT: `assembled` requires per-repo evidence ---

  test "[integration] a two-repo member whose second repo was never promoted does NOT reach assembled" do
    task = two_repo_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB) # the mutation: this candidate carried the hub and skipped turf

    Release::Conductor.qa_green!(release.reload)

    assert_equal "reviewed", task.reload.stage,
                 "a member spanning a repo the candidate never QA'd must not be stamped assembled"
    assert_equal Task::MERGED_RELEASE, task.merged, "it stays swept, for the next self-healing run"
  end

  test "[integration] the same member DOES reach assembled once the missing repo lands" do
    task = two_repo_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB)
    Release::Conductor.qa_green!(release.reload)
    assert_equal "reviewed", task.reload.stage

    qa_landed(release.reload, TURF) # the second repo finally rides
    Release::Conductor.qa_green!(release.reload)

    assert_equal "assembled", task.reload.stage
  end

  test "[integration] a single-repo member on the same candidate still assembles" do
    # The guard must be precise: holding the neighbours would jam the release.
    two_repo = two_repo_task
    neighbour = single_repo_task
    release = Release::Conductor.sweep!(two_repo)
    Release::Conductor.sweep!(neighbour)
    qa_landed(release.reload, HUB)

    Release::Conductor.qa_green!(release.reload)

    assert_equal "assembled", neighbour.reload.stage
    assert_equal "reviewed", two_repo.reload.stage
  end

  # --- THE EFFECT: `shipped` requires per-repo evidence ---

  test "[integration] a two-repo member whose second repo never reached main does NOT reach shipped" do
    task = two_repo_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB, TURF)
    Release::Conductor.qa_green!(release.reload)
    assert_equal "assembled", task.reload.stage

    shipped_landed(release.reload, HUB) # the mutation: only the hub's `main` moved
    Release::Conductor.ship!(release: release.reload, deployed_sha: "deadbeef")

    task.reload
    assert_equal "assembled", task.stage,
                 "a member spanning a repo whose main never moved must not be stamped shipped"
    refute_equal Task::MERGED_MAIN, task.merged,
                 "and it must never claim its code is on main"
  end

  test "[integration] the same member ships once its second repo's main lands" do
    task = two_repo_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB, TURF)
    Release::Conductor.qa_green!(release.reload)
    shipped_landed(release.reload, HUB)
    Release::Conductor.ship!(release: release.reload, deployed_sha: "deadbeef")
    assert_equal "assembled", task.reload.stage

    shipped_landed(release.reload, TURF)
    Release::Conductor.ship!(release: release.reload, deployed_sha: "deadbeef")

    task.reload
    assert_equal "shipped", task.stage
    assert_equal Task::MERGED_MAIN, task.merged
  end

  test "[integration] a single-repo member ships alongside a held multi-repo one" do
    two_repo = two_repo_task
    neighbour = single_repo_task
    release = Release::Conductor.sweep!(two_repo)
    Release::Conductor.sweep!(neighbour)
    qa_landed(release.reload, HUB, TURF)
    Release::Conductor.qa_green!(release.reload)
    shipped_landed(release.reload, HUB)

    Release::Conductor.ship!(release: release.reload, deployed_sha: "deadbeef")

    assert_equal "shipped", neighbour.reload.stage
    assert_equal "assembled", two_repo.reload.stage
  end

  # --- the curation guard, checked over EVERY repo a member names ---
  #
  # The other half of the sweep-time refusal — a multi-repo member whose PR record
  # covers only SOME of its repos — is now here too: validate_member_pr_coverage!,
  # sharing Release::SweepPlan's coverage rule through Task#repos_missing_pr_url so
  # the CLI's pre-promote screen and this record-time backstop cannot disagree. The
  # per-repo evidence guard above remains the stage AFTER it.

  test "[unit] validate_members! passes a multi-repo member with a PR url per repo" do
    release = Release::Conductor.sweep!(two_repo_task)

    assert_nothing_raised { Release::Conductor.validate_members!(release.reload) }
  end

  test "[unit] validate_members! catches an unregistered SECOND repo" do
    task = Task.create!(title: "names an unknown repo", stage: "reviewed",
                        metadata: { "devops" => {
                          "repositories" => [ HUB, "not-a-registered-repo" ],
                          "pr_url" => HUB_PR,
                          "pr_urls" => { HUB => HUB_PR,
                                         "not-a-registered-repo" => "https://github.com/x/not-a-registered-repo/pull/1" }
                        } })
    release = Release::Conductor.sweep!(task)

    error = assert_raises(ArgumentError) { Release::Conductor.validate_members!(release.reload) }

    assert_match(/unknown repo/, error.message)
    assert_match(/not-a-registered-repo/, error.message)
  end

  # --- A GEM MEMBER: two different questions, two different sets ---
  #
  # Slice 1's review left this decision to this slice, so decide it explicitly.
  # #pr_bearing_repositories deliberately UNDER-measures a gem task: an engine task
  # names its consumers, but the work is ONE PR in the gem repo, so it is measured
  # against the gem alone and no PR is ever demanded of a consumer. That under-
  # measures a gem task that legitimately carries a consumer PR too (the breaking-
  # change forward-compat shape).
  #
  # KEEPING IT, because the two sets answer different questions and #release_repos
  # is the one that governs membership:
  #   * #pr_bearing_repositories = "which repos did the BUILDER owe a PR in" — the
  #     set slice 4's sweep-time refusal will measure. Widening it to the consumers
  #     would re-create the exact inversion it exists to prevent: every legitimate
  #     engine release would report both consumers "missing a PR", and once the
  #     refusal is wired that would BLOCK every engine release for the absence of
  #     work nobody is supposed to do.
  #   * #release_repos = "which repos does this task SHIP through" — a deliberate
  #     SUPERSET, built from the declared repositories regardless of PR coverage.
  #     A consumer can therefore never fall out of the plan because no PR was
  #     demanded of it, and it is still held to per-repo evidence.
  # So the residual risk is bounded and visible: a gem task missing a consumer
  # forward-compat PR is not refused at sweep time, but its consumer is still
  # promoted, still deployed and still evidence-guarded — it fails at QA rather
  # than shipping silently. These two tests pin exactly that.

  ENGINE = "studio-engine"
  ENGINE_PR = "https://github.com/McRitchie-Studio/studio-engine/pull/77"

  def gem_task(label = "engine")
    Task.create!(
      title: "bump #{label} for consumers",
      stage: "reviewed",
      metadata: { "devops" => {
        "shape" => "library",
        "repositories" => [ ENGINE, HUB, TURF ],
        "pr_url" => ENGINE_PR,
        "pr_urls" => { ENGINE => ENGINE_PR }
      } }
    )
  end

  test "[unit] a gem task PLANS its consumers even though it owes them no PR" do
    task = gem_task

    assert_equal [ ENGINE ], task.pr_bearing_repositories,
                 "the work is one PR in the gem repo — a consumer PR must never be demanded"
    assert_empty task.repos_missing_pr_url,
                 "a legitimate engine release must not report its consumers missing"
    assert_equal [ ENGINE, HUB, TURF ], task.release_repos,
                 "membership is a SUPERSET of PR coverage — the consumers still ship"
    assert_operator (task.release_repos & task.pr_bearing_repositories).size, :==,
                    task.pr_bearing_repositories.size,
                    "release_repos must contain every pr_bearing repo — the invariant slice 4 relies on"
  end

  test "[integration] a gem member whose CONSUMER never got QA does NOT reach assembled" do
    # The under-measured case, driven: no PR was ever demanded of turf, so nothing
    # refused this member at sweep time. Evidence is what still catches it.
    task = gem_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB) # the mutation: the gem published, the hub deployed, turf did not

    Release::Conductor.qa_green!(release.reload)

    assert_equal "reviewed", task.reload.stage,
                 "turf carried no QA record — the member must be HELD, not stamped assembled"
  end

  test "[integration] the gem member assembles once every consumer lands, gem exempt" do
    task = gem_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB, TURF) # both consumers deployed; the GEM is published, never deployed

    Release::Conductor.qa_green!(release.reload)

    assert_equal "assembled", task.reload.stage,
                 "a gem repo carries no QA sha by design — demanding one would hold every gem forever"
  end

  # THE INCIDENT'S TASK, exactly: two repos, and only the hub's PR url — because the
  # hub's was the only PR slot a task had. Every sweep write runs validate_members!
  # inside its transaction, so this raise leaves the members `reviewed` and the RC
  # unopened rather than recording a member the pipeline cannot vouch for.
  test "[unit] validate_members! refuses a multi-repo member with an incomplete PR record" do
    task = Task.create!(title: "land rails security patch", stage: "reviewed",
                        metadata: { "devops" => {
                          "shape" => "backend",
                          "repositories" => [ HUB, TURF ],
                          "pr_url" => HUB_PR
                        } })
    release = Release::Conductor.sweep!(task)

    error = assert_raises(ArgumentError) { Release::Conductor.validate_members!(release.reload) }

    assert_match(/incomplete PR record/, error.message)
    assert_match(/#{TURF}/, error.message, "the refusal names the repo with no PR url")
    assert_match(/--pr-url-for/, error.message, "…and the command that fixes it")
  end

  test "[unit] validate_members! leaves a SINGLE-repo member with no PR url alone" do
    # A single-repo task cannot lose a repo it never had a second of; its missing PR
    # is the review lane's problem, not the sweep's. Without the rule's size<2 guard
    # this refusal would fire on ordinary single-repo work and jam every sweep.
    release = Release::Conductor.sweep!(single_repo_task)

    assert_nothing_raised { Release::Conductor.validate_members!(release.reload) }
  end

  # THE GEM RELEASE, pinned before the refusal ships — because this is the shape the
  # refusal would have falsely blocked, and it is a LIVE one:
  # `guard-engine-migration-rollback` (shipped 2026-08-14) names studio-engine plus
  # three consumers behind ONE studio-engine PR. `release_pr_urls` keys the singular
  # pr_url by the repo its URL parses to, so every consumer reads as "missing" — but
  # a consumer's change in a gem release is committed by the pipeline itself
  # (bump_consumer_locks_for_qa), so there is no PR url that could ever be recorded.
  # Refusing it would have blocked every engine release: the OPPOSITE of the failure
  # this guard closes.
  def gem_task_naming_consumers
    Task.create!(title: "guard engine migration rollback", stage: "reviewed",
                 metadata: { "devops" => {
                   "shape" => "library",
                   "repositories" => [ "studio-engine", HUB, TURF ],
                   "pr_url" => "https://github.com/McRitchie-Studio/studio-engine/pull/124"
                 } })
  end

  test "[unit] a gem release naming its consumers reports NO missing PR urls" do
    task = gem_task_naming_consumers

    assert_equal :gem, task.release_kind, "shape library ⇒ gem release"
    assert_equal [ HUB, TURF ], task.release_repos - [ "studio-engine" ],
                 "the consumers ARE named — the exemption is about the PR, not the repos"
    assert_empty task.repos_missing_pr_url,
                 "a consumer's lock bump is authored by the pipeline; there is no PR to record"
  end

  test "[unit] validate_members! passes a gem release carrying only the gem PR" do
    release = Release::Conductor.sweep!(gem_task_naming_consumers)

    assert_nothing_raised { Release::Conductor.validate_members!(release.reload) }
  end

  # The CONTROL for the exemption: the same repo list on an APP member is the
  # 2026-08-13 incident and must still be refused. Nothing about naming consumers
  # earns the pass — only the gem kind does.
  test "[unit] the same repo list on an APP member is still refused" do
    task = Task.create!(title: "land rails security patch", stage: "reviewed",
                        metadata: { "devops" => {
                          "shape" => "backend",
                          "repositories" => [ HUB, TURF ],
                          "pr_url" => HUB_PR
                        } })

    assert_equal :app, task.release_kind
    assert_equal [ TURF ], task.repos_missing_pr_url
  end

  # --- THE EFFECT: a DECLARED QA-evidence exemption, and the fence around it ----
  #
  # turf-vault is an Anchor program. The pre-QA gate skips it (no qa_test_cmd →
  # "self-gates") and the QA deploy loop skips it (absent from qa_environments.yml
  # → "no QA environment registered"), and BOTH skip before writing any evidence —
  # so a candidate carrying turf-vault recorded nothing for it and every member
  # naming it was held at `reviewed` permanently. Re-running never cleared it:
  # no run can produce evidence for a step that is skipped by design.
  # rel-20260905-d6c266 held sharpen-update-signers-recipe and
  # document-signer-rotation-path; rel-20260906-90c443 held
  # qualify-vault-authority-by-cluster.
  #
  # The registry now DECLARES `qa_evidence: exempt` and the guard reads the
  # declaration. These tests drive the EFFECT — the member's STAGE — and, just as
  # importantly, they drive the NEGATIVE: an exemption that leaked into a repo
  # which merely LOOKS unconfigured would be a worse defect than the hold it fixes.

  VAULT    = "turf-vault"
  VAULT_PR = "https://github.com/McRitchie-Studio/turf-vault/pull/8"
  # A registered app sharing turf-vault's config shape (no qa_test_cmd, no QA env)
  # but carrying NO exemption declaration — the control for the fence below.
  TWIN     = "tax-studio"
  TWIN_PR  = "https://github.com/McRitchie-Studio/tax-studio/pull/1"

  # The single-repo shape: sharpen-update-signers-recipe, a docs/recipe change
  # landing only in the Anchor repo.
  def vault_only_task(label = "update signers recipe")
    Task.create!(title: "sharpen #{label}", stage: "reviewed",
                 metadata: { "devops" => { "shape" => "backend", "repositories" => [ VAULT ],
                                           "pr_url" => VAULT_PR } })
  end

  # The spanning shape: qualify-vault-authority-by-cluster, which named turf-vault
  # AND turf-monster.
  def vault_and_turf_task
    Task.create!(title: "qualify vault authority by cluster", stage: "reviewed",
                 metadata: { "devops" => {
                   "shape" => "backend",
                   "repositories" => [ TURF, VAULT ],
                   "pr_url" => TURF_PR,
                   "pr_urls" => { TURF => TURF_PR, VAULT => VAULT_PR }
                 } })
  end

  test "[integration] a turf-vault-only member assembles though the candidate QA'd nothing for it" do
    task = vault_only_task
    neighbour = single_repo_task
    release = Release::Conductor.sweep!(task)
    Release::Conductor.sweep!(neighbour)
    # The real candidate's shape: the hub deployed to QA, turf-vault CANNOT.
    qa_landed(release.reload, HUB)

    Release::Conductor.qa_green!(release.reload)

    assert_equal "assembled", task.reload.stage,
                 "turf-vault produces no QA evidence BY DESIGN — holding it made the board read " \
                 "wrong for the whole QA window with no run able to clear it"
    assert_equal "assembled", neighbour.reload.stage, "and its neighbours are unaffected"
  end

  test "[integration] a member spanning turf-vault assembles once its DEPLOYABLE repo lands" do
    task = vault_and_turf_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, TURF) # turf QA'd; turf-vault cannot be, and is exempt

    Release::Conductor.qa_green!(release.reload)

    assert_equal "assembled", task.reload.stage
  end

  # THE FENCE, part 1 — PRECISION. The exemption must drop turf-vault and nothing
  # else. Same member, same run, but the repo that CAN be QA'd wasn't.
  test "[integration] the exemption drops turf-vault ALONE — an unevidenced sibling still holds" do
    task = vault_and_turf_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB) # neither TURF nor VAULT landed; only VAULT is exempt

    Release::Conductor.qa_green!(release.reload)

    assert_equal "reviewed", task.reload.stage,
                 "turf-monster is a deployable Rails app with a registered QA env — its missing " \
                 "evidence must still hold the member, exactly as it did before"
    assert_equal Task::MERGED_RELEASE, task.merged, "and it stays swept for the next self-healing run"
  end

  # THE FENCE, part 2 — MUTATION. Remove the DECLARATION and nothing else. If the
  # member still assembles, the fix was a loosened guard rather than a declared
  # fact, and the 2026-08-13 silent-stamp class is reopened for every repo.
  test "[integration] MUTATION: strip the declaration and the same member is HELD again" do
    task = vault_only_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, HUB)

    Release::Repos.stub(:qa_evidence_exempt?, ->(_repo) { false }) do
      Release::Conductor.qa_green!(release.reload)
    end

    assert_equal "reviewed", task.reload.stage,
                 "the assemble in the tests above must be CAUSED by the registry declaration. " \
                 "If this passes without it, the guard was disarmed for every repo."
  end

  # THE FENCE, part 3 — THE TWIN. tax-studio has the SAME config shape that used to
  # be read as "exempt": no qa_test_cmd, and no config/qa_environments.yml entry.
  # The only thing separating it from turf-vault is that turf-vault DECLARES the
  # exemption and tax-studio does not. So this member must still be held — and it
  # catches every inference-flavoured repair (keying off a blank qa_test_cmd, or off
  # a missing QA environment) WITHOUT stubbing anything, unlike the mutation above.
  test "[integration] a repo with turf-vault's exact config but NO declaration is still held" do
    task = Task.create!(title: "tax studio twin", stage: "reviewed",
                        metadata: { "devops" => { "shape" => "backend",
                                                  "repositories" => [ TWIN ],
                                                  "pr_url" => TWIN_PR } })
    release = Release::Conductor.sweep!(task)
    qa_landed(release.reload, HUB)

    Release::Conductor.qa_green!(release.reload)

    assert_equal "reviewed", task.reload.stage,
                 "#{TWIN} registers no qa_test_cmd and has no QA environment — exactly like " \
                 "turf-vault — but it never DECLARED an exemption, so the guard must still hold it. " \
                 "If this assembles, the exemption is being inferred from missing config."
  end

  # THE FENCE, part 4 — SCOPE. The QA exemption must not reach the `shipped` stamp.
  # `bin/release ship` genuinely fast-forwards turf-vault's release → main and
  # records the sha at the push chokepoint (bin/release.rb:4314) whether or not a
  # deploy adapter fires — so ship evidence for this repo is REAL, and honouring
  # the exemption there would disarm a guard that currently works.
  test "[integration] the QA exemption does NOT extend to `shipped` — main must really move" do
    task = vault_and_turf_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, TURF)
    Release::Conductor.qa_green!(release.reload)
    assert_equal "assembled", task.reload.stage

    shipped_landed(release.reload, TURF) # turf's main moved; turf-vault's did not
    Release::Conductor.ship!(release: release.reload, deployed_sha: "deadbeef")

    task.reload
    assert_equal "assembled", task.stage,
                 "turf-vault's main really does get ff'd — a member must not claim `shipped` " \
                 "on a run that never advanced it"
    refute_equal Task::MERGED_MAIN, task.merged
  end

  test "[integration] the same member ships once turf-vault's main actually lands" do
    task = vault_and_turf_task
    release = Release::Conductor.sweep!(task)
    qa_landed(release, TURF)
    Release::Conductor.qa_green!(release.reload)
    shipped_landed(release.reload, TURF)
    Release::Conductor.ship!(release: release.reload, deployed_sha: "deadbeef")
    assert_equal "assembled", task.reload.stage

    shipped_landed(release.reload, VAULT) # the ff the conductor records at the push
    Release::Conductor.ship!(release: release.reload, deployed_sha: "deadbeef")

    task.reload
    assert_equal "shipped", task.stage
    assert_equal Task::MERGED_MAIN, task.merged
  end

  # ONE RULE, TWO CALLERS. The CLI screens with Release::SweepPlan.repo_coverage_gap
  # before it promotes; the conductor backstops with Task#repos_missing_pr_url at the
  # record. They must be the same verdict — two spellings is how a screen and its
  # guard drift apart, which is what let `bin/release merge` carry three guards that
  # could never fire.
  test "[unit] repos_missing_pr_url IS SweepPlan's coverage rule, not a second copy" do
    task = Task.create!(title: "land rails security patch", stage: "reviewed",
                        metadata: { "devops" => {
                          "repositories" => [ HUB, TURF ], "pr_url" => HUB_PR
                        } })

    assert_equal Release::SweepPlan.repo_coverage_gap(repos: task.release_repos,
                                                      pr_repos: task.release_pr_urls.keys),
                 task.repos_missing_pr_url
    assert_equal [ TURF ], task.repos_missing_pr_url
  end
end
