# frozen_string_literal: true

require "test_helper"

# GUARD (hub-doc-cites-gap, 2026-09-06): no active hub doc may assert that
# `turf-vault/docs/CURRENT_DEPLOYMENT.md` has no mainnet signer or
# upgrade-authority record.
#
# WHAT HAPPENED. That file's `## Mainnet` table genuinely carried only a program
# ID, version, IDL hash and consumer app, so four hub docs said so and routed the
# reader to `turf-vault/scripts/squad.json` instead. turf-vault PR #12 (`f9554d48`,
# 2026-09-05) added the upgrade-authority, threshold and three signer rows, and all
# four hub sentences became false in one merge, in a repo that cannot see the merge:
#
#   docs/agents/system/app-templates.md      — "`## Mainnet` table carries no signer row"
#   docs/agents/system/credentials.md        — "its `## Mainnet` table has none"
#   docs/agents/system/house-burn-down.md    — "records signers only under `## Devnet`"
#   docs/agents/system/secrets-rotation.md   — "records signers only under `## Devnet`"
#
# WHY IT WAS NEARLY MISSED TWICE, and the reason this guard exists at all. AN
# ADDRESS GREP CANNOT FIND ANY OF THEM. Every one asserts an ABSENCE, so none
# contains either vault address, either program ID, or any signer pubkey — the
# values a sweep for stale on-chain facts searches for. The builder sweep missed
# all four; the reviewer's first pass nearly did, having truncated its own search
# with `head -20`. The searchable thing is the CLAIM, not the value, so that is
# what this file matches.
#
# THE PROPERTY, not the four removed spellings. Enumerating the sentences already
# deleted is a ratchet with no teeth: it can only ever catch prose nobody is going
# to write again. So the check is a proximity property — a mention of the FILE (or
# of its `## Mainnet` table) sitting near a DENIAL near a SIGNER/AUTHORITY noun,
# scanned WHOLE-FILE rather than line by line. Line-scoped reads are the specific
# hole that let app-templates.md through a previous sweep: its claim breaks across
# a newline ("…and its\n`## Mainnet` table carries no signer row…"), so no
# single-line pattern could ever span it.
#
# WHAT IS DELIBERATELY NOT FLAGGED:
#   · PAST-TENSE history. "it was the in-repo mainnet record back when only the
#     devnet table carried signers" is true and worth keeping — squad.json is
#     provenance now, and the docs say so. Only present-tense denial is a defect.
#   · squad.json as a SCRIPT INPUT. `initialize-mainnet.js` really does build its
#     `initialize` signer array from `members`, and `squad-upgrade.js` really does
#     take its cluster from that file. Citing it for what a script will DO is
#     correct; citing it for what is DEPLOYED is the thing this guard stops.
#   · `turf-vault/docs/KEY_ROTATION.md`, which says the same thing and is
#     banner-marked HISTORICAL at its line 3. It is a frozen plan in another repo.
#   · Frozen records under docs/agents/audits/** and any /archive path — they are
#     snapshots of what was true on their date.
#   · test/, so the guard cannot trip on its own fixtures below.
class VaultSignerRecordDocsTest < ActiveSupport::TestCase
  # The thing a false claim is made ABOUT. "that file" is included because
  # credentials.md made its denial that way — the filename sat in the previous
  # sentence and a filename-only pattern read straight past the denial itself.
  SUBJECT = /
    CURRENT_DEPLOYMENT(?:\.md)?
    | [`*]{0,2}\#\#\s*Mainnet[`*]{0,2}\s+table
    | \bthat\s+file\b
  /xi

  # The claim is only a defect when it is about the mainnet half. Devnet prose
  # ("signers sit under `## Devnet`") is a true statement of where a row lives.
  MAINNET = /\bmainnet\b|\#\#\s*Mainnet/i

  # The noun the absence is asserted about. Without this, any negation anywhere
  # near a filename would trip.
  OBJECT = /\bsigners?\b|\bupgrade[-\s]authorit(?:y|ies)\b|\bVaultState\b|\bmultisig\b|\bthreshold\b/i

  # Present-tense denials of a record. Each is a SHAPE the claim can take, not a
  # sentence that was once written: "the table has none", "it does not record
  # them", "it is not a source", "it lacks them", "signers only under `## Devnet`"
  # (denial by exclusion — the form three of the four sites actually used).
  DENIALS = [
    [/\b(?:has|have|carries|carry|contains?|records?|lists?|shows?|holds?|gives?)\s+(?:no|none|nothing)\b/i,
     "denies the row outright"],
    [/\b(?:does|do|did)\s+not\s+(?:record|carry|list|contain|have|show|give|name)\b/i,
     "denies that the file records it"],
    [/\b(?:is|are|was|were)\s+\*{0,2}not\*{0,2}\s+(?:a\s+)?(?:source|record|authority)\b/i,
     "denies the file is a source"],
    [/\block(?:s)?\b|\black(?:s|ing)?\b|\bomits?\b|\bmisses\b|\bmissing\b|\babsent\b|\bsilent\s+on\b|\bnowhere\b/i,
     "asserts the record is missing"],
    [/\b(?:signer|signers|them|these|they)\b[^.]{0,40}\bonly\s+under\b/i,
     "denies by exclusion (only under one heading)"],
    [/\bonly\s+under\s+[`*]{0,2}\#\#\s*Devnet/i,
     "denies by exclusion (only under `## Devnet`)"],
    [/\bno\s+(?:signer|upgrade[-\s]authority|mainnet)[\w-]*\s+(?:row|rows|record|records|entry|entries|line|lines|set)\b/i,
     "names the absent row"],
    [/\bnot\s+(?:recorded|listed|present|there|in\s+that\s+file)\b/i,
     "denies the record's presence"],
    [/\bwrong\s+citation\b/i,
     "sends the reader elsewhere for the record"]
  ].freeze

  # How far from the SUBJECT a denial still counts as being about it. Wide enough
  # to cross a sentence boundary (credentials.md put the filename one sentence
  # before its "has none"), narrow enough that an unrelated negation later in the
  # paragraph does not get attributed to it. Tuned against the live tree: at this
  # width the whole repo is clean and every fixture below still bites.
  WINDOW = 240

  # Live prose an agent may act on. Docs and config carry the citations; the code
  # trees carry them too — `db/migrate/20260905040000_drop_users_solana_address.rb`
  # cites this exact file in a comment, and a comment is what the next reader reads.
  DOC_ROOTS = %w[docs].freeze
  CODE_ROOTS = %w[app bin lib config db].freeze

  def guarded_sources
    docs = DOC_ROOTS.flat_map { |d| Dir.glob(Rails.root.join(d, "**", "*.md")) }
    code = CODE_ROOTS.flat_map do |dir|
      %w[*.rb *.erb *.yml *.md].flat_map { |ext| Dir.glob(Rails.root.join(dir, "**", ext)) }
    end

    (docs + code).uniq.reject do |path|
      path.include?("/archive") || path.include?("/audits/") ||
        path.include?("/node_modules/") || path.start_with?(Rails.root.join("test").to_s)
    end
  end

  def line_of(text, offset)
    text[0, offset].count("\n") + 1
  end

  # Whole-file scan. For every mention of the subject, read the surrounding window
  # and report it when that window denies a mainnet signer/authority record.
  # Returns [line_no, why, excerpt].
  def absence_claims(text)
    text.to_enum(:scan, SUBJECT).filter_map do
      match = Regexp.last_match
      from = [match.begin(0) - WINDOW, 0].max
      window = text[from...(match.end(0) + WINDOW)].to_s
      next unless window.match?(MAINNET) && window.match?(OBJECT)

      hit = DENIALS.find { |pattern, _| window.match?(pattern) }
      next unless hit

      denial = window[hit[0]]
      [line_of(text, match.begin(0)), hit[1], "#{match[0].strip} … #{denial.gsub(/\s+/, ' ').strip}"]
    end
  end

  # ── The live tree ─────────────────────────────────────────────────────────
  def test_no_active_doc_denies_the_mainnet_signer_record
    offenders = guarded_sources.flat_map do |path|
      absence_claims(File.read(path)).map do |line, why, excerpt|
        "#{path.sub("#{Rails.root}/", '')}:#{line} — #{why}: #{excerpt}"
      end
    end

    assert_empty offenders, <<~MSG
      A doc claims turf-vault/docs/CURRENT_DEPLOYMENT.md has no mainnet signer or
      upgrade-authority record. Its `## Mainnet` table has carried the upgrade
      authority, the threshold and all three signer rows since turf-vault PR #12
      (f9554d48, 2026-09-05). Cite the file and name the cluster heading; keep
      turf-vault/scripts/squad.json as provenance and as a script input, not as
      the place to look up what is deployed.

      #{offenders.join("\n")}
    MSG
  end

  # A reader sent to one cluster heading of that file must be told the other one
  # exists. This is the structural half of the fix: the four defects all pointed at
  # `## Devnet` alone, which is how "signers live under Devnet" slid into "signers
  # live ONLY under Devnet". Naming both headings makes the exclusion unwritable.
  def test_citing_one_cluster_heading_names_the_other
    offenders = guarded_sources.reject { |path| File.read(path).empty? }.filter_map do |path|
      text = File.read(path)
      next unless text.include?("CURRENT_DEPLOYMENT")
      next unless text.match?(/\#\#\s*Devnet/)
      next if text.match?(/\#\#\s*Mainnet/)

      "#{path.sub("#{Rails.root}/", '')} — cites CURRENT_DEPLOYMENT.md and `## Devnet`, never `## Mainnet`"
    end

    assert_empty offenders, <<~MSG
      A doc points the reader at CURRENT_DEPLOYMENT.md's `## Devnet` heading without
      ever naming `## Mainnet`. Both tables carry a signer set; naming one heading
      alone is how a reader concludes the other has none.

      #{offenders.join("\n")}
    MSG
  end

  # ── The checker itself bites ──────────────────────────────────────────────
  #
  # Every fixture below is a VERBATIM sentence from one of the four sites as it
  # stood before this task, so the guard is pinned against the real defect rather
  # than against a phrasing invented to match the regex. The multi-line one is
  # app-templates.md's, kept broken across lines exactly where it broke — that is
  # the case a line-scoped guard cannot see.
  REGRESSIONS = {
    "app-templates (claim spans a newline)" =>
      "`turf-vault/docs/CURRENT_DEPLOYMENT.md` is\nthe wrong citation: its signer rows sit only " \
      "under `## Devnet`, and its\n`## Mainnet` table carries no signer row and no " \
      "upgrade-authority row at all.",
    "credentials (denial one sentence after the filename)" =>
      "Current program IDs (both clusters) live in `turf-vault/docs/CURRENT_DEPLOYMENT.md`. " \
      "**That file is not a source for the mainnet signer set** — its signer rows sit only " \
      "under `## Devnet` and its `## Mainnet` table has none.",
    "house-burn-down (denial by exclusion)" =>
      "They are **not** a source for the mainnet `VaultState` signer set — " \
      "`CURRENT_DEPLOYMENT.md` records signers only under `## Devnet`; read the live set on-chain.",
    "secrets-rotation (denial by exclusion)" =>
      "`turf-vault/docs/CURRENT_DEPLOYMENT.md` gives the program ID for each cluster but " \
      "records signers only under `## Devnet`; the mainnet set is recorded in " \
      "`turf-vault/scripts/squad.json`.",
    "an unwritten rephrasing the ratchet would miss" =>
      "`CURRENT_DEPLOYMENT.md` lists the mainnet program ID, but its `## Mainnet` table " \
      "still lacks the upgrade authority and the signer set.",
    "the same claim in a code comment" =>
      "# CURRENT_DEPLOYMENT.md does not record the mainnet signers; read squad.json instead."
  }.freeze

  def test_the_checker_catches_every_original_phrasing
    REGRESSIONS.each do |label, prose|
      assert_not_empty absence_claims(prose),
                       "#{label}: this is the defect the guard exists for and it read as clean"
    end
  end

  # The other half of a guard that means anything: correct prose must pass. A
  # guard that cries wolf on the fix gets muted, and then it protects nothing.
  # These are the live sentences this task wrote, plus the legitimate mentions of
  # squad.json that must survive.
  ACCEPTED = {
    "the corrected house-burn-down sentence" =>
      "`CURRENT_DEPLOYMENT.md` records the upgrade authority, threshold and `VaultState` " \
      "signer set per cluster, under `## Devnet` and `## Mainnet` — **read the heading you " \
      "mean**. The two signer sets are identical today, but nothing in the program keeps " \
      "them that way: `update_signers` can move one without the other.",
    "squad.json as history, stated in the past tense" =>
      "`turf-vault/scripts/squad.json` is provenance, not the citation: it was the in-repo " \
      "mainnet record back when only the devnet table carried signers.",
    "squad.json as a script input" =>
      "`scripts/initialize-mainnet.js` builds `signers` from its `members`, and " \
      "`scripts/squad-upgrade.js` takes its cluster from that file's top-level `network`.",
    "a true statement about the devnet table alone" =>
      "The devnet signer rows sit under `## Devnet` in `CURRENT_DEPLOYMENT.md`."
  }.freeze

  def test_the_checker_passes_correct_prose
    ACCEPTED.each do |label, prose|
      assert_empty absence_claims(prose),
                   "#{label}: correct prose was flagged — a guard that cries wolf gets muted"
    end
  end
end
