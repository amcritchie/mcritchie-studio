# frozen_string_literal: true

# [unit] What the G3 pre-QA gate tells an operator when it CANNOT READ GitHub CI.
#
#   ruby -Itest test/lib/release_pre_qa_remedy_test.rb
#
# THE DEFECT (/tasks/release-offers-retired-cert). pre_qa_ci_abort's :unreadable
# branch called CiStatus.unreadable_remedy with NO cert_route:, so it took the
# default — `true` — and ended a RELEASE-grain refusal with "certify in full instead:
# bin/full-suite-check <task>". Two things wrong in one sentence, and only one of them
# was about wording:
#
#   * THE ROUTE IS RETIRED HERE. DevOps v2 Phase 3 DEMOTED the local pre-QA suite:
#     GitHub's verdict for origin/release's tip IS the gate (pre_qa_gate's
#     `ok = ci_pass?(ci)`, and :green is ci_pass?'s only true). bin/release.rb names
#     no certification mechanism anywhere — re-derived at source, and pinned below —
#     so an operator who ran the full suite would spend ~30 minutes and change this
#     verdict by nothing at all.
#   * THE PLACEHOLDER IS UNFILLABLE. `<task>` asks for a task slug; the subject of
#     this gate is a release SHA carrying MANY tasks. There is no value the reader
#     could have typed.
#
# Same family as /tasks/exempt-refusal-prints-dead-remedy (PR #1221): a gate printing
# a remedy it cannot honour. A refusal that names the wrong remedy is worse than one
# that names none, because the reader ACTS on it.
#
# WHY THIS FILE EXISTS SEPARATELY. test/lib/release_cli_test.rb owns the integration
# coverage of pre_qa_gate, and it is the suite's worst APPEND hotspot — frozen at its
# ceiling in config/test_health.yml by design. The ratchet's stated out is a new file
# named for its concern, which is what this is; test/lib/release_auth_remedy_message_test.rb
# is the same move for the ship lane's auth message, and `eval_helper` is
# re-implemented from it rather than shared for the reason that file gives.
require "minitest/autorun"
require "open3"
require_relative "../support/session_env"
require_relative "../../bin/lib/ci_status"

class ReleasePreQaRemedyTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # The two halves of the contract, spelled ONCE. "no local cert stands in" is the
  # clause test/lib/dor_check_exempt_ci_test.rb reads to decide what a gate PROMISED,
  # so a denial must carry it verbatim rather than paraphrase it.
  DENIES_CERT = "no local cert stands in"
  OFFERS_CERT = "certify in full instead"

  # Every cause the remedy classifies, because the route is chosen INDEPENDENTLY of
  # the cause and a spot-check on one cause would not notice a branch that leaks the
  # offer back on the others.
  CAUSES = [:permissions, :credentials, :authentication, :rate_limit, :forbidden, nil].freeze

  # ── the G3 refusal itself ───────────────────────────────────────────────────

  def test_the_unreadable_g3_abort_denies_the_cert_route_on_every_cause
    CAUSES.each do |cause|
      message = abort_message(:unreadable, cause: cause)

      assert_includes message, DENIES_CERT,
                      "#{cause.inspect}: G3 retired the local-cert route, so the refusal must SAY a cert " \
                      "does not stand in:\n#{message}"
      refute_includes message, OFFERS_CERT,
                      "#{cause.inspect}: this is the defect — offering a certification on a gate that " \
                      "advances on a GREEN CI and nothing else:\n#{message}"
      refute_includes message, "bin/full-suite-check",
                      "#{cause.inspect}: naming the cert command is the offer wearing different words"
    end
  end

  # THE SECOND HALF, and it is not cosmetic: `<task>` asks the reader for a value this
  # gate has no way of having. G3 is release-grain, so the command it names must be
  # the one an operator can actually run — spelled as the sibling abort branches in
  # pre_qa_ci_abort spell it.
  def test_the_unreadable_g3_abort_names_a_runnable_command_not_a_placeholder
    CAUSES.each do |cause|
      message = abort_message(:unreadable, cause: cause)

      refute_includes message, "<task>",
                      "#{cause.inspect}: a release-grain gate cannot name a task slug — the placeholder " \
                      "was unfillable, not merely ugly:\n#{message}"
      assert_includes message, "re-run `bin/release prepare`",
                      "#{cause.inspect}: the reader is blocked; the one instruction they get must be a " \
                      "command that exists and applies here"
    end
  end

  # ADVICE IS A FAILURE-PATH ARTIFACT — read only by someone already blocked — so a
  # command it names that does not exist wastes the one instruction they get. The
  # property, not a spelling: the same guard ci_status_test.rb runs over the DEFAULT
  # route, run here over the retired one, which that test never reaches.
  def test_every_command_the_retired_route_names_actually_exists
    root = File.expand_path("../..", __dir__)

    CAUSES.each do |cause|
      text = CiStatus.unreadable_remedy("McRitchie-Studio/mcritchie-studio", cause: cause, cert_route: :retired)

      text.scan(%r{\bbin/[a-z0-9][a-z0-9._-]*}).uniq.each do |rel|
        path = File.join(root, rel)
        assert File.exist?(path), "retired route for #{cause.inspect} names #{rel}, which does not exist"
        assert File.executable?(path), "retired route for #{cause.inspect} names #{rel}, which is not executable"
      end
    end
  end

  # ── the premise, pinned ─────────────────────────────────────────────────────
  #
  # THE DENIAL IS ONLY HONEST IF IT IS TRUE, and its truth is a property of
  # bin/release.rb rather than of any string: the pre-QA suite was DEMOTED at Phase 3
  # and nothing replaced it, so there is no certification this file would consult.
  # Asserted against the SOURCE with comments stripped — this file's whole subject is
  # prose outrunning behaviour, and a scan fooled by a comment (including the ones the
  # fix itself added, which name bin/full-suite-check while explaining why it is not
  # named to the operator) would be the joke writing itself.
  #
  # If a future change gives G3 a real cert path, this fails and sends the author back
  # to the sentence — which is the whole point of pinning a premise instead of a text.
  def test_the_release_gate_holds_no_certification_the_remedy_could_have_named
    code = File.readlines(BIN).reject { |line| line.strip.start_with?("#") }.join

    %w[full-suite-check fast-check full_cert fast_cert].each do |mechanism|
      refute_includes code, mechanism,
                      "bin/release.rb now names #{mechanism} in CODE — if a local certification can reach " \
                      "the G3 verdict, the retired-route denial above has stopped being true and must be " \
                      "re-decided, not left standing"
    end
  end

  # THE CONTROL FOR THE FIXTURE, in both directions. A run that quietly took some
  # OTHER branch of pre_qa_ci_abort would make every assertion above pass while
  # testing nothing — so prove :unreadable reaches the credential remedy, and that the
  # branches on either side of it do NOT (a red CI is a regression, not a token
  # fault, and prescribing a credential fix for it would be the mirror defect).
  def test_only_the_unreadable_branch_carries_the_credential_remedy
    unreadable = abort_message(:unreadable, cause: :permissions)
    assert_includes unreadable, "CREDENTIAL fault or API limit",
                    "the :unreadable fixture must actually reach the shared remedy, or these tests " \
                    "assert nothing:\n#{unreadable}"

    red = abort_message(:red, cause: nil, extra: ", failing: [\"rails\"]")
    assert_includes red, "regression is riding", "the :red branch is the eject/revert recovery"
    refute_includes red, "CREDENTIAL fault", "a red CI is not a token fault"
    refute_includes red, DENIES_CERT
    refute_includes red, OFFERS_CERT

    held = abort_message(:pending, cause: nil)
    assert_includes held, "poll timed out", "the else branch is the HELD, poll-exhausted verdict"
    refute_includes held, "CREDENTIAL fault", "a pending CI is not a token fault"
    refute_includes held, OFFERS_CERT,
                    "no G3 branch may offer a certification — the route is retired for the whole gate"
  end

  # ── the route is a THIRD one, not a reuse ───────────────────────────────────
  #
  # `false` also denies, so a reader may reasonably ask why G3 did not simply pass it.
  # Because its denial rests on "the shape/test-tier gate is already waived" — true of
  # a doc-only diff, FALSE of a release SHA nobody exempted. Reusing it would print a
  # true verdict on a false premise, which is the same species of defect as the offer
  # it replaces. This is the assertion that fails if someone collapses the two.
  def test_the_retired_route_denies_for_its_own_reason_not_the_exempt_one
    retired = CiStatus.unreadable_remedy("McRitchie-Studio/mcritchie-studio", cause: :permissions,
                                                                             cert_route: :retired)
    exempt  = CiStatus.unreadable_remedy("McRitchie-Studio/mcritchie-studio", cause: :permissions,
                                                                             cert_route: false)
    gated   = CiStatus.unreadable_remedy("McRitchie-Studio/mcritchie-studio", cause: :permissions,
                                                                             cert_route: true)

    assert_includes retired, DENIES_CERT
    refute_includes retired, "doc-only",
                    "a release SHA is not a doc-only diff — borrowing the exempt sentence would state a " \
                    "false premise:\n#{retired}"
    refute_includes retired, "already waived",
                    "nothing was waived at G3; the route was RETIRED, which is a different fact"
    assert_includes retired, "RELEASE-grain", "the denial must say WHY it denies, not merely that it does"

    assert_includes exempt, "doc-only", "the exempt route keeps its own premise, unchanged by this task"
    assert_includes gated, OFFERS_CERT, "the gated route still offers the cert that genuinely clears it"
    refute_includes gated, DENIES_CERT

    refute_equal retired, exempt, "two routes that print the same string are one route with two names"
  end

  private

  # Builds a G3 abort message by loading bin/release.rb standalone, exactly as
  # test/lib/release_auth_remedy_message_test.rb does for the ship lane's auth text.
  def abort_message(state, cause:, extra: "")
    ci = "{ state: #{state.inspect}, cause: #{cause.inspect}, reason: \"403 refused\"#{extra} }"
    eval_helper(%(pre_qa_ci_abort("mcritchie-studio", "a" * 40, #{ci})))
  end

  def eval_helper(expr)
    out, err, status = Open3.capture3(
      SessionEnv.neutralized({}), "ruby", "-e", %(load #{BIN.inspect}; print(#{expr}))
    )
    assert_predicate status, :success?, "bin/release must load standalone: #{err}"
    out
  end
end
