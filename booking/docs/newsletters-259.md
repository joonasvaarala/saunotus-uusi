# Uutiskirjeet — booking_259

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
  never recipient addresses/lists. Outbox payload holds only customer id and log id.
- Existing sender obtains `email_newsletter_payload(p_id)` immediately before delivery,
  rechecking consent, anonymisation, valid email and opt-out token. Opt-out after queueing
  is therefore honored. Newsletter failures and dry runs use generic error codes, never
  provider response bodies, addresses or subjects in outbox error logs.
- A mandatory FI/EN opt-out link uses the existing `public_marketing_unsubscribe` route.
- Existing off/dry_run/live, test allowlist and SMTP/Resend behavior are preserved.
  Newsletter HTML never falls back to the event Tapahtuma/Aika template.
- Admin preview uses exactly the sender renderer inside scriptless sandboxed iframes,
  CSP and no-referrer; no untrusted HTML/CSS is evaluated in admin.

## Segment semantics (explicit, no product ids guessed)

All segments require `customers.marketing_consent=true`, `anonymized_at IS NULL`, valid
email and unsubscribe token. One per customer; shared normalized email addresses are
also deduplicated. Language is customer.language, otherwise latest confirmed/completed
order locale, otherwise FI. Additional language filter: all / fi / en.

Visits use non-hidden confirmed/completed reservations that have ENDED, and
confirmed/completed, non-refunded orders (native and imported history are both eligible).
Cancelled, expired, no-show and future reservations do not qualify.

- training: category `training`; no future active training reservation on the same order
  (a completed earlier course on another order still qualifies).
- treatment: categories `treatment`, `ritual`, `ceremony` (includes sauna rituals).
- event: category `event`.
- session_only: `product_config.sale_kind` public_shift/private_shift, and no past
  training/treatment/event visit. Future purchases alone do not count as a visit.
- gift_buyers: gift_cards buyer_customer_id or purchase order customer; issuer own/johku (not partner voucher redeemers); active/used/expired,
  non-complimentary, purchase order (if present) confirmed/completed and non-refunded.
- christmas_gift_buyers: those gift purchases dated November/December in YEARS BEFORE
  the current Helsinki year. Purchase order date, otherwise gift card creation date.

These are booking-history segments, not a newly invented certification/attendance register.
No purchases, prices or customer promises are created. Existing legacy campaigns /
campaign_sends tables are deliberately not used because the latter stores email addresses.

## Bottiavustus rollout note — do not run from this branch automatically

1. booking_259 / pending-import-131 are confirmed by Bottiavustus. Agree only the nav hook with Koodari. Ensure booking_257 is
   represented in the deployment history; it remains independent and unchanged.
2. Review and run `booking/supabase/migrations/20261106220300_booking_259_newsletters.sql`
   transactionally on DEV **aoejjmfzulhkhxbehphs** first, then production
   **sxbofnuisemspgquoxyv**, BEFORE merge. Do not change email mode, DNS or live WordPress.
3. On DEV only, run rollback-only `booking/supabase/tests/t259_newsletters.sql` with
   `psql -X -v ON_ERROR_STOP=1 -f ...`. It creates synthetic fixtures and temporarily
   changes consent inside the transaction; NEVER run this test in production.
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
sending newsletter rows, removes only newsletter RPCs/tables/index, preserves other outbox
rows and settings. It intentionally leaves the allowed `newsletter` kind in the constraint
for retained outbox history. It does not undo site-text imports or assets; revert those
through the normal release workflow. No rollback was run against a Supabase project.

## Verification

Passed:
- New migration, SQL regression suite (including 5000 cap), rollback and preservation
  checks on isolated local PostgreSQL 18.6 using `tests/newsletters/local-fixture.sql`.
  This minimal fixture is LOCAL EMPTY DATABASE ONLY, never DEV/production.
- 105 Node tests: newsletter render/security/gates/texts, browser-module syntax and
  existing mail templates/transport.
- Full `npm run build:test` including resource checks.
- Mocked Playwright at 1280px and 390px: edit/save/preview, invalidation, cancel/confirm,
  queue lock, no horizontal overflow or page errors; anonymous session gate.

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
4. newsletters/rollback-seed.sql
5. rollback 259
6. newsletters/rollback-check.sql

Browser reproduction: `npm run build:test && node booking/tests/newsletters.browser.mjs`.
Unit tests: `node --test booking/tests/newsletters.test.mjs`.
