# frozen_string_literal: true

class Release
  module DurationCache
    VERSION = 1

    STAGE_DEFINITIONS = {
      "building" => {
        "label" => "Building",
        "intent_to" => "building",
        "complete_to" => "submitted",
        "fallback_to" => "building"
      },
      "reviewing" => {
        "label" => "Reviewing",
        "intent_to" => "reviewed",
        "complete_to" => "reviewed",
        "fallback_to" => "submitted"
      },
      "assembled" => {
        "label" => "Assembling",
        "intent_to" => "assembled",
        "complete_to" => "assembled",
        "fallback_to" => "reviewed"
      },
      "shipped" => {
        "label" => "Shipping",
        "intent_to" => "shipped",
        "complete_to" => "shipped",
        "fallback_to" => "assembled"
      }
    }.freeze

    RELEASE_STEP_LABELS = {
      "review_tests" => "Review tests",
      "assemble_release" => "Assemble release",
      "deploy_qa" => "Deploy QA",
      "qa_smoke" => "QA smoke",
      "ship_gate" => "Ship gate",
      "ship_authorized" => "Ship authorized",
      "deploy_prod" => "Deploy production",
      "prod_smoke" => "Production smoke",
      "release_notes" => "Release notes",
      "archive_tasks" => "Archive tasks"
    }.freeze

    # The most INDIVIDUALLY-skipped releases a refresh may report and still be called a
    # success. ZERO — and that is a DELIBERATE divergence from the sibling guard on
    # Task::TestingPhases::BACKFILL_SKIP_ALLOWANCE (5), not a naive copy of it.
    #
    # That backfill walks EVERY task (~1,700 rows), where one unbuildable history is
    # statistically expected and 5 of 1,700 is noise. This refresh walks a set BOUNDED
    # BY `limit` — 3 by default. A flat allowance of 5 would exceed the entire
    # population and forgive a run that rewrote NOTHING through the skip path, which is
    # precisely the defect this guard exists to catch. One skip out of three is a third
    # of the /deployments sample going stale, not noise.
    #
    # The wedge the sibling's allowance answers — one poisoned row blocking every future
    # release, mid-deploy, after the code is already live — is answered here by
    # RECOVERABILITY rather than by a permissive default: an operator steps past a
    # known-bad release with REFRESH_MAX_SKIPPED=<n>. Nothing overrides a total no-op
    # (RefreshResult#no_op?).
    REFRESH_SKIP_ALLOWANCE = 0

    # What a recent-releases refresh actually did, as three separate numbers.
    #
    # It used to be ONE hash, keyed by the releases that SUCCEEDED, and the rake printed
    # its keys and exited 0 regardless. That hash cannot express a shortfall: an empty
    # one reads identically whether nothing was SELECTED (an empty board — fine) or
    # nothing was WRITTEN (every refresh failed — a silent lie the pipeline records
    # GREEN). Carrying `attempted` beside the refreshed slugs is what makes those two
    # distinguishable at all.
    RefreshResult = Struct.new(:attempted, :refreshed_slugs, :skipped_slugs) do
      def refreshed = refreshed_slugs.size
      def skipped = skipped_slugs.size

      # Did this run rewrite NOTHING it selected? The headline failure: the refresh
      # printed an empty list, exited 0, `heroku run --exit-code` reported success, and
      # the release shipped past a hook that touched no rows. `attempted.positive?` is
      # load-bearing — 0 of 0 is a COMPLETE run on a board with no shipped releases
      # (a young board, a QA database), not a no-op.
      def no_op? = attempted.positive? && refreshed.zero?

      # nil when the run is good enough to ship; otherwise the reason, for the abort.
      def shortfall(allowance:)
        return "refreshed #{refreshed} of #{attempted} release(s) — the refresh rewrote NOTHING" if no_op?
        return nil if skipped <= allowance

        "skipped #{skipped} of #{attempted} release(s), past the allowance of " \
          "#{allowance} (#{named_skips})"
      end

      def summary
        base = "refreshed #{refreshed} of #{attempted} release(s)"
        skipped.zero? ? base : "#{base}; skipped #{skipped} (#{named_skips})"
      end

      def named_skips = skipped_slugs.join(", ")
    end

    module_function

    # The skip allowance in force, with an operator escape hatch. A garbled value falls
    # back to the default rather than disarming the guard — a typo in a deploy env var
    # must never be the thing that lets a no-op ship.
    def refresh_skip_allowance(env: ENV)
      raw = env["REFRESH_MAX_SKIPPED"].to_s.strip
      raw.match?(/\A\d+\z/) ? Integer(raw, 10) : REFRESH_SKIP_ALLOWANCE
    end

    def build(release, now: Time.current)
      release = Release.includes(:release_events, tasks: :task_events)
                       .find_by!(slug: release.is_a?(Release) ? release.slug : release)
      now = now.in_time_zone
      tasks = release.tasks.includes(:task_events).order(:position, :created_at).to_a
      task_rows = tasks.map { |task| task_metrics(task, now: now) }
      release_steps = release_step_metrics(release.release_events.chronological.to_a)

      {
        "cache_version" => VERSION,
        "cached_at" => now.iso8601,
        "release" => release_metrics(release, tasks: tasks, now: now),
        "stages" => stage_aggregates(task_rows),
        "release_steps" => release_steps,
        "tasks" => task_rows,
        "integrity" => integrity_metrics(release, tasks, task_rows, release_steps)
      }
    end

    def refresh!(release, now: Time.current)
      release = Release.find_by!(slug: release) unless release.is_a?(Release)
      metrics = build(release, now: now)
      stamp = now.in_time_zone
      release.update_columns( # rubocop:disable Rails/SkipsModelValidations
        duration_metrics: metrics,
        duration_metrics_cached_at: stamp,
        duration_cache_version: VERSION,
        updated_at: Time.current
      )
      metrics
    end

    # Refresh the most recent shipped releases, attempting EACH ONE INDEPENDENTLY.
    # Returns a RefreshResult, NOT a bare hash of the winners.
    #
    # THE DENOMINATOR IS THE SELECTED SET, NOT `limit`. `limit` is a CEILING on
    # #recent_releases, not a demand: a young board — or a QA database — legitimately
    # holds fewer shipped releases than the ceiling. Measuring what was refreshed
    # against `limit` would report "refreshed 2 of 3" on a two-release board and abort
    # the release on a BOARD STATE rather than on a failure, every deploy, forever.
    # `attempted` is therefore what the selection actually returned.
    #
    # The per-release rescue does two things. It makes a shortfall EXPRESSIBLE — a
    # verdict has to be a comparison, and an exception is not one. And it stops the
    # front of the queue starving the rest: the selection is ordered shipped_at DESC, so
    # a poisoned MOST-RECENT release used to raise out of the `map` before releases 2
    # and 3 were ever attempted, and it raised again the same way on every re-run.
    #
    # A failure of the QUERY itself still propagates — it is raised outside this rescue,
    # and a refresh that cannot enumerate its population has nothing honest to report.
    def refresh_recent!(limit: 3, now: Time.current)
      releases = recent_releases(limit: limit).to_a
      refreshed = []
      skipped = []
      releases.each do |release|
        refresh!(release, now: now)
        refreshed << release.slug
      rescue StandardError => e
        skipped << release.slug
        Rails.logger.warn("[release-duration-cache] refresh skipped #{release.slug}: #{e.class}: #{e.message}")
      end
      RefreshResult.new(releases.size, refreshed, skipped)
    end

    def recent_releases(limit: 3)
      Release.where(state: "shipped")
             .order(Arel.sql("COALESCE(shipped_at, created_at) DESC"))
             .limit(limit)
    end

    def dashboard(limit: 3)
      releases = recent_releases(limit: limit).to_a
      metrics = releases.map { |release| cached_or_built(release) }
      {
        "limit" => limit,
        "releases" => releases,
        "averages" => averages_from(metrics),
        "sample_count" => releases.size,
        "generated_at" => Time.current.iso8601
      }
    end

    def averages_from(metrics)
      stage_rows = STAGE_DEFINITIONS.each_key.to_h do |key|
        values = metrics.flat_map { |row| Array(row["tasks"]).filter_map { |task| task.dig("stages", key, "seconds") } }
        [key, average_row(values)]
      end
      deployment_values = metrics.filter_map { |row| row.dig("release", "deployment_seconds") }

      {
        "stages" => stage_rows,
        "deployment" => average_row(deployment_values)
      }
    end

    def cached_or_built(release)
      if release.duration_cache_version == VERSION && release.duration_metrics.present?
        release.duration_metrics
      else
        build(release)
      end
    rescue StandardError => e
      Rails.logger.warn("[release-duration-cache] fallback build failed for #{release.slug}: #{e.class}: #{e.message}")
      build(release)
    end

    def release_metrics(release, tasks:, now:)
      started_at = release.created_at
      assembled_at = release.assembled_at
      confirmed_at = release.confirmed_at
      finished_at = release.shipped_at
      {
        "slug" => release.slug,
        "state" => release.state,
        "started_at" => timestamp(started_at),
        "assembled_at" => timestamp(assembled_at),
        "confirmed_at" => timestamp(confirmed_at),
        "shipped_at" => timestamp(finished_at),
        "assembly_seconds" => seconds_between(started_at, assembled_at),
        "confirmation_seconds" => seconds_between(assembled_at, confirmed_at),
        "shipping_seconds" => seconds_between(confirmed_at, finished_at),
        "deployment_seconds" => seconds_between(started_at, finished_at),
        "live_seconds" => release.active? ? seconds_between(started_at, now) : nil,
        "task_count" => tasks.size,
        "qa_url" => release.qa_url,
        "production_url" => release.production_url,
        "deployed_sha" => release.deployed_sha
      }
    end

    def task_metrics(task, now:)
      events = task.task_events.chronological.to_a
      {
        "slug" => task.slug,
        "title" => task.title,
        "stage" => task.stage,
        "stages" => STAGE_DEFINITIONS.keys.to_h { |key| [key, task_stage_span(task, events, key, now: now)] }
      }
    end

    def task_stage_span(task, events, key, now:)
      definition = STAGE_DEFINITIONS.fetch(key)
      transitions = events.select(&:transition?)
      intents = events.select(&:intent?)
      completion = transitions.select { |event| event.to_stage == definition.fetch("complete_to") }.last
      start = stage_intent(intents, definition, before: completion&.occurred_at) ||
              stage_fallback_transition(transitions, definition, before: completion&.occurred_at)

      if completion && start
        return span_row(
          status: "completed",
          seconds: seconds_between(start.occurred_at, completion.occurred_at),
          started_at: start.occurred_at,
          completed_at: completion.occurred_at,
          source: start.intent? ? "intent" : "transition_fallback",
          actor: start.actor,
          start_event: event_ref(start),
          completion_event: event_ref(completion)
        )
      end

      open_intent = stage_intent(intents, definition)
      if open_intent && !completion
        return span_row(
          status: "in_progress",
          seconds: seconds_between(open_intent.occurred_at, now),
          started_at: open_intent.occurred_at,
          completed_at: nil,
          source: "intent",
          actor: open_intent.actor,
          start_event: event_ref(open_intent),
          completion_event: nil
        )
      end

      span_row(
        status: "missing",
        seconds: nil,
        started_at: start&.occurred_at,
        completed_at: completion&.occurred_at,
        source: start ? "transition_fallback" : nil,
        actor: start&.actor,
        start_event: event_ref(start),
        completion_event: event_ref(completion)
      )
    end

    def stage_intent(intents, definition, before: nil)
      candidates = intents.select { |event| event.to_stage == definition.fetch("intent_to") }
      candidates = candidates.reject { |event| event.metadata["qa"] == true } if definition.fetch("intent_to") == "shipped"
      candidates = candidates.select { |event| event.occurred_at <= before } if before
      candidates.last
    end

    # The transition that opens a stage when no intent recorded it. A BLOCK is never
    # that transition: Task#block! bounces a task back onto `building`, so a rework block
    # writes a `-> building` transition whose actor is the BLOCKER, and taking it here
    # recorded the reviewer who sent the work back as the party who did the Building
    # stage (`span_row(actor: start.actor)`).
    #
    # The reject is unconditional rather than scoped to the `building` fallback because
    # `blocked` can only ever ride a `-> building` transition (Task#block_transition_metadata
    # is keyed on blocked_at moving, and #block! always lands on `building`), so it is a
    # no-op on the other three stages and stays correct if the marker's shape widens.
    #
    # SCOPE, measured on production 2026-09-05: this fallback is not the narrow path it
    # reads as. There are ZERO `intent -> building` rows in the entire ecosystem -- an
    # intent toward `building` is only recordable from `designed` (Task::NEXT_INTENT_STAGE)
    # and nothing writes one -- so #stage_intent returns nil for EVERY task and the
    # Building stage ALWAYS lands here. Only the duration-cache test fixture has ever
    # produced one.
    #
    # Rows written before the marker existed (PR #1214) answer false, so a legacy bounce
    # still names its blocker. Inferring a block from `from_stage` alone would drop a
    # genuine builder who legitimately pulled a submitted task back, which is the worse
    # error; see TaskEvent#block_transition?.
    def stage_fallback_transition(transitions, definition, before: nil)
      candidates = transitions.reject(&:block_transition?)
                              .select { |event| event.to_stage == definition.fetch("fallback_to") }
      candidates = candidates.select { |event| event.occurred_at <= before } if before
      candidates.last
    end

    def release_step_metrics(events)
      RELEASE_STEP_LABELS.keys.to_h do |step|
        rows = events.select { |event| event.step == step }
        start = rows.find(&:started?)
        finish = rows.find do |event|
          next false if event.started?
          next true unless start

          event.occurred_at >= start.occurred_at
        end

        started_at = start&.occurred_at || finish&.occurred_at
        completed_at = finish&.occurred_at
        seconds = if start && finish
                    seconds_between(start.occurred_at, finish.occurred_at)
                  elsif finish
                    0
                  end

        [step, {
          "label" => RELEASE_STEP_LABELS.fetch(step),
          "status" => finish&.status || start&.status || "missing",
          "started_at" => timestamp(started_at),
          "completed_at" => timestamp(completed_at),
          "seconds" => seconds,
          "source" => start ? "bookended" : ("completed_only" if finish),
          "start_event" => event_ref(start),
          "completion_event" => event_ref(finish),
          "event_count" => rows.size
        }]
      end
    end

    def stage_aggregates(task_rows)
      STAGE_DEFINITIONS.each_key.to_h do |key|
        rows = task_rows.map { |task| task.dig("stages", key) }.compact
        completed = rows.select { |row| row["status"] == "completed" && row["seconds"] }
        [key, {
          "label" => STAGE_DEFINITIONS.dig(key, "label"),
          "average_seconds" => average(completed.map { |row| row["seconds"] }),
          "sample_count" => completed.size,
          "missing_count" => rows.count { |row| row["status"] == "missing" },
          "in_progress_count" => rows.count { |row| row["status"] == "in_progress" }
        }]
      end
    end

    def average_row(values)
      values = values.compact
      {
        "average_seconds" => average(values),
        "sample_count" => values.size
      }
    end

    def average(values)
      values = values.compact
      return nil if values.empty?

      (values.sum.to_f / values.size).round
    end

    def integrity_metrics(release, tasks, task_rows, release_steps)
      missing_stage_spans = task_rows.sum do |task|
        task.fetch("stages").values.count { |row| row["status"] == "missing" }
      end
      {
        "release_event_count" => release.release_events.size,
        "task_event_count" => tasks.sum { |task| task.task_events.size },
        "missing_task_stage_spans" => missing_stage_spans,
        "missing_release_steps" => release_steps.values.count { |row| row["status"] == "missing" }
      }
    end

    def span_row(status:, seconds:, started_at:, completed_at:, source:, actor:, start_event:, completion_event:)
      {
        "status" => status,
        "seconds" => seconds,
        "started_at" => timestamp(started_at),
        "completed_at" => timestamp(completed_at),
        "source" => source,
        "actor" => actor,
        "start_event" => start_event,
        "completion_event" => completion_event
      }
    end

    def event_ref(event)
      return nil unless event

      {
        "id" => event.id,
        "kind" => event.respond_to?(:kind) ? event.kind : nil,
        "from_stage" => event.respond_to?(:from_stage) ? event.from_stage : nil,
        "to_stage" => event.respond_to?(:to_stage) ? event.to_stage : nil,
        "step" => event.respond_to?(:step) ? event.step : nil,
        "status" => event.respond_to?(:status) ? event.status : nil,
        "actor" => event.actor,
        "occurred_at" => timestamp(event.occurred_at)
      }.compact
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
