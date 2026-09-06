class Release < ApplicationRecord
  # Workflow 2 — Deploy. A Release is a singleton: at most one is active
  # (assembling/assembled) at a time. It carries `reviewed` tasks onto a
  # disposable release branch, through QA, and to production.
  #   assembling → assembled → shipped   (+ abandoned)
  # The git/merge-queue mechanics live in the conductor tooling (a later task);
  # this model owns the state + the task membership.
  STATES = %w[assembling assembled shipped abandoned].freeze
  ACTIVE_STATES = %w[assembling assembled].freeze
  TERMINAL_STATES = %w[shipped abandoned].freeze

  # The pause between per-member board flips in a BATCH ship — purely an
  # operator-facing cadence, and the ONE place the number lives on the record side
  # (the dev-tools Ship toy passes it; `bin/release ship` mirrors it as its own
  # BOARD_FLIP_CADENCE, because that payload is evaluated by whatever code is
  # DEPLOYED and must not depend on a constant a live prod may predate).
  # ship! defaults to 0 so tests and programmatic callers run at full speed.
  BOARD_FLIP_CADENCE = 0.8

  # The per-repo integration branch. It is now PERSISTENT: every repo keeps a
  # single `release` branch that feature PRs merge INTO (membership flips at
  # merge), QA deploys from, and `ship` fast-forwards into `main`. main is always
  # an ancestor of `release`; on ship it collapses to main and re-accumulates.
  # (Was the disposable `release/<slug>` cut per candidate — see the cutover.)
  BRANCH = "release"

  # --- stage timeline ----------------------------------------------------------
  # The ordered fine-grained stage sequence under the coarse `state` machine. Each
  # stage maps to ONE timestamp column that acts as a time-AND-boolean: stamped =
  # the stage started (or landed), blank = not yet. The /deployments pizza-tracker
  # derives every node's complete/active/pending purely from these stamps, which
  # is what makes the Avi→Steffon QA handoff explicit: `qa_deployed` (Live on QA,
  # 3 green) does NOT imply `confirming` — stage 4 stays dark until Steffon's
  # confirming stamp lands (via the release events API).
  #
  # `current_stage` is MONOTONIC — the LATEST stamped stage wins — so late or
  # out-of-order stamps (e.g. the conductor's post-QA-boot assemble! landing after
  # deploy_qa completed) can never wind the tracker backwards.
  STAGES = [
    ["testing",        :testing_started_at],
    # tested_at is LIVE again: Release::Conductor.qa_green! stamps it (via
    # stamp_stage!) — QA-green IS the tested verdict. Its position here is the
    # LOGICAL stage order, NOT a chronology: assembling_started_at is stamped back
    # at MERGE time (Conductor.sweep!) and qa_deploy_started_at before the QA
    # deploy, so BOTH land before tested_at in wall-clock. That is by design — it
    # is precisely why `current_stage` is MONOTONIC over these stamps. Do NOT drop
    # this column: the `release_timeline` inspection view SELECTs it and projects
    # THIS order (see docs/agents/modules/devops-task-board.md).
    ["tested",         :tested_at],
    ["assembling",     :assembling_started_at],
    ["assembled",      :assembled_at],
    ["qa_deploying",   :qa_deploy_started_at],
    ["qa_deployed",    :qa_deployed_at],
    ["confirming",     :confirming_started_at],
    ["confirmed",      :confirmed_at],
    ["prod_deploying", :prod_deploy_started_at],
    ["shipped",        :shipped_at]
  ].freeze
  STAGE_NAMES = STAGES.map(&:first).freeze
  STAGE_STAMP_COLUMNS = STAGES.to_h { |name, column| [name.to_s, column] }.freeze

  # The one stage an event post may OPEN the slug-less `current` release from:
  # ASSEMBLY START. A candidate is born when qa-release begins assembling (the
  # sweep's current_or_open! / an `assembling` kick-off) — never during the review
  # wave, which runs before any release exists. `testing` used to open here too,
  # which surfaced an empty (0-task) `assembling` release on /deployments minutes
  # before qa-release ran; so a testing/start with no active RC is now a clean 404.
  # Any other (later) stage also requires an already-active release.
  STAGES_THAT_MAY_OPEN = %w[assembling].freeze

  # The stages surfaced as columns on the /deployments table + summary cards. Two
  # shapes:
  #   * stamp-backed — the stage's OWN start→end stamp pair (a span of
  #     Release::STAGES), so the cell shows both timestamps and the duration.
  #   * gate-backed (`gate:`) — the LATEST GateRun attempt of a release-grain
  #     testing gate (G3 Candidate / G4 Ship). Attempt-aware: the span carries
  #     `:success` (fail tint) and `:attempt` (the ×n retry badge), fixing the
  #     old overlap where prepare co-opted the review_tests bracket and "Tested"
  #     started AFTER "Assembled".
  # "Deployed" is the production rollout (prod_deploy_started_at → shipped_at);
  # the end-to-end "Total" (created_at → shipped_at) is #deployment_total_span.
  DEPLOYMENT_STAGES = [
    { key: "assembled",    label: "Assembled",    starts: :assembling_started_at, ends: :assembled_at },
    { key: "g3_candidate", label: "G3 Candidate", gate: "g3_candidate" },
    { key: "g4_ship",      label: "G4 Ship",      gate: "g4_ship" },
    { key: "deployed",     label: "Deployed",     starts: :prod_deploy_started_at, ends: :shipped_at }
  ].freeze

  # How many recently-shipped releases the /deployments summary cards average.
  DEPLOYMENT_DASHBOARD_SAMPLE = 10

  # (release-event step, status) → the stage that boundary stamps. Every write
  # path funnels through record_event! (conductor CLI + the release events API),
  # so posting an event IS the stage notification. `failed` events stamp nothing.
  # deploy_prod completion is deliberately absent: `shipped` is only ever stamped
  # by ship!'s state flip, so a stray API post can't mark a live release shipped.
  # The review_tests → testing/tested mapping stays for event replay + a
  # testing/start posted against an ALREADY-active release (a first-write-wins
  # no-op once assembling has stamped). It no longer OPENS a candidate
  # (STAGES_THAT_MAY_OPEN): node 1 Testing greens on its own the instant the first
  # sweep stamps `assembling` (which is ≥ testing), so no pre-assembly post needed.
  EVENT_STAGE_STAMPS = {
    %w[review_tests started]       => "testing",
    %w[review_tests completed]     => "tested",
    %w[assemble_release started]   => "assembling",
    %w[assemble_release completed] => "assembled",
    %w[deploy_qa started]          => "qa_deploying",
    %w[deploy_qa completed]        => "qa_deployed",
    %w[qa_smoke completed]         => "qa_deployed",
    %w[ship_gate started]          => "confirming",
    %w[ship_authorized started]    => "confirming",
    %w[ship_gate completed]        => "confirmed",
    %w[ship_authorized completed]  => "confirmed",
    %w[deploy_prod started]        => "prod_deploying"
  }.freeze

  # Per-step test-tier ownership for the Deploy workflow (devops-cycle-design
  # §1.2, "Test-tier → step map"). Each tier runs ONCE, at the step that OWNS it —
  # no step re-runs a lower tier a previous step already proved green:
  #   review  → base (unit/component), by the two senior reviewers
  #   prepare → integration + e2e-smoke, by Steffon on origin/release at QA
  #             (the hub registers its FULL suite as qa_test_cmd — the G3 batch
  #             certification that lets G4 self-gate an unchanged SHA)
  #   ship    → full-suite (the registry test_cmd — the repo's highest LOCAL
  #             tier; it was never a browser e2e run, hence the honest relabel
  #             from "e2e-full"), by Steffon on the FROZEN ship SHA. SELF-GATED:
  #             skipped when G3 already certified that exact SHA with that
  #             exact command this run (bin/release test_gate), so the full
  #             suite runs once per release batch; a drifted/straggler SHA
  #             re-triggers it.
  # The ownership is disjoint by construction (a tier maps to exactly one step),
  # which is what makes "runs once" enforceable — see step_owning_tier.
  STEP_TEST_TIERS = {
    "review"  => %w[base],
    "prepare" => %w[integration e2e-smoke],
    "ship"    => %w[full-suite]
  }.freeze

  has_many :tasks, foreign_key: :release_slug, primary_key: :slug, inverse_of: :release
  has_many :release_events, foreign_key: :release_slug, primary_key: :slug, inverse_of: :release, dependent: :destroy
  # Attempt-aware runs of the release-owned testing gates (G3 Candidate, G4
  # Ship) — slug-FK like release_events, scoped to release-grain subjects.
  has_many :gate_runs, -> { where(subject_type: "release") },
           foreign_key: :subject_slug, primary_key: :slug, dependent: :delete_all

  validates :slug, presence: true, uniqueness: true
  validates :state, inclusion: { in: STATES }
  validate :at_most_one_active_release, if: :active?

  before_validation :generate_slug, on: :create
  before_save :set_state_timestamp, if: :state_changed?
  # Live /deployments: re-render the Next + Last release modules to every viewer
  # after ANY release commit (open / assemble / ship / abandon / mascot stamp), so
  # the board's release cards stay current with no reload. after_*_commit (not
  # after_save) so the new singleton state is fully committed before we read
  # Release.current / .last_shipped in the broadcast — and so a rolled-back
  # transaction never broadcasts a state that didn't land.
  after_commit :broadcast_release_modules, on: %i[create update]
  after_commit :refresh_duration_metrics_safely, on: %i[create update]

  scope :active, -> { where(state: ACTIVE_STATES) }

  def to_param
    slug
  end

  # The test tiers a Deploy step OWNS (runs). Unknown step → []. The single
  # source of truth bin/release's per-step gates (prepare's e2e-smoke /up wait,
  # ship's full-e2e gate) are documented against.
  def self.test_tiers_for(step)
    STEP_TEST_TIERS.fetch(step.to_s, [])
  end

  # The one step that OWNS a tier (runs it), or nil. Enforces "each tier runs once
  # at the step that owns it" — a tier maps to exactly one step.
  def self.step_owning_tier(tier)
    STEP_TEST_TIERS.find { |_step, tiers| tiers.include?(tier.to_s) }&.first
  end

  # The current (singleton) active release, if any.
  def self.current
    active.order(created_at: :desc).first
  end

  # The most recently shipped release (for the board's "Last Release" section).
  def self.last_shipped
    where(state: "shipped").order(Arel.sql("COALESCE(shipped_at, created_at) DESC")).first
  end

  # Open a new release candidate. Raises (singleton validation) if one is active.
  # Defaults the integration branch to the persistent `release` (overridable).
  def self.open!(attrs = {})
    create!({ branch: BRANCH }.merge(attrs).merge(state: "assembling"))
  end

  # The active release if one exists, else open a fresh one. The find-or-create
  # the sweep membership path (Conductor#sweep!) leans on so a PR merging
  # into `release` always lands on an active candidate.
  def self.current_or_open!
    current || open!
  end

  def active?
    ACTIVE_STATES.include?(state)
  end

  # --- deployment table spans -------------------------------------------------
  # One /deployments cell: a stage's own start→end span read straight off the
  # stamp columns — or, for a gate-backed stage, off the latest GateRun attempt.
  # status is "completed" (both boundaries), "in_progress" (started, not
  # finished, release still active → the cell ticks a live count-up), or
  # "missing" (never started → the cell reads "—"). Pure column arithmetic, so
  # it is always current (no cache) and the live anchor is real.
  def deployment_stage_span(stage)
    stage = DEPLOYMENT_STAGES.find { |candidate| candidate[:key] == stage.to_s } if stage.is_a?(String) || stage.is_a?(Symbol)
    return deployment_gate_span(stage) if stage[:gate]

    started_at = self[stage.fetch(:starts)]
    ended_at = self[stage.fetch(:ends)]
    deployment_span(stage.fetch(:key), stage.fetch(:label), started_at, ended_at)
  end

  # A gate-backed /deployments cell: the LATEST GateRun attempt of the stage's
  # release-grain gate (retries are first-class — the newest attempt IS the
  # cell). Same span contract as a stamp-backed stage, plus two gate keys:
  #   :success — the attempt's verdict (false → the cell tints red with a ✗;
  #              nil while in flight)
  #   :attempt — the attempt number (> 1 → the ×n retry badge)
  # No run yet → a "missing" dash, like an unstamped column.
  def deployment_gate_span(stage)
    run = latest_gate_run(stage.fetch(:gate))
    span = deployment_span(stage.fetch(:key), stage.fetch(:label), run&.started_at, run&.finished_at)
    span[:success] = run&.success
    span[:attempt] = run&.attempt
    span
  end

  # The newest attempt of a release-grain gate, filtered in Ruby off the
  # gate_runs association so releases#index can `.includes(:gate_runs)` and
  # render every row's G3/G4 cells with no per-release query.
  def latest_gate_run(key)
    gate_runs.select { |run| run.key == key.to_s }.max_by { |run| [run.attempt, run.id] }
  end

  def deployment_stage_spans
    DEPLOYMENT_STAGES.map { |stage| deployment_stage_span(stage) }
  end

  # The end-to-end Total cell: created_at → shipped_at, or created_at → now (live)
  # while the release is still active. Same contract as a stage span.
  def deployment_total_span
    deployment_span("total", "Total", created_at, shipped_at)
  end

  # Every averaging window the UI actually renders. ONE source of truth: the
  # controller reads this to decide which rows to draw, and the end-of-deployment
  # warm reads it to decide which to refresh. They used to be independent — the
  # page drew [3, 10] while the warm only ever refreshed 10 — so within a TTL of a
  # ship the 3-release row excluded the release the 10-release row above it
  # included. Two rows in one table disagreeing about which releases exist.
  RENDERED_AVERAGE_WINDOWS = [3, DEPLOYMENT_DASHBOARD_SAMPLE].freeze

  # Bump when the SHAPE of a stored snapshot changes, so a new reader can never
  # serve a payload the old writer produced.
  DEPLOYMENT_AVERAGES_VERSION = 1

  # Averages each deployment stage (+ Total) over the last N shipped releases —
  # the DevOps card's summary tiles.
  #
  # SIZE THIS HONESTLY. Computing it costs 5-9ms inside a request that takes
  # 1,200-2,000ms (measured on production 2026-08-19): two queries over ten
  # shipped releases. Precomputing it is a SHAPE change — the number only moves
  # when a deployment finishes, so it is computed then rather than by every
  # viewer — and it is worth about 0.4% of the page. Anyone reading this expecting
  # the board to get faster is reading the wrong method; the board's cost was its
  # task scope and its payload.
  #
  # THE SNAPSHOT LIVES IN DEDICATED COLUMNS, and it took two send-backs to get
  # both halves of that right.
  #
  # NOT Rails.cache: in production `ship!` runs on a ONE-OFF dyno (bin/release's
  # conductor shells `heroku run ... rails runner`) and Rails.cache there is a
  # per-dyno FileStore, so a warm written to that dyno's tmp/cache dies with the
  # process and no web dyno ever sees it.
  #
  # NOT the shared `metadata` jsonb either, which was the second attempt: the
  # snapshot was erased FOUR LINES after it was written. Release::Conductor.ship!
  # calls release.ship! (which writes through a freshly-loaded instance) and then
  # stamp_session_mascot on its own now-stale object, whose
  # `update!(metadata: meta)` rewrites the whole blob without the new key. Four
  # writers rewrite that column wholesale; reordering one is whack-a-mole.
  #
  # So: dedicated columns, exactly as Release::DurationCache does it
  # (duration_metrics / duration_metrics_cached_at / duration_cache_version) and
  # immune for exactly the same reason.
  #
  # The snapshot rides the release it was taken FOR — the one just shipped — and
  # the reader takes the newest shipped release's copy, so "the freshest snapshot"
  # needs no separate bookkeeping.
  #
  # READ-THROUGH, deliberately: a missing, version-stale, or unreadable snapshot
  # recomputes rather than rendering blank. That covers a cold database, a shape
  # bump, and the honest limit of this design — a late GateRun stamped on an
  # ALREADY-shipped release is not reflected until the next ship, exactly the
  # tradeoff DurationCache accepts.
  def self.deployment_stage_averages(limit: DEPLOYMENT_DASHBOARD_SAMPLE)
    stored_deployment_stage_averages(limit) || compute_deployment_stage_averages(limit: limit)
  end

  # The snapshot for one window, or nil when there isn't a usable one. Fully
  # rescued: this runs on the PUBLIC, unauthenticated /deployments render, so a
  # malformed payload must degrade to a recompute, never to a 500.
  def self.stored_deployment_stage_averages(limit)
    source = last_shipped
    return nil unless source
    return nil unless source.stage_averages_version == DEPLOYMENT_AVERAGES_VERSION

    window = source.stage_averages[limit.to_s]
    window.is_a?(Hash) && window["stages"].present? ? window : nil
  rescue StandardError => e
    ErrorLog.capture!(e)
    nil
  end

  # Recompute EVERY rendered window and store them on the newest shipped release —
  # the end-of-deployment warm. Windows come from RENDERED_AVERAGE_WINDOWS so the
  # page cannot render a row this never refreshes. Returns the stored windows, or
  # nil when there is no shipped release to hang them on.
  def self.refresh_deployment_stage_averages!(windows: RENDERED_AVERAGE_WINDOWS)
    target = last_shipped
    return nil unless target

    stored = windows.to_h { |window| [window.to_s, compute_deployment_stage_averages(limit: window)] }
    # update_columns, like DurationCache: this is a derived cache, not a state
    # change, and it must not fire callbacks or touch the stage timeline. It also
    # writes ONLY these three columns, so it cannot clobber a concurrent metadata
    # write — and, being its own columns, cannot be clobbered BY one.
    target.update_columns( # rubocop:disable Rails/SkipsModelValidations
      stage_averages: stored,
      stage_averages_cached_at: Time.current,
      stage_averages_version: DEPLOYMENT_AVERAGES_VERSION,
      updated_at: Time.current
    )
    stored
  end

  # The real work. Same span math as the per-row cells, so cards and columns can
  # never disagree.
  def self.compute_deployment_stage_averages(limit: DEPLOYMENT_DASHBOARD_SAMPLE)
    releases = where(state: "shipped")
               .order(Arel.sql("COALESCE(shipped_at, created_at) DESC"))
               .includes(:gate_runs) # the gate-backed spans read the association
               .limit(limit).to_a
    keys = DEPLOYMENT_STAGES.map { |stage| stage[:key] } + ["total"]
    stage_rows = keys.map do |key|
      spans = releases.map { |release| key == "total" ? release.deployment_total_span : release.deployment_stage_span(key) }
      label = key == "total" ? "Total" : DEPLOYMENT_STAGES.find { |stage| stage[:key] == key }.fetch(:label)
      [key, deployment_average_row(label, spans.filter_map { |span| span[:seconds] })]
    end
    { "stages" => stage_rows.to_h, "sample_count" => releases.size }
  end

  def self.deployment_average_row(label, values)
    { "label" => label,
      "average_seconds" => (values.any? ? (values.sum.to_f / values.size).round : nil),
      "sample_count" => values.size }
  end

  # Shared span builder for #deployment_stage_span / #deployment_total_span.
  def deployment_span(key, label, started_at, ended_at)
    status = if started_at && ended_at then "completed"
             elsif started_at && active? then "in_progress"
             else "missing"
             end
    seconds = started_at && ended_at ? [(ended_at - started_at).to_i, 0].max : nil
    { key: key, label: label, started_at: started_at, ended_at: ended_at, seconds: seconds, status: status }
  end

  # --- conductor mascot (the agent working this deployment) -------------------
  # A release wears the Pokémon mascot of the SESSION that ran `bin/release` on
  # it (mirrors Task's per-session mascot). Stored loosely in metadata.devops —
  # `mascot` (slug) + `mascot_session` (the owning session id) — so the board can
  # show who's on the deployment and the same session keeps its face across
  # merge/prepare/ship while a handoff swaps it.

  # The metadata.devops sub-hash, always a Hash (never nil) for safe reads.
  def devops
    raw = metadata.is_a?(Hash) ? metadata["devops"] : nil
    raw.is_a?(Hash) ? raw : {}
  end

  # One devops scalar, or nil when blank/absent.
  def devops_field(key)
    devops[key.to_s].presence
  end

  # The conductor's Pokémon, resolved from the stored mascot slug (nil when
  # unstamped — old releases, or no session — so the card degrades gracefully).
  def mascot
    slug = devops_field("mascot")
    return nil if slug.blank?

    @mascot ||= Pokemon.find_by(slug: slug)
  end

  # Stamp the conductor session's mascot onto the release, drawing/reusing it via
  # SessionMascot.for (the same race-safe lookup tasks use). Idempotent and
  # handoff-aware, mirroring Task#sync_session_mascot: it (re)assigns only when no
  # mascot is set yet OR a DIFFERENT session is now acting — so re-running the
  # conductor in the same session is a no-op, but a handoff swaps the face. A
  # blank session, an unseeded Pokémon table, or a draw that yields nothing all
  # leave the release untouched (no mascot rather than a crash). Returns self.
  def stamp_conductor_mascot!(session_id)
    sid = session_id.to_s.strip
    return self if sid.empty?
    return self unless Pokemon.table_exists?
    return self unless devops_field("mascot").blank? || devops_field("mascot_session") != sid

    slug = SessionMascot.for(sid)&.mascot_slug
    return self unless slug

    meta = (metadata.presence || {}).deep_dup
    d = (meta["devops"] ||= {})
    d["mascot"] = slug
    d["mascot_session"] = sid
    update!(metadata: meta)
    @mascot = nil # bust the memo so a re-read reflects the swap
    self
  end

  # --- production smoke seal --------------------------------------------------
  # The post-ship @qa-readonly verdict (bin/prod-smoke), persisted on the release
  # as the smoke_seal jsonb. The reader rehydrates the raw column into a
  # Release::SmokeSeal value object (nil when unsealed); record_smoke_seal! stores
  # one. Recorded in bin/release step 5c AFTER the deploy + /up gate, BEFORE
  # post_release_notes — so the notes/Discord/board all read the SAME verdict.

  # The seal as a value object, or nil when unsealed. Overrides the AR-generated
  # attribute reader; `self[:smoke_seal]` still reads the raw jsonb underneath.
  def smoke_seal
    Release::SmokeSeal.from_h(self[:smoke_seal])
  end

  def smoke_sealed?
    smoke_seal.present?
  end

  # Persist a Release::SmokeSeal (its {status, summary, checked_at} hash). The
  # after_commit broadcast re-renders the board so the 🟢/🔴 badge appears live.
  def record_smoke_seal!(seal)
    update!(smoke_seal: seal.to_h)
    self
  end

  # Member tasks in PRODUCER-FIRST order: gems (published) before apps
  # (deployed), honoring task `dependencies` within that. This is the order the
  # conductor publishes/deploys in and the order `member_plan` reports.
  def ordered_members
    Release::Ordering.producer_first(tasks.to_a)
  end

  # EVERY repo this release's members name, producer-first and deduped — the set of
  # repos this candidate actually moves.
  #
  # Reads #release_repos (plural) rather than #release_repo, because a two-repo member
  # is "in" BOTH of them; the singular under-reported a multi-repo release exactly as
  # the pipeline under-promoted it (2026-08-13, see Task#release_repos). Two callers
  # share it so they can never disagree about membership: the /deployments per-repo
  # tracker lanes (ApplicationHelper#release_lane_repos) and the app-ladder card, which
  # uses it to decide that a repo is IN FLIGHT rather than at rest.
  def member_repos
    ordered_members.flat_map(&:release_repos).uniq
  end

  # True when EVERY member of this release ships as a published gem — a gem-only
  # release, its own candidate (published to RubyGems, no app deploy). Guards an
  # empty member set to FALSE so a just-created release with no members yet is
  # never mis-flagged. Drives the board's GEM-ONLY badge + 💎 artifact line: a
  # gem-only release has no Deployed stage, so it shows the published gem instead
  # of a Prod/SHA link.
  def gem_only?
    members = tasks.to_a
    members.any? && members.all?(&:gem_release?)
  end

  # The distinct gem repos this release publishes, paired with the version each
  # would publish (nil when the sibling checkout isn't reachable — e.g. on a prod
  # box). Feeds the board's 💎 <gem> <version> artifact line for a gem_only?
  # release. Reads Release::Repos.gem_version, the already-present registry read.
  def gem_release_artifacts
    tasks.to_a.filter_map { |t| t.release_repo if t.gem_release? }.uniq.map do |repo|
      [repo, Release::Repos.gem_version(repo)]
    end
  end

  def shipped?
    state == "shipped"
  end

  # --- per-repo evidence (Release::MemberEvidence) -----------------------------
  #
  # What this candidate can PROVE it landed, repo by repo. Both readers are unions
  # of the records the real pipeline writes as it goes; neither is derivable from
  # the member set, which is the whole point — a plan that lost a repo still reads
  # as a complete plan, so the stamp has to be backed by what the RUN recorded, not
  # by what it intended.

  # Repos this candidate took through QA: a frozen QA sha (record_qa_shas) or a
  # pre-QA gate verdict (record_qa_gate). Unioned because a repo can legitimately
  # have one and not the other — a partial freeze skips the sha, an unregistered
  # qa_test_cmd skips the gate.
  # A gate entry counts only when it PASSED: record_qa_gate writes red verdicts
  # too (`ok: false`), and a repo whose gate went red and never froze a sha did
  # not go through QA — it aborted the run.
  def qa_evidence_repos
    gates = metadata["qa_gates"].is_a?(Hash) ? metadata["qa_gates"] : {}
    passed = gates.select { |_repo, record| record.is_a?(Hash) && record["ok"] }.keys.map(&:to_s)
    evidence_keys("qa_shas") | passed
  end

  # Repos this candidate fast-forwarded onto `main` (record_shipped_shas), written
  # by `bin/release ship` as each push lands.
  def ship_evidence_repos
    evidence_keys("shipped_shas")
  end

  # The members of `tasks` that must NOT be stamped, because a repo they name has
  # no landed record on this candidate. GEM repos are exempt: they publish rather
  # than deploy, so they carry no QA sha and no ff'd `main`, and demanding one
  # would hold every gem member forever. Logs each hold — a member left behind
  # silently is the failure mode this whole guard exists to end.
  def unproven_members(members, stamp: "assembled")
    proven = stamp == "shipped" ? ship_evidence_repos : qa_evidence_repos
    Array(members).select do |task|
      repos = task.release_repos
      exempt = repos.select { |repo| evidence_exempt?(repo, stamp: stamp) }
      next false unless Release::MemberEvidence.hold?(repos: repos, proven: proven, exempt: exempt)

      Rails.logger.warn(
        "[release-evidence] #{slug}: " \
        "#{Release::MemberEvidence.hold_reason(slug: task.slug, repos: repos, proven: proven,
                                               exempt: exempt, stamp: stamp)}"
      )
      true
    end
  end

  # Does THIS stamp's evidence requirement not apply to this repo? Two sources,
  # and the difference between them is the point:
  #
  #   * a GEM is exempt at BOTH stamps. It publishes rather than deploys, so it
  #     carries neither a QA sha nor an ff'd `main`. Unchanged.
  #   * a repo DECLARING `qa_evidence: exempt` is exempt at the QA stamp ONLY.
  #
  # The QA-only scope is deliberate and load-bearing. turf-vault (the one repo
  # that declares it today) genuinely cannot produce QA evidence — no dyno, no
  # URL, both QA steps skip it by design — but it absolutely DOES produce SHIP
  # evidence: `bin/release ship` fast-forwards its `release → main` and records
  # the sha at the push chokepoint whether or not a deploy adapter fires. So its
  # `shipped` stamp is backed by a real record, and honouring the exemption there
  # would disarm a guard that currently works correctly on this exact repo.
  #
  # Note what this does NOT do: it never infers an exemption from missing config.
  # A repo with no qa_test_cmd and no QA environment that has not DECLARED itself
  # exempt is still held — which is what keeps the guard armed for a Rails app
  # whose QA env was merely forgotten.
  def evidence_exempt?(repo, stamp:)
    return true if Release::Repos.gem?(repo)

    stamp != "shipped" && Release::Repos.qa_evidence_exempt?(repo)
  end

  def evidence_keys(key)
    value = metadata[key]
    return [] unless value.is_a?(Hash)

    value.reject { |_repo, recorded| recorded.blank? }.keys.map(&:to_s)
  end

  # --- stage timeline reads/writes ---------------------------------------------

  # The stage's stamp (time-and-boolean): a Time when reached, nil when not.
  def stage_stamp(stage)
    column = STAGE_STAMP_COLUMNS.fetch(stage.to_s) do
      raise ArgumentError, "unknown release stage #{stage.inspect} (known: #{STAGE_NAMES.join(', ')})"
    end
    self[column]
  end

  # A stage's "started at" for the tracker: its own start stamp when present,
  # else the nearest EARLIER stamped boundary as a lower-bound estimate (a stage
  # starts no sooner than the latest upstream stamp), falling back to the
  # release's open time as the floor. So every reached tracker node always has a
  # started_at even when its own start event was never posted — testing/review
  # and assembling starts are frequently un-instrumented or arrive late (see the
  # STAGES comment above), which otherwise left those nodes' timing blank.
  def stage_started_at_or_before(stage)
    index = STAGE_NAMES.index(stage.to_s)
    raise ArgumentError, "unknown release stage #{stage.inspect} (known: #{STAGE_NAMES.join(', ')})" unless index

    index.downto(0) do |i|
      stamp = self[STAGES[i].last]
      return stamp if stamp.present?
    end
    created_at
  end

  # Index of the furthest stamped stage (monotonic: the LATEST stage wins, so a
  # late upstream stamp never regresses it). nil when nothing is stamped yet. A
  # shipped STATE counts as the terminal stage even if shipped_at was never set
  # (legacy rows), so a shipped release always reads fully complete.
  def current_stage_index
    index = STAGES.rindex { |name, _column| stage_stamp(name).present? }
    return STAGES.length - 1 if shipped?

    index
  end

  # The furthest stage name, or nil when the timeline is untouched.
  def current_stage
    index = current_stage_index
    index && STAGES[index].first
  end

  # true when the timeline is AT or PAST the stage. The tracker's per-node
  # complete/active/pending derives from exactly this.
  def stage_reached?(stage)
    target = STAGE_NAMES.index(stage.to_s)
    raise ArgumentError, "unknown release stage #{stage.inspect} (known: #{STAGE_NAMES.join(', ')})" unless target

    index = current_stage_index
    index.present? && index >= target
  end

  # All stamps keyed by stage name (nil values included) — the API's stage
  # snapshot, so an agent posting an update sees the whole timeline it moved.
  def stage_stamps
    STAGES.to_h { |name, column| [name, self[column]] }
  end

  # Stamp a stage boundary. FIRST-WRITE-WINS: a stamped stage is immutable, so
  # replays and idempotent re-runs never rewrite history. Persisting the stamp
  # broadcasts the release modules (after_commit), which is what flips the live
  # /deployments tracker for every viewer. Returns self.
  def stamp_stage!(stage, at: Time.current)
    column = STAGE_STAMP_COLUMNS.fetch(stage.to_s) do
      raise ArgumentError, "unknown release stage #{stage.inspect} (known: #{STAGE_NAMES.join(', ')})"
    end
    return self if self[column].present?

    update!(column => at)
    self
  end

  def record_event!(step:, status:, **attrs)
    event = ReleaseEvent.record!(release: self, step: step, status: status, **attrs)
    stamp_stage_for_event(step, status, at: event.occurred_at)
    event
  end

  def refresh_duration_metrics!
    Release::DurationCache.refresh!(self)
  end

  def refresh_duration_metrics_safely
    return unless persisted?

    refresh_duration_metrics!
  rescue StandardError => e
    Rails.logger.warn("[release-duration-cache] refresh failed for #{slug}: #{e.class}: #{e.message}")
  end

  def event_completed?(step)
    release_events.for_step(step).completed.exists?
  end

  def event_started?(step)
    release_events.for_step(step).started.exists?
  end

  # Attach (SWEEP) a task onto this (assembling) release: set its `release_slug`
  # and stamp `merged: "release"` (its PR is now riding the persistent `release`
  # branch). The task's STAGE does NOT move here — under the Steffon-owns-the-
  # middle flow (2026-07-03) a member flips `reviewed → assembled` only on
  # QA-green (`Release::Conductor.qa_green!`), so a QA-deploy failure leaves it
  # `reviewed` for the next self-healing sweep. The actual branch merge + the
  # pre-QA tests are the conductor/CLI's job; this is the membership bookkeeping.
  #
  # Eligible stages: `reviewed` (the standard sweep) and `assembled` (a
  # STRAGGLER — an already-QA-green member a prior RC left behind; it re-attaches
  # without moving and re-QAs with the new candidate).
  #
  # `override: true` is the explicit, audited escape hatch for
  # `bin/release merge --override` — it skips the stage precondition so an
  # operator can carry a not-yet-reviewed PR onto the train. The review skip is
  # itself recorded on the audit spine (Conductor.sweep! flips the target to
  # `reviewed` with Current.task_event_review_bypass stamped on that transition),
  # so the bypass is never silent.
  def add(task, override: false)
    # Validate the task BEFORE mutating release state, so sweeping an ineligible
    # task onto an assembled RC doesn't needlessly reopen it. `override` is the
    # only path that may attach an ineligible-stage task (audited by sweep!).
    unless override || %w[reviewed assembled].include?(task.stage)
      raise ArgumentError, "task #{task.slug} is not sweepable (stage: #{task.stage})"
    end

    # On the durable `release` branch a PR can merge AFTER we've assembled (QA'd)
    # the candidate. That late sweep must re-open the RC so it re-assembles and
    # re-QAs before shipping — so absorb an assembled state by reopening, rather
    # than refusing the member.
    #
    # Atomic: the reopen and the member attach are ONE unit. The conductor's
    # late-merge caller (Conductor.sweep! ← `bin/release merge`) runs `add`
    # standalone with no enclosing transaction (unlike prepare!/curate!), so
    # without this wrapper a failed member attach would leave the RC reopened
    # (assembling) with the member never attached. Defense-in-depth.
    transaction do
      reopen! if state == "assembled"
      raise ArgumentError, "release #{slug} is not assembling (state: #{state})" unless state == "assembling"

      # Sweeping the task onto the RC means its PR merged onto the `release`
      # branch — stamp the git-location (the qa-deploy heartbeat's crash-recovery
      # signal: an interrupted Steffon skips re-merging a `merged: "release"`
      # task). See Task::MERGED_STATES. Stage is untouched: `reviewed` members
      # flip to `assembled` only on QA-green.
      #
      # NEVER downgrade `merged: "main"` → "release". A cross-release straggler
      # (an interrupted ship stamped it "main"; a LATER release re-adopts it via
      # this path) is already fast-forwarded onto main — re-stamping "release"
      # would claim it still waits on the release→main ff. sweep!'s own
      # never-regress short-circuit only sees CURRENT-release members, so this
      # is the backstop that keeps that promise absolute.
      stamp = task.merged == Task::MERGED_MAIN ? Task::MERGED_MAIN : Task::MERGED_RELEASE
      task.update!(release_slug: slug, merged: stamp)
    end
    task
  end

  # Every member in + tests check out → the RC is complete.
  def assemble!
    raise ArgumentError, "release #{slug} is not assembling (state: #{state})" unless state == "assembling"

    update!(state: "assembled")
  end

  # The operator "Makes the release" → ship to prod; members flip to `shipped`.
  # Allowed from an active release (assembling or assembled). A shipped release
  # with unfinished members is also accepted so an interrupted production record
  # step can resume the member flips after the release itself has already become
  # the board's Last Release.
  #
  # `usage_by_slug` is the optional { slug => {model, tokens_in, tokens_out, cost} }
  # best-effort per-member usage for the assembled→shipped transition (captured by
  # bin/release from the conductor's local transcript). Each member's ship! runs
  # inside Current.with_task_event_usage, which stamps that member's shipped
  # TaskEvent and clears the fields afterward so the next member isn't
  # mis-attributed. A member with no entry records the deterministic spine only.
  def ship!(by: nil, usage_by_slug: {}, member_pause: 0)
    resumable_member_ship = shipped? && tasks.where.not(stage: "shipped").exists?
    unless active? || resumable_member_ship
      raise ArgumentError, "release #{slug} is already terminal (state: #{state})"
    end

    usage_by_slug ||= {}
    member_pause = member_pause.to_f

    # confirmed_at is a stage stamp (first-write-wins): when Avi already posted
    # his confirming completion via the events API, ship keeps that earlier,
    # truer boundary instead of re-dating it to the ship moment. Commit this
    # before member flips so /deployments swaps the candidate into Last Release
    # immediately, then each task moves to Shipped in its own after_commit.
    if active?
      update!(state: "shipped", confirmed_by: by, confirmed_at: confirmed_at || Time.current)
    elsif by.present? && confirmed_by.blank?
      update!(confirmed_by: by, confirmed_at: confirmed_at || Time.current)
    end

    shipped_count = 0
    # PER-REPO EVIDENCE (Release::MemberEvidence): `shipped` + `merged: "main"` is
    # the most durable claim this system makes — that the member's code is live in
    # production — and nothing downstream ever revisits it. So a member spanning a
    # repo this release never fast-forwarded onto `main` (metadata["shipped_shas"])
    # is LEFT BEHIND rather than stamped: it keeps its real stage, stays visible as
    # unfinished work, and the operator sees the reason in the log. On 2026-08-13
    # this loop stamped a security patch shipped+main while turf's `main` sat
    # untouched at 0d63c7ebbb.
    unshipped = unproven_members(tasks.to_a, stamp: "shipped").map(&:slug)
    # Ship members in the BOARD's own order (Task.ordered — the exact ordering the
    # Assembled column renders), so a watching operator sees the batch peel off the
    # TOP of the column downward, one card every `member_pause` seconds. This used
    # to be `order(:created_at, :id)` — oldest-first, which is the BOTTOM card
    # first, so the column emptied upward.
    #
    # The resting rank follows the departure order rather than fighting it: each
    # Task#ship! stamps position = target-column max + 100, so the LAST member to
    # flip takes the freshest rank and lands on top of Shipped. That is also where
    # the live board puts it (every arrival is a prepend), so the column reads the
    # same before and after a reload. The batch therefore comes to rest in Shipped
    # in the reverse of its Assembled order — the trade for a top-down departure,
    # made deliberately.
    # The metronome: member 0 flips at 0s, member 1 one beat later, and so on from
    # the START of the batch (Release::BeatClock) — sleeping a full beat after each
    # flip would add each write's own time to the gap and drift the batch late.
    clock = nil
    tasks.ordered.to_a.each do |task|
      next if task.stage == "shipped"
      next if unshipped.include?(task.slug)

      clock&.wait_for_beat(shipped_count) { |seconds| pause_between_member_shipments(seconds) }
      Current.with_task_event_usage(usage_by_slug[task.slug]) { task.ship! }
      shipped_count += 1
      # The beat starts when the FIRST member flips (see Release::BeatClock).
      clock ||= Release::BeatClock.new(member_pause)
    end

    # The deployment just finished, so the DevOps card's averages just changed —
    # recompute EVERY rendered window here, once, and store it where every web
    # dyno can read it. This runs on a one-off dyno in production, which is
    # precisely why the snapshot goes to a column and not to Rails.cache.
    #
    # RESCUED, deliberately. A ship is the most consequential write this system
    # makes, and by this line the release and every member are already stamped and
    # committed. A failed snapshot write must not turn a completed production
    # deploy into a raised exception; the worst it can cost is that the next
    # viewer recomputes an 8ms figure.
    begin
      self.class.refresh_deployment_stage_averages!
    rescue StandardError => e
      ErrorLog.capture!(e)
    end
  end

  # Pull an assembled RC back to `assembling` so more reviewed work can be added.
  # Adding members invalidates the prior QA pass, so the RC must re-assemble (and
  # re-QA) before it can ship. This is what lets `Prepare release` be additive
  # instead of refusing when a release is already in flight.
  def reopen!
    raise ArgumentError, "release #{slug} is not assembled (state: #{state})" unless state == "assembled"

    # New members invalidate the prior assembly, QA pass, and any confirmation —
    # wind the stage timeline back to `assembling` so the tracker honestly shows
    # the re-assemble + re-QA ahead. The re-run re-stamps each boundary fresh
    # (first-write-wins applies to the NEW blanks). testing/assembling stamps
    # stay: the candidate's overall clock keeps its true origin.
    update!(
      state: "assembling",
      assembled_at: nil,
      qa_deploy_started_at: nil,
      qa_deployed_at: nil,
      confirming_started_at: nil,
      confirmed_at: nil
    )
  end

  # Discard a stuck RC → members fall back to `reviewed` (off the train), and the
  # singleton frees up for a fresh release.
  #
  # NOTE: this only drops BOARD membership. On the DURABLE per-repo `release`
  # branch the git-side remediation — reverting each abandoned member's merge
  # commit on `release` (never a force-push, since `release` is permanent and
  # shared) — is owned by the conductor/CLI as a documented step. The model never
  # touches git. `merged` is deliberately LEFT as-is: an un-reverted member's PR
  # still rides `release`, so `merged: "release"` stays true and the next sweep
  # correctly skips re-merging it. If you DO revert a member's merge commit,
  # clear its `merged` too (`Release::Conductor.eject!` does both for the
  # single-task regression path).
  def abandon!
    raise ArgumentError, "release #{slug} is already terminal (state: #{state})" unless active?

    transaction do
      tasks.to_a.each { |task| task.update!(stage: "reviewed", release_slug: nil) }
      update!(state: "abandoned")
    end
  end

  private

  # The event→stage seam: recording a step boundary stamps the matching stage
  # (EVENT_STAGE_STAMPS; unmapped steps and `failed` stamp nothing). Uses the
  # event's occurred_at so a backdated event stamps its true time. stamp_stage!
  # is first-write-wins, so idempotent event replays are stamp no-ops.
  def stamp_stage_for_event(step, status, at:)
    stage = EVENT_STAGE_STAMPS[[step.to_s, status.to_s]]
    return unless stage

    stamp_stage!(stage, at: at || Time.current)
  end

  def at_most_one_active_release
    scope = Release.where(state: ACTIVE_STATES)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:state, "another release is already active") if scope.exists?
  end

  # First-write-wins like every stage stamp: an agent may have already posted the
  # boundary (e.g. `assembled` at sweep-merge completion) before the state flip
  # lands — the earlier, truer time survives. reopen! clears the downstream
  # stamps, so a re-assembly stamps fresh.
  def set_state_timestamp
    case state
    when "assembled" then self.assembled_at ||= Time.current
    when "shipped"   then self.shipped_at ||= Time.current
    when "abandoned" then self.abandoned_at ||= Time.current
    end
  end

  def pause_between_member_shipments(seconds)
    sleep(seconds)
  end

  def generate_slug
    self.slug ||= "rel-#{Time.current.strftime('%Y%m%d')}-#{SecureRandom.hex(3)}"
  end

  # Push the refreshed release modules to the live /deployments board. Delegates to
  # the broadcaster, which is itself wrapped in Studio::Cable.safe_broadcast, so
  # this after_commit can never raise into the release write.
  #
  # The declared `fx` names WHY, for the client's ReleaseFx router. A ship is the one
  # transition that puts a new release in the Last Release slot, so it is called out
  # by name; every other save is `release.saved`, which no handler claims — the card
  # then animates only if its own signature moved. The router treats an unclaimed
  # kind as a hint, not a silencer, so a save that DOES change the last-shipped
  # release still reads as a change.
  def broadcast_release_modules
    kind = saved_change_to_shipped_at? && shipped_at.present? ? "deploy.landed" : "release.saved"
    DeploymentsBroadcaster.release_modules(fx: kind)
    # The app-ladder row too, as its OWN push rather than folded into release_modules
    # (that method is the Next + Last cards, and its tests assert the exact slots it
    # sends). A release opening / assembling / shipping re-stamps `merged` across its
    # members, which is what the row's rung counts read.
    DeploymentsBroadcaster.app_ladder
  end
end
