# Secrets Rotation Runbook

> **When to read this:** A token/key/secret needs to be rotated — scheduled, compromised, or expiring. Each section is a self-contained procedure: where the secret is stored, how to regenerate it at the source, how to push the new value to every consumer, how to verify the rotation succeeded.

The 1Password account is `alex@mcritchie.studio` (account ID `MWOV5OT5BRHATI4EGMN26C5DPA`), vaults `studio-agents` (agent lane) and `studio-agents-admin` (ship lane — separate service account, `bin/setup-1pass-token --admin`). Heroku apps are `mcritchie-studio` and `turf-monster-mainnet`. After every rotation, re-run `bin/ecosystem-build` so the dev `.env` files refresh from Heroku's new config.

---

## 1Password service account token

**Store:** the macOS dev shell only (`~/.zprofile`, `OP_SERVICE_ACCOUNT_TOKEN`). Never in Heroku — it's the bootstrap secret, not a runtime one.

**Symptoms of rotation needed:** `op vault list` returns 401 / "service account token revoked." Token compromise (committed to a repo, screenshotted, etc.).

**Procedure:**
1. https://start.1password.com → Developer Tools → Service Accounts.
2. Find the existing service account row. Click "Rotate token" (or delete + recreate with read on `studio-agents`). The admin token is a second, separate service account with read on `studio-agents-admin` — rotate it the same way and install it with `bin/setup-1pass-token --admin`.
3. Copy the new `ops_...` token to clipboard.
4. From `~/projects/mcritchie-studio`: `bin/setup-1pass-token`. The script reads from `pbpaste`, validates the prefix, replaces the existing line in `~/.zprofile`, chmods 600, and verifies with `op vault list`.
5. `source ~/.zprofile` (or open a new terminal).

**Verify:** `op vault list` lists `studio-agents`. `bin/ecosystem-build` reaches Phase 4 cleanly.

---

## Heroku API key (`HEROKU_API_KEY`)

**Store:** 1Password item `heroku.studio.agents` in `studio-agents`. Pre-cutover the fleet key is the `legacy-personal-api-key` field (delete it at the app-transfer cutover); after, the lane's `credential` field. `bin/ecosystem-build` Phase 4 reads legacy-first with the same fallback, then writes `~/.zprofile`.

**Symptoms of rotation needed:** `heroku auth:whoami` returns 401. Heroku-side suspicion of compromise.

**Procedure:**
1. Mint the replacement lane (admin profile): `heroku authorizations:create -s identity,read-protected,write-protected -d "heroku.studio.agents" -S` → the `HRKU-...` token.
2. Update 1Password → `heroku.studio.agents` → the active key field (`legacy-personal-api-key` pre-cutover, `credential` after) → paste the new token; update `authorization-id`. Save.
3. Remove the old `HEROKU_API_KEY` line from `~/.zprofile`: `sed -i '' '/HEROKU_API_KEY/d' ~/.zprofile`.
4. Re-run `bin/ecosystem-build` — Phase 4 re-fetches `heroku.studio.agents` from 1P, writes the new key to `~/.zprofile`, and `heroku auth:whoami` against it.
5. Revoke the old token: `heroku authorizations` to list, then `heroku authorizations:revoke <id>` for the old one.

**Verify:** `heroku auth:whoami` returns `alex@mcritchie.studio`. `heroku apps` lists both apps.

---

## Rails `RAILS_MASTER_KEY`

**Store:** Heroku config var on both apps + `config/master.key` (gitignored) locally + 1Password (recommended backup).

**Symptoms of rotation needed:** master key compromise (committed accidentally, leaked from CI logs, etc.). This is the single most disruptive secret to rotate because it decrypts `config/credentials.yml.enc` AND derives the session-cookie signing secret — rotating it logs out every user and requires re-encrypting credentials.

**Procedure (per app — do each Rails app separately):**
1. Edit `config/credentials.yml.enc` with the *current* key: `EDITOR='code --wait' bin/rails credentials:edit`.
2. Save all credentials to a scratch file outside the repo (you'll need to re-add them after rotation).
3. Delete `config/credentials.yml.enc` and `config/master.key`.
4. Regenerate: `EDITOR='code --wait' bin/rails credentials:edit` — Rails creates a fresh `master.key` + empty `credentials.yml.enc`.
5. Paste your scratch-file credentials back into the editor. Save.
6. Capture the new master key: `cat config/master.key`.
7. `heroku config:set RAILS_MASTER_KEY=<new_key> --app mcritchie-studio` (or `--app turf-monster-mainnet`).
8. Update the matching 1Password item (recommended naming: `mcritchie.studio/RAILS_MASTER_KEY`, `turf-monster/RAILS_MASTER_KEY`).
9. Update local `.env`: `sed -i '' '/^RAILS_MASTER_KEY=/d' .env && echo "RAILS_MASTER_KEY=<new_key>" >> .env`.
10. Commit `config/credentials.yml.enc` to the repo. Push.

**Verify:** App boots locally (`bin/rails server`). `heroku logs --tail --app <app>` after a deploy shows no `:secret_key_base` errors. Direct login still works in each app.

**Warning:** Rotating session secrets logs users out. Apps that opt into shared SSO need compatible secrets; Turf Monster currently isolates its money-app cookie and uses direct login.

---

## Managed-wallet encryption key (`MANAGED_WALLET_ENCRYPTION_KEY`)

**Store:** 1Password item `agent.managed_wallet` (field `encryption key`) + Heroku config on `turf-monster-mainnet` + `.env` locally. Shipped as OPSEC-015 (`KeyGenerator`-derived KDF for managed-wallet keypair encryption).

**What it does:** Every managed wallet (`web2_solana_address`) has its Ed25519 secret encrypted at rest with a key derived from `MANAGED_WALLET_ENCRYPTION_KEY` via `ActiveSupport::KeyGenerator`. Rotating the key requires re-encrypting every managed-wallet secret column — a controlled, online operation but disruptive enough to be its own runbook.

**Symptoms of rotation needed:** Suspected key compromise (committed accidentally, leaked from logs). Routine quarterly hygiene tied to the Solana admin-key cadence. Required after any incident affecting the `RAILS_MASTER_KEY` (which seeds the key derivation salt).

**Procedure (turf-monster only — managed wallets don't exist in mcritchie-studio):**
1. Generate a fresh 32-byte key: `bin/rails runner 'puts SecureRandom.hex(32)'`. Copy the value.
2. Update 1Password `agent.managed_wallet` → field `encryption key` → paste the new value. Save.
3. Set the new key on Heroku as `MANAGED_WALLET_ENCRYPTION_KEY_NEW` (NOT yet replacing the live one):
   ```bash
   heroku config:set MANAGED_WALLET_ENCRYPTION_KEY_NEW=<new_value> --app turf-monster-mainnet
   ```
4. Run the reencrypt rake task — this reads each `User.web2_solana_address` row, decrypts with the OLD key, re-encrypts with the NEW key, and writes the row back. Runs in batches with a row-lock per user:
   ```bash
   heroku run --app turf-monster-mainnet bin/rails managed_wallets:reencrypt
   ```
   The task is idempotent — safe to re-run if it crashes mid-stream. It tracks progress in `OutboundRequest`-style audit rows.
5. Promote the new key to primary on Heroku (atomic swap):
   ```bash
   heroku config:set MANAGED_WALLET_ENCRYPTION_KEY=<new_value> --app turf-monster-mainnet
   heroku config:unset MANAGED_WALLET_ENCRYPTION_KEY_NEW --app turf-monster-mainnet
   ```
6. Restart dynos: `heroku ps:restart --app turf-monster-mainnet`.
7. Update dev `.env` files via `bin/ecosystem-build` (re-fetches from Heroku).
8. Verify a managed-wallet user can sign a transaction (a contest entry, faucet claim, or any flow that exercises `User#solana_keypair`).

**Verify:** `heroku run --app turf-monster-mainnet bin/rails runner 'puts User.where.not(web2_solana_secret_encrypted: nil).first.solana_keypair.address'` returns the correct base58 address (no decrypt errors). A test contest entry from a managed wallet completes.

**Last rotation (2026-05-20, prod v80):** Reencrypt ran clean against ~all managed-wallet users. Memory ref: `project_managed_wallet_encryption_key`.

**Warning:** If `MANAGED_WALLET_ENCRYPTION_KEY` is lost while the wallets are still in use, every managed wallet becomes unrecoverable. Treat it with the same care as `RAILS_MASTER_KEY` — 1Password + cold backup.

---

## Solana admin key (`SOLANA_ADMIN_KEY` / `agent.alex.solana`)

**Store:** 1Password item `agent.alex.solana` (field `private key`, base58-encoded Ed25519 secret) + Heroku config on `turf-monster-mainnet` + `.env` locally.

**Symptoms of rotation needed:** Suspected wallet compromise. Routine quarterly hygiene. Adding/removing a multisig signer.

**Procedure:**
1. Generate a new keypair: `solana-keygen new --no-bip39-passphrase --silent --outfile /tmp/new-admin.json`.
2. Get the base58 secret: `cat /tmp/new-admin.json | jq -r '. | map(.) | @json'` (the JSON array IS the secret), then convert with `bin/rails runner "puts Solana::Keypair.from_bytes(JSON.parse(File.read('/tmp/new-admin.json'))).secret_key_base58"`.
3. Get the public address: `solana-keygen pubkey /tmp/new-admin.json`.
4. **Before rotating**, run the on-chain `update_signers` instruction to swap the new pubkey into `VaultState.signers`. This requires 2-of-3 cosign. **Confirm the signer set for the cluster you are rotating** — this procedure ends on `turf-monster-mainnet` (step 6), so assume mainnet unless you have checked. `turf-vault/docs/CURRENT_DEPLOYMENT.md` records the program ID, upgrade authority, threshold and signer set for each cluster under its own heading — read `## Mainnet`, not `## Devnet`. (`turf-vault/scripts/squad.json`'s `members` is what `scripts/initialize-mainnet.js` builds its `initialize` signer array from; it is a script input and the historical record, not the deployment record.) Verify live truth on-chain before signing: `solana program show <PROGRAM_ID> --url <mainnet-beta|devnet>` for the upgrade authority, then read `VaultState` (`seeds = [b"vault"]` against that program ID) for the signers and threshold. `turf-vault/docs/KEY_ROTATION.md` is a SUPERSEDED plan — read it for background, never as the procedure.
5. Update 1Password `agent.alex.solana` -> field `private key` -> paste the new base58 secret. Save.
6. `heroku config:set SOLANA_ADMIN_KEY=<new_base58> --app turf-monster-mainnet`.
7. Re-run `bin/ecosystem-build` → Phase 4 re-fetches from 1P and writes to local `.env`.
8. Securely delete `/tmp/new-admin.json` (it contains the unencrypted secret).
9. After 24-48h of confirmed normal operation, run `update_signers` again to remove the *old* pubkey from `VaultState.signers`.

**Verify:** `bin/rails runner 'puts Solana::Keypair.from_base58(ENV["SOLANA_ADMIN_KEY"]).address'` matches the new pubkey. A test contest settlement completes successfully (admin signs as `admin`, human cosigns).

---

## Anthropic API key (`ANTHROPIC_API_KEY`)

**Store:** 1Password item `anthropic` + Heroku config on `mcritchie-studio` + `.env` locally.

**Symptoms of rotation needed:** Suspected compromise. Anthropic console shows unusual usage. Quarterly hygiene.

**Procedure:**
1. https://console.anthropic.com → Settings → API Keys → "Create Key" (name it e.g. `mcritchie-studio-2026-Q2`).
2. Copy the `sk-ant-api...` value (only shown once).
3. Update 1Password `anthropic` → field `api key` → paste the new value. Save.
4. `heroku config:set ANTHROPIC_API_KEY=<new_value> --app mcritchie-studio`.
5. Re-run `bin/ecosystem-build`.
6. After 24h of confirmed normal operation, revoke the old key in the Anthropic console.

**Verify:** `bin/rails runner 'require "net/http"; r = Net::HTTP.post(URI("https://api.anthropic.com/v1/messages"), {model: "claude-haiku-4-5-20251001", max_tokens: 10, messages: [{role: "user", content: "ping"}]}.to_json, "x-api-key" => ENV["ANTHROPIC_API_KEY"], "anthropic-version" => "2023-06-01", "content-type" => "application/json"); puts r.code'` returns `200`.

---

## X (Twitter) API credentials

**Store:** 1Password item `x.api` (5 fields: bearer, api_key, api_secret, access_token, access_token_secret) + Heroku config on `mcritchie-studio` + `.env` locally.

**Symptoms of rotation needed:** X suspends the app and reissues. Quarterly hygiene.

**The 5 vars:**
- `X_BEARER_TOKEN` — read-only (News intake)
- `X_API_KEY`, `X_API_SECRET` — OAuth 1.0a app credentials (write, for `X::PostMedia`)
- `X_ACCESS_TOKEN`, `X_ACCESS_TOKEN_SECRET` — OAuth 1.0a user credentials (for posting as @turfmonstershow)

**Procedure:**
1. https://developer.x.com/en/portal/projects → the `mcritchie-studio` project → app keys & tokens.
2. For each of the 5 values, click "Regenerate" → copy → save to 1Password `x.api`.
3. The app MUST have "Read and Write" permission — verify on the User authentication settings page. If not, the post will silently 401.
4. `heroku config:set X_BEARER_TOKEN=... X_API_KEY=... X_API_SECRET=... X_ACCESS_TOKEN=... X_ACCESS_TOKEN_SECRET=... --app mcritchie-studio`.
5. Re-run `bin/ecosystem-build`.

**Verify:** `bin/rails news:intake` succeeds (uses bearer). For write creds, post a test Content via `Content::PostToX` against a draft contest, then delete the tweet.

---

## Higgsfield API credentials (`HIGGSFIELD_API_KEY` + `HIGGSFIELD_API_SECRET`)

**Store:** 1Password item `agent.higgesfield` (note the typo — preserved historically) + Heroku config on `mcritchie-studio` + `.env` locally.

**Procedure:**
1. Higgsfield dashboard → API keys → regenerate.
2. Copy both `hf-api-key` and `hf-secret` values.
3. Update 1Password `agent.higgesfield`.
4. `heroku config:set HIGGSFIELD_API_KEY=... HIGGSFIELD_API_SECRET=... --app mcritchie-studio`.
5. Re-run `bin/ecosystem-build`.

**Verify:** `bin/rails content:assets_agent SLUG=<a-content-slug>` completes successfully.

---

## TikTok credentials (`TIKTOK_CLIENT_KEY/SECRET/REFRESH_TOKEN/OPEN_ID`)

**Store:** 1Password item `🐊 TikTok` (4 fields) + Heroku config on `mcritchie-studio` + `.env` locally.

**Refresh token rotates roughly every 1 year, but use shortens it.** Watch for `invalid_grant` errors from `Tiktok::OAuthClient`.

**Procedure (client key/secret — app-level, rarely changes):**
1. https://developers.tiktok.com → your app → App information → regenerate Client Secret.
2. Update 1Password `🐊 TikTok` fields `client key`, `client secret`.
3. `heroku config:set TIKTOK_CLIENT_KEY=... TIKTOK_CLIENT_SECRET=... --app mcritchie-studio`.

**Procedure (refresh token + open_id — user-level, rotates with re-auth):**
1. Visit `https://app.mcritchie.studio/admin/tiktok/connect` (admin-only).
2. Authenticate as @turfmonstershow.
3. The success page displays a fresh `TIKTOK_REFRESH_TOKEN` and `TIKTOK_OPEN_ID`. Copy both.
4. Update 1Password `🐊 TikTok` fields `refresh token`, `open id`.
5. `heroku config:set TIKTOK_REFRESH_TOKEN=... TIKTOK_OPEN_ID=... --app mcritchie-studio`.
6. Re-run `bin/ecosystem-build`.

**Verify:** `bin/rails runner 'puts Tiktok::OAuthClient.new.access_token.present?'` returns `true`.

---

## AWS S3 credentials (`AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`)

**Store:** Per-app `.env` files + per-app Heroku config + 1Password.

**Procedure:**
1. https://console.aws.amazon.com → IAM → Users → the `studio` user → Security credentials → Create access key.
2. Copy both values.
3. Update 1Password (recommended item name: `aws.studio`).
4. `heroku config:set AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... --app mcritchie-studio` (repeat for `turf-monster-mainnet`).
5. Update each app-local `.env` that uses S3.
6. Re-run `bin/ecosystem-build` (writes to per-app `.env` from Heroku).
7. After 24h of confirmed normal operation, deactivate the old key in IAM.

**Verify:** `bin/rails runner 'puts Studio::S3.list(prefix: "headshots").first(3).inspect'` returns S3 keys without errors.

---

## Google OAuth (`GOOGLE_CLIENT_ID` + `GOOGLE_CLIENT_SECRET`)

**Store:** Per-app Heroku config + 1Password.

**Procedure:**
1. https://console.cloud.google.com → APIs & Services → Credentials → your OAuth 2.0 Client.
2. Click "Reset Secret" — confirm.
3. Copy the new client secret. (Client ID does NOT change on reset.)
4. Update 1Password.
5. `heroku config:set GOOGLE_CLIENT_SECRET=... --app mcritchie-studio` (and `--app turf-monster-mainnet` if they share — currently they have separate OAuth clients).
6. Re-run `bin/ecosystem-build`.

**Verify:** Sign in via Google on each app.

**Note:** Google OAuth tokens (the access/refresh tokens per user) are NOT rotated as part of this — those live in `users.uid` and re-issue automatically on next sign-in. This procedure rotates only the *app-level* client secret.

---

## Quick reference: the rotation cadence

| Secret | Recommended rotation | Trigger |
|--------|---------------------|---------|
| 1P service token | yearly + on compromise | Hygiene |
| Heroku API key | yearly | Hygiene |
| `RAILS_MASTER_KEY` | **only on compromise** — disruptive (rotates session signing key) | Compromise only |
| `SOLANA_ADMIN_KEY` | quarterly + on suspicion | Pre-mainnet |
| Anthropic API key | quarterly | Hygiene |
| X API credentials | yearly | Hygiene |
| Higgsfield | yearly | Hygiene |
| TikTok client secret | yearly | Hygiene |
| TikTok refresh token | on `invalid_grant` (1y default) | Auth error |
| AWS S3 keys | quarterly | Hygiene |
| Google OAuth client secret | yearly | Hygiene |

Add a calendar reminder for the quarterly cycle so this doesn't slip.

---

## When this runbook is wrong

If a procedure here doesn't match the current code path (e.g. an env-var name has changed), fix this doc as part of whatever PR introduced the drift. Code is source of truth; this doc is the recovery layer.
