# frozen_string_literal: true

# A REVIEWER IS NOT AN AUTHOR — Task#reviewing_party_claim?, the seam that tells a
# review write from a build write.
#
# THE DEFECT. `bin/task block <slug> --kind rework` lands the bounced task back on
# `building` and repoints the BLOCKING session's feature marker at it. bin/statusline
# reads that marker, sees `building`, and fires that session's build-claim heartbeat
# — from a session that never built anything. The claim keys were stripped when the
# task moved to `submitted` (Task#enforce_build_claim_invariant), so the lease read
# :unclaimed, the heartbeat ADOPTED it, and the resulting PATCH named the reviewer's
# session. Server-side that is indistinguishable from a handoff: the lease was
# rewritten, the write named no soul, and #builder_roll_call stamped
# `devops.builders_unattributed` with the REVIEWER's session id. The author set then
# reads INCOMPLETE and `bin/reviewer-select` refuses the next round — "the AUTHORS
# ARE UNKNOWN".
#
# Measured 2026-09-04: four bounced tasks in one review sitting, each needing a
# hand-passed `--builder <soul>` before it could be reviewed again. `--agent carl`
# on the block did not help — the stamp is not written by the block, it is written
# by the throttled heartbeat that follows it, which carries no actor at all.
#
# THE TWO HALVES THIS FILE PINS, and they must be pinned SEPARATELY because either
# one alone stops the measured bug and would leave the other free to rot:
#   · this file — the BOARD refuses to read authorship out of a write by the
#     session holding the task's live review claim.
#   · test/commands/task_heartbeat_claim_test.rb — the CLI never SENDS that write:
#     a heartbeat renews a lease it already holds and never acquires a free one.
#
# AND THE HALF THAT MUST NOT MOVE. The refusal is fail-CLOSED on purpose: a
# genuinely incomplete author set must still refuse, or the whole mechanism is
# decoration. A fix that made the selector always succeed would satisfy the bug
# report and destroy the property. Every "still refuses" test below is that half.
require "test_helper"

class ReviewerNotAnAuthorTest < ActiveSupport::TestCase
  # UUID-shaped, like real session ids — the roll call branches on SOUL_SLUG, so a
  # soul-shaped stand-in would take a different path entirely.
  BUILDER_SESSION  = "b1d0f2a3-4b5c-4d6e-8f90-a1b2c3d4e5f6"
  REVIEWER_SESSION = "c2e1f3b4-5c6d-4e7f-9a01-b2c3d4e5f6a7"
  STRANGER_SESSION = "d3f2a4c5-6d7e-4f80-ab12-c3d4e5f6a7b8"

  # --- the sequence, driven exactly as the pipeline drives it -----------------

  def submitted_task(builder: "shannon")
    task = Task.create!(title: "Reviewer Author Seam Task", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    Current.task_event_actor = builder
    task.update!(stage: "building",
                 metadata: { "devops" => task.devops.merge(
                   ClaimLease.renewed(session: BUILDER_SESSION, nonce: "inst-B")
                 ) })
    Current.reset
    Current.task_event_actor = BUILDER_SESSION
    task.update!(stage: "submitted")
    task
  ensure
    Current.reset
  end

  # The reviewer's rework bounce, as api/v1/tasks#block performs it.
  def block_for_rework!(task, by: "carl")
    Current.task_event_actor = by
    task.block!(by: by, kind: "rework")
  ensure
    Current.reset
  end

  # What `bin/task heartbeat` PATCHes: the devops hash with a fresh lease for the
  # heartbeating session, and NO event actor (a heartbeat names nobody).
  def heartbeat_lease!(task, session:, nonce: "inst-R")
    devops = task.reload.devops
    task.update!(metadata: task.metadata.merge(
      "devops" => devops.merge(ClaimLease.renewed(session: session, nonce: nonce, prior: devops))
    ))
    task.reload
  end

  def reviewing!(task, session: REVIEWER_SESSION, nonce: "inst-R", reviewer: "carl")
    outcome = TaskReviewClaim.acquire(task_slug: task.slug, session: session,
                                      nonce: nonce, reviewer: reviewer)
    assert outcome.acquired, "the review claim must be held for this scenario to mean anything"
    outcome
  end

  def authors(task) = task.reload.devops["builders"]
  def unattributed(task) = task.reload.devops["builders_unattributed"]

  # --- THE REGRESSION ---------------------------------------------------------

  test "a rework block from another session leaves the author set untouched" do
    task = submitted_task
    reviewing!(task)
    block_for_rework!(task)

    heartbeat_lease!(task, session: REVIEWER_SESSION)

    assert_equal ["shannon"], authors(task),
                 "the reviewer's session never wrote a line of this diff"
    assert_nil unattributed(task),
               "the block bounced the task; it did not hand the build to an unnamed party"
    assert_equal "shannon", task.reload.devops["built_by"]
  end

  test "a rework block from another session leaves reviewer selection able to select" do
    # The consequence the operator actually felt: not a wrong field, a REFUSAL on
    # every subsequent round, cleared by hand with `--builder <soul>`.
    task = submitted_task
    reviewing!(task)
    block_for_rework!(task)
    heartbeat_lease!(task, session: REVIEWER_SESSION)

    decision = ReviewerSelector.explain(task.reload)

    assert_equal true, decision["builder_known"],
                 "the record names its author; a bounce must not turn that into UNKNOWN"
    assert_nil decision["builders_unattributed"]
    assert_equal ["shannon"], decision["builders"]
  end

  test "the reviewer is still kept out of the seats after the bounce" do
    # Suppressing the stamp must not suppress the EXCLUSION it feeds. A fix that
    # emptied the author set would pass the two tests above and seat the author.
    task = submitted_task
    reviewing!(task)
    block_for_rework!(task)
    heartbeat_lease!(task, session: REVIEWER_SESSION)

    seated = ReviewerSelector.select(task.reload).map { |r| r["slug"] }

    refute_includes seated, "shannon", "the author is still excluded from her own diff"
    assert_equal 2, seated.uniq.size, "and a pair still forms"
  end

  test "a reviewer write carrying a soul actor does not re-point built_by" do
    # The inverted form of the same defect, and the worse one. #builder_to_stamp
    # rule 1 re-points built_by to an explicit soul actor, so a review write made
    # with `--agent carl` would have recorded CARL as the builder of a PR he
    # reviewed — an author set that is confidently WRONG rather than merely
    # incomplete.
    #
    # THE PROPERTY IS built_by, AND ONLY built_by. This test also asserted that carl
    # stayed OUT of devops.builders, and that half was pinning the implementation
    # rather than the property: suppressing the whole claim dropped a soul-named
    # write with no record of it anywhere, which is the silent hole
    # test/models/reviewer_turned_builder_test.rb now covers. He is recorded as an
    # AUTHOR (over-counting over-EXCLUDES, so it refuses rather than seats) and still
    # never as the builder.
    task = submitted_task
    reviewing!(task)
    block_for_rework!(task)

    devops = task.reload.devops
    Current.task_event_actor = "carl"
    task.update!(metadata: task.metadata.merge(
      "devops" => devops.merge(ClaimLease.renewed(session: REVIEWER_SESSION, nonce: "inst-R", prior: devops))
    ))
    Current.reset

    assert_equal "shannon", task.reload.devops["built_by"],
                 "the reviewer named himself, and that never re-points the builder"
    assert_equal ["shannon", "carl"], authors(task),
                 "but it is on record, because a claim nobody can see is the worse failure"
  end

  # --- THE TRANSITION TRAIL, WHICH READS AUTHORS TOO --------------------------
  #
  # The third site of the same defect, and it needs no heartbeat to fire: #block!
  # lands the task on `building`, so the bounce itself writes a `→ building`
  # transition whose actor is the REVIEWER. ReviewerSelector#builders unions those
  # actors in, so after a bounce the author set read ["shannon", "carl"] — the
  # reviewer excluded from the task's own pool, and named in the audit as an author
  # of a diff he only read.

  test "the bounce alone does not read the reviewer into the author set" do
    task = submitted_task
    block_for_rework!(task)

    decision = ReviewerSelector.explain(task.reload)

    assert_equal ["shannon"], decision["builders"],
                 "moving a task to `building` by BOUNCING it is not a build claim"
    assert_equal true, decision["builder_known"]
  end

  test "the bounce still records WHO blocked it, marked as a block" do
    # The marker must not be bought by hiding the actor. The trail is the record of
    # who did what, and a bounce with no blocker on it would be a worse lie than
    # the one being fixed.
    task = submitted_task
    block_for_rework!(task)

    event = task.task_events.where(to_stage: "building").order(:occurred_at, :id).last

    assert_equal "carl", event.actor, "the trail still names the blocker"
    assert event.block_transition?, "and says the transition was a block"
    assert_equal "rework", event.metadata["block_kind"]
  end

  test "an ordinary build claim is NOT marked as a block" do
    # The guard, run against the case it must not catch: without this, marking
    # every `→ building` transition would empty the author set entirely and the
    # tests above would still pass.
    task = Task.create!(title: "Ordinary Build Claim Task", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    Current.task_event_actor = "shannon"
    task.update!(stage: "building")
    Current.reset

    event = task.task_events.where(to_stage: "building").order(:occurred_at, :id).last

    refute event.block_transition?, "a plain claim is not a block"
    assert_equal ["shannon"], ReviewerSelector.explain(task.reload)["builders"],
                 "and it still reads as authorship"
  end

  # --- THE FAIL-CLOSED HALF, WHICH MUST NOT MOVE ------------------------------

  test "an unnamed claim by a session that is NOT reviewing still refuses" do
    # The property the whole mechanism exists for. A session that holds no review
    # claim is an ordinary handoff: it worked here and the record cannot name it,
    # so the author set is incomplete and selection refuses.
    task = submitted_task
    block_for_rework!(task)

    heartbeat_lease!(task, session: STRANGER_SESSION, nonce: "inst-S")

    assert_equal STRANGER_SESSION, unattributed(task),
                 "an anonymous claimant with no review claim is still an unnamed author"
    assert_equal false, ReviewerSelector.explain(task.reload)["builder_known"]
  end

  test "an EXPIRED review claim does not exempt the writing session" do
    # The exemption is bound to a LIVE review lease, not to "this session once
    # reviewed something". A lapsed reviewer is indistinguishable from any other
    # unnamed party, and unknown must refuse.
    task = submitted_task
    reviewing!(task)
    TaskReviewClaim.find_by(task_slug: task.slug)
                   .update!(claim_expires_at: 10.minutes.ago)
    block_for_rework!(task)

    heartbeat_lease!(task, session: REVIEWER_SESSION)

    assert_equal REVIEWER_SESSION, unattributed(task),
                 "a lapsed review lease is not a live reviewer"
    assert_equal false, ReviewerSelector.explain(task.reload)["builder_known"]
  end

  test "a live review claim held by a DIFFERENT session does not exempt this one" do
    # The seam compares the writing session against the review holder. A task under
    # review by session A does not license session B to claim it anonymously.
    task = submitted_task
    reviewing!(task)
    block_for_rework!(task)

    heartbeat_lease!(task, session: STRANGER_SESSION, nonce: "inst-S")

    assert_equal STRANGER_SESSION, unattributed(task),
                 "somebody else is reviewing; this claimant is still unnamed"
  end

  test "a task with no author on record still refuses" do
    # The other genuine unknown: nothing was ever stamped. Selection must refuse on
    # the empty set exactly as before — this fix touches who gets ADDED, never
    # whether an empty set counts as known.
    task = Task.create!(title: "Never Stamped Author Task", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    task.update!(stage: "building",
                 metadata: { "devops" => task.devops.merge(
                   ClaimLease.renewed(session: BUILDER_SESSION, nonce: "inst-B")
                 ) })
    task.update!(stage: "submitted")

    assert_equal false, ReviewerSelector.explain(task.reload)["builder_known"],
                 "an unstamped task names nobody to exclude"
  end

  # --- the ordinary builder path, unchanged -----------------------------------

  test "a genuine second builder is still recorded after a bounce" do
    # The bounce's happy path: the builder comes back and re-claims by name. That
    # IS an authorship moment and must still accumulate, or the fix has bought
    # criterion 1 by breaking the accumulator underneath it.
    task = submitted_task
    reviewing!(task)
    block_for_rework!(task)
    heartbeat_lease!(task, session: REVIEWER_SESSION)

    Current.task_event_actor = "alex"
    devops = task.reload.devops
    task.update!(stage: "building",
                 metadata: task.metadata.merge(
                   "devops" => devops.merge(ClaimLease.renewed(session: STRANGER_SESSION, nonce: "inst-S",
                                                               prior: devops))
                 ))
    Current.reset

    assert_equal %w[shannon alex], authors(task).sort_by { |s| %w[shannon alex].index(s) },
                 "the soul who finished the rework joins the set"
    assert_nil unattributed(task)
  end
end
