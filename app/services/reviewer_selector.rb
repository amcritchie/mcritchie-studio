# Picks the reviewer pair for a submitted task's PR under the Carl-owns-review
# model (docs/agents/agents/carl/sops/pr-review.md). There is no Avi supervisor
# and no domain-fit contest for the deep seat: **Carl is the STANDING PRIMARY** —
# the Lead Architect, deep reviewer, and OWNER of every PR review. The selection
# here only chooses the LIGHT (the focused second read): a domain-fit pick from
# the specialist pool {Shannon=UI · Jasper=Web3 · Steffon=DevOps/Platform ·
# Alex=Documentation}. Carl is no longer a pool pick — he sits above it as the
# fixed primary.
#
# The LIGHT is chosen by DOMAIN FIT (the task's shape + repositories + risk tags →
# the specialist whose domains cover the change) with a LOGGED, SEEDED-PER-TASK
# tiebreak, so the second read spreads across the specialists instead of always
# landing on the same soul. The pair is stamped 1 PRIMARY (Carl) / 1 LIGHT (the
# specialist); the two role NAMES come from the single vocabulary
# (config/devops_vocabulary.yml → reviewer_roles) via .primary_role / .light_role
# so the role this stamps can't drift from the SOP + the docs.
#
# The tiebreak RNG is seeded per-task by default (see #seed_for), so the LIGHT
# pick is REPRODUCIBLE across processes: `bin/reviewer-select` (.decision) and the
# avatars recorder in Task (.select) compute it independently, and the seed makes
# both roll identically — the CLI preview always matches the recorded pick, even
# on a genuine tie. Different tasks still spread the picks.
#
# CARL YIELDS THE PRIMARY SEAT ONLY to the hard "no self-review" rule: if Carl is
# among the task's AUTHORS — or a caller names Carl the qa_owner — he reviews
# nothing, and the standing-primary convenience gives way to a domain-fit pair drawn
# entirely from the specialist pool. Self-review integrity outranks the
# standing-primary policy.
#
# The specialist pool is {shannon=UI · jasper=Web3 · steffon=DevOps/Platform ·
# alex=Documentation}. The QA owner (Avi by default — after the 2026-07-22 reslot he
# owns qa-release: the accepted→release sweep + the QA deploy that flips members
# `assembled`) is EXCLUDED as a LIGHT so one soul never both reviews AND QAs the same
# change — "no self-gating". Avi isn't in the specialist pool, so his default
# exclusion is a formal safeguard; pass a different `qa_owner:` (e.g. a specialist)
# and that soul is dropped from the light pool for this task.
#
# EVERY AUTHOR is excluded from the LIGHT seat — a soul shouldn't review their own
# work, and a task can have SEVERAL authors. `devops.built_by` holds ONE slug and
# Task#builder_to_stamp RE-POINTS it on an explicit re-claim, so after a mid-build
# handoff (a session limit kills a builder, another soul finishes the job) it names
# the LAST claimant and the first author is gone from the only field this class used
# to read. Measured 2026-08-30 on two tasks in one sitting; on PR #1081 the light
# seat went to ALEX, who had written every test on the diff, because built_by said
# "steffon". A hand-passed `--busy alex` was the only thing that stopped it.
#
# So #builders is the exclusion set, unioned from three sources: devops.built_by
# (the current builder), devops.builders (the SERVER-OWNED append-only claim
# history — see Task#builder_roll_call), and every soul actor on a `→ building`
# TaskEvent (persisted tasks only, which self-heals rows stamped before the
# accumulator existed). Pass `builder:` — a comma/space list — to override the whole
# set. #builder keeps its old singular meaning for the audit and the log.
#
# An author who isn't a specialist (Carl, a non-pool soul, or the QA owner) excludes
# nobody from the light pool. If excluding them all would leave too few light
# candidates, the least-likely-to-be-seated are KEPT (the decision/log flag them via
# #kept_builders) so a pair is always returned — the recorder must never break — and
# `bin/reviewer-select` REFUSES on that flag, because a kept author is a soul about
# to review their own diff.
#
# WHEN NO SOURCE NAMES A SOUL the authors are UNKNOWN, not absent, and the decision
# says so via `builder_known` — the distinction this class did not draw until
# 2026-08-13, when an empty exclusion list read as "nobody to exclude" and
# `bin/reviewer-select` picked Carl to review Carl's own PR. `builder_known` is now
# asked over the SET and over its COMPLETENESS: a claim that named nobody while
# other authors were already on record stamps devops.builders_unattributed, and an
# author list known to be missing someone is not a settled answer either. Selection
# still DEGRADES here (the reviewed-transition recorder must never break on a missing
# stamp); it is the CLI that fails closed on the fact, and `builder: "none"`
# (NO_BUILDER) is the caller's explicit "no soul built this" assertion.
#
# EVERY SLUG IS CHECKED AGAINST THE ROSTER (#soul? → Task.soul?), never the shape
# alone. `Task::SOUL_SLUG` only asks "does this look like a handle", so a typo'd
# `--builder stefon` was a KNOWN builder excluding NOBODY — the fail-closed refusal
# lifted by a value identifying no one. Task.soul_roster keeps a static floor when
# the DB is unreachable, so this holds in the no-Agent-rows degraded mode below
# without trading fail-closed for fail-open.
#
# BUSY souls are excluded from the LIGHT seat too — specialists currently
# mid-build or mid-review on OTHER in-flight tasks shouldn't be handed a second
# read while they're heads-down elsewhere. Pass `busy:` (bin/reviewer-select's
# `--busy a,b,c`, and/or its board query of agents on stage=building tasks). Like
# the builder, the busy drop YIELDS rather than starve: if removing the builder +
# QA owner + every busy soul would leave too few candidates, the least-bad (best
# domain fit) busy souls are KEPT eligible (the decision/log flags them) so a pair
# is always returned.
#
# Reads each specialist's Agent.metadata["domains"] + ["review_weight"]; DEGRADES
# GRACEFULLY to built-in defaults when the Agent row or those keys are absent, so
# selection works even before the reviewer souls are seeded.
#
# `bin/reviewer-select <task>` is the CLI wrapper a review session runs to preview
# the pair + the auditable tiebreak from `.explain`.
require "zlib"

class ReviewerSelector
  # The full senior soul pool (slugs). Carl is the standing primary (removed from
  # the specialist draw below); the other four are the LIGHT specialists.
  POOL = %w[shannon carl jasper steffon alex].freeze

  # Carl — the Lead Architect. He owns EVERY PR review as the STANDING PRIMARY
  # (deep review + owner), so he is never a light-pool pick.
  STANDING_PRIMARY = "carl"

  # The soul who runs qa-release — the accepted→release sweep + the QA deploy at the
  # `assembled` step — excluded from the light pool by default so a reviewer never
  # gates their own QA (no self-gating). After the 2026-07-22 reslot this is AVI (he
  # owns qa-release); Steffon moved to production-deploy (the ship) and rejoined the
  # light specialist pool as the DevOps/Platform second read.
  DEFAULT_QA_OWNER = "avi"

  # The `builder:` value that ASSERTS no soul built this task (vs. the record
  # merely not saying). It is the caller's stated fact, and the only thing other
  # than a real soul that satisfies #builder_known? — so the fail-closed guard in
  # `bin/reviewer-select` has an explicit, auditable escape instead of being
  # routed around when a Pokémon session (no soul) genuinely did the build.
  NO_BUILDER = "none"

  # The two reviewer-role NAMES, sourced from the single vocabulary
  # (config/devops_vocabulary.yml → reviewer_roles) so the role this selector
  # stamps stays in lockstep with the SOP + the docs — rename a role in the YAML
  # and it flows here in one edit. Order is the convention: the FIRST role is the
  # deep/accountable seat (primary), the SECOND the focused second pass (light).
  # Degrades to the built-in pair if the YAML can't be read, so selection never
  # depends on the config loading.
  ROLE_FALLBACK = %w[primary light].freeze

  def self.reviewer_roles
    names = Devops::Vocabulary.reviewer_roles.keys.map(&:to_s)
    names.size >= 2 ? names : ROLE_FALLBACK
  rescue StandardError
    ROLE_FALLBACK
  end

  # The deep/accountable seat's role name (the "primary" reviewer — Carl).
  def self.primary_role = reviewer_roles.first

  # The focused second-pass seat's role name (the "light" reviewer — a specialist).
  def self.light_role = reviewer_roles.last

  # Fallback domain tags per soul when an Agent row has no metadata["domains"].
  # Keep aligned with the seeded `domains` in db/seeds/02_agents.rb.
  DEFAULT_DOMAINS = {
    "shannon" => %w[ui],
    "carl"    => %w[backend],
    "jasper"  => %w[web3 onchain],
    "steffon" => %w[devops platform],
    "alex"    => %w[docs documentation]
  }.freeze

  # Neutral weight when an Agent row has no metadata["review_weight"].
  DEFAULT_REVIEW_WEIGHT = 1.0

  # The seeded review_weight LABELS → their numeric weight. Under the standing-Carl
  # model this only orders the LIGHT specialists on a fit tie (the primary seat no
  # longer depends on it). A bare String#to_f would silently zero every label
  # ("heavy".to_f == 0.0); mapping the labels here keeps numeric weights (tests,
  # future tuning) and legacy "heavy"/"light" label rows both working.
  WEIGHT_LABELS = { "heavy" => 2.0, "light" => 1.0 }.freeze

  # The task's shape → the review domains that change needs covered (drives the
  # LIGHT specialist's domain fit).
  SHAPE_DOMAINS = {
    "ui-only"          => %w[ui],
    "ui+db"            => %w[ui backend],
    "backend"          => %w[backend],
    "library"          => %w[backend],
    "onchain"          => %w[web3 onchain],
    "onchain-vertical" => %w[web3 onchain ui backend],
    # A documentation-only change (SOP / runbook / operating-model / README) needs
    # the pool's Documentation seat — Alex, whose seeded domains carry both `docs`
    # and `documentation`. Both tokens map here so a doc-shaped task fits Alex
    # (fit 2) and nobody else (fit 0), landing him the LIGHT seat. Read by BOTH the
    # CLI preview (.decision) and the recorder (.select), so they stay reproducible.
    "docs"             => %w[docs documentation],
    # A test-only change (test/, tests/, e2e/ and nothing else) is reviewed as
    # BACKEND work, the same call `library` makes: its subject is test
    # infrastructure and the suite's own correctness, which is Carl's deep read
    # either way. The shape alone cannot tell a UI spec from a job test, so it
    # claims no ui/web3 domain here and lets the ADDITIVE signals do it — a
    # `ui` risk tag pulls Shannon in, a turf-vault/solana-studio repo pulls
    # Jasper in (RISK_DOMAINS / REPO_DOMAINS below). Claiming ui+backend from
    # the shape would fit every specialist equally and pick the light by tiebreak.
    "test-only"        => %w[backend]
  }.freeze

  # A risk tag → the domain whose specialist should weigh in as the light (deepens
  # the fit for risk-bearing work — e.g. a `solana` tag pulls Web3 in even on a
  # backend shape, where Carl already owns the deep read).
  RISK_DOMAINS = {
    "solana"    => "web3",
    "onchain"   => "web3",
    "payment"   => "backend",
    "migration" => "backend",
    "auth"      => "backend",
    "ui"        => "ui",
    "docs"      => "docs"
  }.freeze

  # A repo a task touches → the domain whose specialist should weigh in as the
  # light. The on-chain repos carry a strong Web3 signal the change's shape alone
  # can miss (e.g. a `backend` Ruby change inside solana-studio still wants
  # Jasper's eyes). ADDITIVE only — an unmapped repo contributes nothing.
  REPO_DOMAINS = {
    "turf-vault"    => %w[web3 onchain],
    "solana-studio" => %w[web3 onchain]
  }.freeze

  # The TaskEvent.metadata["reviewers"] payload: [{ "slug" =>, "weight" => },…].
  def self.select(task, **opts)
    new(task, **opts).reviewers
  end

  # The full, auditable decision record for the CLI (bin/reviewer-select): the
  # chosen pair (primary/light) PLUS the inputs, each reviewer's matched domains,
  # the excluded QA owner, and the per-candidate rolls + ranking — produced in ONE
  # ranked pass (one roll set) so what the CLI prints is exactly what was picked.
  # `.select` stays the slim canonical pick the model records.
  def self.explain(task, **opts)
    new(task, **opts).decision
  end

  # `builder:` overrides who built the task (else it's derived from the task —
  # see #builder). Pass it when the caller already knows the build agent.
  # `busy:` is a set of souls currently mid-build / mid-review on OTHER in-flight
  # tasks; they're excluded from the LIGHT pool too, so the second read never lands
  # on a specialist who's already heads-down elsewhere — UNLESS excluding them
  # would starve the pool below the light floor, in which case the least-bad busy
  # souls are KEPT back (see #excluded_busy), mirroring the builder keep rule.
  def initialize(task, qa_owner: DEFAULT_QA_OWNER, builder: nil, busy: [], logger: nil, random: nil)
    @task = task
    @qa_owner = qa_owner.to_s
    @builder_override = builder.to_s.strip.presence
    @busy = Array(busy).map { |s| s.to_s.strip }.reject(&:empty?).uniq
    @logger = logger || Rails.logger
    # Default the tiebreak RNG to a STABLE per-task seed. The default LIGHT pick
    # must be reproducible across processes: bin/reviewer-select prints `.decision`
    # while the avatars recorder in Task computes `.select` INDEPENDENTLY, so on a
    # genuine fit+weight tie a fresh process RNG let them diverge — one pair spawned,
    # another recorded. Seeding from the task's own identity (+ the excluded QA
    # owner AND excluded builder, which set the light pool) makes both passes roll
    # identically over the SAME post-exclusion pool, while different tasks still
    # spread the picks. Tests pass an explicit `random:` to pin a scenario.
    @random = random || Random.new(seed_for(@task, @qa_owner, excluded_builders.join(","), excluded_busy))
  end

  # Exactly two entries — [{ "slug" => carl, "weight" => "primary" }, { … "light" }]
  # — string-keyed so it serializes straight into the jsonb event metadata. The
  # role names come from the vocabulary (self.class.primary_role / .light_role).
  def reviewers
    primary, light = pair
    [
      { "slug" => primary[:slug], "weight" => self.class.primary_role },
      { "slug" => light[:slug], "weight" => self.class.light_role }
    ]
  end

  # The auditable selection detail behind #reviewers (see .explain) — string-keyed
  # so it serializes straight to JSON. One ranked pass (memoized #ranked), so the
  # rolls reported here are the rolls the light pick was made on.
  def decision
    needs = needed_domains
    primary, light = pair
    {
      "task" => task.try(:slug),
      "shape" => task_shape,
      "repositories" => task_repositories,
      "risk_tags" => task_risk_tags,
      "needed_domains" => needs,
      "standing_primary" => carl_primary? ? STANDING_PRIMARY : nil,
      "excluded_qa_owner" => qa_owner,
      "builder" => builder,
      # THE FACT A CALLER CAN FAIL CLOSED ON. `excluded_builder` was always
      # computed correctly — the 2026-08-13 defect was that it was computed over
      # an EMPTY builder and nothing said so, so an absent fact read exactly like
      # "there is nobody to exclude". These are different answers and the decision
      # now distinguishes them. See #builder_known?.
      "builder_known" => builder_known?,
      "excluded_builder" => builder_excluded? ? builder : nil,
      "builder_candidate" => builder_candidate?,
      # THE AUTHOR SET, beside the singular builder the four keys above describe.
      # `builders` is every soul who worked the task; `excluded_builders` is how
      # many of them the pool could actually drop; `kept_builders` is the residue
      # that MAY be seated on its own diff — a refusal, not a note.
      # `builders_unattributed` names the claiming session the record could not
      # attribute, which is what makes an incomplete set say so.
      "builders" => builders,
      "excluded_builders" => excluded_builders,
      "kept_builders" => kept_builders,
      "builders_unattributed" => builders_unattributed,
      # Entries of an explicit --builder list that named nobody. Non-empty means the
      # caller's stated fact was only partly understood — the CLI refuses on it.
      "builder_override_unresolved" => (@builder_override && !builder_asserted_none? ? override_unresolved : []),
      # Names the RECORD carries that resolve to no soul. Distinct from the key
      # above, which is the CALLER's list. This is what lets a refusal tell "the
      # record says nothing" from "the record says something that is not a soul" —
      # two states that need OPPOSITE fixes (stamp it vs. correct the spelling) and
      # which the CLI reported as one, calling a typo'd built_by "blank".
      "record_unresolved" => record_unresolved,
      # Whether the caller ASSERTED `--builder none`. The audit line needs the
      # assertion itself; inferring it from `builder.empty? && builder_known` was
      # sound only while builder_known? was defined over the singular builder.
      "builder_asserted_none" => builder_asserted_none?,
      "busy" => busy,
      "excluded_busy" => excluded_busy,
      "kept_busy" => kept_busy,
      "candidates" => candidate_slugs,
      "reviewers" => [seat(primary, needs, self.class.primary_role), seat(light, needs, self.class.light_role)],
      "ranked" => ranked.map { |c| ranked_view(c) }
    }
  end

  private

  attr_reader :task, :qa_owner, :busy, :logger, :random

  # The full soul pool. A seam (returns POOL) so tests can shrink it to exercise
  # the too-few-candidates fallback without mutating the frozen constant.
  def pool
    POOL
  end

  # The LIGHT specialist pool — the full pool minus Carl (the standing primary).
  def light_pool
    pool - [STANDING_PRIMARY]
  end

  # True when Carl takes the standing PRIMARY seat. He yields it ONLY to the hard
  # no-self-review rule: he built the task, or a caller named him the qa_owner.
  # (Busy does NOT unseat Carl — the review model spins a FRESH Carl per PR, so
  # "Carl is busy elsewhere" never applies to the primary seat.)
  # Asked over the whole author set: Carl co-authoring a task someone else claimed
  # last is still Carl reviewing his own work, and `!= builder` could not see it.
  def carl_primary?
    STANDING_PRIMARY != qa_owner && !builders.include?(STANDING_PRIMARY)
  end

  # The floor of LIGHT candidates a selection needs: 1 when Carl takes the standing
  # primary seat (only the light is drawn from the pool), 2 when Carl is out (he
  # built it, or is the QA owner) and BOTH seats are domain picks. The builder/busy
  # drops yield rather than fall below this.
  def min_candidates
    carl_primary? ? 1 : 2
  end

  # The chosen [primary, light] candidate pair. In the normal case Carl is the
  # fixed primary and the light is the best-fit specialist; when Carl has yielded
  # (self-review), BOTH seats are the top domain-fit specialists. Memoized so the
  # decision's pair and its ranked view agree.
  def pair
    @pair ||= begin
      lights = ranked
      carl_primary? ? [carl_candidate, lights.first] : lights.first(2)
    end
  end

  # The standing-primary candidate view (Carl). Not part of the light ranking, so
  # it carries a fixed roll of 0.0 — he is chosen deterministically, not rolled.
  def carl_candidate
    build_candidate(STANDING_PRIMARY, roll: 0.0)
  end

  def build_candidate(slug, roll:)
    domains = reviewer_domains(slug)
    { slug: slug, fit: (needed_domains & domains).size, weight: reviewer_weight(slug),
      roll: roll, domains: domains }
  end

  # A STABLE integer seed derived from the task identity AND the two exclusions
  # that set the light pool — the QA owner and the excluded builder. CRC32 of the
  # key gives a fixed 32-bit seed, so any process selecting for the same task over
  # the SAME post-exclusion pool rolls the same tiebreak (the basis for the CLI
  # preview matching the recorded pick). Folding the excluded builder in keeps two
  # passes that exclude DIFFERENT builders from sharing a seed over different pools.
  # A slug-less in-memory stand-in falls back to a constant key (still reproducible).
  # `excluded_builder` is now the comma-joined excluded AUTHOR SET. For the zero- and
  # one-author cases that string is byte-for-byte what the single slug produced, so
  # no existing task's default light pick shifts; a multi-author task excludes a
  # different pool and correctly gets a different seed.
  def seed_for(task, qa_owner, excluded_builder, excluded_busy_list = [])
    key = "#{task.try(:slug)}:#{qa_owner}:#{excluded_builder}"
    # Fold the excluded busy souls in (only when present, so the no-busy seed is
    # byte-for-byte the historical one and the default pick never shifts).
    key += ":#{excluded_busy_list.sort.join(',')}" if excluded_busy_list.any?
    Zlib.crc32(key)
  end

  # The selectable LIGHT pool — the four specialists minus the QA owner (no
  # self-gating), minus the builder (a soul never reviews their own work), minus
  # the busy souls (mid-build / mid-review elsewhere). Each drop yields rather than
  # starve: the builder is kept when removing it would leave too few candidates
  # (#builder_excluded?), and the busy filter keeps the least-bad busy souls back
  # the same way (#excluded_busy).
  def candidate_slugs
    busy_base - excluded_busy
  end

  # The light pool AFTER the QA-owner + builder drops but BEFORE the busy filter —
  # the floor the busy filter protects.
  def busy_base
    return @busy_base if defined?(@busy_base)

    @busy_base = light_pool - [qa_owner] - excluded_builders
  end

  # The busy souls actually removed. Only a busy soul that's a real light candidate
  # (in busy_base) is removable; removing every removable busy soul can starve the
  # pool, so the filter removes the LEAST useful ones first (worst domain fit, then
  # a stable slug order) and STOPS once the remaining candidate count would fall
  # below #min_candidates — keeping the best-fitting (least-bad) busy souls eligible
  # (#kept_busy). Memoized; pure of the tiebreak RNG, so it's safe to compute for
  # the seed.
  def excluded_busy
    return @excluded_busy if defined?(@excluded_busy)

    removable = busy & busy_base
    room = [busy_base.size - min_candidates, 0].max
    drop = [removable.size, room].min
    @excluded_busy = removable.sort_by { |slug| [busy_domain_fit(slug), slug] }.first(drop)
  end

  # Busy souls that WERE candidates but had to stay eligible to keep a formable
  # pair (the keep-rather-than-starve remainder). Empty in the common case.
  def kept_busy
    (busy & busy_base) - excluded_busy
  end

  # A busy soul's domain fit — used only to order which busy souls to drop first
  # (worst fit) when the pool can't afford to exclude them all.
  def busy_domain_fit(slug)
    (needed_domains & reviewer_domains(slug)).size
  end

  # Who built this task: the explicit override, else devops.built_by (stamped from
  # the build-claim actor — works for the CLI's in-memory task built from board
  # JSON), else the actor on the latest `→ building` TaskEvent (persisted tasks
  # only). nil when the builder can't be determined. Memoized (the event lookup
  # can hit the DB).
  #
  # Every source is filtered through Task::SOUL_SLUG, because only a SOUL can be
  # excluded from a soul-keyed pool. Without that filter the TaskEvent fallback
  # returned whatever the actor column held — and a bare `bin/task move <slug>
  # building` writes the SESSION UUID there, which is not a builder anyone can
  # exclude. A bare presence check would then have called the builder "known"
  # while excluding nobody: the same fail-open, one layer down.
  def builder
    return @builder if defined?(@builder)

    @builder =
      if builder_asserted_none?
        nil
      elsif @builder_override
        # An explicit override is AUTHORITATIVE: a caller who names a builder has
        # spoken for the task, so a non-soul override resolves to nobody rather
        # than silently falling through to the record it was meant to correct.
        override_builders.first
      else
        [devops_built_by, building_event_actor].map { |s| s.to_s.strip }.find { |s| soul?(s) }
      end
  end

  # EVERY author, not just the current one — the set the exclusion actually needs.
  #
  # #builder above answers "who is building this", which is a genuinely different
  # question from "who wrote this diff", and conflating them seated an author twice
  # in one day. A session limit kills a builder mid-work, another soul finishes the
  # task, and Task#builder_to_stamp rule 1 RE-POINTS built_by to whoever claimed
  # last: the first author is erased from the only field the pool consults. On
  # 2026-08-30 `bin/reviewer-select agent-flag-silently-drops --no-record` duly
  # seated ALEX as the light on a diff Alex had written every test on, because
  # built_by said "steffon". Only a hand-passed `--busy alex` stopped it, and a
  # hand-pass is not a property.
  #
  # Three sources, unioned so a task stamped before the accumulator existed still
  # yields its authors: devops.built_by (the current builder), devops.builders (the
  # server-owned append-only claim history), and every `→ building` event actor that
  # names a soul AND is a build CLAIM — a rework block lands the task back on
  # `building` too, and that transition's actor is the reviewer who bounced it, so
  # #building_claim_events skips it. The events are the persisted-task self-heal,
  # since the CLI builds an in-memory Task from board JSON and never sees events at
  # all. built_by leads, so #builders.first is #builder in the ordinary
  # single-author case.
  def builders
    return @builders if defined?(@builders)

    @builders =
      if builder_asserted_none?
        []
      elsif @builder_override
        override_builders
      else
        ([devops_built_by] + task_devops_builders + building_event_actors)
          .map { |s| s.to_s.strip }.select { |s| soul?(s) }.uniq
      end
  end

  # The caller's `--builder a,b` — a comma/space list, so naming several authors is
  # a FIRST-CLASS statement of the fact rather than the `--busy` abuse the live
  # incident had to resort to. Non-roster entries drop out; if that empties the
  # list, the builder is unknown and the caller gets the refusal, not a free pass.
  def override_builders
    override_entries.select { |s| soul?(s) }.uniq
  end

  # Entries in an explicit `--builder` list that name NOBODY on the roster. A
  # PARTIAL typo is the dangerous one: `--builder steffon,stefon` resolves to a
  # non-empty set, so the authors read as KNOWN while the soul the caller meant to
  # exclude quietly did not register — criterion 2's fail-open, wearing criterion
  # 1's clothes. The CLI refuses on this rather than dropping it.
  def override_unresolved
    override_entries.reject { |s| soul?(s) }.uniq
  end

  def override_entries
    @override_entries ||= @builder_override.to_s.split(/[,\s]+/).map(&:strip).reject(&:empty?)
  end

  # The claiming session that named nobody while other authors were already on
  # record — "someone else worked this and we cannot say who". Present ⇒ the author
  # set is INCOMPLETE, so #builder_known? is false and the CLI refuses. An explicit
  # override (or `none`) clears it: the caller has stated the fact, which is exactly
  # the escape hatch the fail-closed guard is supposed to have.
  def builders_unattributed
    return nil if builder_asserted_none? || @builder_override
    return nil unless task.respond_to?(:devops_builders_unattributed)

    task.devops_builders_unattributed
  end

  # Names the RECORD carries that resolve to NO soul — a typo'd devops.built_by, or
  # a `→ building` actor holding a session UUID because someone ran `bin/task move`
  # without `--actor`. Sibling of #override_unresolved, which covers the CALLER's
  # list; this one covers the board's.
  #
  # It exists so a refusal can stop saying "devops.built_by is blank" about a field
  # that plainly is not. Those two states need opposite remedies — one wants a
  # stamp, the other wants a correction, and the stamping command would overwrite
  # the evidence of the typo — so a message that conflates them sends the reader to
  # do the wrong thing confidently.
  def record_unresolved
    return [] if builder_asserted_none? || @builder_override

    ([devops_built_by] + task_devops_builders + building_event_actors)
      .map { |s| s.to_s.strip }.reject(&:empty?).reject { |s| soul?(s) }.uniq
  end

  def task_devops_builders
    task.respond_to?(:devops_builders) ? Array(task.devops_builders) : []
  end

  # The caller's explicit "no soul built this task" assertion (`builder: "none"` /
  # `bin/reviewer-select --builder none`). It names nobody, yet it makes the
  # builder KNOWN — an asserted absence is a fact, an unstamped task is not. This
  # is what keeps the fail-closed guard usable instead of routed around.
  def builder_asserted_none?
    @builder_override.to_s.strip.casecmp(NO_BUILDER).zero?
  end

  # Whether WHO BUILT THIS is a settled question. False means the record simply
  # does not say — the state in which a caller must refuse to auto-select rather
  # than roll a reviewer who may be the author.
  # Asked over the SET, and over its completeness. A set of one that is merely the
  # last claimant of several is not a settled answer, and reading it as one is what
  # seated an author: accumulating authors only helps while every claim names a
  # soul, so the claim that named NOBODY has to be able to say so
  # (#builders_unattributed). Both halves must hold — someone is on record, and
  # nobody is missing from it.
  def builder_known?
    return true if builder_asserted_none?

    builders.any? && builders_unattributed.nil?
  end

  # A soul who EXISTS — Task.soul? checks the roster, not merely the shape.
  #
  # This was `slug.to_s.match?(Task::SOUL_SLUG)`: a regex, satisfied by any
  # lowercase word. So `--builder stefon` (one f) was a KNOWN builder that excluded
  # NOBODY — the fail-closed refusal, whose entire job is keeping a soul off the
  # review of their own PR, lifted by a value that identifies no one. Blank failed
  # closed and was safe; a typo failed OPEN and was not. Task.soul_roster keeps its
  # static floor when the DB is unreachable, so this stays true in the degraded mode
  # this class is built for (see the header) without trading fail-closed for
  # fail-open: an unrecognised slug is UNKNOWN, and unknown refuses.
  def soul?(slug)
    Task.soul?(slug)
  end

  # True when the builder is a real selectable LIGHT candidate — present, in the
  # light pool, and not the QA owner (who's already excluded). The PRECONDITION for
  # actually excluding them: only a candidate can be removed. Carl-the-builder is
  # NOT a light candidate (he's the standing primary, who has already yielded the
  # seat via #carl_primary?), a known-but-non-pool builder is NOT a candidate, and
  # the QA owner is already out — so "excluding" any of those removes nobody, and
  # the audit must not report an exclusion. Memoized.
  def builder_candidate?
    return @builder_candidate if defined?(@builder_candidate)

    @builder_candidate = builder.present? && builder_candidates.include?(builder)
  end

  # Every AUTHOR who is a real light candidate — the ones an exclusion can actually
  # remove. Carl (the standing primary, who yields via #carl_primary?), a non-pool
  # soul, and the already-excluded QA owner are not candidates, so "excluding" them
  # removes nobody and the audit must not claim otherwise.
  def builder_candidates
    @builder_candidates ||= builders & (light_pool - [qa_owner])
  end

  # The authors actually removed from the light pool — ALL of them when the pool can
  # afford it, which is the ordinary case.
  #
  # The drop order matters and it is the OPPOSITE of #excluded_busy's. Busy keeps
  # the BEST-fitting soul back, because a busy reviewer is an inconvenience. A kept
  # AUTHOR is a self-review, so when the pool cannot afford to drop them all we keep
  # back the one LEAST likely to win the seat — worst fit — and #kept_builders makes
  # the residue loud enough for `bin/reviewer-select` to refuse on it. Pure of the
  # tiebreak RNG, so it is safe to compute for the seed.
  def excluded_builders
    return @excluded_builders if defined?(@excluded_builders)

    base = light_pool - [qa_owner]
    room = [base.size - min_candidates, 0].max
    drop = [builder_candidates.size, room].min
    @excluded_builders = builder_candidates.sort_by { |slug| [-busy_domain_fit(slug), slug] }.first(drop)
  end

  # Authors who had to stay eligible to keep a formable pair. Empty in every
  # ordinary case; non-empty means the next pick MAY seat an author, which is why
  # the CLI treats it as a refusal rather than a note.
  def kept_builders
    builder_candidates - excluded_builders
  end

  # True only when the builder IS a light candidate (#builder_candidate?) and is
  # actually removed from the pool. False when the builder is unknown, isn't a
  # candidate (Carl, not a specialist, or the QA owner), or when removing it would
  # drop the light count below #min_candidates — then the builder is KEPT and the
  # decision/log flags it. Memoized.
  def builder_excluded?
    return @builder_excluded if defined?(@builder_excluded)

    @builder_excluded = builder.present? && excluded_builders.include?(builder)
  end

  def devops_built_by
    task.respond_to?(:devops_built_by) ? task.devops_built_by.to_s.strip.presence : nil
  end

  # EVERY `→ building` transition that is a BUILD CLAIM, oldest first — the one
  # query both event readers below are views onto.
  #
  # A BLOCK's transition is skipped: Task#block! lands a bounced task back on
  # `building`, so a rework block writes a `→ building` event whose actor is the
  # REVIEWER who sent the work back. Counted as a build claim, that read the
  # reviewer into the author set — after a bounce #builders returned ["shannon",
  # "carl"], excluding the reviewer from the task's own pool and naming him in the
  # audit as an author of a diff he only read. See TaskEvent#block_transition?,
  # which also explains why legacy rows (written before the marker) still count.
  #
  # THE TWO READERS SHARE THIS ON PURPOSE. They were written as two copies of one
  # query, and PR #1214 taught only the plural one to skip a block — so the
  # singular one went on resolving to the reviewer after a bounce for as long as the
  # copies could drift apart. One source means they cannot.
  #
  # Persisted tasks only (the CLI's in-memory stand-in carries no events, which is
  # why the accumulator has to live in devops), and any lookup error degrades to
  # empty so selection never depends on the events being readable.
  def building_claim_events
    return [] unless task.respond_to?(:task_events) && task.try(:persisted?)

    task.task_events.where(to_stage: "building").where.not(actor: [nil, ""])
        .order(:occurred_at, :id).reject(&:block_transition?)
  rescue StandardError
    []
  end

  # The actor on the most recent build CLAIM — the current builder, as #builder
  # reads it. A bounce is not a claim, so it cannot answer this (see above).
  def building_event_actor
    building_claim_events.last&.actor.to_s.strip.presence
  end

  # EVERY soul who claimed the build, oldest first — the same events the singular
  # reader above takes only the last of. A handoff writes a second `→ building`
  # event, so this is where a task built before devops.builders existed still gives
  # up both its authors.
  def building_event_actors
    building_claim_events.map { |e| e.actor.to_s.strip }.uniq
  end

  # The domains this change needs reviewed: its shape's domains, plus any pulled in
  # by its risk tags, plus any from the repos it touches. Empty for an unknown/blank
  # shape with no risk tags or mapped repos — then every specialist scores 0 and the
  # logged random tiebreak decides the light.
  def needed_domains
    (Array(SHAPE_DOMAINS[task_shape]) +
     task_risk_tags.filter_map { |tag| RISK_DOMAINS[tag.to_s] } +
     task_repositories.flat_map { |repo| Array(REPO_DOMAINS[repo.to_s]) }).uniq
  end

  # Task input readers — guarded so an in-memory / non-Task stand-in (the CLI
  # builds one from board JSON) still works.
  def task_shape
    task.respond_to?(:devops_shape) ? task.devops_shape : nil
  end

  def task_risk_tags
    task.respond_to?(:devops_risk_tags) ? Array(task.devops_risk_tags) : []
  end

  def task_repositories
    task.respond_to?(:devops_repositories) ? Array(task.devops_repositories) : []
  end

  # The LIGHT specialists scored + ordered best-first: domain fit (desc), then
  # review_weight (desc), then a per-candidate random roll. The roll is the LOGGED
  # tiebreak. Memoized so the pair and the decision's ranked view share one roll set.
  def ranked
    @ranked ||= begin
      needs = needed_domains
      scored = candidate_slugs.map { |slug| build_candidate(slug, roll: random.rand) }
      ordered = scored.sort_by { |c| [-c[:fit], -c[:weight], c[:roll]] }
      log_tiebreak(needs, ordered)
      ordered
    end
  end

  # A chosen-seat view for #decision: who, at what depth, and which of the needed
  # domains they actually cover.
  def seat(candidate, needs, weight)
    {
      "slug" => candidate[:slug],
      "weight" => weight,
      "domains" => candidate[:domains],
      "matched" => (needs & candidate[:domains]),
      "fit" => candidate[:fit],
      "roll" => candidate[:roll].round(4)
    }
  end

  # A ranked-candidate view for #decision — the per-candidate roll + fit that made
  # the light tiebreak auditable.
  def ranked_view(candidate)
    {
      "slug" => candidate[:slug],
      "fit" => candidate[:fit],
      "weight" => candidate[:weight],
      "roll" => candidate[:roll].round(4)
    }
  end

  def reviewer_domains(slug)
    list = agent_meta(slug)["domains"]
    list.is_a?(Array) && list.any? ? list.map(&:to_s) : Array(DEFAULT_DOMAINS[slug])
  end

  # Numeric review weight for a slug. Understands the seeded "heavy"/"light" LABELS
  # (via WEIGHT_LABELS — so the label isn't silently zeroed by String#to_f), a
  # Numeric or numeric String (its own value), and a missing/unknown value (the
  # neutral default — never 0.0, which would sink a specialist below every
  # default-weighted peer).
  def reviewer_weight(slug)
    raw = agent_meta(slug)["review_weight"]
    case raw
    when nil     then DEFAULT_REVIEW_WEIGHT
    when Numeric then raw.to_f
    else
      label = raw.to_s.strip.downcase
      # Only a FULLY numeric string is read as its value — a stray "12abc" must NOT
      # slip through as 12.0 (String#to_f would truncate it silently); it falls back
      # to the neutral default like any unknown label.
      WEIGHT_LABELS.fetch(label) { label.match?(/\A[-+]?\d+(?:\.\d+)?\z/) ? label.to_f : DEFAULT_REVIEW_WEIGHT }
    end
  end

  # Agent.metadata for a slug (memoized). A missing row / any lookup error degrades
  # to {} so selection never depends on the souls being seeded.
  def agent_meta(slug)
    (@agent_meta ||= {})[slug] ||= (Agent.find_by(slug: slug)&.metadata || {})
  rescue StandardError
    {}
  end

  # Emit the auditable tiebreak trail — the standing primary, the LIGHT rolls + the
  # resulting ranking, and the chosen pair — so review spread is reviewable after
  # the fact. `chosen` is computed inline from `ordered` (never via #pair) to avoid
  # re-entering #ranked while it memoizes.
  def log_tiebreak(needs, ordered)
    chosen = carl_primary? ? [STANDING_PRIMARY, ordered.first&.dig(:slug)] : ordered.first(2).map { |c| c[:slug] }
    logger.info(
      "[reviewer-selector] task=#{task.try(:slug)} needs=#{needs.join('/').presence || '-'} " \
      "primary=#{carl_primary? ? STANDING_PRIMARY : "#{ordered.first&.dig(:slug)}(yield)"} " \
      "excluded=#{qa_owner} builder=#{builder_log_token} busy=#{busy_log_token} " \
      "rolls=#{ordered.map { |c| "#{c[:slug]}:#{c[:roll].round(4)}" }.join(',')} " \
      "ranked=#{ordered.map { |c| "#{c[:slug]}(fit#{c[:fit]},w#{c[:weight]})" }.join('>')} " \
      "chosen=#{chosen.compact.join('+')}"
    )
  end

  # The builder, annotated for the audit log: "UNKNOWN(no-exclusion)" when the
  # record doesn't say, "none(asserted)" when a caller stated no soul built it,
  # "<slug>(excluded)" when removed from the light pool, "<slug>(kept:too-few)"
  # when a specialist builder is kept because excluding it would leave too few
  # candidates, or "<slug>(not-a-candidate)" when a known builder isn't a light
  # candidate (Carl, a non-pool soul, or the QA owner) — nothing to exclude.
  #
  # The unknown token used to be a bare "-", which is why nobody caught it live:
  # a DISABLED safety check has to read as disabled, not as a tidy empty field.
  def builder_log_token
    return "none(asserted)" if builder_asserted_none?
    return "UNKNOWN(unattributed:#{builders_unattributed})" if builders_unattributed
    return "UNKNOWN(no-exclusion)" if builders.empty?

    builders.map do |soul|
      next "#{soul}(not-a-candidate)" unless builder_candidates.include?(soul)

      "#{soul}(#{excluded_builders.include?(soul) ? 'excluded' : 'KEPT:too-few'})"
    end.join(",")
  end

  # The busy souls, annotated for the audit log: "-" when none were passed, else the
  # excluded ones, with any kept-back (starve-guard) souls flagged "(kept)".
  def busy_log_token
    return "-" if busy.empty?

    (excluded_busy + kept_busy.map { |s| "#{s}(kept)" }).join(",").presence || "-"
  end
end
