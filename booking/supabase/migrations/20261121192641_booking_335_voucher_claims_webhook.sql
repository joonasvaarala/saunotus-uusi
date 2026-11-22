-- booking_335: heräte Asiakaspalvelun lunastusrutiiniin, kun voucher_claimsiin tulee uusi open-rivi.
-- URL ja avain luetaan vaultista (voucher_claims_webhook_url / _key). Ei koodia eikä asiakastietoja bodyssa.
create or replace function booking._vc_webhook_trg()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_url text; v_key text;
begin
  if new.status is distinct from 'open' then return null; end if;
  if tg_op = 'UPDATE' and old.status = 'open' then return null; end if;
  if coalesce(current_setting('booking.skip_cron', true), '') = 'on' then return null; end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'voucher_claims_webhook_url';
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'voucher_claims_webhook_key';
  if v_url is null or v_key is null then return null; end if;
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('event', 'voucher_claim_open', 'claim_id', new.id, 'source', new.source, 'created_at', new.created_at),
    headers := jsonb_build_object('content-type', 'application/json', 'authorization', 'Bearer ' || v_key)
  );
  return null;
exception when others then
  raise warning 'voucher_claims webhook failed: %', sqlerrm;
  return null;
end $function$;

revoke all on function booking._vc_webhook_trg() from public, anon, authenticated;

drop trigger if exists voucher_claims_webhook on booking.voucher_claims;
create trigger voucher_claims_webhook
  after insert or update of status on booking.voucher_claims
  for each row execute function booking._vc_webhook_trg();
