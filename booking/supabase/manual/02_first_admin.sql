-- 2. Henkilökunnan käyttäjät ja roolit (ajetaan käsin SQL Editorissa tai Bottiavustuksen kautta, MIGRAATIOIDEN JÄLKEEN)
--
-- Roolit (taulu booking.roles, oikeudet taulussa booking.role_permissions):
--   admin    = kaikki oikeudet (Joonas ja Koodari): myös henkilöstön/roolien hallinta ja audit-loki
--   manager  = ylläpitäjä (Otto ja Laura): varaukset + hinnat, kuvaukset, tuoteasetukset, muut asetukset, resurssit,
--              vuorosääntöjen muokkaus ja vuosikortit. EI henkilöstön hallintaa.
--   staff    = peruskäyttäjä (kaikki työntekijät): varausten ja asiakkaiden katselu ja luonti/muokkaus, maksujen kirjaus, sulut.
--              EI hinta-, tuote- eikä asetusmuokkausta.
--   customer / annual_card = EI henkilöstöä (ei hallintaoikeuksia). Vain asiakastyyppejä (booking.customers.customer_type).
--
-- a) Luo kullekin henkilölle käyttäjä Supabase Authissa: Dashboard → Authentication → Users → Add user → "Create new user"
--    (sähköposti + salasana, ruksi "Auto Confirm User"). Älä käytä sähköpostia jota ei omista.
-- b) Aja alla olevat KOLME erillistä lohkoa (vaihda sähköpostit ja nimet; ajettavat voi lisätä/poistaa tarpeen mukaan).

-- b1) ADMIN: Joonas ja Koodari (kaikki oikeudet)
insert into booking.staff (user_id, email, name, role, active)
select id, email, 'Joonas Vaarala', 'admin', true
  from auth.users where email = 'JOONAS@ESIMERKKI.FI'        -- <-- vaihda
on conflict (user_id) do update set role = 'admin', active = true;

insert into booking.staff (user_id, email, name, role, active)
select id, email, 'Koodari', 'admin', true
  from auth.users where email = 'KOODARI@ESIMERKKI.FI'        -- <-- vaihda
on conflict (user_id) do update set role = 'admin', active = true;

-- b2) MANAGER (ylläpitäjä): Otto ja Laura (hinnat, kuvaukset, asetukset, resurssit, vuorosäännöt)
insert into booking.staff (user_id, email, name, role, active)
select id, email, 'Otto', 'manager', true
  from auth.users where email = 'OTTO@ESIMERKKI.FI'          -- <-- vaihda
on conflict (user_id) do update set role = 'manager', active = true;

insert into booking.staff (user_id, email, name, role, active)
select id, email, 'Laura', 'manager', true
  from auth.users where email = 'LAURA@ESIMERKKI.FI'          -- <-- vaihda
on conflict (user_id) do update set role = 'manager', active = true;

-- b3) STAFF (peruskäyttäjä): muut työntekijät (varaukset ja asiakkaat, ei hinta-/asetusmuokkausta)
insert into booking.staff (user_id, email, name, role, active)
select id, email, 'Työntekijä Esimerkki', 'staff', true
  from auth.users where email = 'TYONTEKIJA@ESIMERKKI.FI'    -- <-- vaihda
on conflict (user_id) do update set role = 'staff', active = true;

-- c) Tarkista:
select s.user_id, s.email, s.name, s.role, r.label as rooli, s.active
  from booking.staff s join booking.roles r on r.code = s.role order by r.sort_order, s.name;
-- Mitä oikeuksia kukin rooli antaa:
select role_code, string_agg(permission, ', ' order by permission) as oikeudet from booking.role_permissions group by role_code order by role_code;

-- Lisähenkilöt ja roolimuutokset voi jatkossa tehdä hallinnasta (Asetukset → Henkilökunta; vain admin) kun ensimmäinen admin on olemassa.
-- Käytöstä poisto: update booking.staff set active = false where email = '...';   (viimeistä adminia ei voi poistaa hallinnasta)
--
-- UUDEN ROOLIN LISÄÄMINEN (ei koodimuutoksia; esim. "kirjanpitäjä", joka saa vain lukea ja kirjata maksuja):
--   insert into booking.roles (code, label, description, is_staff, sort_order) values ('bookkeeper', 'Kirjanpitäjä', 'Maksut', true, 25);
--   insert into booking.role_permissions (role_code, permission) values ('bookkeeper', 'payments.manage');
--   -- sen jälkeen rooli on valittavissa hallinnan henkilöstölistassa. Oikeuslista: ks. booking.role_permissions / docs/roolit-ja-kb.md
