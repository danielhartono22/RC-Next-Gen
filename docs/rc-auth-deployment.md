# RC DEV user-ID authentication

## Implemented

Migration `20260915064525_rc_userid_auth_password_gate` is applied to DEV `vvojshgcduqlugngpzkj`.

- Imported 63 Auth users and corresponding email identities/profiles; 62 active, 1 suspended/banned.
- User ID remains the login identifier. Internally, SHA-256 of the trimmed, case-sensitive user ID forms an address at `rc-login.invalid`. Business emails remain in profiles; shared business emails do not merge identities.
- Password/PIN is trimmed consistently with the legacy frontend and bcrypt-hashed locally at cost 12 before import. Plaintext PIN is not transferred to MCP, written to repository files, or included in reports. This one-time hash import used SQL against the inspected Auth schema; no Auth accounts existed beforehand. It must not be repeated over accounts with changed passwords.
- Native Supabase Auth performs password verification and issues sessions. No custom JWT signing or exposed password-check RPC exists.
- Profiles start with `must_change_password=true`; depot/customer data and permission assignments remain unavailable until the Auth password-update trigger clears this flag. Active owners can read their own profile to see that a change is required.
- System Manager access maps to all known depots, matching the legacy rule. Other accounts receive only exact Authority depot matches. No scope is inferred from emails or requested browser roles. Missing mappings need operator review.
- No invitations or reset emails were sent. Internal login addresses cannot receive email; recovery requires an administrator to verify the person and reset their account through a controlled process. Shared business emails must not be used as automatic account-recovery identities.

## Frontend and current limitation

Update: owner supplied the publishable key; it is now set in `config/rc-auth-dev.js`. An HTTPS request to `/auth/v1/settings` with this key returned HTTP 200. Key configuration is resolved. This check does not verify user sign-in or password change; those remain to be tested.

`rc-auth-dev.html` provides user ID/password login, password change, logout and scoped depot display using Supabase JS v2. Sessions remain in memory. This is a DEV authentication screen, not the full RC application. Original `index (4).html` still uses Apps Script because its workflow endpoints and bootstrap have not been ported. Supabase JWTs are not sent to legacy Apps Script as if they were legacy tokens.

`config/rc-auth-dev.js` needs a public publishable key. MCP `get_publishable_keys` returned `Insufficient scope`; the key was not obtained through another credential path. Set only a publishable/anon key here, never service_role or secret. Serve the repository over localhost HTTP or HTTPS; do not open the module page using file://.

After key configuration, test an active user with their old password, the required password change, depot scope, logout, wrong password, and suspended account denial. Native Auth rate limiting applies; project-specific limits and password-strength settings still need verification. HTTP sign-in, browser rendering, password update through Auth, recovery and token refresh have not yet been tested. Database checks do not substitute for these tests.

## Gross-up

`public.rc_gross_up_legacy(net numeric, subject text)` reproduces `ResourceCollection.calcGrossUpCB`, including the Badan 15% calculation and progressive branches. It uses numeric division without adding rounding. Only service_role can execute it until a scoped submit transaction calls it. This function is not yet connected to submit and has not backfilled historical blank AK values. It implements source-code parity, not a new determination of applicable tax law.

## Verification completed

- `node --check scripts/rc-auth-dev.mjs`: pass.
- `supabase/tests/rc_auth_gate.sql` via MCP, rolled back: password-change gate, trigger and gross-up boundary checks pass.
- `supabase/tests/rc_master_access.sql` via MCP, rolled back: depot/customer scope, mutation denial, inactive account and anonymous access checks pass.
- After tests: 63 real profiles, 62 active, all 63 still requiring password change. Synthetic accounts were rolled back.

References: [Supabase password hashing](https://supabase.com/docs/guides/auth/password-security), [Auth migration and identities](https://supabase.com/docs/guides/platform/migrating-to-supabase/auth0).
