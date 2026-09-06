# frozen_string_literal: true

# CertEvidence — the MACHINE-OWNED namespace inside a task's devops.checks_run.
#
# checks_run holds two kinds of line, written by two different hands:
#
#   [unit] bin/rails test test/models/task_test.rb      ← AUTHOR-owned (tier tags,
#   [integration] bin/rails test test/controllers          bypass records, prose)
#   [full-suite-bypass] CI outage, ran locally
#
#   [full-suite@<fp>:<repo>] bin/rails test (782 runs, 0 failures) ← MACHINE-owned
#   [rubocop@<fp>:<repo>]    bin/rubocop (clean)                      CERT EVIDENCE
#   [fast-cert@<fp>:<repo>]  mapped+spine tests + scoped rubocop      (bin/fast-check,
#                                                                bin/full-suite-check)
#
# The `@<fingerprint>` is what separates the two namespaces: a tier tag is a bare
# `[lane]`, evidence is `[lane@<git tree hash>]`. The optional `:<repo>` suffix
# scopes evidence to the repo whose tree was hashed, so a task naming two repos
# holds a cert for EACH (see THE REPO DIMENSION below). bin/dor-check reads ONLY the
# evidence lines to decide whether the code is certified (see
# bin/lib/full_suite_gate.rb for the fingerprint + grading half).
#
# WHY THIS MODULE EXISTS (bug, 2026-07-12 — hit twice in one session, ~8 minutes
# burned each time): `bin/task update <slug> --checks "…"` REPLACED the whole
# checks_run array. An agent that recorded its tier-tagged test plan AFTER
# certifying silently DESTROYED its own cert evidence, and bin/dor-check then
# reported "full-suite: MISSING (never certified for this exact code)" on code
# that WAS just certified — a FALSE NEGATIVE in the G1 cert gate, whose only
# visible remedy was to burn another suite run (or, worse, to hand-write an
# evidence line and forge the cert). The check-writers already protected the
# author's lines ("tier tags preserved"); the author's --checks wiped the
# machine's. This module makes that asymmetry symmetric.
#
# THE WRITE RULE (#preserve) — one sentence: a writer may only supersede a
# NAMESPACE it supplies lines for — each (evidence LANE, REPO) pair is a
# namespace, and the author's lines (tier tags, bypasses, prose) are one
# namespace too. So:
#   * an author `--checks` update (tier tags only, no `[lane@fp]` lines) can
#     never drop a cert — every lane is carried over;
#   * a cert writer that just ran a lane green stamps that lane FOR THE REPO IT
#     CERTIFIED and replaces its own prior line (no stale accumulation), leaving
#     the other lanes — and every OTHER REPO's cert — intact;
#   * a PURE-EVIDENCE write (only `[lane@fp]` lines — what the cert writers send
#     when their own read of checks_run was stale or empty) can never drop the
#     author's tier tags — the author namespace is carried over (reverse
#     regression 2026-07-20: fast-check's read missed freshly recorded tier
#     lines and its evidence write superseded the author namespace with nothing,
#     while claiming "tier tags preserved").
#
# THE REPO DIMENSION (bug, 2026-08-13 — found landing land-rails-security-patch
# across two repos). The namespace used to be the LANE alone, so on a task naming
# TWO repos the second repo's `[full-suite@fpB]` superseded the first's
# `[full-suite@fpA]`: the hub's cert was silently GONE, and dor-check later called
# it STALE — a false-stale on a repo that HAD been certified green, surfacing long
# after the write that destroyed it, with no error at the time. The workaround was
# an invisible ordering rule (certify satellites first, the dor-check root repo
# last). The system was already multi-repo-aware at the PR/coverage layer
# (devops.pr_urls is keyed per repo; Task#pr_bearing_repositories,
# Task#repos_missing_pr_url, Release::SweepPlan) and single-repo-only at the CERT
# layer; that INCONSISTENCY was the bug, so the cert layer was brought up to the
# coverage layer rather than the coverage layer dragged down (an earlier session
# implemented a Task validation FORBIDDING multi-repo tasks and the suite caught
# it immediately: a GEM task legitimately names its CONSUMER repos so the gates
# can reason the gem owes the PR while the consumers do not — the gem-release
# path). The line format carries the scope:
#
#   [full-suite@<fp>]                  ← UNSCOPED: "the one cert slot" (legacy)
#   [full-suite@<fp>:turf-monster]     ← SCOPED to a repo (what writers stamp now)
#
# The repo rides AFTER the fingerprint on purpose. `#extract_fingerprint` already
# terminated the hash on `[\]:]`, so every parser that predates this change reads
# a scoped line as a correct, unscoped `lane`+`fingerprint` — a stale checkout's
# dor-check grades a new cert fine, and neither direction of the rollout produces a
# false STALE. Putting the repo BEFORE the `@` (`[control:moms-app@fp]`) would have
# collided with `tier_satisfied?`, which terminates a tier tag on `[\]:]` too: the
# machine's control STAMP would have silently satisfied the AUTHOR's required
# `[control]` tier tag — a gate satisfying itself.
#
# AN UNSCOPED LINE IS ITS OWN NAMESPACE, never superseded by a scoped write. Its
# repo is unknowable, so retiring it on a scoped write could destroy the OTHER
# repo's cert — precisely the bug above. Preserving it cannot hurt: freshness still
# demands an exact git TREE HASH match, which two different repos' trees cannot
# collide on, so a leftover unscoped line can only fail to match (never falsely
# match). At most one per lane survives — an unscoped write still supersedes the
# unscoped slot — so it is bounded, and READING treats it as answering for any repo
# (a task certified before this landed still grades FRESH).
# Destroying a cert therefore REQUIRES writing a fingerprint-bound line for that
# lane by hand — i.e. deliberately forging a certification, not fat-fingering an
# ordinary `--checks` update. Ordering ("record --checks BEFORE you certify") is
# no longer load-bearing: both orders are safe.
#
# Enforced at BOTH ends, so no caller inherits the old behavior:
#   * bin/task     — build_devops carries evidence forward into the PATCH body
#                    (protects agents immediately, even against an older board).
#   * Task#preserve_cert_evidence — the board funnel every writer passes through
#                    (bin/task, the board UI form, a raw API PATCH, the console).
#
# NOT protected, deliberately: `[full-suite-bypass] <why>` is an AUTHOR record —
# a human's conscious, loud skip. Force-preserving it would make a bypass
# impossible to withdraw, so it stays author-owned and removable.
module CertEvidence
  TEST_LANE = "full-suite"
  RUBOCOP_LANE = "rubocop"
  FAST_LANE = "fast-cert"
  # The `test-only` shape's EXECUTED control (bin/control-check): the pre-change
  # version of the changed test files, replayed against current production code.
  # Fingerprint-bound like the certs, and machine-owned for the same reason —
  # a `[control@<fp>]` stamp an author `--checks` update could wipe would send the
  # builder back to re-run it, which is how the cert-wipe bug of 2026-07-12 taught
  # people to hand-write evidence. NOT a lane the full cert waits on (see LANES).
  CONTROL_LANE = "control"
  # A cert that was DEFERRED to GitHub CI (bin/fast-check, capped mapped lane over
  # an empty spine). NOT a cert and never green on its own: it is the machine's
  # record that NO local lane could certify THIS tree, and that the evidence is
  # therefore the CI run of the commit this tree becomes. bin/dor-check credits it
  # only alongside a GREEN CI — never provisionally, unlike the fast lane, because
  # there is no local run underneath it to be provisional ABOUT.
  #
  # Fingerprint-bound and machine-owned for the same reasons as the lanes above: a
  # receipt an author `--checks` update could wipe would strand the build, and one
  # that survived an edit would defer a tree CI never saw.
  DEFER_LANE = "cert-deferred"
  # The FULL-cert lanes (what "certified" means: full suite + full rubocop, both
  # fresh). The fast lane is separate — it only satisfies the gate paired with a
  # green GitHub CI, which is bin/dor-check's call. The control lane is separate
  # too, and for a sharper reason: it is required only by the shapes whose
  # `required_evidence` asks for it, so folding it in here would silently demand a
  # control of EVERY shape — including the ones that have no test-only diff to
  # replay. Membership of EVIDENCE_LANES buys the namespace protection and the
  # fingerprint grading; membership of LANES would buy a universal requirement.
  LANES = [TEST_LANE, RUBOCOP_LANE].freeze
  # Every fingerprint-bound lane — the whole machine-owned namespace.
  EVIDENCE_LANES = (LANES + [FAST_LANE, CONTROL_LANE, DEFER_LANE]).freeze

  module_function

  # The checks_run line a passing lane records, embedding the fingerprint and — when
  # the writer knows which repo it stood in — the REPO SCOPE.
  #
  # `repo` is the repo the certified TREE belongs to, derived from the root that was
  # actually hashed (CertRootGuard#repo_of_checkout), never from the task record: the rule
  # Task.normalize_devops_map_pair applies to pr_urls, where the key comes from the
  # artifact rather than from what the writer claimed. A blank repo writes the legacy
  # unscoped line, so a caller that cannot name its repo degrades instead of lying.
  def evidence_line(lane, fingerprint, detail, repo: nil)
    scope = repo.to_s.strip
    tag = scope.empty? ? "#{lane}@#{fingerprint}" : "#{lane}@#{fingerprint}:#{scope}"
    "[#{tag}] #{detail}"
  end

  # Pattern for a recorded evidence line of the given lanes, at the start of a
  # checks_run line. The `@` is required — a bare "[unit]" tier tag or a
  # "[full-suite-bypass]" record never matches.
  def evidence_re(lanes)
    /\A\s*\[\s*(?:#{Array(lanes).map { |l| Regexp.escape(l) }.join("|")})\s*@/i
  end

  EVIDENCE_RE = evidence_re(EVIDENCE_LANES)

  # The fingerprint embedded in a "[lane@<fp>] …" line, or nil.
  def extract_fingerprint(line, lane)
    m = line.to_s.match(/\A\s*\[\s*#{Regexp.escape(lane)}\s*@\s*([0-9a-f]{7,64})\s*[\]:]/i)
    m && m[1].downcase
  end

  # The evidence lane a line belongs to ("full-suite" / "rubocop" / "fast-cert"),
  # or nil when the line is author-owned (a tier tag, a bypass, prose).
  #
  # Keyed on the `[lane@` PREFIX — the same predicate EVIDENCE_RE uses — not on a
  # well-formed fingerprint. Membership of the machine-owned namespace is about
  # the SHAPE of the line; whether the embedded fingerprint is a real tree hash
  # that grades :fresh is bin/dor-check's question (#extract_fingerprint, which
  # stays strict). Splitting the two predicates would let a malformed evidence
  # line be neither superseded nor recognized, and it would leave the writers'
  # merge disagreeing with the board's preserve.
  def lane_of(line)
    EVIDENCE_LANES.find { |lane| line.to_s.match?(evidence_re([lane])) }
  end

  # The REPO an evidence line is scoped to ("[lane@<fp>:<repo>]"), or nil for the
  # unscoped legacy form.
  #
  # Lenient in the SAME direction as #lane_of, and for the same reason: membership of
  # a namespace is about the SHAPE of the line, so a scope is read off any
  # "[…@…:<repo>]" even when the fingerprint between them is malformed. Splitting the
  # two leniencies would let a bad line be neither superseded nor recognized.
  def repo_of(line)
    m = line.to_s.match(/\A\s*\[\s*[^\[\]@\s]+\s*@[^\]:]*:\s*([^\]\s]+)\s*\]/)
    m && m[1]
  end

  # The NAMESPACE a line belongs to — [lane, repo] for machine-owned evidence (repo
  # nil on the unscoped legacy form), or nil when the line is author-owned. This is
  # the key #preserve supersedes on.
  def namespace_of(line)
    lane = lane_of(line)
    lane && [lane, repo_of(line)]
  end

  # The namespaces a list of lines carries evidence for.
  def namespaces_addressed(lines)
    Array(lines).filter_map { |line| namespace_of(line) }.uniq
  end

  # Does this line's evidence answer for `repo`? An UNSCOPED line answers for ANY
  # repo — that is what keeps a cert recorded before the repo dimension existed
  # grading FRESH — and so does any line when the reader names no repo. A SCOPED line
  # answers only for its own. Compared on the bare slug, case-insensitively, so an
  # owner-qualified reference ("McRitchie-Studio/turf-monster") still matches the
  # bare slug the repositories list carries.
  def scoped_to?(line, repo)
    scope = repo_of(line)
    return true if scope.nil? || repo.to_s.strip.empty?

    same_repo?(scope, repo)
  end

  # Two repo references naming the same repo, compared on the bare slug.
  def same_repo?(left, right)
    left.to_s.split("/").last.to_s.casecmp?(right.to_s.split("/").last.to_s)
  end

  # THE WRITE RULE. `incoming` is the list the caller wants stored; `prior` is
  # what's stored now. Every evidence line whose NAMESPACE — its (lane, repo) pair —
  # the caller did NOT address is carried over (appended, after the caller's lines —
  # evidence reads last, the order the cert writers already stamp). Certifying
  # turf-monster therefore addresses ("full-suite", "turf-monster") and leaves
  # ("full-suite", "mcritchie-studio") standing; before the repo half of the key
  # existed it addressed "full-suite" and erased it.
  #
  # The AUTHOR namespace obeys the same rule (reverse regression, 2026-07-20 —
  # fast-check-preserves-checks): a PURE-EVIDENCE write — every incoming line a
  # `[lane@fp]` evidence line, which is what bin/fast-check / bin/full-suite-check
  # send when their own read of checks_run came back stale or empty — supplies no
  # author line, so it may not supersede the author namespace: the prior tier
  # tags, bypass records, and prose are carried through, ahead of the evidence.
  # An author write (any non-evidence line present) still REPLACES the author
  # namespace wholesale — the documented `--checks` contract — and an explicitly
  # EMPTY incoming list keeps its meaning as a deliberate author-namespace clear.
  #
  # WHICH NAMESPACE A WRITE BELONGS TO IS INFERRED FROM CONTENT SHAPE, because the
  # wire carries a list of strings and no intent flag (bin/task's `--checks` → the
  # API → this rule). So the protection is exactly as good as the writers' output:
  # a MIXED write (evidence PLUS one unparseable line) counts as an author write
  # and replaces the author namespace with just that line. That is correct for a
  # human `--checks` update carrying a hand-copied evidence line, and it is a
  # FOOTGUN for a cert that ever emits a stray note beside its evidence.
  # The coupling that makes it safe — every production evidence writer emits only
  # #evidence_line output, which #lane_of always parses (it is prefix-keyed, so
  # even a malformed fingerprint still classifies as evidence) — is ASSERTED in
  # test/lib/cert_evidence_test.rb, not merely believed. Giving the write an
  # explicit namespace would need an intent channel threaded through CLI → API →
  # model; worth doing, but it is a contract change rather than this bug's fix.
  def preserve(prior:, incoming:)
    incoming = Array(incoming).map(&:to_s)
    prior = Array(prior).map(&:to_s)
    addressed = namespaces_addressed(incoming)
    carried = prior.select do |line|
      ns = namespace_of(line)
      ns && !addressed.include?(ns)
    end
    if incoming.any? && incoming.all? { |line| lane_of(line) }
      return prior.reject { |line| lane_of(line) } + incoming + carried
    end

    incoming + carried
  end
end
