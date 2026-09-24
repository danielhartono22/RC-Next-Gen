# Resource Collection on Vercel — deployment

Written for: the operator who deploys and rolls back the RC frontend.

## What is deployed

A static site. There is no server code on Vercel, no API route and no secret in the build.
`node scripts/build-rc-frontend.mjs` reads the legacy `index (4).html`, applies three
anchored edits inside its inline `<script>` block, and writes `public/`:

| Path | Source |
|---|---|
| `public/index.html` | `index (4).html` with its transport swapped |
| `public/assets/rc-legacy-adapter.js` | `scripts/rc-legacy-adapter.js` |
| `public/assets/rc-env.js` | `config/rc-env.js` |

The edits are split into two kinds, and the build keeps them apart on purpose.

**Transport** edits carry no visual change at all:

1. two `<script src>` tags are inserted before the inline script;
2. `fetchApp()` calls `window.RCBackend.call(bodyData)` instead of POSTing to Apps Script;
3. the login form calls the same adapter instead of POSTing to Apps Script.

**Sign-up** edits are new interface the owner asked for on 17 September 2026, and they do
change markup:

4. a "Belum punya akun? Daftar di sini" line under the login button;
5. the Daftar Akun Baru dialog, built from the same classes as the existing Ganti PIN dialog;
6. `openSignupModal()`, `closeSignupModal()` and `submitSignup()` in the inline script.

The added markup lives in one file, `scripts/rc-signup-ui.mjs`, so the build can subtract
exactly those blocks. It fails if any anchor does not match exactly once, and after removing
the injected script tags and the two sign-up blocks it requires the remaining markup to be
byte for byte the legacy page. A build that succeeds is therefore proof that nothing moved
except the enumerated additions. `npm run check` runs that verification without writing.

## Vercel settings

`vercel.json` pins the build so the dashboard cannot drift from the repository:

- build command `node scripts/build-rc-frontend.mjs`, output directory `public`, no install step
- `index.html` and `assets/rc-env.js` are served `no-store`, so flipping the backend flag
  takes effect on the next page load instead of waiting for a cached copy to expire
- security headers on every response, including `frame-ancestors 'none'`, which also
  prevents the Document Center from ever being re-added as an iframe
- `connect-src` allows only the Supabase project and the Apps Script host, so a script
  injected into the page cannot quietly post claim data somewhere else

The Content-Security-Policy still permits `'unsafe-inline'` and `'unsafe-eval'` for scripts.
That is not an oversight: the legacy page uses inline `onclick` attributes throughout and
loads the Tailwind CDN, which compiles styles in the browser. Tightening this requires
editing the markup, which the owner has excluded. Revisit it when the UI is next rebuilt.

## Live deployment

| | |
|---|---|
| URL | `https://rc-next-gen.vercel.app` |
| Project | `rc-next-gen` (`prj_weSJq2XwU4iP2R80EftJ85GXlbGr`) |
| Scope | team `niel17` |
| Protection | Vercel Authentication, `deploymentType: all` |
| Latest preview | `https://rc-next-1uh0cmbyx-niel17.vercel.app` (carries the sign-up portal) |

Both the project alias and the per-deployment URL answer `302` to an unauthenticated
request and redirect to the Vercel login. The page is only served to a signed-in member of
that Vercel team, and the application then still requires a Supabase sign-in.

Two things about this deployment need a decision.

**It is in the wrong account.** The Vercel CLI on this machine is signed in as
`01021282025121-8675`, whose only team is `niel17`. The Vercel connector used elsewhere in
this work points at the team `sales-analytics`, which is where an internal Nippon Paint
system belongs. Move the project, or add the CLI account to `sales-analytics` and redeploy
there, before anyone treats this URL as the real one.

**Protection was not on by default.** Vercel promoted the first deployment straight to
production and the project shipped with `all_except_custom_domains`, under which
`rc-next-gen.vercel.app` answered `200` to anybody. It was set to `all` immediately, but
check `ssoProtection` again after any project move or plan change rather than assuming it
carried over.

If a custom domain is attached later, `deploymentType: all` will keep Vercel Authentication
in front of that domain too. Decide deliberately at that point whether Supabase Auth alone
is the intended gate for real users.

**Do not publish a public URL with `dataBackend: 'apps_script'`.** In that mode the page
talks to the live Apps Script deployment, which authorises from browser-supplied identity.
A public URL in that mode is a second, unprotected entry point into the production claim
system. Use the fallback only behind deployment protection.

## Rollback

`config/rc-env.js` carries the flag required by section 13 of the migration instruction:

```js
dataBackend: 'supabase'      // target state
dataBackend: 'apps_script'   // fall back to the existing Apps Script deployment
```

Change the value, run the build, redeploy. The page then sends exactly the payloads it sent
before this migration, to the same deployment, including the legacy token field. Nothing
else needs to be reverted.

Rollback is only this simple while Supabase has not yet accepted writes. Once claims have
been submitted or processed through Supabase, follow the delta procedure in the migration
instruction rather than flipping the flag: export everything changed since cutover, reconcile
it into the spreadsheet, and only then move traffic. Never leave both backends writing.

## Environment values

`config/rc-env.js` holds the project URL and the publishable key. Both are public by design;
`supabase-js` sends the publishable key on every request and RLS does the access control. A
`service_role` or secret key in this file would be readable by every visitor and must never
appear there. Operator-only secrets belong in `.env`, which `.gitignore` excludes; see
`.env.example` for the names.

## Vercel toolbar

Preview deployments were injecting `https://vercel.live/_next-live/feedback/feedback.js` into
the page. On an internal claim system that is a third party script on a page that displays
customer data, and the Content-Security-Policy blocks it anyway, which only produces console
errors. `enablePreviewFeedback` and `enableProductionFeedback` are now both `false` on the
project. The preview currently deployed still contains the injected tag because it was built
before that change; the next deployment will not.

## Verified on the deployment

- the served preview matches the local build exactly apart from Vercel's injected toolbar
  tag, which is now disabled for future deployments;
- it contains both injected `<script src>` tags and two `window.RCBackend.call()` sites;
- it contains the sign-up dialog, its fields and its handlers, and the "Daftar di sini" link;
- it contains no remaining `fetch(SCRIPT_URL)` call;
- `Content-Security-Policy`, `X-Frame-Options: DENY`, `X-Content-Type-Options`,
  `Referrer-Policy` and `Permissions-Policy` are present on the page response;
- `/` and `/assets/rc-env.js` are served `no-store, must-revalidate`, so a rollback flip is
  picked up on the next load.

## Current state

The frontend build and the Vercel preview are done and verified. The production alias still
serves the build from before the sign-up portal was added, because promoting to production
was refused by this session's permission rules; run `npx vercel deploy --prod --scope niel17`
to promote the current build.

The Supabase side is not done. Neither
`supabase/migrations/20260917010000_rc_legacy_compat_api.sql` nor
`supabase/migrations/20260917020000_rc_auth_reset_and_signup.sql` has been applied, so both
signing in and signing up will fail until they are, and three Auth project settings must be
changed by hand first. See [rc-auth-signup.md](rc-auth-signup.md) and
[rc-migration-status-17-september-2026.md](rc-migration-status-17-september-2026.md).
