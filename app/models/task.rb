class Task < ApplicationRecord
  SIZES = %w[small medium large xl].freeze

  # --- Auto-derived actual_size (the "what it really cost" leg of the trio) ---
  # The size trio is: po_size (Avi's estimate at creation), dev_size (the builder
  # Pokémon's estimate at claim), and actual_size — the MEASURED outcome, derived
  # at ship from the task's real usage. po/dev are forecasts; actual is the ground
  # truth that scores them on the intelligence dashboard.
  #
  # SIGNAL: total tokens. We sum tokens_total across the task's TaskEvents — the
  # measured spine of work the agents actually burned across every stage. Tokens
  # (not cost, not wall-clock duration) is the cleanest size proxy: cost is just
  # tokens × a model's per-token price (so it tracks model choice, not work
  # volume), and duration is dominated by handoff/idle gaps between stages
  # (wall-clock, not effort). Tokens measure the work itself. Cost and
  # created_at→completed_at duration are both available on the record if a future
  # calibration wants to factor them; tokens stay the single, tunable signal here.
  #
  # THRESHOLDS: size → the EXCLUSIVE upper bound (in total tokens) of that bucket;
  # a task lands in the first bucket whose ceiling its token total falls under.
  # These are deliberately ROUND starting points — the seed board carries no
  # measured token usage yet, so they can't be fit to data; they're meant to be
  # re-tuned once real shipped tasks accumulate a token distribution. Kept in one
  # constant map so that re-tuning is a one-line edit.
  # actual_size buckets on measured $COST, not token count: cost is ground-truth
  # correct (priced through UsagePricing), while the token total is dominated
  # ~98% by cache_read and pinned nearly every task to XL. Ceilings are USD and
  # TUNABLE — a one-line edit once shipped tasks accumulate a cost distribution
  # (early prod data: quick fixes < $10, epics $250-500).
  ACTUAL_SIZE_COST_THRESHOLDS = {
    "small"  => 10.0,   # < $10  — a quick, contained change
    "medium" => 50.0,   # < $50  — a normal feature
    "large"  => 200.0,  # < $200 — a heavy, multi-stage build
    "xl"     => Float::INFINITY # ≥ $200 — an epic
  }.freeze

  # Two-workflow status model. See docs/agents/system/devops-cycle-design.md.
  #
  #   Workflow 1 — Build (feature agent):  designed → building → submitted
  #   Workflow 2 — Deploy (DevOps):        submitted → reviewed → assembled → shipped
  #   `submitted` is the shared seam — the feature agent hands off to DevOps there.
  #   blocked  — NOT a stage: it's an ATTRIBUTE of a `building` task (blocked_at +
  #              blocked_from + blocked_by + block_kind). A block means "more
  #              building to do", so a blocked task sits in `building`; #blocked?
  #              re-derives the live block from those columns.
  #   archived — terminal resting state: abandoned tickets AND shipped/completed
  #              work filed away (Archive completed tasks) to close the loop.
  STAGE_LABELS = {
    "designed"  => "Designed",
    "building"  => "Building",
    "submitted" => "Submitted",
    "reviewed"  => "Reviewed",
    "assembled" => "Assembled",
    "shipped"   => "Shipped",
    "archived"  => "Archived"
  }.freeze
  # The ACTIVE (gerund) form of each stage — "what's happening right now" — for UI
  # that shows a stage still UNDERWAY, where the past-tense noun reads wrong: a card
  # for the assembled stage in progress says "Assembling", not "Assembled". First
  # use is the /tasks/:id live timeline card; kept beside STAGE_LABELS so other
  # surfaces can share it. Use Task.active_stage_label for a safe fallback.
  STAGE_ACTIVE_LABELS = {
    "designed"  => "Designing",
    "building"  => "Building",
    "submitted" => "Submitting",
    "reviewed"  => "Reviewing",
    "assembled" => "Assembling",
    "shipped"   => "Shipping",
    "archived"  => "Archiving"
  }.freeze
  STAGES = STAGE_LABELS.keys.freeze
  # The two workflows, split at the `submitted` seam (which belongs to both):
  # Build is the feature agent's, Deploy is DevOps's.
  BUILD_STAGES  = %w[designed building submitted].freeze
  # The two pipeline gates where a task's Pokémon evolves (one step each): the
  # successful senior review and the QA-green assemble — Charmander tasks review
  # as Charmeleon and assemble as Charizard. The value is the evolution stage the
  # gate leaves the mascot at (devops.mascot_stage), which is what makes a
  # blocked→resubmitted loop idempotent. See #evolve_stage_mascot.
  #
  # They used to sit at submitted/reviewed, and moved out one stage each on
  # 2026-08-15: submitting is the builder handing work over, not the work being
  # accepted, so the celebration belongs at the gates that ACCEPT it. It also puts
  # every mascot's final form on the deploy side of the seam, where a one-evolution
  # line (Pikachu → Raichu) now lands at `assembled` instead of `reviewed`.
  MASCOT_EVOLUTION_GATES = { "reviewed" => 1, "assembled" => 2 }.freeze
  DEPLOY_STAGES = %w[submitted reviewed assembled shipped].freeze
  NEXT_INTENT_STAGE = { "designed" => "building", "building" => "submitted",
                        "submitted" => "reviewed", "reviewed" => "assembled",
                        "assembled" => "shipped" }.freeze
  # WHERE the task's code physically is, ORTHOGONAL to `stage` (the board
  # position) — so an interrupted assemble/deploy heartbeat contextualizes itself
  # from durable state instead of guessing (an interrupted Steffon skips
  # re-merging a `release` task; an interrupted Avi skips re-ff'ing a `main` one).
  #   nil        — not merged anywhere (submitted)
  #   "accepted" — merged onto the accepted branch by review (reviewed, pre-sweep):
  #                the ladder's first rung. An interrupted Steffon reads this to
  #                promote accepted→release without re-reviewing. Release#add
  #                downgrades it to "release" when the task is swept onto an RC.
  #   "release"  — merged onto the release branch (going through QA)
  #   "main"     — fast-forwarded into main (going through prod deploy)
  MERGED_ACCEPTED = "accepted"
  MERGED_RELEASE  = "release"
  MERGED_MAIN     = "main"
  MERGED_STATES   = [MERGED_ACCEPTED, MERGED_RELEASE, MERGED_MAIN].freeze
  # Board columns per page. /tasks is the feature-agent lane (the Build workflow;
  # blocked tasks ride the Building column as a red-glowing attribute, not a
  # separate lane). /deployments shows the full pipeline as swim lanes — the
  # Deploy workflow plus the upstream designed/building lanes (drag-and-drop).
  # The Deploy *workflow* itself (the /stages guide + per-stage kickoffs) stays
  # DEPLOY_STAGES — the board carrying extra lanes doesn't widen the workflow.
  TASKS_BOARD_STAGES       = %w[designed building submitted].freeze
  DEPLOYMENTS_BOARD_STAGES = %w[designed building submitted reviewed assembled shipped].freeze
  # Why a task is blocked (stored in the block_kind column) — lets a heartbeat
  # agent route it correctly.
  BLOCK_KINDS = %w[environment rework dependency].freeze
  REVIEW_ROLES = %w[primary light].freeze
  REVIEW_ROLE_ALIASES = {
    "primary" => "primary",
    "heavy" => "primary",
    "deep" => "primary",
    "heavy_review" => "primary",
    "light" => "light",
    "light_review" => "light"
  }.freeze
  REVIEW_MOMENTS = {
    "primary" => %w[started context diff tests risk findings completed failed],
    "light" => %w[started context diff smoke handoff completed failed]
  }.freeze
  REVIEW_MOMENT_LABELS = {
    "primary" => {
      "started" => "Started deep review",
      "context" => "Loaded task and PR context",
      "diff" => "Audited code diff",
      "tests" => "Checked required test evidence",
      "risk" => "Scanned release and regression risk",
      "findings" => "Prepared findings",
      "completed" => "Completed deep review",
      "failed" => "Reported deep-review blocker"
    },
    "light" => {
      "started" => "Started light review",
      "context" => "Loaded task and PR context",
      "diff" => "Skimmed changed files",
      "smoke" => "Checked targeted smoke path",
      "handoff" => "Checked docs and handoff",
      "completed" => "Completed light review",
      "failed" => "Reported light-review blocker"
    }
  }.freeze
  REVIEW_STATUSES = %w[started completed failed info].freeze
  # The `backend_migration` exclusive-lane key (docs/agents/system/exclusive-lanes.md).
  # The lane is CLAIMED through MigrationLaneClaim, not here. Task once carried a
  # `try_acquire_migration_lane` / `release_migration_lane` pair wrapping
  # `pg_try_advisory_lock(hashtext(...))`; both are gone. A session advisory lock
  # could not back this lane — bin/task is an HTTP client with no DB connection,
  # and a lock taken in a web request rides the POOLED connection past the
  # response, where it is re-entrant (two acquires on one pooled connection are
  # BOTH granted). See MigrationLaneClaim for the durable, unique-indexed claim.
  MIGRATION_LANE = "backend_migration".freeze
  OPERATOR_APPROVAL_WAITING = "waiting".freeze
  # The only stages where a WAITING operator-approval request is meaningful: the
  # ones whose owner can still act on the local demo. Past the `submitted` seam
  # the PR review flow owns the work, so the request is settled on every save
  # (#settle_operator_approval_past_submit). An ALLOW-list, so a stage added later
  # settles by default. `blocked` is not a stage (Task#block! parks the task on
  # `building`), so a QA-rework demo can re-request approval.
  APPROVAL_REQUEST_STAGES = %w[designed building].freeze
  OPERATOR_APPROVAL_APPROVED = "approved".freeze
  OPERATOR_APPROVAL_CHANGES_REQUESTED = "changes_requested".freeze
  # The settled/moot resolution. An open "waiting" request is cleared to "none"
  # the moment a task moves into `submitted` — the PR review flow takes over, so
  # the local-preview approval is no longer pending. See
  # #settle_operator_approval_past_submit. The settle resolves to "none" and never
  # to "approved" — nobody granted approval, and fabricating a grant would
  # misreport the acceptance metric.
  OPERATOR_APPROVAL_NONE = "none".freeze
  # Request-layer sources that mean the OPERATOR lane rather than the agent lane.
  # "web" is stamped only by the admin-gated TasksController#update — the board UI.
  # A BLANK source is an internal/console write (conductor, rails runner, model
  # callbacks). Every API bearer write stamps its own source via
  # Api::V1::TasksController#capture_task_event_context ("api" default, "cli" from
  # bin/task), and that controller clamps a caller-supplied "web" back to "api".
  # This is ATTRIBUTION only — it keeps a bearer write from labelling itself an
  # operator action in the TaskEvent trail. It gates no value: every
  # approval_status, "approved" included, is writable from either lane.
  OPERATOR_APPROVAL_GRANT_SOURCES = %w[web].freeze
  # Names that live in a TOP-LEVEL COLUMN and are therefore NOT writable devops
  # metadata. Each value is the sentence the writer gets back, naming the real home.
  #
  # Deleting a name from DEVOPS_SCALAR_KEYS is HALF a retirement: the write stops
  # landing, but normalize_devops_metadata's `next unless DEVOPS_KEYS.include?`
  # skips it in silence, so the caller gets a 200 for a write that evaporated.
  # `release_slug` is what that costs. It stayed a live devops key after the column
  # arrived, so the two names diverged into disjoint stores — the sweep wrote the
  # column (Release#record_members), the board form wrote the key, the task page
  # rendered the key, and bin/conductor read the column. The visible one was inert.
  # So a retired name RAISES here instead: one decider, and a wrong write is loud.
  # Both API paths (Api::V1::TasksController#update, TasksController#update) rescue
  # StandardError into a 422 carrying this message.
  #
  # A blank value is still skipped silently — it asserts nothing, so there is
  # nothing to lose or to correct.
  DEVOPS_COLUMN_KEYS = {
    "release_slug" => "the tasks.release_slug column — release membership is recorded by the sweep " \
                      "(Release#record_members), never set by hand",
    "release_train" => "the tasks.release_slug column — release membership is recorded by the sweep " \
                       "(Release#record_members), never set by hand",
    "block_kind" => "the tasks.block_kind column — stamped server-side by Task#block! " \
                    "(POST /api/v1/tasks/:slug/block)"
  }.freeze
  DEVOPS_SCALAR_KEYS = %w[
    kind shape worktree_slug branch pr_url local_url qa_url production_url
    requires_release_conductor included_in_release agent_context session_id session_provider mascot
    mascot_session claimed_session claim_nonce claim_expires_at post_deploy_cmd built_by gem_bump
    persona approval_status approval_requested_at approval_requested_by approval_approved_at
  ].freeze
  # Provider → resume-command template (one %s, the session id).
  RESUME_COMMANDS = {
    "claude" => "claude --resume %s",
    "codex"  => "codex resume %s"
  }.freeze
  # Human-facing fields are kept terse (so the operator can read the board at a
  # glance); agents put their verbose detail in `agent_context`.
  TITLE_WORD_RANGE = (3..5).freeze
  ACCEPTANCE_WORD_RANGE = (5..12).freeze
  # `abandoned_prs` is the ARCHIVE override's receipt: one entry per PR that was
  # still OPEN when an operator archived the task anyway with `bin/task move <slug>
  # archived --force`. Written only by that path (lib/open_pr_guard.rb), never by a
  # form, and never cleared — it is the difference a later reader needs between a PR
  # that was DROPPED DELIBERATELY and one that was simply forgotten, which is the
  # whole defect the open-PR gate closes.
  DEVOPS_LIST_KEYS = %w[repositories risk_tags acceptance test_plan checks_run abandoned_prs].freeze
  # Repo-keyed MAPS: { "<repo>" => "<value>" }. `pr_urls` is the per-repo PR url
  # register — the multi-repo answer to the single-valued `pr_url`.
  #
  # WHY IT EXISTS. `pr_url` holds ONE url, and Task#release_repo parses that url
  # for the repo a release plans against. So a task naming two repos had exactly
  # one place to record a PR, and the repo it named won: on 2026-08-13
  # `land-rails-security-patch` carried repositories [mcritchie-studio,
  # turf-monster] with the HUB's PR url, turf's PR #305 had nowhere to live, and
  # turf never existed as far as promote/QA/ship were concerned. The task was
  # stamped shipped+main while turf production still ran the unpatched code.
  # `pr_url` stays the PRIMARY (every existing reader keeps working); `pr_urls`
  # is where the SECOND repo's PR finally has a home.
  DEVOPS_MAP_KEYS = %w[pr_urls].freeze
  DEVOPS_KEYS = (DEVOPS_SCALAR_KEYS + DEVOPS_LIST_KEYS + DEVOPS_MAP_KEYS).freeze
  # github.com/<owner>/<repo>/pull/<n> → the repo segment.
  PR_URL_REPO_PATTERN = %r{github\.com/[^/]+/([^/]+)/pull/}
  # The change shape selects its DoR test contract. Keep in sync with
  # config/feature_shapes.yml (the source of truth that bin/dor-check reads).
  SHAPES = %w[ui-only ui+db backend library onchain onchain-vertical docs test-only].freeze

  # Board rank read-model (studio-engine board primitive). Supplies `reposition!`
  # (the shared reorder write, driven by Studio::Board::Reorderable in the
  # controller), `board_next_position`, the `board_ordered` scope, and the
  # `set_initial_position` genesis seed wired below. `board_zone_attr` defaults to
  # `:stage`, so ranking is per-column exactly as this board always did. Task's own
  # `ordered` scope (below) EXTENDS `board_ordered` with the operator-approval
  # priority clause, and `set_stage_timestamp` re-ranks a card to the top of its new
  # column on a stage move — both are Task-specific and stay here.
  include Studio::Board::Rankable

  belongs_to :agent, foreign_key: :agent_slug, primary_key: :slug, optional: true
  belongs_to :release, foreign_key: :release_slug, primary_key: :slug, optional: true, inverse_of: :tasks
  has_many :activities, foreign_key: :task_slug, primary_key: :slug, dependent: :nullify
  has_many :task_events, foreign_key: :task_slug, primary_key: :slug, inverse_of: :task, dependent: :destroy
  has_many :task_transitions, foreign_key: :task_slug, primary_key: :slug,
                              inverse_of: :task, dependent: :destroy
  # Forward-only per-action trajectory (AgentAction.capture). Nullify on destroy
  # so the finest-grain telemetry survives a task teardown as orphaned history.
  has_many :agent_actions, foreign_key: :task_slug, primary_key: :slug, inverse_of: :task, dependent: :nullify
  has_many :atomic_actions, class_name: "AgentAction", foreign_key: :task_slug, primary_key: :slug
  # Agent-narrated activities (AgentActivity.open_activity!/close_activity!) — the
  # coarse, meaningful layer the raw actions attribute under. Nullify on destroy so
  # the narrated history survives a task teardown as orphaned activities.
  has_many :agent_activities, foreign_key: :task_slug, primary_key: :slug, inverse_of: :task, dependent: :nullify
  has_many :atomic_events, class_name: "AgentActivity", foreign_key: :task_slug, primary_key: :slug
  # Attempt-aware runs of the task-owned testing gates (G1 Cert, G2a/G2b review
  # lanes) — slug-FK like the spines above, scoped to task-grain subjects.
  has_many :gate_runs, -> { where(subject_type: "task") },
           foreign_key: :subject_slug, primary_key: :slug, dependent: :delete_all
  # The per-task REVIEW claim (TaskReviewClaim) — at most one live pr-review session
  # per submitted task. Slug-FK like everything else; destroyed with the task so a
  # teardown never strands a claim row behind a gone task.
  has_one :review_claim, class_name: "TaskReviewClaim",
          foreign_key: :task_slug, primary_key: :slug, dependent: :destroy

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :stage, inclusion: { in: STAGES }
  # `merged` is optional (nil = not merged); when set it must be a known git
  # location. A typo must be a hard error here (unlike `--agent`), since the
  # heartbeats' crash-recovery reads it as ground truth.
  validates :merged, inclusion: { in: MERGED_STATES }, allow_nil: true
  # Naming discipline — enforced wherever the title/acceptance is set or changed
  # (every create + any update that touches them, all paths). Gated on change, so
  # existing tasks that don't touch these fields stay grandfathered.
  validate :title_within_word_range, if: :title_changed?
  validate :acceptance_bullets_within_word_range, if: :acceptance_changed?
  validates :priority, inclusion: { in: [0, 1, 2] }
  validates :pm_size,     inclusion: { in: SIZES }, allow_nil: true
  validates :po_size,     inclusion: { in: SIZES }, allow_nil: true
  validates :dev_size,    inclusion: { in: SIZES }, allow_nil: true
  validates :actual_size, inclusion: { in: SIZES }, allow_nil: true

  attr_readonly :slug # the readable handle is set once at creation, then immutable

  before_validation :generate_slug, on: :create
  before_validation :default_devops_handles_from_slug, on: :create
  # Persona BEFORE the Pokémon draw: when a session "acts as" a soul (devops.persona),
  # stamp the agent's name/color/emoji as the mascot and skip the Pokémon entirely.
  before_validation :sync_persona_identity, on: :create
  before_validation :sync_session_mascot, on: :create
  # The mascot's DERIVED stamps (shiny/color/emoji) — server-owned, so they must
  # be re-asserted on every save. See #sync_mascot_display.
  before_validation :sync_mascot_display, on: :create
  # Stamp the app's status-line tint (App#color) from the first repository, so
  # bin/statusline can color the app slug without DB access. Cheap, idempotent.
  before_validation :sync_app_identity, on: :create
  before_create :set_initial_position
  before_save :set_stage_timestamp, if: :stage_changed?
  # A block is a `building` attribute: advancing OUT of building (to submitted or
  # beyond) resolves it, so clear the block columns on that forward move. This
  # keeps blocked_at meaning "currently blocked" — without it, a later return to
  # building would false-positive as blocked off a stale timestamp.
  before_save :clear_block_on_forward_move, if: -> { will_save_change_to_stage? && stage != "building" }
  # Per-session mascot: re-derive on each build-phase transition (designed/building/
  # submitted) so a task picked up by a DIFFERENT agent swaps to that session's Pokémon.
  # FIRST of the mascot callbacks: put the handle back before anything reads it.
  # sync_session_mascot's redraw guard fires on a blank mascot, so a PATCH that
  # simply didn't mention the mascot would otherwise swap the task's Pokémon.
  # See #restore_mascot_identity.
  # The invariant behind DEVOPS_COLUMN_KEYS, enforced at the LAST gate rather than
  # only at the door: no task stores a devops key that shadows a column. See
  # #shed_column_shadow_keys for why the normalizer's raise is not sufficient.
  before_save :shed_column_shadow_keys
  before_save :restore_mascot_identity
  before_save :sync_persona_identity
  before_save :sync_session_mascot, if: -> { will_save_change_to_stage? && Task::BUILD_STAGES.include?(stage) }
  # Evolution AFTER the session sync: a handoff-resubmit first swaps to the new
  # session's base Pokémon, then evolves it — so the gate always evolves the
  # mascot that owns the transition. Runs before the after_update TaskEvent, so
  # the transition's snapshot bakes the EVOLVED form (older events keep theirs).
  # Unconditional, and BEFORE the evolution gate: the mascot's shiny/color/emoji
  # and its consumed gate are server-owned, so a client that rebuilds the hash from
  # the whitelist drops them. Re-asserting them here — the same
  # self-healing shape as sync_app_identity below — means the gate check reads a
  # restored mascot_stage (a wiped one re-opens a spent gate and double-evolves)
  # and evolve_stage_mascot's own emoji stamp reads a restored mascot_shiny. The
  # evolved form's color/emoji then belong to evolve_stage_mascot, which stamps
  # them for the slug it lands on. See #sync_mascot_display.
  before_save :sync_mascot_display
  before_save :evolve_stage_mascot, if: -> { will_save_change_to_stage? && Task::MASCOT_EVOLUTION_GATES.key?(stage) }
  before_save :sync_app_identity
  # Unconditional: the settle is a stage INVARIANT re-asserted on every save, not
  # a transition event. See #settle_operator_approval_past_submit for the three
  # leaks the transition shape had.
  before_save :settle_operator_approval_past_submit
  before_save :stamp_operator_approval_request
  before_save :stamp_operator_approval_approved
  # The cert evidence in devops.checks_run is MACHINE-owned and survives an
  # author's checks update. Every writer of checks_run — bin/task's PATCH, the
  # board UI form, a raw API call, the console — lands here, so the guard is on
  # the model rather than in any one caller. See #preserve_cert_evidence.
  before_save :preserve_cert_evidence
  # The build claim is a BUILD-STAGE lease, re-asserted as an INVARIANT on every
  # save rather than handled at any one transition. It both RELEASES the claim
  # once the task leaves `building` and DEFENDS it from a client write that blanks
  # or bypasses the keys while it is there. See #enforce_build_claim_invariant.
  before_save :enforce_build_claim_invariant
  # WHO BUILT THIS is a property of the build CLAIM, not of the transition into
  # `building`. Registered AFTER enforce_build_claim_invariant so it reads the
  # restored claim (that guard decides what counts as a claim write) — and, like
  # its five siblings above, it re-asserts a server-owned devops key on every save
  # so a client cannot clear it by posting it blank. See #enforce_builder_stamp.
  before_save :enforce_builder_stamp
  # One TaskEvent per save that lands a stage: the genesis on create (the default
  # "designed" stage isn't a dirty change, so this is guard-free) and one per real
  # transition on update.
  after_create :record_genesis_event
  after_update :record_transition_event, if: :saved_change_to_stage?
  # When a task lands in `shipped`, stamp actual_size from its MEASURED usage.
  # Registered AFTER record_transition_event so the shipping transition's own
  # TaskEvent is already on the spine and counted in the token total. See
  # #autoderive_actual_size — it only fills a BLANK actual_size (never clobbers a
  # manual size) and never unwinds the ship if derivation fails.
  after_update :autoderive_actual_size, if: :saved_change_to_stage?
  after_commit :refresh_duration_metrics_for_release_changes, on: %i[create update destroy]
  after_commit :refresh_testing_phases_after_change, on: %i[create update]
  # Avi auto shirt-sizes a task the instant it enters `designed` WITHOUT a po_size
  # — on create (the stage a task is BORN in, so the typical trigger is a
  # `bin/task create` with no --po-size) or a later move INTO designed with the
  # size still blank. Enqueued async (AviSizingJob) so the sizing runs in PARALLEL
  # with the build, never blocking the create/move. See #enqueue_avi_sizing_if_designed_unsized.
  after_commit :enqueue_avi_sizing_if_designed_unsized, on: %i[create update]
  # The /deployments app-ladder row counts tasks PARKED at each branch rung, read
  # straight from the `merged` column (accepted / release / main), with `archived`
  # excluded so the main rung can drain. So the ladder moves when — and only when —
  # one of those two columns moves, which is what this guard says.
  #
  # Deliberately NOT folded into DeploymentsBroadcaster.release_modules, even though a
  # sweep and a ship are what usually change these stamps. That method is documented
  # as "the Next + Last release modules" and its tests assert the exact slots it
  # pushes, on the discipline that a caller must not push a card it cannot have
  # changed. Pushing from here instead keeps that rule intact, fires for a hand-run
  # `bin/task merged` that no release touched, and cannot double-push on a CI tick
  # (ci_progress pushes the ladder on its own, for the verdicts rather than the counts).
  after_commit :broadcast_app_ladder_if_rung_changed, on: %i[create update destroy]

  # The operator-approval status lives INSIDE the metadata JSON, so flipping it to
  # "waiting" (an agent requesting a demo review) or clearing it changes no stage
  # column and writes no TaskEvent — the two spines the live /deployments board
  # listens on. Without this the WAITING APPROVAL bar only appeared on a full
  # reload. Broadcast an event-less in-place card replace whenever the DERIVED
  # approval_status actually changes (a wholesale devops rewrite that echoes the
  # same value is not a change, so `bin/task update --checks` never spams the board).
  after_update_commit :broadcast_operator_approval_change, if: :saved_change_to_approval_status?
  # A block/unblock changes no stage and records NO TaskEvent — Task#block! is a bare
  # update! — so the live board never heard about it and a blocked card sat unchanged
  # until something else forced a re-render. That is the one state an operator most
  # needs to see arrive on its own. Keyed on blocked_at because it is the column that
  # moves in BOTH directions (nil → time on block, time → nil on unblock), so one
  # guard covers both without a second callback.
  after_update_commit :broadcast_block_change, if: :saved_change_to_blocked_at?
  # A destroy fires no TaskEvent, so the live /deployments board never hears about
  # it — broadcast the card removal explicitly so every viewer's board drops it.
  after_destroy_commit :broadcast_removal_to_deployments_board

  def to_param
    slug
  end

  # `blocked` is NOT a stage — it is an ATTRIBUTE of a `building` task — so a
  # column-equality filter on it can only ever return zero rows. Route that one
  # name through the `blocked` scope instead, and keep every real stage on the
  # column. Without this, `bin/task list --stage blocked` and
  # `GET /api/v1/tasks?stage=blocked` answered "nothing is blocked" instead of
  # "that is not a stage" — the query an operator runs to find blocked work.
  scope :by_stage, ->(stage) { stage.to_s == "blocked" ? blocked : where(stage: stage) }
  # A LIVE block is a `building` task carrying an unresolved block marker
  # (blocked_at set). blocked_at persists as history after the task advances, so
  # the `building` guard is what keeps the scope to CURRENTLY-blocked tasks.
  scope :blocked, -> { where(stage: "building").where.not(blocked_at: nil) }
  scope :recent, -> { order(created_at: :desc) }
  # Board order: highest `position` first, so the freshest task in a column sits
  # on top. `position` is an event-driven RANK — a create or a stage move stamps
  # it to (column max + 100), floating that task to the top (see
  # set_initial_position / set_stage_timestamp). The 100-gaps leave room for a
  # drag-drop reorder to slot a card between two others without renumbering. This
  # mirrors the News/Content rank scheme (which Task previously inverted).
  scope :ordered, -> {
    order(Arel.sql(
      "CASE WHEN metadata -> 'devops' ->> 'approval_status' = '#{OPERATOR_APPROVAL_WAITING}' THEN 1 ELSE 0 END DESC, " \
        "position DESC NULLS LAST, created_at DESC"
    ))
  }
  scope :requires_migration, -> { where(requires_migration: true) }
  # Tasks still in play — everything except the two terminal stages, i.e.
  # designed + building + submitted + reviewed + assembled. A live task's mascot
  # is "taken"; shipping or archiving returns its Pokémon to the deck. Also the
  # WIP metric (see .wip_count) — one scope, so the deck and the card can never
  # disagree about what counts as open work.
  scope :live, -> { where.not(stage: %w[shipped archived]) }
  # The load-bearing query of the per-task review claim: submitted PR tasks NOT
  # already under LIVE review. It's a proper SERVER-SIDE query (NOT EXISTS on
  # task_review_claims where the lease is still in the future), not a Ruby filter —
  # the whole point is that many parallel pr-review sessions each ask the board for
  # the unclaimed-for-review work in one round trip. `claim_expires_at` is a real
  # datetime column, so it can never be the "corrupt/unparseable" lease ClaimLease
  # guards for a JSON string claim: NULL (never claimed / released) and a past
  # expiry (lapsed) both fall through as reviewable; only a future expiry excludes.
  scope :reviewable, ->(now: Time.current) {
    by_stage("submitted").where(
      "NOT EXISTS (SELECT 1 FROM task_review_claims trc " \
      "WHERE trc.task_slug = tasks.slug AND trc.claim_expires_at > ?)", now
    )
  }

  # The verdict of an atomic review pop. `task` is nil when nothing was claimed;
  # `reason` names why ("claimed" / "none_reviewable" / "no_green_ci").
  #
  # `blind_repos` names the repos among the SKIPPED candidates that the board
  # holds no ingested CI run for at all (Ci::Ingestion). It is a REPORTING field,
  # never a gate: a blind repo is skipped for exactly the same reason as any
  # other non-green PR. It exists because `no_green_ci` alone reads as "the
  # queue is red or still running", which is how an unwired repo's task sat in
  # `submitted` for days — the pop was right and unreadable at the same time.
  # `skipped_ci` is what THE BOARD HOLDS for each skipped candidate — its state and
  # the head SHA that state belongs to. Also reporting-only.
  #
  # It exists because the two mechanisms in the review SOP read DIFFERENT SOURCES,
  # by design: this pop folds our own ingested GithubWorkflowRun rows (never a live
  # call — see Ci::ReviewGate), while `bin/dor-check --gate-role review` reads
  # `gh pr checks` LIVE. When the board has not ingested the PR's current tip, the
  # entry gate says no and gate-zero says yes about the SAME PR, and the task is
  # unreviewable by the SOP. That happened to auto-mint-level-up-tokens (turf PR
  # 407), which sat in `submitted` from 2026-08-23 and missed releases on it.
  #
  # blind_repos could not describe it: that field fires only when a repo has NO
  # ingested runs AT ALL, and this repo was wired — it simply had nothing for THIS
  # head. So the refusal printed no warning and cost a bisect of two CLIs. Naming
  # the state and the SHA makes the same situation readable in one line.
  ClaimNextResult = Struct.new(:task, :outcome, :reason, :blind_repos, :skipped_ci, keyword_init: true) do
    def claimed?
      task.present?
    end

    # Always an Array — callers built before this field passed no value at all.
    def blind_repo_list
      Array(blind_repos)
    end

    def skipped_ci_list
      Array(skipped_ci)
    end
  end

  # The ATOMIC review pop (relocate-review-selection-to-server): claim the single
  # highest-ranked reviewable task whose PR CI has concluded GREEN, in one board
  # transaction, stamping the review lease on it. This relocates the "which task do I
  # review next" decision bin/pr-review assembled CLIENT-side (reviewable list →
  # per-PR live `gh` CI read → per-task acquire) into ONE authoritative SERVER pop, so
  # the UI gets one fast answer and two parallel pr-review sessions never collide.
  #
  # Walks `reviewable.ordered` in rank order and, per candidate, in its OWN short
  # transaction:
  #   1. re-selects the row `FOR UPDATE SKIP LOCKED`, so two concurrent callers never
  #      grind the same top task — the loser SKIPS the locked row to the next;
  #   2. gates on Ci::ReviewGate.green? — :red / :pending / :ci_less / :none are
  #      SKIPPED, never claimed (a non-green PR is not a review target), and the
  #      gate reads EVERY repo the task has a PR in, so one green repo can no longer
  #      pop a task whose second repo is red or still running;
  #   3. claims it via TaskReviewClaim.acquire, whose per-claim-row lock is the FINAL
  #      winner-picker — a claim already held by a racer skips to the next candidate.
  # The first candidate that clears all three is returned; a non-claim commits the
  # short transaction (releasing its row lock) so an un-green/locked task is never held.
  #
  # `ci_status` is the test seam mirroring bin/pr-review's injected_ci_state: a Hash
  # `{ slug => token }` (or a bare token for the whole wave) applied AS each task's CI
  # verdict, so a rank/skip unit test drives green vs. not-green per slug without
  # ingesting GithubWorkflowRun rows. Production passes nil — the real DB fold runs.
  def self.claim_next_review(session:, nonce:, label: nil, reviewer: nil, now: Time.current, ci_status: nil)
    ordered_slugs = reviewable(now: now).ordered.pluck(:slug)
    return ClaimNextResult.new(task: nil, outcome: nil, reason: "none_reviewable") if ordered_slugs.empty?

    skipped_ungreen = false
    skipped_repos = []
    skipped_ci = []
    ordered_slugs.each do |slug|
      claimed = transaction do
        task = reviewable(now: now).where(slug: slug).lock("FOR UPDATE SKIP LOCKED").first
        next nil unless task # locked by a concurrent caller, or claimed since the pluck

        token = ci_status_token(ci_status, slug)
        unless Ci::ReviewGate.green?(task, injected: token)
          skipped_ungreen = true
          # EVERY repo the skipped task has a PR in, for the blind-repo report below.
          # The singular read here named repo #1 only, so an unwired SECOND repo —
          # the repo actually holding the task in `submitted` — was the one thing the
          # report could not say.
          skipped_repos.concat(Ci::ReviewGate.repos_for(task))
          # THE SAME token the gate just judged on. Re-reading without it would let the
          # report describe a DIFFERENT verdict than the one that caused this skip —
          # a diagnostic that contradicts the decision it explains is worse than none.
          skipped_ci << ci_report_for(task, slug, token)
          next nil # red / pending / ci-less / none — never claim a non-green PR
        end

        outcome = TaskReviewClaim.acquire(task_slug: slug, session: session, nonce: nonce, label: label,
                                          reviewer: reviewer, now: now)
        next nil unless outcome.acquired # claim held by a racer — skip to the next

        ClaimNextResult.new(task: task, outcome: outcome, reason: "claimed")
      end
      return claimed if claimed
    end

    ClaimNextResult.new(task: nil, outcome: nil, reason: skipped_ungreen ? "no_green_ci" : "none_reviewable",
                        blind_repos: blind_repos_among(skipped_repos), skipped_ci: skipped_ci)
  end

  # Which of the just-skipped candidates' repos deliver NO CI to the board at all
  # — the wiring gap, told apart from a red or still-running build. Reporting
  # only: the pop's decision is already made, so this can never change what gets
  # claimed, and a failure here degrades to "no blind repos" rather than taking
  # the review pop down with it.
  # What the BOARD holds for one skipped candidate, for reporting only.
  #
  # Deliberately tolerant: this runs inside the pop's short transaction, on the
  # refusal path, purely to explain a decision that has ALREADY been made. It must
  # never be the reason a pop fails, so any error here degrades to :unreadable
  # rather than propagating — a diagnostic that can break the thing it describes is
  # worse than no diagnostic.
  def self.ci_report_for(task, slug, injected = nil)
    verdict = Ci::ReviewGate.verdict(task, injected: injected)
    { "slug" => slug,
      "state" => verdict[:state].to_s,
      "sha" => verdict[:sha].to_s[0, 12],
      "repo" => verdict[:repo].to_s }
  rescue StandardError => e
    { "slug" => slug, "state" => "unreadable", "sha" => "", "repo" => e.class.name }
  end

  def self.blind_repos_among(repos)
    return [] if repos.blank?

    Ci::Ingestion.unwired(repos)
  rescue StandardError => e
    ErrorLog.capture!(e)
    []
  end

  # The injected CI verdict for one slug (test seam) — a per-slug Hash lookup, a bare
  # token applied to every slug, or nil (no injection → the real Ci::ReviewGate read).
  def self.ci_status_token(injection, slug)
    return nil if injection.nil?
    return injection[slug] || injection[slug.to_sym] if injection.is_a?(Hash)

    injection
  end

  # The tasks that render in a board column. Blocked tasks ARE building tasks now
  # (a block is a building attribute), so the building column no longer folds in a
  # separate "blocked" bucket — the stage grouping already carries them.
  def self.board_column_tasks(tasks_by_stage, stage)
    Array((tasks_by_stage || {})[stage.to_s])
  end

  # How many `shipped` cards a board draws by default. Shipped is HISTORY, and it
  # was the biggest column on either board — 31 of the 57 cards /deployments drew —
  # carrying the heaviest crew markup (the 4-slot crew cluster). The cap trims the
  # RENDER, never the record: `?stage=shipped` still returns every one.
  BOARD_SHIPPED_LIMIT = 12

  # The board's default task set: live work in full, plus the freshest slice of
  # `shipped`, and NEVER `archived`.
  #
  # This scope is the page's whole performance story. The boards used to load every
  # task and let each view pick columns out of the result, so a board drawing 57
  # cards instantiated 1,212 tasks, 14,170 TaskEvents and 3,742 GateRuns — about 56%
  # of everything the request allocated, on a dyno already reporting R14. Measured
  # on production 2026-08-19: 648ms / 511,905 objects unscoped, 25ms / 24,784 scoped.
  #
  # `shipped` is capped in SQL rather than trimmed in Ruby afterwards so its
  # TaskEvents are never instantiated either — the object count is the expensive
  # half, not the row count. Callers pass an already-ordered, already-preloaded
  # scope; `ordered` sorts waiting-approval first then position desc, so the kept
  # slice is the freshest. Returns an Array, not a relation: it is two loads.
  def self.board_default_tasks(scope = all)
    scope.where.not(stage: %w[archived shipped]).to_a +
      scope.where(stage: "shipped").limit(BOARD_SHIPPED_LIMIT).to_a
  end

  # { stage => true total } for every column board_default_tasks actually trimmed —
  # empty when nothing was, so a board badge stays a plain number in the common
  # case. Pass the SAME filtered scope the cards came from, or an agent-filtered
  # board would advertise the unfiltered total.
  def self.board_capped_stage_totals(scope = all)
    shipped = scope.where(stage: "shipped").count
    shipped > BOARD_SHIPPED_LIMIT ? { "shipped" => shipped } : {}
  end

  # WIP — how much work is open right now, the DevOps card's sixth tile:
  # designed + building + submitted + reviewed + assembled. That set IS `live`
  # (everything but the two terminal stages), so this counts THROUGH the scope
  # instead of restating the stage list where the two could drift apart.
  # Deliberately independent of the board's agent/stage filter params: WIP is the
  # pipeline's total, not the count of whatever the current view has narrowed to.
  def self.wip_count
    live.count
  end

  # Avi's per-APPLICATION release disposition over the `reviewed` queue — the read
  # behind the reviewed-stage board marker and the `qa-release` disposition step. It
  # groups the reviewed candidates by their release application (Task#release_repo) and
  # reports, per app, whether it rides the next candidate (`included`) and which task
  # members carry it. An app is `included` only when EVERY one of its reviewed members
  # is `included_in_release?` — a single member Avi holds out (`included_in_release:
  # false`) flags its whole app as held from this release, so the marker never says
  # "shipping" while a member is deliberately ejected. Default is include-all, so a
  # fresh reviewed queue reports every app included. `scope` is injectable for tests.
  def self.reviewed_release_inclusion(scope = where(stage: "reviewed"))
    scope.to_a.group_by(&:release_repo).transform_values do |members|
      { included: members.all?(&:included_in_release?), members: members }
    end
  end

  def self.unresolved_feedback_by_slug(task_slugs)
    slugs = Array(task_slugs).map(&:to_s).reject(&:blank?)
    return {} if slugs.empty?

    Activity.where(task_slug: slugs, activity_type: %w[qa_feedback handoff])
            .conversation_order
            .each_with_object({}) do |activity, unresolved|
      if activity.activity_type == "qa_feedback"
        unresolved[activity.task_slug] = activity
      elsif activity.resolves_feedback?
        unresolved.delete(activity.task_slug)
      end
    end
  end

  # The mascot slugs currently held by live tasks — the exclusion set the draw
  # skips so two in-flight tasks never share a Pokémon.
  def self.active_mascots
    live.pluck(:metadata).filter_map { |m| m&.dig("devops", "mascot").presence }
  end

  def self.shiny_value?(value)
    value == true || value.to_s.strip.downcase == "true" || value.to_s.strip == "1"
  end

  # Backfill: give a mascot to every LIVE task that lacks one — for tasks created
  # before the mascot feature (assign_mascot is create-only) so the existing board
  # lights up. Idempotent (skips tasks that already have one), unique among live
  # tasks, written through the normal devops path (not update_column) so it stays a
  # real, normalized scalar. The exclusion set is hoisted once and grown in memory
  # (no per-row table re-scan), terminal stages are skipped, and a row that fails to
  # save is captured to ErrorLog (durable — rolling logs roll off) and skipped so
  # one bad task can't abort a prod run. Returns the count newly assigned.
  # One-time sweep for the rows the OLD one-shot settle left behind (the
  # transition callback fired on the single building→submitted save, so anything
  # that rewrote devops afterwards restored "waiting" and nothing cleared it —
  # the request rode to `shipped` and kept flashing WAITING APPROVAL on a
  # finished card). #settle_operator_approval_past_submit now holds the invariant
  # on every save, but a row nobody saves again never gets it.
  #
  # Idempotent: only ever "waiting" → "none", only past the seam. update_column
  # skips callbacks so a historical row is not otherwise disturbed — no
  # broadcasts, no timestamps, no stage churn. Returns the slugs it settled.
  # Driver: `rake tasks:settle_stale_operator_approvals`.
  def self.settle_stale_operator_approvals!
    settled = []
    where.not(stage: APPROVAL_REQUEST_STAGES).find_each do |task|
      next unless task.devops["approval_status"] == OPERATOR_APPROVAL_WAITING

      metadata = task.metadata.deep_dup
      metadata["devops"]["approval_status"] = OPERATOR_APPROVAL_NONE
      task.update_column(:metadata, metadata) # rubocop:disable Rails/SkipsModelValidations
      settled << task.slug
    end
    settled
  end

  def self.backfill_mascots!
    taken = active_mascots.to_set
    assigned = 0
    live.find_each do |task|
      next if task.devops["mascot"].present?

      pick = Pokemon.draw(exclude: taken.to_a)
      next unless pick

      merged = task.metadata.deep_dup
      backfilled = (merged["devops"] ||= {})
      backfilled["mascot"] = pick.slug
      # A backfilled mascot is a fresh draw, so it gets its own shiny roll.
      backfilled["mascot_shiny"] = Pokemon.roll_shiny?
      task.update!(metadata: merged)
      taken << pick.slug
      assigned += 1
    rescue StandardError => e
      log = ErrorLog.capture!(e)
      log.target = task
      log.target_name = task.slug
      log.save!
    end
    assigned
  end

  # Migrate a board from the old per-TASK mascots to the per-SESSION rule: every live
  # task carrying a session_id adopts its session's Pokémon (the first one seen for that
  # session wins; sessions stay unique among themselves). Session-less tasks keep theirs.
  # Idempotent; a failed row is captured to ErrorLog and skipped. Returns the count.
  def self.resync_session_mascots!
    by_session = {}
    shiny_by_session = {}
    taken = active_mascots.to_set
    restamped = 0
    live.find_each do |task|
      sid = task.metadata&.dig("devops", "session_id").to_s
      next if sid.blank?

      slug = by_session[sid] ||= (task.metadata.dig("devops", "mascot").presence || Pokemon.draw(exclude: taken.to_a)&.slug)
      next unless slug
      taken << slug

      # The session's shiny roll rides along with its Pokémon: the SessionMascot
      # row is the truth when present, else the first task seen keeps its flag.
      # key? (not ||=) because a legitimate `false` must cache too.
      unless shiny_by_session.key?(sid)
        session_mascot = SessionMascot.find_by(session_id: sid)
        shiny_by_session[sid] = session_mascot ? session_mascot.shiny? : shiny_value?(task.metadata.dig("devops", "mascot_shiny"))
      end
      shiny = shiny_by_session[sid]

      dev = task.metadata["devops"] || {}
      next if dev["mascot"] == slug && dev["mascot_session"] == sid && shiny_value?(dev["mascot_shiny"]) == shiny

      merged = task.metadata.deep_dup
      d = (merged["devops"] ||= {})
      d["mascot"] = slug
      d["mascot_session"] = sid
      d["mascot_shiny"] = shiny
      pokemon = Pokemon.find_by(slug: slug)
      d["mascot_color"] = pokemon&.signature_color
      d["mascot_emoji"] = pokemon&.status_emoji(shiny: shiny)
      task.update_columns(metadata: merged)
      restamped += 1
    rescue StandardError => e
      log = ErrorLog.capture!(e)
      log.target = task
      log.target_name = task.slug
      log.save!
    end
    restamped
  end

  def devops
    metadata.fetch("devops", {}) || {}
  end

  def devops?
    devops.any?
  end

  # Whether this task's mascot came up SHINY — rolled once at draw time (the
  # session's SessionMascot roll, adopted here) and stamped server-side as
  # devops.mascot_shiny alongside mascot_color/emoji.
  def mascot_shiny?
    self.class.shiny_value?(devops["mascot_shiny"])
  end

  def devops_kind
    devops.fetch("kind", "").presence || "feature"
  end

  def devops_shape
    devops.fetch("shape", "").presence
  end

  # NOTE: there is deliberately no `devops_release_slug`. Release membership is the
  # `release_slug` COLUMN (the `belongs_to :release` FK, written by the sweep) —
  # read `task.release_slug`, or `task.release` for the record itself. A
  # `devops_`-prefixed reader existed here, read a same-named devops key, and fed
  # the task page a value the release lane never saw. See DEVOPS_COLUMN_KEYS.

  def devops_worktree_slug
    devops.fetch("worktree_slug", "").presence
  end

  # Free-form verbose detail agents write for each other — no length constraint
  # (the readability constraints are on title + acceptance).
  def devops_agent_context
    devops.fetch("agent_context", "").presence
  end

  # The soul who BUILT this task — stamped on any build CLAIM, a re-claim of an
  # already-`building` task included (see #enforce_builder_stamp), so the reviewer
  # pool can exclude the builder (a soul shouldn't review their own work). Source
  # precedence: an explicit soul-slug build-claim actor (`--actor <soul>`), else
  # the task's soul persona, else its assigned agent_slug — so a bare `bin/task
  # move <slug> building` records the builder WITHOUT a manual flag whenever the
  # record names one. nil only when NONE resolves to a soul, and that nil means
  # "the record does not say" — never "nobody built it". ReviewerSelector also
  # falls back to a soul actor on the `→ building` TaskEvent, and REFUSES to
  # auto-select while the answer stays unknown.
  def devops_built_by
    devops.fetch("built_by", "").presence
  end

  # EVERY soul that WORKED this task, in the order recorded — the answer `built_by`
  # cannot
  # give, because it holds one slug and a task can have several authors (a session
  # limit kills a builder mid-work and another soul finishes it). Append-only and
  # SERVER-OWNED: it is deliberately not in DEVOPS_KEYS, so a client can neither
  # write nor shrink it; #enforce_builder_stamp is the only author. ReviewerSelector
  # excludes the whole set, so a handoff no longer leaves a co-author eligible to
  # review their own diff.
  def devops_builders
    Array(devops["builders"]).map(&:to_s).select(&:present?)
  end

  # The claiming session that named NO soul while other authors were already on
  # record — i.e. "someone else worked this task and the record cannot say who".
  # Present ⇒ the author set is INCOMPLETE, ReviewerSelector reports the builder
  # UNKNOWN, and `bin/reviewer-select` refuses rather than rolling a reviewer who
  # might be that someone. Server-owned like #devops_builders.
  def devops_builders_unattributed
    devops.fetch("builders_unattributed", "").presence
  end

  # --- Session resume (V1: store + display + copy; no enforcement gate) -------
  # The Claude/Codex session that worked this task, captured by bin/task on
  # create + on the move to `building` (the claim moment). Lets the operator see
  # which terminal owns a task (the last-4 on the board + status line) and copy a
  # command to reopen it.
  def devops_session_id
    devops.fetch("session_id", "").presence
  end

  # Which CLI the session belongs to; nil is treated as "claude" (the default).
  def devops_session_provider
    devops.fetch("session_provider", "").presence
  end

  # Last 4 chars of the session id — the at-a-glance handle. nil when unset.
  def session_id_last4
    id = devops_session_id
    id && id[-4..]
  end

  # The FULL, copyable resume command (provider-aware). nil when no session id.
  def resume_command
    id = devops_session_id
    return nil unless id

    provider = devops_session_provider || "claude"
    format(RESUME_COMMANDS.fetch(provider, RESUME_COMMANDS["claude"]), id)
  end

  # Truncated display form, e.g. "claude --resume …12ab" (verb + …<last4>).
  # nil when no session id.
  def resume_command_display
    id = devops_session_id
    return nil unless id

    provider = devops_session_provider || "claude"
    format(RESUME_COMMANDS.fetch(provider, RESUME_COMMANDS["claude"]), "…#{id[-4..]}")
  end

  # --- Build claim lease (V2: the enforcement gate) -------------------------
  # The LIVE INSTANCE that owns this task while it's building — the session id
  # PLUS a per-process nonce, under a TTL lease (claim_expires_at) renewed by the
  # heartbeat (bin/statusline). `bin/task move <task> building` refuses to claim a
  # task already held by a different, non-expired instance. The lease math lives
  # in ClaimLease (shared verbatim with the standalone bin/task CLI).
  def devops_claim
    ClaimLease.from_devops(devops)
  end

  def claimed_session_id
    devops.fetch("claimed_session", "").presence
  end

  def devops_claim_nonce
    devops.fetch("claim_nonce", "").presence
  end

  # True while a non-expired claim is held — the liveness check the /tasks resume
  # control reuses ("session looks active in another terminal — resume anyway?").
  def claim_live?(now: Time.current)
    ClaimLease.live?(devops, now: now)
  end

  # Seconds since the holder's last heartbeat (nil when unclaimed / no lease).
  def claim_heartbeat_seconds_ago(now: Time.current)
    ClaimLease.heartbeat_age(devops, now: now)
  end

  # --- Review claim lease (the per-TASK review gate) ------------------------
  # A DIFFERENT lease from the build claim above: this one guards WHO is REVIEWING
  # the submitted task, stored in its own row (TaskReviewClaim) rather than in the
  # devops metadata, so many parallel pr-review sessions contend per-task and skip a
  # task already under live review. True while a non-expired review claim is held —
  # the liveness fact the `reviewable` scope filters on, exposed per-row for the API.
  def review_claim_live?(now: Time.current)
    review_claim&.live?(now: now) || false
  end

  # --- The progress fact (see the long note in ClaimLease) -------------------
  # `claim_live?` above says only "a terminal is rendering". These say what the
  # task has actually PRODUCED, read from the durable evidence we already write:
  # TaskEvents (stage moves, intents, cert checkpoints) and GateRuns (a gate
  # opening, recording a lane, or closing). No new heartbeat, no new write path —
  # a wedged agent cannot fake these, because they only exist when work landed.
  #
  # nil means UNKNOWN (a task that has produced nothing yet), and unknown always
  # reads as healthy: never invent trouble from an absence of evidence.
  PROGRESS_IN_FLIGHT_BUDGET = 6.hours # past the longest cert ever measured (321m)

  def last_progress_event
    @last_progress_event ||= progress_evidence.max_by(&:first)
  end

  def last_progress_at
    last_progress_event&.first
  end

  # What the last durable artifact WAS ("cert started", "moved to building") —
  # the difference between "no progress in 40m" and a reader who can act on it.
  def last_progress_label
    last_progress_event&.at(1)
  end

  def progress_seconds_ago(now: Time.current)
    ClaimLease.progress_age(last_progress_at, now: now)
  end

  # --- Attribution: progress belongs to whoever PRODUCED it ------------------
  #
  # The fields above answer "what has landed on this task". They do NOT answer
  # "is the holder alive", and on 2026-08-13 the claim gate treated them as if
  # they did: a challenger ran `bin/full-suite-check`, the cert landed a g1_cert
  # gate row on the task, and the gate refused that same challenger with "last
  # durable progress ~2m ago (g1_cert passed)" — the challenger's OWN work, quoted
  # back as proof the holder was working. Unowned progress gets credited to
  # whoever happens to hold the claim, which is how a lease manufactures its own
  # evidence.
  #
  # So the holder's liveness is asked of the holder's OWN artifacts, and the
  # newest artifact's owner is published beside it so no reader has to assume.

  # Who produced the newest artifact — nil when the row names nobody (an older
  # row, a plain-shell run). nil is UNKNOWN and must never be read as "the holder".
  def last_progress_actor
    last_progress_event&.at(2)
  end

  def holder_progress_event
    @holder_progress_event ||= progress_evidence_by(claimed_session_id).max_by(&:first)
  end

  def holder_progress_at
    holder_progress_event&.first
  end

  def holder_progress_label
    holder_progress_event&.at(1)
  end

  # Seconds since the CLAIM HOLDER last produced something durable. nil means the
  # holder has produced nothing we can attribute to it — which is a genuinely
  # different statement from "nothing has happened here", and the claim gate says
  # so rather than borrowing someone else's work to fill the gap.
  def holder_progress_seconds_ago(now: Time.current)
    ClaimLease.progress_age(holder_progress_at, now: now)
  end

  # A gate is demonstrably running right now (opened, never closed, and recently
  # enough to be plausible). Open gate rows latch forever when a run crashes, so
  # this is BOUNDED — an ancient open gate is not evidence of anything.
  #
  # Filtered in Ruby over the SAME association progress_evidence reads, so the board
  # (which preloads :gate_runs) answers this from loaded rows instead of issuing a
  # fresh EXISTS on every call — and the card asks two or three times per live desk.
  def gate_in_flight?(now: Time.current)
    window = (now - PROGRESS_IN_FLIGHT_BUDGET)..now

    gate_runs.any? { |gate| gate.finished_at.nil? && gate.started_at.present? && window.cover?(gate.started_at) }
  end

  # --- Reaping: the same rule, pointed the other way -------------------------
  #
  # holder_progress_* above answers "what has the holder DEMONSTRABLY produced",
  # and it is strict on purpose: the refusal MESSAGE may never claim an
  # unattributed artifact as the holder's, because inventing that owner is the
  # manufactured evidence this whole family exists to end.
  #
  # The REAPING decision obeys the same master rule — never invent evidence —
  # but it is asserting the OPPOSITE proposition. The message argues the holder
  # is ALIVE; the heartbeat argues it is GONE. So an unsigned row has to fall on
  # the opposite side of each: it is not proof the holder worked (the message
  # must not cite it) and equally not proof the holder didn't (the heartbeat must
  # not reap on it). A gate run written before bin/gate stamped its session is
  # exactly such a row, and reading its silence as "not the holder" would evict a
  # live worker on the strength of a missing field.
  #
  # So here an artifact counts as the holder's unless it is DEMONSTRABLY someone
  # else's. That is what closes the incident: a queued challenger's checkpoint and
  # g1_cert are stamped with the CHALLENGER's session, so they are demonstrably
  # not the holder's, and they stop propping up an abandoned lease — while every
  # unknown still keeps the desk.

  # Seconds since the newest artifact not demonstrably someone else's. nil when
  # the task has none at all (known-absent, not unknown — nothing has ever landed
  # here, by anyone).
  def holder_liveness_seconds_ago(now: Time.current)
    ClaimLease.progress_age(undisowned_progress_event&.first, now: now)
  end

  # A gate that could be the holder's is running right now. Same bounded window as
  # gate_in_flight?, minus the runs another session signed — the challenger's cert
  # that renewed an abandoned lease for another 1h29m.
  #
  # The channel itself stays: a cert writes NOTHING into the desk for up to the
  # measured 94-minute p99, so dropping it would reap a holder mid-cert. Filtering
  # it by actor keeps that protection for the holder and denies it to everyone else.
  def holder_gate_in_flight?(now: Time.current)
    window = (now - PROGRESS_IN_FLIGHT_BUDGET)..now

    gate_runs.any? do |gate|
      gate.finished_at.nil? && gate.started_at.present? && window.cover?(gate.started_at) &&
        !disowned?(gate)
    end
  end

  # Held by a live session, yet nothing durable has landed in a long time.
  # Informational only — it reclaims nothing and blocks nothing.
  #
  # Measured against the HOLDER's own artifacts whenever the holder has any, for
  # the same reason the claim gate's refusal is: a chip that counts anyone's work
  # as the holder's says "healthy" the moment a second agent runs a cert on the
  # task, which is precisely when a reader most needs the truth. Falls back to the
  # task-wide fact when nothing is attributable, so an older row (no session on
  # its events) keeps the signal it has rather than going blind.
  def claim_progress_quiet?(now: Time.current)
    ClaimLease.quiet?(devops,
                      last_progress_at: holder_progress_at || last_progress_at,
                      in_flight: holder_gate_in_flight?(now: now),
                      now: now)
  end


  def devops_repositories
    devops_list("repositories")
  end

  def devops_risk_tags
    devops_list("risk_tags")
  end

  def devops_acceptance
    devops_list("acceptance")
  end

  def devops_test_plan
    devops_list("test_plan")
  end

  def devops_checks_run
    devops_list("checks_run")
  end

  # The open-PR archive gate's abandonment receipt (lib/open_pr_guard.rb): one line
  # per PR that `bin/task move <slug> archived --force` deliberately dropped. Its
  # entire purpose is that a LATER READER can tell a dropped PR from a forgotten
  # one, so it needs a reader on the surfaces a human actually opens.
  def devops_abandoned_prs
    devops_list("abandoned_prs")
  end

  def approval_status
    devops.fetch("approval_status", "").presence
  end

  def waiting_for_operator_approval?
    approval_status == OPERATOR_APPROVAL_WAITING
  end

  def unresolved_feedback_activity
    self.class.unresolved_feedback_by_slug([slug])[slug]
  end

  def unresolved_feedback?
    unresolved_feedback_activity.present?
  end

  # FRESH BUILD OR RESUBMISSION? A `--kind rework` block leaves the task on
  # `building` (Task#block!), so a bounced task and a never-reviewed one are the same
  # shape on the board. This is the distinction, and it is answered by the TREE (has
  # the PR head moved since the bounce?) rather than by #unresolved_feedback?, which
  # is cleared by an explicit ceremony and not by the work landing. Full rationale and
  # the three measured instances: Task::Resubmission.
  #
  # Board rendering preloads the batch (Task::Resubmission.for_tasks) and passes it in;
  # a single-card Turbo render, the show page and tests self-query.
  #
  # DELIBERATELY NOT MEMOIZED, and that is a correctness rule rather than a
  # preference. Task broadcasts its card on commit (#broadcast_block_change and the
  # other after_*_commit hooks render DeploymentsBroadcaster#card_locals), so a
  # `||=` here is evaluated on the LIVE instance at create/update time — before the
  # qa_feedback row that makes the task a resubmission exists. That froze `:fresh`
  # onto the instance, and every later read on it, including the card render, served
  # the stale verdict. Measured while building this: the model answered :unaddressed
  # and the instance answered :fresh, in the same test, one line apart. A signal
  # whose whole job is to stop a reader trusting a stale field must not itself be a
  # stale field. Callers that need it more than once hold the value (the controller
  # assigns @resubmission; the boards pass the batch as a local).
  def resubmission
    Task::Resubmission.for(self)
  end

  # Has this task ever carried a blocking qa_feedback (a QA block), resolved or
  # not? The "was it ever blocked" half of #block_state — distinct from
  # #unresolved_feedback? (an OPEN qa_feedback) and #blocked? (a LIVE block, from
  # the blocked_at column).
  def ever_blocked?
    Activity.for_task(self).by_type("qa_feedback").exists?
  end

  # The card's block lifecycle as a tri-state:
  #   :blocked — a LIVE block (#blocked?, off the blocked_at column) OR an
  #              unresolved qa_feedback is open (red card)
  #   :cleared — was blocked, the block is resolved, and it is back in `submitted`
  #              awaiting a re-review (the light-yellow "look again" card)
  #   :never   — no live block: never blocked, already re-reviewed past submitted
  #              (the yellow clears once it advances), or re-blocked (→ :blocked)
  # Board rendering passes preloaded `unresolved:`/`ever_blocked:` booleans to
  # avoid N+1; omit them (single-card Turbo render, the show page, tests) and it
  # self-queries.
  def block_state(unresolved: nil, ever_blocked: nil)
    unresolved = unresolved_feedback? if unresolved.nil?
    return :blocked if blocked? || unresolved

    ever_blocked = ever_blocked?() if ever_blocked.nil?
    return :cleared if stage == "submitted" && ever_blocked

    :never
  end

  # `events:` rides through to open_intents_for — same parameter-not-sniff contract
  # as everything else on this path. The boards call this once PER CARD, so on a
  # column of submitted work it was the last per-card pair of queries left.
  def review_in_progress?(events: nil)
    stage == "submitted" && open_intent_for("reviewed", events: events).present? && review_claim_alive?
  end

  # Is the review lane's face still TRUE? An open intent says a review STARTED; it
  # cannot say the reviewer is still alive, because an intent only closes when the
  # →reviewed transition lands. A crashed reviewer therefore left a face on the board
  # asserting a live review forever. The review CLAIM is the liveness primitive — a
  # TTL lease its holder heartbeats — so when a claim row exists, defer to it: the
  # seat empties within the TTL of the reviewer dying, and immediately on a clean
  # release.
  #
  # Claim-less intents still read live, deliberately: `bin/reviewer-select` records
  # the pair before any reviewer claims, and a hand-run review may never claim at
  # all. Absent evidence of death is not evidence of death.
  #
  # THIS IS THE ONE RULE, and it lives here because there are TWO readers and a
  # first version of this change hardened only one of them. `review_in_progress?`
  # is a PREDICATE the board asks; `StageAgentsHelper#in_progress_work` is what
  # actually DRAWS the face, and it rebuilt the review lane straight from the open
  # intent — so the seat kept ticking for a dead reviewer even though the predicate
  # said otherwise. Both now ask this method; a third reader must ask it too.
  def review_claim_alive?
    claim = TaskReviewClaim.find_by(task_slug: slug)
    claim.nil? || claim.live?
  end

  # The two senior reviewers Avi assigned for the `submitted` review (the Deploy
  # half's review step), each `{ "slug" => ..., "weight" => "primary"|"light" }`
  # (legacy intents recorded before the rename still read "heavy" — treated as
  # "primary"),
  # read off THIS task's own `metadata["reviewers"]`. NOTE: the canonical write
  # target for the avatars UI is the submitted→reviewed TaskEvent's metadata (see
  # #stage_event_metadata) — StageAgentsHelper#stage_agent_groups reads the event,
  # not this. This stays for callers that store the pair on the task itself.
  # Old-flow tasks that predate the two-senior model have none → empty list.
  def reviewers
    self.class.normalize_reviewers(metadata["reviewers"])
  end

  # Record an INTENT: an agent (or the two-senior review pair) STARTING the work
  # that will produce `to_stage`, the moment that work begins — so the board and
  # the task timeline can show WHO is on it with a live ticker before the
  # transition lands. Appends a TaskEvent(kind: intent) FROM the current stage TO
  # to_stage, carrying `actor` (a single owner — Avi at QA, Steffon at ship)
  # and/or `reviewers` metadata (the primary/light pair at review). Append-only +
  # current-cycle scoped: only the current stage's immediate next target is
  # recordable; an identical open intent (same target + same crew) is returned
  # as-is rather than stacked; and it is a no-op once to_stage has landed in the
  # current stage cycle. If rework sends a task back to `submitted`, a fresh
  # `→reviewed` intent can open for that new cycle.
  #
  # An intent row is intentionally USAGELESS — it marks work STARTING, not a
  # completed transition, so it carries no model/tokens/cost. The work the agent
  # burns between an intent and its transition is captured on the TRANSITION
  # event instead: the intent SEEDS the per-session usage baseline (bin/task
  # intent / bin/reviewer-select), and the later move/flip records the delta.
  #
  # `qa: true` marks the Avi assembled-QA intent (see
  # Release::Conductor#record_qa_intent): in the standard flow the merge already
  # flipped the member to `assembled`, so the QA intent rides toward `shipped`
  # (superseded by the SHIP, not the merge) and is distinguished from Steffon's ship
  # intent — same target — by this marker. Idempotency therefore matches on the
  # FULL identity (target + actor + reviewers + qa), not merely the last intent for
  # the target, so two distinct open intents toward the same stage never collide.
  def record_intent_event(to_stage:, actor: nil, reviewers: nil, source: nil, qa: false)
    to_stage = to_stage.to_s
    return nil unless NEXT_INTENT_STAGE[stage] == to_stage
    return nil if target_landed_in_current_stage?(to_stage)

    pair  = reviewers.present? ? self.class.normalize_reviewers(reviewers).presence : nil
    actor = actor.to_s.strip.presence
    qa    = !!qa

    existing = open_intents_for(to_stage).reverse.find do |e|
      e.actor == actor &&
        self.class.normalize_reviewers(e.metadata["reviewers"]).presence == pair &&
        !!e.metadata["qa"] == qa
    end
    return existing if existing

    metadata = {}
    metadata["reviewers"] = pair if pair
    metadata["qa"] = true if qa

    task_events.create!(
      kind: TaskEvent::INTENT,
      from_stage: stage,
      to_stage: to_stage,
      occurred_at: Time.current,
      seconds_in_from: nil,
      source: (source.presence || Current.task_event_source).presence,
      actor: actor,
      metadata: metadata
    )
  end

  def record_checkpoint_event(name:, status:, actor: nil, source: nil, metadata: {})
    task_events.create!(
      kind: TaskEvent::CHECKPOINT,
      from_stage: stage,
      to_stage: name.to_s,
      occurred_at: Time.current,
      seconds_in_from: nil,
      source: (source.presence || Current.task_event_source).presence,
      actor: actor.to_s.strip.presence || Current.task_event_actor.presence,
      **task_event_usage_attrs,
      metadata: metadata.to_h.merge("status" => status.to_s)
    )
  end

  def record_review_check_in(role:, moment:, status: nil, actor: nil, source: nil, message: nil, idempotency_key: nil, metadata: {})
    role = self.class.normalize_review_role(role)
    raise ArgumentError, "review role must be primary or light" unless REVIEW_ROLES.include?(role)

    moment = self.class.normalize_review_moment(moment)
    raise ArgumentError, "review moment is required" if moment.blank?
    unless REVIEW_MOMENTS.fetch(role).include?(moment)
      raise ArgumentError, "review moment must be one of: #{REVIEW_MOMENTS.fetch(role).join(', ')}"
    end

    status = self.class.normalize_review_status(status.presence || default_review_status_for(moment))
    unless REVIEW_STATUSES.include?(status)
      raise ArgumentError, "review status must be one of: #{REVIEW_STATUSES.join(', ')}"
    end

    key = idempotency_key.to_s.strip.presence
    if key
      existing = task_events.checkpoints.where("metadata ->> 'idempotency_key' = ?", key).first
      return existing if existing
    end

    review_metadata = metadata.to_h.merge(
      "stage" => "reviewed",
      "event" => "review_check_in",
      "review_role" => role,
      "review_moment" => moment,
      "moment_label" => self.class.review_moment_label(role, moment)
    )
    review_metadata["message"] = message.to_s.strip if message.present?
    review_metadata["idempotency_key"] = key if key

    record_checkpoint_event(
      name: "review_#{role}_#{moment}",
      status: status,
      actor: actor,
      source: source,
      metadata: review_metadata
    )
  end

  def review_check_in_events
    task_events.checkpoints.chronological.to_a.select(&:review_check_in?)
  end

  # The OPEN intent event for `to_stage` (work has STARTED toward that stage but no
  # later transition into it has landed yet), or nil once it's resolved by a
  # transition — so a non-nil result means "work is in progress on this stage right
  # now". Scope is cycle-aware: if QA blocks a task and it re-enters `submitted`,
  # old review intents from the prior submitted cycle are closed even if no
  # `→reviewed` transition ever landed, and a fresh review intent can open.
  def open_intent_for(to_stage, events: nil)
    open_intents_for(to_stage, events: events).last
  end

  # Avi's crew-seat duration, measured from WHEN HE PICKED THE TASK UP rather
  # than from when review handed the task over.
  #
  # The transition's own `seconds_in_from` cannot answer this: it measures back
  # to the previous TRANSITION by design, so `reviewed -> assembled` is
  # inherently `assembled_at - reviewed_at` — which is mostly the time the task
  # sat in the queue waiting for a sweep, not time anyone worked on it. Measured
  # on rel-20260818-63bdb8, whose four members all assembled at the same second:
  # 148m, 134m, 120m and 49m. Those four numbers differ ONLY by when each task
  # entered the lane. Avi ran ONE batch sweep across all four.
  #
  # `bin/release prepare` already records an INTENT row the moment it picks a
  # member up (Release::Conductor#record_qa_intent), so the pickup time exists;
  # it is simply excluded from `seconds_in_from`, deliberately and correctly —
  # an intent is the live "who's on it" signal, not a stage boundary, and
  # widening the transitions scope to include intents would also shorten the
  # REVIEW seat and rewrite every historical reading. So this reads the intent
  # directly at render time and leaves that rule untouched.
  #
  # EXPECT EVERY MEMBER OF ONE SWEEP TO REPORT THE SAME NUMBER. That is the
  # honest reading of a batch operation, not a bug.
  #
  # nil when there is no pickup row to measure from — a task assembled before
  # the intent existed, or by a path that records none. The caller falls back to
  # the transition figure rather than rendering blank.
  #
  # `events:` — the caller's already-loaded TaskEvents, when it has them. This is
  # the board's fast path and the reason the parameter exists: it used to call
  # `task_events.transitions.where(to_stage: …)`, and a `.where` on a LOADED
  # association still issues SQL, so the boards' `includes(:task_events)` bought
  # nothing here. Two queries per assembled/shipped card, 62 of the 149 uncached
  # queries a production /deployments render made (2026-08-19).
  #
  # A PARAMETER, not a peek at `task_events.loaded?`, and that distinction is the
  # whole safety of this. A loaded association can be STALE: the model stamps its
  # own transition event on save, so an instance whose rows are later rewritten by
  # `update_all`, by another instance, or by a replayed fixture still holds the OLD
  # occurred_at in memory — and reading that silently returns a wrong DURATION
  # rather than failing. Sniffing `loaded?` would have opted every such caller in
  # without asking. (Caught by CI: TaskAssembledSeatTest's fixture rewrites the
  # transition with update_all, and the sniffing version read 30m for a 20m seat.)
  #
  # So the default stays SQL — every existing caller reads the truth — and only a
  # caller holding a genuinely fresh array opts in. The board's is a per-request
  # preload, which is exactly that.
  def assembled_seconds_from_pickup(events: nil)
    # The assemble MOMENT comes from the transition event, not the assembled_at
    # column, because the card's cluster is built from task_events and the two
    # must not be able to disagree. Production stamps both; a caller that
    # replays events without the column would otherwise silently get nil here
    # while the card still drew a duration from the same events.
    #
    # Filtered in RUBY over the loaded events (see #board_read_events), not with
    # `.where`: this runs once per assembled/shipped CARD on a board that already
    # preloaded :task_events, and the two `.where` calls it used to make were 62 of
    # the 149 uncached queries a production /deployments render issued.
    landed_at = assembled_landing_at(events)
    return nil unless landed_at

    pickup = latest_assembled_pickup(events, landed_at)
    return nil unless pickup

    (landed_at - pickup.occurred_at).round
  end

  # When the assemble LANDED. Prefers the transition event over the assembled_at
  # column so the card and the model cannot disagree.
  def assembled_landing_at(events)
    landed =
      if events
        latest_event(events) { |e| e.transition? && e.to_stage == "assembled" }
      else
        task_events.transitions.where(to_stage: "assembled").chronological.last
      end
    landed&.occurred_at || assembled_at
  end

  # Avi's pickup intent for that landing — the latest one at or before it.
  def latest_assembled_pickup(events, landed_at)
    if events
      latest_event(events) { |e| e.intent? && e.to_stage == "assembled" && e.occurred_at <= landed_at }
    else
      task_events.intents.where(to_stage: "assembled")
                 .where(occurred_at: ..landed_at).chronological.last
    end
  end

  # `chronological.last` in Ruby: newest by (occurred_at, id), matching the scope's
  # `order(occurred_at: :asc, id: :asc)`. Both columns are NOT NULL in the schema,
  # so the tuple compare is total.
  def latest_event(events)
    events.select { |event| yield(event) }.max_by { |event| [event.occurred_at, event.id.to_i] }
  end

  # `events:` — the caller's already-resolved TaskEvents, same contract and same
  # reasoning as #assembled_seconds_from_pickup above: a PARAMETER with the SQL
  # default, never a `task_events.loaded?` sniff, because a loaded association can
  # be stale and a stale read here silently changes WHICH intents count as open.
  #
  # That default is what keeps `record_intent_event` safe. This method is its
  # idempotency guard — a write path — and it calls with no events, so it still
  # asks the database. Only the board's crew partial, holding a fresh per-request
  # preload, opts in. That was 2 queries per SUBMITTED and REVIEWED card
  # (open_intents_for itself, plus current_stage_entry_event re-read per intent).
  def open_intents_for(to_stage, events: nil)
    to_stage = to_stage.to_s
    return [] unless NEXT_INTENT_STAGE[stage] == to_stage

    # Resolved ONCE for the whole rejection pass, not per intent. It used to be
    # re-read inside intent_started_in_current_stage? for every candidate, which
    # is a query per intent on the SQL path and pointless work on the array path.
    # Passed down rather than memoised on the instance, so its lifetime is exactly
    # this call — the same tight-lifetime rule that made a view-context memo the
    # wrong answer for release_ci_progress.
    entry = current_stage_entry_event(events: events)

    open_intent_candidates(to_stage, events).reject do |intent|
      !intent_started_in_current_stage?(intent, entry: entry) ||
        intent_superseded?(intent, events: events)
    end
  end

  # The →to_stage intents, oldest first — `chronological` in Ruby when the caller
  # brought its own events.
  def open_intent_candidates(to_stage, events)
    return task_events.intents.where(to_stage: to_stage).chronological.to_a unless events

    events.select { |event| event.intent? && event.to_stage == to_stage }
          .sort_by { |event| [event.occurred_at, event.id.to_i] }
  end

  # The reviewer pair (normalized) recorded on the latest review intent, or nil —
  # ties the completed →reviewed event back to the pair that actually started.
  def latest_intent_reviewers(to_stage = "reviewed")
    intent = task_events.intents.where(to_stage: to_stage).chronological.last
    intent && self.class.normalize_reviewers(intent.metadata["reviewers"]).presence
  end

  # Has the target transition already landed in the task's CURRENT stage cycle?
  # This keeps retries idempotent after the target lands, while still allowing a
  # reworked task to re-enter `submitted` and open a second `→reviewed` intent.
  def target_landed_in_current_stage?(to_stage)
    entry = current_stage_entry_event
    landed = task_events.transitions.where(to_stage: to_stage)
    return landed.exists? if entry.nil?

    landed.where(
      "occurred_at > ? OR (occurred_at = ? AND id >= ?)",
      entry.occurred_at, entry.occurred_at, entry.id
    ).exists?
  end

  def current_stage_entry_event(events: nil)
    return latest_event(events) { |e| e.transition? && e.to_stage == stage } if events

    task_events.transitions.where(to_stage: stage).chronological.last
  end

  # `entry:` is REQUIRED — the caller resolves the stage-entry event once and hands
  # it in, so this cannot re-query per intent. There is exactly one caller.
  def intent_started_in_current_stage?(intent, entry:)
    return false unless intent.from_stage == stage
    return true if entry.nil?

    intent.occurred_at > entry.occurred_at ||
      (intent.occurred_at == entry.occurred_at && intent.id.to_i >= entry.id.to_i)
  end

  # An intent is live only while the task remains in its source-stage cycle. It
  # closes when the target lands OR when any later transition leaves the source
  # stage (direct QA block, archive, etc.).
  #
  # The Ruby branch mirrors the SQL predicate term for term — same OR on the two
  # stage columns, same strict (occurred_at, id) tiebreak — so the two paths can
  # only ever agree. `any?` rather than a full select: this is an existence check.
  def intent_superseded?(intent, events: nil)
    return superseded_by?(events, intent) if events

    task_events.transitions.where(
      "(to_stage = :target OR from_stage = :source) AND " \
        "(occurred_at > :occurred_at OR (occurred_at = :occurred_at AND id > :id))",
      target: intent.to_stage,
      source: intent.from_stage,
      occurred_at: intent.occurred_at,
      id: intent.id
    ).exists?
  end

  def superseded_by?(events, intent)
    events.any? do |event|
      next false unless event.transition?
      next false unless event.to_stage == intent.to_stage || event.from_stage == intent.from_stage

      event.occurred_at > intent.occurred_at ||
        (event.occurred_at == intent.occurred_at && event.id.to_i > intent.id.to_i)
    end
  end

  def devops_url(name)
    devops.fetch("#{name}_url", "").presence
  end

  def devops_field(name)
    devops.fetch(name.to_s, "").presence
  end

  def requires_release_conductor?
    ActiveModel::Type::Boolean.new.cast(devops.fetch("requires_release_conductor", false))
  end

  # Per-application RELEASE INCLUSION — Avi's disposition over the `reviewed` queue in
  # `qa-release`. The DEFAULT is to ship EVERY reviewed task (this reads true when the
  # flag is unset), so a plain reviewed task rides the next candidate. Avi HOLDS an
  # application back — when order-of-operations matters, e.g. a gem that must publish
  # before its consumer, or an app that should wait a release — by marking its reviewed
  # tasks `included_in_release: false`. That decision is board-visible on the reviewed
  # stage (the card's inclusion marker) and enforced through the existing sweep controls
  # (`bin/release prepare --task …` / `bin/release eject`). A blank/absent flag is
  # included; only an explicit false holds a member out.
  def included_in_release?
    ActiveModel::Type::Boolean.new.cast(devops.fetch("included_in_release", true))
  end

  # EVERY ecosystem repo this task ships through — its full release identity, and
  # the set the Deploy workflow must promote, QA and ship. Ordered: the PRIMARY
  # repo first (#release_repo, unchanged), then any repo with a recorded PR url,
  # then the rest of the declared `repositories`.
  #
  # THIS IS THE FIX for the 2026-08-13 half-ship. Every release stage read the
  # SINGULAR #release_repo — the promote list (`bin/release` prepare step 4), the
  # member plan, the repo plan, the pre-QA gate, the QA deploy and the ship — so a
  # task's whole release identity collapsed to whichever repo its ONE `pr_url`
  # named. `land-rails-security-patch` named [mcritchie-studio, turf-monster] with
  # a hub PR url: turf was never promoted, never QA'd and never shipped, while the
  # task was stamped shipped+main. Callers that plan work MUST use this; #release_repo
  # remains only for the single "which repo is this task's home" answers (gem-vs-app
  # kind, the board's app badge).
  def release_repos
    ([ release_repo ] + release_pr_urls.keys + devops_repositories).compact_blank.uniq
  end

  # The PRIMARY ecosystem repo this task's PR/branch lives in — the unit the Deploy
  # workflow classifies as a gem (producer) or an app (consumer). Prefer the
  # repo parsed from the PR url (github.com/<owner>/<repo>/pull/N), since that's
  # where the branch actually is; fall back to the declared repositories — for a
  # `library` shape the gem repo named there, otherwise the first entry.
  #
  # NOT the task's release identity when it names more than one repo — see
  # #release_repos, and never re-derive a promote/deploy set from this.
  def release_repo
    repo_from_pr_url.presence ||
      if devops_shape == "library"
        devops_repositories.find { |repo| Release::Repos.gem?(repo) } || devops_repositories.first
      else
        devops_repositories.first
      end
  end

  # { "<repo>" => "<pr url>" } for every PR this task landed, the singular
  # `pr_url` included (keyed by the repo it names). The per-repo register that
  # gives a second repo's PR somewhere to live — see DEVOPS_MAP_KEYS.
  #
  # THE SINGULAR WINS FOR ITS OWN REPO — it is merged in LAST, over any `pr_urls`
  # entry naming the same repo. That precedence is deliberate. `pr_url` is the
  # field the rest of the pipeline already acts on: #release_repo parses it,
  # bin/dor-check and bin/pr-review read it, and ReviewPendingActionsController
  # links to it. If a map entry could override it, the pipeline would hold two
  # different PRs for one repo and say nothing about the divergence — and the
  # obvious operator correction (`bin/task update <slug> --pr-url <right-url>`)
  # would be silently undone by whatever stale entry was recorded first. One
  # repo, one authoritative PR, and it is the one every other reader already
  # sees. This map's job is the repos `pr_url` cannot reach, not a second
  # opinion about the repo it already names.
  def release_pr_urls
    map = devops.fetch("pr_urls", {})
    map = map.is_a?(Hash) ? map.to_h { |repo, url| [repo.to_s.strip, url.to_s.strip] } : {}
    primary = devops_url("pr").to_s
    primary_repo = self.class.repo_from_pr_url(primary)
    map = map.merge(primary_repo => primary) if primary_repo.present? && primary.present?
    map.reject { |repo, url| repo.blank? || url.blank? }
  end

  # The repos this task is EXPECTED to carry its own PR in — the set
  # #repos_missing_pr_url measures coverage against.
  #
  # For an app task that is simply every repo it names: each one needs its own PR
  # merged onto its own `accepted`, and a repo without one is invisible to the
  # release lane.
  #
  # A GEM task is different IN KIND, and reading `repositories` literally there
  # produces the exact inversion of the failure this measures. A studio-engine
  # task names the gem AND the consumers that must pick the new version up —
  # [studio-engine, mcritchie-studio, turf-monster] — but the work is ONE PR, in
  # the gem repo. The consumers reach production through a published version and
  # the conductor's bump, not through a PR the builder opens; those PRs must
  # never exist. Measured literally, every legitimate engine release would report
  # both consumers "missing a PR" — refusing the release for the absence of work
  # nobody is supposed to do, which is the opposite of the hole being closed.
  #
  # So a gem task is measured against the GEM repos in play: the gem repos it
  # names, or (when it names none — the PR lives in a repo `repositories` never
  # listed) the gem repos it actually recorded a PR for. If neither exists there
  # is no gem evidence at all, and it falls back to the literal list rather than
  # reporting full coverage off an empty set.
  def pr_bearing_repositories
    return devops_repositories unless gem_release?

    named_gems = devops_repositories.select { |repo| Release::Repos.gem?(repo) }
    return named_gems if named_gems.any?

    recorded_gems = release_pr_urls.keys.select { |repo| Release::Repos.gem?(repo) }
    recorded_gems.presence || devops_repositories
  end

  # Repos this task is expected to carry a PR in but recorded none for. A
  # non-empty answer on a multi-repo task is the 2026-08-13 shape exactly: the
  # work exists in a repo the pipeline has no evidence for, so nothing can prove
  # its code reached `accepted`.
  #
  # IT IS ENFORCED NOW: `Release::Conductor.validate_member_pr_coverage!` (reached
  # from validate_members!, which every sweep write runs inside its transaction)
  # raises on a non-empty answer, so a member with a repo the record cannot vouch
  # for is refused rather than swept. This method IS the rule, delegated to
  # `Release::SweepPlan.repo_coverage_gap` so the CLI's pre-promote screen and the
  # record-time backstop answer identically — two spellings of one rule is how the
  # screen and the guard drift apart.
  #
  # Reading `release_repos` rather than `devops_repositories` widens the input to
  # the task's full release identity (the PR-derived repo included), and the rule's
  # own `size < 2` guard is why a SINGLE-repo task is never an offender: it cannot
  # lose a repo it never had a second of, and its missing PR is the review lane's
  # problem, not the sweep's.
  #
  # `release_kind` is passed because A GEM RELEASE IS EXEMPT, and this method is
  # where that would otherwise bite hardest: `release_pr_urls` keys the singular
  # `pr_url` by the repo its URL parses to, so a `library` task whose PR lives in
  # the GEM repo while `repositories` names the CONSUMERS would report EVERY
  # consumer missing. Live example, 2026-08-14: guard-engine-migration-rollback
  # names [studio-engine, mcritchie-studio, turf-monster, mcritchie-industries]
  # behind one studio-engine PR. Refusing that would block every engine release,
  # for a URL that does not exist — the pipeline authors the consumer's change
  # itself (bump_consumer_locks_for_qa). See Release::SweepPlan#repo_coverage_gap.
  def repos_missing_pr_url
    Release::SweepPlan.repo_coverage_gap(repos: release_repos, pr_repos: release_pr_urls.keys,
                                         expected: pr_bearing_repositories)
  end

  # True when this task ships as a published gem rather than a deployed app — a
  # `library` shape always is, and so is anything whose release_repo is a
  # registered gem. Drives producer-first ordering and the board 💎 gem badge.
  def gem_release?
    devops_shape == "library" || Release::Repos.gem?(release_repo)
  end

  # :gem / :app / :unknown — the member kind the conductor orders + plans by.
  def release_kind
    return :gem if gem_release?

    Release::Repos.kind(release_repo)
  end

  # A LIVE block: the task carries an unresolved block marker (blocked_at set)
  # while it sits in `building`. blocked_at persists as history after the task
  # advances (release notes read it), so the `building` gate is what distinguishes
  # "currently blocked" from "was blocked". #block! sets it; #unblock! clears it.
  def blocked?
    blocked_at.present? && stage == "building"
  end

  # Why the task is blocked (environment / rework / dependency) — a real column
  # now (promoted out of devops), stamped by #block!. `block_kind` is provided by
  # ActiveRecord; a blank column reads as nil.
  def stage_label
    STAGE_LABELS.fetch(stage, stage.to_s.humanize)
  end

  # The active (gerund) label for a stage — e.g. "Assembling" for `assembled` —
  # for UI showing that stage still in progress. Falls back to the noun label,
  # then a humanized key, so an unknown stage never blanks out.
  def self.active_stage_label(stage)
    STAGE_ACTIVE_LABELS[stage] || STAGE_LABELS.fetch(stage, stage.to_s.humanize)
  end

  # The MEASURED total tokens for this task — the sum of tokens_total across every
  # TaskEvent on its spine (a missing token field counts as 0). Feeds the
  # /intelligence token charts; actual_size now sizes on $cost (see
  # #derive_actual_size), NOT this. Computed in SQL off a fresh relation so it
  # never reads a stale loaded-association cache mid-transaction.
  def measured_tokens_total
    TaskEvent.where(task_slug: slug)
             .sum(Arel.sql("COALESCE(tokens_in, 0) + COALESCE(tokens_out, 0)"))
  end

  # The MEASURED total cost for this task — the sum of `cost` (USD) across every
  # TaskEvent on its spine. SQL SUM ignores NULL costs, so an unpriced event
  # counts as 0; returns a BigDecimal, and 0 when the task has no events. Computed
  # in SQL off a fresh relation (like #measured_tokens_total) so it never reads a
  # stale loaded-association cache mid-transaction. Powers the release-notes card.
  def total_cost
    TaskEvent.where(task_slug: slug).sum(:cost)
  end

  # The actual_size this task's measured $COST maps to via ACTUAL_SIZE_COST_THRESHOLDS,
  # or nil when there's NO measured cost (zero) — an honest "can't size it" rather
  # than a misleading "small" for a task whose usage was never captured/priced.
  # Sizes on cost, not tokens: cost is ground-truth priced, while the token total
  # is ~98% cache_read and pinned everything to XL. Pure (no writes): callers
  # decide whether to persist it.
  def derive_actual_size
    cost = total_cost
    return nil if cost.nil? || cost.zero?

    ACTUAL_SIZE_COST_THRESHOLDS.find { |_size, ceiling| cost < ceiling }&.first
  end

  # Apply a PARTIAL devops write on top of what the task already carries.
  #
  # The board UI posts a SUBSET of devops — the fields `tasks/_form.html.erb`
  # renders, narrowed again by TasksController#task_params' permit list.
  # Everything else a task carries (`agent_context`, `built_by`, `gem_bump`,
  # `pr_urls`, the mascot/session keys) is missing from that post because the
  # form has no field for it, NOT because anyone asked for it to go. Writing the
  # normalized post over `metadata["devops"]` wholesale — what TasksController
  # used to do — therefore DELETED every one of them on any edit, silently, with
  # a 200. `agent_context` is often the only place a task carries its reasoning.
  #
  # So the write merges, keyed on WHICH NAMES THE CALLER POSTED rather than on
  # which values survived normalization:
  #
  #   * a name the post does not carry → UNCHANGED (the default is now preserve)
  #   * a name the post does carry     → AUTHORITATIVE, blank included, so
  #                                      emptying a field in the browser still
  #                                      clears it
  #
  # KEYING ON THE POSTED NAMES IS WHAT KEEPS BOTH HALVES TRUE AT ONCE, and it is
  # the whole trick — neither simpler shape works. Merging only the NORMALIZED
  # hash would preserve everything, but `normalize_devops_metadata` drops blanks,
  # so a field the operator cleared would read as "unchanged" and NO field could
  # ever be emptied from the browser. Replacing wholesale destroys every unposted
  # name. The posted-name set separates "absent" from "present and blank", which
  # the normalized hash alone cannot express.
  #
  # This inverts the default from destroy-unless-listed to preserve-unless-posted,
  # so a devops key added to the model later survives a board edit WITHOUT anyone
  # remembering to touch the permit list. The permit list still governs what a
  # form may WRITE; it no longer governs what survives.
  #
  # `& DEVOPS_KEYS` keeps a posted name that is not storable devops from deleting
  # anything — the permit list carries DEVOPS_COLUMN_KEYS names only so the
  # normalizer can refuse them out loud, and a refusal must not also be a delete.
  #
  # Pure: returns the merged hash and writes nothing. Raises whatever
  # normalize_devops_metadata raises (both controllers turn that into a 422).
  def self.merge_devops_metadata(existing, raw)
    normalized = normalize_devops_metadata(raw)
    posted = raw.to_h.keys.map(&:to_s) & DEVOPS_KEYS

    (existing || {}).to_h.deep_dup.except(*posted).merge(normalized)
  end

  # Fold a PARTIAL devops post into a task's FULL metadata hash — the ONE
  # implementation both write paths share.
  #
  # WHY IT LIVES ON THE MODEL. This fold used to be a private method on
  # TasksController (the board form), so the JSON API — the path every agent and
  # every bin/ script writes through — did not have it, and assigned the metadata
  # column from the posted params instead. Two controllers, one field name,
  # OPPOSITE semantics. On 2026-08-30 a one-key PATCH
  # ({"devops": {"included_in_release": false}}) took a REVIEWED task from 20
  # devops keys to 8 at HTTP 200 with no warning, and seven of the lost names —
  # acceptance, agent_context, checks_run, risk_tags among them — existed nowhere
  # else to restore from. The board keeps no task-version history, so prevention
  # is the whole remedy. Putting the fold here is what stops the paths drifting
  # apart again: a new caller gets the merge by construction rather than by
  # remembering to copy it.
  #
  # BOTH halves of the metadata column are preserved:
  #   * names OUTSIDE "devops" ride through untouched — the API used to replace
  #     them too, so a devops PATCH silently dropped every other metadata name.
  #   * names INSIDE "devops" follow merge_devops_metadata's posted-name rule —
  #     unposted means UNCHANGED, posted-and-blank still CLEARS. Deletion stays
  #     expressible; it just has to be said out loud instead of happening by
  #     omission.
  #
  # The "devops" key itself is DROPPED when the merge empties it, so a task with
  # no devops data carries no empty hash — Task#devops? and the show page's
  # handoff panel both key off presence.
  #
  # Pure: returns a new hash and writes nothing. Raises whatever
  # normalize_devops_metadata raises (both controllers turn that into a 422).
  def self.merge_devops_into_metadata(metadata, raw_devops)
    base = (metadata || {}).to_h.deep_dup
    merged = merge_devops_metadata(base["devops"], raw_devops)
    if merged.any?
      base["devops"] = merged
    else
      base.delete("devops")
    end
    base
  end

  def self.normalize_devops_metadata(raw)
    return {} if raw.blank?

    raw.to_h.each_with_object({}) do |(key, value), normalized|
      key = key.to_s
      normalized_value =
        if DEVOPS_MAP_KEYS.include?(key)
          normalize_devops_map(value)
        elsif DEVOPS_LIST_KEYS.include?(key)
          normalize_devops_list(value)
        else
          value.to_s.strip
        end
      next if normalized_value.blank?

      # Column-backed name: refuse LOUDLY and say where it lives. Checked after the
      # blank guard (a blank asserts nothing) and BEFORE the whitelist, so it can
      # never decay back into the silent skip this exists to prevent.
      if (home = DEVOPS_COLUMN_KEYS[key])
        raise ArgumentError, "devops.#{key} is not writable — it lives in #{home}"
      end
      next unless DEVOPS_KEYS.include?(key)

      normalized[key] = normalized_value
    end
  end

  # Normalize a repo-keyed map (DEVOPS_MAP_KEYS) into { "<repo>" => "<value>" }.
  # Two input shapes, because the two writers differ:
  #   * a HASH ({ "turf-monster" => "https://github.com/.../pull/305" }) — the
  #     shape the JSON API takes and the only one `bin/task --pr-url-for` writes.
  #   * a LIST or newline/comma STRING of PR urls — the ergonomic shape, for a
  #     caller holding bare urls with no repo to hand.
  #
  # BOTH SHAPES ARE VALIDATED THE SAME WAY, and the symmetry is the point. The
  # hash branch used to take its value verbatim, so `{ "turf-monster" => "lol" }`
  # stored "lol" and #repos_missing_pr_url then reported turf fully covered: the
  # evidence this key exists to hold, satisfiable by a nonsense string, on the
  # only path anything actually writes. Every value must parse as
  # github.com/<owner>/<repo>/pull/<n>, and the entry is KEYED BY THE REPO THE
  # URL NAMES — so a hash key that disagrees with its url is refused rather than
  # filing turf's PR under the hub.
  #
  # A bad pair RAISES rather than dropping: a silently-skipped PR url is exactly
  # the failure this key exists to close (see DEVOPS_MAP_KEYS), so a write that
  # reaches nothing must be loud. Both controllers turn that into a 422 —
  # Api::V1::TasksController#create/#update rescue StandardError into
  # render_error (default :unprocessable_entity), and TasksController#create/
  # #update rescue into an :unprocessable_entity render. The web path only
  # reaches the normalizer because `pr_urls` is in its permit list; strong params
  # stripping the key first is what used to make that path 200 for a write that
  # reached nothing.
  def self.normalize_devops_map(value)
    pairs =
      if value.is_a?(Hash)
        value.to_h.map { |repo, url| normalize_devops_map_pair(repo, url) }
      else
        normalize_devops_list(value).map { |url| normalize_devops_map_pair(nil, url) }
      end

    pairs.compact.to_h
  end

  # One validated `<repo> => <pr url>` pair, or nil when the value is blank.
  #
  # A BLANK VALUE DROPS rather than raising, and that is the API-level UNSET: the
  # writers all send the whole map (read-merge-write), so blanking one value in
  # it is how a wrong entry gets removed. `bin/task --pr-url-for <repo>=none`
  # deletes the key client-side for the same reason. A blank asserts nothing, so
  # there is no url to lose — unlike an unparseable one, which is a real claim
  # the caller made and got wrong.
  def self.normalize_devops_map_pair(repo, url)
    repo = repo.to_s.strip
    url = url.to_s.strip
    return nil if url.blank?

    named = repo_from_pr_url(url)
    if named.blank?
      raise ArgumentError,
            "devops.pr_urls entry #{url.inspect} names no repo — expected a " \
            "github.com/<owner>/<repo>/pull/<n> url"
    end
    if repo.present? && repo != named
      raise ArgumentError,
            "devops.pr_urls entry #{repo.inspect} => #{url.inspect} is filed under the " \
            "wrong repo — that url names #{named.inspect}"
    end

    [named, url]
  end

  # The repo segment of a GitHub PR url, or nil. Class-level so the map
  # normalizer (and any caller holding a bare url) shares ONE parser with
  # Task#repo_from_pr_url, which delegates here.
  def self.repo_from_pr_url(url)
    url.to_s[PR_URL_REPO_PATTERN, 1]
  end

  def self.normalize_devops_list(value)
    # Array input (the JSON API / bin/task) is already delimited — each element
    # is one item, so split ONLY on newlines. Commas are legitimate inside
    # acceptance/test_plan sentences and must be preserved. String input (UI
    # free-text fields) keeps the newline+comma split so a single field can
    # carry several comma-separated entries.
    parts =
      if value.is_a?(Array)
        value.flat_map { |item| item.to_s.split("\n") }
      else
        value.to_s.split(/[\n,]/)
      end
    parts.map(&:strip)
         .reject(&:blank?)
         .uniq
  end

  # Normalize a raw reviewers payload — from EITHER the submitted→reviewed
  # TaskEvent's metadata["reviewers"] (the canonical write target, see
  # #stage_event_metadata) OR a Task's own metadata["reviewers"] — into uniform
  # `{ "slug" =>, "weight" => "primary"|"light"|nil }` entries. The weight is
  # passed through verbatim (role-agnostic), so a legacy "heavy" record still
  # normalizes — the UI maps it back to "primary" at render (StageAgent#role_label).
  # Accepts a list of slug strings or of hashes, and tolerates the
  # agent_slug/review_weight/depth aliases (review_weight is the per-agent key the
  # souls seed + ReviewerSelector use), so the writer's exact shape isn't
  # load-bearing. Blank-slug entries drop.
  def self.normalize_reviewers(raw)
    Array(raw).filter_map do |entry|
      if entry.is_a?(Hash)
        slug = (entry["slug"] || entry["agent_slug"]).to_s.strip
        next if slug.blank?

        { "slug" => slug, "weight" => (entry["weight"] || entry["review_weight"] || entry["depth"]).to_s.strip.presence }
      else
        slug = entry.to_s.strip
        next if slug.blank?

        { "slug" => slug, "weight" => nil }
      end
    end
  end

  def self.normalize_review_role(raw)
    REVIEW_ROLE_ALIASES[raw.to_s.strip.downcase]
  end

  def self.normalize_review_moment(raw)
    raw.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
  end

  def self.normalize_review_status(raw)
    raw.to_s.strip.downcase
  end

  def self.review_moment_label(role, moment)
    role = normalize_review_role(role)
    moment = normalize_review_moment(moment)
    REVIEW_MOMENT_LABELS.dig(role, moment).presence || moment.to_s.tr("_", " ").presence&.humanize || "Review update"
  end

  # --- Workflow 1: Build ---------------------------------------------------
  def design!
    update!(stage: "designed")
  end

  def build!
    update!(stage: "building")
  end

  def submit!
    update!(stage: "submitted")
  end

  def review!
    update!(stage: "reviewed")
  end

  # --- Workflow 2: Deploy --------------------------------------------------
  def assemble!
    update!(stage: "assembled")
  end

  def ship!(result_data = {})
    # Shipping ff's release → main, so the code is now on main — stamp it as the
    # git-location alongside the board flip (the deploy heartbeat's crash-recovery
    # signal). See MERGED_STATES.
    update!(stage: "shipped", merged: MERGED_MAIN, result: result_data)
  end

  # --- Block: a `building` attribute, no longer a stage ---------------------
  # block! marks the task blocked WITHOUT leaving the pipeline: it lands on
  # `building` (a block means "more building to do") and stamps the block columns
  # — blocked_at (when), blocked_from (the stage it stalled in), blocked_by (the
  # agent that raised it), block_kind (why). There is NO →blocked transition, so
  # the DURABLE block markers are these columns plus the qa_feedback Activity a
  # caller posts alongside (bin/task block, eject!) — retros/insights/rework-counts
  # key on those markers, never a vanished stage transition. set_stage_timestamp
  # skips the build-claim stamp on a block (the blocker isn't the builder).
  def block!(by: nil, kind: nil)
    update!(
      stage: "building",
      blocked_from: stage.presence, # evaluated BEFORE the stage assignment: where it stalled
      blocked_at: Time.current,
      blocked_by: by.to_s.strip.presence,
      block_kind: kind.to_s.strip.presence
    )
  end

  # Clear a live block, leaving the task on `building` (the "Resume" action). The
  # block columns are wiped so #blocked? / the red card / the scope all drop it;
  # the qa_feedback ledger (ever_blocked? / block mining) is untouched.
  def unblock!
    update!(blocked_at: nil, blocked_by: nil, block_kind: nil, blocked_from: nil)
  end

  def archive!
    update!(stage: "archived")
  end

  # Recompute this task's testing-phase projection (Task::TestingPhases) — PUBLIC so
  # the TaskEvent after_create_commit hook can call it on the parent task, mirroring
  # release.refresh_duration_metrics_safely. update_columns inside refresh! skips
  # callbacks, so this never re-enters.
  def refresh_testing_phases!
    Task::TestingPhases.refresh!(self)
  end

  def refresh_testing_phases_safely
    refresh_testing_phases!
  rescue StandardError => e
    Rails.logger.warn("[task-testing-phases] refresh failed for #{slug}: #{e.class}: #{e.message}")
    nil
  end

  # Recompute this task's latest-attempt-per-gate projection (Task::GatesProjection)
  # — PUBLIC so the GateRun commit hooks can call it on the parent task, mirroring
  # refresh_testing_phases!. update_columns inside refresh! skips callbacks, so this
  # never re-enters.
  def refresh_gates!
    Task::GatesProjection.refresh!(self)
  end

  def refresh_gates_safely
    refresh_gates!
  rescue StandardError => e
    Rails.logger.warn("[task-gates] refresh failed for #{slug}: #{e.class}: #{e.message}")
    nil
  end

  private

  # [[time, label], ...] — the durable artifacts this task has produced. Reads the
  # LOADED associations when there are any: the board preloads BOTH :task_events and
  # :gate_runs, so a card's chip costs it no extra query. Off the board (a single
  # task, the API) each association loads once and is then cached on the record, so
  # the repeated asks the chip makes still cost nothing further.
  def progress_evidence
    evidence = []

    event = task_events.max_by(&:occurred_at)
    evidence << [event.occurred_at, progress_event_label(event), progress_actor(event)] if event&.occurred_at

    gate = gate_runs.max_by(&:updated_at)
    evidence << [gate.updated_at, progress_gate_label(gate), progress_actor(gate)] if gate&.updated_at

    evidence
  end

  # WHO produced a durable artifact, as the record itself names them — the
  # session stamped in metadata (bin/task checkpoint, bin/gate) first, then
  # `actor`, which a CLI stage move already fills with the mover's session id and
  # a block fills with a soul slug. nil when the row names nobody, and nil must
  # stay nil: a guessed owner is exactly the failure this exists to end.
  def progress_actor(row)
    row.metadata.to_h["session"].presence || row.actor.presence
  end

  # The newest artifact produced BY a given session. Filtered in Ruby over the
  # same loaded associations progress_evidence reads, so a card that preloaded
  # :task_events and :gate_runs pays nothing extra.
  def progress_evidence_by(session)
    return [] if session.blank?

    evidence = []

    event = task_events.select { |row| row.occurred_at && progress_actor(row) == session }.max_by(&:occurred_at)
    evidence << [event.occurred_at, progress_event_label(event), session] if event

    gate = gate_runs.select { |row| row.updated_at && progress_actor(row) == session }.max_by(&:updated_at)
    evidence << [gate.updated_at, progress_gate_label(gate), session] if gate

    evidence
  end

  # Is this row DEMONSTRABLY not the holder's? True only when the row names a
  # DIFFERENT SESSION. Everything else answers false — unknown, which protects the
  # holder (see the reaping note above). With no holder on the claim nothing is
  # disowned, so the answer degrades to "keep".
  #
  # A SOUL SLUG IS NOT A SESSION, and this is the trap worth naming: progress_actor
  # falls back to `actor`, which a block fills with a soul ("carl") and
  # bin/pr-review passes soul slugs through. A soul and a session id live in
  # different namespaces, so `"carl" != "8d632410-…"` is true for a reason that has
  # nothing to do with WHO acted — comparing them would mark every soul-attributed
  # row as a stranger's and reap a holder on it. A soul name cannot establish that a
  # row belongs to a different session, which makes it an unknown like any other.
  #
  # The incident is untouched by this: bin/gate and bin/task checkpoint stamp
  # metadata["session"] with a session id, and progress_actor prefers it, so a
  # challenger's cert is still demonstrably the challenger's.
  def disowned?(row)
    actor = progress_actor(row)
    return false if actor.blank? || claimed_session_id.blank?
    return false if actor.match?(SOUL_SLUG)

    actor != claimed_session_id
  end

  # The newest artifact not demonstrably someone else's — the reaping counterpart
  # to progress_evidence_by, over the same loaded associations, so a preloaded
  # card still pays nothing extra.
  def undisowned_progress_event
    @undisowned_progress_event ||= begin
      evidence = []

      event = task_events.select { |row| row.occurred_at && !disowned?(row) }.max_by(&:occurred_at)
      evidence << [event.occurred_at, progress_event_label(event), progress_actor(event)] if event

      gate = gate_runs.select { |row| row.updated_at && !disowned?(row) }.max_by(&:updated_at)
      evidence << [gate.updated_at, progress_gate_label(gate), progress_actor(gate)] if gate

      evidence.max_by(&:first)
    end
  end

  def progress_event_label(event)
    case event.kind
    when TaskEvent::CHECKPOINT then checkpoint_label(event)
    when TaskEvent::INTENT     then "intent recorded"
    # The event's OWN destination, not the task's current stage. The row carries the
    # fact one column away; reading the task instead reports where the task is NOW,
    # which is a different (and, once a later move lands, wrong) claim.
    else "moved to #{event.to_stage.presence || stage}"
    end
  end

  # A checkpoint's NAME is its `to_stage` (record_checkpoint_event writes
  # `to_stage: name`), and checkpoints are NOT cert-only: review check-ins route
  # through the same spine (`review_primary_complete`), and `bin/task checkpoint
  # <slug> <name>` takes an arbitrary name. This label used to hardcode "cert", so a
  # review check-in rendered as "cert passed" — the board naming an artifact it had
  # never seen, and naming it in the one string the claim gate shows a second agent
  # deciding whether to take the desk. Read the name off the event.
  def checkpoint_label(event)
    name = event.to_stage.to_s.strip.presence || "checkpoint"
    status = event.metadata.to_h["status"].presence

    status ? "#{name} #{status}" : name
  end

  def progress_gate_label(gate)
    return "#{gate.key} running" if gate.finished_at.nil?

    "#{gate.key} #{gate.success ? 'passed' : 'failed'}"
  end

  # Refresh the testing-phase projection after a stage transition — the only edit
  # ON THIS ROW that moves a v2 task-owned phase window (build/ci/review bounds).
  # The other movers are their own append-only spines and trigger the refresh
  # themselves: cert checkpoints + review intents via TaskEvent#after_create_commit.
  # Metadata churn (approval stamps, statusline claim_*, agent_context) moves no v2
  # window — approval was only a mover for the v1 Operator Acceptance phase, dropped
  # in VERSION 2 — so it must NOT trigger a rebuild.
  # Push the app-ladder row when this task's rung membership changed. Destroy always
  # counts: the row is a COUNT, so a removed task changes it even though no column
  # "changed" in the saved_change sense. Wrapped by the broadcaster's own
  # safe_broadcast, so a cable failure can never break the task write.
  def broadcast_app_ladder_if_rung_changed
    return unless destroyed? || saved_change_to_merged? || saved_change_to_stage?

    DeploymentsBroadcaster.app_ladder
  end

  def refresh_testing_phases_after_change
    return unless saved_change_to_stage?

    refresh_testing_phases_safely
  end

  def refresh_duration_metrics_for_release_changes
    release_slugs = [release_slug]
    if previous_changes.key?("release_slug")
      release_slugs.concat(previous_changes["release_slug"])
    elsif previous_changes.key?("stage")
      release_slugs << release_slug
    end

    release_slugs.compact_blank.uniq.each do |slug|
      Release.find_by(slug: slug)&.refresh_duration_metrics_safely
    end
  rescue StandardError => e
    Rails.logger.warn("[release-duration-cache] task #{slug} refresh failed: #{e.class}: #{e.message}")
  end

  def default_review_status_for(moment)
    case moment
    when "started" then "started"
    when "completed" then "completed"
    when "failed" then "failed"
    else "info"
    end
  end

  # The repo this task's singular `pr_url` names: github.com/<owner>/<repo>/pull/<n>.
  # Delegates to the class method so there is genuinely ONE parser — this used to
  # carry its own literal copy of the regex, which is the duplication extracting
  # PR_URL_REPO_PATTERN was meant to end.
  def repo_from_pr_url
    self.class.repo_from_pr_url(devops_url("pr"))
  end

  def devops_list(key)
    self.class.normalize_devops_list(devops.fetch(key.to_s, []))
  end

  # Append-only audit spine: one TaskEvent per stage that lands. The deterministic
  # fields (from/to/occurred_at/seconds_in_from) are computed here from the same
  # chokepoint that stamps the stage timestamps, so they're server-owned and
  # exact. The optional attribution (actor/model/tokens/cost) rides in on Current —
  # set per-transition by the request layer (web) or the CLI's --actor (defaulted
  # to the mover's own session in bin/task) for the move it just performed — and is
  # null for model-method and conductor transitions. actor is intentionally NOT
  # backfilled from devops_session_id: that's the session that CLAIMED the task at
  # `building`, so inheriting it would mis-attribute later reviewed/assembled/
  # shipped moves to the build agent. Runs inside the save transaction so a stage
  # change can never land without its event.
  # The genesis (Created→Designed) event is intentionally USAGELESS: it fires
  # inside Task.create — before any session/usage context exists (no build claim,
  # no transcript, no Current.task_event_*) — so it can only ever carry the
  # deterministic spine. This is correct by design, NOT a capture gap: the
  # timeline renders genesis without model/token/cost chips, and the usage
  # backfill (lib/tasks/task_events.rake) leaves it alone.
  def record_genesis_event
    write_stage_event(from: nil)
  end

  # Drop this task's card from the live /deployments board for every viewer.
  def broadcast_removal_to_deployments_board
    DeploymentsBroadcaster.task_removed(slug)
  end

  def record_transition_event
    write_stage_event(from: stage_before_last_save)
  end

  # Stamp actual_size from the task's measured usage the moment it ships — closing
  # the size trio (po/dev forecasts vs. the measured actual). Only fills a BLANK
  # actual_size, so a manually set size (the /sizing editor) is never clobbered;
  # only persists a real derivation (a no-usage task derives nil → left blank).
  # Writes via update_column to skip the callback chain (no re-entrancy). The
  # rescue is INTENTIONALLY swallow-and-log, not re-raise: this runs inside the
  # ship transition, so a derivation bug must degrade to "no auto-size" rather
  # than roll the ship back (mirrors stage_event_metadata + backfill_mascots!).
  def autoderive_actual_size
    return unless stage == "shipped"
    return if actual_size.present?

    size = derive_actual_size
    return if size.blank?

    update_column(:actual_size, size) # rubocop:disable Rails/SkipsModelValidations
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target = self
    log.target_name = slug
    log.save!
  end

  # after_commit trigger: fire Avi's async shirt-sizer the moment a task ENTERS
  # `designed` with a blank po_size — a fresh create (the birth stage) or a move
  # back INTO designed that's still unsized. Enqueue only (AviSizingJob owns the
  # LLM call + attribution) so this never blocks the create/move. Guarded on:
  #   * stage == "designed" AND po_size blank (never re-size a set task), and
  #   * the task just entered designed (a fresh row, or a real stage change) — so a
  #     plain metadata/title edit on an already-designed unsized task doesn't re-fire.
  # Best-effort: an enqueue failure (e.g. Redis down) is logged, never raised — a
  # broken queue must not sink task creation. AviSizingJob itself re-guards po_size,
  # so a duplicate enqueue is a harmless no-op.
  def enqueue_avi_sizing_if_designed_unsized
    return unless stage == "designed"
    return if po_size.present?
    return unless previously_new_record? || saved_change_to_stage?

    AviSizingJob.perform_later(slug)
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target = self
    log.target_name = slug
    log.save!
  end

  # The usage columns for a TaskEvent, with cost DERIVED server-side. bin/task mints its
  # cost in a plain-Ruby process with no ActiveRecord, so it can never see an operator's
  # rate override (UsagePricing.db_rates returns {} there) — re-deriving here is what
  # carries a saved rate into task-event cost, and therefore into actual_size on the
  # sizing dashboard. The CLI's cost stays the FALLBACK: kept for an unpriced model, or
  # an older CLI that doesn't send the un-folded cache_creation bucket needed to split
  # the folded tokens_in faithfully.
  def task_event_usage_attrs
    model      = Current.task_event_model.presence
    tokens_in  = Current.task_event_tokens_in
    tokens_out = Current.task_event_tokens_out
    cache_creation_tokens = Current.task_event_cache_creation_tokens
    cache_read_tokens     = Current.task_event_cache_read_tokens

    derived = UsagePricing.cost_from_capture(
      model: model, tokens_in: tokens_in, tokens_out: tokens_out,
      cache_creation_tokens: cache_creation_tokens, cache_read_tokens: cache_read_tokens
    )

    {
      model: model,
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      cache_creation_tokens: cache_creation_tokens,
      cache_read_tokens: cache_read_tokens,
      cost: derived || Current.task_event_cost
    }
  end

  def write_stage_event(from:)
    occurred = Time.current
    # Measure the stage duration between TRANSITIONS only — an intent row recorded
    # mid-stage (review picked, QA started) is the live "who's on it" signal, not a
    # stage boundary, so it must never shorten seconds_in_from.
    previous = task_events.transitions.chronological.last
    task_events.create!(
      from_stage: from,
      to_stage: stage,
      occurred_at: occurred,
      seconds_in_from: previous && (occurred - previous.occurred_at).round,
      source: Current.task_event_source,
      actor: Current.task_event_actor.presence,
      **task_event_usage_attrs,
      # Merge the review-bypass marker (set only by Conductor.sweep!(override:true)
      # for `bin/release merge --override`) onto THIS transition, so the review-gate
      # skip is recorded on the same spine the move writes — not as a second, orphan
      # event. Absent on every normal move (Current flag nil), so it never widens the
      # default metadata.
      metadata: stage_event_metadata(from: from)
        .merge(Current.task_event_review_bypass ? { "review_bypassed" => true } : {})
        # And the BLOCK marker, for the same reason one indirection along: #block!
        # lands a bounced task on `building`, so a rework block writes a
        # `→ building` transition whose actor is the BLOCKER. Readers that equate
        # that transition with a build claim counted the reviewer as an author —
        # ReviewerSelector#builders read ["shannon", "carl"] after a bounce, so the
        # reviewer who sent the work back was excluded from the task's own pool and
        # named in the audit as one of its authors. The actor is right and stays;
        # what was missing is WHY, and it rides the same event rather than a second
        # orphan row. See TaskEvent#block_transition?.
        .merge(block_transition_metadata)
    )
  end

  # The `blocked` marker for a transition written by #block! — empty on every
  # ordinary move. Keyed on blocked_at moving to a value in the save that just
  # landed, the same tell #build_claim_save? and #set_stage_timestamp already use
  # for "this transition is a block, not a claim".
  def block_transition_metadata
    return {} unless saved_change_to_blocked_at? && blocked_at.present?

    { "blocked" => true }.merge(block_kind.present? ? { "block_kind" => block_kind } : {})
  end

  # Extra, non-spine event metadata. EVERY staged transition snapshots the mascot
  # that owned THAT event, so a later rework handoff — or a gate evolution
  # (#evolve_stage_mascot) — can repaint the current task mascot without
  # rewriting history: the reviewed card keeps Charmeleon after the task
  # assembles as Charizard. On the submitted→reviewed transition this
  # also carries the TWO reviewers (+ primary/light) so the avatars UI can render
  # WHO reviewed — the single `actor` stays the primary mover. An explicit
  # Current.task_event_reviewers (set when Avi curated the pair) wins; otherwise
  # the pair is selected here via ReviewerSelector, so the avatars populate no
  # matter who drove the move. It NEVER blocks the stage change: a selection error
  # is logged and the event records the metadata gathered so far.
  def stage_event_metadata(from:)
    metadata = stage_mascot_event_metadata
    return metadata unless from == "submitted" && stage == "reviewed"

    # Prefer the pair that actually STARTED the review (stamped on the open review
    # intent) so the completed event shows the same two seniors the board showed
    # ticking; an explicit Current override (Avi curated on the move) still wins,
    # and an old-flow move with neither falls back to a fresh selection.
    reviewers = Current.task_event_reviewers.presence ||
                latest_intent_reviewers("reviewed") ||
                ReviewerSelector.select(self)
    reviewers.present? ? metadata.merge("reviewers" => reviewers) : metadata
  rescue StandardError => e
    Rails.logger.warn("[reviewer-selector] recording failed (non-fatal): #{e.class}: #{e.message}")
    metadata || {}
  end

  def stage_mascot_event_metadata
    slug = devops["mascot"].presence
    return {} unless slug

    pokemon = Pokemon.find_by(slug: slug) if Pokemon.table_exists?
    # A shiny mascot bakes its shiny avatar URL into the snapshot, so historical
    # events keep the shiny face even after the mascot recycles to another task.
    snapshot = {
      "slug" => slug,
      "name" => pokemon&.name.presence || slug,
      "avatar" => pokemon&.display_avatar(shiny: mascot_shiny?).presence,
      "color" => devops["mascot_color"].presence || pokemon&.signature_color.presence,
      "emoji" => devops["mascot_emoji"].presence,
      "shiny" => (true if mascot_shiny?)
    }.compact

    { "mascot" => snapshot }
  rescue StandardError => e
    Rails.logger.warn("[task-event-mascot] recording failed (non-fatal): #{e.class}: #{e.message}")
    {}
  end

  def set_stage_timestamp
    case stage
    when "building"
      # A block! lands the task on `building` too, but it's NOT a fresh build
      # claim — the blocker isn't the builder, so skip the started_at re-stamp
      # (#enforce_builder_stamp applies the same exemption to the builder stamp,
      # which used to live here). A block is detected by blocked_at being set in
      # this same save.
      self.started_at = Time.current unless will_save_change_to_blocked_at? && blocked_at.present?
    when "submitted" then self.submitted_at = Time.current
    when "reviewed"  then self.reviewed_at  = Time.current
    when "assembled" then self.assembled_at = Time.current
    when "shipped"   then self.completed_at = Time.current
    when "archived"  then self.archived_at = Time.current
    end
    # Re-rank to the TOP of the new column on every stage move: max + 100 wins the
    # `position DESC` sort. The 100-gap keeps room for later drag inserts. (Skip on
    # create — set_initial_position seeds the genesis rank.)
    self.position = (Task.where(stage: stage).maximum(:position) || 0) + 100 unless new_record?
  end

  # Clear the live-block columns when the task advances out of `building` — the
  # block resolved (the fix moved forward). The qa_feedback ledger (ever_blocked?)
  # is untouched, so the "was blocked" history survives on the durable marker.
  def clear_block_on_forward_move
    self.blocked_at = nil
    self.blocked_by = nil
    self.block_kind = nil
    self.blocked_from = nil
  end

  # A soul SLUG is a short human handle (carl, shannon) — lowercase letters with
  # optional internal hyphens, NO digits. That format distinguishes it from a
  # session id (the UUID `bin/task move <slug> building` defaults the actor to,
  # which always carries digits), so the check needs no Agent-table lookup and
  # works before the reviewer souls are seeded.
  SOUL_SLUG = /\A[a-z]+(?:-[a-z]+)*\z/

  # THE ROSTER — the souls that actually exist. SOUL_SLUG above answers "does this
  # LOOK like a handle"; that is a different question from "is this SOMEBODY", and
  # the gap between them was a live fail-open: `--actor stefon` (one f) matches the
  # shape, so it stamped as the builder, satisfied every "the builder is known"
  # check, and excluded NOBODY from the reviewer pool — the fail-closed refusal
  # lifted by a value identifying no one. A blank builder fails closed and is safe;
  # a typo'd one failed open and was not.
  #
  # The static list is the FLOOR, not the whole answer: .soul_roster unions the
  # seeded Agent slugs over it, so a newly seeded soul validates without a code
  # change. It is a floor rather than a plain DB read because ReviewerSelector
  # DEGRADES to built-in defaults with no Agent rows at all (see its header), and a
  # roster that empties with the DB would turn every soul into an unknown. Keep it
  # in lockstep with db/seeds/02_agents.rb — test/models/agents_seed_test.rb asserts
  # every seeded slug appears here.
  SOUL_ROSTER = %w[alex avi carl shannon jasper steffon turf-monster mack mason].freeze

  # Every soul slug this deployment recognises: the static floor plus whatever is
  # seeded. Any lookup error (no table yet, DB down, mid-migration) degrades to the
  # floor — which still names all nine real souls, so degrading never turns a real
  # soul into an unknown NOR an unknown into a soul.
  # Memoized per request/job (Current.soul_roster) — .soul? is asked once per
  # candidate on every build claim and every reviewer selection, and an unmemoized
  # roster re-SELECTs the agents table several times per save.
  def self.soul_roster
    Current.soul_roster ||= begin
      (SOUL_ROSTER + Agent.pluck(:slug).map(&:to_s).select { |s| s.match?(SOUL_SLUG) }).uniq
    rescue StandardError
      SOUL_ROSTER.dup
    end
  end

  # Is this string a soul that EXISTS — the right shape AND on the roster. The
  # authorship guards (who built this, who may not review it) ask this; the
  # session-vs-handle disambiguation in #disowned? still asks SOUL_SLUG alone,
  # because there a typo'd handle is correctly "not a session id".
  def self.soul?(slug)
    value = slug.to_s
    value.match?(SOUL_SLUG) && soul_roster.include?(value)
  end

  # Stamp WHO built this task onto devops.built_by — the soul the reviewer pool
  # later excludes (ReviewerSelector) so a soul never reviews their own work. The
  # value MUST be a soul SLUG to match the soul-keyed pool. Resolved by
  # #builder_to_stamp (precedence below); nil leaves any existing built_by
  # untouched — never clobbered.
  #
  # AN INVARIANT OF THE BUILD CLAIM, not of the transition into `building`. It ran
  # inside `set_stage_timestamp` (`before_save … if: :stage_changed?`) until
  # 2026-08-13, and that shape had a silent hole the whole fast lane fell through:
  # `bin/task begin` leaves the task AT `building`, so the documented recovery —
  # `bin/task move <slug> building --actor <soul>` — carried no stage change, the
  # callback never fired, and the stamp no-op'd at exit 0. Two tasks in one day
  # reached review with `built_by` blank; on one of them `bin/reviewer-select`
  # picked Carl to review Carl's own PR, and only a human routing reviewers by
  # hand stopped it. A re-claim IS a claim, so it stamps.
  #
  # TWO HALVES, like its siblings above:
  #   STAMP — on a build CLAIM (#build_claim_save?) resolve and record the builder.
  #     Keyed on the claim so it stays a claim stamp: a note, a checks update, or
  #     any other save that happens to carry a soul actor while the task sits in
  #     `building` must not make that soul the builder.
  #   DEFEND — on ANY save, carry a stored builder forward. BOTH write paths fold
  #     through Task.merge_devops_into_metadata since `api-devops-patch-replaces`,
  #     so a partial PATCH that never mentions built_by now preserves it on its
  #     own — the merge, not this guard, is what covers omission. What the merge
  #     does NOT cover is a name posted BLANK: it keys on the POSTED names and
  #     `normalize_devops_metadata` drops blanks, so
  #     `{"devops":{"built_by":""}}` deletes the record of who built the task. That
  #     is this half's remaining job, and it is the whole of it. A regression test
  #     drives exactly that PATCH — test/integration/builder_stamp_api_test.rb,
  #     "a client cannot erase the builder by posting it blank"; without it,
  #     deleting the `|| prior_devops["built_by"]` below passes the whole suite.
  def enforce_builder_stamp
    # An explicit devops teardown (the whole hash removed) is left alone — this
    # guard defends the builder key, not the existence of devops. Same posture as
    # #enforce_build_claim_invariant.
    return unless metadata.is_a?(Hash) && metadata["devops"].is_a?(Hash)

    claim = build_claim_save?
    named = (builder_to_stamp if claim)
    # A REVIEWER WHO TAKES THE BUILD IS AN AUTHOR, NEVER THE CURRENT BUILDER. `named`
    # still joins the author set below (over-counting an author over-EXCLUDES, which
    # refuses rather than seats) but it must not reach built_by: a reviewer recorded
    # as the builder of the PR he is reviewing is the same defect fully inverted, and
    # a confidently-wrong author set is worse than a refusing one.
    soul = (named unless reviewer_taking_the_build?(named)) ||
           prior_devops["built_by"].to_s.strip.presence
    authors, unattributed = builder_roll_call(claim, named, soul)

    return if soul.nil? && authors.empty? && unattributed.nil?
    return if metadata["devops"]["built_by"].to_s == soul.to_s &&
              Array(metadata["devops"]["builders"]) == authors &&
              metadata["devops"]["builders_unattributed"].to_s == unattributed.to_s

    merged = metadata.deep_dup
    merged["devops"]["built_by"] = soul if soul
    if authors.any?
      merged["devops"]["builders"] = authors
    else
      merged["devops"].delete("builders")
    end
    if unattributed
      merged["devops"]["builders_unattributed"] = unattributed
    else
      merged["devops"].delete("builders_unattributed")
    end
    self.metadata = merged
  end

  # THE AUTHOR SET, and whether it is COMPLETE. Returns [authors, unattributed].
  #
  # `built_by` holds ONE soul, but a task can have SEVERAL authors: a session limit
  # kills a builder mid-work and another soul finishes the job. Rule 1 of
  # #builder_to_stamp RE-POINTS built_by on an explicit actor, so the handoff
  # OVERWRITES the first author rather than remembering them — and the reviewer pool
  # then excludes one of two. Measured 2026-08-30 on TWO tasks in one sitting:
  # credential-prose-tells-truth reads built_by=avi and agent-flag-silently-drops
  # reads built_by=steffon, yet ALEX wrote the tests on the first and the whole
  # rework on the second. `bin/reviewer-select` duly seated Alex as the LIGHT on
  # Alex's own diff (PR #1081); a hand-passed `--busy alex` was the only thing that
  # stopped it, and a hand-pass is not a property.
  #
  # So `built_by` KEEPS its meaning (the current builder — every existing reader and
  # the board card are untouched, and nothing needs migrating) and `builders`
  # ACCUMULATES: append-only, deduped, seeded from whatever built_by already held so
  # a task stamped before this change still names its author. It is SERVER-OWNED —
  # deliberately absent from DEVOPS_KEYS, so `normalize_devops_metadata` drops any
  # client attempt to write it and this callback rebuilds it from the prior record
  # on every save. A client can no more shrink the author set than forge it.
  #
  # `unattributed` is the half that keeps this FAIL-CLOSED. Accumulating only helps
  # when each claim names a soul; the handoff that names NOBODY (a bare `bin/task
  # move <slug> building`, actor a session UUID) would otherwise leave a set of one
  # that READS complete — the original bug, one layer along. When a claim from a
  # DIFFERENT live instance resolves no soul while authors are already on record, we
  # record WHICH session we could not name. Present ⇒ "someone else worked this and
  # we cannot say who" ⇒ ReviewerSelector reports the builder UNKNOWN and the CLI
  # refuses. It clears when that same session finally identifies itself.
  #
  # Keyed on the live INSTANCE (claimed_session + claim_nonce, ClaimLease's identity)
  # rather than on the claim save, because the statusline renews the lease every few
  # seconds with no actor: treating a renewal as an anonymous handoff would refuse
  # every task in the fleet, and a guard that cries wolf gets routed around.
  #
  # TWO authorship moments, not one. Accumulating on the CLAIM alone still misses the
  # author who never claimed — see the `submit_save?` branch below, which closes that
  # half and is why this method no longer keys on the claim exclusively.
  def builder_roll_call(claim, named, soul)
    # The STORED built_by joins the set too, and it has to be read separately from
    # `soul`: on a claim that names a new soul, `soul` IS that new soul, so seeding
    # from it alone would drop the author already on record — the very overwrite this
    # exists to prevent, and the only thing a task stamped before `builders` existed
    # has to give.
    authors = (Array(prior_devops["builders"]) + [prior_devops["built_by"]])
              .map { |s| s.to_s.strip }.select { |s| self.class.soul?(s) }.uniq
    authors |= [soul] if soul && self.class.soul?(soul)
    unattributed = prior_devops["builders_unattributed"].to_s.strip.presence

    if claim
      if named
        authors |= [named]
        # The session we could not name has now named itself — the gap it opened is
        # closed. ONLY that session closes it: a THIRD soul claiming by name says
        # nothing about who the second one was, and clearing on any named claim
        # would hand the fail-open straight back.
        unattributed = nil if unattributed == claiming_party_id
      elsif authors.any? && claim_party_changed?
        unattributed = claiming_party_id
      end
    elsif submit_save?
      # THE AUTHOR IS NOT ALWAYS THE CLAIMER — the half the accumulator above cannot
      # see. Everything before this point keys on the CLAIM, so a soul who never
      # claimed the task and wrote the entire diff never enters the set. Measured
      # 2026-08-30 on PR #1094: shannon's agent claimed the task and was killed by a
      # session limit with NOTHING committed; ALEX then wrote the whole diff and both
      # test files, and shipped it. built_by read "shannon" and `builders` held only
      # shannon, so `bin/reviewer-select` ran happily, excluded a soul who had written
      # nothing, and left the REAL author in the light pool (alex:0.9968, ranked 3rd).
      # Jasper drew the seat by luck of the seeded roll; a different roll seats the
      # author on his own diff and every mechanical check still reports the property
      # upheld. That is the WORSE failure: the blank-built_by case fails CLOSED and a
      # human decides, while this one fails CONFIDENTLY WRONG. It is also the standard
      # shape of a session-limit handover, which happened FOUR times that day.
      #
      # So the SUBMIT is an authorship moment too, and it is the right one: it is the
      # save that turns a diff into a PR, so whoever drives it is the party handing
      # over work. Two outcomes, mirroring the claim above:
      #   NAMED — `--actor <soul>` on the submit ADDS that soul to the set. The
      #     handover author can therefore declare themselves through the flag that
      #     already exists, with no new one to remember.
      #   UNNAMED — a bare submit carries the mover's SESSION as its actor. When that
      #     session is provably not the one that claimed the task, an author worked
      #     here whom the record cannot name, which is precisely what
      #     `builders_unattributed` already means: ReviewerSelector reports the authors
      #     UNKNOWN and the CLI refuses. Omitting the flag is therefore LOUD (a refusal
      #     a human must clear) rather than silent, which is the failure mode that
      #     produced /tasks/agent-flag-silently-drops.
      actor = Current.task_event_actor.to_s.strip
      if self.class.soul?(actor)
        authors |= [actor]
      elsif authors.any? && (shipper = handoff_shipping_party(actor))
        unattributed = shipper
      end
    end

    [authors, unattributed]
  end

  # True when THIS save hands the build off — the task LANDS on `submitted`. Keyed on
  # the transition, not on sitting there: the later writes a submitted task takes
  # (`--checks`, a pr_url stamp, the review's own moves) are not authorship moments,
  # and treating them as such would let any passing session stamp a handoff.
  def submit_save?
    stage == "submitted" && will_save_change_to_stage?
  end

  # The SHIPPING session, when it is provably NOT the one holding the claim — the
  # signature of an author who never claimed. nil (no signal, stay silent) unless
  # every part of that is on record, because a guard that cries wolf gets routed
  # around and this one has to survive the ordinary case untouched:
  #   - a blank actor says nothing (a plain shell / CI submit stamps no actor);
  #   - a soul actor is handled by the caller — it NAMES the author rather than
  #     flagging one, so it never reaches here;
  #   - an operator EMAIL is a board action, not a shipping session. Dragging a card
  #     to `submitted` on the web is not evidence about who wrote the diff, and
  #     stamping it would refuse reviews for a move that carries no authorship claim
  #     at all (TasksController sets the actor to current_user.email there);
  #   - a BLANK claimed_session leaves nothing to differ FROM. A claim that recorded
  #     no session (plain shell / CI) is already the degraded path; inferring a
  #     handover from its absence would flag every such task;
  #   - and the common case by far — the claimer ships their OWN work, actor ==
  #     claimed_session — must produce no signal whatsoever.
  # What remains is the exact PR #1094 shape: session A claimed, session B shipped.
  def handoff_shipping_party(actor)
    return nil if actor.empty? || actor.include?("@")

    claimed = prior_devops["claimed_session"].to_s.strip
    return nil if claimed.empty? || actor == claimed

    actor
  end

  # The party holding the claim — the agent SESSION (ClaimLease's `claimed_session`).
  # Not the session+nonce pair: the nonce distinguishes two PROCESSES of one session
  # (the operator's terminal-A/terminal-B case), which is the same party working, so
  # keying on it would refuse to clear a gap the same soul had just closed from a
  # restarted terminal. "unknown" when the claim names no session, so an
  # unattributed handoff is still recorded (and still clearable) for want of an id.
  def claiming_party_id
    devops = metadata.is_a?(Hash) ? (metadata["devops"] || {}) : {}
    devops["claimed_session"].to_s.strip.presence || "unknown"
  end

  # True when a DIFFERENT party is claiming than the one on record — a handoff, not
  # a heartbeat. claim_expires_at moves on every statusline renewal by design and
  # claim_nonce moves on every new process, so neither can mark a change of hands.
  def claim_party_changed?
    current = metadata.is_a?(Hash) ? (metadata["devops"] || {}) : {}
    current["claimed_session"].to_s != prior_devops["claimed_session"].to_s
  end

  # True when THIS save is a build claim: the task lands (or sits) on `building`
  # and the save either moves it there or (re)writes the claim lease — the two
  # shapes `bin/task move <slug> building` takes, whether or not the stage changes.
  # A block! lands on `building` too but is NOT a build claim: the blocker is not
  # the builder (detected by blocked_at being set in this same save).
  #
  # Neither is the AUTOMATIC write from the session that is REVIEWING this task
  # (#reviewing_party_renewal?). The block itself was always exempt; the writes that
  # FOLLOW it were not, and one of them is automatic — see that method.
  def build_claim_save?
    return false unless stage == "building"
    return false if will_save_change_to_blocked_at? && blocked_at.present?
    return false if reviewing_party_renewal?
    return true if will_save_change_to_stage?

    claim_lease_rewritten?
  end

  # The reviewing session's write that CLAIMS NOTHING — the only one this seam may
  # swallow.
  #
  # #reviewing_party_claim? on its own was too wide. It answers "is this write from
  # the session reviewing this task", and suppressing on that alone also swallowed a
  # write that NAMES A SOUL — which is never the automatic heartbeat (that PATCH
  # carries a `devops` slice and no `event` at all, so Current.task_event_actor is
  # nil) and always a deliberate `bin/task move <slug> building --actor <soul>`.
  #
  # THAT WRITE IS ON THE DOCUMENTED PATH, and dropping it was silent. TWO sites
  # prescribe exactly that command to a REVIEWER holding this task's review claim, to
  # repair a wrong or missing author stamp: `bin/reviewer-select` (:446, the durable
  # fix under its refusal) and pr-review-sop.md (:137). He runs it while holding the
  # claim because that is the moment he is looking at the refusal, so the repair
  # no-op'd at exit 0 and the next round refused again.
  #
  # A THIRD site prints the same remedy and was never on this path:
  # bin/lib/review_claim_cli.rb (:690) reports it on a REFUSED claim — TaskReviewClaim
  # .acquire returns :self_review (task_review_claim.rb:49) BEFORE the row lock, so
  # that caller holds no claim at all and the pre-fix suppression never applied to him.
  #
  # So the rule is stated over the WRITE, not the writer: a claim that names a soul
  # is an assertion of authorship and is recorded; one that names nobody is a
  # liveness ping and is not. The reviewer who names HIMSELF is still recorded — as
  # an AUTHOR only, never as built_by (see #reviewer_taking_the_build?).
  def reviewing_party_renewal?
    return false if self.class.soul?(Current.task_event_actor.to_s.strip)

    reviewing_party_claim?
  end

  # THE SEAM BETWEEN A REVIEW WRITE AND A BUILD WRITE — true when the session
  # named in the INCOMING claim is the one holding this task's LIVE REVIEW claim.
  #
  # Nothing used to distinguish the two. A build claim is an assertion of
  # authorship (`bin/task move <slug> building`); a lease renewal is a liveness
  # ping. Both arrive as one shape — a devops PATCH that rewrites ClaimLease's
  # keys — so #claim_lease_rewritten? read them identically, and any session whose
  # status line happened to be pointed at a `building` task became a recorded
  # (unnamed) worker on it.
  #
  # That is not hypothetical. `bin/task block <slug> --kind rework` lands the task
  # back on `building` and repoints the BLOCKING session's feature marker at it, so
  # bin/statusline fires that session's build-claim heartbeat seconds later. The
  # claim keys were stripped at `submitted` (#enforce_build_claim_invariant), so the
  # heartbeat adopted the free lease, the write named no soul, and #builder_roll_call
  # stamped `devops.builders_unattributed` with the REVIEWER's session id. The author
  # set then reads INCOMPLETE and `bin/reviewer-select` refuses the next round —
  # measured 2026-09-04 on four bounced tasks in one sitting, each needing a
  # hand-passed `--builder <soul>`. And a hand-pass is not a property: reviewers
  # who learn to pass it reflexively are exactly how a REAL incomplete author set
  # gets waved through.
  #
  # The board already recorded who is reviewing — TaskReviewClaim, the per-task
  # review lease every review path takes (`bin/task review-claim acquire` and the
  # server-side `claim_next_review` pop both funnel through .acquire). It was simply
  # never consulted when deciding who BUILT. It is a safe answer to ask: .acquire
  # refuses a review claim by anyone in the author set (.self_review?), so a live
  # review holder is by construction not an author of this task.
  #
  # The CLI half of this fix (bin/task's #heartbeat_may_claim?) stops the renewal
  # from being sent at all. This half is what makes it a PROPERTY of the board
  # rather than of one script: a hand-run PATCH, another client, or a future caller
  # reaching the API directly is judged the same way.
  #
  # Suppressing the whole claim — not merely the unattributed branch — is
  # deliberate for the write this covers. #builder_to_stamp rule 1 re-points
  # `built_by` to an explicit soul actor, so a reviewer write carrying `--agent carl`
  # would otherwise record CARL as the builder of a PR he reviewed: the same defect
  # fully inverted, and a confidently-wrong author set is worse than a refusing one.
  # That re-point is now blocked at its OWN seam (#reviewer_taking_the_build?), which
  # is what let this one narrow to the UNNAMED write (#reviewing_party_renewal?) and
  # stop swallowing the documented `move building --actor <soul>` repair.
  #
  # Any lookup failure (no table yet, DB trouble) answers false — the pre-existing
  # behaviour, which fails CLOSED for review selection.
  #
  # Deliberately NOT memoized: one Task instance is saved many times over its life
  # (a move, then a notes update, then a renewal), a review claim is acquired and
  # released between them, and a memo taken on the first save would answer for
  # writes that happen minutes later. One indexed read (task_slug is unique) per
  # save of a `building` task is the cheaper mistake.
  def reviewing_party_claim?
    live_reviewing_party_claim.present?
  end

  # The task's live TaskReviewClaim WHEN the session named in the INCOMING claim is
  # the one holding it — nil otherwise, and nil on any lookup failure (fails CLOSED
  # for review selection, the pre-existing posture). The ROW, not a boolean, because
  # #reviewer_taking_the_build? needs the holder's soul off it.
  #
  # Not memoized, for the reason stated above: a review claim is acquired and released
  # between the many saves one Task instance takes. At most TWO indexed reads
  # (task_slug is unique) per save of a `building` task, and usually one: a soul ACTOR
  # short-circuits #reviewing_party_renewal? before it reads at all, and a renewal that
  # answers TRUE stops the save being a build claim, so #reviewer_taking_the_build? is
  # then handed nil and returns before reading. The path that pays twice is the
  # ordinary BARE claim from a session holding no review — a non-soul actor makes read
  # 1, then #builder_to_stamp resolves a soul from the persona or agent_slug and this
  # method makes read 2. Perf-trivial on a unique index; stated because a comment that
  # says "never" is a thing the next caller builds on.
  def live_reviewing_party_claim
    current = metadata.is_a?(Hash) ? (metadata["devops"] || {}) : {}
    session = current["claimed_session"].to_s.strip
    return nil if session.empty?

    review = TaskReviewClaim.find_by(task_slug: slug)
    return nil unless review.present? && review.live? &&
                      review.claimed_session.to_s.strip == session

    review
  rescue StandardError => e
    Rails.logger.warn("[builder-stamp] review-claim lookup failed for #{slug}: #{e.class}: #{e.message}")
    nil
  end

  # True when this task's live REVIEW claim cannot CLEAR the soul this save names as
  # the builder — so devops.built_by must not move to him.
  #
  # THREE STATES, not two. The claim is read for its HOLDER, and the answer differs by
  # what that holder says:
  #
  #   no live claim from this session  -> false. An ordinary handoff. Re-point freely;
  #                                              this seam has nothing to say about it.
  #   the holder IS this soul          -> true.  A reviewer taking the build of the PR
  #                                              he is reviewing.
  #   the claim names NOBODY           -> true.  Blank, OR a value on no roster — a
  #   (blank or off-roster)                      typo'd --agent names nobody just
  #                                              as a blank one does, so it cannot
  #                                              say he is NOT that reviewer,
  #                                              and guessing costs the author already
  #                                              on record.
  #
  # THE NAMELESS CLAIM IS NOT A CORNER — it is a designed state, reachable at every
  # door. `--agent` is optional on `bin/task review-claim acquire` AND on the
  # server-side `claim_next_review` pop (bin/lib/review_claim_cli.rb:185-187 says so
  # outright), the CLI's own hint prints the acquire without it, and TaskReviewClaim
  # stores `reviewer.to_s.strip.presence` with no Task.soul? check. A guard that asked
  # only "does the holder's NAME match?" read that blank as "not the reviewer" and
  # stamped him — the inversion this method exists to stop, arrived at by the ordinary
  # path. Measured both ways on a throwaway tree: on the pre-fix shape a nameless claim
  # gave built_by="carl" where the record held "shannon". This is the same hole the
  # paragraph below notes in TaskReviewClaim.self_review? — that field is where BOTH
  # live, which is exactly why a name match alone was never enough to lean on.
  #
  # FAILING CLOSED HERE COSTS THE RECORD NOTHING. `named` still joins the author set —
  # #builder_roll_call folds it into devops.builders whatever this method answers — and
  # ReviewerSelector#builder_known? is asked over that SET, not over built_by. So the
  # documented `move building --actor <soul>` repair still clears the refusal it was
  # printed for, and the soul is still excluded from the seats on this task. The one
  # thing withheld is the RE-POINT, the half that could name a reviewer as the author
  # of a diff he only read.
  #
  # Do NOT widen it to "any named claim while a review is live". That suppresses the
  # ordinary handoff too, and it is the mutation that goes 26 red.
  #
  # It is narrow by construction: the same SESSION must hold the review claim and
  # claim the build inside ClaimLease::DEFAULT_TTL_SECONDS, which the SOP forbids
  # outright (reviewers release on the verdict). But narrow is not impossible, and the
  # previous shape handled it the one way that must never happen — the whole claim was
  # dropped, so the session was recorded NEITHER as a builder NOR as an unattributed
  # one, the author set came out confidently short, and nothing anywhere said so.
  #
  # It is RECORDED instead: as an AUTHOR (#builder_roll_call folds `named` into
  # devops.builders) and never as devops.built_by. That direction is the safe one — an
  # author over-counted is an author over-EXCLUDED, and Carl yields even the standing
  # primary seat to the no-self-review rule, so the worst outcome is a pool too small
  # to seat, which refuses loudly, rather than a soul silently seated on his own diff.
  # TaskReviewClaim.self_review? cannot be leaned on to prevent any of this: it answers
  # false on a blank reviewer slug or an unstamped task, which is exactly where the
  # author set is empty.
  #
  # The warning is the other half of "recorded or REFUSED LOUDLY". The board record is
  # what a human reads; this is what the log carries when someone asks why built_by did
  # not move — and on the nameless lane it is the ONLY signal there is, so it says
  # which of the two states it is and how to leave that state.
  def reviewer_taking_the_build?(named)
    return false unless self.class.soul?(named)

    claim = live_reviewing_party_claim
    return false if claim.nil?

    holder = claim.holder_agent.to_s.strip
    unless self.class.soul?(holder)
      Rails.logger.warn(
        "[builder-stamp] #{slug}: this task's live REVIEW claim names no reviewer, so it " \
        "cannot clear #{named}, who claimed the build from the session holding it. " \
        "Recorded as an AUTHOR (devops.builders); devops.built_by left alone. Name the " \
        "reviewer (bin/task review-claim acquire #{slug} --agent <soul>) or release the " \
        "review first (bin/task review-claim release #{slug})."
      )
      return true
    end
    return false unless holder.casecmp?(named.to_s.strip)

    Rails.logger.warn(
      "[builder-stamp] #{slug}: #{holder} holds this task's live REVIEW claim and claimed " \
      "the build. Recorded as an AUTHOR (devops.builders); devops.built_by left alone. " \
      "Release the review first: bin/task review-claim release #{slug}"
    )
    true
  end

  # True when this save writes a claim lease that differs from the stored one — a
  # re-claim or a renewal. Compared AFTER enforce_build_claim_invariant, so a write
  # that simply omitted the claim — a raw whole-column `metadata:` assignment, or a
  # key posted blank — reads as unchanged once that guard restores the keys from the
  # prior record, and is correctly not a claim.
  def claim_lease_rewritten?
    current = metadata.is_a?(Hash) ? (metadata["devops"] || {}) : {}
    ClaimLease::CLAIM_KEYS.any? { |key| current[key].to_s != prior_devops[key].to_s }
  end

  # The soul to record as the builder, or nil to leave built_by as-is. Precedence:
  #   1. The build-claim actor (Current.task_event_actor) when it's a soul SLUG —
  #      an explicit `--actor <soul>` move (or a web action by a soul). This always
  #      wins, so a rework re-claim by a different soul RE-POINTS built_by.
  #   2. else KEEP an existing built_by — a no-actor / non-soul re-claim never
  #      clobbers a recorded builder (only an explicit --actor re-points it).
  #   3. else the task's PERSONA (devops.persona) when it's a soul SLUG — a session
  #      "acting as" a soul, whose face the card already paints as the one working
  #      this task (see #sync_persona_identity). If the board shows Jasper building
  #      it, Jasper is the builder.
  #   4. else the task's assigned agent_slug when it's a soul SLUG — the automatic,
  #      no-flag default. A bare `bin/task move <slug> building` defaults the actor
  #      to the session id (a UUID, not a soul), so rule 1 can't fire; backing the
  #      stamp with the assigned agent records the builder WITHOUT the operator
  #      passing a flag every time (the FIX behind reviewer-select-exclude). The
  #      persona/assignee fills only a BLANK built_by (rule 2 guards re-claims).
  # nil when none apply (non-soul actor, no existing builder, non-soul/blank
  # persona and agent_slug) — the builder is then genuinely UNKNOWN, and
  # ReviewerSelector reports it as such so callers can fail closed rather than
  # read an empty exclusion list as "nobody to exclude".
  # Every rule below tests .soul? — the ROSTER, not just SOUL_SLUG's shape. A
  # typo'd `--actor stefon` is not a soul who could have built anything, and
  # stamping it named a builder that excluded nobody while reading as known. It now
  # falls through to the later rules, and if none resolve the builder stays blank —
  # UNKNOWN, which refuses. An unrecognised soul must never do better than silence.
  def builder_to_stamp
    actor = Current.task_event_actor.presence
    return actor if actor && self.class.soul?(actor)
    # Rule 2 consults the STORED builder as well as the incoming one: a client that
    # posts built_by BLANK — or a raw whole-column `metadata:` write, which is
    # permitted wholesale and folds through nothing — leaves the incoming value
    # empty, and reading only that would let the persona/assignee default re-point a
    # builder already on record. Only an explicit soul actor (rule 1) ever re-points.
    return nil if devops["built_by"].presence || prior_devops["built_by"].presence

    [devops["persona"].to_s, agent_slug.to_s].find { |slug| self.class.soul?(slug) }
  end

  # `set_initial_position` (the `before_create` genesis seed above) now comes from
  # Studio::Board::Rankable — a new task lands at the TOP of its column (zone max +
  # 100 under the `position DESC` sort, 100-spaced to leave drag gaps). The concern's
  # implementation is byte-for-byte what Task hand-rolled, so it was removed here.

  # A still-open operator-approval REQUEST is settled once the task is past the
  # `submitted` seam: the PR review flow takes over, so the local-preview approval
  # is moot and its WAITING APPROVAL treatment (the card_glow "approval" state and
  # the operator-approval status bar, both keyed off #waiting_for_operator_approval?)
  # must drop. Settled in before_save, so it rides the SAME UPDATE as whatever
  # write reached this stage — a rollback can never strand a half-settled card.
  #
  # An INVARIANT, not a transition event. It was a transition callback
  # (`entering_submitted_stage?`, fired only on the one save that moved
  # building → submitted) until 2026-07-27, and that shape leaked three ways —
  # all three reproduced against the shipped code, all three now regression-tested
  # below:
  #
  #   1. a LATER wholesale devops echo restores it. `bin/task update --checks`
  #      PATCHes the entire devops hash, and a hash read before the move still
  #      carries "waiting"; the stage does not change on that write, so the
  #      transition callback never fired again.
  #   2. flagging approval AFTER submitting sticks forever — there was no move
  #      left to settle it.
  #   3. neither did any LATER move: reviewed / assembled / shipped were not the
  #      submitted transition, so a restored request rode all the way to SHIPPED.
  #      That is what the operator saw: a shipped card still flashing WAITING
  #      APPROVAL, with nothing left in the pipeline that could clear it.
  #
  # So the rule is now stated as a property of the STAGE, re-asserted on every
  # save: a waiting request may exist only in the stages that can act on it.
  # APPROVAL_REQUEST_STAGES is an ALLOW-list on purpose — a stage added later
  # settles by default rather than quietly inheriting a badge nothing clears.
  # (`blocked` is absent because a block is a `building` attribute — Task#block!
  # parks the task on building — so a QA-rework demo can re-request approval.)
  #
  # Only "waiting" is settled — "changes_requested" and an already-"approved"
  # grant carry their own meaning into review and are left untouched. We resolve
  # to "none" (a settled, no-badge status), NOT "approved": the operator never
  # granted approval, so faking a grant would misreport the acceptance metric.
  # That reason stands on its own. It is a property of THIS transition — a
  # state-machine settle must not invent an outcome nobody chose — not a rule
  # about who may write "approved". Since 2026-08-09 any lane may record a grant
  # the operator gave in words; this settle still never fabricates one.
  #
  # Idempotent by construction: once "none" every later save is a no-op.
  def settle_operator_approval_past_submit
    return if APPROVAL_REQUEST_STAGES.include?(stage)
    return unless approval_status == OPERATOR_APPROVAL_WAITING

    merged = metadata.deep_dup
    (merged["devops"] ||= {})["approval_status"] = OPERATOR_APPROVAL_NONE
    self.metadata = merged
  end

  def stamp_operator_approval_request
    return unless will_save_change_to_metadata?
    return unless devops["approval_status"] == OPERATOR_APPROVAL_WAITING
    return if (metadata_was || {}).dig("devops", "approval_status") == OPERATOR_APPROVAL_WAITING

    merged = metadata.deep_dup
    approval = (merged["devops"] ||= {})
    approval["approval_requested_at"] ||= Time.current.iso8601
    self.metadata = merged
  end

  # The durable close of the operator-acceptance approval window — stamped the
  # moment approval flips to "approved", mirroring stamp_operator_approval_request's
  # open. Still a real release/operator metric (the /deployments approval chip reads
  # it); it just no longer projects as a task testing phase since VERSION 2.
  # Runs in before_save so it stamps onto the metadata the controller has already
  # folded — server-owned, with no client write left that could land after it.
  def stamp_operator_approval_approved
    return unless will_save_change_to_metadata?
    return unless devops["approval_status"] == OPERATOR_APPROVAL_APPROVED
    return if (metadata_was || {}).dig("devops", "approval_status") == OPERATOR_APPROVAL_APPROVED

    merged = metadata.deep_dup
    approval = (merged["devops"] ||= {})
    approval["approval_approved_at"] ||= Time.current.iso8601
    self.metadata = merged
  end

  # True when the just-saved update actually CHANGED the derived approval_status.
  # Rails' saved_change_to_* only tracks columns, not a scalar nested in the
  # metadata JSON, so compare the before/after devops.approval_status ourselves.
  # Gated on saved_change_to_metadata? first so a stage-only save short-circuits.
  def saved_change_to_approval_status?
    return false unless saved_change_to_metadata?

    approval_status_before_last_save != approval_status
  end

  def approval_status_before_last_save
    before, = saved_change_to_metadata
    (before || {}).dig("devops", "approval_status").to_s.presence
  end

  def broadcast_operator_approval_change
    DeploymentsBroadcaster.approval_change(self)
  end

  def broadcast_block_change
    DeploymentsBroadcaster.block_change(self)
  end

  # devops.checks_run carries TWO namespaces. The AUTHOR owns the tier tags
  # ("[unit] bin/rails test ..."), and a checks update REPLACES those — that is the
  # documented contract. The CERT WRITERS (bin/fast-check, bin/full-suite-check)
  # own the fingerprint-bound evidence ("[full-suite@<tree-hash>] ..."), which
  # bin/dor-check reads to decide whether this exact code is certified. A write
  # may supersede an evidence LANE only by SUPPLYING evidence for it; every lane
  # the incoming list does not address is carried forward. The rule is symmetric
  # (reverse regression 2026-07-20, fast-check-preserves-checks): a PURE-EVIDENCE
  # write — every incoming line `[lane@fp]`, what a cert writer sends when its own
  # read of checks_run came back stale or empty — supplies no author line and so
  # cannot supersede the author namespace; the tier tags are carried forward too.
  #
  # Regression (2026-07-12, hit twice in one session): `bin/task update --checks`
  # replaced the whole array, so an agent recording its tier-tagged test plan
  # AFTER certifying silently destroyed its own cert — and dor-check reported
  # "full-suite: MISSING (never certified for this exact code)" on code it had just
  # certified green. A gate that lies teaches agents to route around it, and the
  # fastest way "around" was to hand-write an evidence line, i.e. forge the cert.
  # This makes the destruction impossible instead of documenting an ordering
  # workaround. The write rule lives in lib/cert_evidence.rb (shared with the CLI).
  def preserve_cert_evidence
    return unless will_save_change_to_metadata?

    prior = Array((metadata_was || {}).dig("devops", "checks_run"))
    return if prior.empty?
    # An explicit devops teardown (the whole hash removed) is left alone — this
    # guard defends the evidence namespace, not the existence of devops.
    return unless metadata["devops"].is_a?(Hash)

    incoming = Array(metadata.dig("devops", "checks_run"))
    preserved = CertEvidence.preserve(prior: prior, incoming: incoming)
    return if preserved == incoming

    merged = metadata.deep_dup
    merged["devops"]["checks_run"] = preserved
    self.metadata = merged
  end

  # The build claim exists only while the task is BUILDING, and while it is
  # building it survives a client PATCH that forgot to mention it. One invariant,
  # two failures it retires.
  #
  # RELEASE. Every other lease in this codebase has an explicit release that nils
  # its columns — DevopsShift, TaskReviewClaim, ReleaseConductorClaim,
  # MigrationLaneClaim all do. The devops build claim was the one lease with NO
  # release path at all: `bin/task move <slug> submitted` sends no devops, nothing
  # server-side cleared the keys, and the normalizer silently drops blanks
  # (`next if normalized_value.blank?`) so a client could not clear them even on
  # purpose. Sessions therefore stopped heartbeating and walked away, leaving a
  # stale holder on the row forever. Stating it as an invariant rather than
  # hanging it off the submitted transition means it also heals the rows already
  # carrying a dead claim, and it cannot be escaped by a path that moves the stage
  # some other way.
  #
  # PRESERVE. This USED TO BE the whole story: Api::V1::TasksController#task_params
  # assigned metadata WHOLESALE, so every PATCH carrying `devops` REPLACED the
  # subhash and deleted any key the client did not echo. The board's own edit form
  # permits no claim keys at all (app/controllers/tasks_controller.rb), so opening a
  # task on the board and saving it silently destroyed a LIVE claim — and a destroyed
  # claim reads as unclaimed, which lets a second agent take a desk someone is working
  # at. Both paths now fold through Task.merge_devops_into_metadata since
  # `api-devops-patch-replaces`, so a merely OMITTED claim key survives on its own.
  # Two doors still reach this guard: a key posted BLANK (the fold keys on the
  # posted names and the normalizer drops blanks, so a blank claim key IS a delete),
  # and a raw whole-column `metadata:` write, which is permitted wholesale and folds
  # through nothing. That is also why `bin/task show --json` and `bin/task begin`
  # disagreed about the same lease 20 seconds apart: not two readers of one fact,
  # but one fact being erased and rewritten underneath them. This is the same
  # self-healing shape as #restore_mascot_identity and #preserve_cert_evidence,
  # applied to the keys that decide who owns a desk.
  #
  # Note what is NOT here: nothing expires a lease. Expiry stays where it belongs,
  # on the TTL clock in ClaimLease — restoring an omitted key preserves a lease
  # that is still lapsing on its own schedule, it does not extend it.
  def enforce_build_claim_invariant
    devops = metadata.is_a?(Hash) ? metadata["devops"] : nil
    # An explicit devops teardown (the whole hash removed) is left alone — this
    # guard defends the claim namespace, not the existence of devops.
    return unless devops.is_a?(Hash)

    updated = devops.dup
    if stage == "building"
      return if new_record?

      # Fill in ONLY for the holder already on the row. A payload naming a
      # DIFFERENT session is a re-claim or a steal and stands entirely on its own:
      # inheriting the previous holder's nonce would staple one instance's
      # identity to another instance's claim — the rule ClaimLease.renewed states
      # for itself as "a DIFFERENT session's nonce is never inherited".
      #
      # Reachable, not theoretical. SessionIdentity.nonce degrades to "" whenever
      # the agent process cannot be resolved (the detached case), and
      # normalize_devops_metadata drops blank values, so a real steal arrives
      # naming a NEW claimed_session with NO claim_nonce at all — precisely the
      # shape this guard has to refuse to complete from the old record.
      #
      # A payload naming NO session is not talking about the claim (the blank-post
      # and raw-metadata-write cases this method exists for), and there the stored
      # claim is restored whole.
      incoming_session = updated["claimed_session"].to_s
      return unless incoming_session.empty? || incoming_session == prior_devops["claimed_session"].to_s

      ClaimLease::CLAIM_KEYS.each do |key|
        next if updated[key].present? || prior_devops[key].blank?

        updated[key] = prior_devops[key]
      end
    else
      ClaimLease::CLAIM_KEYS.each { |key| updated.delete(key) }
    end
    return if updated == devops

    self.metadata = metadata.merge("devops" => updated)
  end

  # The slug is the readable, immutable handle set at creation — it drives the
  # URL (/tasks/<slug>) and seeds the worktree + branch. Precedence: an explicit
  # --slug (parameterized), else the (now-terse) title (parameterized +
  # auto-suffixed), else an opaque task-<hex> last resort. `@custom_slug` records
  # whether the slug is readable, so the trickle-down only fires for a real handle.
  def generate_slug
    explicit = slug.present?
    base = (explicit ? slug : title).to_s.parameterize
    if base.present?
      # Explicit --slug is left as-is (uniqueness validation surfaces a collision
      # to the chooser); a title-derived slug auto-suffixes, since short titles repeat.
      self.slug = explicit ? base : unique_slug(base)
      @custom_slug = true
    else
      self.slug = "task-#{SecureRandom.hex(6)}"
      @custom_slug = false
    end
  end

  # Append -2, -3, … until the title-derived slug is unique.
  def unique_slug(base)
    candidate = base
    n = 1
    while Task.where(slug: candidate).where.not(id: id).exists?
      n += 1
      candidate = "#{base}-#{n}"
    end
    candidate
  end

  # Trickle-down: a custom slug seeds worktree_slug + branch (feat/<slug>) when
  # they aren't given explicitly, so one slug drives the rest. Opaque hex slugs
  # don't trickle (nothing readable to propagate).
  def default_devops_handles_from_slug
    return unless @custom_slug

    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    devops["worktree_slug"] = slug if devops["worktree_slug"].blank?
    devops["branch"] = "feat/#{slug}" if devops["branch"].blank?
  end

  # Give every new task a Pokémon mascot — a fun, unique, traitless handle for the
  # session working it ("Snorlax is building <task>"). Idempotent: an explicit
  # mascot (the --mascot override) is left alone. Unique among live tasks; the draw
  # recycles a Pokémon once its task ships or is archived. No-ops gracefully when
  # the deck isn't seeded (or the table doesn't exist yet) so task creation never
  # depends on Pokémon being present.
  def sync_session_mascot
    return unless Pokemon.table_exists?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    # A persona (acting as a soul) owns the mascot fields — never overwrite it with
    # a Pokémon. sync_persona_identity has already stamped the agent's identity.
    return if devops["persona"].to_s.strip.present?
    sid = devops["session_id"].to_s
    # Reassign only when there's no mascot yet, or this session differs from the one
    # the current mascot belongs to (an agent handoff). A session-less task keeps it.
    needs = devops["mascot"].blank? || (sid.present? && devops["mascot_session"].to_s != sid)
    return unless needs

    slug, shiny = session_mascot_draw(sid)
    return unless slug
    devops["mascot"] = slug
    devops["mascot_session"] = sid
    # Stamp the mascot's signature type color (its least-common type) AND its type
    # emoji(s) so the status line / context JSON can tint and glyph the ⊙<mascot>
    # handle without DB access (bin/task and bin/agent-worktree are API clients).
    # nil/blank when the type colors aren't seeded — the status line then falls
    # back to its default tint and the 🛠 ⊙ glyphs. A shiny draw is stamped
    # (server-owned, like color/emoji) and announces itself with a ✨ glyph.
    pokemon = Pokemon.find_by(slug: slug)
    devops["mascot_shiny"] = shiny
    devops["mascot_color"] = pokemon&.signature_color
    devops["mascot_emoji"] = pokemon&.status_emoji(shiny: shiny)
    # A fresh draw starts a fresh line — the new Pokémon hasn't earned any gates.
    devops.delete("mascot_stage")
  end

  # Strip any devops key that shadows a top-level column, on EVERY save. The
  # normalizer's raise covers the front door (`devops:` params), but two paths walk
  # around it: `Api::V1::TasksController#task_params` permits `metadata: {}` and
  # only overrides it when `params[:devops]` is present, so a raw
  # `{"metadata":{"devops":{"release_slug":"…"}}}` PATCH lands unnormalized; and
  # rows written BEFORE the retirement already carry the stale value.
  #
  # So the rule is enforced twice, deliberately, with different manners:
  #   • normalize_devops_metadata RAISES — the caller named the wrong home and can
  #     be told so, which is the whole point of retiring the key loudly.
  #   • this callback SHEDS in silence — it also runs on saves that never mentioned
  #     the key (a stage move on a legacy row), and raising there would brick every
  #     task already carrying the shadow. The value is a fiction either way; the
  #     invariant is what matters, and this makes the store self-healing.
  # Net effect: `metadata.devops.release_slug` is unreachable by any path, so the
  # column is the only place the name can live. Do not "simplify" this to one site.
  def shed_column_shadow_keys
    return if metadata.blank?

    devops = metadata["devops"]
    return unless devops.is_a?(Hash)

    DEVOPS_COLUMN_KEYS.each_key { |key| devops.delete(key) }
  end

  # Carry the mascot HANDLE across a client write that dropped it. `mascot` and
  # `mascot_session` ARE client keys, so the fold now preserves them when a PATCH
  # simply OMITS them. What still empties them is a name posted BLANK (the fold keys
  # on the posted names) or a raw whole-column `metadata:` write — and
  # normalize_devops_metadata already SKIPS blank values, so no client can express
  # "clear the mascot" through this path anyway. A client that sends a real slug
  # (the --mascot override) still wins; only silence is undone. Without this a bare
  # `{"devops":{"worktree_slug":"…"}}` PATCH emptied the mascot, and the next
  # build-stage save redrew a different Pokémon mid-task.
  def restore_mascot_identity
    return if new_record?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})

    %w[mascot mascot_session].each do |key|
      next if devops[key].present? || prior_devops[key].blank?

      devops[key] = prior_devops[key]
    end
  end

  # Re-derive the mascot's DISPLAY stamps — shiny, signature color, type emoji(s) —
  # plus carry its consumed evolution gate forward. These four are server-owned
  # (deliberately absent from DEVOPS_KEYS) — which is now also what SAVES them from a
  # v1 devops PATCH, since the fold keys on the posted names INTERSECTED with
  # DEVOPS_KEYS and so can never drop a name it does not know. What still wipes them
  # is a client that rebuilds the hash FROM the whitelist — `bin/task`'s
  # read-modify-write echoes normalize_devops_metadata, which keeps only DEVOPS_KEYS
  # — or a raw whole-column `metadata:` write, permitted wholesale and folded by
  # nothing. sync_session_mascot cannot restore them: it runs only
  # on a build-stage change, and its own `needs` guard short-circuits while `mascot`
  # (a client key) survives. So they are re-asserted here on EVERY save
  # — the same shape as sync_app_identity's app_color, which is why app_color never
  # suffered this. Without it the stamps died on the first bind-task PATCH: the
  # →designed event snapshot baked the shiny face and every later one baked the
  # normal sprite, so the board card's second crew slot lost its ✨.
  #
  # Shiny is a property of the DRAW, and SessionMascot is that draw's durable home,
  # so a session-bound task re-derives from it (find_by, never SessionMascot.for —
  # `for` would CREATE a row and roll a fresh shiny for an unknown session). A
  # session-less task drew task-locally with nowhere durable to re-read, so its
  # stamp is carried forward from the pre-save record instead. Non-fatal: a mascot
  # is decoration, and no task save may die for it.
  def sync_mascot_display
    return unless Pokemon.table_exists?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    # A persona (acting as a soul) owns the mascot fields — its name/color/emoji
    # are an Agent's, not a Pokémon's. sync_persona_identity is authoritative.
    return if devops["persona"].to_s.strip.present?
    return if devops["mascot"].blank?

    # The consumed evolution gate has no derivable source — only the prior record.
    # Losing it re-opens a spent gate, so a blocked→resubmitted loop evolves twice.
    # Restored BEFORE evolve_stage_mascot reads it (see the callback order above),
    # and only for the SAME Pokémon: a handoff redraw deliberately clears the gate
    # so the new mascot starts a fresh line, and carrying the old one forward would
    # rob it of its submit evolution.
    if devops["mascot_stage"].nil? && same_mascot_as_prior?(devops) && prior_devops["mascot_stage"]
      devops["mascot_stage"] = prior_devops["mascot_stage"]
    end
    shiny = mascot_shiny_source(devops)
    devops["mascot_shiny"] = shiny
    pokemon = Pokemon.find_by(slug: devops["mascot"])
    return unless pokemon # unseeded deck: keep the color/emoji we already carry

    devops["mascot_color"] = pokemon.signature_color
    devops["mascot_emoji"] = pokemon.status_emoji(shiny: shiny)
  rescue StandardError => e
    Rails.logger.warn("[mascot-display] stamp skipped (non-fatal): #{e.class}: #{e.message}")
  end

  # Whether this task's mascot is a shiny draw, cheapest source first: the stamp
  # already on the record (present unless a client PATCH just wiped it), else the
  # session's SessionMascot row, else the pre-save record. The SessionMascot read
  # therefore costs one query only on the saves that follow a wipe.
  def mascot_shiny_source(devops)
    return self.class.shiny_value?(devops["mascot_shiny"]) unless devops["mascot_shiny"].nil?

    sid = devops["mascot_session"].to_s.strip
    if sid.present? && SessionMascot.table_exists? &&
       (session_mascot = SessionMascot.find_by(session_id: sid))
      return session_mascot.shiny?
    end

    same_mascot_as_prior?(devops) && self.class.shiny_value?(prior_devops["mascot_shiny"])
  end

  # The devops hash as it stands in the DB — what a wholesale in-memory replace
  # has not touched. Empty on create.
  def prior_devops
    (metadata_was || {})["devops"] || {}
  end

  # Whether this save keeps the mascot the DB already holds. False on create and on
  # a handoff redraw — the two cases where the prior record describes a DIFFERENT
  # Pokémon and so must not be carried forward.
  def same_mascot_as_prior?(devops)
    prior = prior_devops["mascot"]
    prior.present? && prior == devops["mascot"]
  end

  # Evolve the TASK's copy of its mascot at a pipeline gate (reviewed/assembled).
  # The review gate is reserved for three-stage families, so Charmander reviews as
  # Charmeleon while Pikachu stays Pikachu. The assemble gate then evolves whatever
  # can still evolve, celebrating QA-green with the mascot's final form — which is
  # what puts a one-evolution line's single step at `assembled` rather than
  # spending it early. The SESSION's mascot is untouched: a session working
  # two tasks keeps its own stable Pokémon while each task's copy evolves with
  # progress. devops.mascot_stage records the gate consumed, so a blocked→resubmitted
  # loop never double-evolves; it is not a client (DEVOPS_KEYS) field, so board
  # updates can't clobber it.
  def evolve_stage_mascot
    return unless Pokemon.table_exists?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    # Personas own the mascot fields (an agent name, not a Pokémon) — never evolve.
    return if devops["persona"].to_s.strip.present?

    gate = Task::MASCOT_EVOLUTION_GATES[stage]
    return if gate.nil? || devops["mascot_stage"].to_i >= gate

    pokemon = Pokemon.find_by(slug: devops["mascot"].presence)
    return unless pokemon

    devops["mascot_stage"] = gate
    return if gate == 1 && !pokemon.second_evolution_form?

    evolved = pokemon.evolutions.order(Arel.sql("RANDOM()")).first
    return unless evolved # nowhere to go — the gate is still consumed

    devops["mascot"] = evolved.slug
    devops["mascot_color"] = evolved.signature_color
    devops["mascot_emoji"] = evolved.status_emoji(shiny: mascot_shiny?)
  rescue StandardError => e
    Rails.logger.warn("[mascot-evolution] skipped (non-fatal): #{e.class}: #{e.message}")
  end

  # Persona override: when a task carries devops.persona (an agent slug — "act as
  # Jasper"), the status-line mascot becomes that SOUL (name + glyph + tint) instead
  # of the session's Pokémon. Idempotent and re-stamped on every save so it survives
  # the client's read-modify-write (mascot_color/emoji aren't client keys). An
  # unknown/blank persona is a no-op, leaving the Pokémon path to run.
  # Explicit "revert to the session Pokémon" sentinels for devops.persona, so a
  # mid-task `bin/task update <slug> --persona none` drops the soul. Case-insensitive.
  PERSONA_CLEAR = %w[none clear off -].freeze

  def sync_persona_identity
    return unless Agent.table_exists?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    raw = devops["persona"].to_s.strip
    return if raw.empty?

    agent = Agent.find_by(slug: raw.downcase)
    # Clear (--persona none) OR an unknown soul (a typo): drop the persona AND reset
    # the mascot so the session's Pokémon is (re)drawn. Niling the mascot first is
    # required — on a plain update (no stage change) sync_session_mascot's own
    # before_save guard wouldn't fire, so call it inline to repaint the Pokémon now.
    # (An unknown soul reverting is the right "your persona didn't take" feedback.)
    if PERSONA_CLEAR.include?(raw.downcase) || agent.nil?
      devops.delete("persona")
      devops["mascot"] = nil
      devops["mascot_session"] = nil
      devops["mascot_shiny"] = nil
      devops["mascot_color"] = nil
      devops["mascot_emoji"] = nil
      devops.delete("mascot_stage")
      sync_session_mascot
      return
    end

    devops["mascot"] = agent.name
    devops["mascot_color"] = agent.status_color
    devops["mascot_emoji"] = agent.emoji
  end

  # Stamp the app's status-line tint from its first repository, so bin/statusline
  # can color the app slug without DB access (it and bin/agent-worktree are API
  # clients). app_color is server-owned (not a DEVOPS_KEY), so it's re-derived each
  # save — never lost to the client's read-modify-write. No-ops when the apps table
  # isn't present or the repo has no App row (the slug then renders in the default tint).
  def sync_app_identity
    return unless App.table_exists?
    self.metadata ||= {}
    devops = (metadata["devops"] ||= {})
    # FIRST repo, deliberately: this paints the status line's app TINT, and a tint is
    # singular by nature. It is the one `.first` in the multi-repo family that is
    # cosmetic — the gates read the whole list (bin/dor-check grades a cert per repo),
    # coverage reads `release_pr_urls` per repo, and `release_repo` is separately
    # fenced by `release_repos`. Worst case here is repo #1's color.
    app_slug = self.class.normalize_devops_list(devops["repositories"]).first
    return if app_slug.blank?

    app = App.find_by(slug: app_slug)
    devops["app_color"] = app&.color
  end

  # The Pokémon for a session: ADOPT the session's stable mascot (SessionMascot —
  # drawn eagerly at session start so the status line shows it in seconds, OR
  # drawn here on first task when the hook hasn't run). SessionMascot itself reuses
  # a live peer task's mascot, so every task an agent builds shares its handle.
  # With no session, draw a one-off so the task isn't mascot-less.
  # [slug, shiny] for this task's mascot: the session's stable draw (slug AND its
  # shiny roll) when a session exists, else a fresh task-local draw with its own
  # shiny roll. [nil, false] when nothing can be drawn.
  def session_mascot_draw(sid)
    if sid.present? && (session_mascot = SessionMascot.for(sid))
      return [session_mascot.mascot_slug, session_mascot.shiny?]
    end

    slug = Pokemon.draw(exclude: Task.active_mascots)&.slug
    slug ? [slug, Pokemon.roll_shiny?] : [nil, false]
  end

  def word_count(text)
    text.to_s.split(/\s+/).reject(&:blank?).size
  end

  # True on create (acceptance newly set) and on any update that actually changes
  # the acceptance list — so untouched existing tasks (and updates to other devops
  # fields) stay grandfathered. Both sides are normalized before comparing, so a
  # task whose stored acceptance isn't already in normalized form (e.g. a direct
  # Task.create! with dupes/embedded newlines) isn't falsely re-validated on an
  # unrelated devops update.
  def acceptance_changed?
    previous = self.class.normalize_devops_list((metadata_was || {}).dig("devops", "acceptance"))
    previous != devops_acceptance
  end

  # Keep titles tight (3-5 words) so they read at a glance and slugify cleanly —
  # detail belongs in agent_context, not the title.
  def title_within_word_range
    count = word_count(title)
    return if TITLE_WORD_RANGE.cover?(count)

    errors.add(:title, "must be #{TITLE_WORD_RANGE.first}-#{TITLE_WORD_RANGE.last} words " \
                       "(was #{count}) — name it tightly; put detail in agent_context")
  end

  # Each acceptance bullet stays a readable 5-12 words so the human can follow the story.
  def acceptance_bullets_within_word_range
    devops_acceptance.each_with_index do |bullet, i|
      count = word_count(bullet)
      next if ACCEPTANCE_WORD_RANGE.cover?(count)

      errors.add(:base, "acceptance ##{i + 1} must be #{ACCEPTANCE_WORD_RANGE.first}-" \
                        "#{ACCEPTANCE_WORD_RANGE.last} words (was #{count}): #{bullet.to_s.truncate(48)}")
    end
  end
end
