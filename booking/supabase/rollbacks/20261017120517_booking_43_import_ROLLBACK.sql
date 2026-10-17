-- ============================================================
-- booking_43_import_ROLLBACK: poistaa Johku-tuonnin lahjakortit (source='johku') ja niiden ledger-rivit.
-- Estetty jos jokin Johku-kortti on jo lunastettu uudessa järjestelmässä (payments.gift_card_id) – silloin korjaa käsin.
-- Ledger on append-only; tämä purku ohittaa suojan vain tässä transaktiossa (booking.allow_ledger_rewrite).
-- ============================================================
do $$ begin
  if exists (select 1 from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id where g.source = 'johku') then
    raise exception 'ROLLBACK ESTETTY: Johku-korttia on lunastettu uudessa järjestelmässä';
  end if;
  perform set_config('booking.allow_ledger_rewrite', '1', true);
  perform set_config('booking.skip_audit', 'on', true);
  delete from booking.gift_card_ledger where gift_card_id in (select id from booking.gift_cards where source = 'johku');
  delete from booking.gift_cards where source = 'johku';
end $$;
