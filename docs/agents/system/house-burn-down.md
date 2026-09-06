# House Burn-Down Recovery Protocol

How to rebuild the McRitchie dev environment from a freshly-reset Mac. This is the detailed fallback behind `mcritchie-studio/bin/ecosystem-build`; start with the fast path and only drop into manual phases when a script phase fails. For the script itself — its phases, when to run it, idempotency, and reset semantics — see [ecosystem-build.md](ecosystem-build.md).

**Time budget**: ~25-30 min on a fresh machine with Homebrew installed, longer on slow links or when Rust/Anchor dependencies compile cold. Later runs are usually under a minute because the script is idempotent.

## The Ecosystem

| Repo | Role | Stack | Port |
|------|------|-------|------|
| [`mcritchie-studio`](https://github.com/McRitchie-Studio/mcritchie-studio) | Flagship hub. Task/News/Content pipelines, NFL data, agent docs, recovery scripts | Rails 8.1 / Postgres | 3000 |
| [`turf-monster`](https://github.com/McRitchie-Studio/turf-monster) | Sports pick'em (World Cup 2026). Solana onchain | Rails 8.1 / Postgres / Redis / Sidekiq | 3100 |
| [`chain-ops`](https://github.com/McRitchie-Studio/chain-ops) | Planned Solana environment control plane | Rails 8.1 / Postgres | 3400 |
| [`studio-engine`](https://github.com/McRitchie-Studio/studio-engine) | Shared Rails engine: passwordless auth, error logging, theme, modals, ImageCache | Ruby gem | — |
| [`solana-studio`](https://github.com/McRitchie-Studio/solana-studio) | Ruby Solana client (RPC, ed25519, borsh, txns) | Ruby gem | — |
| [`turf-vault`](https://github.com/McRitchie-Studio/turf-vault) | Onchain escrow vault. 2-of-3 multisig. Consumed by Turf Monster | Anchor / Rust / Solana | — |

**Dependency graph (build order):**

```
studio-engine gem ──┐
                    ├──> mcritchie-studio (flagship)
                    ├──> chain-ops ─────> solana-studio gem
                    └──> turf-monster ──> solana-studio gem
                                       ──> turf-vault (devnet + mainnet deployments)
```

The Rails apps consume `studio-engine` and `solana-studio` from RubyGems. Local clones are still part of the rebuild because agents edit, release, and audit those gems.

---

## Fast path (the only commands you should need)

On a fresh Mac with Homebrew already installed:

```bash
# 1. Clone the flagship — every other repo + script lives downstream of this one
git clone https://github.com/McRitchie-Studio/mcritchie-studio.git ~/projects/mcritchie-studio
cd ~/projects/mcritchie-studio

# 2. First pass — installs all brew packages (incl. 1Password CLI), Rust, Solana,
#    Anchor, etc. Bails at Phase 4 once it needs your 1Password service token.
bin/ecosystem-build

# 3. Copy your 1Password service account token (ops_...) to clipboard, then:
bin/setup-1pass-token

# 4. Second pass — picks up at Phase 4 with the token now set, restores .env
#    from Heroku + 1Password, clones sibling repos, bundles + DBs + Anchor,
#    installs the root AGENTS.md + shared user-global agent skills, bounces active Rails servers.
bin/ecosystem-build
```

That's it. The only thing you actually do is copy the token and run the commands above. On every later machine a single pass just walks checkmarks and re-bounces the servers.

**Re-running anytime:** `bin/ecosystem-build` is fully idempotent. Run it after pulling new commits, switching branches, or anytime you want to confirm "everything still works." It will reset active Rails servers to a clean dev state.

**Custom project layout:** set `PROJECTS_DIR` to override `~/projects` (e.g. `PROJECTS_DIR=~/code bin/ecosystem-build`). The script clones siblings into that directory.

**Default NFL data:** every build pulls the live schedule, runs the ESPN depth-chart scrape, and snapshots current-week rosters (~3-5 min). Game show pages and the season grid work out of the box.

**Headshots (opt-in):** `/nfl-rosters` shows position-labeled placeholders by default. To cache real player photos, run `WITH_NFL_HEADSHOTS=1 bin/ecosystem-build` — adds ~10-15 min for the nflverse master CSV + S3 headshot uploads. Requires AWS creds in `.env` (auto-restored by Phase 4).

The manual phase-by-phase steps below are kept as a fallback for debugging when the script can't complete a phase.

---

## Phase 0 — Prereqs

You need these *already installed* before this protocol can start:

- macOS with Xcode Command Line Tools (`xcode-select --install` if missing)
- Homebrew (`brew --version`)
- `git` (ships with Xcode CLT)
- The GitHub repos accessible to your account (HTTPS clone works)
- TWO 1Password service account tokens: one with read on the AGENT vault
  (`studio-agents`), one with read on the ADMIN vault (`studio-agents-admin`) — see 5a (account `alex@mcritchie.studio` / `MWOV5OT5BRHATI4EGMN26C5DPA`)

`bin/ecosystem-build` handles everything else.

---

## Phase 1 — System tools (one brew command)

```bash
brew update && brew install \
  ruby@3.3 \
  mise \
  postgresql@14 \
  redis \
  1password-cli \
  gh \
  imagemagick \
  ffmpeg \
  libpq \
  heroku/brew/heroku

brew install --cask google-chrome
```

~5 min. Installs:
- **ruby@3.3** — Ruby 3.3.11 with the full stdlib for McRitchie Studio and ecosystem bootstrap
- **google-chrome** (cask) — the operator's browser. Needed before
  `docs/agents/agents/steffon/sops/chrome-profiles.md` can restore the avatar-menu
  roster, and nothing else in this protocol installs it.
- **mise** — version manager for Node (not Ruby — see above)
- **postgresql@14** — local DB for Rails apps
- **redis** — Sidekiq queue for Turf Monster and worktree stacks
- **1password-cli** (`op`) — secret retrieval
- **gh** — GitHub CLI
- **imagemagick** — image resizing for studio engine's `ImageCache`
- **ffmpeg** — lineup-graphic video assembly (Starter Post X/TikTok workflows)
- **libpq** — `pg` gem build deps
- **heroku** — deploys

Start the background services:

```bash
brew services start postgresql@14
brew services start redis
```

The brew Postgres install creates a superuser matching your macOS login name with no password. Rails apps' `database.yml` uses default role + no password, so they connect fine without further setup.

---

## Phase 2 — Shell setup

Append to `~/.zshrc` (idempotent — check before adding):

```bash
# Ruby via Homebrew (keg-only — must be added to PATH explicitly)
export PATH="/opt/homebrew/opt/ruby@3.3/bin:$PATH"
export PATH="/opt/homebrew/lib/ruby/gems/3.3.0/bin:$PATH"

# mise — Node (and other non-Ruby langs) version manager
eval "$(/opt/homebrew/bin/mise activate zsh)"

# Solana CLI
export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"

# Cargo (Rust)
export PATH="$HOME/.cargo/bin:$PATH"
```

Then either `source ~/.zshrc` or open a new terminal. Verify: `which ruby` → `/opt/homebrew/opt/ruby@3.3/bin/ruby`.

---

## Phase 3 — Languages

### Node + yarn (via mise)

```bash
mise use --global node@22
npm install -g yarn
```

~30s. Node 22 is the ecosystem standard for local dev, CI, and Heroku asset builds. `turf-vault`'s TypeScript test deps (`@solana/codecs-numbers`) need Node >= 20.18.0, so do not downgrade to Node 18.

### Ruby — already installed in Phase 1

Brew's `ruby@3.3` formula gives you Ruby 3.3.11 with the complete stdlib. Verify:

```bash
ruby --version                                          # ruby 3.3.11 (...)
ruby -e "require 'socket'; puts Socket.gethostname"     # should print your hostname
```

If `socket` errors here, you're picking up the wrong Ruby — re-check Phase 2 PATH order.

### Rust + Solana CLI + Anchor

```bash
# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
source "$HOME/.cargo/env"
rustup install 1.89.0
rustup default 1.89.0

# Solana CLI (Anza — release.solana.com is deprecated)
sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"
export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"

# Anchor (uses Rust + cargo)
cargo install anchor-cli --version 0.32.1 --locked
```

~10-15 min. Anchor compile is the longest single step.

**Gotcha**: The Solana installer appends PATH to `~/.profile` (bash convention), which zsh doesn't read by default. The PATH line in Phase 2's `~/.zshrc` block handles this — don't skip it.

Verify:
```bash
rustc --version    # rustc 1.89.0
solana --version   # solana-cli 3.x (Agave)
anchor --version   # anchor-cli 0.32.1
```

### Solana keypair (for local Anchor testing)

```bash
solana-keygen new --no-bip39-passphrase --silent --outfile ~/.config/solana/id.json
solana config set --url devnet
solana address  # confirm your new pubkey
```

This is a **local dev keypair**, NOT one of the agent vault wallets. The agent wallets (Alex Bot, Mason, Mack, Turf Monster) stay in 1Password.

---

## Phase 4 — Clone all repos

```bash
mkdir -p ~/projects && cd ~/projects
gh repo clone McRitchie-Studio/mcritchie-studio
gh repo clone McRitchie-Studio/turf-monster
gh repo clone McRitchie-Studio/studio-engine
gh repo clone McRitchie-Studio/solana-studio
gh repo clone McRitchie-Studio/turf-vault
```

(`gh auth login` first if not authenticated.)

---

## Phase 5 — Secrets

Two layers:

### 5a. 1Password CLI auth (via service account token)

Use a **service account token** rather than the desktop app integration — it avoids Touch ID prompts per call and works headlessly. One-time setup:

1. Sign into https://start.1password.com as `alex@mcritchie.studio` (account `MWOV5OT5BRHATI4EGMN26C5DPA`)
**TWO TOKENS, TWO VAULTS — and the split is a security boundary, not bookkeeping.**
The build lanes and the ship lane authenticate as different GitHub App identities
(`github.mcritchie-agent` builds and merges; `github.mcritchie-deployer` pushes
`main` and deploys but cannot touch PRs). Their credentials live in **different
vaults**, read by **different service-account tokens**, so an ordinary agent shell
cannot MINT an admin credential — the 1Password read is the step that is
*structurally* blocked, not merely discouraged. That such a shell does not come to
HOLD a deployer token is a **second, separate** mechanism: `bin/gh-token` refuses
to cache that identity at all (`CACHEABLE_IDENTITIES`). Both hold today — 5a-ii
has the history — but they are enforced in different files, and a boundary
described as one thing gets trusted for the other. `bin/lib/op_vaults.rb` is the
one place that maps lane → vault → token; nothing else should ever name a vault.

| Lane | Vault (default) | Token variable | Loaded where |
|------|-----------------|----------------|--------------|
| `agent` — build, review, merge | `studio-agents` | `OP_SERVICE_ACCOUNT_TOKEN` | `~/.zprofile` — every shell |
| `deployer` — ship, deploy | `studio-agents-admin` | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` | `~/.zprofile.admin` — **opt-in only** |

A machine whose vaults are named differently overrides with `MCR_OP_VAULT_AGENT` /
`MCR_OP_VAULT_ADMIN` rather than editing any script.

#### 5a-i. The AGENT token (required — nothing works without it)

2. **Developer Tools → Service Accounts → Create Service Account**
3. Grant **read** on the **agent** vault (`studio-agents`), plus `🧱 Blockchain` if you'll need it
4. Copy the token (`ops_...` — shown only once), then:

```bash
bin/setup-1pass-token
```

Writes `OP_SERVICE_ACCOUNT_TOKEN` to `~/.zprofile` (idempotent, `chmod 600`) and
verifies with `op vault list`. Then `source ~/.zprofile`, or open a new terminal.

#### 5a-ii. The ADMIN token (required before any production deploy)

5. Create a **SECOND, SEPARATE** service account granted **read** on `studio-agents-admin`.
   Do **not** simply add `studio-agents-admin` to the agent's service account: one token
   that sees both vaults still works, but the isolation above is then gone.
6. Confirm `github.mcritchie-deployer` actually lives in `studio-agents-admin` — the
   deployer App item, `app-id` field plus the `.pem` **file attachment**.
7. Copy that token, then:

```bash
bin/setup-1pass-token --admin
```

Writes `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` to **`~/.zprofile.admin`** (`chmod 600`),
which is deliberately **not** auto-loaded. Ship lanes opt in explicitly:

```bash
source ~/.zprofile.admin
```

**Verify both lanes before trusting either** — a missing admin token does not
announce itself until a deploy:

```bash
eval "$(bin/gh-auth-refresh --export)" && gh api rate_limit --jq .rate.remaining   # agent
bin/gh-token --identity deployer >/dev/null && echo "deployer OK"                  # admin
```

Run the deployer check in a shell that has sourced `~/.zprofile.admin`.

**THE CACHE USED TO LIE TO YOU HERE. It no longer does — trust the green.**
`bin/gh-token` caches a minted token for **50 minutes**
(`REFRESH_AFTER_SECONDS = 3000`) in `<projects>/.agents/github-tokens.json`, and
the main flow reads that cache BEFORE it mints. Until
`/tasks/never-cache-deployer-token` that cache covered the deployer too, so
within 50 minutes of ANY successful admin mint the check above printed `deployer
OK` **in a shell that never sourced `~/.zprofile.admin`** — certifying an admin
token you had not installed, with the truth surfacing at the next production
deploy. That is exactly the cause-far-behind-symptom failure this section exists
to prevent. The deployer is now cached NOWHERE (`CACHEABLE_IDENTITIES =
%w[agent]`), so a green `deployer OK` proves the 1Password read itself
succeeded, with no cache-clearing dance first.

What is blocked without the admin token is the **1Password read** — the mint.
And since `never-cache-deployer-token` shipped, a build lane can no longer obtain
a deployer token by any route either: there is nothing on disk to read, so the
mint is the only path and it is closed.

Both scripts read from `pbpaste`, validate the prefix and strip whitespace, so the
token never touches shell parsing — bypassing the smart-quote / line-wrap /
newline-in-paste failures that broke direct `! echo ops_… >> ~/.zprofile` attempts.
See Gotcha 12.

**To rotate either token**, re-copy and re-run the same command — each replaces only
its own line. (The removal is anchored on `^export VAR=`, so it takes that variable's
own export line and nothing else — not a comment that mentions the name, not a longer
variable that contains it. It is **not** protecting the admin line from the agent
install: an earlier version of this paragraph said an unanchored match on
`OP_SERVICE_ACCOUNT_TOKEN` also matched `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` as a
substring and had once silently deleted the admin token. That never happened and
could not — `OP_ADMIN_` sits between `OP_` and `SERVICE_`, so neither name contains
the other, and the two variables live in different files. Verified 2026-08-29 by
replaying the old `sed` against a profile holding both lines in both orders.)

### 5b. Per-app .env files

The Rails apps read `.env` via Rails' default dotenv (or the `dotenv-rails` gem). Restore each:

**`/Users/alex/projects/mcritchie-studio/.env`** — see `docs/agents/modules/credentials.md` for the operating rules and `docs/agents/modules/credential-inventory.md` for item names. Minimum to boot:

```bash
RAILS_MASTER_KEY=$(heroku config:get RAILS_MASTER_KEY --app mcritchie-studio)
GOOGLE_CLIENT_ID=...                  # Google Cloud Console
GOOGLE_CLIENT_SECRET=...
ANTHROPIC_API_KEY=...                 # heroku config:get — studio-agents held no "anthropic" item on 2026-08-29
X_BEARER_TOKEN=...                    # 1Password: "x.api" (read)
X_API_KEY=...                         # 1Password: "x.api" (write — Read+Write app)
X_API_SECRET=...
X_ACCESS_TOKEN=...
X_ACCESS_TOKEN_SECRET=...
HIGGSFIELD_API_KEY=...                # 1Password: "agent.higgesfield"
HIGGSFIELD_API_SECRET=...
TIKTOK_CLIENT_KEY=...                 # 1Password: "🐊 TikTok"
TIKTOK_CLIENT_SECRET=...
TIKTOK_REFRESH_TOKEN=...
TIKTOK_OPEN_ID=...
AWS_ACCESS_KEY_ID=...                 # S3 ImageCache bucket
AWS_SECRET_ACCESS_KEY=...
SES_AWS_ACCESS_KEY_ID=...             # 1Password: agent.aws.mcritchie-ses, SES API checks only
SES_AWS_SECRET_ACCESS_KEY=...
SES_REGION=us-east-2
```

**`/Users/alex/projects/turf-monster/.env`** — see `turf-monster/docs/SOLANA.md` for full list. **`RAILS_MASTER_KEY` is not optional** — `db:seed` calls `User#generate_managed_wallet!` which reads `Rails.application.credentials.secret_key_base` to encrypt the wallet. Without the key, seed crashes mid-run with `undefined method '[]' for nil:NilClass`.

```bash
RAILS_MASTER_KEY=$(heroku config:get RAILS_MASTER_KEY --app turf-monster-mainnet)
GOOGLE_CLIENT_ID=...                  # may differ from mcritchie-studio
GOOGLE_CLIENT_SECRET=...
SOLANA_ADMIN_KEY=$(op item get "agent.alex.solana" --vault studio-agents --fields "private key")
SOLANA_RPC_URL=https://api.devnet.solana.com   # or paid provider if rate-limited
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
SES_AWS_ACCESS_KEY_ID=...             # 1Password: agent.aws.mcritchie-ses, SES API checks only
SES_AWS_SECRET_ACCESS_KEY=...
SES_REGION=us-east-2
```

**Shared `/Users/alex/projects/.env`** — keep this minimal, only put truly cross-app vars here. Prefer app-local `.env` files plus the credential inventory for most secrets.

### 5c. Heroku CLI login

```bash
heroku login   # opens browser
heroku apps    # should list mcritchie-studio and turf-monster
```

This is what unlocks the `heroku config:get` commands above.

---

## Phase 6 — Per-app bringup

### 6a. mcritchie-studio (flagship — bring this up first)

```bash
cd ~/projects/mcritchie-studio
bundle install
bin/rails db:create db:migrate db:seed
bin/rails server                   # port 3000
```

Visit http://localhost:3000 and sign in with a magic link to `alex@mcritchie.studio`.

Seeds load 9 agents (Alex, Avi, Carl, Shannon, Jasper, Steffon, Turf Monster, Mack, Mason), 35 skills, sample tasks, 32 NFL + 71 NCAA + 48 FIFA teams, ~2400 active contracts, ~570 PFF-graded athletes. The `db:seed` phase 32 (`32_headshot_links.rb`) makes network calls — safe to let it run, or skip with `SKIP_NETWORK_SEEDS=1` if behind a firewall.

For full NFL data (UDFAs, depth charts, ESPN headshots cached to S3), use the NFL rebuild workflow once it has been promoted into neutral agent docs. The underlying steps are `db:reset` -> `db:seed` -> `nfl:players_seed` -> `espn:scrape_depth_charts`. Requires AWS creds in `.env`.

For the lineup capture (Starter Post X workflow) and Playwright e2e tests:
```bash
npm install              # installs Playwright + Chromium
npm test                 # 13 e2e smoke tests
```

### 6b. turf-monster

```bash
cd ~/projects/turf-monster
bundle install
bin/rails db:create db:migrate db:seed
bin/tm up                # starts/adopts web (3100), Sidekiq, Tailwind, Stripe listener
```

Visit http://localhost:3100. Login same admin.

`bin/tm up` is the agent-friendly command. It runs detached, preflights Redis/Postgres, builds Tailwind once, starts Sidekiq, starts the Stripe listener when available, polls readiness, and prints the review URL. `bin/dev` remains useful for a human interactive terminal with combined logs, but it can self-terminate in background/no-TTY sessions and does not manage the Stripe listener.

### 6c. solana-studio (gem, no bringup)

```bash
cd ~/projects/solana-studio
bundle install
ruby -Itest test/keypair_test.rb test/borsh_test.rb test/transaction_test.rb
```

Library only — no server. Only clone locally if editing.

### 6d. studio-engine (gem, no bringup)

```bash
cd ~/projects/studio-engine
bundle install
```

Engine only — no DB, no server, no tests of its own. Test it via the consuming apps' suites. Only clone locally if editing the engine.

After editing the engine and pushing to GitHub:
```bash
cd ~/projects/mcritchie-studio && bundle update studio-engine
cd ~/projects/turf-monster && bundle update studio-engine
```

### 6e. turf-vault (Anchor smart contract)

```bash
cd ~/projects/turf-vault
yarn install                                 # TypeScript test deps (ts-mocha, @solana/codecs-*)
anchor build                                 # ~3-5 min on first build
anchor test                                  # spins up local validator and runs the TS suite
```

Current deployment facts drift quickly. Treat `turf-vault/docs/CURRENT_DEPLOYMENT.md` and `turf-monster/docs/SOLANA.md` as the source of truth for program IDs and clusters. `CURRENT_DEPLOYMENT.md` records the upgrade authority, threshold and `VaultState` signer set per cluster, under `## Devnet` and `## Mainnet` — **read the heading you mean**. The two signer sets are identical today, but nothing in the program keeps them that way: `update_signers` can move one without the other. Confirm the live set on-chain before you act on it.

**Gotcha**: `anchor test` will fail with `ts-mocha: command not found` if you skip `yarn install`. The Anchor scaffold's test runner is JS, not Rust.

To deploy a new version: the program's upgrade authority is a Squads V4 2-of-3 multisig, and **the vault PDA differs per cluster** — devnet (`EQGFJAcA…`) is `BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC`, mainnet (`DaFv83yo…`) is `Bk9sS7iiSRL18vuo2KVzkeGw7EekKqxMCjrdoyGGdJm`. The first two commands below are the **devnet** path, but the third is not scoped by them: `squad-upgrade.js` reads its cluster from `turf-vault/scripts/squad.json`'s top-level `network`/`programId`/`vaultPda`, which on `main` are the **mainnet** set, so it proposes against that file's cluster no matter what `solana config set` selected. Confirm the authority for the cluster you are on with `solana program show <PROGRAM_ID> --url <cluster>` before proposing anything. Either way a plain `anchor deploy` no longer works — it would be rejected by the on-chain upgrade-authority check. Build the program, then route the upgrade through the Squads multisig:
```bash
solana config set --url devnet
anchor build
node turf-vault/scripts/squad-upgrade.js   # writes the buffer + proposes the upgrade to the Squad for 2-of-3 cosign
```
See `docs/agents/system/squads-upgrade-authority-migration.md` for the historical migration notes, then verify current procedure in the `turf-vault` repo before proposing or approving an upgrade.

Season bootstrap and free-entry token operations now live with the app that runs them. Use `turf-monster/docs/SOLANA.md`, `turf-monster/docs/AUTH.md`, and the Turf Monster admin UI (`/admin/seasons`, `/admin/free_entries`) for current steps instead of copying version-specific instructions here.

---

## Phase 7 — Smoke test the ecosystem

1. **Hub running**: http://localhost:3000 → dashboard renders, can log in
2. **Satellite running**: http://localhost:3100 → contests list renders
3. **Auth**: request magic links in both apps. Turf Monster currently disables cross-app SSO and 404s `/sso_login` by design.
4. **Solana keypair**: `solana address` returns your pubkey
5. **Anchor local test**: `cd ~/projects/turf-vault && anchor test` — suite passes

---

## Appendix A — Gotchas encountered during this protocol

These are the surprises from the last burn-down. Pre-baked into the steps above; documented here so future-you knows *why*:

1. **Don't use mise/ruby-build for Ruby on Darwin 25 / Apple Silicon** — mise auto-applies `--with-ext=openssl,psych,+` which silently skips the `socket` C extension. Every `bundle exec` then dies with `cannot load such file -- socket (LoadError)`. It's a mise build-flag issue, not version-specific. Fix: use `brew install ruby@3.3` (always builds the full stdlib) and keep mise scoped to Node only. The `.ruby-version` files in both Rails apps pin `3.3.11`, matching brew's `ruby@3.3`.

2. **`release.solana.com` is deprecated** — returns SSL errors. Use `release.anza.xyz/stable/install`.

3. **Solana installer writes PATH to `~/.profile`** — zsh doesn't source `.profile` by default. The Phase 2 `~/.zshrc` block handles this explicitly.

4. **Bundler version drift** — Gemfile.lock pins `BUNDLED WITH 2.4.19`. mise's Ruby 3.3.11 ships with bundler 2.3.x and will auto-upgrade on first `bundle install`. Works fine if `socket` ext is present (Gotcha 1).

5. **System Ruby 2.6 is unusable** — macOS ships with ancient Ruby. Don't run `bundle` against it. mise's shims (`~/.local/share/mise/shims`) must be earlier on PATH than `/usr/bin`.

6. **Heroku LFS gotcha** — `mcritchie-studio` repo has LFS pointers in history (retired 2026-04-30) but Heroku's git remote doesn't speak LFS. Push with `git push heroku main --no-verify` to skip the LFS pre-push hook.

7. **Public devnet RPC is rate-limited** — `SOLANA_RPC_URL` defaults to public devnet which 429s under load. Use a paid provider (QuickNode, Helius) for serious work.

8. **Sidekiq dies silently without Redis** — Turf Monster's `bin/tm up` preflights Redis before starting Sidekiq. If running manually, check `brew services list | grep redis` first.

9. **TikTok app is in review** (submitted 2026-05-04) — only sandbox + manual posting paths work until Content Posting API approval. Don't expect API-direct posts to publish.

10. **`RAILS_MASTER_KEY` is a hard prerequisite for `turf-monster db:seed`** — not just for booting. `db/seeds/users.rb` calls `User#generate_managed_wallet!`, which encrypts the wallet's private key via `Rails.application.credentials.secret_key_base[0, 32]`. Without the master key, that returns nil and the seed dies. Restore the key **before** running `db:create db:migrate db:seed`.

11. **Don't tail-pipe `bin/rails db:seed`** — `bin/rails db:seed | tail -30` returns `tail`'s exit code (0), masking seed failures. Use `set -o pipefail` or run the seed without piping when verifying it ran clean.

12. **macOS Terminal mangles long secret pastes** — Multiple compounding failure modes when pasting tokens via shell commands:
    - **Smart quotes** (System Settings → Keyboard → Text Input → "Use smart quotes and dashes") silently convert `"` → `"` `"` on paste. zsh doesn't treat these as quote delimiters, so quoted strings get tokenized as bare words. Symptom: `zsh: command not found: WRITE OK` from `echo "WRITE OK"`.
    - **Line wrapping** in long commands can insert literal newlines mid-paste, splitting `chmod 600` into `chmod 60` + `\n` + `0 filename`.
    - **Token whitespace** — copy buffers sometimes wrap with `&nbsp;` or literal spaces inside base64url tokens.
    Solution: use `bin/setup-1pass-token` (which reads `pbpaste` → never goes through shell parsing). For one-off Heroku/etc. keys, use the same pattern: `KEY=$(pbpaste | tr -d '[:space:]')` rather than `KEY=ops_paste_here`.

---

## Appendix B — What `bin/ecosystem-build` does

Phases execute in order. Each phase: detect current state → install/configure only what's missing → verify. Re-running is safe; on a healthy machine, every phase logs ✓ checkmarks.

| Phase | Responsibility |
|-------|----------------|
| 1. System tools | Homebrew packages (ruby@3.3, postgres@14, redis, mise, gh, heroku, etc.), starts Postgres + Redis services, verifies ruby socket extension |
| 2. Languages | Node 22 + yarn (via mise), Rust 1.89.0 (via rustup), Solana CLI (via Anza), Anchor 0.32.1 (via cargo), local Solana devnet keypair |
| 3. Shell config | `~/.zshrc` PATH lines (brew Ruby, mise activation, Solana, Cargo), `~/.zprofile` chmod 600 |
| 4. Secrets | Verifies `OP_SERVICE_ACCOUNT_TOKEN` works; pulls `heroku.studio.agents` from 1Password into `HEROKU_API_KEY` (`legacy-personal-api-key` field until the app-transfer cutover, then `credential`); restores `.env` for active Rails apps from provider config |
| 5. Sibling repos | `gh repo clone` for `turf-monster`, `studio-engine`, `solana-studio`, `turf-vault` (skips ones already present) |
| 5b. Agent runtime | Runs `bin/agent-runtime install`, which installs `/Users/alex/projects/AGENTS.md` + `CLAUDE.md` from `mcritchie-studio/docs/agents/{index,claude}.md` (Claude Code reads CLAUDE.md, not AGENTS.md), mirrors the shared user-global agent skills `docs/agents/skills/*` → `~/.claude/skills/*` + `~/.codex/skills/*`, and configures Codex marker hooks. The lower-level `bin/install-agent-docs` remains the implementation, and `bin/agent-runtime doctor` verifies drift plus marker/runtime state. |
| 5c. Secrets replay | Re-runs Phase 4 after sibling repos exist so newly-cloned active satellites get `.env` before DB setup |
| 6. Bundles + DBs | `bundle install` + `db:create db:migrate db:seed` for each Rails app; bundle for `solana-studio` |
| 6b. NFL data (default) | Always runs. Chains `nfl:schedule_seed YEAR=2026` (real schedule from nflverse) + `espn:scrape_depth_charts` (live depth charts from ESPN JSON API) + `nfl:rosters_snapshot SEASON=2026-nfl` (snapshot fresh depth charts → current-week Rosters) + `nfl:rankings_compute SEASON=2026-nfl GRADES_FROM=2025-nfl` (preseason TeamRanking snapshot using last year's PFF grades, so `/games/2026/week/N/...` show pages render rank pills). ~3-5 min, network only — no AWS creds needed. |
| 6c. NFL headshots (opt-in) | Only runs when `WITH_NFL_HEADSHOTS=1`. Chains `nfl:players_seed` (nflverse master CSV ~24k rows + S3 headshot cache ~1100 athletes) + `nfl:upload_headshots`. ~10-15 min, requires AWS creds in `.env`. Without this, `/nfl-rosters` shows position-labeled placeholder circles instead of player photos. |
| 7. Anchor + e2e | `yarn install` + `anchor build` for `turf-vault`; `npm install` for active Rails apps; `npx playwright install chromium` (~90 MB cached for e2e tests) |
| 8. Servers | Always kills + restarts active Rails apps on their registered ports, curls each to verify HTTP 2xx/3xx |
| 9. Env snapshot | Writes `mcritchie-studio/tmp/env-snapshot-YYYY-MM-DD.json` containing both apps' `.env` contents (raw, faithfully). Heroku-independent fallback for secret recovery. Gitignored, chmod 600. Skipped silently if no `.env` files exist yet. |

If any phase fails, the script prints what to do and exits. Re-running picks up where it left off.

The one secret-input boundary is **Phase 4**: if the OP token isn't set, the script bails with instructions to run `bin/setup-1pass-token` first. That's the only step that can't be automated — by design (the token has to come from your clipboard).

---

## Appendix C — Tooling versions reference

What this protocol installed last successful run:

| Tool | Version | Source |
|------|---------|--------|
| Homebrew | latest | pre-existing |
| mise | latest | brew |
| Ruby | 3.3.11 | brew `ruby@3.3` |
| Node | 22.x | mise |
| yarn | 1.22.x | npm -g |
| Postgres | 14.x | brew (`postgresql@14`) |
| Redis | latest | brew |
| Rust | 1.89.0 | rustup (pinned) |
| Solana CLI | 3.1.x (Agave) | release.anza.xyz |
| Anchor | 0.32.1 | cargo |
| Bundler | 2.4.19 | auto-upgraded by Gemfile.lock |
| Heroku CLI | latest | brew |
| 1Password CLI | latest | brew |

---

## Appendix D — Cross-references

- `docs/agents/system/ecosystem-build.md` — the `bin/ecosystem-build` script reference (phases, when to run, idempotency, reset semantics)
- `docs/agents/agents/steffon/sops/chrome-profiles.md` — the operator's Chrome avatar-menu roster. NOT restored by `bin/ecosystem-build`: Chrome's profile state lives outside every backup this repo controls, so it is rebuilt from `config/chrome_profiles.yml` after you sign the accounts back in.
- `docs/agents/system/bootstrap.md` — first-time setup (one app, simpler)
- `docs/agents/modules/credentials.md` — credential rules and 1Password operating model
- `docs/agents/modules/credential-inventory.md` — known 1Password item names
- `docs/agents/system/news-pipeline.md` — News pipeline + X API setup
- `RUNBOOK.md` (top-level) — production troubleshooting (Heroku deploys, theme cache, SSO, OAuth)
- `turf-monster/docs/SOLANA.md` — Solana integration deep dive
- `turf-vault/README.md` — Anchor program structure + multisig
