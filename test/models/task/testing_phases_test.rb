require "test_helper"

class Task::TestingPhasesTest < ActiveSupport::TestCase
  # A task whose durable events make each phase a clean, exactly-measured window:
  # build 600s (building → first cert start), cert 300s, submitted at +20m and
  # reviewed at +33m. Review/CI evidence (gate runs, intents, CI actions) is layered
  # on per test, so each v2 boundary rule is exercised in isolation.
  def probe_task
    @anchor = 60.minutes.ago
    task = Task.create!(title: "Phase Timing Probe")
    add_event(task, kind: "transition", to_stage: "building",  at: @anchor)
    add_event(task, kind: "checkpoint", to_stage: "cert", status: "started",   at: @anchor + 10.minutes)
    add_event(task, kind: "checkpoint", to_stage: "cert", status: "completed", at: @anchor + 15.minutes)
    add_event(task, kind: "transition", to_stage: "submitted", at: @anchor + 20.minutes)
    add_event(task, kind: "transition", to_stage: "reviewed",  at: @anchor + 33.minutes)
    task
  end

  def add_event(task, kind:, to_stage:, at:, status: nil)
    task.task_events.create!(kind: kind, from_stage: task.stage, to_stage: to_stage,
                             occurred_at: at, seconds_in_from: nil, source: "test",
                             metadata: status ? { "status" => status } : {})
  end

  # A block bounce: Task#block! lands the task back on `building`, so the event is a
  # `-> building` TRANSITION whose actor is the BLOCKER, carrying the `blocked` marker
  # TaskEvent#block_transition? reads.
  def add_block(task, at:, actor: "carl")
    task.task_events.create!(kind: "transition", from_stage: "submitted", to_stage: "building",
                             occurred_at: at, seconds_in_from: nil, source: "test",
                             actor: actor, metadata: { "blocked" => true, "block_kind" => "rework" })
  end

  def add_ci_action(task, event_slug:, at:, duration_ms: 60_000)
    AgentAction.create!(session_id: "sess-ci-probe", kind: "test_scope", event_slug: event_slug,
                        result_slug: "pass", task_slug: task.slug, occurred_at: at,
                        duration_ms: duration_ms)
  end

  # A CI action carrying the REAL GitHub workflow-run window bin/ci-scope-capture
  # stamps: the actual startedAt (input) + completedAt (output). `occurred_at` (the
  # INGEST time) is deliberately set LATE so a test can prove ci_phase spans on the
  # real completedAt, never the ingest occurred_at.
  def add_real_ci_action(task, event_slug:, started_at:, completed_at:, occurred_at:)
    AgentAction.create!(session_id: "sess-ci-probe", kind: "test_scope", event_slug: event_slug,
                        result_slug: "pass", task_slug: task.slug, occurred_at: occurred_at,
                        duration_ms: ((completed_at - started_at) * 1000).to_i,
                        input: started_at.iso8601, output: completed_at.iso8601)
  end

  def open_review_gate(task, key: "g2a_primary", at:)
    GateRun.open!(subject_type: "task", subject_slug: task.slug, key: key, actor: "carl", now: at)
  end

  test "[unit] build derives the four task-owned phase windows from events + gate runs + CI actions" do
    task = probe_task
    add_ci_action(task, event_slug: "ci_lint", at: @anchor + 25.minutes)
    add_ci_action(task, event_slug: "ci_test", at: @anchor + 27.minutes)
    open_review_gate(task, at: @anchor + 22.minutes)

    phases = Task::TestingPhases.build(task).fetch("phases")

    assert_equal Task::TestingPhases::PHASE_KEYS, phases.keys, "exactly the four v2 phases, in order"
    assert_equal 600, phases.dig("build", "seconds"), "building -> first cert start"
    assert_equal "completed", phases.dig("build", "status")
    assert_equal 300, phases.dig("local_certification", "seconds"), "cert started -> cert finished"
    assert_equal 420, phases.dig("ci", "seconds"), "submitted handoff -> last CI action settle"
    assert_equal 660, phases.dig("review", "seconds"), "gate-run start -> reviewed, NOT submitted -> reviewed"
    refute phases.key?("acceptance"), "operator acceptance is no longer a task phase"
  end

  test "[unit] the SHARDED lane's own scopes close the CI phase" do
    # The suite was sharded on 2026-08-20: the monolithic `test` job became `rails` (a
    # 4-way matrix, all four reported under ci_rails once bin/ci-scope-capture strips the
    # matrix suffix) plus `system` and `rails_executed_set`. If the new slugs are not in
    # CI_SCOPES, every task from now on renders a blank CI window.
    task = probe_task
    add_ci_action(task, event_slug: "ci_rails", at: @anchor + 25.minutes)
    add_ci_action(task, event_slug: "ci_rails_executed_set", at: @anchor + 27.minutes)

    assert_equal 420, Task::TestingPhases.build(task).dig("phases", "ci", "seconds"),
                 "the sharded lane's own scopes must close the CI phase"
  end

  test "[unit] a task whose CI rows predate the shard rename still renders its CI phase" do
    # DATA COMPATIBILITY, and nothing in the sharding diff would have caught it if the
    # sibling test above had not happened to build its fixture with `ci_test`. EVERY task
    # shipped before 2026-08-20 carries ci_test rows and nothing else; dropping the retired
    # slug from the READER blanks their timelines silently, for the whole history of the
    # board. Renaming what the WRITER emits and narrowing what the READER accepts are two
    # different decisions, and only the first is safe to make on a rename.
    task = probe_task
    add_ci_action(task, event_slug: "ci_test", at: @anchor + 27.minutes)

    assert_equal 420, Task::TestingPhases.build(task).dig("phases", "ci", "seconds"),
                 "a task whose CI rows predate the shard rename must still render its CI phase"
  end

  test "[unit] review starts at the earliest G2 lane when both review gates ran" do
    task = probe_task
    open_review_gate(task, key: "g2a_primary", at: @anchor + 26.minutes)
    open_review_gate(task, key: "g2b_light",   at: @anchor + 22.minutes)

    review = Task::TestingPhases.build(task).dig("phases", "review")
    assert_equal "gate_run", review["source"]
    assert_equal 660, review["seconds"], "the earlier lane (g2b at +22m) IS review start"
  end

  test "[unit] review falls back to the review intent when no gate runs exist" do
    task = probe_task
    add_event(task, kind: "intent", to_stage: "reviewed", at: @anchor + 23.minutes)

    review = Task::TestingPhases.build(task).dig("phases", "review")
    assert_equal "intent", review["source"]
    assert_equal 600, review["seconds"], "reviewer-select intent -> reviewed"
  end

  test "[unit] a completed legacy review falls back to the submitted transition" do
    review = Task::TestingPhases.build(probe_task).dig("phases", "review")

    assert_equal "transition", review["source"], "no gate run, no intent, reviewed landed -> v1 semantics"
    assert_equal "completed", review["status"]
    assert_equal 780, review["seconds"], "submitted -> reviewed keeps its measured window on the version bump"
  end

  test "[unit] a submitted task with no review evidence reports review missing" do
    task = Task.create!(title: "Queued Review Probe")
    add_event(task, kind: "transition", to_stage: "building",  at: 50.minutes.ago)
    add_event(task, kind: "transition", to_stage: "submitted", at: 40.minutes.ago)
    task.update_columns(stage: "submitted") # rubocop:disable Rails/SkipsModelValidations

    review = Task::TestingPhases.build(task).dig("phases", "review")
    assert_equal "missing", review["status"], "queue time is the visible gap, not a fake review window"
    assert_nil review["started_at"]
  end

  test "[unit] ci spans the submission handoff until captured checks settle" do
    task = probe_task
    add_ci_action(task, event_slug: "ci_lint", at: @anchor + 25.minutes)
    add_ci_action(task, event_slug: "ci_test", at: @anchor + 27.minutes)

    ci = Task::TestingPhases.build(task).dig("phases", "ci")
    assert_equal "completed", ci["status"]
    assert_equal "ci_approx", ci["source"]
    assert_equal (@anchor + 20.minutes).iso8601, ci["started_at"], "CI starts at the submitted handoff"
    assert_equal 420, ci["seconds"], "handoff (+20m) -> latest CI action (+27m)"
  end

  test "[unit] ci prefers the real GitHub workflow-run window over the ingest approximation" do
    task = probe_task # submitted at @anchor + 20m
    # Two CI jobs whose REAL completedAt is +26m/+28m, but whose INGEST occurred_at is
    # a late +50m — proving ci_phase spans on the real completedAt, not the ingest time.
    add_real_ci_action(task, event_slug: "ci_lint", started_at: @anchor + 22.minutes,
                       completed_at: @anchor + 26.minutes, occurred_at: @anchor + 50.minutes)
    add_real_ci_action(task, event_slug: "ci_test", started_at: @anchor + 22.minutes,
                       completed_at: @anchor + 28.minutes, occurred_at: @anchor + 50.minutes)

    ci = Task::TestingPhases.build(task).dig("phases", "ci")
    assert_equal "ci", ci["source"], "real GitHub bounds present -> real source, not ci_approx"
    assert_equal "completed", ci["status"]
    assert_equal (@anchor + 20.minutes).iso8601, ci["started_at"], "still the submitted handoff (v2 window start)"
    assert_equal (@anchor + 28.minutes).iso8601, ci["completed_at"],
                 "real completedAt = settle end, NOT the +50m ingest occurred_at"
    assert_in_delta 480, ci["seconds"], 1, "submitted (+20m) -> real settle (+28m)"
  end

  test "[unit] ci real window falls back to the earliest workflow start when no submitted transition" do
    task = Task.create!(title: "Backfilled CI Probe")
    @anchor = 60.minutes.ago
    add_event(task, kind: "transition", to_stage: "building", at: @anchor)
    # No submitted transition (a backfilled history), but real CI bounds exist.
    add_real_ci_action(task, event_slug: "ci_test", started_at: @anchor + 30.minutes,
                       completed_at: @anchor + 35.minutes, occurred_at: @anchor + 50.minutes)
    task.update_columns(stage: "reviewed") # rubocop:disable Rails/SkipsModelValidations

    ci = Task::TestingPhases.build(task).dig("phases", "ci")
    assert_equal "ci", ci["source"]
    assert_equal (@anchor + 30.minutes).iso8601, ci["started_at"], "no submitted -> earliest real workflow start"
    assert_equal (@anchor + 35.minutes).iso8601, ci["completed_at"]
    assert_equal 300, ci["seconds"], "earliest real start -> latest real settle"
  end

  test "[unit] a task sitting in submitted with no CI evidence ticks in_progress" do
    task = Task.create!(title: "Open Handoff Probe")
    add_event(task, kind: "transition", to_stage: "building",  at: 50.minutes.ago)
    add_event(task, kind: "transition", to_stage: "submitted", at: 40.minutes.ago)
    task.update_columns(stage: "submitted") # rubocop:disable Rails/SkipsModelValidations

    ci = Task::TestingPhases.build(task).dig("phases", "ci")
    assert_equal "in_progress", ci["status"], "the handoff window stays open while the task sits submitted"
    assert_in_delta 2400, ci["seconds"], 5
  end

  test "[unit] a task that left submitted with no CI evidence reports ci missing" do
    ci = Task::TestingPhases.build(probe_task).dig("phases", "ci")

    assert_equal "missing", ci["status"],
                 "legacy tasks recompute cleanly — no eternal in_progress CI after the version bump"
  end

  test "[unit] an unfinished phase reports in_progress measured against now" do
    task = Task.create!(title: "Open Cert Probe")
    add_event(task, kind: "transition", to_stage: "building", at: 20.minutes.ago)
    add_event(task, kind: "checkpoint", to_stage: "cert", status: "started", at: 10.minutes.ago)

    cert = Task::TestingPhases.build(task).dig("phases", "local_certification")
    assert_equal "in_progress", cert["status"]
    assert_in_delta 600, cert["seconds"], 5, "roughly ten minutes of open cert"
  end

  test "[unit] refresh! persists the projection at the current version" do
    Task::TestingPhases.refresh!(task = probe_task)
    task.reload

    assert_equal Task::TestingPhases::VERSION, task.testing_phases_version
    assert task.testing_phases_cached_at.present?
    assert_equal 300, task.testing_phases.dig("phases", "local_certification", "seconds")
  end

  # The VERSION 2 self-heal: a v1 row (five phases, review anchored to submitted)
  # rebuilds with v2 boundaries the first time it is read — no backfill required.
  test "[unit] cached_or_built rebuilds a stale v1 projection to v2 boundaries" do
    task = probe_task
    open_review_gate(task, at: @anchor + 22.minutes)
    task.update_columns( # rubocop:disable Rails/SkipsModelValidations
      testing_phases_version: 1,
      testing_phases: { "cache_version" => 1, "phases" => {
        "review" => { "status" => "completed", "seconds" => 780, "source" => "transition" },
        "acceptance" => { "status" => "completed", "seconds" => 300, "source" => "approval" }
      } }
    )

    rebuilt = Task::TestingPhases.cached_or_built(task.reload)
    assert_equal Task::TestingPhases::VERSION, rebuilt["cache_version"]
    refute rebuilt["phases"].key?("acceptance"), "the v1 acceptance window does not survive the rebuild"
    assert_equal "gate_run", rebuilt.dig("phases", "review", "source")
    assert_equal 660, rebuilt.dig("phases", "review", "seconds"), "review re-anchors to actual review start"
  end

  test "[unit] approval_approved_at is stamped when approval flips to approved" do
    task = Task.create!(title: "Approval Stamp Probe")
    assert_nil task.devops["approval_approved_at"]

    task.update!(metadata: task.metadata.deep_merge("devops" => { "approval_status" => "approved" }))

    assert task.reload.devops["approval_approved_at"].present?,
           "the operator-acceptance stamps survive v2 — they just no longer project as a phase"
  end

  # Fix (review): the after_commit refresh must NOT fire on metadata churn that
  # can't move a phase window — e.g. the statusline heartbeat rewriting claim_*.
  test "[unit] a heartbeat-style metadata change does not rebuild the projection" do
    task = probe_task
    task.update_columns(testing_phases: { "sentinel" => true }, testing_phases_version: 99)

    task.update!(metadata: task.metadata.deep_merge("devops" => {
      "claim_nonce" => "beef", "claim_expires_at" => 5.minutes.from_now.iso8601
    }))

    task.reload
    assert_equal 99, task.testing_phases_version, "heartbeat/claim churn must NOT rebuild"
    assert_equal({ "sentinel" => true }, task.testing_phases)
  end

  # Fix (review): cached_or_built must never re-raise into a render — a failed
  # build returns a safe all-missing projection, not the same failing call.
  test "[unit] cached_or_built returns a safe empty projection when build fails" do
    task = probe_task
    task.update_columns(testing_phases_version: 0) # force the build path

    Task::TestingPhases.stub(:build, ->(*) { raise "boom" }) do
      result = Task::TestingPhases.cached_or_built(task.reload)
      assert_equal Task::TestingPhases::VERSION, result["cache_version"]
      assert_equal "missing", result.dig("phases", "build", "status"), "degrades to all-missing, no raise"
    end
  end

  # Drive the REAL write paths a producer uses — stage transitions, cert checkpoints
  # (record_checkpoint_event, what the API + bin/full-suite-check call), the review
  # intent (bin/reviewer-select), and the G2 gate run (the review supervisor) — and
  # confirm they flow through build + the persisted projection.
  test "[integration] real write paths populate the projection through the database" do
    task = Task.create!(title: "Producer Flow Probe")
    task.update!(stage: "building")
    task.record_checkpoint_event(name: "cert", status: "started")
    task.record_checkpoint_event(name: "cert", status: "completed")
    task.update!(stage: "submitted")
    task.record_intent_event(to_stage: "reviewed", reviewers: %w[carl shannon])
    GateRun.open!(subject_type: "task", subject_slug: task.slug, key: "g2a_primary", actor: "carl")
    task.update!(stage: "reviewed")

    phases = Task::TestingPhases.build(task.reload).fetch("phases")
    assert_equal "completed", phases.dig("local_certification", "status"), "cert start+finish paired"
    assert_equal "completed", phases.dig("review", "status"), "review start -> reviewed"
    assert_equal "gate_run", phases.dig("review", "source"), "the gate run outranks the intent"
    assert_equal "missing", phases.dig("ci", "status"), "left submitted with no captured CI evidence"
    refute phases.key?("acceptance"), "no acceptance phase on the v2 projection"

    task.refresh_testing_phases!
    reloaded = Task.find_by!(slug: task.slug)
    assert_equal Task::TestingPhases::VERSION, reloaded.testing_phases_version
    assert_equal "completed", reloaded.testing_phases.dig("phases", "review", "status"),
                 "the persisted projection round-trips through the DB"
  end

  # ---- block bounces must not become the Build span's START ---------------------
  #
  # MEASURED on production 2026-09-05: 322 tasks carry a post-`designed` `-> building`
  # transition, and 238 of them (14% of the whole board) had a STORED build span whose
  # start was AFTER its finish, seconds clamped to 0 by the `[x, 0].max` in
  # #seconds_between. The remaining 84 are the tasks with no cert checkpoint: those are
  # not inverted, they are silently WORSE -- the span measures the rework window and
  # calls it Build. Two damage shapes, and only one of them is visible as an inversion.

  test "[unit] a block bounce does not become the Build span's start" do
    # The headline: bounce AFTER the cert ran. finish (first cert start) sits BEFORE the
    # block, so the unfixed reader pairs a later start with an earlier finish.
    task = probe_task
    add_block(task, at: @anchor + 40.minutes)
    add_event(task, kind: "transition", to_stage: "submitted", at: @anchor + 50.minutes)

    build = Task::TestingPhases.build(task).dig("phases", "build")

    assert_equal 600, build["seconds"], "build claim -> first cert start, unchanged by the bounce"
    assert_equal (@anchor).iso8601, build["started_at"], "the START is the builder's claim, not the block"
    assert_operator Time.zone.parse(build["started_at"]), :<=, Time.zone.parse(build["completed_at"]),
                    "a span must never start after it finishes"
  end

  test "[unit] a block bounce with no cert checkpoint still starts at the build claim" do
    # The 84-task shape. With no cert, finish falls back to the LAST `-> submitted`,
    # which sits AFTER the block -- so the span is not inverted and the ordering guard
    # alone cannot see anything wrong. Only the `blocked` marker separates them.
    task = Task.create!(title: "Uncertified Bounce Probe")
    anchor = 60.minutes.ago
    add_event(task, kind: "transition", to_stage: "building",  at: anchor)
    add_event(task, kind: "transition", to_stage: "submitted", at: anchor + 20.minutes)
    add_block(task, at: anchor + 30.minutes)
    add_event(task, kind: "transition", to_stage: "submitted", at: anchor + 45.minutes)

    build = Task::TestingPhases.build(task).dig("phases", "build")

    assert_equal anchor.iso8601, build["started_at"], "the builder's claim, not the blocker's bounce"
    assert_equal 45.minutes.to_i, build["seconds"], "claim -> the resubmission that closed the build"
  end

  test "[unit] an UNMARKED post-finish -> building transition is still not the start" do
    # Every one of the 238 corrupted rows predates the `blocked` marker (PR #1214), so
    # block_transition? answers false for all of them and the marker filter alone repairs
    # NOTHING historical. The ordering guard is what reaches them: an event that lands
    # after the span already finished cannot be that span's start, whatever wrote it.
    task = probe_task
    task.task_events.create!(kind: "transition", from_stage: "submitted", to_stage: "building",
                             occurred_at: @anchor + 40.minutes, seconds_in_from: nil,
                             source: "test", actor: "carl", metadata: {})
    add_event(task, kind: "transition", to_stage: "submitted", at: @anchor + 50.minutes)

    build = Task::TestingPhases.build(task).dig("phases", "build")

    assert_equal 600, build["seconds"], "legacy bounce, no marker -- the ordering guard still holds"
    assert_equal (@anchor).iso8601, build["started_at"]
  end

  test "[unit] the ordinary build claim is still the Build span's start" do
    # The over-broad direction. A filter that rejected EVERY `-> building` event passes
    # every assertion above and destroys the ordinary path for all 1,668 tasks.
    build = Task::TestingPhases.build(probe_task).dig("phases", "build")

    assert_equal "completed", build["status"], "no bounce in the trail: the claim still starts the span"
    assert_equal 600, build["seconds"]
    assert_equal (@anchor).iso8601, build["started_at"]
  end

  test "[unit] a builder re-claim after the bounce wins over the earlier claim" do
    # A genuine `-> building` transition recorded AFTER a block (a second builder taking
    # the desk while the task sits in the build lane) is a claim, not a block: it carries
    # no marker and it precedes the finish, so both guards pass it through.
    task = Task.create!(title: "Reclaim After Bounce Probe")
    anchor = 90.minutes.ago
    add_event(task, kind: "transition", to_stage: "building",  at: anchor)
    add_event(task, kind: "transition", to_stage: "submitted", at: anchor + 10.minutes)
    add_block(task, at: anchor + 20.minutes)
    task.task_events.create!(kind: "transition", from_stage: "designed", to_stage: "building",
                             occurred_at: anchor + 30.minutes, seconds_in_from: nil,
                             source: "test", actor: "shannon", metadata: {})
    add_event(task, kind: "checkpoint", to_stage: "cert", status: "started", at: anchor + 50.minutes)

    build = Task::TestingPhases.build(task).dig("phases", "build")

    assert_equal (anchor + 30.minutes).iso8601, build["started_at"], "the LAST real claim before the finish"
    assert_equal 20.minutes.to_i, build["seconds"]
  end

  test "[integration] a real Task#block! bounce leaves a non-inverted stored span" do
    # End to end through the real writers: Task#block! writes the `-> building`
    # transition and its `blocked` marker, and the TaskEvent after_create_commit
    # refreshes the stored projection. The COLUMN is what 238 tasks are carrying.
    base = Time.zone.local(2026, 6, 22, 9, 0, 0)
    task = travel_to(base) { Task.create!(title: "Bounce Persistence Probe") }
    travel_to(base + 1.minute)  { task.update!(stage: "building") }
    travel_to(base + 11.minutes) { task.record_checkpoint_event(name: "cert", status: "started") }
    travel_to(base + 16.minutes) { task.record_checkpoint_event(name: "cert", status: "completed") }
    travel_to(base + 20.minutes) { task.update!(stage: "submitted") }
    travel_to(base + 40.minutes) { task.block!(by: "carl", kind: "rework") }

    bounce = task.task_events.transitions.chronological.last
    assert_equal "building", bounce.to_stage
    assert bounce.block_transition?, "Task#block! must stamp the marker this fix reads"

    travel_to(base + 55.minutes) { task.update!(stage: "submitted") }
    stored = Task.find_by!(slug: task.slug).testing_phases.dig("phases", "build")

    assert_equal "completed", stored["status"]
    assert_operator Time.zone.parse(stored["started_at"]), :<=, Time.zone.parse(stored["completed_at"]),
                    "the STORED span is what the board reads; it must not be inverted"
    refute_equal bounce.occurred_at.iso8601, stored["started_at"], "the blocker's bounce is not the build start"
    assert_equal 600, stored["seconds"], "build claim -> first cert start, measured across the bounce"
  end

  test "[integration] a stale stored projection is rebuilt rather than served" do
    # Criterion 3. Every one of the 238 corrupted rows was written by the OLD reader and
    # is not repaired by fixing the reader. The VERSION bump is the invalidation: a row
    # stamped at an older version is ignored on read and rebuilt, and backfill! rewrites
    # the column so the direct-SQL readers (Review::DurationRoll) see repaired data too.
    task = probe_task
    add_block(task, at: @anchor + 40.minutes)
    add_event(task, kind: "transition", to_stage: "submitted", at: @anchor + 50.minutes)
    corrupt = { "cache_version" => Task::TestingPhases::VERSION - 1, "cached_at" => @anchor.iso8601,
                "phases" => { "build" => { "status" => "completed", "seconds" => 0,
                                           "started_at" => (@anchor + 40.minutes).iso8601,
                                           "completed_at" => (@anchor + 10.minutes).iso8601,
                                           "source" => "transition" } } }
    task.update_columns(testing_phases: corrupt, # rubocop:disable Rails/SkipsModelValidations
                        testing_phases_version: Task::TestingPhases::VERSION - 1)

    served = Task::TestingPhases.cached_or_built(Task.find_by!(slug: task.slug))
    assert_equal 600, served.dig("phases", "build", "seconds"), "a stale row is rebuilt, never served"

    Task::TestingPhases.backfill!
    rewritten = Task.find_by!(slug: task.slug)
    assert_equal Task::TestingPhases::VERSION, rewritten.testing_phases_version
    assert_equal 600, rewritten.testing_phases.dig("phases", "build", "seconds"),
                 "backfill repairs the COLUMN, not just the read"
  end

  test "[unit] a projection stamped at cache_version 2 is never served" do
    # The VERSION bump IS criterion 3's invalidation, and nothing else in the diff makes
    # it load-bearing: all 238 corrupted production rows are stamped cache_version 2 --
    # written by the reader that took a block as the build claim. Reverting the bump puts
    # every one of them back on the board, silently, with a fixed reader sitting behind it.
    task = probe_task
    add_block(task, at: @anchor + 40.minutes)
    add_event(task, kind: "transition", to_stage: "submitted", at: @anchor + 50.minutes)
    task.update_columns( # rubocop:disable Rails/SkipsModelValidations
      testing_phases: { "cache_version" => 2, "cached_at" => @anchor.iso8601,
                        "phases" => { "build" => { "status" => "completed", "seconds" => 0,
                                                   "started_at" => (@anchor + 40.minutes).iso8601,
                                                   "completed_at" => (@anchor + 10.minutes).iso8601,
                                                   "source" => "transition" } } },
      testing_phases_version: 2
    )

    served = Task::TestingPhases.cached_or_built(Task.find_by!(slug: task.slug))

    assert_operator Task::TestingPhases::VERSION, :>, 2, "the bump is what invalidates the corrupted rows"
    assert_equal 600, served.dig("phases", "build", "seconds"), "a v2 row is rebuilt, never served"
  end

  # ---- a review gate cannot open a window that already closed --------------------
  #
  # The sibling of the Build-span defect above, one phase over, and DEMONSTRATED BY THE
  # REVIEW THAT FOUND IT: recording PR #1220's own G2 lanes wrote a g2a_primary gate run
  # at 07:11:35Z against a `-> reviewed` transition at 07:09:46Z, inverting that task's
  # own review span. MEASURED on production 2026-09-05: 24 of 1,672 stored review spans
  # were inverted (seconds clamped to 0 by #seconds_between), 19 of them sitting inside
  # Review::DurationRoll's live 250-row candidate pool -- which is entirely version 2, so
  # a 0-second "review" is being averaged into the /deployments card TODAY, as though it
  # happened. That pool reads the jsonb directly with no version check, which is why this
  # fix needs a post-deploy backfill and not just the VERSION bump.

  test "[unit] a review gate opened after the reviewed transition does not start the Review span" do
    # The headline regression. reviewed lands at +33m; the gate run opens at +40m.
    task = probe_task
    open_review_gate(task, at: @anchor + 40.minutes)

    review = Task::TestingPhases.build(task).dig("phases", "review")

    assert_operator Time.zone.parse(review["started_at"]), :<=, Time.zone.parse(review["completed_at"]),
                    "the review span must never start after it finished"
    refute_equal "gate_run", review["source"], "a gate opened after `reviewed` is not this review's start"
    assert_equal "transition", review["source"], "it falls to the next rung of the cascade, not to nothing"
    assert_equal 780, review["seconds"], "submitted -> reviewed, the honest legacy window"
  end

  test "[unit] the ordinary gate-run start still opens the Review span" do
    # THE OVER-BROAD DIRECTION. A guard that dropped every gate run would satisfy the
    # headline criterion above and destroy the measurement this phase exists for.
    task = probe_task
    open_review_gate(task, at: @anchor + 22.minutes)

    review = Task::TestingPhases.build(task).dig("phases", "review")
    assert_equal "gate_run", review["source"], "an on-time gate run is still the start"
    assert_equal 660, review["seconds"], "gate start -> reviewed, unchanged by the guard"
  end

  test "[unit] an in-flight review with no reviewed transition still starts at its gate run" do
    # The ceiling is nil while review is in flight, and a nil ceiling admits everything.
    # A guard demanding a finish to compare against would blank every live review.
    task = Task.create!(title: "In Flight Review Probe")
    add_event(task, kind: "transition", to_stage: "building",  at: 50.minutes.ago)
    add_event(task, kind: "transition", to_stage: "submitted", at: 40.minutes.ago)
    task.update_columns(stage: "submitted") # rubocop:disable Rails/SkipsModelValidations
    open_review_gate(task, at: 30.minutes.ago)

    review = Task::TestingPhases.build(task).dig("phases", "review")
    assert_equal "in_progress", review["status"], "a live review still measures against now"
    assert_equal "gate_run", review["source"]
    assert_in_delta 1800, review["seconds"], 5
  end

  test "[unit] a gate opened in the same second as the merge is still the start" do
    # The ceiling is INCLUSIVE (<=), matching #last_build_claim. A strict `<` would drop
    # the one gate run whose start is exactly the finish -- equal is not inverted.
    task = probe_task
    open_review_gate(task, at: @anchor + 33.minutes)

    review = Task::TestingPhases.build(task).dig("phases", "review")
    assert_equal "gate_run", review["source"], "start == finish is a zero-length window, not an inverted one"
    assert_equal 0, review["seconds"]
  end

  test "[unit] a late lane leaves an earlier on-time lane as the Review start" do
    # The guard filters CANDIDATES, it does not reject the gate_run rung wholesale.
    task = probe_task
    open_review_gate(task, key: "g2b_light",   at: @anchor + 22.minutes)
    open_review_gate(task, key: "g2a_primary", at: @anchor + 40.minutes)

    review = Task::TestingPhases.build(task).dig("phases", "review")
    assert_equal "gate_run", review["source"]
    assert_equal 660, review["seconds"], "the on-time lane survives its late sibling"
  end

  test "[unit] a late gate run falls to the review intent rather than blanking the phase" do
    task = probe_task
    add_event(task, kind: "intent", to_stage: "reviewed", at: @anchor + 23.minutes)
    open_review_gate(task, at: @anchor + 40.minutes)

    review = Task::TestingPhases.build(task).dig("phases", "review")
    assert_equal "intent", review["source"], "the cascade continues past a rejected gate run"
    assert_equal 600, review["seconds"]
  end

  test "[unit] a review intent recorded after the merge is not the Review start either" do
    # The intent rung carries its OWN ceiling. bin/reviewer-select writes the intent, and
    # a re-selection after the merge lands one exactly as late as the gate run -- so
    # guarding only the gate run would move the inversion down a rung instead of fixing it.
    task = probe_task
    add_event(task, kind: "intent", to_stage: "reviewed", at: @anchor + 40.minutes)
    open_review_gate(task, at: @anchor + 45.minutes)

    review = Task::TestingPhases.build(task).dig("phases", "review")
    assert_equal "transition", review["source"], "both late markers rejected, the cascade continues"
    assert_equal 780, review["seconds"], "submitted -> reviewed, still not inverted"
  end

  test "[unit] a review whose every start marker postdates the finish reports missing" do
    # The honest end of the cascade. `missing` carries no seconds, so Review::DurationRoll
    # drops the row instead of averaging in a 0-second review.
    task = Task.create!(title: "All Markers Late Probe")
    add_event(task, kind: "transition", to_stage: "building",  at: @anchor = 60.minutes.ago)
    add_event(task, kind: "transition", to_stage: "reviewed",  at: @anchor + 33.minutes)
    add_event(task, kind: "transition", to_stage: "submitted", at: @anchor + 45.minutes)
    open_review_gate(task, at: @anchor + 40.minutes)

    review = Task::TestingPhases.build(task).dig("phases", "review")
    assert_equal "missing", review["status"], "no start marker precedes the finish"
    assert_nil review["started_at"]
    assert_nil review["seconds"], "a missing window contributes nothing to the review average"
  end

  test "[integration] a review gate landing after the stage move refreshes the stored review span" do
    # The staleness half. The projection refreshed on a stage change and on a TaskEvent,
    # but a GateRun is neither -- so a review lane opening after the task had already
    # moved left the STORED span wrong until an unrelated later stage change rebuilt it
    # (1 production task standing wrong when measured on 2026-09-05 — small today, and
    # the hole reopens on every late gate, which is how PR #1220 inverted its own span).
    task = Task.create!(title: "Late Gate Refresh Probe")
    task.update!(stage: "building")
    task.update!(stage: "submitted")
    task.update!(stage: "reviewed")

    stored = Task.find_by!(slug: task.slug).testing_phases.dig("phases", "review")
    assert_equal "transition", stored["source"], "no gate run yet -> the legacy rung"

    reviewed_at = task.task_events.where(to_stage: "reviewed").last.occurred_at
    GateRun.open!(subject_type: "task", subject_slug: task.slug, key: "g2a_primary",
                  actor: "carl", now: reviewed_at - 5.minutes)

    refreshed = Task.find_by!(slug: task.slug).testing_phases.dig("phases", "review")
    assert_equal "gate_run", refreshed["source"], "the gate write refreshed the phase it feeds"
    assert_equal 300, refreshed["seconds"], "and the STORED column carries the corrected span"
  end

  test "[integration] a non-review gate does not rebuild the testing-phase projection" do
    # THE OVER-BROAD DIRECTION on the refresh side. Refreshing on EVERY gate write would
    # pass the test above while making g1_cert/dor writes pay for a recompute that cannot
    # change an answer -- REVIEW_GATE_KEYS are the only gates any phase reads.
    task = Task.create!(title: "Narrow Refresh Probe")
    task.update!(stage: "building")
    task.update_columns(testing_phases: { "sentinel" => true }) # rubocop:disable Rails/SkipsModelValidations

    GateRun.open!(subject_type: "task", subject_slug: task.slug, key: "g1_cert", actor: "shannon")
    assert_equal({ "sentinel" => true }, Task.find_by!(slug: task.slug).testing_phases,
                 "a cert gate leaves the phase projection alone")

    GateRun.open!(subject_type: "task", subject_slug: task.slug, key: "g2a_primary", actor: "carl")
    refute_equal({ "sentinel" => true }, Task.find_by!(slug: task.slug).testing_phases,
                 "a review gate rebuilds it")
  end

  # --- backfill!: the result must distinguish "nothing to do" from "nothing done" ---
  #
  # backfill! used to return a bare SUCCESS count while its per-task rescue swallowed
  # every failure, so a systematic failure drove the count toward ZERO — the same
  # number an empty board reports. The result now carries attempted/refreshed/skipped
  # so the caller can tell those two apart and abort on the second.

  test "[unit] backfill! reports attempted, refreshed and the skipped slugs" do
    ok    = Task.create!(title: "Backfill Result Ok")
    bad_a = Task.create!(title: "Backfill Result Bad A")
    bad_b = Task.create!(title: "Backfill Result Bad B")
    poisoned = [bad_a.slug, bad_b.slug]

    result = Task::TestingPhases.stub(:refresh!, ->(task, **) { raise "boom" if poisoned.include?(task.slug) }) do
      Task::TestingPhases.backfill!
    end

    population = Task.count
    assert_equal population, result.attempted, "attempted counts the whole population, raise or not"
    assert_equal population - 2, result.refreshed, "only rows that did not raise count as refreshed"
    assert_equal poisoned.sort, result.skipped_slugs.sort, "the skipped rows are NAMED, not just counted"
    assert_equal 2, result.skipped
    assert_includes(Task.pluck(:slug) - result.skipped_slugs, ok.slug)
  end

  test "[unit] backfill! actually rewrites the stored projection to the current VERSION" do
    task = probe_task
    task.update_columns(testing_phases: { "sentinel" => true }, testing_phases_version: 0) # rubocop:disable Rails/SkipsModelValidations

    result = Task::TestingPhases.backfill!

    assert_equal Task.count, result.refreshed, "a clean run refreshes the whole population"
    assert_empty result.skipped_slugs
    stored = Task.find_by!(slug: task.slug)
    assert_equal Task::TestingPhases::VERSION, stored.testing_phases_version,
                 "the column rewrite is the ONLY path that reaches a version-blind reader"
    assert_equal 600, stored.testing_phases.dig("phases", "build", "seconds")
  end

  # --- the shortfall policy (what the rake aborts on) ------------------------

  test "[unit] a run that rewrote nothing on a non-empty board is a shortfall" do
    result = Task::TestingPhases::BackfillResult.new(4, 0, %w[a b c d])

    assert result.no_op?
    refute_nil result.shortfall(allowance: 99), "no allowance can excuse a total no-op"
    assert_match(/refreshed 0 of 4/, result.shortfall(allowance: 99))
  end

  test "[unit] an empty board is complete, not a shortfall" do
    result = Task::TestingPhases::BackfillResult.new(0, 0, [])

    refute result.no_op?, "0 of 0 is a complete run"
    assert_nil result.shortfall(allowance: 0)
  end

  test "[unit] skips within the allowance pass; one more is a shortfall" do
    within = Task::TestingPhases::BackfillResult.new(100, 98, %w[a b])
    beyond = Task::TestingPhases::BackfillResult.new(100, 97, %w[a b c])

    assert_nil within.shortfall(allowance: 2), "isolated poison must not wedge the release"
    assert_match(/skipped 3 of 100/, beyond.shortfall(allowance: 2).to_s)
  end

  test "[unit] the skip allowance is overridable by env for a known-bad row" do
    assert_equal Task::TestingPhases::BACKFILL_SKIP_ALLOWANCE, Task::TestingPhases.backfill_skip_allowance(env: {})
    assert_equal 12, Task::TestingPhases.backfill_skip_allowance(env: { "BACKFILL_MAX_SKIPPED" => " 12 " })
    assert_equal Task::TestingPhases::BACKFILL_SKIP_ALLOWANCE,
                 Task::TestingPhases.backfill_skip_allowance(env: { "BACKFILL_MAX_SKIPPED" => "lots" }),
                 "a garbled override falls back to the default rather than disarming the guard"
  end

  test "[unit] the summary names the skipped rows so a tolerated skip is visible" do
    result = Task::TestingPhases::BackfillResult.new(10, 8, %w[poisoned-a poisoned-b])

    assert_match(/refreshed 8 of 10/, result.summary)
    assert_match(/poisoned-a/, result.summary)
    assert_match(/poisoned-b/, result.summary)
  end
end
