-- booking_197: kuitti-PDF kuuluu täsmälleen yhdelle kuittiriville.
--
-- Juurisyy: receipt-pdf tallensi ja luki Storage-objektin nimellä {kuittinumero}.pdf.
-- Jos sama numero annettiin uudelleen (laskuri nollattiin testidatan jälkeen, tai
-- kuittinumero ei ollut uniikki), lataus palautti aiemman kuitin tiedoston.
-- receipt_by_token löysi oikean rivin, mutta välimuisti ei ollut rivikohtainen.
--
-- Tämä migraatio:
--   1) Ilmoittaa (NOTICE) päällekkäiset receipt_no- ja (series, year, seq) -ryhmät.
--   2) Jos päällekkäisyyksiä on, ne ovat testidataa (ei asiakkaita ennen 1.11.2026):
--      pienin id pitää numeronsa, myöhemmät saavat seuraavan vapaan numeron ja seqin,
--      snapshot.receipt_no ja text_body päivitetään, ja ryhmän pdf_path tyhjennetään
--      jotta jaettua tiedostoa ei kirjata kenellekään. Uniikkeja kuitteja ei numeroida uudelleen.
--   3) Varmistaa uniikkiuden receipt_no:lle ja (series, year, seq):lle, jos rajoite puuttuu.
--   4) Synkkaa receipt_counters vähintään max(seq):iin. _next_receipt_no ei enää laske
--      laskuria taaksepäin eikä anna käytössä olevaa numeroa, vaikka last_seq nollattaisiin.
--   5) PDF-avain on {public_token}/{md5(snapshot)}.pdf. receipt_set_pdf hylkää muun polun.
--      public_get_receipt palauttaa kuitin vain, kun se kuuluu tähän tilaukseen ja osumia on yksi.
--
-- Vanhat objektit receipts/{kuittinumero}.pdf pitää poistaa Storage-API:lla (ei tässä).
-- Migraatiota ei ajeta tästä commitista.

set local lock_timeout = '5s';

-- ---------- 1) päällekkäiset testinumerot ----------
do $mig$
declare
  n_no integer := 0;
  n_seq integer := 0;
  n_ren integer := 0;
  n_seqfix integer := 0;
  dup record;
  v_seq integer;
  v_no text;
  v_snap jsonb;
begin
  select count(*) into n_no from (
    select receipt_no from booking.receipts group by receipt_no having count(*) > 1
  ) d;
  select count(*) into n_seq from (
    select series, year, seq from booking.receipts group by series, year, seq having count(*) > 1
  ) d;
  raise notice 'booking_197: duplicate receipt_no groups=% ; duplicate (series,year,seq) groups=%', n_no, n_seq;

  if n_no = 0 and n_seq = 0 then
    raise notice 'booking_197: no duplicates; existing receipt numbers are left unchanged';
  else
    for dup in
      select x.receipt_no, array_agg(x.id order by x.id) as ids
        from booking.receipts x
       group by x.receipt_no
      having count(*) > 1
    loop
      raise notice 'booking_197: receipt_no % keep id % renumber ids %', dup.receipt_no, dup.ids[1], dup.ids[2:array_length(dup.ids, 1)];
    end loop;

    alter table booking.receipts disable trigger receipts_guard;
    begin
      update booking.receipts as rc
         set pdf_path = null, pdf_generated_at = null
       where rc.receipt_no in (
         select x.receipt_no from booking.receipts x group by x.receipt_no having count(*) > 1
       );

      for dup in
        select id, receipt_no, series, year, snapshot
          from booking.receipts
         where receipt_no in (select x.receipt_no from booking.receipts x group by x.receipt_no having count(*) > 1)
           and id not in (select min(x.id) from booking.receipts x group by x.receipt_no having count(*) > 1)
         order by id
      loop
        select greatest(
                 coalesce((select max(x.seq) from booking.receipts x where x.series = dup.series and x.year = dup.year), 0),
                 coalesce((select c.last_seq from booking.receipt_counters c where c.series = dup.series and c.year = dup.year), 0)
               ) + 1 into v_seq;
        v_no := format('%s-%s-%s', dup.series, dup.year, lpad(v_seq::text, 6, '0'));
        while exists (select 1 from booking.receipts x where x.series = dup.series and x.year = dup.year and x.seq = v_seq)
           or exists (select 1 from booking.receipts x where x.receipt_no = v_no)
        loop
          v_seq := v_seq + 1;
          v_no := format('%s-%s-%s', dup.series, dup.year, lpad(v_seq::text, 6, '0'));
          if v_seq > 1000000 then
            raise exception 'booking_197: free receipt number not found for id %', dup.id;
          end if;
        end loop;
        v_snap := coalesce(dup.snapshot, '{}'::jsonb) || jsonb_build_object('receipt_no', v_no);
        update booking.receipts
           set receipt_no = v_no,
               seq = v_seq,
               snapshot = v_snap,
               text_body = booking._receipt_text(v_snap),
               pdf_path = null,
               pdf_generated_at = null
         where id = dup.id;
        n_ren := n_ren + 1;
        raise notice 'booking_197: renumbered receipt id % from % to %', dup.id, dup.receipt_no, v_no;
      end loop;

      for dup in
        select id, series, year, seq, receipt_no
          from booking.receipts
         where (series, year, seq) in (
           select x.series, x.year, x.seq from booking.receipts x group by x.series, x.year, x.seq having count(*) > 1
         )
           and id not in (
             select min(x.id) from booking.receipts x group by x.series, x.year, x.seq having count(*) > 1
           )
         order by id
      loop
        select coalesce(max(x.seq), 0) + 1 into v_seq from booking.receipts x where x.series = dup.series and x.year = dup.year;
        while exists (select 1 from booking.receipts x where x.series = dup.series and x.year = dup.year and x.seq = v_seq) loop
          v_seq := v_seq + 1;
          if v_seq > 1000000 then
            raise exception 'booking_197: free seq not found for id %', dup.id;
          end if;
        end loop;
        update booking.receipts set seq = v_seq where id = dup.id;
        n_seqfix := n_seqfix + 1;
        raise notice 'booking_197: moved seq of receipt id % (%) from % to %; receipt_no unchanged', dup.id, dup.receipt_no, dup.seq, v_seq;
      end loop;

      alter table booking.receipts enable trigger receipts_guard;
    exception when others then
      alter table booking.receipts enable trigger receipts_guard;
      raise;
    end;
  end if;

  raise notice 'booking_197: renumbered=% seq_moved=% (unique receipts not renumbered)', n_ren, n_seqfix;
end
$mig$;

-- ---------- 2) uniikkius tästä eteenpäin ----------
do $uq$
begin
  if not exists (
    select 1 from pg_constraint c
     where c.conrelid = 'booking.receipts'::regclass and c.contype = 'u'
       and (
         select array_agg(a.attname::text order by k.ord)
           from unnest(c.conkey) with ordinality as k(attnum, ord)
           join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
       ) = array['receipt_no']::text[]
  ) then
    alter table booking.receipts add constraint receipts_receipt_no_key unique (receipt_no);
    raise notice 'booking_197: added unique (receipt_no)';
  else
    raise notice 'booking_197: unique (receipt_no) already present';
  end if;

  if not exists (
    select 1 from pg_constraint c
     where c.conrelid = 'booking.receipts'::regclass and c.contype = 'u'
       and (
         select array_agg(a.attname::text order by k.ord)
           from unnest(c.conkey) with ordinality as k(attnum, ord)
           join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
       ) = array['series', 'year', 'seq']::text[]
  ) then
    alter table booking.receipts add constraint receipts_series_year_seq_key unique (series, year, seq);
    raise notice 'booking_197: added unique (series, year, seq)';
  else
    raise notice 'booking_197: unique (series, year, seq) already present';
  end if;
end
$uq$;

insert into booking.receipt_counters as c (series, year, last_seq)
select r.series, r.year, max(r.seq) from booking.receipts r group by r.series, r.year
on conflict (series, year) do update
  set last_seq = greatest(c.last_seq, excluded.last_seq);

-- ---------- 3) laskuri ei uusi numeroa ----------
create or replace function booking._next_receipt_no(p_series text, p_year integer)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  n integer;
  m integer;
  v_no text;
begin
  if p_series is null or p_year is null then
    perform booking._err('invalid_param', 'Kuittisarja puuttuu');
  end if;
  insert into booking.receipt_counters(series, year, last_seq) values (p_series, p_year, 0)
  on conflict (series, year) do nothing;
  select c.last_seq into n from booking.receipt_counters c
   where c.series = p_series and c.year = p_year
   for update;
  select coalesce(max(r.seq), 0) into m from booking.receipts r
   where r.series = p_series and r.year = p_year;
  n := greatest(coalesce(n, 0), coalesce(m, 0)) + 1;
  loop
    v_no := format('%s-%s-%s', p_series, p_year, lpad(n::text, 6, '0'));
    exit when not exists (
      select 1 from booking.receipts r
       where (r.series = p_series and r.year = p_year and r.seq = n)
          or r.receipt_no = v_no
    );
    n := n + 1;
    if n > m + 1000000 then
      perform booking._err('receipt_number', 'Kuittinumeroa ei voitu varata');
    end if;
  end loop;
  update booking.receipt_counters set last_seq = n
   where series = p_series and year = p_year;
  return n;
end $$;

-- ---------- 4) PDF-avain = kuitin uuid + snapshotin tiiviste ----------
create or replace function booking.receipt_snapshot_hash(p_snapshot jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select md5(p_snapshot::text)
$$;

create or replace function booking.receipt_pdf_object_key(p_token uuid, p_snapshot jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_token is null or p_snapshot is null then null
    else lower(p_token::text) || '/' || booking.receipt_snapshot_hash(p_snapshot) || '.pdf'
  end
$$;

create or replace function booking.public_get_receipt(p_order_token uuid, p_receipt_no text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  rc booking.receipts;
  v_ids bigint[];
begin
  if p_order_token is null or nullif(btrim(p_receipt_no), '') is null then
    return jsonb_build_object('ok', false, 'code', 'receipt_not_found', 'message', 'Kuittia ei löydy');
  end if;
  if booking._client_ip() is not null and not booking._rate_limit('receipt:' || booking._client_ip(), 60, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta pyyntöä');
  end if;
  select coalesce(array_agg(r.id order by r.id), '{}') into v_ids
    from booking.receipts r
    join booking.orders o on o.id = r.order_id
   where o.public_token = p_order_token
     and r.receipt_no = p_receipt_no;
  if coalesce(array_length(v_ids, 1), 0) <> 1 then
    return jsonb_build_object('ok', false, 'code', 'receipt_not_found', 'message', 'Kuittia ei löydy');
  end if;
  select * into rc from booking.receipts where id = v_ids[1];
  if rc.order_id is distinct from (select o.id from booking.orders o where o.public_token = p_order_token) then
    return jsonb_build_object('ok', false, 'code', 'receipt_not_found', 'message', 'Kuittia ei löydy');
  end if;
  return jsonb_build_object('ok', true) || booking._receipt_json(rc, false);
end $$;

create or replace function booking.receipt_by_token(p_token uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select booking._receipt_json(rc, false) || jsonb_build_object(
           'order_public_token', o.public_token,
           'content_hash', booking.receipt_snapshot_hash(rc.snapshot),
           'pdf_object_key', booking.receipt_pdf_object_key(rc.public_token, rc.snapshot))
    from booking.receipts rc
    join booking.orders o on o.id = rc.order_id
   where rc.public_token = p_token
     and rc.pdf_deleted_at is null
$$;

create or replace function booking.receipt_set_pdf(p_receipt_id bigint, p_path text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  rc booking.receipts;
  v_key text;
begin
  select * into rc from booking.receipts where id = p_receipt_id;
  if not found or rc.pdf_deleted_at is not null then
    perform booking._err('receipt_not_found', 'Kuittia ei löydy');
  end if;
  v_key := booking.receipt_pdf_object_key(rc.public_token, rc.snapshot);
  if v_key is null or p_path is distinct from v_key or position('/' in p_path) = 0 then
    perform booking._err('receipt_pdf_path', 'PDF-polku ei vastaa kuittia');
  end if;
  update booking.receipts
     set pdf_path = p_path, pdf_generated_at = now()
   where id = p_receipt_id;
end $$;

revoke all on function booking.receipt_snapshot_hash(jsonb) from public, anon, authenticated;
revoke all on function booking.receipt_pdf_object_key(uuid, jsonb) from public, anon, authenticated;
grant execute on function booking.receipt_snapshot_hash(jsonb) to service_role;
grant execute on function booking.receipt_pdf_object_key(uuid, jsonb) to service_role;

comment on function booking.receipt_pdf_object_key(uuid, jsonb) is
  'booking_197: Storage-polku receipts/{public_token}/{md5(snapshot)}.pdf. Ei kuittinumeroa.';
comment on function booking._next_receipt_no(text, integer) is
  'booking_197: seuraava numero on max(laskuri, käytetty seq)+1. Nollattu laskuri ei uusi olemassa olevaa numeroa.';
