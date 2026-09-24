# RC DEV migration progress — 15 September 2026

## Applied through MCP

### Auth implementation update

Owner approved user ID plus legacy password login. 63 native Supabase Auth users/identities and profiles are now imported from locally generated bcrypt hashes (62 active, 1 suspended). Shared business-email blocker is resolved through deterministic internal login addresses. First-password-change access gating and gross-up legacy function are deployed and database-tested. Full RC cutover remains incomplete; browser sign-in awaits publishable key, and workflow endpoints are not ported. See [rc-auth-deployment.md](rc-auth-deployment.md), which supersedes earlier statements below that no Auth users exist.

### Corrected source intake — latest update

Found `D:\DANIEL\data-rc\Authority\Authority.csv` (63 rows) and corrected `D:\DANIEL\data-rc\Compile.csv` (2,773 rows). Imported Compile as a new snapshot through MCP, preserving the earlier snapshot. The new file changes multiple columns, including dates and identifiers; no old snapshot was overwritten. Its AK header is `Gross UP`, with all 2,773 AK cells blank. Candidates now expose blank AK as NULL, never zero; AL remains unused.

Authority was projected through an explicit allowlist before transfer: user code, source record, name, email, role, activation, depot, suffix and RC permission flags. Neither Pin nor Ganti Pin Req was retrieved into tool output or imported. The 63 records are in private `staging.rc_authority_review`, not auth.users. There are 42 unique normalized emails (21 additional occurrences); resolve shared emails before provisioning one Auth account per legacy user. No invitation emails were sent.

Migration `20260915055416_rc_corrected_compile_authority_review` applied via MCP. Check queries: [rc_authority_review.sql](../supabase/queries/rc_authority_review.sql). The original header/value and missing-Authority findings below are historical and superseded by this update. Gross-up calculation/blank handling and shared-email identity decisions remain necessary before full activation.

### Owner correction and follow-up

- Owner confirms AK is gross-up; its CSV header DMD30 USED is obsolete. AL is unused. The previous uncertainty about which column to use is resolved.
- `ListCampaign.csv` is imported via MCP as 100 source records and 100 rows in `public.campaigns`. Period values remain text pending date validation. No automatic browser access to the campaign table has been granted.
- Migration `20260915032700_rc_campaign_and_confirmed_mapping` adds `public.rc_claims_migration_candidates`: 2,756 claims, excluding 4 empty/missing document records and 13 claims without customer master. All candidates match a campaign. The original review view and snapshots retain all source rows for audit.
- AK still contains unsuitable formatted values in the existing CSV: 1,068 candidate rows have nonempty AK, and 1,067 of those contain alphabetic characters (the previously inspected values include formatted dates). Column identity is confirmed, but monetary values must be re-exported correctly; do not infer money from date strings or copy AL.
- Authority has not been found: recursive workspace filename search found no Authority file or `.xlsx`/`.xls` workbook at this inspection. The folder currently contains six CSVs including ListCampaign. Account import remains pending the file location.
- Owner requested removal from the current query. This is implemented as candidate filtering, not deletion of snapshots/reject history. The remaining reports below retain earlier audit findings for traceability.

Project URL verified as `https://vvojshgcduqlugngpzkj.supabase.co`. Migration `20260915021126_rc_master_access_foundation` applied successfully; local filename matches remote migration history.

| Object | Verified state |
|---|---|
| public.depots | 4 rows; address uses Depot Address, master link uses Link Master |
| public.customers | 1,520 unique nonempty Payer codes; name from Payer Name |
| public.customer_depots | 1,428 explicit matches from ListCust DC to depot code |
| public.profiles | Empty; references auth.users, defaults inactive |
| public.permissions | 8 RC permission definitions; no DC permissions |
| public.user_permissions / user_depot_access | Empty; no automatic privilege assignments |
| public.migration_runs | needs_review |
| public.migration_rejects | References source snapshot/record and reason; no copied cell payload |
| public.rc_claims_review | Operator-only view of 2,773 source records, values preserved as text |
| staging.rc_latest_rows | Operator-only security-invoker view; latest snapshot per source/sheet |

Source snapshots are unchanged. No claims financial table or workflow RPC was activated. Subsequent CSV imports update the latest-source views but do not automatically overwrite imported master tables. A reviewed incremental import is still required.

## Findings that prevent full cutover

- Compile has 2,769 unique nonempty No Document values, 2 entirely empty rows and 2 nonempty rows without No Document.
- ListCust has 1,520 unique nonempty Payer values. Another 111 rows are entirely empty and 4,074 nonempty rows lack Payer. These rows are retained in staging and recorded for review; no invented customer codes.
- DepoMaster has 4 unique nonempty depot codes and 1 row without a code.
- 13 nonempty claims reference customers absent from the customer master. All nonempty claims match a known depot.
- 92 imported customers have no matching depot from the explicit ListCust DC field. They have no app visibility until their depot mapping is resolved. Do not infer access from customer code patterns or browser payloads.
- Backend reads gross-up from zero-based index 36 (AK), but actual AK header is DMD30 USED and AL is Gross Up Disc. AK includes date-formatted values, including implausibly distant years. Converting this field to money would be unsafe without source correction/confirmation.
- ListCampaign and ReqProfile are not among imported snapshots. Claim campaign snapshots cannot establish the current authoritative campaign master used for rebate decisions.
- No Auth users exist. Need user codes, company emails, role/permission/depot assignments and suffixes; never import legacy PINs.
- Hold/Expired rules, gross-up parity, and customer master update policy remain unresolved in prior audit. These need an explicit target decision before implementing mutations.
- PROD Supabase is not assigned. DEV is the only deployment target. The source of new claims while DC remains legacy must be agreed before production cutover.

## Verification

All 9 public base tables have RLS enabled, no anonymous SELECT and no authenticated INSERT grants. `supabase/tests/rc_master_access.sql` ran through MCP in a rolled-back transaction with synthetic identities. PASS: allowed depot/customer reads, cross-depot exclusion, client write denial, review-view denial, inactive user denial and anonymous denial. No test accounts were retained. These are database tests; no browser login or production workload tests are claimed.

Queries: [rc_migration_review.sql](../supabase/queries/rc_migration_review.sql). Protection follows [Supabase RLS documentation](https://supabase.com/docs/guides/database/postgres/row-level-security).

## Remaining work

Resolve findings above, finalize financial/date dictionary and business rules, import complete master/sensitive data with controlled access, implement transactional claims/history/batches, provision Auth users, adapt RC frontend with pagination, then run end-to-end UAT and recovery rehearsal. Document Center and existing Apps Script deployments remain untouched. This progress report is not a claim that the migration is complete.
