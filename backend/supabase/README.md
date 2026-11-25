# Scribe accounts backend (Supabase)

Scribe 0.7.3.2 adds an **optional** account: email + 6-digit code (no password), used to back up
and sync your Dictionary, Vocabulary, learned fixes, Styles and settings across Macs (and, only if
the user turns them on, People and voice profiles). The app works fully without it.

Everything synced is **end-to-end encrypted on the Mac** (CryptoKit AES-GCM, a 256-bit key per
account kept in the Mac's Keychain). This backend only ever stores ciphertext plus a few labels
(the item kind, a random per-Mac id, timestamps). Audio is never uploaded.

Until a project is configured, the app shows **"Accounts coming soon"** and makes no account calls.

## 1. Create the project

1. <https://supabase.com/dashboard> → **New project** (any region; the free tier is fine to start).
2. **SQL Editor** → paste and run `migrations/20261125000000_scribe_sync.sql`
   (or with the CLI: `supabase link --project-ref <ref>` then `supabase db push`).
   It creates `sync_items`, `sync_keys`, the `updated_at` trigger, row-level security
   (each user reads/writes only their own rows; signed-out requests get nothing) and
   `delete_my_account()`.

## 2. Email sign-in with a 6-digit code

1. **Authentication → Sign In / Providers → Email**: enable Email, keep **Confirm email** on.
   Set **Email OTP length** to **6** (the app asks for 6 digits) and an expiry (e.g. 600 s).
2. **Authentication → Email Templates → Magic Link** *and* **Confirm signup**: include the code,
   e.g.

   ```html
   <h2>Your Scribe code</h2>
   <p>Type this code in Scribe: <strong>{{ .Token }}</strong></p>
   <p>It expires in 10 minutes. If you didn't ask for it, ignore this email.</p>
   ```

   (Without `{{ .Token }}` Supabase sends a link instead of a code.)
3. **Authentication → SMTP Settings**: set up your own SMTP sender before launch. Supabase's
   built-in sender is rate-limited (a few emails per hour) and meant for testing only.
4. **Authentication → Rate Limits**: keep the OTP limits on (they stop code-guessing / spam).

## 3. Give the keys to the build

Project **Settings → API**: copy the **Project URL** and the **anon public** key.
(The anon key is public by design; it ships in every client. Never put the `service_role` key
anywhere in the app or the repo.)

In GitHub: **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
| --- | --- |
| `SUPABASE_URL` | `https://<ref>.supabase.co` |
| `SUPABASE_ANON_KEY` | the anon public key |

`scripts/build.sh` writes them into the built app's `Supabase.plist`. The committed
`Resources/Supabase.plist` keeps placeholders. For local development you can instead run the app
with `SCRIBE_SUPABASE_URL` and `SCRIBE_SUPABASE_ANON_KEY` in the environment.

## What the app calls

| Call | Purpose |
| --- | --- |
| `POST /auth/v1/otp` | email a 6-digit code (creates the user on first sign-in) |
| `POST /auth/v1/verify` (`type: email`) | code → session |
| `POST /auth/v1/token?grant_type=refresh_token` | refresh the session |
| `POST /auth/v1/logout` | sign out |
| `GET/POST/DELETE /rest/v1/sync_items` | download / upsert (`on_conflict=user_id,kind`) / remove opt-in kinds |
| `GET/POST /rest/v1/sync_keys` | the key check used to verify a recovery key |
| `POST /rest/v1/rpc/delete_my_account` | delete all cloud data + the sign-in account |

## Encryption model

- First Mac: a random 256-bit key is made, stored in the Keychain, and shown once as a
  **recovery key** (52 Crockford base-32 characters, groups of 4). The server gets only a
  "key check" (a fixed phrase sealed with the key).
- Each item: `"v1." + base64(nonce ‖ ciphertext ‖ tag)`, AES-GCM, with
  `scribe-sync-v1|<user id>|<kind>` as associated data.
- Another Mac (or after a reinstall): the user types the recovery key; it must open the key check.
- **Lost recovery key = the backup can't be read** (by design; nobody can reset it). The user can
  delete the account and start again from any Mac that still has its data.

## Checklist before turning it on

- [ ] Migration run; RLS shows **enabled** on both tables in Table Editor.
- [ ] Email OTP length 6, templates show `{{ .Token }}`, custom SMTP set.
- [ ] `SUPABASE_URL` / `SUPABASE_ANON_KEY` secrets set; a build log says
      "Accounts: Supabase URL + anon key set from the build environment".
- [ ] Privacy policy updated: what's stored (ciphertext, email, timestamps), voiceprints are
      opt-in biometric data, how to delete (Profile → Delete account and cloud data).
- [ ] Sign in on two Macs with a test address; Sync now on both; delete the account.
