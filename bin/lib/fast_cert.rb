# frozen_string_literal: true

require "yaml"

# bin/lib/fast_cert.rb — test SELECTION for the G1 fast cert (bin/fast-check).
#
# The 90/10 rethink of local certification: GitHub CI already runs the FULL
# suite (+ test:system) on every PR push, and bin/dor-check blocks on CI green —
# so a ~6-minute local `bin/rails test` before handoff bought EARLINESS, not
# coverage. The fast cert keeps the earliness (catch the obvious break in ~1
# minute, before the commit/push round-trip) and leans on CI as the full net.
#
# This module is the PURE selection half — mapping a branch diff to the test
# files worth running — so it unit-tests directly (require it, call functions)
# without spawning the runner. bin/fast-check owns orchestration: lanes, gate
# emits, fingerprint-bound evidence.
#
# Selection = union of three sets:
#   1. CONVENTION — each changed file maps to its test by path convention
#      (app/models/x.rb → test/models/x_test.rb, views → their controller test,
#      bin/tool → test/lib/tool_test.rb, a changed *_test.rb includes itself).
#   2. GREP FALLBACK — a changed .rb file with NO existing convention target
#      falls back to a word-boundary grep of its class name (or a bin script's
#      name, or a config file's basename) across test/**/*_test.rb.
#   3. SPINE — config/fast_cert_spine.yml, a curated always-run core (critical
#      model/flow tests, ~10-15s) so a diff that maps to nothing still exercises
#      the money paths. Entries may be files or directories; missing paths are
#      skipped (a satellite worktree runs the hub's script but not its spine).
module FastCert
  # app/<layer>/<rest>.rb → test/<layer>/<rest>_test.rb for these layers
  # (nested paths carry through: app/controllers/api/v1/x_controller.rb →
  # test/controllers/api/v1/x_controller_test.rb).
  APP_LAYERS = %w[models controllers helpers jobs mailers services channels commands].freeze

  module_function

  # --- changed-file collection (mirrors bin/dor-check's changed_files) --------
  # Union of the three base-independent working-tree views (staged, unstaged,
  # untracked) + the committed diff against the release-aware base — so the
  # selection is the same whether the cert runs pre- or post-commit.
  def changed_files(root, base)
    files = []
    [
      %w[diff --cached --name-only],
      %w[diff --name-only],
      %w[ls-files --others --exclude-standard]
    ].each do |args|
      files.concat(capture(["git", "-C", root.to_s, *args]).split("\n"))
    end
    committed = capture(["git", "-C", root.to_s, "diff", "--name-only", "#{base}...HEAD"])
    files.concat(committed.split("\n"))
    files.map(&:strip).reject(&:empty?).uniq
  end

  # origin/accepted when it exists (post-v2 branches are cut off `accepted`), else
  # origin/release, else origin/main — same three-tier default as bin/dor-check.
  def default_diff_base(root)
    %w[origin/accepted origin/release].each do |ref|
      ok = system("git", "-C", root.to_s, "rev-parse", "--verify", ref,
                  out: File::NULL, err: File::NULL)
      return ref if ok
    end
    "origin/main"
  rescue SystemCallError
    "origin/main"
  end

  # --- convention mapping ------------------------------------------------------
  # One changed path → its candidate test paths (existence NOT checked here; the
  # caller filters against the repo). Unmappable paths (docs, assets, db/) return
  # [] and rely on the grep fallback + spine.
  def convention_candidates(path)
    return [path] if path.match?(%r{\Atest/.+_test\.rb\z})

    case path
    when %r{\Aapp/views/(.+)/[^/]+\z}
      # A view/partial exercises through its controller (or mailer) test:
      # app/views/tasks/_gates.html.erb → test/controllers/tasks_controller_test.rb;
      # app/views/task_mailer/ping.html.erb → test/mailers/task_mailer_test.rb.
      dir = Regexp.last_match(1)
      ["test/controllers/#{dir}_controller_test.rb", "test/mailers/#{dir}_test.rb"]
    when %r{\Aapp/(#{APP_LAYERS.join("|")})/(.+)\.rb\z}
      ["test/#{Regexp.last_match(1)}/#{Regexp.last_match(2)}_test.rb"]
    when %r{\A(?:bin/)?lib/(.+)\.rb\z}
      # lib/foo.rb AND bin/lib/foo.rb → test/lib/foo_test.rb.
      ["test/lib/#{Regexp.last_match(1)}_test.rb"]
    when %r{\Abin/([^/]+)\z}
      # bin/fast-check → test/lib/fast_check_test.rb (the harness-test seam).
      ["test/lib/#{Regexp.last_match(1).tr('-', '_')}_test.rb"]
    else
      []
    end
  end

  # The word this file's grep fallback hunts for across test/: a class name for
  # a .rb file (gate_run.rb → GateRun), the script name for a bin tool
  # (bin/fast-check → "fast-check", how harness tests reference it), the bare
  # basename for a config file (config/fast_cert_spine.yml → "fast_cert_spine").
  # nil = no fallback for this path (views/docs/assets rely on the spine).
  def grep_token(path)
    case path
    when %r{\Abin/([^/]+)\z} then Regexp.last_match(1)
    when /\.rb\z/ then camelize(File.basename(path, ".rb"))
    when %r{\Aconfig/.+\.ya?ml\z} then File.basename(path).sub(/\.ya?ml\z/, "")
    end
  end

  def camelize(str)
    str.to_s.split(/[_\-]/).map { |part| part.sub(/\A[a-z]/) { |c| c.upcase } }.join
  end

  # Every test file under root whose text mentions `token` as a whole word.
  # Read-in-Ruby (not shell grep) for BSD/GNU portability and determinism.
  def grep_tests(root, token)
    return [] if token.to_s.strip.empty?

    re = /\b#{Regexp.escape(token)}\b/
    Dir.glob("test/**/*_test.rb", base: root.to_s).select do |rel|
      File.read(File.join(root, rel)).match?(re)
    rescue StandardError
      false
    end
  end

  # PER CHANGED FILE, what it maps to: its EXISTING convention targets, or the
  # grep fallback when it has none. Returns { changed_path => [test paths] }.
  #
  # Exposed separately from select_tests because WHICH FILE mapped widely is the
  # only actionable detail when the mapping explodes. A cap that says "48 files,
  # too many" sends the builder looking through their whole diff; one that says
  # "config/initializers/studio.rb alone mapped 44" names the cause, and the cause
  # is almost always a single file whose grep token is too generic to mean
  # anything. Same passes as select_tests did — the union is computed from this,
  # so nothing is read twice.
  def mapping(root, changed)
    Array(changed).to_h do |path|
      existing = convention_candidates(path).select { |t| File.file?(File.join(root, t)) }
      [path, existing.empty? ? grep_tests(root, grep_token(path)) : existing]
    end
  end

  # The diff-mapped test set: the union of the above. Sorted + deduped, paths
  # relative to root.
  def select_tests(root, changed)
    mapping(root, changed).values.flatten.uniq.sort
  end

  # HOW MANY MAPPED TESTS THIS LANE WILL RUN BEFORE IT IS WORTH RUNNING AT ALL.
  #
  # There was no cap, and a fast lane that can silently become a full suite is
  # worse than a slow one: the builder cannot tell which they are in. Observed
  # live on 2026-08-15 — a diff touching config/initializers/studio.rb mapped to
  # 48 test files and bin/fast-check was still running at 39m34s against a lane
  # that g1-cert.md budgets at about one minute. bin/ship runs this by default, so
  # every builder pays it.
  #
  # An initializer has no convention candidate, so it falls through to a
  # word-boundary grep of its camelized name — and "Studio" appears across the
  # whole tree. A grep that matches half the suite has told you nothing about
  # which tests are RELEVANT; it has only told you the token is too generic. Past
  # the cap the honest move is to stop pretending the mapping is a signal, run the
  # spine, and say so loudly.
  #
  # 15 is deliberately low. The lane's value is being predictable, not thorough —
  # bin/full-suite-check is one command away and is the right answer for a diff
  # this broad.
  DEFAULT_MAPPED_CAP = 15

  def mapped_cap
    raw = ENV["FAST_CHECK_MAPPED_CAP"].to_s.strip
    return DEFAULT_MAPPED_CAP if raw.empty?

    n = raw.to_i
    n.positive? ? n : DEFAULT_MAPPED_CAP
  end

  # The cap decision for an already-spine-deduped mapped set.
  #
  # APPLIED AFTER THE SPINE DEDUPE, deliberately: the cap is about how much EXTRA
  # work this lane does, and a mapped test the spine already runs costs nothing.
  # Capping the raw union would trip on diffs whose mapping is entirely redundant.
  #
  # Returns a Hash rather than a bare Boolean because the caller has to explain
  # itself: the cap it applied, how far over, and the file to look at.
  def cap_decision(mapped_only, breakdown, cap: mapped_cap)
    worst = Array(breakdown).max_by { |_path, tests| Array(tests).size }

    {
      capped: mapped_only.size > cap,
      cap: cap,
      count: mapped_only.size,
      worst_path: worst && worst[0],
      worst_count: worst ? Array(worst[1]).size : 0
    }
  end

  # --- the zero-evidence guard ----------------------------------------------------
  #
  # WHAT THIS CERT WILL ACTUALLY EXECUTE, as a set of test PATHS. Both lanes that can
  # run tests are consulted: the mapped lane — EMPTY when the cap above skipped it —
  # and the spine.
  #
  # STATED LIMIT: this counts paths SELECTED, not test cases executed. A selected file
  # that happens to contain no test cases still counts here, because seeing that needs
  # the runner's own output. This guard needs only the selection, which is why it can be
  # decided before a single lane runs.
  def executed_test_paths(mapped_only, spine, cap)
    ran_mapped = cap && cap[:capped] ? [] : Array(mapped_only)
    (ran_mapped + Array(spine)).uniq
  end

  # A CERT THAT EXECUTES ZERO TESTS MUST NOT REPORT GREEN.
  #
  # Live on turf-monster PR #549, 2026-09-05, verbatim from checks_run:
  #
  #   fast cert green: 0 mapped (CAPPED: 26 > 15; spine only) + 0 spine test path(s),
  #   rubocop on 3 changed file(s)
  #
  # Read it slowly. The mapped lane was capped, so it announced a fallback to the spine;
  # the spine then resolved to ZERO paths. Nothing ran. The one executed check was
  # rubocop — a linter, which cannot observe behaviour — and the gate printed "green".
  # Three of five builds that night degraded this way, and every reviewer had to be told
  # by hand to weight CI over the G1 cert. A gate whose verdict needs a verbal caveat is
  # not a gate.
  #
  # WHY THE GUARD IS KEYED ON ZERO EXECUTED TESTS AND NOT ON THE CAP. The cap is one door
  # into this room, not the room. Keyed on the cap, a satellite diff that maps to 26 test
  # files would be refused while a satellite diff that maps to NONE — strictly LESS
  # evidence — would still certify green on rubocop alone. That ordering is incoherent, and
  # the second door is not hypothetical: config/fast_cert_spine.yml is anchored in the hub
  # and NONE of its entries exist in turf-monster or rolio, so on either satellite the spine
  # is always empty and the mapped lane is the only lane that can run a test at all.
  #
  # WHAT IT DELIBERATELY DOES NOT DO: it does not degrade a capped run that still ran a
  # spine. That run executed real tests, and its evidence line already says "0 mapped
  # (CAPPED: ...)" beside a loud MAPPED LANE CAPPED narration — it is a NARROWER cert,
  # honestly labelled, which is what the cap was designed to produce. Refusing it too
  # would degrade builds that legitimately certified.
  #
  # THE CAP ITSELF IS UNTOUCHED. This changes what a capped run REPORTS, never how much it
  # runs — an uncapped mapped lane on a broad diff is the ~31-minute local suite the fast
  # lane exists to avoid.
  #
  # Returns the refusal text (the caller prefixes "fast-check: " and aborts), or nil when
  # at least one test path will run. Mirrors the string-or-nil shape of the script's other
  # preconditions — CertRootGuard.refusal, DeskGuard.refusal, CertTreeGuard.refusal.
  def zero_test_refusal(mapped_only, spine, cap, slug: nil)
    return nil unless executed_test_paths(mapped_only, spine, cap).empty?

    task = slug.to_s.strip.empty? ? "<task>" : slug.to_s.strip
    capped = !!(cap && cap[:capped])
    why =
      if capped
        culprit =
          if cap[:worst_path]
            " (widest: #{cap[:worst_path]} → #{cap[:worst_count]} test file(s))"
          else
            ""
          end
        "the mapped lane was CAPPED — #{cap[:count]} mapped path(s) over the cap of " \
          "#{cap[:cap]}#{culprit} — so it ran nothing"
      else
        "the diff maps to NO test file — no convention target, and no word-boundary grep hit"
      end
    override =
      if capped
        "\n  (or run the mapped lane anyway, deliberately: FAST_CHECK_MAPPED_CAP=#{cap[:count]} " \
          "bin/fast-check #{task} — that is the broad local suite this cap exists to avoid.)"
      else
        ""
      end

    "REFUSING TO CERTIFY — this run would execute ZERO test files, so there is nothing to " \
      "certify. #{why}, and this checkout resolves NO spine entries (the spine list is " \
      "anchored in the hub; a satellite checkout resolves none of it). That leaves rubocop " \
      "as the only lane, and a linter cannot observe behaviour — a green cert here would be " \
      "a verdict on evidence that does not exist. Run the cert that DOES cover this diff:" \
      "\n    bin/full-suite-check #{task}#{override}"
  end

  # --- spine --------------------------------------------------------------------
  # The curated always-run core from config/fast_cert_spine.yml. Entries may be
  # files or directories; only ones that exist under root survive (the hub's
  # spine list silently no-ops in a satellite checkout).
  def spine(root, config_path)
    data = YAML.safe_load(File.read(config_path.to_s)) || {}
    Array(data["spine"]).map(&:to_s).select { |p| File.exist?(File.join(root, p)) }
  rescue Errno::ENOENT, Psych::SyntaxError
    []
  end

  # Mapped tests already covered by a spine entry (exact file, or inside a spine
  # directory) are dropped from the mapped lane so nothing runs twice.
  def covered_by_spine?(test_path, spine_entries)
    Array(spine_entries).any? { |s| test_path == s || test_path.start_with?("#{s}/") }
  end

  # --- rubocop scope --------------------------------------------------------------
  # The changed files rubocop can actually lint: ruby by extension/name, plus bin
  # scripts with a ruby shebang. Deleted files are skipped (nothing to lint).
  RUBY_PATH_RE = /\.(rb|rake|gemspec|ru)\z/
  RUBY_BASENAMES = %w[Gemfile Rakefile config.ru].freeze

  def lintable_files(root, changed)
    Array(changed).select do |path|
      full = File.join(root, path)
      next false unless File.file?(full)
      next true if path.match?(RUBY_PATH_RE) || RUBY_BASENAMES.include?(File.basename(path))

      path.start_with?("bin/") && ruby_shebang?(full)
    end
  end

  def ruby_shebang?(full)
    File.open(full) { |f| f.gets }.to_s.include?("ruby")
  rescue StandardError
    false
  end

  def capture(argv)
    IO.popen(argv, err: File::NULL, &:read).to_s
  rescue SystemCallError
    ""
  end
end
