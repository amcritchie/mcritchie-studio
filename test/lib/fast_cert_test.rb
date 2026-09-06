# frozen_string_literal: true

# [unit] tests for bin/lib/fast_cert.rb — the PURE selection half of the G1 fast
# cert (bin/fast-check): diff → test-file mapping (path convention + class-name
# grep fallback), the always-run spine, and the changed-files rubocop scope.
# No processes are spawned here except git fixture setup; the ORCHESTRATION
# (lanes, gate emits, evidence) is covered by test/lib/fast_check_test.rb.
# Run directly:
#   ruby -Itest test/lib/fast_cert_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/fast_cert"

class FastCertTest < Minitest::Test
  # --- convention mapping ------------------------------------------------------

  def test_model_maps_to_model_test
    assert_equal ["test/models/task_test.rb"], FastCert.convention_candidates("app/models/task.rb")
  end

  def test_nested_controller_maps_with_namespace
    assert_equal ["test/controllers/api/v1/tasks_controller_test.rb"],
                 FastCert.convention_candidates("app/controllers/api/v1/tasks_controller.rb")
  end

  def test_helper_job_service_map_through_their_layers
    assert_equal ["test/helpers/application_helper_test.rb"],
                 FastCert.convention_candidates("app/helpers/application_helper.rb")
    assert_equal ["test/jobs/avi_sizing_job_test.rb"],
                 FastCert.convention_candidates("app/jobs/avi_sizing_job.rb")
    assert_equal ["test/services/avi_sizer_test.rb"],
                 FastCert.convention_candidates("app/services/avi_sizer.rb")
  end

  def test_view_partial_maps_to_controller_and_mailer_tests
    assert_equal ["test/controllers/tasks_controller_test.rb", "test/mailers/tasks_test.rb"],
                 FastCert.convention_candidates("app/views/tasks/_gates.html.erb")
  end

  def test_namespaced_view_maps_to_namespaced_controller_test
    assert_includes FastCert.convention_candidates("app/views/api/v1/tasks/show.json.jbuilder"),
                    "test/controllers/api/v1/tasks_controller_test.rb"
  end

  def test_lib_and_bin_lib_map_to_test_lib
    assert_equal ["test/lib/feature_marker_test.rb"], FastCert.convention_candidates("lib/feature_marker.rb")
    assert_equal ["test/lib/fast_cert_test.rb"], FastCert.convention_candidates("bin/lib/fast_cert.rb")
  end

  def test_bin_script_maps_to_underscored_harness_test
    assert_equal ["test/lib/fast_check_test.rb"], FastCert.convention_candidates("bin/fast-check")
  end

  def test_changed_test_file_maps_to_itself
    assert_equal ["test/models/task_test.rb"], FastCert.convention_candidates("test/models/task_test.rb")
  end

  def test_unmappable_paths_yield_no_candidates
    assert_empty FastCert.convention_candidates("docs/agents/sop.md")
    assert_empty FastCert.convention_candidates("README.md")
    assert_empty FastCert.convention_candidates("db/migrate/20260708_add_widgets.rb")
    assert_empty FastCert.convention_candidates("app/assets/stylesheets/app.css")
  end

  # --- grep fallback tokens ----------------------------------------------------

  def test_grep_token_camelizes_ruby_basenames
    assert_equal "GateRun", FastCert.grep_token("app/models/gate_run.rb")
    assert_equal "FullSuiteGate", FastCert.grep_token("bin/lib/full_suite_gate.rb")
  end

  def test_grep_token_uses_the_script_name_for_bin_tools
    assert_equal "fast-check", FastCert.grep_token("bin/fast-check")
  end

  def test_grep_token_uses_the_basename_for_config_yml
    assert_equal "fast_cert_spine", FastCert.grep_token("config/fast_cert_spine.yml")
  end

  def test_grep_token_is_nil_for_views_and_docs
    assert_nil FastCert.grep_token("app/views/tasks/_gates.html.erb")
    assert_nil FastCert.grep_token("docs/agents/sop.md")
  end

  # --- grep fallback + select_tests over a fixture tree -------------------------

  # A repo-shaped fixture directory (files only; git added where needed).
  def with_tree(files)
    Dir.mktmpdir do |dir|
      files.each do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      yield dir
    end
  end

  def test_grep_finds_word_bounded_class_mentions_only
    with_tree(
      "test/lib/widget_flow_test.rb" => "class WidgetFlowTest\n  Widget.create!\nend\n",
      "test/lib/other_test.rb" => "class OtherTest\n  WidgetRegistry.reset\nend\n"
    ) do |dir|
      # "Widget" matches the whole word, NOT the "WidgetRegistry" substring.
      assert_equal ["test/lib/widget_flow_test.rb"], FastCert.grep_tests(dir, "Widget")
      assert_empty FastCert.grep_tests(dir, "Gadget")
      assert_empty FastCert.grep_tests(dir, nil)
    end
  end

  def test_select_prefers_an_existing_convention_target_over_grep
    with_tree(
      "app/models/widget.rb" => "class Widget; end\n",
      "test/models/widget_test.rb" => "class WidgetTest; end\n",
      "test/lib/mentions_widget_test.rb" => "Widget everywhere\n"
    ) do |dir|
      # The convention target exists → grep is NOT consulted (no mentions file).
      assert_equal ["test/models/widget_test.rb"],
                   FastCert.select_tests(dir, ["app/models/widget.rb"])
    end
  end

  def test_select_falls_back_to_grep_when_no_convention_target_exists
    with_tree(
      "app/services/charger.rb" => "class Charger; end\n",
      "test/integration/billing_flow_test.rb" => "Charger.charge!\n"
    ) do |dir|
      assert_equal ["test/integration/billing_flow_test.rb"],
                   FastCert.select_tests(dir, ["app/services/charger.rb"])
    end
  end

  def test_select_dedupes_and_sorts_across_changed_files
    with_tree(
      "test/models/widget_test.rb" => "class WidgetTest; end\n",
      "app/models/widget.rb" => "class Widget; end\n"
    ) do |dir|
      changed = ["app/models/widget.rb", "test/models/widget_test.rb", "docs/notes.md"]
      assert_equal ["test/models/widget_test.rb"], FastCert.select_tests(dir, changed)
    end
  end

  # --- spine ---------------------------------------------------------------------

  def test_spine_loads_existing_entries_and_skips_missing_ones
    with_tree(
      "test/models/task_test.rb" => "x\n",
      "test/controllers/api/v1/tasks_controller_test.rb" => "x\n",
      "spine.yml" => "spine:\n  - test/models/task_test.rb\n  - test/controllers/api/v1\n  - test/models/missing_test.rb\n"
    ) do |dir|
      assert_equal ["test/models/task_test.rb", "test/controllers/api/v1"],
                   FastCert.spine(dir, File.join(dir, "spine.yml"))
    end
  end

  def test_spine_is_empty_for_a_missing_or_blank_config
    Dir.mktmpdir do |dir|
      assert_empty FastCert.spine(dir, File.join(dir, "nope.yml"))
      File.write(File.join(dir, "empty.yml"), "")
      assert_empty FastCert.spine(dir, File.join(dir, "empty.yml"))
    end
  end

  def test_covered_by_spine_matches_exact_files_and_directory_members
    spine = ["test/models/task_test.rb", "test/controllers/api/v1"]
    assert FastCert.covered_by_spine?("test/models/task_test.rb", spine)
    assert FastCert.covered_by_spine?("test/controllers/api/v1/tasks_controller_test.rb", spine)
    refute FastCert.covered_by_spine?("test/models/release_test.rb", spine)
    # A sibling that merely SHARES the directory prefix string is NOT covered.
    refute FastCert.covered_by_spine?("test/controllers/api/v1_legacy_test.rb", spine)
  end

  # --- rubocop scope ---------------------------------------------------------------

  def test_lintable_files_keeps_ruby_and_ruby_shebang_bin_scripts_only
    with_tree(
      "app/models/widget.rb" => "class Widget; end\n",
      "Gemfile" => "source 'https://rubygems.org'\n",
      "bin/ruby-tool" => "#!/usr/bin/env ruby\nputs 1\n",
      "bin/shell-tool" => "#!/bin/sh\necho hi\n",
      "docs/notes.md" => "notes\n",
      "app/views/tasks/_gates.html.erb" => "<div></div>\n"
    ) do |dir|
      changed = ["app/models/widget.rb", "Gemfile", "bin/ruby-tool", "bin/shell-tool",
                 "docs/notes.md", "app/views/tasks/_gates.html.erb", "app/models/deleted.rb"]
      assert_equal ["app/models/widget.rb", "Gemfile", "bin/ruby-tool"],
                   FastCert.lintable_files(dir, changed)
    end
  end

  # --- changed-file collection over a real git repo --------------------------------

  def with_git_repo
    Dir.mktmpdir do |dir|
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("commit -q --allow-empty -m init")
      yield dir, git
    end
  end

  def test_changed_files_unions_staged_unstaged_untracked_and_committed
    with_git_repo do |dir, git|
      write = lambda do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      base_sha = `git -C #{dir} rev-parse HEAD`.strip

      write.call("app/models/committed.rb", "x\n")
      git.call("add -A")
      git.call("commit -q -m committed")
      write.call("app/models/staged.rb", "x\n")
      git.call("add app/models/staged.rb")
      write.call("app/models/untracked.rb", "x\n")

      files = FastCert.changed_files(dir, base_sha)
      assert_includes files, "app/models/committed.rb"
      assert_includes files, "app/models/staged.rb"
      assert_includes files, "app/models/untracked.rb"
    end
  end

  def test_default_diff_base_prefers_origin_release
    with_git_repo do |dir, git|
      assert_equal "origin/main", FastCert.default_diff_base(dir)
      sha = `git -C #{dir} rev-parse HEAD`.strip
      git.call("update-ref refs/remotes/origin/release #{sha}")
      assert_equal "origin/release", FastCert.default_diff_base(dir)
    end
  end

  # origin/accepted (the v2 integration branch feature PRs target) is preferred
  # over origin/release when present — the base-flip regression.
  def test_default_diff_base_prefers_origin_accepted_over_release
    with_git_repo do |dir, git|
      sha = `git -C #{dir} rev-parse HEAD`.strip
      git.call("update-ref refs/remotes/origin/release #{sha}")
      assert_equal "origin/release", FastCert.default_diff_base(dir)
      git.call("update-ref refs/remotes/origin/accepted #{sha}")
      assert_equal "origin/accepted", FastCert.default_diff_base(dir)
    end
  end

  # --- the mapped cap -----------------------------------------------------------
  #
  # WHY THERE IS A CAP AT ALL. There was none, and a fast lane that can silently
  # become a full suite is worse than a slow one: the builder cannot tell which
  # they are in. Observed live 2026-08-15 — a diff touching
  # config/initializers/studio.rb mapped to 45 test files and bin/fast-check was
  # still running at 39m34s against a lane g1-cert.md budgets at ~1 minute, which
  # bin/ship runs by default.

  def test_mapping_reports_what_each_changed_file_maps_to
    with_tree(
      "test/models/widget_test.rb" => "class WidgetTest; end\n",
      "test/lib/other_test.rb" => "class OtherTest; end\n"
    ) do |dir|
      result = FastCert.mapping(dir, ["app/models/widget.rb", "app/models/ghost.rb"])

      assert_equal ["test/models/widget_test.rb"], result["app/models/widget.rb"]
      assert_empty result["app/models/ghost.rb"], "a path that maps nowhere still gets an entry"
    end
  end

  # select_tests IS the union of mapping, and must stay so — the cap reads the
  # per-file breakdown to name a culprit, and it can only be trusted if the two
  # come from the same pass.
  def test_select_tests_is_the_union_of_the_mapping
    with_tree(
      "test/models/widget_test.rb" => "class WidgetTest; end\n",
      "test/models/gadget_test.rb" => "class GadgetTest; end\n"
    ) do |dir|
      changed = ["app/models/widget.rb", "app/models/gadget.rb"]

      assert_equal FastCert.mapping(dir, changed).values.flatten.uniq.sort,
                   FastCert.select_tests(dir, changed)
    end
  end

  def test_the_cap_defaults_low_and_reads_the_env
    assert_equal 15, FastCert::DEFAULT_MAPPED_CAP

    with_env("FAST_CHECK_MAPPED_CAP" => "3") { assert_equal 3, FastCert.mapped_cap }
  end

  # A MALFORMED OVERRIDE MUST NOT DISABLE THE CAP. "0", "" and "banana" all mean
  # "I did not say anything usable" — and `to_i` turns every one of them into 0,
  # which as a cap would skip the mapped lane on EVERY diff. That is a silent
  # cert-shaped hole, which is the exact disease this task exists to close.
  def test_a_useless_cap_override_falls_back_to_the_default
    ["0", "", "   ", "banana", "-4"].each do |raw|
      with_env("FAST_CHECK_MAPPED_CAP" => raw) do
        assert_equal FastCert::DEFAULT_MAPPED_CAP, FastCert.mapped_cap,
                     "#{raw.inspect} disabled the cap instead of falling back"
      end
    end
  end

  def test_a_narrow_diff_is_not_capped
    decision = FastCert.cap_decision(["test/models/widget_test.rb"],
                                     { "app/models/widget.rb" => ["test/models/widget_test.rb"] })

    refute decision[:capped]
    assert_equal 1, decision[:count]
  end

  # THE CULPRIT IS NAMED, not just the total. "48 files, too many" sends the
  # builder through their whole diff; "this one file mapped 44" names the cause,
  # and the cause is almost always one file whose grep token is too generic.
  def test_a_capped_decision_names_the_widest_mapping
    breakdown = {
      "app/models/widget.rb" => ["test/models/widget_test.rb"],
      "config/initializers/studio.rb" => (1..40).map { |i| "test/lib/t#{i}_test.rb" }
    }
    decision = FastCert.cap_decision(breakdown.values.flatten.uniq.sort, breakdown)

    assert decision[:capped]
    assert_equal 15, decision[:cap]
    assert_equal 41, decision[:count]
    assert_equal "config/initializers/studio.rb", decision[:worst_path]
    assert_equal 40, decision[:worst_count]
  end

  # THE CAP IS ABOUT EXTRA WORK, so it reads the set AFTER the spine dedupe. A
  # mapped test the spine already runs costs this lane nothing, and capping the
  # raw union would refuse diffs whose mapping is entirely redundant — punishing
  # exactly the diffs the spine already covers well.
  def test_the_cap_counts_what_it_is_given_not_the_raw_union
    breakdown = { "config/initializers/studio.rb" => (1..40).map { |i| "test/lib/t#{i}_test.rb" } }
    after_spine_dedupe = ["test/lib/t1_test.rb", "test/lib/t2_test.rb"]

    decision = FastCert.cap_decision(after_spine_dedupe, breakdown)

    refute decision[:capped],
           "the cap tripped on the raw mapping — 38 of those 40 are already in the spine"
    assert_equal 2, decision[:count]
  end

  # --- [unit] the zero-evidence guard -------------------------------------------
  #
  # THE DEFECT, verbatim from turf-monster PR #549's checks_run:
  #   "fast cert green: 0 mapped (CAPPED: 26 > 15; spine only) + 0 spine test
  #    path(s), rubocop on 3 changed file(s)"
  # The mapped lane was capped, the spine resolved to nothing, and the cert
  # reported GREEN having executed no test at all — rubocop was the only lane, and
  # a linter cannot observe behaviour.

  # THE SET IS WHAT WILL RUN, NOT WHAT MAPPED. A capped mapped lane contributes
  # NOTHING here — that difference is the whole guard, and reading `mapped_only`
  # regardless is exactly how the green cert was issued.
  def test_a_capped_mapped_lane_contributes_no_executed_paths
    mapped = (1..20).map { |i| "test/lib/t#{i}_test.rb" }
    capped = FastCert.cap_decision(mapped, { "config/initializers/studio.rb" => mapped })

    assert_equal ["test/models/spine_core_test.rb"],
                 FastCert.executed_test_paths(mapped, ["test/models/spine_core_test.rb"], capped),
                 "the capped lane runs nothing, so only the spine is executed"
    assert_empty FastCert.executed_test_paths(mapped, [], capped),
                 "capped mapped lane + empty spine = no test file is executed at all"
  end

  def test_an_uncapped_mapped_lane_contributes_its_paths
    mapped = ["test/models/widget_test.rb"]
    decision = FastCert.cap_decision(mapped, { "app/models/widget.rb" => mapped })

    assert_equal ["test/models/widget_test.rb", "test/models/spine_core_test.rb"],
                 FastCert.executed_test_paths(mapped, ["test/models/spine_core_test.rb"], decision)
    assert_equal ["test/models/widget_test.rb"],
                 FastCert.executed_test_paths(mapped, [], decision),
                 "an empty spine is survivable — the mapped lane still executed a test"
  end

  # A path in BOTH lanes is executed once, so the count of executed paths cannot be
  # inflated by the dedupe's leftovers.
  def test_executed_paths_are_deduped_across_the_two_lanes
    mapped = ["test/models/widget_test.rb"]
    decision = FastCert.cap_decision(mapped, { "app/models/widget.rb" => mapped })

    assert_equal ["test/models/widget_test.rb"],
                 FastCert.executed_test_paths(mapped, ["test/models/widget_test.rb"], decision)
  end

  # --- the refusal itself --------------------------------------------------------

  def test_a_capped_lane_over_an_empty_spine_is_refused_and_names_the_culprit
    mapped = (1..26).map { |i| "test/lib/t#{i}_test.rb" }
    capped = FastCert.cap_decision(mapped, { "app/services/solana/config.rb" => mapped })

    refusal = FastCert.zero_test_refusal(mapped, [], capped, slug: "some-task")

    refute_nil refusal, "the PR #549 shape must NOT certify"
    assert_match(/REFUSING TO CERTIFY/, refusal)
    assert_match(/ZERO test files/, refusal)
    assert_match(/CAPPED — 26 mapped path\(s\) over the cap of 15/, refusal,
                 "the builder is told what tripped it")
    assert_match(%r{widest: app/services/solana/config\.rb}, refusal, "and which file caused it")
    assert_match(%r{bin/full-suite-check some-task}, refusal,
                 "the remedy is NAMED, for THIS task — that is what makes the builder able to act")
    assert_match(/FAST_CHECK_MAPPED_CAP=26/, refusal, "the deliberate override stays discoverable")
  end

  # THE OTHER DOOR INTO THE SAME ROOM. Keyed on the CAP, a satellite diff mapping to
  # 26 test files would be refused while one mapping to NONE — strictly LESS evidence
  # — would still certify green on rubocop alone. The guard is keyed on the zero.
  def test_a_diff_that_maps_to_nothing_over_an_empty_spine_is_refused_too
    refusal = FastCert.zero_test_refusal([], [], FastCert.cap_decision([], {}), slug: "some-task")

    refute_nil refusal, "zero executed tests is zero evidence however it was reached"
    assert_match(/maps to NO test file/, refusal, "the reason given must be the REAL one, not the cap")
    refute_match(/CAPPED/, refusal, "no cap was involved — saying so would misdirect the builder")
    refute_match(/FAST_CHECK_MAPPED_CAP/, refusal,
                 "raising a cap that never tripped fixes nothing; offering it is a dead end")
    assert_match(%r{bin/full-suite-check some-task}, refusal)
  end

  # WITHOUT A SLUG (bin/fast-check --print, or a hook) the remedy still has to be
  # copyable, so it degrades to the placeholder rather than to "bin/full-suite-check ".
  def test_the_refusal_without_a_slug_still_prints_a_usable_command
    refusal = FastCert.zero_test_refusal([], [], FastCert.cap_decision([], {}))

    assert_match(%r{bin/full-suite-check <task>}, refusal)
  end

  # AND THE HALF THAT MUST NOT MOVE. A capped run whose SPINE still ran executed real
  # tests: it is a NARROWER cert, honestly labelled by the existing "0 mapped
  # (CAPPED: ...)" evidence, and refusing it would degrade builds that legitimately
  # certified. This is the any-cap-degrades ruling, rejected, pinned as a test.
  def test_a_capped_lane_with_a_LIVE_spine_still_certifies
    mapped = (1..26).map { |i| "test/lib/t#{i}_test.rb" }
    capped = FastCert.cap_decision(mapped, { "app/services/solana/config.rb" => mapped })

    assert_nil FastCert.zero_test_refusal(mapped, ["test/models/task_test.rb"], capped),
               "the spine ran real tests — a cap alone must not degrade the verdict"
  end

  def test_an_ordinary_diff_is_never_refused
    mapped = ["test/models/widget_test.rb"]
    decision = FastCert.cap_decision(mapped, { "app/models/widget.rb" => mapped })

    assert_nil FastCert.zero_test_refusal(mapped, ["test/models/task_test.rb"], decision)
    assert_nil FastCert.zero_test_refusal(mapped, [], decision),
               "a mapped lane that runs is evidence, spine or no spine"
    assert_nil FastCert.zero_test_refusal([], ["test/models/task_test.rb"], decision),
               "a spine that runs is evidence, mapping or no mapping"
  end

  def with_env(pairs)
    previous = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
