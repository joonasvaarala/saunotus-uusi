# Uutiskirjeet — booking_259

## HOLD after real-schema review

The corrected implementation is local only. Do not push, open a PR, merge, deploy,
import texts or run SQL on DEV/production from this branch. Bottiavustus must review
the new commit and migration SHA256 first. **General-marketing opt-out durability
needs a shared-boundary decision with Koodari** (proposal below); the number reservation
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
no bot gateway scope, API key, connector or send permission is expanded by this migration.
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

## Address opt-out: scoped implementation and shared-interface HOLD

`newsletter_optout_tokens` maps a random opaque UUID to an address SHA256 fingerprint;
`newsletter_suppressions` persists address-level opt-out independently of customer profiles,
log/outbox retention and email changes/deletions. Both are private RLS tables with no direct
public/anon/authenticated/service_role access. The token-only RPC
`booking.public_newsletter_unsubscribe(uuid)` returns the same generic result for known,
unknown or previously used tokens; it reveals no addresses or token existence. It can only
add suppression, never enumerate, send, remove suppression or change customer records.

The mandatory link is `/hallinta/newsletter-unsubscribe.html#token=<uuid>&lang=fi|en`.
A GET never unsubscribes: the page clears the URL fragment, then waits for explicit human
confirmation before calling that RPC. New fragment navigation reinitializes safely rather
than retaining a previously opened token/language. FI/EN copy clearly says newsletter-only; other service
messages/marketing permissions are not modified. The token is permanently bound to the
approved address, not the profile's future address. Any duplicate/new consented profile at
that address stays suppressed. No bot/admin re-consent silently clears suppression; a future
resubscription mechanism requires a separately reviewed policy. Hashes are still sensitive
pseudonymous data and are never returned by admin preview/list or written to application logs.

Core 259 seeds existing `marketing_unsubscribed_at` addresses into durable suppression and
checks current explicit general opt-outs across all duplicate profiles at preview/send/delivery.
A scoped partial customer-email index avoids scanning all customers for each such check.
**Remaining integration gap:** future general opt-outs can disappear if that profile is later
edited/deleted before its address is durably captured. No newsletter-only link implementation
can observe that past shared-path mutation without an integration hook. Do not claim this gap
is solved by the core migration or enable live newsletters before the policy is agreed.

Prepared, NOT installed / NOT automatically included in 259:
`booking/docs/newsletter-general-optout-hook-proposal.sql`. Proposed private newsletter-only
AFTER INSERT/UPDATE trigger captures old/new address hashes on explicit general opt-out or
true→false consent. It does not replace the shared unsubscribe, change customer flags, add
broad grants or affect transactional mail. Parent must agree this customer-table trigger with
Koodari (or choose an equivalent hook in the shared unsubscribe/consent writers) and obtain
review of its rollout packaging before hosted execution. Local proposal tests demonstrate
persistence after address edit/deletion and across duplicate-profile re-consent. No proposal
has been applied on DEV/PROD. The core migration has **no dependency on booking_258**.

## Bottiavustus rollout note — do not run from this branch automatically

1. Keep HOLD until Bottiavustus reviews the corrected commit/hash and parent agrees the
   shared opt-out integration with Koodari. Also agree the nav hook. Numbers 259/131 are
   reserved, NOT execution permission. Ensure booking_257 is
   represented in the deployment history; it remains independent and unchanged.
2. Only after explicit review/approval, Bottiavustus may run `booking/supabase/migrations/20261106220300_booking_259_newsletters.sql`
   transactionally on DEV **aoejjmfzulhkhxbehphs** first, then production
   **sxbofnuisemspgquoxyv**, BEFORE merge. Apply only the reviewed 259 transactionally
   (for psql: `-X -v ON_ERROR_STOP=1 --single-transaction -f <migration>` against the
   explicitly selected project); do not blanket-push unrelated reserved migrations.
   Do not change email mode, DNS or live WordPress.
3. On DEV only, after review of write-test side effects, run rollback-only
   `booking/supabase/tests/t259_newsletters.sql` and `t259_newsletters_edges.sql` with
   `psql -X -v ON_ERROR_STOP=1 -f ...`. These create synthetic fixtures and temporarily
   change consent/config inside transactions; NEVER run them in production. **ROLLBACK
   restores rows but DOES NOT undo sequence advances** (customer/order/reservation/outbox/
   newsletter IDs etc.). The local minimal fixture file is NEVER for either hosted DB.
   Proposal-hook test is separate and only appropriate after that integration is approved.
4. After both migrations pass, merge only via the normal reviewed workflow. At merge,
   import `content/site-texts.pending-import-131.json` through the established
   site-text import process, DEV first, then production. This branch imports nothing.
5. Deploy the updated **send-emails Edge Function and its _shared/newsletter-render.js**
   through the normal approved process, then the admin assets. Do not queue a newsletter
   until the updated sender is deployed. Existing mode / allowlist stay unchanged.
6. DEV: create a synthetic bot draft; review FI/EN; preview counts; confirm using controlled
   test recipients / dry_run; verify no real customers receive mail. Production use only
   after review, with the existing live-send process and explicit human confirmation.

Rollback: `booking/supabase/rollbacks/20261106220300_booking_259_ROLLBACK.sql`.
Stop newsletter dispatch/sender first and back up drafts/history. It skips pending/failed/
sending newsletter rows and removes feature dispatch/draft/log helpers/tables/indexes,
including the optional proposed customer trigger if it was separately approved. Preserves
other outbox rows/settings and **retains newsletter_optout_tokens, newsletter_suppressions
and public_newsletter_unsubscribe** so already delivered links remain valid. It intentionally leaves the allowed `newsletter` kind in the constraint
for retained outbox history. It does not undo site-text imports or assets. Keep the minimal public opt-out page/JS,
shared sb/ui/text dependencies, public config and opt-out texts available for shipped links;
do not blindly remove those when reverting the admin newsletter feature. No rollback was run against a Supabase project.

## Verification

Passed:
- Corrected migration, original SQL suite (34 assertions including 5000 cap), edge suite
  (41 assertions), separately proposed
  general-opt-out capture test, rollback and persistent-token checks on isolated local
  PostgreSQL 18.6 using `tests/newsletters/local-fixture.sql`. Fixture now enforces actual
  consent timestamps, native HH + exactly 12 uppercase-alnum gift codes and dead status.
  This minimal fixture is LOCAL EMPTY DATABASE ONLY, never DEV/production.
- Edge regressions: absent, past unchecked, cancelled, no-show, future-only, prior-plus-future
  courses, check-in/out, missing/future/absent/all-present required sessions, standalone
  segment, language-before-dedup, changed preview address, queued fingerprint, normalized
  address, unique log/address, post-queue change/convergence, missing fingerprint, dead count,
  anonymous token privacy, durable duplicate suppression, retained old links, current general
  opt-out. Proposal separately tests later address editing/deletion/re-consent.
- 106 Node tests: newsletter render/security/gates/texts, browser-module syntax and
  existing mail templates/transport.
- Full `npm run build:test` including resource checks.
- Mocked Playwright at 1280px and 390px: edit/save/preview, invalidation, cancel/confirm,
  queue lock, no horizontal overflow or page errors; anonymous session gate; FI/EN public
  opt-out requires a click, clears fragment, handles invalid token and renders no admin UI.

Known pre-existing verification limits (not changed here):
- Full old migration replay with the repository's normal mocks stops at booking_161's
  kb.products description MD5 guard (fixture content does not match expected text).
  The new SQL suite therefore still needs the real-schema DEV gate described above.
- Deno check reaches existing `send-emails/templates.ts:357` TS7006 (untyped `c`), not new
  newsletter code. That unrelated template file is untouched.
- npm ci reports one existing high-severity dependency advisory; no dependency/lock update.

Local SQL reproduction on a disposable PostgreSQL instance:
1. local-fixture.sql (empty DB only)
2. migration 259
3. t259_newsletters.sql (rolls its test data back)
4. t259_newsletters_edges.sql (rolls rows back; sequences still advance)
5. Optional isolated-only integration test: docs/newsletter-general-optout-hook-proposal.sql,
   then tests/newsletters/general-optout-hook-check.sql; NOT part of automatic 259 rollout.
6. newsletters/rollback-seed.sql
7. rollback 259
8. newsletters/rollback-check.sql (old public token still works)

Browser reproduction: `npm run build:test && node booking/tests/newsletters.browser.mjs`.
Unit tests: `node --test booking/tests/newsletters.test.mjs`.
