-- r147: ajetaan booking_147:n paluun (rollbacks/20261024230000_booking_147_ROLLBACK.sql) jälkeen samassa istunnossa kuin pre147.
-- Tarkistaa, että määritelmät ovat tavu tavulta tuotannon/booking_64+06:n mukaiset ja katalogi = ennen booking_147:ää. Tulos: TESTRESULT …
create temp table r147_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into r147_r values (coalesce(p_ok, false), p_label) $$;
do $t$
declare pre record;
begin
  select * into pre from pre147;
  perform pg_temp.ck(md5(pg_get_functiondef('booking.public_catalog()'::regprocedure)) = '0cd7d46e6d9bb24499e1b2ab6e334587', 'R1: public_catalog = tuotannon edellinen määritelmä (md5)');
  perform pg_temp.ck(md5(pg_get_functiondef('booking.admin_list_products()'::regprocedure)) = '7a881ee43d8231528c5a05f8359da540', 'R2: admin_list_products = tuotannon edellinen määritelmä (md5)');
  perform pg_temp.ck(booking.public_catalog() = pre.cat, 'R3: katalogi täsmälleen kuten ennen booking_147:ää');
  perform pg_temp.ck((select proacl::text from pg_proc where oid = 'booking.public_catalog()'::regprocedure) = pre.acl_cat
    and (select proacl::text from pg_proc where oid = 'booking.admin_list_products()'::regprocedure) = pre.acl_alp, 'R4: oikeudet ennallaan');
  perform pg_temp.ck(exists (select 1 from information_schema.columns where table_schema = 'kb' and table_name = 'products' and column_name = 'duration_text_en'), 'R5: paluu ei poista kb-saraketta (Bottiavustuksen oma paluu)');
  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from r147_r where ok), (select count(*) from r147_r where not ok),
    coalesce((select string_agg(label, ' | ') from r147_r where not ok), 'ALL OK');
end $t$;
