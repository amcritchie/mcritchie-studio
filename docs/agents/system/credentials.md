# Credentials

> **Restoring credentials on a fresh Mac?** `bin/ecosystem-build` does this automatically: it pulls `RAILS_MASTER_KEY` and other env vars from `heroku config` and `SOLANA_ADMIN_KEY` from 1Password (`agent.alex.solana`), then writes `.env` for both Rails apps. See [house-burn-down.md](house-burn-down.md). This doc is legacy system context while the neutral modules in `docs/agents/modules/` become canonical.

## Environment Variables

All sensitive credentials are stored as environment variables, never in code.

### Required
- `DATABASE_URL` — PostgreSQL connection string (production only)

### Optional
- `GOOGLE_CLIENT_ID` — Google OAuth client ID
- `GOOGLE_CLIENT_SECRET` — Google OAuth client secret
- `RAILS_MASTER_KEY` — Rails encrypted credentials key
- `SOLANA_ADMIN_KEY` — Alex Bot's Solana private key (base58), used by Turf Monster for onchain operations
- `ANTHROPIC_API_KEY` — Claude API key for AI chat (McRitchie Studio)
- `X_BEARER_TOKEN` — X (Twitter) API bearer token for News intake (McRitchie Studio). See `docs/agents/system/news-pipeline.md` for setup.

## Development Defaults

- Database: `mcritchie_studio_development` (local PostgreSQL, no password)
- Admin login: `alex@mcritchie.studio`; sign in by magic link in normal local development.
- API: No authentication required (add token auth later)

## Agent Email Accounts

All agents share a primary Gmail account and have individual forwarding addresses on the `mcritchie.studio` domain.

### Shared Account
- **Email**: `team@mcritchie.studio` — shared Gmail account used by all agents
- **1Password**: Credentials stored in the `alex@mcritchie.studio` 1Password account

### Per-Agent Forwarding Addresses
Each agent has a dedicated email that forwards to the shared `team@mcritchie.studio`
inbox — **except Turf Monster**, which is a real Google user on its own domain (see the
note under the table):

| Agent | Email | Purpose |
|-------|-------|---------|
| Alex | `admin@mcritchie.studio` | Orchestrator, admin notifications |
| Avi | `avi@mcritchie.studio` | Product Owner — PR review, release sign-off, ticket grooming |
| Carl | `carl@mcritchie.studio` | Dev Backend Expert — Rails, ActiveRecord, jobs |
| Shannon | `shannon@mcritchie.studio` | Dev UI Expert — frontend, Tailwind, Alpine, theme |
| Jasper | `jasper@mcritchie.studio` | Dev Blockchain Expert — turf-vault, solana-studio, Phantom |
| Steffon | `steffon@mcritchie.studio` | Infrastructure Expert — Heroku, deploys, CI, OPSEC |
| Turf Monster | `team@turfmonster.media` | Sports data, Turf Monster app notifications — **own domain, not a forwarder** |
| Mack | `mack@mcritchie.studio` | Worker agent comms — scraping, processing, bulk ops |
| Mason | `mason@mcritchie.studio` | Marketing — brand voice, launch comms, social, funnels (was Infrastructure pre 2026-05-23 — see `mission.md`) |

> The 5 new agents (Avi/Carl/Shannon/Jasper/Steffon) were added 2026-05-23 alongside Mason's
> pivot from Infrastructure to Marketing; persona definitions live at `docs/agents/agents/<slug>/`.
> The forwarding addresses now EXIST as Google Groups on `mcritchie.studio`, each redirecting
> into the shared `team@mcritchie.studio` inbox — so every soul reads the same mailbox and the
> per-agent address is an addressing convention, not a separate account to sign in to.
>
> **Turf Monster is the exception, as of 2026-09-04.** `turf@mcritchie.studio` was a group with
> zero members and is being deleted; the soul now uses `team@turfmonster.media`, a real Google
> user on Turf's own domain (1Password `google.turf.agents`). It is the one agent address that is
> NOT a redirect into the studio inbox.
>
> These addresses are also seeded as app accounts — `User::PARKED_IDENTITIES` in
> mcritchie-studio and turf-monster is the source of truth for which of them hold `admin`.
> `admin@mcritchie.studio` is the super-admin seat shared by Alex and Steffon, and carries no
> Solana wallet on purpose.
>
> **Editing that list does not change an account that already exists.** The roster is read
> on SAVE (`assign_parked_identity`), and a release saves nothing — so a demotion waits for
> its owner to sign in, which for a shared house account may be never. Measured: mack@ stayed
> an admin in production for twenty-one days after the roster made him a viewer. A role or
> name change to a deployed seat rides a data migration (see
> `db/migrate/20260904190000_rename_turf_house_identity.rb`); the seed carries it for local,
> test, and QA.

## Solana Wallets

Each agent has a dedicated Solana wallet. Credentials stored in 1Password. The three vault-admin identities below (Alex Bot, Alex Human, Mason) are **the same keys on devnet and mainnet** — verified 2026-09-05 as the `VaultState.signers` set on both clusters — so a rotation of any of them is a mainnet event, not a devnet one. The other rows were not part of that verification: check the cluster before assuming any of them is devnet-only.

### Wallet Addresses

| Agent | Address | Role |
|-------|---------|------|
| Alex Bot | `8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd` | Rotated vault admin (signs routine onchain ops) |
| Alex Human | `7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr` | Backup vault admin (recovery only) |
| Mason | `CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR` | Vault signer (third 2-of-3 cosigner) |
| Mack | `foUuRyeibadQoGdKXZ9pBGDqmkb1jY1jYsu8dZ29nds` | Agent wallet |
| Turf Monster | `BLSBw8fXHzZc5pbaYCKMpMSsrtXBTbWXpUPVzMrXx9oo` | Agent wallet |

### 1Password CLI Access

Wallet credentials are stored in the `alex@mcritchie.studio` 1Password account. Use the CLI to retrieve them programmatically.

There are **two access modes** — agent sessions use the service account, humans use the desktop-app integration:

#### Agent sessions: service-account access (canonical pattern — read this first)

Claude/agent sessions are already authenticated: a 1Password **service account** token lives in `~/.zprofile` (`OP_SERVICE_ACCOUNT_TOKEN`, installed by `mcritchie-studio/bin/setup-1pass-token`), and agent shells initialize from the profile. Verify with `/opt/homebrew/bin/op whoami` (expect `User Type: SERVICE_ACCOUNT`). No `--account` flag, no biometric prompt, no token-sourcing preamble needed.

- **Scope**: the service account sees only the **agents** vault. Anything agents need must be stored there (`agent.*` naming convention, or product items like `Coinbase Developer Platform`).
- **Always invoke by full path** — `/opt/homebrew/bin/op read|item|vault …`. The session permission allow-rules match these full-path prefixes. Prefixing commands with `eval`/`export` token-sourcing, or running broad vault scans/listing hunts, trips the permission classifier as "credential exploration" and gets blocked.
- **Never print secrets.** Pull secret fields clipboard-only and consume from there; print only non-secret fields (key IDs, addresses, usernames). Avoid `op item get --format json` on items with secret fields — it dumps the secret into the session transcript.

Worked example (CDP key → turf-monster `.env`):
```bash
cd ~/projects/turf-monster && bin/setup-cdp-key   # no args → reads the key from 1Password (op://<agent-vault>/Coinbase Developer Platform) → writes .env, never echoes the secret
```
`bin/setup-cdp-key` defaults to a 1Password pull (PR #144); `--clipboard` (full JSON blob) and `bin/setup-cdp-key <key-id>` (secret in clipboard) remain as first-time/fallback modes.

- **Hard boundaries — don't fight them**: agent sessions cannot scan vaults for credentials they weren't pointed at, and cannot edit `.claude/settings*.json` to self-grant access. Targeted reads of operator-named items via the allowed full-path commands are the sanctioned path. (Codified 2026-06-09 after the CDP key retrieval hit both walls.)

#### Human/desktop access

**Prerequisites**: Install `brew install 1password-cli`, then enable "Integrate with 1Password CLI" in 1Password desktop app (Settings > Developer).

**Account ID**: `MWOV5OT5BRHATI4EGMN26C5DPA`

**Vault layout**:
- `studio-agents` — All agent wallet credentials (renamed from "🦞 Bots" 2026-05-03, and from `agents` 2026-08-28)
- `🧱 Blockchain` — General blockchain credentials

**Retrieve a wallet's private key** (items renamed 2026-05-03 to `agent.*` convention):
```bash
# Alex Bot
op item get "agent.alex.solana" --vault "studio-agents" --account MWOV5OT5BRHATI4EGMN26C5DPA --fields "private key"

# Mason
op item get "agent.mason.solana" --vault "studio-agents" --account MWOV5OT5BRHATI4EGMN26C5DPA --fields "private key"

# Mack
op item get "agent.mack.solana" --vault "studio-agents" --account MWOV5OT5BRHATI4EGMN26C5DPA --fields "private key"

# Turf Monster
op item get "agent.turf.solana" --vault "studio-agents" --account MWOV5OT5BRHATI4EGMN26C5DPA --fields "private key"
```

**Set as env var (one-liner)**:
```bash
export SOLANA_ADMIN_KEY=$(op item get "agent.alex.solana" --vault "studio-agents" --account MWOV5OT5BRHATI4EGMN26C5DPA --fields "private key")
```

**Item fields**: Each wallet entry contains `recovery phrase`, `private key` (base58), and `wallet address` (base58 public key).

### Onchain Admin

Alex Bot is the primary admin for routine TurfVault operations. Mr. McRitchie is the backup/admin cosigner. Deployment identity for both clusters lives in `turf-vault/docs/CURRENT_DEPLOYMENT.md`: each of its `## Devnet` and `## Mainnet` tables carries that cluster's program ID, Squads upgrade authority, threshold and three signer rows. **Read the heading you mean** — the two signer sets happen to agree today, but nothing in the program ties them together, so an address alone cannot tell you which cluster you are on. `turf-vault/scripts/squad.json` (`members`) is provenance and a script input — `scripts/initialize-mainnet.js` builds its `initialize` signer array from it — not the deployment record. Confirm the live set on-chain from `VaultState` (`seeds = [b"vault"]` against that cluster's program ID) rather than from any file. The `SOLANA_ADMIN_KEY` env var in Turf Monster's `.env` holds the Alex Bot private key from `agent.alex.solana`.

## AWS — S3 + Amazon SES

Credential names and provider status now live in the modular docs:

- Shared credential inventory: [`../modules/credential-inventory.md`](../modules/credential-inventory.md)
- Shared email operations: [`../modules/email-operations.md`](../modules/email-operations.md)
- McRitchie-specific delivery notes: `docs/email-delivery.md` (outside the docs viewer's root, so not a link)

Do not duplicate SES production status here; it changes as AWS support,
DNS verification, and runtime SMTP credentials move.

## Security Notes

- Never commit `.env` files or credential files
- API is currently open (no auth) — suitable for local/trusted networks only
- Google OAuth credentials must be configured per environment
- Password hashing uses bcrypt via `has_secure_password`
- 1Password CLI: human/desktop mode requires biometric or password auth on each use; agent sessions use scoped service-account tokens — the agent lane sees the agent vault, the ship lane's separate token sees the admin vault (see `bin/lib/op_vaults.rb`) — credentials are never cached in plaintext either way
- Private keys should only be stored in 1Password and `.env` files (gitignored), never in code or commits
