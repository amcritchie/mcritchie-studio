# frozen_string_literal: true

# bin/lib/full_suite_gate.rb — the fingerprint-bound certification evidence contract.
#
# Shared by the writers and the reader so the format lives in ONE place:
#   * bin/full-suite-check WRITES full-cert evidence (FULL suite + FULL rubocop —
#                          minus the lint lane in a repo declaring `lint_lane: none`,
#                          which it SKIPS rather than fakes; see #required_lanes).
#   * bin/fast-check       WRITES fast-cert evidence (diff-mapped tests + core
#                          spine + rubocop on changed files — the G1 fast cert;
#                          bin/dor-check accepts it only alongside a GREEN GitHub
#                          CI, which runs the full suite as the net).
#   * bin/dor-check        VALIDATES evidence (refuses a stale/partial/lint-red PR).
#
# Why this exists (devops retro, lines 54 + 58): dor-check used to TRUST a
# free-text tier tag ("[unit] ..."), so a build could satisfy a tier by running
# only the FILES it touched. The full suite or rubocop then broke post-merge.
# The fix: a task may not cross to `submitted` until the FULL `bin/rails test`
# and a FULL `bin/rubocop` have gone green against the EXACT code being shipped.
#
# The anti-stale mechanism is a content-addressed FINGERPRINT, not a SHA or a
# free-text tag. We stage the WHOLE working tree — tracked edits AND
# untracked-but-not-ignored files — into a THROWAWAY git index (GIT_INDEX_FILE)
# and hash it with `git write-tree`; a git tree hash is purely content-addressed,
# so committing the same changes produces the SAME hash. (An earlier version used
# `git stash create`, which silently DROPS untracked files — so a change that
# ADDED a file fingerprinted differently before vs after the commit and was
# wrongly read as STALE.) That gives two properties the retro needs:
#   * Freshness — edit ANY tracked OR untracked-not-ignored file after certifying
#     and the fingerprint changes, so the recorded evidence goes STALE and
#     dor-check refuses. You cannot certify a subset and then keep editing.
#   * Checkout-independence — the reviewer/heartbeat checkout at the committed
#     HEAD recomputes the SAME fingerprint the feature agent certified pre-commit,
#     so the evidence (carried on the task's devops.checks_run) validates there
#     too. tmp/ files don't travel between checkouts; a tree hash does.
#
# Evidence is recorded as fingerprint-tagged checks_run lines the runners stamp,
# scoped to the repo whose tree was hashed (`:<repo>`):
#   [full-suite@<fp>:<repo>] bin/rails test (NNN runs, 0 failures) (bin/full-suite-check)
#   [rubocop@<fp>:<repo>]    bin/rubocop (clean)                   (bin/full-suite-check)
#   [fast-cert@<fp>:<repo>]  mapped+spine tests + scoped rubocop   (bin/fast-check)
# dor-check credits a lane only when a line is tagged for it AND the embedded
# fingerprint equals the local recomputed one. Hand-writing a green tag is not
# defended against (honor system — "Trust over guardrails"); the point is to make
# the honest path one command and to CATCH the easy mistake (touched-files subset
# + a stale tag), which a content fingerprint does deterministically.
#
# The evidence LINE FORMAT and the write rule that keeps an author's `--checks`
# update from wiping a cert live in lib/cert_evidence.rb — shared, because the
# board (app/models/task.rb) enforces the same rule server-side and Rails can
# autoload lib/ but not bin/lib/. This module owns the parts that need git and a
# working tree: the fingerprint, the freshness grading, the bypass record.
require "tmpdir"
require "yaml"
require_relative "../../lib/cert_evidence"

module FullSuiteGate
  TEST_LANE = CertEvidence::TEST_LANE
  RUBOCOP_LANE = CertEvidence::RUBOCOP_LANE
  FAST_LANE = CertEvidence::FAST_LANE
  # The DEFERRAL receipt lane — bin/fast-check's record that no local lane could
  # certify this tree (a capped mapped lane over an empty spine), so the evidence
  # is CI's. Graded here like any other lane; the pairing rule that makes it mean
  # anything (a GREEN CI, never a provisional one) is dor-check's, exactly as the
  # fast lane's pairing is.
  DEFER_LANE = CertEvidence::DEFER_LANE
  BYPASS_TAG = "full-suite-bypass"
  # The FULL-cert lanes — what evaluate's `ok` means (full suite + full rubocop
  # both fresh). The fast lane is deliberately NOT part of `ok`: fast-cert
  # evidence only satisfies the merge gate when dor-check ALSO sees a green
  # GitHub CI, and that pairing is dor-check's call, not this module's.
  LANES = CertEvidence::LANES
  # Every fingerprint-bound evidence lane (for merge/replace + grading).
  EVIDENCE_LANES = CertEvidence::EVIDENCE_LANES
  EVIDENCE_RE = CertEvidence::EVIDENCE_RE

  # --- fingerprint PROVENANCE ------------------------------------------------
  # A fingerprint without provenance is a number nobody can check. Every verdict
  # therefore carries WHAT was hashed to produce it, in two flavours:
  #
  #   WORKING_TREE — the as-if-committed tree of a directory. fingerprint_root is
  #                  that absolute PATH. Recompute: FullSuiteGate.fingerprint(path).
  #   BRANCH_TREE  — a COMMITTED git ref's tree (the review gate-zero, and the
  #                  builder's reclaimed-worktree remedy). fingerprint_root is the
  #                  REF EXPRESSION (e.g. "origin/feat/x^{tree}"), resolved inside
  #                  fingerprint_repo. Recompute:
  #                  git -C <fingerprint_repo> rev-parse <fingerprint_root>.
  #
  # This exists because the announcement used to name the caller's `root` no matter
  # which of the two produced the hash — so in the review lane (where the override
  # is ALWAYS on) it printed the reviewer's primary checkout beside a hash taken
  # from the branch tree, and recomputing the named root gave a THIRD number. A
  # confident, wrong log line is worse than the opaque STALE it replaced. The rule
  # is now structural: the fingerprint and its origin leave this module TOGETHER.
  WORKING_TREE_SOURCE = "working-tree"
  BRANCH_TREE_SOURCE = "branch-tree"

  module_function

  # Content-addressed fingerprint of the CURRENT code — tracked edits AND
  # untracked-but-not-ignored files — stable across the pre-commit→commit
  # boundary. Returns a git tree hash, or nil when git can't read the tree (no
  # repo / missing identity) — the caller treats nil as "unverifiable" and
  # refuses, since this gate's job is to refuse what it cannot confirm. `root` is
  # the repo dir (overridable in tests).
  #
  # Implementation: stage everything into a THROWAWAY index (GIT_INDEX_FILE, never
  # the real one) with `git add -A` — which honours .gitignore and DOES include
  # new files — then `git write-tree`. This is "the tree you'd get by committing
  # the whole working state", so it stays stable when an added file is later
  # committed (`git stash create` dropped untracked files and broke that).
  def fingerprint(root)
    index = File.join(Dir.tmpdir, "fsg-index-#{Process.pid}-#{rand(1 << 32)}")
    env = { "GIT_INDEX_FILE" => index }
    return nil unless run(["git", "-C", root.to_s, "add", "-A"], env: env)

    tree = capture(["git", "-C", root.to_s, "write-tree"], env: env).strip
    tree.empty? ? nil : tree
  ensure
    File.delete(index) if index && File.exist?(index)
  end

  # Tree hash of a COMMITTED git ref (e.g. origin/feat/<slug>) within `root`, or
  # nil when the ref can't be resolved (unfetched branch / bad ref). A git tree
  # hash is purely content-addressed, so a branch's committed `^{tree}` equals the
  # working-tree fingerprint the builder certified before committing + pushing
  # (commit → cert is stable across the boundary — the whole anti-stale design).
  # That lets the REVIEW gate-zero grade the builder's cert from a checkout that
  # ISN'T on the branch — the primary checkout the reviewer runs from is on
  # release/main, so `fingerprint(root)` there reads a DIFFERENT tree and the cert
  # false-reads STALE; this reads the branch tree instead. `--verify --quiet`
  # emits nothing on stdout and exits non-zero on a bad ref, so capture → "".
  def fingerprint_of_ref(root, ref)
    return nil if ref.to_s.strip.empty?

    tree = capture(["git", "-C", root.to_s, "rev-parse", "--verify", "--quiet", ref_expression(ref)]).strip
    tree.empty? ? nil : tree
  end

  # The exact ref expression fingerprint_of_ref resolves — the string an agent can
  # paste into `git -C <repo> rev-parse …` and get the SAME hash back. One
  # definition, so what we ANNOUNCE and what we HASH cannot drift apart.
  def ref_expression(ref)
    "#{ref}^{tree}"
  end

  # Try each ref in order and return the fingerprint of the first that resolves,
  # WITH the ref that produced it: { fingerprint:, ref:, root: } — or nil when none
  # resolve. The hash and its provenance are yielded by ONE call, so a caller cannot
  # hold a fingerprint from ref A while reporting ref B (or, as the bug went, while
  # reporting a filesystem root that was never hashed at all).
  def fingerprint_of_first_ref(root, *refs)
    refs.flatten.compact.each do |ref|
      fp = fingerprint_of_ref(root, ref)
      return { fingerprint: fp, ref: ref_expression(ref), root: root.to_s } if fp
    end
    nil
  end

  # --- the evidence-namespace contract (lib/cert_evidence.rb) ---------------
  # Delegated, not re-implemented: the board enforces the same rule on every
  # write, so the format has exactly one definition.

  # The checks_run line a passing lane records, embedding the fingerprint and the
  # repo whose tree was hashed (nil → the unscoped legacy line).
  def evidence_line(lane, fingerprint, detail, repo: nil)
    CertEvidence.evidence_line(lane, fingerprint, detail, repo: repo)
  end

  # Pattern for a recorded evidence line of the given lanes (e.g.
  # "[full-suite@..]" / "[rubocop@..]" / "[fast-cert@..]"), at the start of a
  # checks_run line.
  def evidence_re(lanes)
    CertEvidence.evidence_re(lanes)
  end

  # Freshness of one lane against `fingerprint`: :fresh (a tag matches the current
  # fingerprint), :stale (tagged, but every tag is for a different fingerprint),
  # or :missing (no tag for this lane at all).
  # `repo` narrows the read to the evidence that answers for ONE repo: lines scoped
  # to it, plus the unscoped legacy lines (which answer for any repo — see
  # CertEvidence#scoped_to?). Without it, a two-repo task graded lane-wide would
  # report the OTHER repo's fingerprint as this one's :stale, which is the same
  # cross-repo confusion in the reader that the single-value slot caused in the
  # writer. nil (the single-repo default) reads every line, unchanged.
  def lane_status(checks, lane, fingerprint, repo: nil)
    seen = Array(checks).each_with_object([]) do |line, values|
      next unless CertEvidence.scoped_to?(line, repo)

      fp = extract_fingerprint(line, lane)
      values << fp if fp
    end
    return :missing if seen.empty?

    seen.include?(fingerprint) ? :fresh : :stale
  end

  # The fingerprint embedded in a "[lane@<fp>] ..." checks_run line, or nil. The
  # @<fp> is what distinguishes this from a plain "[lane]" tier tag, so it never
  # collides with tier_satisfied?.
  def extract_fingerprint(line, lane)
    CertEvidence.extract_fingerprint(line, lane)
  end

  # Every fingerprint RECORDED for `lane` (the "[lane@<fp>]" tags), de-duped, in
  # order. lane_status collapses these to :fresh/:stale/:missing — a verdict, but
  # not an EXPLANATION. "STALE" alone reads as "you edited since certifying" even
  # when the real cause is that the gate is standing in the WRONG TREE, and the two
  # want opposite fixes (re-certify vs. re-root). Surfacing what the evidence was
  # certified FOR lets dor-check print the DELTA — certified @abc, HEAD is now @def
  # — so the cause is legible instead of guessed at.
  def recorded_fingerprints(checks, lane, repo: nil)
    Array(checks).select { |line| CertEvidence.scoped_to?(line, repo) }
                 .filter_map { |line| extract_fingerprint(line, lane) }.uniq
  end

  # A recorded, sanctioned bypass: "[full-suite-bypass] <reason>" with a non-empty
  # reason. Returns the reason string or nil. Like the post_deploy "none" hatch,
  # the bypass is an explicit RECORD (it lives in checks_run, prints loud, shows in
  # the verdict) — not a silent skip and not a forged green.
  def bypass_reason(checks)
    Array(checks).each do |line|
      m = line.to_s.match(/\A\s*\[\s*#{Regexp.escape(BYPASS_TAG)}\s*[\]:]\s*(.+\S)/i)
      return m[1].strip if m
    end
    nil
  end

  # The whole verdict dor-check needs. Order of precedence:
  #   1. a recorded bypass wins (ok, but loudly flagged);
  #   2. an injected status (tests only — DOR_CHECK_SUITE_EVIDENCE) short-circuits
  #      the git+tag work so the gate logic can be exercised without a real run;
  #   3. otherwise recompute the fingerprint and grade every evidence lane.
  # Returns a Hash: { ok:, bypass:, verifiable:, fingerprint:, lanes:, recorded: }.
  # `ok` means the FULL cert is satisfied (LANES fresh). lanes[FAST_LANE] carries
  # the fast-cert lane's freshness so dor-check can pair a fresh fast cert with a
  # green GitHub CI — this module grades evidence; it never reads CI. `recorded`
  # carries each lane's RECORDED fingerprints (what the evidence was certified for)
  # so a STALE verdict can be reported as a delta against `fingerprint` rather than
  # as an opaque label.
  #
  # `fingerprint_override` (the review gate-zero seam): grade against THIS tree
  # hash instead of recomputing `fingerprint(root)`. The reviewer runs from a
  # primary checkout that isn't on the task branch, so the working-tree hash there
  # is the wrong tree — dor-check passes the branch's committed tree (via
  # fingerprint_of_first_ref) so the cert grades against the code the builder
  # certified. nil (the default / a branch that couldn't be resolved) → recompute
  # from root, the builder-side behavior.
  #
  # An override MUST arrive with its `fingerprint_origin` — the { ref:, root: } the
  # hash came from (fingerprint_of_first_ref hands you both). Passing a hash with no
  # provenance raises: the verdict has to be able to say WHAT it hashed, and the one
  # bug this seam has ever had was a fingerprint from the branch tree reported beside
  # the caller's `root`, which was never hashed to produce it. An unattributed
  # override is not a thing this module will grade.
  # `repo` (the bare repo slug the graded TREE belongs to) narrows the evidence read
  # to that repo's certs — see #lane_status. It rides on the verdict as :repo so a
  # caller grading several repos can say WHICH repo each verdict is about; nil keeps
  # the single-repo behavior in every respect.
  def evaluate(checks:, root:, injected: nil, fingerprint_override: nil, fingerprint_origin: nil, repo: nil)
    reason = bypass_reason(checks)
    return verdict(ok: true, bypass: reason, repo: repo) if reason

    return injected_verdict(injected).merge(repo: repo) if injected && !injected.empty?

    fp_root, fp_repo, fp_source = provenance(root, fingerprint_override, fingerprint_origin)
    fp = fingerprint_override || fingerprint(root)
    return verdict(ok: false, verifiable: false, repo: repo) if fp.nil?

    lanes = EVIDENCE_LANES.to_h { |lane| [lane, lane_status(checks, lane, fp, repo: repo)] }
    recorded = EVIDENCE_LANES.to_h { |lane| [lane, recorded_fingerprints(checks, lane, repo: repo)] }
    verdict(ok: required_lanes(repo).all? { |lane| lanes[lane] == :fresh },
            fingerprint: fp, lanes: lanes, recorded: recorded,
            fingerprint_root: fp_root, fingerprint_repo: fp_repo, fingerprint_source: fp_source, repo: repo)
  end

  # The FULL-cert lanes a given repo actually owes.
  #
  # LANES for everything, MINUS the rubocop lane for a repo that DECLARES it has
  # no lint lane (`lint_lane: none` in config/release_repos.yml).
  #
  # WHY THIS EXISTS. studio-engine ships no rubocop at all — not in the Gemfile,
  # not in the gemspec, no .rubocop.yml, and `bundle exec rubocop` fails outright;
  # its static gate is `ruby -c` inside bin/release-check. Before this, a task
  # naming that repo could NEVER be certified: the gate demanded a rubocop cert
  # that no honest command could produce, and the only way through was pointing
  # FULL_SUITE_RUBOCOP_CMD at a no-op, which records a rubocop pass for a lint
  # that never ran. That is manufacturing the exact evidence these gates exist to
  # check, and it was refused (2026-08-24, /tasks/brand-the-current-wallet).
  #
  # DECLARED, NEVER INFERRED — the whole design is in that distinction. This does
  # NOT probe for a rubocop binary, because a waiver inferred from a missing
  # binary turns every broken rubocop install into a silently skipped lane. The
  # waiver must be a reviewable line in a registry a human edits on purpose.
  #
  # Unknown repo, or nil, owes EVERYTHING. Failing closed is the only safe default
  # for a gate: a typo'd repo slug must not waive a lane.
  #
  # SCOPE — this closes the READER half of the bug, and only that half. The cert
  # WRITER (bin/full-suite-check) still runs BOTH lanes unconditionally, and in
  # studio-engine both resolve to commands that repo does not ship: the test lane
  # to `bin/rails` (CiTestCommand::DEFAULT — the engine has engine-ci.yml, not the
  # ci.yml the resolver reads) and the lint lane to `bin/rubocop`. It then dies on
  # an unrescued Errno::ENOENT in bin/lib/cert_process.rb:88 before recording
  # anything, so a task naming the engine still cannot PRODUCE the full-suite line
  # this gate now asks it for. Verified 2026-08-25 reviewing PR #1004; fixing the
  # writer is a separate task. Do not read this waiver as "the engine is now
  # certifiable" — it means "the engine is no longer asked for a lint it cannot run".
  def required_lanes(repo)
    lint_waived?(repo) ? LANES - [RUBOCOP_LANE] : LANES
  end

  def lint_waived?(repo)
    slug = repo.to_s.strip
    return false if slug.empty?

    repo_registry.dig(slug, "lint_lane").to_s == "none"
  end

  # THE TEST LANE, RESOLVED THE SAME WAY THE LINT LANE IS. A gem repo has no
  # ci.yml for CiTestCommand to read (studio-engine ships engine-ci.yml) and no
  # `bin/rails` to reset a test DB with — so an unaided cert crashed on ENOENT
  # long before it reached the lint waiver. The registry already answers this:
  # the row carries `release_check`, the repo's own pre-publish gate.
  #
  # DECLARED, NEVER INFERRED, exactly like the waiver. Nothing here probes for a
  # binary or sniffs for a Gemfile; a repo gets a registry test command because
  # its row names one. An unrecognised slug or unreadable registry returns nil
  # and the caller falls back to CiTestCommand — the behaviour every app has
  # today, unchanged.
  def release_check_cmd(repo)
    slug = repo.to_s.strip
    return nil if slug.empty?

    cmd = repo_registry.dig(slug, "release_check").to_s.strip
    cmd.empty? ? nil : cmd
  end

  # TRUE for a repo the registry files under `gems`. Used only to decide that a
  # Rails test-DB reset is meaningless here — a gem has no test database and no
  # bin/rails to purge one with. Same DECLARED rule: the section in the registry
  # is the statement, not a guess from the tree's shape.
  def gem_repo?(repo)
    slug = repo.to_s.strip
    return false if slug.empty?

    repo_sections[slug] == "gems"
  end

  def repo_sections
    @repo_sections ||= begin
      path = File.expand_path("../../config/release_repos.yml", __dir__)
      cfg = YAML.safe_load_file(path) || {}
      %w[apps gems].each_with_object({}) do |section, out|
        (cfg[section] || {}).each { |slug, row| out[slug] = section if row.is_a?(Hash) }
      end
    rescue StandardError
      {}
    end
  end

  # repo slug => its registry row, flattened across the apps/gems sections. Read
  # once. A registry that cannot be read waives NOTHING — same fail-closed rule.
  def repo_registry
    @repo_registry ||= begin
      path = File.expand_path("../../config/release_repos.yml", __dir__)
      cfg = YAML.safe_load_file(path) || {}
      %w[apps gems].each_with_object({}) do |section, out|
        (cfg[section] || {}).each { |slug, row| out[slug] = row if row.is_a?(Hash) }
      end
    rescue StandardError
      {}
    end
  end

  # Where the graded fingerprint CAME FROM → [fingerprint_root, fingerprint_repo,
  # fingerprint_source]. Override → the ref expression it was resolved from, in the
  # repo it was resolved in. No override → the working tree at `root`, which is both.
  # Refuses an override with no origin rather than guessing one, because guessing is
  # exactly how `root` ended up labelling a hash it never produced.
  def provenance(root, override, origin)
    return [root.to_s, root.to_s, WORKING_TREE_SOURCE] if override.nil?

    origin = { ref: origin } unless origin.is_a?(Hash)
    ref = origin[:ref].to_s.strip
    if ref.empty?
      raise ArgumentError, "fingerprint_override requires fingerprint_origin (the ref it was hashed from) — " \
                           "a fingerprint whose provenance is unknown cannot be honestly announced"
    end

    repo = origin[:root].to_s.strip
    [ref, repo.empty? ? root.to_s : repo, BRANCH_TREE_SOURCE]
  end

  # --- internals -----------------------------------------------------------

  def verdict(ok:, bypass: nil, verifiable: true, fingerprint: nil, lanes: nil, recorded: nil,
              fingerprint_root: nil, fingerprint_repo: nil, fingerprint_source: nil, repo: nil)
    lanes ||= EVIDENCE_LANES.to_h { |lane| [lane, ok ? :fresh : :missing] }
    # The bypass/injected/unverifiable paths never read the checks, so they carry no
    # recorded fingerprints — an EMPTY list per lane, not a missing key, so callers
    # can always index it. dor-check falls back to the plain STALE wording there.
    # They carry no fingerprint either, hence no provenance: nil, never a root we
    # did not hash. "No fingerprint" and "a fingerprint from somewhere" are different
    # claims and the verdict must not blur them.
    recorded ||= EVIDENCE_LANES.to_h { |lane| [lane, []] }
    { ok: ok, bypass: bypass, verifiable: verifiable, fingerprint: fingerprint, lanes: lanes,
      recorded: recorded, fingerprint_root: fingerprint_root, fingerprint_repo: fingerprint_repo,
      fingerprint_source: fingerprint_source, repo: repo }
  end

  # Map a DOR_CHECK_SUITE_EVIDENCE token to a verdict (test seam only). Tokens:
  # ok | missing | stale | tests_stale | rubocop_stale | unverifiable |
  # fast_fresh | fast_stale (fast-cert evidence with NO full-cert evidence) |
  # deferred_fresh | deferred_stale (a DEFERRAL receipt and no cert at all — the
  # capped-diff shape, whose only evidence is the PR's CI).
  def injected_verdict(token)
    case token
    when "ok"            then verdict(ok: true)
    when "unverifiable"  then verdict(ok: false, verifiable: false)
    when "stale"         then verdict(ok: false, lanes: { TEST_LANE => :stale, RUBOCOP_LANE => :stale, FAST_LANE => :missing })
    when "tests_stale"   then verdict(ok: false, lanes: { TEST_LANE => :stale, RUBOCOP_LANE => :fresh, FAST_LANE => :missing })
    when "rubocop_stale" then verdict(ok: false, lanes: { TEST_LANE => :fresh, RUBOCOP_LANE => :stale, FAST_LANE => :missing })
    when "fast_fresh"    then verdict(ok: false, lanes: { TEST_LANE => :missing, RUBOCOP_LANE => :missing, FAST_LANE => :fresh })
    when "fast_stale"    then verdict(ok: false, lanes: { TEST_LANE => :missing, RUBOCOP_LANE => :missing, FAST_LANE => :stale })
    when "deferred_fresh"
      verdict(ok: false, lanes: { TEST_LANE => :missing, RUBOCOP_LANE => :missing,
                                  FAST_LANE => :missing, DEFER_LANE => :fresh })
    when "deferred_stale"
      verdict(ok: false, lanes: { TEST_LANE => :missing, RUBOCOP_LANE => :missing,
                                  FAST_LANE => :missing, DEFER_LANE => :stale })
    else verdict(ok: false) # "missing" and any unknown token → all lanes missing
    end
  end

  def capture(argv, env: {})
    IO.popen([env, *argv], err: File::NULL, &:read).to_s
  rescue SystemCallError
    ""
  end

  # Run a command for its exit status only (stdout/stderr discarded); true on a
  # clean exit. Used to stage into the throwaway index without leaking output.
  def run(argv, env: {})
    system(env, *argv, out: File::NULL, err: File::NULL)
  rescue SystemCallError
    false
  end
end
