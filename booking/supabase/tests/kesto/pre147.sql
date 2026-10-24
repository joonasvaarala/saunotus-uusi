-- pre147: tilannekuva ENNEN booking_147:ää (ajetaan booking_148:n jälkeen samassa istunnossa kuin t147/r147; temp-taulu).
-- Tallentaa public_catalog()- ja admin_list_products()-tulokset, hintojen tiivisteen ja funktioiden md5:n (vertailu tuotannon pg_get_functiondefiin).
create temp table pre147 as select booking.public_catalog() cat,
  (select md5(string_agg(id::text || ':' || coalesce(price::text, '') || ':' || coalesce(price_text, '') || ':' || coalesce(vat_rate::text, ''), '|' order by id)) from kb.products) prices,
  md5(pg_get_functiondef('booking.public_catalog()'::regprocedure)) md5_cat, md5(pg_get_functiondef('booking.admin_list_products()'::regprocedure)) md5_alp,
  (select proacl::text from pg_proc where oid = 'booking.public_catalog()'::regprocedure) acl_cat, (select proacl::text from pg_proc where oid = 'booking.admin_list_products()'::regprocedure) acl_alp,
  null::jsonb alp;
grant all on pre147 to public;
do $$ begin perform test.login(test.mk_staff('adm147@example.test', 'admin')); update pre147 set alp = booking.admin_list_products(); perform test.logout(); end $$;
