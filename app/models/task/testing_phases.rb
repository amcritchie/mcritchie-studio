# frozen_string_literal: true

class Task
  # Materialized per-task TESTING-PHASE durations — a start→complete window for each
  # phase, denormalized onto the task row (testing_phases jsonb) exactly like
  # Release::DurationCache denormalizes onto releases. A PURE function of the task's
  # append-only TaskEvents + G2 review GateRuns + CI test-scope AgentActions, so
  # recompute is idempotent and self-heals on a VERSION bump (see #cached_or_built).
  #
  # The four phases are TASK-OWNED (individual to the branch, all done by `reviewed`).
  # Release-owned phases (QA, production) are release-grain and inherited by membership
  # — intentionally OUT of this per-task projection. Operator Acceptance left in
  # VERSION 2: it is a release/operator metric, not a testing phase the task owns
  # (the devops approval_requested_at/approval_approved_at stamps remain — they just
  # no longer project as a phase window here).
  #
  # VERSION 4 (2026-09-05): the Review span gets the same ordering guard the Build span
  # got in VERSION 3, one phase over. #review_phase took the FIRST G2 gate run's
  # started_at as the start and the last `reviewed` transition as the finish with nothing
  # holding them in order, so a gate run opened AFTER the task was already `reviewed`
  # started a window that had already closed. It was demonstrated by being CAUSED:
  # recording PR #1220's own G2 lanes wrote a gate run 109s after that task's `reviewed`
  # transition and inverted its own review span.
  #
  # MEASURED on production 2026-09-05: 24 of 1,672 stored review spans were inverted
  # (seconds clamped to 0 by #seconds_between); re-resolving the start moves 25.
  #
  # THE BUMP ALONE IS NOT THE REPAIR, and that is the difference from VERSION 3. Every
  # BUILD-span reader went through #cached_or_built, so the v3 bump invalidated them all,
  # and no LIVE reader ever consumed a build span. 39 of that fix's rows DO sit in the
  # candidate pool below — an earlier draft of this note said 0 of 232, and both halves
  # were wrong — but the pool selects on `{phases,review}` and never reads
  # `{phases,build}`, so the bump alone was a complete repair there. That STRUCTURAL
  # fact, not a row count, is the asymmetry. Review::DurationRoll reads
  # `{phases,review}` DIRECTLY in SQL with no version check, so it would keep serving the
  # stored lie after this deploy: 19 of the 250 rows in its LIVE candidate pool carry a
  # 0-second review, averaged into the /deployments card as though it happened. That pool
  # is ENTIRELY version 2 — this is live corruption of a current number, not old debt. So
  # `rake tasks:backfill_testing_phases` runs post-deploy and is what actually rewrites
  # the column; the bump only stops #cached_or_built serving a stale row in the meantime.
  #
  # THE SECOND HALF is the staleness that let a wrong span sit there: the projection
  # refreshed on a stage change (Task#refresh_testing_phases_after_change) and on a
  # TaskEvent, but a GateRun is NEITHER — so a review gate landing after the stage move
  # never refreshed the phase it feeds. GateRun now does
  # (GateRun#refresh_task_testing_phases). Its measured footprint TODAY is 1 row, and the
  # honest reading of that 1 is forward-looking rather than dismissive: it is the hole
  # that reopens on every late gate, and a late gate is exactly what produced this defect.
  #
  # NOT TO BE CONFUSED WITH THE 380. A separate 380 stored review spans disagree with a
  # fresh recompute, and 379 of them are stamped testing_phases_version = 1 — rows that
  # never rode a backfill through the v1→v2 review redefinition (232 read
  # `transition/completed → intent/completed`, 141 `transition/missing → gate_run/missing`).
  # That is PRE-EXISTING debt, not this bug, and it currently sits outside DurationRoll's
  # pool. The post-deploy backfill clears it in the same pass; it is recorded here so the
  # next reader does not re-attribute those 379 rows to the ordering guard.
  #
  # VERSION 3 (2026-09-05): the Build span no longer starts at a BLOCK. Task#block!
  # bounces a task back onto `building`, and #build_phase took the last such transition
  # as the build claim — so a bounced task's Build window started after it finished (238
  # of 1,668 production tasks, seconds clamped to 0) or silently measured the rework
  # window instead (a further 84, with no cert checkpoint to invert against).
  #
  # The bump is deliberate and is the INVALIDATION for those stored rows: #cached_or_built
  # ignores a row stamped at an older version and rebuilds it, so no reader can serve a
  # corrupted span after deploy. `rake tasks:backfill_testing_phases` then rewrites the
  # column itself — needed because Review::DurationRoll reads this jsonb DIRECTLY in SQL
  # with no version check, so a read-time rebuild alone would leave the column a lie.
  #
  # VERSION 2 (operator design session 2026-07-09): submitted != review-started — PR
  # submission and PR review are different nodes. Review now starts when review work
  # actually begins (G2 gate run, else review intent), and CI owns the submission
  # handoff window review used to swallow. The queue time between CI settling and a
  # reviewer picking the task up is deliberately VISIBLE as the gap between the two
  # windows — that gap is the insight, not a bookkeeping hole.
  module TestingPhases
    VERSION = 4

    PHASE_DEFINITIONS = {
      "build"               => { "label" => "Build" },
      "local_certification" => { "label" => "Local Certification" },
      "ci"                  => { "label" => "CI" },
      "review"              => { "label" => "Review" }
    }.freeze
    PHASE_KEYS = PHASE_DEFINITIONS.keys.freeze

    # The checkpoint NAME bin/full-suite-check bookends the local-certification phase
    # with (record_checkpoint_event name → TaskEvent#to_stage).
    CERT_CHECKPOINT = "cert"
    CERT_FINISHED = %w[completed finished failed].freeze
    # CI test-scope AgentAction slugs (config/devops_test_suites.yml ci_scopes).
    #
    # `ci_rails` covers all four shards of the sharded suite — bin/ci-scope-capture strips
    # the matrix suffix, so `rails (1)`..`rails (4)` all report under it.
    #
    # `ci_static` is the merged brakeman/importmap/rubocop lane (2026-08-20).
    #
    # `ci_test`, `ci_lint`, `ci_scan_ruby` and `ci_scan_js` ARE RETIRED NAMES AND THEY STAY. It was the slug for the monolithic
    # `test` job that the sharded lane replaced on 2026-08-20, and this list is not a
    # description of today's workflow — it is the reader for AgentAction rows that were
    # WRITTEN AT THE TIME. Every task shipped before that date carries `ci_test` rows and
    # nothing else; drop the slug and their timeline's CI phase renders blank, silently,
    # for the whole history of the board.
    #
    # This is exactly the kind of thing a workflow rename takes with it and a test caught
    # by accident: testing_phases_test.rb builds its fixtures with `ci_test`, and the four
    # failures it produced were the only sign that a data-compatibility break was in the
    # diff. Retiring a slug from the WRITER (bin/ci-scope-capture) and from the READER are
    # two different decisions, and only the first one is safe to make on a rename.
    CI_SCOPES = %w[ci_rails ci_rails_executed_set ci_system ci_static ci_lint ci_scan_ruby ci_scan_js ci_test].freeze
    # The task-grain review gates whose first attempt marks actual review start.
    REVIEW_GATE_KEYS = %w[g2a_primary g2b_light].freeze

    # The most INDIVIDUALLY-skipped tasks a full backfill may report and still be
    # called a success. Zero would be stricter, and it is the wrong trade: this
    # backfill runs as a release post-deploy hook, AFTER the code is already live,
    # so an abort there leaves a half-shipped release for a human to unwind. One
    # genuinely poisoned event history must not be able to wedge every future
    # release. Past a handful, a skip is no longer poison — it is systematic (a DB
    # blip mid-run, a column missing after a partial migration), and that DOES
    # abort. Override for a known-bad row with BACKFILL_MAX_SKIPPED=<n>; nothing
    # can override a total no-op (BackfillResult#no_op?).
    BACKFILL_SKIP_ALLOWANCE = 5

    # What a full backfill actually did, as three separate numbers.
    #
    # It used to be ONE number: a success count, incremented only on the happy path
    # by a loop whose per-task `rescue` swallowed everything else. So a systematic
    # failure drove that count DOWN toward zero — the exact same number an empty
    # board reports — and the caller could not tell "nothing to do" from "nothing
    # done". Keeping attempted alongside refreshed is what makes that distinction
    # expressible at all; naming the skipped rows is what makes a tolerated skip
    # visible in the deploy log instead of buried in a Rails logger warning nobody
    # tails during a release.
    BackfillResult = Struct.new(:attempted, :refreshed, :skipped_slugs) do
      def skipped = skipped_slugs.size

      # Did this run rewrite NOTHING it was asked to? The headline failure: every
      # refresh raises, the old count printed 0, the rake exited 0, `heroku run
      # --exit-code` reported success, and the release shipped past a backfill that
      # touched no rows.
      def no_op? = attempted.positive? && refreshed.zero?

      # nil when the run is good enough to ship; otherwise the reason, for the abort.
      def shortfall(allowance:)
        return "refreshed #{refreshed} of #{attempted} task(s) — the backfill rewrote NOTHING" if no_op?
        return nil if skipped <= allowance

        "skipped #{skipped} of #{attempted} task(s), past the allowance of #{allowance} " \
          "(#{named_skips}) — that is systematic, not one poisoned row"
      end

      def summary
        base = "refreshed #{refreshed} of #{attempted} task(s)"
        skipped.zero? ? base : "#{base}; skipped #{skipped} (#{named_skips})"
      end

      # Bounded so a whole-board failure cannot bury the abort reason under 1,600 slugs.
      def named_skips
        shown = skipped_slugs.first(10).join(", ")
        skipped > 10 ? "#{shown}, +#{skipped - 10} more" : shown
      end
    end

    module_function

    # The skip allowance in force, with an operator escape hatch. A garbled value
    # falls back to the default rather than disarming the guard — a typo in a deploy
    # env var must never be the thing that lets a no-op ship.
    def backfill_skip_allowance(env: ENV)
      raw = env["BACKFILL_MAX_SKIPPED"].to_s.strip
      raw.match?(/\A\d+\z/) ? Integer(raw, 10) : BACKFILL_SKIP_ALLOWANCE
    end

    def build(task, now: Time.current)
      task = Task.includes(:task_events).find_by!(slug: task.is_a?(Task) ? task.slug : task)
      now = now.in_time_zone
      events = task.task_events.chronological.to_a
      {
        "cache_version" => VERSION,
        "cached_at" => now.iso8601,
        "phases" => {
          "build"               => build_phase(events, now: now),
          "local_certification" => certification_phase(events, now: now),
          "ci"                  => ci_phase(task, events, now: now),
          "review"              => review_phase(task, events, now: now)
        }
      }
    end

    # Idempotent persist — update_columns skips validations/callbacks (no re-entrancy).
    def refresh!(task, now: Time.current)
      task = Task.find_by!(slug: task) unless task.is_a?(Task)
      metrics = build(task, now: now)
      task.update_columns( # rubocop:disable Rails/SkipsModelValidations
        testing_phases: metrics,
        testing_phases_cached_at: now.in_time_zone,
        testing_phases_version: VERSION,
        updated_at: Time.current
      )
      metrics
    end

    # Serve the cached projection when it matches the current VERSION, else recompute
    # on the fly (self-healing on a version bump — v1 rows rebuild with v2 boundaries
    # the first time they are read, no backfill required). Never raises into a render.
    def cached_or_built(task)
      if task.testing_phases_version == VERSION && task.testing_phases.present?
        task.testing_phases
      else
        build(task)
      end
    rescue StandardError => e
      Rails.logger.warn("[task-testing-phases] projection unavailable for #{task.slug}: #{e.class}: #{e.message}")
      empty_projection
    end

    # A safe, phases-all-missing projection — returned when a live read genuinely
    # can't build (so cached_or_built NEVER re-raises into a render, honoring its
    # contract). The card partial + aggregate already tolerate "missing" windows.
    def empty_projection
      {
        "cache_version" => VERSION,
        "cached_at" => nil,
        "phases" => PHASE_KEYS.index_with do
          { "status" => "missing", "seconds" => nil, "started_at" => nil, "completed_at" => nil, "source" => nil }
        end
      }
    end

    def refresh_recent!(limit: 100, now: Time.current)
      Task.order(updated_at: :desc).limit(limit).map { |task| [task.slug, refresh!(task, now: now)] }.to_h
    end

    # Full backfill — recompute every task's projection from its durable events.
    #
    # Returns a BackfillResult, NOT a bare count. The per-task rescue stays (one
    # unbuildable history must not strand the other 1,600 rows), but it now RECORDS
    # the skip instead of only logging it, so the caller can compare what was done
    # against what was attempted. `lib/tasks/task_testing_phases.rake` is that caller
    # and it aborts on a shortfall; see BACKFILL_SKIP_ALLOWANCE for where the line sits.
    #
    # A failure of the QUERY itself (rather than of one row) still propagates — it is
    # raised outside this rescue, and a backfill that cannot even enumerate its
    # population has nothing honest to report.
    def backfill!(now: Time.current)
      attempted = 0
      refreshed = 0
      skipped = []
      Task.find_each do |task|
        attempted += 1
        refresh!(task, now: now)
        refreshed += 1
      rescue StandardError => e
        skipped << task.slug
        Rails.logger.warn("[task-testing-phases] backfill skipped #{task.slug}: #{e.class}: #{e.message}")
      end
      BackfillResult.new(attempted, refreshed, skipped)
    end

    # ---- per-phase derivations (each returns a span row) ----------------------

    # Build = the build CLAIM → the first cert-started checkpoint (else the `submitted`
    # transition when no cert ran). Implementation + directional testing.
    #
    # The finish is resolved FIRST because it bounds the start: #last_build_claim only
    # considers claims at or before it. A `→ building` event landing after the span has
    # already finished cannot be that span's start, whatever wrote it.
    def build_phase(events, now:)
      finish = first_cert(events, "started") || last_transition_to(events, "submitted")
      start = last_build_claim(events, before: finish&.occurred_at)
      span(start&.occurred_at, finish&.occurred_at, now: now, source: "transition")
    end

    # Local Certification = the cert-started checkpoint → its cert-finished bookend.
    def certification_phase(events, now:)
      start = first_cert(events, "started")
      finish = last_cert_finished(events, after: start&.occurred_at)
      span(start&.occurred_at, finish&.occurred_at, now: now, source: "checkpoint")
    end

    # CI = the submission handoff window: START = the last transition to `submitted`
    # (the builder hands the branch to CI at PR handoff), END = CI settle.
    #
    # END prefers the REAL GitHub workflow-run bounds: bin/ci-scope-capture stamps
    # each captured test-scope action with its actual startedAt (input) + completedAt
    # (output) read from `gh pr checks`, so `finish` = the real max completedAt (the
    # true settle end) with source "ci". LEGACY actions predating that capture keep
    # only duration_ms + ingest occurred_at, so we fall back to the occurred_at
    # approximation with the honest "ci_approx" source. Either way the window is
    # anchored to the submitted handoff; the real completedAt just sharpens its end.
    # A task that already LEFT `submitted` with no captured CI evidence has no
    # measurable window (missing) — so legacy projections recompute cleanly on the
    # version bump instead of ticking in_progress forever.
    def ci_phase(task, events, now:)
      submitted = last_transition_to(events, "submitted")
      actions = ci_actions(task)
      real = ci_real_windows(actions)
      if real.any?
        start = submitted&.occurred_at || real.map(&:first).min
        finish = real.map(&:last).max # real completedAt = the settle end
        return span(start, finish, now: now, source: "ci")
      end

      start = submitted&.occurred_at || approx_ci_start(actions)
      finish = actions.map(&:occurred_at).max
      return span(nil, nil, now: now, source: "ci_approx") if start && finish.nil? && task.stage != "submitted"

      span(start, finish, now: now, source: "ci_approx")
    end

    # Review = when review work ACTUALLY begins → the `reviewed` transition.
    # Submission is not review. START resolves most-durable-evidence first:
    #   1. the first G2 review GateRun (g2a_primary/g2b_light) started_at,
    #   2. else the first review INTENT event (kind=intent toward `reviewed`,
    #      recorded by bin/reviewer-select before any gate run opens),
    #   3. else — LEGACY tasks predating gate runs + intents — the `submitted`
    #      transition, but only once `reviewed` has landed (v1 semantics, so old
    #      completed reviews keep a measured window on the version bump).
    # A submitted task with no review evidence is genuinely MISSING: the queue
    # time shows as the gap after CI, which is exactly the operator's insight.
    # The finish is resolved FIRST because it BOUNDS the start, the same shape #build_phase
    # uses: every candidate below is constrained to `before: ceiling`, so evidence recorded
    # after the review already closed cannot open it. Recording THIS task's own G2 lanes is
    # how the defect was demonstrated — the gate run opened 109s after the `reviewed`
    # transition and inverted the span it was supposed to measure.
    #
    # The guard is a CEILING, never a requirement: `ceiling` is nil for a review still in
    # flight (no `reviewed` transition yet), and a nil ceiling admits everything. A guard
    # that rejected a gate run outright whenever it failed to prove it started early enough
    # would satisfy "never inverted" by measuring nothing — every in-flight review would go
    # missing and every ordinary one would fall through to a weaker source.
    #
    # A candidate failing the ceiling does not blank the phase; it falls to the next rung of
    # the same most-durable-evidence cascade, and only an empty cascade yields "missing".
    # That is the honest answer: a review whose every start marker postdates its own finish
    # has no measurable window, and "missing" drops it from Review::DurationRoll's pool
    # instead of averaging in a 0-second review.
    def review_phase(task, events, now:)
      finish = last_transition_to(events, "reviewed")
      ceiling = finish&.occurred_at
      if (gate = first_review_gate_run(task, before: ceiling))
        span(gate.started_at, ceiling, now: now, source: "gate_run")
      elsif (intent = first_intent_to(events, "reviewed", before: ceiling))
        span(intent.occurred_at, ceiling, now: now, source: "intent")
      elsif finish && (legacy_start = last_transition_to(events, "submitted", before: ceiling))
        span(legacy_start.occurred_at, ceiling, now: now, source: "transition")
      else
        span(nil, ceiling, now: now, source: "gate_run")
      end
    end

    def ci_actions(task)
      AgentAction.where(task_slug: task.slug, event_slug: CI_SCOPES).where.not(occurred_at: nil).to_a
    rescue StandardError
      []
    end

    # Fallback CI start when no `submitted` transition exists but CI evidence does
    # (backfilled histories): earliest (occurred_at − duration) across the jobs.
    def approx_ci_start(actions)
      actions.map { |a| a.occurred_at - (a.duration_ms.to_i / 1000.0) }.min
    end

    # The REAL GitHub workflow-run windows carried on the CI test-scope actions —
    # bin/ci-scope-capture stamps each job's actual startedAt (durable `input`) +
    # completedAt (durable `output`) from `gh pr checks` (AgentAction has no metadata
    # column). Returns [[started, completed], …] for the actions carrying BOTH real
    # bounds — their presence is the real-vs-approx marker. An empty array means only
    # legacy ingest-time actions exist, so ci_phase falls back to the occurred_at
    # approximation. Best-effort: an unparseable stamp drops that action, never raises.
    def ci_real_windows(actions)
      actions.filter_map do |action|
        started = safe_iso8601(action.input)
        completed = safe_iso8601(action.output)
        [started, completed] if started && completed
      end
    end

    def safe_iso8601(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError, TypeError
      nil
    end

    # The first G2 review-gate attempt for the task — retries and the second lane
    # come later by definition, so the first started_at IS review start. `before:` is the
    # ordering ceiling from #review_phase: a lane that opened after the task was already
    # `reviewed` is not this review's start, whatever wrote it. Inclusive (`<=`), matching
    # #last_build_claim — a gate opened in the same second as the merge is not inverted.
    # Best-effort: a gate-run read must never break the projection.
    def first_review_gate_run(task, before: nil)
      scope = GateRun.for_subject("task", task.slug).where(key: REVIEW_GATE_KEYS)
      scope = scope.where(started_at: ..before) if before
      scope.order(:started_at, :id).first
    rescue StandardError
      nil
    end

    # ---- event finders --------------------------------------------------------

    # `before:` is optional everywhere: only #review_phase's legacy rung passes one, and a
    # nil ceiling leaves every existing caller (build, ci) reading exactly as before.
    def last_transition_to(events, stage, before: nil)
      found = events.select { |e| e.transition? && e.to_stage == stage }
      found = found.select { |e| e.occurred_at <= before } if before
      found.last
    end

    # The last `→ building` transition that is a BUILD CLAIM — the event the Build span
    # actually starts at. Two independent guards, because a bounce damages the span in
    # two different shapes and neither guard catches both:
    #
    #   1. #block_transition? — Task#block! lands a bounced task back on `building`, so a
    #      rework block writes a `→ building` transition whose actor is the BLOCKER.
    #      Taking it as the start makes the BLOCKER's bounce open the builder's window.
    #      This is the only guard that reaches a bounce with NO cert checkpoint, where the
    #      finish falls back to the LAST `→ submitted` — after the block, so the span is
    #      not inverted, just silently measuring the rework and calling it Build. 84 tasks
    #      on production carried exactly that shape on 2026-09-05.
    #
    #   2. `before:` — the ordering guard. Every row corrupted before the marker existed
    #      (PR #1214) answers false to #block_transition?, so guard 1 repairs NOTHING
    #      historical. 238 of 1,668 production tasks had a stored build span whose start
    #      was AFTER its finish, seconds clamped to 0 by #seconds_between. Guard 2 reaches
    #      all of them without having to guess WHY the event exists — and guessing is the
    #      trap: inferring a block from `from_stage == "submitted"` alone would also drop
    #      a genuine builder who legitimately pulled a submitted task back.
    #
    # A `→ building` transition recorded after a bounce and before the finish stays a
    # claim: a second builder taking the desk is exactly that, and both guards pass it.
    def last_build_claim(events, before: nil)
      claims = events.select { |e| e.transition? && e.to_stage == "building" && !e.block_transition? }
      claims = claims.select { |e| e.occurred_at <= before } if before
      claims.last
    end

    def first_intent_to(events, stage, before: nil)
      found = events.select { |e| e.intent? && e.to_stage == stage }
      found = found.select { |e| e.occurred_at <= before } if before
      found.first
    end

    def first_cert(events, status)
      events.find { |e| cert_checkpoint?(e) && e.metadata["status"] == status }
    end

    def last_cert_finished(events, after:)
      finished = events.select { |e| cert_checkpoint?(e) && CERT_FINISHED.include?(e.metadata["status"]) }
      finished = finished.select { |e| e.occurred_at >= after } if after
      finished.last
    end

    def cert_checkpoint?(event)
      event.checkpoint? && event.to_stage == CERT_CHECKPOINT
    end

    # ---- span construction ----------------------------------------------------

    def span(started_at, completed_at, now:, source:)
      status =
        if started_at && completed_at then "completed"
        elsif started_at then "in_progress"
        else "missing"
        end
      seconds =
        if started_at && completed_at then seconds_between(started_at, completed_at)
        elsif started_at then seconds_between(started_at, now)
        end
      {
        "status" => status,
        "seconds" => seconds,
        "started_at" => timestamp(started_at),
        "completed_at" => timestamp(completed_at),
        "source" => source
      }
    end

    def seconds_between(from, to)
      return nil unless from && to

      [(to - from).to_i, 0].max
    end

    def timestamp(value)
      value&.iso8601
    end
  end
end
