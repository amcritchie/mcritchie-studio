# frozen_string_literal: true

require "test_helper"

# [unit] THE SINGULAR BUILD-CLAIM READER MUST SKIP A BLOCK, exactly as the plural one
# does — ReviewerSelector#building_event_actor beside #building_event_actors.
#
# THE DEFECT. Task#block! lands a bounced task back on `building`, so a rework block
# writes a `→ building` TaskEvent whose actor is the REVIEWER who sent the work back.
# PR #1214 taught the PLURAL reader to skip those (TaskEvent#block_transition?) and
# left the SINGULAR one — the same query, minus the filter — reading the last event
# unconditionally. After a bounce it therefore resolved to the reviewer, and #builder
# is what the stored audit payload calls the task's builder.
#
# WHAT IT COULD AND COULD NOT REACH, measured against the code as it stands. The
# singular reader has exactly ONE call site (#builder), and #builder feeds only three
# audit keys — "builder", "excluded_builder", "builder_candidate". Every seat-setting
# path reads the FILTERED plural instead: #builder_candidates, #excluded_builders,
# #busy_base, #carl_primary?, #builder_known? and the RNG seed all derive from
# #builders. So this was an AUDIT defect, not a seating one — and the tests below pin
# BOTH halves, because the bound is the reason the fix is one line and the reason it
# still had to be made.
class ReviewerSelectorBlockActorTest < ActiveSupport::TestCase
  BUILDER = "shannon"
  REVIEWER = "carl"

  # A task whose ONLY record of its author is the transition trail — devops.built_by
  # and devops.builders stripped, which is the state PR #1214's own comments name as
  # the reader's reachable one ("a task stamped before the accumulator existed", or a
  # bare `bin/task move` that named no soul). Written past the callbacks with
  # update_column on purpose: the stamp and the event are written by the SAME save,
  # so there is no way to produce this divergence through the model's front door.
  def bounced_task(builder: BUILDER, reviewer: REVIEWER)
    task = Task.create!(title: "Block Actor Reader Task", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    Current.task_event_actor = builder
    task.update!(stage: "building")
    Current.reset
    Current.task_event_actor = builder
    task.update!(stage: "submitted")
    Current.reset

    Current.task_event_actor = reviewer
    task.block!(by: reviewer, kind: "rework")
    Current.reset

    strip_author_fields!(task)
  ensure
    Current.reset
  end

  def strip_author_fields!(task)
    metadata = task.reload.metadata.deep_dup
    metadata["devops"] = (metadata["devops"] || {}).except("built_by", "builders", "builders_unattributed")
    task.update_column(:metadata, metadata)
    task.reload
  end

  def building_actors(task)
    task.task_events.where(to_stage: "building").order(:occurred_at, :id).map(&:actor)
  end

  # --- THE REGRESSION ---------------------------------------------------------

  test "the singular builder reader skips the reviewer's bounce" do
    task = bounced_task

    assert_equal [BUILDER, REVIEWER], building_actors(task),
                 "the scenario is only meaningful while the bounce is the LAST building event"

    assert_equal BUILDER, ReviewerSelector.explain(task)["builder"],
                 "a rework block is not a build claim, so it cannot name the builder"
  end

  test "the audit reports the exclusion against the soul who actually built it" do
    # The downstream tell. #builder_excluded? asks whether the SINGULAR builder is in
    # the (plural-derived) excluded set, so a singular reader pointing at the reviewer
    # reported NO exclusion on a task whose author was in fact excluded.
    decision = ReviewerSelector.explain(bounced_task)

    assert_equal BUILDER, decision["excluded_builder"]
    assert_equal true, decision["builder_candidate"]
  end

  # --- THE BOUND, PINNED SO IT CANNOT SILENTLY WIDEN --------------------------

  test "the bounce never reached the pool, the seats, or the refusal" do
    decision = ReviewerSelector.explain(bounced_task)

    assert_equal [BUILDER], decision["builders"], "the plural reader already skipped it"
    assert_equal [BUILDER], decision["excluded_builders"]
    assert_equal true, decision["builder_known"]
    refute_includes decision["candidates"], BUILDER, "the author is out of the light pool"
    assert_includes decision["candidates"], REVIEWER == "carl" ? "jasper" : REVIEWER,
                    "and the pool is otherwise whole"
  end

  test "the reviewer is not seated on the diff he bounced" do
    seated = ReviewerSelector.select(bounced_task).map { |r| r["slug"] }

    refute_includes seated, BUILDER, "the author never reviews her own diff"
    assert_equal 2, seated.uniq.size
  end

  # --- THE FAIL-CLOSED DIRECTION ----------------------------------------------
  #
  # An over-broad fix — one that dropped the event fallback, rejected every event, or
  # took the FIRST claim instead of the last — satisfies the two regressions above and
  # destroys what the reader is for. These are that half.

  test "a genuine second build claim still names the CURRENT builder" do
    # A handoff writes a second `→ building` event and nothing about it is a block.
    task = Task.create!(title: "Handoff Names Current Builder", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    Current.task_event_actor = BUILDER
    task.update!(stage: "building")
    Current.reset
    Current.task_event_actor = BUILDER
    task.update!(stage: "submitted")
    Current.reset
    Current.task_event_actor = "jasper"
    task.update!(stage: "building")
    Current.reset
    strip_author_fields!(task)

    assert_equal [BUILDER, "jasper"], building_actors(task)
    assert_equal "jasper", ReviewerSelector.explain(task)["builder"],
                 "the LAST build claim is the current builder; only blocks are skipped"
  ensure
    Current.reset
  end

  test "a task whose only building event is a block still refuses" do
    # Nothing left to read means the author is UNKNOWN, and unknown must refuse. A fix
    # that let the reviewer stand in as the builder would make this pass by seating him.
    task = Task.create!(title: "Only A Block Names Anyone", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.update!(stage: "building")
    task.update!(stage: "submitted")
    Current.task_event_actor = REVIEWER
    task.block!(by: REVIEWER, kind: "rework")
    Current.reset
    strip_author_fields!(task)

    decision = ReviewerSelector.explain(task)

    assert_nil decision["builder"], "a bounce names no builder, and no builder is UNKNOWN"
    assert_equal [], decision["builders"]
    assert_equal false, decision["builder_known"], "and unknown fails CLOSED"
  ensure
    Current.reset
  end
end
