# frozen_string_literal: true

require "test_helper"

# [integration] THE DOCUMENTED REPAIR, DRIVEN THROUGH THE API THE REVIEWER CALLS.
#
# The unit tier (test/models/reviewer_turned_builder_test.rb) drives the model. This
# one drives the wire, because the defect was in what the board did with an ordinary
# PATCH — and because the repair's whole point is that a REVIEWER runs it.
#
# When `bin/reviewer-select` refuses ("the AUTHORS ARE UNKNOWN") it prints the durable
# fix, and so do bin/lib/review_claim_cli.rb and pr-review-sop.md:
#
#     bin/task move <slug> building --actor <the-real-builder>
#
# On the wire that is `PATCH /api/v1/tasks/:slug` with `stage: building`, an `event`
# naming the author, and a devops slice carrying the caller's lease. The caller is the
# reviewer, holding this task's live TaskReviewClaim — that is the only moment anyone
# is reading the refusal. Keyed on the session alone, the board read that as a review
# write and dropped the whole claim: the stamp never landed, the response was 200, and
# the next round refused identically.
#
# THE FAIL-CLOSED HALF RIDES ALONG. The heartbeat that names NOBODY must still be
# swallowed, or the measured 2026-09-04 bug (four bounced tasks, each needing a
# hand-passed `--builder <soul>`) comes straight back.
class ReviewerRepairStampApiTest < ActionDispatch::IntegrationTest
  BUILDER_SESSION  = "b1d0f2a3-4b5c-4d6e-8f90-a1b2c3d4e5f6"
  REVIEWER_SESSION = "c2e1f3b4-5c6d-4e7f-9a01-b2c3d4e5f6a7"

  def token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)

  def auth = { "Authorization" => "Bearer #{token}" }

  def patch_task(slug, params)
    patch "/api/v1/tasks/#{slug}", params: params, headers: auth, as: :json
    assert_response :success
  end

  # `bin/task move <slug> building [--actor <soul>]`.
  def claim!(task, actor:, session:)
    patch_task(task.slug, stage: "building", event: { actor: actor },
                          devops: ClaimLease.renewed(session: session, nonce: "inst-B"))
  end

  def submit!(task, actor:)
    patch_task(task.slug, stage: "submitted", event: { actor: actor })
  end

  def block!(task, by:)
    patch "/api/v1/tasks/#{task.slug}/block",
          params: { kind: "rework", by: by, event: { actor: by, source: "cli" } },
          headers: auth, as: :json
    assert_response :success
  end

  # `bin/task heartbeat <slug>` — a devops PATCH with a fresh lease and NO event.
  def heartbeat!(task, session:)
    devops = task.reload.metadata["devops"] || {}
    patch_task(task.slug, devops: devops.merge(
      ClaimLease.renewed(session: session, nonce: "inst-R", prior: devops)
    ))
  end

  # `bin/task move <slug> building --actor <soul>` run from the REVIEWER's session:
  # the same shape as claim!, but the lease names the session holding the review.
  def repair!(task, actor:, session: REVIEWER_SESSION)
    devops = task.reload.metadata["devops"] || {}
    patch_task(task.slug, stage: "building", event: { actor: actor },
                          devops: devops.merge(
                            ClaimLease.renewed(session: session, nonce: "inst-R", prior: devops)
                          ))
  end

  # A submitted task whose author the record cannot name — a bare `bin/task move`
  # stamps the SESSION, not a soul, which is the state the repair exists for.
  def unattributed_task(title)
    task = Task.create!(title: title, stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    claim!(task, actor: BUILDER_SESSION, session: BUILDER_SESSION)
    submit!(task, actor: BUILDER_SESSION)
    task.reload
  end

  def reviewing!(task, reviewer: "carl")
    outcome = TaskReviewClaim.acquire(task_slug: task.slug, session: REVIEWER_SESSION,
                                      nonce: "inst-R", reviewer: reviewer)
    assert outcome.acquired, "the review claim must be held for this scenario to mean anything"
  end

  test "the reviewer's repair stamps the author it names" do
    task = unattributed_task("Reviewer Repair Stamps Author")
    reviewing!(task)
    block!(task, by: "carl")

    assert_equal false, ReviewerSelector.explain(task.reload)["builder_known"],
                 "the scenario is only meaningful while the record still refuses"

    repair!(task, actor: "shannon")

    devops = task.reload.metadata["devops"]
    assert_equal "shannon", devops["built_by"]
    assert_equal ["shannon"], devops["builders"]
    assert_equal true, ReviewerSelector.explain(task.reload)["builder_known"],
                 "and the refusal the repair was printed for is cleared"
  end

  test "the reviewer naming himself is recorded without re-pointing built_by" do
    task = Task.create!(title: "Reviewer Names Himself Api", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    claim!(task, actor: "shannon", session: BUILDER_SESSION)
    submit!(task, actor: BUILDER_SESSION)
    reviewing!(task.reload)
    block!(task, by: "carl")

    repair!(task, actor: "carl")

    devops = task.reload.metadata["devops"]
    assert_equal "shannon", devops["built_by"], "a reviewer never becomes the builder"
    assert_equal ["shannon", "carl"], devops["builders"], "but the claim is on the record"
    refute_includes ReviewerSelector.select(task.reload).map { |r| r["slug"] }, "carl"
  end

  test "a review claim that names NOBODY still cannot re-point built_by" do
    # THE SAME INVERSION, REACHED BY THE ORDINARY PATH. `--agent` is optional on both
    # `bin/task review-claim acquire` and the server-side pop, and TaskReviewClaim
    # stores `reviewer.to_s.strip.presence` with no soul check — so `holder_agent` is
    # routinely blank. A seam that clears the claimant whenever the holder's name does
    # not MATCH reads that blank as "not the reviewer" and stamps him. Measured on a
    # throwaway tree both ways: origin/accepted -> shannon, head 31ba687d -> carl.
    #
    # Every other fixture in this file hardcodes `reviewer: "carl"`, which populates
    # holder_agent — which is precisely why the mutation that lets a reviewer re-point
    # built_by died at only 3 red. This lane was never exercised.
    task = Task.create!(title: "Nameless Review Claim Api", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    claim!(task, actor: "shannon", session: BUILDER_SESSION)
    submit!(task, actor: BUILDER_SESSION)
    reviewing!(task.reload, reviewer: "")
    block!(task, by: "carl")

    repair!(task, actor: "carl")

    devops = task.reload.metadata["devops"]
    assert_equal "shannon", devops["built_by"],
                 "the claim names no reviewer, so it cannot clear this soul to re-point"
    assert_equal ["shannon", "carl"], devops["builders"], "but the claim is on the record"
    assert_equal true, ReviewerSelector.explain(task.reload)["builder_known"]
    refute_includes ReviewerSelector.select(task.reload).map { |r| r["slug"] }, "carl"
  end

  test "the reviewer's unnamed heartbeat is still swallowed" do
    # THE FAIL-CLOSED DIRECTION. A fix keyed on the session alone — or one that
    # recorded every write from a reviewing party — passes the two tests above and
    # reinstates the measured bug.
    task = Task.create!(title: "Reviewer Heartbeat Still Swallowed", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    claim!(task, actor: "shannon", session: BUILDER_SESSION)
    submit!(task, actor: BUILDER_SESSION)
    reviewing!(task.reload)
    block!(task, by: "carl")

    heartbeat!(task, session: REVIEWER_SESSION)

    devops = task.reload.metadata["devops"]
    assert_equal ["shannon"], devops["builders"], "a heartbeat names nobody and claims nothing"
    assert_nil devops["builders_unattributed"]
    assert_equal true, ReviewerSelector.explain(task.reload)["builder_known"]
  end
end
