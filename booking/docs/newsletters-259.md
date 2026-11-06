# Uutiskirjeet — booking_259

## HOLD after real-schema review

The corrected implementation is local only. Do not push, open a PR, merge, deploy,
import texts or run SQL on DEV/production from this branch. Bottiavustus must review
the new commit and migration SHA256 first. Koodari’s read-only compatibility check found
no conflict with current send-emails/public_marketing_unsubscribe; this confirms design
compatibility ONLY, not hosted execution, merge or release permission. **Capture is now reserved/tracked as booking_262, still awaiting execution approval**; the number reservation
is not execution approval. Nothing has been run on either hosted project.

## Delivery boundary

Local checkout `/workspace/koodari2-newsletter`, branch `feat/newsletter-admin-259`.
Built on main `68bb8f9`. Main had booking_256 at checkout; fetched origin/main now includes booking_257 from PR #315
(`20261106220000_booking_257_customer_message.sql`). Bottiavustus subsequently confirmed booking_259 / pending-import-131 for this feature.
booking_258 / pending-import-130 belong to Koodari’s product-list fix; booking_260 /
pending-import-132 are reserved for admin UX. This feature does NOT depend on 258
and does not read or modify any objects introduced by that correction.
The CLI-generated migration was renamed to its confirmed booking_259 number. No merge, deployment or DB write was performed.

No admin shell, layout, left navigation, Messages view, customer_message file, PR #315
file, training-site draft or Christmas ad asset was changed. Only existing files changed:
`booking/supabase/functions/send-emails/index.ts` and `scripts/build-pages.mjs`.
The latter copies the shared renderer and versions the new standalone entry.
`email_outbox_claim` and its wrapper chain are untouched.

## Reach the view / agree with Koodari

Once built/deployed, open `/hallinta/newsletters.html` (test deployment uses its normal
base path). Sign in through the existing admin first; the page uses the same session,
public configuration and `messages.edit` permission. No separate sign-in implementation.

Koodari owns the nav. The smallest hook is a permission-gated link to
`newsletters.html`, label **Uutiskirjeet**, permission **messages.edit**.
Alternatively, Koodari may add this ROUTES row to `admin.js` when coordinating the redesign:

```js
{ path: 'uutiskirjeet', label: 'Uutiskirjeet', icon: 'mail',
  any: ['messages.edit'], mod: () => loadView('newsletters') }
```

Then `/hallinta/#/uutiskirjeet` renders the same exported `render({ctx})` view.
The view loads only its own scoped CSS. I have NOT added either nav hook or hash route.

## Bot authoring contract

Service-role-only RPC in schema `booking`:

```js
svc_newsletter_save({
  p_id: null, // existing id for updates
  p_version: null, // required current version when updating
  p_data: {
    subject_fi: '...', subject_en: '...',
    body_fi: '...', body_en: '...',
    segment: 'all', language: 'all', suggested_send_at: null,
    style: {
      layout: 'editorial', // or letter
      background: '#f4f1e9', foreground: '#24332c', accent: '#465e4b',
      // Optional image_url, cta_url: credential-free HTTPS URLs.
      // cta_url requires both cta_fi and cta_en labels (1–100 characters).
    }
  }
})
```

Use the existing authorized service/MCP integration. No credentials are shipped in the
browser or this repository. Both bots can author through this same service RPC;
no bot gateway scope, API key, connector or send permission is expanded by these migrations.
If Otto only has the restricted bot-gateway credential, its broker needs to be wired
to this draft-only RPC by the owner of that integration; do NOT give it admin dispatch.

The style is a validated **structured style package**, not arbitrary HTML. Two layouts,
hex colors, optional hero and bilingual CTA; body paragraphs remain escaped plain text.
This is the spec's structured-format alternative. Humans edit only subject, body,
segment and language, never style. Suggested send time is an advisory timestamp only:
**there is no automatic scheduling or bot sending**. Both languages are required, so
an English recipient never silently receives a Finnish fallback.

`svc_newsletter_save` returns id/version/state/content. Optimistic version checks and
row locks prevent bots and humans from silently overwriting one another. Sent drafts
are immutable; make a new draft for a new campaign.

## Human workflow / safety

- `admin_newsletters_list()` returns up to 100 recent drafts plus count-only delivery status.
- `admin_newsletter_save(p_id,p_data,p_version)` edits text/audience and invalidates preview.
- `admin_newsletter_dispatch(p_id,p_version,false,null)` persists a 30-minute preview,
  returns only counts (total/FI/EN), version and opaque preview token. No names/emails.
- `admin_newsletter_dispatch(p_id,p_version,true,p_preview_token)` requires an authenticated
  staff JWT with `messages.edit`, matching version, fresh token and unchanged audience hash.
  Only this confirmed path queues mail. **service_role has no dispatch grant**, and the
  function itself rejects service-role claims even if invoked by a privileged SQL owner.
- Maximum 5000 recipients: rejects, never truncates. Empty audience / transport off rejects.
- Row lock + one unique log per newsletter + `newsletter:<log>:<customer>` dedupe prevent
  repeated clicks/retries from queueing twice. `state=sent` means queued, not delivered.
- Log holds subjects, content snapshot, style, segment, language, counts and staff id,
  never recipient addresses/lists. Outbox payload holds customer id, log id and the
  approved normalized-address SHA256 fingerprint, not the raw email. A unique log/address
  index also prevents two different customer IDs queueing the same address.
- Existing sender obtains `email_newsletter_payload(p_id)` immediately before delivery,
  rechecking consent, anonymisation, valid email, address fingerprint and suppression.
  Changed addresses fail closed rather than following a customer profile; address
  convergence cannot duplicate a campaign. Case/outer whitespace normalization is stable.
  Opt-out after queueing
  is therefore honored. Newsletter failures and dry runs use generic error codes, never
  provider response bodies, addresses or subjects in outbox error logs.
- A mandatory FI/EN link uses the NEW newsletter-only public page/RPC described below.
  The shared `public_marketing_unsubscribe` function and its grants are untouched.
- Existing off/dry_run/live, test allowlist and SMTP/Resend behavior are preserved.
  Newsletter HTML never falls back to the event Tapahtuma/Aika template.
- Admin preview uses exactly the sender renderer inside scriptless sandboxed iframes,
  CSP and no-referrer; no untrusted HTML/CSS is evaluated in admin.

## Segment semantics (explicit, no product ids guessed)

All segments require `customers.marketing_consent=true`, `anonymized_at IS NULL`, a valid
email and no address-level newsletter suppression / current explicit general opt-out.
Language is customer.language, otherwise latest confirmed/completed order locale,
otherwise FI. Explicit **FI/EN filtering is BEFORE normalized-address deduplication**:
for EN the lowest eligible EN customer ID wins even if an earlier FI profile exists.
With `all`, the lowest eligible customer ID determines language. One per customer and
normalized address per campaign; a separate campaign is a separate human decision.

**Positive attendance** means a reservation has ended, is visible and confirmed/completed,
on a confirmed/completed non-refunded order, plus recorded checkin_at / checkout_at or an
explicit `completed` reservation state. Existing `admin_set_reservation_status` uses
`completed` for arrival and sets checkin_at (booking_06; dayparts.js). Elapsed time on a
`confirmed` reservation alone is NOT proof. For training, an existing participant-details
row is authoritative: `present=true` required; `present=false` overrides check-in and
completed status. Missing historical attendance is never inferred from a booking date.
Cancelled, expired, pending, no-show and future reservations cannot prove attendance.

- training: category `training`; at least one completed course/order. Every training
  reservation on that course/order must be ended, visible, valid and positively attended.
  Every non-cancelled session configured in `training_segments` must have a corresponding
  positively attended, ended reservation on that order. A standalone segment-only booking
  cannot establish the whole course without its parent on that order. A future or absent
  session prevents completion; a completed earlier course on another order still qualifies.
- treatment: category `treatment`, `ritual` or `ceremony`, with positive attendance.
- event: category `event`, with positive attendance.
- session_only: a positively attended `public_shift` / `private_shift`, AND **no confirmed,
  completed or no-show non-session history** (training/treatment/ritual/ceremony/event) on
  a visible reservation with valid non-refunded order. This history predicate is independent
  of actual attendance/course completion: incomplete, absent, unchecked or future confirmed
  training conservatively excludes session-only, instead of reclassifying a past trainee.
  Cancelled/expired/pending-only non-session bookings do not exclude. A future-only session
  never qualifies. This deliberately errs against claiming someone is a session-only guest.
- gift_buyers: gift_cards buyer_customer_id or purchase order customer; issuer own/johku
  (not partner voucher redeemers); active/used/expired, non-complimentary; purchase order
  (if present) confirmed/completed and non-refunded.
- christmas_gift_buyers: those gift purchases dated November/December in years BEFORE
  the current Helsinki year. Purchase order date, otherwise gift card creation date.

These are conservative operational booking-history segments, not certification promises.
No purchases, prices or customer promises are created. Legacy campaign_sends is not used
because it stores recipient addresses.

## Permanent opt-out infrastructure / shared-interface HOLD

The permanent layer consists of newsletter_suppressions, newsletter_optout_tokens,
_newsletter_fingerprint, _newsletter_address_blocked, public_newsletter_unsubscribe,
the customer opt-out index, permanent campaign/log identity sequences, and the262 capture
trigger/helper (only after execution approval).
These have no dependency on newsletter draft/log/dispatch tables. Feature rollback MUST
retain all of them and the public opt-out page/dependencies. No re-consent, profile address
change, account deletion, outbox cleanup or UI rollback clears suppression. Raw addresses
are not stored in the suppression/token maps; SHA256 hashes remain sensitive pseudonyms.
Tables have RLS and no direct public/anon/authenticated/service_role access; private helpers
have no direct grants. No arbitrary-address public RPC or suppression-clear RPC is added.

The mandatory link is `/hallinta/newsletter-unsubscribe.html#token=<uuid>&lang=fi|en`.
GET never unsubscribes. The page clears the fragment and requires an explicit click before
calling only the new token-limited public_newsletter_unsubscribe(uuid). New fragment
navigation resets the token/language safely. Responses reveal neither addresses nor token
existence. The token stays bound to the approved address, never a profile's future address.
FI/EN copy accurately says newsletter-only; service messages/other marketing flags unchanged.

**Numbered capture package, HOLD:**
`booking/supabase/migrations/20261106221404_booking_262_newsletter_capture.sql`.
Bottiavustus reserved262; no text import number. The old docs SQL execution path is removed.
Koodari’s read-only compatibility check found no conflict, but allocation/compatibility do not
approve hosted execution, push, PR, merge or release. The migration does not replace public_marketing_unsubscribe(uuid), change its grants,
response or existing after_marketing-message cancellation. It captures valid OLD + NEW
fingerprints on true→false consent / a new explicit opt-out timestamp. Ordinary never-consented
profiles are NOT suppressed. Explicit opt-out INSERTs are captured. Nothing removes history.
Johku227 true→false capture is intentionally sticky even if later sync/profile edits restore
true: newsletter eligibility stays blocked. No automatic restoration is implemented. Separate
unimplemented design: `booking/docs/newsletter-resubscribe-proposal.md`, requiring verified
fresh address-owner proof and an approved revocation-generation/shared-path design. It grants
no new right now and must not be implemented as a profile/Johku-based clear operation.
Existing event_message/customer service messages remain outside newsletter suppression;
only newsletter payloads consult it. The shared after_marketing cancellation remains unchanged.

Capture262 contains NO internal BEGIN/COMMIT. Its caller-owned transaction and explicit
SHARE ROW EXCLUSIVE customer lock cover trigger installation AND existing explicit-opt-out
backfill atomically. Core259 performs no separate seed. Use the combined outer transaction
below with the customer-write lock acquired BEFORE259 to avoid an installation interval at all.
If separately approved transactions are used instead, keep259→262 interval short; dispatch AND
payload hard-gates fail closed until enabled capture exists, but live use must wait for262.
Like any first installation, already-deleted historical addresses cannot be reconstructed;
no claim is made to recover data no longer present before capture starts.

## Rollback and forward-only re-enable

Rollback: `booking/supabase/rollbacks/20261106220300_booking_259_ROLLBACK.sql`.
Stop feature dispatch/sender and back up drafts/logs before any approved rollback. This is a
FEATURE rollback: it skips pending/failed/sending newsletter rows, removes draft/log tables,
feature-only indexes and draft/dispatch/render RPCs. Other mail rows/settings and retained
outbox history are not removed. The two OWNED BY NONE, WAL-logged BIGINT NO CYCLE sequences
newsletter_campaign_id_seq and newsletter_log_id_seq survive feature-table deletion. Do not
reset/restart/setval or re-own them: future campaigns/logs MUST NOT alias retained outbox keys. The newsletter kind remains allowed. Importantly it NEVER
drops the permanent capture trigger/helper, fingerprint/address-blocked helpers, private
suppression/token tables, customer opt-out index or public token RPC. General marketing
opt-outs continue being captured while newsletter UI/dispatch is rolled back.

Keep newsletter-unsubscribe.html/.js, newsletter-texts.js and fallbacks/imported opt-out
texts, sb.js, ui.js, i18n.js, required transitive modules, admin/newsletter CSS and public config
available for shipped links. Do not blindly revert the complete admin directory or remove
those dependencies with the newsletter view. Retained public token RPC needs no UI tables.

Core259 is NOT directly replayable after rollback because permanent objects survive.
UNNUMBERED forward-only proposal: `booking/docs/newsletter-reenable-proposal.sql`.
No number has been reserved, and it is not in migrations/. It checks retained infrastructure,
enabled approved capture, retained outbox kind and absent feature tables, then reconstructs
ONLY feature tables/indexes/RPCs transactionally. It never drops/truncates history, recreates
suppression infrastructure or re-seeds/changes public/shared RPCs. Static tests enforce feature
schema/function parity with corrected259; later packaging needs its own review and number.
Re-enable reuses the retained sequence defaults and validates sequence permanence, unowned
monotonic shape and next-log high-water greater than ALL retained newsletter outbox log IDs.
It fails closed if identity infrastructure is missing/stale; never auto-repairs by discarding
history. Regression queues an actual campaign (IDs start at1 in a fresh database), retains its
real sent outbox payload/key/address, performs rollback→re-enable, queues a new campaign to
the same recipient, retries confirmation, and checks new IDs, no collision/duplicate and no
old-history/metrics alias. Sequence gaps from rolled-back tests are expected and safe.

262 intentionally has no destructive rollback. Its matching rollback guard
`booking/supabase/rollbacks/20261106221404_booking_262_ROLLBACK.sql` raises an exception,
changes nothing and prevents falsely removing262 from applied history. Keep262 applied;
use reviewed259 feature rollback to disable newsletter UI/dispatch, never capture.

## Bottiavustus rollout note — HOLD, review only; execute NOTHING now

Numbers:259 / pending-import131 remain ours; capture is262 with no text import.260 UX and261
calendar correction belong to Koodari. No dependency on258/260/261;262 needs259 permanent
infrastructure only. Re-enable remains an unnumbered future draft, not an installation step.

After explicit execution approval ONLY, use the reviewed files in the explicitly selected
DEV aoejjmfzulhkhxbehphs connection first, then (after successful DEV review + separate approval)
production sxbofnuisemspgquoxyv BEFORE merge. Never blanket-push all migrations.
Recommended atomic packaging with psql against the approved connection (no credentials here):

```sh
psql -X -v ON_ERROR_STOP=1 --single-transaction \
  -c "SET LOCAL lock_timeout='5s'; LOCK TABLE booking.customers IN SHARE ROW EXCLUSIVE MODE;" \
  -f booking/supabase/migrations/20261106220300_booking_259_newsletters.sql \
  -f booking/supabase/migrations/20261106221404_booking_262_newsletter_capture.sql
```

The ONE outer transaction acquires the customer-write lock before either file, holds it
through capture/backfill, and commits both. Neither259 nor262 contains internal BEGIN/COMMIT.
A lock timeout/error aborts the package: stop, do not bypass, disable triggers or continue
partially. For any separately approved per-file migration runner, ensure each file has its
own real transaction and ON_ERROR_STOP, keep259→262 interval minimal, and never enable live
use before262. Migration-history bookkeeping must retain BOTH reviewed259 and262 entries
through the established approved process; do not replace it with an untracked docs script.
No mode/DNS/WordPress changes or unapproved import/deployment actions.

### Test safety — IMPORTANT reclassification

The ONLY prepared hosted candidate is
`booking/supabase/tests/t259_newsletters_capture_hosted_safe.sql`:
actual existing token RPC, synthetic customers only, full BEGIN/ROLLBACK, repeated opt-out,
duplicate re-consent, later address change/delete, simultaneous OLD+NEW withdrawal,
never-consented checks and unchanged shared definition/grants/response. It also runs while
UI/dispatch is rolled back because it uses permanent infrastructure only. Needs complete
review and explicit DEV write-test approval; NOT run now, not permission for production.
Review customer audit/trigger side effects; ROLLBACK does NOT undo sequence advances.

**ALL reservation/attendance scenarios are DISPOSABLE LOCAL ONLY, NEVER DEV/PROD.**
`t259_newsletters_attendance_hosted_safe.sql` was removed/renamed to
`booking/supabase/tests/t259_newsletters_attendance_local_only.sql`.
Reason: inserting confirmed reservations can trigger _expire_holds →
_release_unpaid_additions(null,null), operating on unrelated global reservations/orders and
locks even when outer ROLLBACK restores rows. Synthetic data is NOT sufficient isolation.
Do NOT disable/replace triggers to make these tests run hosted. The original t259 suite,
edges suite, all tests/newsletters/* (fixture/seed/rollback/identity/compat helpers) are ALSO
local-only and some deliberately alter fixture-wide consent/config or commit synthetic rows.
Never install the local copied shared RPC/schema/roles into a hosted database.

Merge/import/deploy still need normal separate approval after review. Pending-import131 is
for merge-time import DEV then production; nothing imported here. Preserve public opt-out
assets/transitive dependencies throughout feature rollback. Deploy updated sender/renderer
before approved human dispatch. Bots only author drafts; no send or re-subscribe scope.

## Verification

Passed:
- Local two-session check of the documented caller-owned259+262 transaction confirmed
  customer withdrawal blocks throughout the initial core→capture interval; backfill and
  post-commit token capture work.262 rollback guard refuses without disabling capture.
- Corrected migration, original SQL suite (34 assertions including 5000 cap), edge suite
  (42 assertions), numbered262
  general-opt-out capture test, rollback and persistent-token checks on isolated local
  PostgreSQL 18.6 using `tests/newsletters/local-fixture.sql`. Fixture now enforces actual
  consent timestamps, native HH + exactly 12 uppercase-alnum gift codes and dead status.
  This minimal fixture is LOCAL EMPTY DATABASE ONLY, never DEV/production. It includes the
  unchanged real public_marketing_unsubscribe function/grants copied from booking_121 and
  schedule_rules_event_shape (valid_from=valid_to, matching ISO weekday).
- Edge regressions: absent, past unchecked, cancelled, no-show, future-only, prior-plus-future
  courses, check-in/out, missing/future/absent/all-present required sessions, standalone
  segment, language-before-dedup, changed preview address, queued fingerprint, normalized
  address, unique log/address, post-queue change/convergence, missing fingerprint, dead count,
  anonymous token privacy, durable duplicate suppression, retained old links, current general
  opt-out. Proposal separately tests later address editing/deletion/re-consent.
- 108 Node tests: newsletter render/security/gates/texts, browser-module syntax and
  existing mail templates/transport.
- Previous full `npm run build:test` including resource checks passed; this SQL-only lifecycle
  correction does not change frontend assets. Latest unit suite was rerun.
- Mocked Playwright at 1280px and 390px: edit/save/preview, invalidation, cancel/confirm,
  queue lock, no horizontal overflow or page errors; anonymous session gate; FI/EN public
  opt-out requires a click, clears fragment, handles invalid token and renders no admin UI.

Known pre-existing verification limits (not changed here):
- Full old migration replay with the repository's normal mocks stops at booking_161's
  kb.products description MD5 guard (fixture content does not match expected text).
  Do NOT compensate by running reservation suites on DEV. Attendance compatibility needs
  read-only schema review / a disposable full-schema replica; only capture_hosted_safe is
  a candidate for a separately approved DEV rollback test.
- Deno check reaches existing `send-emails/templates.ts:357` TS7006 (untyped `c`), not new
  newsletter code. That unrelated template file is untouched.
- npm ci reports one existing high-severity dependency advisory; no dependency/lock update.

Local SQL reproduction on a disposable PostgreSQL instance, in order:
1. tests/newsletters/local-fixture.sql (empty DB ONLY)
2. migration259; tests/newsletters/capture-required-check.sql (fail-closed before hook)
3. tests/newsletters/capture-install-seed.sql (existing explicit + never-consented fixtures)
4. migration262 (LOCAL ONLY here for package verification)
5. tests/newsletters/capture-install-check.sql (backfill + unchanged shared contract)
6. t259_newsletters.sql; t259_newsletters_edges.sql; t259_newsletters_attendance_local_only.sql
   and t259_newsletters_capture_hosted_safe.sql;
   tests/newsletters/shared-message-compat-check.sql (after_marketing vs event/service separation)
7. tests/newsletters/rollback-seed.sql; rollback259; tests/newsletters/rollback-check.sql
8. t259_newsletters_capture_hosted_safe.sql AGAIN while feature rolled back (capture works)
9. docs/newsletter-reenable-proposal.sql (LOCAL ONLY); tests/newsletters/reenable-check.sql
10. capture-install-check.sql and original + hosted-safe capture suites again.
Fresh-ID regression separately: local-fixture →259 →262 →identity-history-before.sql →
259 rollback → re-enable proposal → identity-history-after.sql (all DISPOSABLE LOCAL ONLY).
No migration/rollback/install/write test was executed against a Supabase project.

Browser reproduction: `npm run build:test && node booking/tests/newsletters.browser.mjs`.
Unit tests: `node --test booking/tests/newsletters.test.mjs`.

Review integrity: `booking/docs/newsletter-review-sha256.txt` lists the complete feature package
(including unchanged131 texts and standalone assets). Verify from repo root with
`sha256sum -c booking/docs/newsletter-review-sha256.txt`. The manifest excludes itself.
