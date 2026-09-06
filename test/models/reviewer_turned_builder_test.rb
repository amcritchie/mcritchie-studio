# frozen_string_literal: true

require "test_helper"

# [unit] THE REVIEWING SESSION THAT TAKES THE BUILD — the hole in the seam
# test/models/reviewer_not_an_author_test.rb pins.
#
# THAT seam (Task#reviewing_party_claim?) suppresses the ENTIRE build claim on any
# write from the session holding this task's live TaskReviewClaim. Correct for the
# write it was built for: bin/statusline's throttled heartbeat, which names NOBODY.
# But it was keyed on the SESSION alone, so it also swallowed a write that names a
# soul — and a claim that names a soul is a deliberate assertion of authorship, not a
# liveness ping.
#
# WHAT THAT COST, on the documented path. `bin/reviewer-select` (:446), the review
# claim CLI (bin/lib/review_claim_cli.rb:690) and pr-review-sop.md (:137) all send a
# reviewer to repair a wrong or missing author stamp with
#
#     bin/task move <slug> building --actor <the-real-builder>
#
# The reviewer runs that while HOLDING the review claim — that is the only moment he
# is looking at the refusal — so the write came from the reviewing session and was
# dropped in silence, at exit 0. The stamp it was supposed to write never landed and
# the next round refused again.
#
# The narrower half is the reviewer who names HIMSELF. It is SOP-forbidden (reviewers
# release the claim on the verdict) and it must not re-point devops.built_by, because
# a reviewer recorded as the current builder is the same defect fully inverted. But it
# must not vanish either: he is now on record as an author, so he is added to
# devops.builders and excluded from the seats — over-counting an author over-excludes,
# which produces a refusal rather than a silent seat.
#
# THE HALF THAT MUST NOT MOVE. Every "still" test below is the fail-closed direction:
# a fix that recorded EVERY write from a reviewing session would satisfy the two
# regressions here and hand the measured 2026-09-04 bug straight back.
class ReviewerTurnedBuilderTest < ActiveSupport::TestCase
  BUILDER_SESSION  = "b1d0f2a3-4b5c-4d6e-8f90-a1b2c3d4e5f6"
  REVIEWER_SESSION = "c2e1f3b4-5c6d-4e7f-9a01-b2c3d4e5f6a7"
  STRANGER_SESSION = "d3f2a4c5-6d7e-4f80-ab12-c3d4e5f6a7b8"

  # A submitted task. `builder:` nil leaves devops.built_by BLANK — the state the
  # documented repair exists for (a bare `bin/task move` names the session, not a
  # soul), and the state in which the repair's effect is observable.
  def submitted_task(builder: nil)
    task = Task.create!(title: "Reviewer Turned Builder Task", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    Current.task_event_actor = builder || BUILDER_SESSION
    task.update!(stage: "building",
                 metadata: { "devops" => task.devops.merge(
                   ClaimLease.renewed(session: BUILDER_SESSION, nonce: "inst-B")
                 ) })
    Current.reset
    Current.task_event_actor = BUILDER_SESSION
    task.update!(stage: "submitted")
    task.reload
  ensure
    Current.reset
  end

  def reviewing!(task, session: REVIEWER_SESSION, reviewer: "carl")
    outcome = TaskReviewClaim.acquire(task_slug: task.slug, session: session,
                                      nonce: "inst-R", reviewer: reviewer)
    assert outcome.acquired, "the review claim must be held for this scenario to mean anything"
    outcome
  end

  def block_for_rework!(task, by: "carl")
    Current.task_event_actor = by
    task.block!(by: by, kind: "rework")
  ensure
    Current.reset
  end

  # `bin/task move <slug> building --actor <soul>` — a deliberate build claim: a fresh
  # lease for the calling session, and an event actor that NAMES somebody.
  def claim_build!(task, actor:, session:)
    devops = task.reload.devops
    Current.task_event_actor = actor
    task.update!(stage: "building", metadata: task.metadata.merge(
      "devops" => devops.merge(ClaimLease.renewed(session: session, nonce: "inst-R", prior: devops))
    ))
    task.reload
  ensure
    Current.reset
  end

  # `bin/task heartbeat <slug>` — the same lease write with NO actor at all.
  def heartbeat!(task, session:)
    devops = task.reload.devops
    task.update!(metadata: task.metadata.merge(
      "devops" => devops.merge(ClaimLease.renewed(session: session, nonce: "inst-R", prior: devops))
    ))
    task.reload
  end

  # The loud half of "recorded or refused loudly" is a log line, so one test has to
  # read the log. Swap the logger for the duration and hand back what it wrote.
  def capture_rails_log
    buffer   = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(buffer)
    yield
    buffer.string
  ensure
    Rails.logger = original
  end

  def built_by(task) = task.reload.devops["built_by"]
  def authors(task) = task.reload.devops["builders"]
  def unattributed(task) = task.reload.devops["builders_unattributed"]

  # --- THE REGRESSION: THE DOCUMENTED REPAIR --------------------------------

  test "the reviewer's repair records the author it names" do
    task = submitted_task
    reviewing!(task)
    block_for_rework!(task)

    claim_build!(task, actor: "shannon", session: REVIEWER_SESSION)

    assert_equal "shannon", built_by(task),
                 "the reviewer stated who wrote it; the board must not drop the statement"
    assert_equal ["shannon"], authors(task)
    assert_nil unattributed(task)
  end

  test "the reviewer's repair clears the refusal it was prescribed for" do
    # The symptom: `bin/reviewer-select` refuses, prints the repair, the reviewer runs
    # it, and the next round refused all the same because nothing was written.
    task = submitted_task
    reviewing!(task)
    block_for_rework!(task)

    refute ReviewerSelector.explain(task.reload)["builder_known"],
           "the scenario is only meaningful while the record still refuses"

    claim_build!(task, actor: "shannon", session: REVIEWER_SESSION)

    decision = ReviewerSelector.explain(task.reload)
    assert_equal true, decision["builder_known"]
    assert_equal ["shannon"], decision["builders"]
    refute_includes ReviewerSelector.select(task.reload).map { |r| r["slug"] }, "shannon"
  end

  # --- THE REGRESSION: THE REVIEWER WHO NAMES HIMSELF -------------------------

  test "a reviewer who takes the build is recorded as an author" do
    task = submitted_task(builder: "shannon")
    reviewing!(task)
    block_for_rework!(task)

    claim_build!(task, actor: "carl", session: REVIEWER_SESSION)

    assert_equal ["shannon", "carl"], authors(task),
                 "he is on record as having claimed the build; the set must say so"
    assert_nil unattributed(task), "he named himself, so nothing here is unattributable"
  end

  test "but he never re-points built_by to himself" do
    # The inversion jasper reproduced on PR #1214 — Expected shannon, Actual carl. A
    # reviewer recorded as the CURRENT builder is a confidently-wrong author set, which
    # is worse than a refusing one. Recording him as an author costs nothing; letting
    # him overwrite the author already on record costs the record.
    task = submitted_task(builder: "shannon")
    reviewing!(task)
    block_for_rework!(task)

    claim_build!(task, actor: "carl", session: REVIEWER_SESSION)

    assert_equal "shannon", built_by(task)
  end

  test "and he is then kept out of the seats on that task" do
    # The consequence that makes recording him the SAFE answer: an author over-counted
    # is an author over-excluded, and Carl yields even the standing primary seat to the
    # no-self-review rule.
    task = submitted_task(builder: "shannon")
    reviewing!(task)
    block_for_rework!(task)
    claim_build!(task, actor: "carl", session: REVIEWER_SESSION)

    seated = ReviewerSelector.select(task.reload).map { |r| r["slug"] }

    refute_includes seated, "carl", "he claimed the build; he does not review it"
    refute_includes seated, "shannon"
    assert_equal 2, seated.uniq.size, "and a pair still forms"
  end

  # --- THE REGRESSION: THE CLAIM THAT NAMES NO REVIEWER ----------------------

  # `holder_agent` is OPTIONAL. `--agent` is optional on both `bin/task review-claim
  # acquire` and the server-side `claim_next_review` pop (bin/lib/review_claim_cli.rb
  # :185-187 says so outright), and TaskReviewClaim stores
  # `reviewer.to_s.strip.presence` with no Task.soul? check — so a live review claim
  # naming NOBODY is a designed state, not a corner. Keying the seam on a name match
  # alone reads that blank as "not the reviewer" and re-points built_by to the very
  # session doing the reviewing: the inversion, reached by the ordinary path.

  # A holder that names nobody ON THE ROSTER is the same state as a blank one. `--agent`
  # is unvalidated at every door (TaskReviewClaim stores `reviewer.to_s.strip.presence`
  # with no Task.soul? check), so a typo'd `--agent carll` stores a holder that IS
  # present and matches NO soul. Keyed on `holder.empty?`, that fell past the guard to
  # the name comparison, missed, and re-pointed built_by to the reviewer — the very
  # inversion, reached through a typo instead of an omission.
  test "a review claim whose holder is OFF-ROSTER holds built_by back too" do
    task = submitted_task(builder: "shannon")
    reviewing!(task, reviewer: "carll")
    block_for_rework!(task)

    claim_build!(task, actor: "carl", session: REVIEWER_SESSION)

    assert_equal "shannon", built_by(task),
                 "a holder matching no soul cannot clear carl any more than a blank one can"
    assert_equal ["shannon", "carl"], authors(task), "and he is still RECORDED as an author"
  end

  test "a review claim that names NOBODY still holds built_by back" do
    task = submitted_task(builder: "shannon")
    reviewing!(task, reviewer: nil)
    block_for_rework!(task)

    claim_build!(task, actor: "carl", session: REVIEWER_SESSION)

    assert_equal "shannon", built_by(task),
                 "the claim cannot identify its holder, so it cannot clear him to re-point"
  end

  test "and the soul it names is still RECORDED as an author" do
    # The other half of "recorded or refused loudly": holding built_by back must not
    # cost the record. He joins the set, so the refusal the repair was printed for
    # clears (ReviewerSelector#builder_known? is asked over the SET, not over
    # built_by) and he is kept out of the seats on his own diff.
    task = submitted_task(builder: "shannon")
    reviewing!(task, reviewer: nil)
    block_for_rework!(task)

    claim_build!(task, actor: "carl", session: REVIEWER_SESSION)

    assert_equal ["shannon", "carl"], authors(task)
    assert_nil unattributed(task), "he named himself, so nothing here is unattributable"
    assert_equal true, ReviewerSelector.explain(task.reload)["builder_known"]
    refute_includes ReviewerSelector.select(task.reload).map { |r| r["slug"] }, "carl"
  end

  test "and the refusal to re-point is LOUD" do
    # Criterion 2 is "recorded OR REFUSED LOUDLY". The warning is the whole of the
    # loud half — it is what the log carries when someone asks why built_by did not
    # move — and on the blank lane it is the only signal there is. Pin it, or the
    # guard can go quiet without a single test noticing.
    task = submitted_task(builder: "shannon")
    reviewing!(task, reviewer: nil)
    block_for_rework!(task)

    log = capture_rails_log { claim_build!(task, actor: "carl", session: REVIEWER_SESSION) }

    assert_match(/\[builder-stamp\].*#{Regexp.escape(task.slug)}/, log)
    assert_match(/names no reviewer/, log,
                 "the log has to say WHY it could not clear him, not merely that it did not")
  end

  test "an ANONYMOUS claim under a nameless review is still merely a renewal" do
    # The fail-closed direction for this lane. Widening the seam to "a nameless review
    # claim suppresses everything" is not what changed: the unnamed write is still
    # judged by #reviewing_party_renewal?, which never reaches this guard at all.
    task = submitted_task(builder: "shannon")
    reviewing!(task, reviewer: nil)
    block_for_rework!(task)

    heartbeat!(task, session: REVIEWER_SESSION)

    assert_equal "shannon", built_by(task)
    assert_equal ["shannon"], authors(task), "a heartbeat names nobody and claims nothing"
    assert_nil unattributed(task)
  end

  # --- THE FAIL-CLOSED DIRECTION ---------------------------------------------

  test "the reviewer's unnamed heartbeat is still not a build claim" do
    # THE MEASURED BUG, unchanged. A fix keyed on the session alone — recording every
    # write from a reviewing party — hands this straight back: four bounced tasks in
    # one 2026-09-04 sitting, each needing a hand-passed `--builder <soul>`.
    task = submitted_task(builder: "shannon")
    reviewing!(task)
    block_for_rework!(task)

    heartbeat!(task, session: REVIEWER_SESSION)

    assert_equal "shannon", built_by(task)
    assert_equal ["shannon"], authors(task), "a heartbeat names nobody and claims nothing"
    assert_nil unattributed(task)
    assert_equal true, ReviewerSelector.explain(task.reload)["builder_known"]
  end

  test "an unnamed claim from a session that is NOT reviewing still refuses" do
    # The refusal has to survive the fix, or the whole mechanism is decoration.
    task = submitted_task(builder: "shannon")
    block_for_rework!(task)

    heartbeat!(task, session: STRANGER_SESSION)

    assert_equal STRANGER_SESSION, unattributed(task),
                 "no review claim means an ordinary anonymous handoff"
    assert_equal false, ReviewerSelector.explain(task.reload)["builder_known"]
  end

  test "a named claim from a session that is NOT reviewing re-points built_by" do
    # The ordinary handoff, untouched — the control for the two regressions above. Only
    # the REVIEWING party is held back from re-pointing.
    task = submitted_task(builder: "shannon")
    block_for_rework!(task)

    claim_build!(task, actor: "jasper", session: STRANGER_SESSION)

    assert_equal "jasper", built_by(task)
    assert_equal ["shannon", "jasper"], authors(task)
  end

  test "a review claim held by a DIFFERENT session does not hold the stamp back" do
    # The seam is the session, not the existence of a review. Another session reviewing
    # says nothing about the session doing the claiming.
    task = submitted_task(builder: "shannon")
    reviewing!(task, session: REVIEWER_SESSION)
    block_for_rework!(task)

    claim_build!(task, actor: "carl", session: STRANGER_SESSION)

    assert_equal "carl", built_by(task),
                 "this claim came from a session holding no review on this task"
  end
end
