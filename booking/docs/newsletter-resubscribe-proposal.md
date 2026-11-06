# Newsletter re-subscribe — separate design proposal, NOT implemented

HOLD. No endpoint, grant, token flow, automatic consent restoration or suppression clearing
is provided by259/262 or the re-enable proposal. Read-only compatibility approval of capture is
NOT execution/release approval and does not approve this future re-subscribe design.

## Why sticky is intentional

Johku booking_227 can transition marketing_consent true→false and later true again. The
capture hook conservatively stores the withdrawal fingerprint. A subsequent Johku sync,
profile edit, new duplicate profile or ordinary marketing_consent=true DOES NOT remove it:
that address remains excluded from newsletters. This can suppress a legitimate subscriber
until an approved explicit re-subscribe flow exists. Operationally report counts only; do not
"repair" the condition by deleting hashes, editing customers or giving bots a clear permission.
This affects newsletter eligibility only, not event_message/customer service messages.

## Required design for a future reviewed flow

1. Obtain a fresh, explicit request from the address owner for newsletter re-subscription.
   Verify possession with a short-lived, one-use, purpose-bound double-opt-in token sent only
   through a separately reviewed confirmation transport. Do not add an arbitrary-address public
   lookup/clear RPC or expose suppressed addresses. Rate-limit and use generic responses.
2. Bind the proof to normalized-address fingerprint, consent purpose, expiry and current
   revocation generation. Store token hashes, not raw proof tokens; never raw addresses in
   the suppression/audit log. A later withdrawal MUST invalidate earlier pending proof.
3. Newsletter permission remains separate from general marketing permission. A customer must
   still have fresh valid marketing consent, be non-anonymized and have the verified current
   address. Do not restore broader marketing flags just because a newsletter link was clicked.
   If general marketing consent is false, first use its separately approved explicit consent
   flow. Do not treat an imported/profile-edited true value as re-subscribe proof.
4. Current _newsletter_address_blocked also checks existing explicit opt-out profiles. Merely
   deleting newsletter_suppressions would be both unsafe and insufficient. A future design
   must define a verified address-scoped consent/revocation ledger and safe precedence over
   historical duplicate-profile opt-outs, without silently resetting those profiles or grants.
5. Current suppression timestamps preserve the first withdrawal (ON CONFLICT DO NOTHING),
   and the shared public_marketing_unsubscribe may perform no UPDATE on repeated old tokens.
   Therefore current data cannot prove the newest revocation generation after re-subscribe.
   Before implementation, coordinate a reviewed way to observe EVERY later opt-out, including
   repeated shared tokens, and atomically advance/revoke the ledger even when customer flags
   were already false. Shared API signature, grants, response and existing message-cancellation
   behavior must remain compatible. This is an unresolved prerequisite, not a bypass proposal.
6. Only a verified, still-current proof may authorize the address-scoped state transition under
   a transaction/row lock. No bot, generic admin profile edit, Johku import or service-role
   draft RPC gets re-subscribe rights. Audit proof id/purpose/time and hashes only.

Acceptance tests for that future work: expired/replayed proof; email change; duplicate profiles;
withdrawal during verification; repeated old general/newsletter unsubscribe tokens; Johku
false→true cycles; concurrent activation/withdrawal; feature rollback/re-enable; event_message
unchanged. New grants, schema/migration number, copy and live flow all require separate review.
