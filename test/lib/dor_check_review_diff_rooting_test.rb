# frozen_string_literal: true

# Regression for the bin/dor-check DIFF rooting — the FALSE PASS half of the
# wrong-tree family.
#   ruby -Itest test/lib/dor_check_review_diff_rooting_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# THE BUG (2026-08-08, task dor-check-review-rooting). `bin/dor-check <task>
# --gate-role review`, run from the mcritchie-studio PRIMARY checkout — which is
# EXACTLY what pr-review-primary.md instructs (its Entry says `cd
# /Users/alex/projects/mcritchie-studio`, a later step says run the gate, and nothing
# pins either to the task's tree) — inspected the PRIMARY's working tree instead of
# the task's diff. Observed, verbatim, over a multi-file code PR:
#
#   ✓ DoR-to-Merge n/a … doc-only diff (kind: chore): 1 file(s), none behavioral —
#     docs/agents/maintenance/delete-later.md [source: git working tree]
#     → ready to advance submitted → reviewed
#
# That file was one unrelated dirty file on the primary's `main`. The PR was a
# multi-file code change. Re-run rooted at the task's worktree, the same command
# evaluated the real diff and passed honestly.
#
# WHY THIS IS THE DANGEROUS DIRECTION. The 2026-07-14 fix
# (test/lib/dor_check_root_guard_test.rb) rooted the cert FINGERPRINT and stopped at
# the builder lane, reasoning that review "already roots at the branch tree". True of
# the fingerprint; false of the DIFF, which never re-rooted in either lane. And the
# two fail OPPOSITELY: a foreign fingerprint can only ever produce a false STALE —
# loud, self-correcting, nobody accepts an unexplained refusal. A foreign DIFF
# produces a false PASS in the gate whose entire job is refusing under-tested work,
# it is indistinguishable from a real verdict, and the dirtier the checkout the more
# confidently it lies.
#
# THE INVARIANT THESE TESTS ASSERT, in both directions:
#
#     dor-check's diff is the TASK's diff. Never the diff of the tree you stand in —
#     which can wave code through (a dirty .md here) just as easily as it can block
#     prose (a dirty .rb here).
#
# A happy-path test would have passed BEFORE this fix and proves nothing, so every
# integration case below stands in a checkout that is deliberately dirty with files
# that would flip the verdict if they were read.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

load File.expand_path("../../bin/lib/cert_root_guard.rb", __dir__)

class DorCheckReviewDiffRootingTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  SLUG = "task-x"
  # The exact file from the observed false pass. Prose, so reading it from the wrong
  # tree buys the `kind: chore` exemption.
  PRIMARY_DIRT = "docs/agents/maintenance/delete-later.md"
  # The PR's real contents: MULTI-FILE and behavioral, so a gate that sees them
  # cannot possibly call the change doc-only.
  PR_CODE = ["app/services/widget.rb", "app/models/gadget.rb"].freeze

  # ── git fixtures ───────────────────────────────────────────────────────────

  def git!(dir, *args)
    assert system("git", "-C", dir, *args, out: File::NULL, err: File::NULL), "git #{args.join(' ')}"
  end

  def write(dir, rel, body)
    full = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  # A repo that ignores /.worktrees/, exactly as every managed repo does (see this
  # repo's own .gitignore: "Hidden per-task git worktrees created by
  # bin/agent-worktree"). This is not decoration — WITHOUT it the primary's untracked
  # listing includes `.worktrees/<slug>/`, which classifies as behavioral, and the
  # pre-fix run gets GATED by the very worktree it was failing to look inside. The
  # fixture would then redden on the wrong-tree assertion while never reproducing the
  # false PASS the whole task is about.
  def init_repo(dir)
    FileUtils.mkdir_p(dir)
    real = File.realpath(dir)
    git!(real, "init", "-q")
    git!(real, "config", "user.email", "t@t.co")
    git!(real, "config", "user.name", "T")
    # The `origin` every real clone has. NOT decoration: the repo axis asks origin
    # FIRST and only falls back to the directory name when there is none, so fixtures
    # without a remote quietly exercised the FALLBACK — the weaker, owner-blind path
    # this round set out to stop trusting. Nulling remote_slug used to leave every
    # integration test green, i.e. the suite was green for a reason that would have
    # survived deleting the mechanism (review round 5).
    git!(real, "remote", "add", "origin", origin_url_for(real))
    write(real, "README.md", "base\n")
    write(real, ".gitignore", "/.worktrees/\n")
    git!(real, "add", "-A")
    git!(real, "commit", "-qm", "init")
    real
  end

  # …/<app> and …/<app>/.worktrees/<slug> both belong to <app>.
  def origin_url_for(dir)
    app = File.basename(File.dirname(dir)) == ".worktrees" ? CertRootGuard.app_of(dir) : File.basename(dir)
    "https://github.com/McRitchie-Studio/#{app}.git"
  end

  # A task tree: the base rung recorded as a remote ref, then the feature committed
  # on feat/<slug> — the state a REVIEWER meets (branch pushed, nothing uncommitted).
  #
  # `base_rung` is the rung this repo actually has. Post-v2 hub/satellite repos have
  # origin/accepted; a moms-app-style repo has only origin/main, and the gate must
  # resolve each repo's OWN base rather than assuming one ladder.
  def build_task_tree(dir, files:, base_rung: "accepted", branch: "feat/#{SLUG}")
    tree = init_repo(dir)
    git!(tree, "update-ref", "refs/remotes/origin/#{base_rung}", "HEAD")
    git!(tree, "checkout", "-q", "-b", branch)
    files.each { |rel| write(tree, rel, "# #{rel}\n") }
    git!(tree, "add", "-A")
    git!(tree, "commit", "-qm", "feat")
    git!(tree, "update-ref", "refs/remotes/origin/#{branch}", branch)
    tree
  end

  # The world the bug lives in:
  #
  #   <projects>/myapp/                    ← the PRIMARY the reviewer stands in, on
  #                                          `release`, DIRTY with `dirt` — files that
  #                                          are not the task's and never were.
  #   <projects>/myapp/.worktrees/task-x/  ← the task's tree, carrying `files` on
  #                                          feat/task-x.
  #
  # `worktree: false` omits the task tree entirely. Yields [projects, primary, tree].
  def with_world(files: PR_CODE, dirt: [PRIMARY_DIRT], worktree: true, base_rung: "accepted")
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      primary = init_repo(File.join(projects, "myapp"))
      git!(primary, "checkout", "-q", "-b", "release")
      dirt.each { |rel| write(primary, rel, "unrelated local scratch\n") }

      tree = nil
      tree = build_task_tree(File.join(projects, "myapp", ".worktrees", SLUG), files: files,
                             base_rung: base_rung) if worktree
      yield projects, primary, tree
    end
  end

  # ── the task fixture ───────────────────────────────────────────────────────

  # A `kind: chore` task — an EXEMPT kind, so the whole shape/test-tier gate hangs on
  # one question: does the observed diff ship behavior? That makes it the exact shape
  # the false pass needs, and the sharpest probe of WHICH tree got observed.
  def chore_task(slug: SLUG, repo: "myapp", pr: true)
    {
      "slug" => slug, "title" => "Task X",
      "metadata" => { "devops" => {
        "kind" => "chore",
        "branch" => "feat/#{slug}",
        "worktree_slug" => slug,
        "pr_url" => (pr ? "https://github.com/McRitchie-Studio/#{repo}/pull/7" : nil),
        "acceptance" => ["read the task's diff"],
        "repositories" => [repo],
        "risk_tags" => ["gate-integrity"],
        "test_plan" => ["[unit] resolver", "[integration] dor-check"],
        "post_deploy_cmd" => "none",
        "checks_run" => []
      }.compact }
    }
  end

  # Run bin/dor-check FROM `cwd` with an IMPLICIT root (no DOR_CHECK_DIFF_ROOT — an
  # explicit one is the caller declaring a root, and bypasses the guard by design).
  #
  # DOR_CHECK_PR_FILES=unverified simulates the observed condition: `gh` could not
  # read the PR's file list, so the resolver falls back to a local view. That
  # fallback is the whole subject of this file — when it is allowed to be the
  # PRIMARY's working tree, the gate lies.
  #
  # Returns [verdict_hash, exit_code, stderr].
  def dor_check(task, cwd, projects, *args, pr_files: "unverified")
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      err = File.join(d, "stderr.txt")
      File.write(path, JSON.generate(task))
      env = SessionEnv.neutralized(
        "DOR_CHECK_DIFF_ROOT" => nil,
        "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_DIFF_BASE" => nil, # exercise the real release-aware base resolver
        "DOR_CHECK_PR_FILES" => pr_files,
        "DOR_CHECK_CI_STATUS" => "green",
        "DOR_CHECK_SUITE_EVIDENCE" => "ok",
        "DOR_CHECK_PROJECTS_DIR" => projects
      )
      out = IO.popen(env, "#{BIN} #{task['slug']} --file #{path} --json #{args.join(' ')} 2>#{err}",
                     chdir: cwd, &:read)
      [JSON.parse(out), $?.exitstatus, File.read(err)]
    end
  end

  # The verdict describes SOME tree; these say which, positively.
  def assert_saw_the_prs_code(verdict, code, files: PR_CODE)
    # First, and most specifically: the false PASS itself. A `kind: chore` whose PR
    # ships behavior must never collect the doc-only exemption, whatever tree the
    # caller is standing in.
    refute verdict["exempt"], "THE BUG: the doc-only exemption granted to a multi-file code PR"
    assert_equal 1, code, "a multi-file code diff on an unshaped chore must NOT advance: #{verdict['errors']}"
    refute verdict["ready"]
    assert_equal files.sort, Array(verdict["changed_files"]).sort,
                 "the gate must have observed the TASK's files"
    refute_includes Array(verdict["changed_files"]), PRIMARY_DIRT,
                    "the standing checkout's unrelated dirt is not this task's diff"
    assert_match(/ships a code diff/, verdict["errors"].join(" "),
                 "seeing the code must trigger the shape/test-tier gate")
  end

  # ── [unit] the resolver: which tree belongs to this task ───────────────────

  def with_two_repo_worktrees
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      # Alphabetical order decides a first-hit pick, so name them so the WRONG one
      # sorts first. This is the live shape on the operator's machine today:
      # repair-moms-app-ci exists under BOTH moms-app and studio-engine.
      a = File.join(projects, "aaa-app", ".worktrees", SLUG)
      b = File.join(projects, "zzz-app", ".worktrees", SLUG)
      [a, b].each { |p| FileUtils.mkdir_p(p) }
      yield projects, a, b
    end
  end

  def test_unit_worktree_candidates_lists_every_repos_worktree
    with_two_repo_worktrees do |projects, a, b|
      assert_equal [a, b].sort, CertRootGuard.worktree_candidates(SLUG, projects),
                   "a multi-repo task has one worktree per repo; the set is the fact, the pick is a guess"
      assert_empty CertRootGuard.worktree_candidates("never-created", projects)
    end
  end

  def test_unit_worktree_hint_prefers_the_repo_the_work_belongs_to
    with_two_repo_worktrees do |projects, a, b|
      assert_equal b, CertRootGuard.worktree_hint(SLUG, projects, prefer_repo: "zzz-app"),
                   "the preference must beat glob order, or the tie is decided alphabetically"
      assert_equal a, CertRootGuard.worktree_hint(SLUG, projects, prefer_repo: "aaa-app")
    end
  end

  def test_unit_worktree_hint_without_a_preference_is_unchanged
    # The cert writers call this positionally for a `cd` hint and must keep their
    # existing behavior: first candidate, nil when there is none.
    with_two_repo_worktrees do |projects, a, _b|
      assert_equal a, CertRootGuard.worktree_hint(SLUG, projects)
      assert_equal a, CertRootGuard.worktree_hint(SLUG, projects, prefer_repo: "no-such-app")
      assert_nil CertRootGuard.worktree_hint("never-created", projects)
    end
  end

  def test_unit_app_of_names_the_repo_for_a_desk_and_for_a_primary
    assert_equal "turf-monster", CertRootGuard.app_of("/p/turf-monster/.worktrees/task-x")
    # A PRIMARY checkout is the other shape the guard is handed. The old
    # unconditional two-level climb returned "p" here — the projects directory, which
    # is nobody's repo — so the directory fallback silently compared garbage.
    assert_equal "turf-monster", CertRootGuard.app_of("/p/turf-monster")
    assert_equal "turf-monster", CertRootGuard.app_of("/p/turf-monster/")
  end

  # ── [unit] the DESTINATION axes ────────────────────────────────────────────

  # A candidate worktree under <app>, on <branch>, optionally with an origin remote.
  def with_candidate(app: "myapp", branch: "feat/#{SLUG}", remote: nil)
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      path = init_repo(File.join(projects, app, ".worktrees", SLUG))
      # init_repo already wired the conventional origin; override it when the case
      # under test is about a DIFFERENT one (a fork, or a renamed local folder).
      git!(path, "remote", "set-url", "origin", remote) if remote
      git!(path, "checkout", "-q", "-b", branch)
      yield projects, path
    end
  end

  def test_unit_a_matching_worktree_has_no_mismatch
    with_candidate do |_projects, path|
      assert_nil CertRootGuard.worktree_mismatch(path, expected_branch: "feat/#{SLUG}", prefer_repo: "myapp")
    end
  end

  def test_unit_the_branch_axis_rejects_a_desk_that_never_carried_the_branch
    # B2 at unit grain.
    with_candidate(branch: "release") do |_projects, path|
      why = CertRootGuard.worktree_mismatch(path, expected_branch: "feat/#{SLUG}", prefer_repo: "myapp")
      assert_includes why.to_s, "release"
      assert_includes why.to_s, "feat/#{SLUG}", "a reason that doesn't name the expectation isn't actionable"
    end
  end

  def test_unit_the_repo_axis_rejects_another_repos_worktree
    # B1 at unit grain — and note the branch is RIGHT here, which is why the branch
    # axis alone cannot catch it.
    with_candidate(app: "otherapp") do |_projects, path|
      why = CertRootGuard.worktree_mismatch(path, expected_branch: "feat/#{SLUG}", prefer_repo: "myapp")
      assert_includes why.to_s, "otherapp"
      assert_includes why.to_s, "myapp"
    end
  end

  def test_unit_origin_rescues_a_repo_whose_directory_name_differs
    # The false-REFUSAL risk the repo axis introduces: a repo cloned into a folder
    # named differently from its GitHub repo is a naming mismatch nobody chose, and
    # refusing it would turn a working review into a dead end. `origin` is the
    # authoritative answer, so it wins over the folder.
    with_candidate(app: "locally-renamed", remote: "https://github.com/McRitchie-Studio/myapp.git") do |_p, path|
      assert_equal "McRitchie-Studio/myapp", CertRootGuard.remote_slug(path)
      assert_nil CertRootGuard.worktree_mismatch(path, expected_branch: "feat/#{SLUG}",
                                                 prefer_repo: "McRitchie-Studio/myapp")
    end
  end

  def test_unit_the_repo_axis_is_owner_aware_so_a_fork_does_not_validate
    # Same repo NAME, someone else's account. `origin` carries the owner, so this is a
    # positive contradiction rather than a match — a bare-name comparison would have
    # accepted a fork's checkout as the tree behind this PR.
    with_candidate(app: "myapp", remote: "https://github.com/someone-else/myapp.git") do |_p, path|
      why = CertRootGuard.repo_mismatch(path, "McRitchie-Studio/myapp")
      assert_includes why.to_s, "someone-else/myapp"
      assert_includes why.to_s, "McRitchie-Studio/myapp"
    end
  end

  def test_unit_remote_slug_parses_https_and_ssh_with_the_owner
    assert_equal "McRitchie-Studio/turf-monster",
                 CertRootGuard.remote_slug_from("git@github.com:McRitchie-Studio/turf-monster.git")
    assert_equal "McRitchie-Studio/mcritchie-studio",
                 CertRootGuard.remote_slug_from("https://github.com/McRitchie-Studio/mcritchie-studio.git")
    assert_equal "McRitchie-Studio/rolio", CertRootGuard.remote_slug_from("https://github.com/McRitchie-Studio/rolio")
    assert_nil CertRootGuard.remote_slug_from("")
  end

  def test_unit_slugs_match_compares_owners_only_when_both_have_one
    # A directory name cannot vouch for an owner. Comparing it AS an owner would
    # either refuse everything or wave forks through, depending which way we guessed.
    assert CertRootGuard.slugs_match?("McRitchie-Studio/myapp", "mcritchie-studio/MYAPP"), "GitHub is case-insensitive"
    refute CertRootGuard.slugs_match?("someone-else/myapp", "McRitchie-Studio/myapp")
    assert CertRootGuard.slugs_match?("myapp", "McRitchie-Studio/myapp"), "bare name falls back to the repo half"
  end

  def test_unit_no_repo_preference_leaves_the_branch_axis_in_charge
    # The builder's pre-PR run has no PR and therefore no repo to compare against.
    # Each axis is enforced when it is DETERMINABLE; an absent one must not become a
    # blanket refusal, or every legitimate pre-PR re-root dies.
    with_candidate(app: "otherapp") do |_projects, path|
      assert_nil CertRootGuard.worktree_mismatch(path, expected_branch: "feat/#{SLUG}", prefer_repo: "")
      refute_nil CertRootGuard.worktree_mismatch(path, expected_branch: "release", prefer_repo: "")
    end
  end

  # ── [integration] THE FALSE PASS ───────────────────────────────────────────

  def test_integration_a_dirty_primary_cannot_pass_a_code_pr_off_as_doc_only_in_review
    # THE MUTATION, reproduced exactly: review lane, run from the primary, PR files
    # unreadable, one unrelated dirty .md on the primary, a multi-file code PR in the
    # task's worktree. Pre-fix this printed "✓ DoR-to-Merge n/a … doc-only diff …
    # → ready to advance" and exited 0.
    with_world do |projects, primary, tree|
      verdict, code, = dor_check(chore_task, primary, projects, "--gate-role", "review")

      assert_saw_the_prs_code(verdict, code)
      # THE PAIRING is the invariant, not the source label: "git working tree" is a
      # perfectly good answer FROM the task's tree, and a lie from anywhere else. The
      # verdict now carries both halves so the pairing can be checked at all.
      assert_equal "git", verdict["diff_source"]
      assert_equal tree, verdict["code_root"],
                   "a working-tree read must be a read of the TASK's working tree"
      refute_equal primary, verdict["code_root"], "grading the checkout you STAND in is the bug itself"
    end
  end

  def test_integration_the_builder_lane_is_held_to_the_same_rule
    # Same world, the other role. The guard was builder-only before this fix and the
    # roles must not drift again: one lane rooted correctly is how the review hole
    # survived a month of green tests.
    with_world do |projects, primary, tree|
      verdict, code, = dor_check(chore_task, primary, projects)

      assert_saw_the_prs_code(verdict, code)
      assert_equal tree, verdict["code_root"]
    end
  end

  def test_integration_the_diff_re_root_is_announced_naming_both_trees
    # A gate that silently judges a different tree than the one you are looking at is
    # how you argue with a verdict instead of reading it (cert_root_guard.rb's own
    # contract). The banner must name where you ARE and where it WENT.
    with_world do |projects, primary, tree|
      _verdict, _code, stderr = dor_check(chore_task, primary, projects, "--gate-role", "review")

      assert_includes stderr, primary, "name the root you were standing in"
      assert_includes stderr, tree, "name the root it moved to"
    end
  end

  # ── [integration] the OTHER direction: it must not over-refuse ─────────────

  def test_integration_a_genuinely_doc_only_pr_still_earns_its_exemption_from_the_primary
    # The mirror-image mutation. Here the PR really is prose and the PRIMARY is dirty
    # with CODE — so a gate reading the wrong tree fails the OTHER way, refusing an
    # honest chore. Re-rooting has to fix the tree, not the answer: the exemption must
    # still be granted, and granted on the TASK's files.
    with_world(files: ["docs/agents/modules/heartbeats.md"], dirt: ["app/services/rogue.rb"]) do |projects, primary, _tree|
      # THE GRANT IS SUBMIT-SIDE, and since /tasks/exempt-path-trusts-local-tree that
      # is the only role that grants it off a local view. A REVIEW-role run whose PR
      # file list could not be read no longer earns the doc-only exemption from ANY
      # local tree, however well re-rooted. That is not new policy — it is what
      # :unreadable has always done on this path (flip `pr_files:` to "unreadable"
      # below against the pre-fix binary and this very assertion failed); :unverified
      # was simply the failed-read state that escaped the rule.
      granted, code, = dor_check(chore_task, primary, projects, "--gate-role", "builder")

      assert_equal 0, code, "a doc-only PR must still pass submit-side: #{granted['errors']}"
      assert granted["ready"]
      assert granted["exempt"]
      assert_equal ["docs/agents/modules/heartbeats.md"], granted["changed_files"]

      # AND THE OVER-REFUSAL GUARD SURVIVES IN BOTH ROLES, which is this test's actual
      # subject. The review-role refusal must be about the UNREAD PR, never about a
      # bad root: a run that re-rooted wrongly would name the primary's rogue file.
      refused, refused_code, = dor_check(chore_task, primary, projects, "--gate-role", "review")

      assert_equal 1, refused_code, "an unread PR is not proof of doc-only for review"
      assert_equal ["docs/agents/modules/heartbeats.md"], refused["changed_files"],
                   "the refusal must still have re-rooted onto the task's own tree"
      [granted, refused].each do |verdict|
        refute_includes Array(verdict["changed_files"]), "app/services/rogue.rb",
                        "the primary's dirty code must not be blamed on this task either"
      end
    end
  end

  def test_integration_a_readable_pr_file_list_still_wins
    # Source priority is unchanged: the PR is the artifact under gate, and reading it
    # is repo-correct from anywhere. The re-rooting is the FALLBACK's cure, not a
    # replacement for it.
    with_world do |projects, primary, _tree|
      verdict, code, = dor_check(chore_task, primary, projects, "--gate-role", "review",
                                 pr_files: "app/jobs/from_the_pr.rb")

      assert_equal "pr", verdict["diff_source"]
      assert_equal ["app/jobs/from_the_pr.rb"], verdict["changed_files"]
      assert_equal 1, code
    end
  end

  # ── [integration] no worktree on disk: the branch, else fail closed ────────

  def test_integration_reads_the_branch_diff_when_the_worktree_is_gone
    # The reclaimed-worktree case. The branch is still in the standing repo, and a
    # committed diff does not care what the checkout is dirty with — so there IS an
    # honest local answer, and refusing here would strand reviewers the way the false
    # STALE did.
    with_world(worktree: false) do |projects, primary, _none|
      git!(primary, "update-ref", "refs/remotes/origin/accepted", "release")
      git!(primary, "checkout", "-q", "-b", "feat/#{SLUG}")
      PR_CODE.each { |rel| write(primary, rel, "# #{rel}\n") }
      git!(primary, "add", *PR_CODE) # NOT -A: the dirt must stay UNCOMMITTED, or the
      git!(primary, "commit", "-qm", "feat") # fixture hides the very file under test
      git!(primary, "checkout", "-q", "release") # back to the wrong-root state
      assert_path_exists File.join(primary, PRIMARY_DIRT), "the dirt must survive as untracked scratch"

      verdict, code, = dor_check(chore_task, primary, projects, "--gate-role", "review")

      assert_saw_the_prs_code(verdict, code)
      assert_equal "branch", verdict["diff_source"],
                   "the committed branch diff is the honest source when no worktree exists"
    end
  end

  def test_integration_fails_closed_when_no_tree_here_can_show_the_diff
    # No worktree, no branch, PR unreadable — and a dirty primary sitting right there
    # offering a convincing doc-only answer. There is no honest verdict available, so
    # the exemption must be REFUSED rather than taken from the nearest tree.
    with_world(worktree: false) do |projects, primary, _none|
      verdict, code, = dor_check(chore_task, primary, projects, "--gate-role", "review")

      assert_equal 1, code
      refute verdict["ready"]
      refute verdict["exempt"], "an unobservable diff is not a doc-only diff"

      blame = verdict["errors"].join(" ")
      assert_includes blame, primary, "name the checkout whose tree was refused"
      assert_includes blame, "feat/#{SLUG}", "and the branch it needed instead"
      refute_includes blame, PRIMARY_DIRT,
                      "the primary's dirt must not even be quoted as evidence — it was never read"
    end
  end

  # ── [integration] the foreign tree is off limits to CONTENT readers too ────

  def test_integration_the_gem_guard_never_reads_a_foreign_checkouts_gemfile
    # The same wrong-tree mistake, one gate over, failing the other way — a false
    # BLOCK instead of a false pass. The gem-publish guard READS Gemfile +
    # Gemfile.lock CONTENT from the root, so from a foreign checkout it compares two
    # unrelated trees: a reviewer who happens to be mid `bundle update` on their
    # primary would see their own half-finished bump reported as THIS task's blocker.
    # The diff here comes from the PR (repo-correct), so nothing but the trust rule
    # keeps the guard away from the local pair.
    with_world(worktree: false, dirt: []) do |projects, primary, _none|
      write(primary, "Gemfile", %(source "https://rubygems.org"\ngem "studio-engine", "0.99.0"\n))
      write(primary, "Gemfile.lock", "GEM\n  remote: https://rubygems.org/\n  specs:\n    studio-engine (0.32.1)\n")
      git!(primary, "add", "Gemfile", "Gemfile.lock")
      git!(primary, "commit", "-qm", "lockfile")
      write(primary, "Gemfile", %(source "https://rubygems.org"\ngem "studio-engine", "1.99.0"\n)) # dirty bump

      verdict, code, = dor_check(chore_task, primary, projects, "--gate-role", "review",
                                 pr_files: "app/services/widget.rb")

      assert_equal 1, code, "the code PR is still gated for a shape — that part is unchanged"
      blame = verdict["errors"].join(" ")
      assert_match(/ships a code diff/, blame)
      refute_match(/Gemfile\.lock pins/, blame,
                   "the reviewer's own mid-bump Gemfile is not this task's blocker")
    end
  end

  # ── [integration] multi-repo: disambiguate, or refuse to guess ─────────────

  # Two repos, one slug, one PR. The task's worktree exists under BOTH — the normal
  # shape of a multi-repo task — and only the PR says which one this verdict is about.
  def with_multi_repo_world
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      primary = init_repo(File.join(projects, "hub"))
      git!(primary, "checkout", "-q", "-b", "release")
      write(primary, PRIMARY_DIRT, "unrelated local scratch\n")

      # Sorts FIRST, and ships only prose — the tree a blind pick would grab, and the
      # one that would hand the code PR a doc-only exemption all over again.
      docs_side = build_task_tree(File.join(projects, "aaa-app", ".worktrees", SLUG),
                                  files: ["docs/agents/notes.md"])
      # Sorts LAST, and is the repo the PR actually lives in.
      code_side = build_task_tree(File.join(projects, "zzz-app", ".worktrees", SLUG), files: PR_CODE)
      yield projects, primary, docs_side, code_side
    end
  end

  def test_integration_multi_repo_resolves_the_repo_the_pr_names
    with_multi_repo_world do |projects, primary, docs_side, code_side|
      verdict, code, = dor_check(chore_task(repo: "zzz-app"), primary, projects, "--gate-role", "review")

      assert_saw_the_prs_code(verdict, code)
      assert_equal code_side, verdict["code_root"], "devops.pr_url names the repo under gate"
      refute_equal docs_side, verdict["code_root"],
                   "the alphabetically-first worktree is a coin flip, not an answer"
    end
  end

  def test_integration_multi_repo_refuses_to_guess_when_the_pr_names_no_worktree
    # A blank/foreign pr_url leaves nothing to break the tie. Picking the first
    # candidate would re-create the wrong-tree bug one repo over — and here it would
    # land on the docs-only tree and pass the code PR. Refuse instead.
    with_multi_repo_world do |projects, primary, _docs_side, _code_side|
      verdict, code, stderr = dor_check(chore_task(pr: false), primary, projects, "--gate-role", "review")

      assert_equal 1, code
      refute verdict["ready"]
      refute verdict["exempt"], "an unresolved multi-repo task must not collect a doc-only exemption"
      assert_includes stderr, "AMBIGUOUS", "the refusal to guess must be announced"
      assert_includes stderr, "aaa-app", "naming every candidate is what makes the refusal actionable"
      assert_includes stderr, "zzz-app"
    end
  end

  # ── [integration] the DESTINATION is validated too, on BOTH axes ──────────
  #
  # Found in review of this very fix (2026-08-09). The first cut asked two questions
  # of the checkout you were STANDING in (`CertRootGuard.assess`: is its branch the
  # task's? is it the task's worktree dir?) and ZERO questions of the checkout it
  # JUMPED TO — while announcing "Re-rooted at the task's worktree: <path>" as fact.
  # A destination was trusted for having the right DIRECTORY NAME.
  #
  # That reopened the same false pass one hop downstream, twice and independently:
  # B1 has the right branch in the wrong repo, B2 the right repo on the wrong branch.
  # Either alone is enough, so validating "either axis" is not a fix — the
  # destination must satisfy BOTH.

  def test_integration_refuses_a_lone_worktree_that_belongs_to_another_repo
    # B1. The multi-repo repo check was gated behind `candidates.size > 1`, so a
    # SINGLE candidate was trusted without ever being asked which repo it was in.
    # The PR is in myapp; the only worktree on disk is otherapp's, on the right
    # branch, carrying prose — so the gate re-rooted into a different product's
    # checkout and handed the exemption out on ITS files.
    #
    # This one is doubly damning: the refusal was already PROMISED, by the
    # AMBIGUOUS banner and by docs/agents/modules/gates/dor.md, for exactly this
    # input. The documentation was more protective than the code.
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      primary = init_repo(File.join(projects, "myapp"))
      git!(primary, "checkout", "-q", "-b", "release")
      write(primary, PRIMARY_DIRT, "unrelated local scratch\n")
      # Right slug, right branch — wrong PRODUCT.
      foreign = build_task_tree(File.join(projects, "otherapp", ".worktrees", SLUG),
                                files: ["docs/notes.md"])

      verdict, code, stderr = dor_check(chore_task(repo: "myapp"), primary, projects,
                                        "--gate-role", "review")

      refute verdict["exempt"], "B1: a worktree in another repo must not earn this PR's exemption"
      assert_equal 1, code
      refute_equal foreign, verdict["code_root"], "it must not re-root into another repo's checkout"
      refute_includes stderr, "Re-rooted at the task's worktree",
                      "announcing a re-root it must not perform is how the bug reads as correct"
    end
  end

  def test_integration_refuses_a_stale_desk_that_never_carried_the_branch
    # B2. Candidates were globbed by DIRECTORY NAME only. A leftover desk at
    # myapp/.worktrees/task-x — right repo, right path, but sitting on `release` and
    # never having carried feat/task-x — passed as "the task's worktree", and its one
    # untracked file was read as the PR's entire diff.
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      primary = init_repo(File.join(projects, "myapp"))
      git!(primary, "checkout", "-q", "-b", "release")
      write(primary, PRIMARY_DIRT, "unrelated local scratch\n")
      # Right repo, right directory name — never carried the task's branch.
      stale = init_repo(File.join(projects, "myapp", ".worktrees", SLUG))
      git!(stale, "checkout", "-q", "-b", "release")
      write(stale, "docs/leftover.md", "someone else's abandoned scratch\n")

      verdict, code, stderr = dor_check(chore_task(repo: "myapp"), primary, projects,
                                        "--gate-role", "review")

      refute verdict["exempt"], "B2: a desk that never carried the branch is not the task's tree"
      assert_equal 1, code
      refute_includes Array(verdict["changed_files"]), "docs/leftover.md",
                      "a stale desk's leftovers are not this PR's diff"
      refute_includes stderr, "Re-rooted at the task's worktree"
    end
  end

  def test_integration_the_refusal_names_which_axis_the_destination_failed
    # A refusal you cannot act on gets worked around. Both axes must say which one
    # broke and what was expected, or the reader's only move is to re-run.
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      primary = init_repo(File.join(projects, "myapp"))
      git!(primary, "checkout", "-q", "-b", "release")
      stale = init_repo(File.join(projects, "myapp", ".worktrees", SLUG))
      git!(stale, "checkout", "-q", "-b", "release")

      verdict, _code, stderr = dor_check(chore_task(repo: "myapp"), primary, projects,
                                         "--gate-role", "review")

      blame = "#{verdict['errors'].join(' ')} #{stderr}"
      assert_includes blame, stale, "name the candidate it rejected"
      assert_includes blame, "feat/#{SLUG}", "and the branch that would have made it the task's tree"
    end
  end

  # ── [integration] the tree you STAND in is validated too ──────────────────
  #
  # Round 4, and the mirror of the round-3 finding: having fixed the tree the gate
  # JUMPS TO, it still trusted the tree it STANDS IN. `assess` short-circuited on a
  # branch-only check (the repo axis was never asked of the standing root) backed by a
  # pure STRING match on `.worktrees/<slug>` — so these three walked straight through
  # with `exempt: true`, exit 0, and no stderr banner at all.
  #
  # No banner is the tell. Every other wrong-tree path at least announces itself; this
  # one produced a verdict that looked completely ordinary.

  # Stand INSIDE `desk` (a checkout named like the task's worktree) and gate a chore
  # whose PR is a multi-file code change in `repo`.
  def standing_in_desk_verdict(desk_branch: nil, detach: false, desk_repo: "myapp", pr_repo: "myapp")
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      desk = init_repo(File.join(projects, desk_repo, ".worktrees", SLUG))
      git!(desk, "checkout", "-q", "-b", desk_branch) if desk_branch
      if detach
        git!(desk, "checkout", "-q", "-b", "feat/#{SLUG}")
        write(desk, "app/services/real.rb", "# real work\n")
        git!(desk, "add", "-A")
        git!(desk, "commit", "-qm", "feat")
        git!(desk, "checkout", "-q", "--detach", "HEAD~1") # mid-rebase-looking state
      end
      # The desk's only visible change is PROSE — the bait. Read from here, it earns
      # the doc-only exemption; it is not what the PR ships.
      write(desk, "docs/desk-scratch.md", "scratch\n")
      yield projects, desk if block_given?
      dor_check(chore_task(repo: pr_repo), desk, projects, "--gate-role", "review")
    end
  end

  def test_integration_standing_in_a_stale_desk_is_not_standing_in_the_task_tree
    # Vector 1: the desk is named right and sits in the right repo, but is on
    # `release` and never carried the task's branch.
    verdict, code, stderr = standing_in_desk_verdict(desk_branch: "release")

    refute verdict["exempt"], "a stale desk's scratch file must not earn this PR's exemption"
    assert_equal 1, code
    refute_empty stderr, "silence is the tell — this path used to emit no banner at all"
    assert_includes stderr, "feat/#{SLUG}", "name the branch that would have made it the task's tree"
  end

  def test_integration_a_detached_head_in_the_right_desk_is_not_the_prs_state
    # Vector 2: physically the task's desk, but HEAD is detached — mid-rebase, or
    # parked on an older commit. Whatever the working tree shows, it is not the state
    # the PR would merge, and the `worktree_dir?` string match vouched for it anyway.
    verdict, code, stderr = standing_in_desk_verdict(detach: true)

    refute verdict["exempt"], "a detached HEAD is not the PR's state"
    assert_equal 1, code
    refute_empty stderr
  end

  def test_integration_standing_in_another_repos_desk_grades_the_prs_repo
    # Vector 3, and this shape is live on disk today — `repair-moms-app-ci` has desks
    # under BOTH moms-app and studio-engine. Standing in the wrong one, on the right
    # branch, the repo axis was never asked: the gate silently graded the wrong repo.
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      # Where the PR actually lives, carrying real code.
      right = build_task_tree(File.join(projects, "moms-app", ".worktrees", SLUG), files: PR_CODE)
      # The desk the operator happens to be standing in — same slug, same branch,
      # different product, and nothing but prose to show.
      wrong = build_task_tree(File.join(projects, "studio-engine", ".worktrees", SLUG),
                              files: ["docs/engine-note.md"])

      verdict, code, = dor_check(chore_task(repo: "moms-app"), wrong, projects, "--gate-role", "review")

      refute verdict["exempt"], "the wrong repo's desk must not earn this PR's exemption"
      assert_equal 1, code
      refute_equal wrong, verdict["code_root"], "it silently graded the wrong repo"
      assert_equal right, verdict["code_root"], "devops.pr_url says which repo this verdict is about"
    end
  end

  # ── [integration] the tree it READS is validated too ──────────────────────
  #
  # Round 5, the same family one door out: the gate validated the tree it STANDS in
  # and the tree it JUMPS to, then read a BRANCH out of a checkout it had already
  # declared foreign. Branch names are not repo-scoped, so any repo that merely HAS a
  # `feat/<slug>` was graded as this PR's diff — 21 real hub↔satellite collisions
  # exist on disk today.

  # The reviewer's world: a satellite carries the real code PR; the hub the reviewer
  # stands in has a same-named branch that only touches prose.
  def with_branch_name_collision
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      hub = init_repo(File.join(projects, "mcritchie-studio"))
      git!(hub, "update-ref", "refs/remotes/origin/accepted", "HEAD")
      git!(hub, "checkout", "-q", "-b", "feat/#{SLUG}")
      write(hub, "docs/hub-note.md", "unrelated work that happens to share a branch name\n")
      git!(hub, "add", "-A")
      git!(hub, "commit", "-qm", "hub prose")
      git!(hub, "update-ref", "refs/remotes/origin/feat/#{SLUG}", "feat/#{SLUG}")
      git!(hub, "checkout", "-q", "master") if git_branch_exists?(hub, "master")
      git!(hub, "checkout", "-q", "-B", "release", "origin/accepted")
      yield projects, hub
    end
  end

  def git_branch_exists?(dir, branch)
    system("git", "-C", dir, "rev-parse", "--verify", branch, out: File::NULL, err: File::NULL)
  end

  def test_integration_a_same_named_branch_in_another_repo_is_not_this_prs_diff
    # The satellite's worktree is NOT on disk, so the branch fallback is the only
    # local source left — and the hub happens to carry `feat/<slug>`. Pre-fix that
    # branch's doc-only diff earned the exemption for a satellite CODE PR.
    with_branch_name_collision do |projects, hub|
      verdict, code, = dor_check(chore_task(repo: "turf-monster"), hub, projects, "--gate-role", "review")

      refute verdict["exempt"], "another repo's same-named branch is not this PR's diff"
      assert_equal 1, code
      refute_includes Array(verdict["changed_files"]), "docs/hub-note.md"
      refute_equal "branch", verdict["diff_source"], "the branch source must not fire outside the PR's repo"

      # The REMEDY has to match the diagnosis. `git fetch origin feat/<slug>` is
      # useless here — the branch is already present, it just belongs to another
      # project — and a refusal whose fix cannot work teaches the reader to route
      # around it. The two refusals that say this share one source so they cannot
      # drift apart again.
      blame = verdict["errors"].join(" ")
      refute_includes blame, "git fetch origin", "fetching cannot fix standing in the wrong repo"
      assert_includes blame, "not the PR's repo"
    end
  end

  def test_integration_the_refusal_and_the_verdict_cannot_disagree
    # THE WORST FORM, and the one to fix against: with the hub's OWN desk on disk the
    # gate printed "TASK TREE NOT FOUND … working tree is NOT read as the diff" and
    # then read that same repo's BRANCH and passed anyway. A gate whose refusal fires
    # while its verdict advances is worse than one that simply misses — the banner
    # becomes evidence that it was checked.
    with_branch_name_collision do |projects, hub|
      stale = init_repo(File.join(projects, "mcritchie-studio", ".worktrees", SLUG))
      git!(stale, "checkout", "-q", "-b", "release")

      verdict, code, stderr = dor_check(chore_task(repo: "turf-monster"), hub, projects,
                                        "--gate-role", "review")

      assert_includes stderr, "NOT read as the diff", "the refusal must actually fire in this fixture"
      refute verdict["exempt"], "the gate refused on stderr and then granted the exemption anyway"
      refute verdict["ready"], "a banner the verdict contradicts is worse than no banner"
      assert_equal 1, code
    end
  end

  # A SHAPED code task, so the suite gate actually runs — the exempt-kind fixtures
  # above short-circuit before it and cannot see the cert fingerprint at all.
  def backend_task(repo:, fp:)
    task = chore_task(repo: repo)
    task["metadata"]["devops"].merge!(
      "kind" => "bug", "shape" => "backend",
      "checks_run" => ["[unit] u", "[integration] i",
                       "[full-suite@#{fp}] bin/rails test", "[rubocop@#{fp}] bin/rubocop"]
    )
    task
  end

  def test_integration_a_foreign_repos_branch_tree_is_never_offered_as_this_certs_fingerprint
    # The fingerprint twin of the branch-diff vector. Reading a same-named branch out
    # of the WRONG repo produces a precise, confident, wrong hash — and this file's own
    # provenance invariant says that is worse than an opaque refusal, because it sends
    # the reader to a tree that graded nothing. The wrong direction is survivable here
    # (a false STALE is loud); being confidently wrong about WHICH tree is not.
    with_branch_name_collision do |projects, hub|
      hub_branch_tree = IO.popen(["git", "-C", hub, "rev-parse", "feat/#{SLUG}^{tree}"], &:read).strip
      refute_empty hub_branch_tree

      verdict, code, = dor_check(backend_task(repo: "turf-monster", fp: "a" * 40), hub, projects,
                                 "--gate-role", "review")

      assert_equal 1, code
      blame = "#{verdict['errors'].join(' ')} #{verdict.dig('full_suite', 'fingerprint')}"
      refute_includes blame, hub_branch_tree[0, 12],
                      "the hub's branch tree graded nothing and must not appear as this task's fingerprint"
      assert_match(/root guard/i, verdict["errors"].join(" "),
                   "with no honest tree available it must refuse, not grade a foreign one")
    end
  end

  def test_integration_the_branch_source_still_works_inside_the_prs_own_repo
    # The other direction: remedy 2 must keep working where it is honest. Right repo,
    # wrong branch checked out, worktree reclaimed — the branch's committed diff is
    # exactly the PR's, and refusing here would strand reviewers.
    with_world(worktree: false) do |projects, primary, _none|
      git!(primary, "update-ref", "refs/remotes/origin/accepted", "release")
      git!(primary, "checkout", "-q", "-b", "feat/#{SLUG}")
      PR_CODE.each { |rel| write(primary, rel, "# #{rel}\n") }
      git!(primary, "add", *PR_CODE)
      git!(primary, "commit", "-qm", "feat")
      git!(primary, "checkout", "-q", "release")

      verdict, code, = dor_check(chore_task(repo: "myapp"), primary, projects, "--gate-role", "review")

      assert_saw_the_prs_code(verdict, code)
      assert_equal "branch", verdict["diff_source"], "the PR's own repo may still answer with its branch"
    end
  end

  # ── [unit] the writer/reader split on the physical desk ───────────────────

  def test_unit_the_physical_desk_vouches_for_a_WRITER_but_is_only_a_fact_to_the_READER
    # These two must never be "simplified" into agreement. A cert stamped from a
    # detached desk is content-addressed, so it can only later read STALE — loud and
    # self-correcting. A DIFF read from the same desk is graded as though it were the
    # PR, and passes silently. Same fact, opposite correct answers.
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      desk = init_repo(File.join(projects, "myapp", ".worktrees", SLUG))
      git!(desk, "checkout", "-q", "--detach", "HEAD")
      stub = File.join(projects, "task-stub")
      File.write(stub, "#!/bin/sh\necho '{}'\n")
      FileUtils.chmod(0o755, stub)

      assert_nil CertRootGuard.refusal(task_bin: stub, slug: SLUG, root: desk),
                 "the WRITER still certifies from the task's own desk"

      found = CertRootGuard.assess(task_bin: stub, slug: SLUG, root: desk)
      refute_nil found, "the READER must still receive the assessment, not a silent nil"
      assert found[:standing_in_task_desk], "reported as a FACT the reader can decline"
      assert_includes found[:standing_mismatch].to_s, "feat/#{SLUG}"
    end
  end

  # ── [unit] the cd hint the cert writers die! with ─────────────────────────

  def test_unit_the_cd_hint_respects_the_repo_preference
    # bin/ship, bin/fast-check and bin/full-suite-check all die! with this text, so a
    # hint that ignores prefer_repo is wrong in four places at once — and it is advice
    # someone FOLLOWS, straight to another repo's desk.
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      # Both are genuinely the task's tree on the branch axis; only the repo axis
      # separates them, which is exactly what the hint was dropping.
      a = build_task_tree(File.join(projects, "aaa-app", ".worktrees", SLUG), files: ["docs/a.md"])
      b = build_task_tree(File.join(projects, "zzz-app", ".worktrees", SLUG), files: ["docs/b.md"])

      message = CertRootGuard.refusal_message(SLUG, "/somewhere/else", "release", "feat/#{SLUG}", SLUG,
                                              projects, prefer_repo: "zzz-app")
      assert_includes message, b, "the hint must point at the repo under gate"
      refute_includes message, a, "alphabetical order is not an answer to which repo"
    end
  end

  # ── [integration] the pairing is checkable on the path that matters ────────

  def test_integration_exempt_payloads_carry_the_root_they_were_read_from
    # dor.md calls (code_root, diff_source) "the checkable invariant", but the
    # exempt-kind payloads omitted code_root — so the one verdict shape the 08-08
    # false pass actually took was the one a monitor could not check. Both exempt
    # payloads (the pass and the fail-closed) must carry it.
    with_world(files: ["docs/agents/modules/heartbeats.md"], dirt: []) do |projects, primary, tree|
      # Submit-side, because the PASS is the shape under test and a review-role run
      # with an unread PR file list no longer produces one
      # (/tasks/exempt-path-trusts-local-tree). The fail-closed half below stays in
      # the review role, where it always refused.
      passing, code, = dor_check(chore_task, primary, projects, "--gate-role", "builder")
      assert_equal 0, code
      assert passing["exempt"]
      assert_equal tree, passing["code_root"], "the doc-only PASS must name the tree it read"
      assert_equal "git", passing["diff_source"]
    end

    with_world(worktree: false, dirt: []) do |projects, primary, _none|
      closed, code, = dor_check(chore_task, primary, projects, "--gate-role", "review")
      assert_equal 1, code
      assert_equal "indeterminate", closed["diff_source"]
      assert_equal primary, closed["code_root"], "the fail-closed payload must name where it stood"
    end
  end

  # ── [integration] the rung ladder is per-repo ──────────────────────────────

  def test_integration_a_repo_with_no_accepted_rung_still_resolves_its_own_base
    # moms-app-style: no `accepted` branch, only `main`. The resolver must fall
    # through the ladder in the TASK's repo instead of assuming the hub's rungs —
    # otherwise the committed diff comes back empty and the gate quietly reverts to
    # "nothing observed" on a repo that simply sits on a different rung.
    with_world(base_rung: "main") do |projects, primary, tree|
      verdict, code, = dor_check(chore_task, primary, projects, "--gate-role", "review")

      assert_saw_the_prs_code(verdict, code)
      assert_equal tree, verdict["code_root"]
    end
  end
end
