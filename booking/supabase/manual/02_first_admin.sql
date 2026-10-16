-- 2. Ensimmäinen admin (ajetaan käsin SQL Editorissa tai Bottiavustuksen kautta, MIGRAATIOIDEN JÄLKEEN)
--
-- Roolit (taulu booking.roles, oikeudet taulussa booking.role_permissions):
--   admin    = kaikki oikeudet (Joonas ja Koodari): myös käyttäjähallinta (kutsut, roolit) ja audit-loki
--   manager  = ylläpitäjä (Otto ja Laura): varaukset + hinnat, kuvaukset, tuoteasetukset, muut asetukset, resurssit,
--              vuorosääntöjen muokkaus, vuosikortit ja kaikkien työvuorojen katselu. EI käyttäjähallintaa.
--   staff    = peruskäyttäjä (kaikki työntekijät): varausten ja asiakkaiden katselu ja luonti/muokkaus, maksujen kirjaus, sulut, omat työvuorot.
--              EI hinta-, tuote- eikä asetusmuokkausta.
--   customer / annual_card = EI henkilöstöä (ei hallintaoikeuksia). Vain asiakastyyppejä (booking.customers.customer_type).
--
-- a) Luo kullekin henkilölle käyttäjä Supabase Authissa: Dashboard → Authentication → Users → Add user → "Create new user"
--    (sähköposti + salasana, ruksi "Auto Confirm User"). Älä käytä sähköpostia jota ei omista.
-- b) TESTIVAIHE: ajetaan vain tämä YKSI lohko (Joonas = admin). Muut lohkot on kommentoitu pois; muut käyttäjät kutsutaan
--    myöhemmin hallinnan Käyttäjät-näkymästä (Edge Function admin-users), jolloin ei tarvita SQL:ää eikä käsin luotuja tunnuksia.

-- b1) ADMIN: Joonas (kaikki oikeudet). Sähköposti on sama jolla tunnus on luotu Supabase Authissa.
insert into booking.staff (user_id, email, name, role, active)
select id, email, 'Joonas Vaarala', 'admin', true
  from auth.users where lower(email) = lower('Joonas.vaarala@gmail.com')   -- Auth tallentaa sähköpostin pienillä kirjaimilla
on conflict (user_id) do update set role = 'admin', active = true;

-- ---- MYÖHEMMIN / TARVITTAESSA (kommentoitu pois testivaiheessa) ----
-- b1b) ADMIN: Koodari
-- insert into booking.staff (user_id, email, name, role, active)
-- select id, email, 'Koodari', 'admin', true
--   from auth.users where email = 'KOODARI@ESIMERKKI.FI'        -- <-- vaihda
-- on conflict (user_id) do update set role = 'admin', active = true;
--
-- b2) MANAGER (ylläpitäjä): Otto ja Laura (hinnat, kuvaukset, asetukset, resurssit, vuorosäännöt, kaikkien työvuorot)
-- insert into booking.staff (user_id, email, name, role, active)
-- select id, email, 'Otto', 'manager', true
--   from auth.users where email = 'OTTO@ESIMERKKI.FI'          -- <-- vaihda
-- on conflict (user_id) do update set role = 'manager', active = true;
-- insert into booking.staff (user_id, email, name, role, active)
-- select id, email, 'Laura', 'manager', true
--   from auth.users where email = 'LAURA@ESIMERKKI.FI'          -- <-- vaihda
-- on conflict (user_id) do update set role = 'manager', active = true;
--
-- b3) STAFF (peruskäyttäjä): muut työntekijät (varaukset ja asiakkaat, omat työvuorot)
-- insert into booking.staff (user_id, email, name, role, active)
-- select id, email, 'Työntekijä Esimerkki', 'staff', true
--   from auth.users where email = 'TYONTEKIJA@ESIMERKKI.FI'    -- <-- vaihda
-- on conflict (user_id) do update set role = 'staff', active = true;

-- c) Tarkista:
select s.user_id, s.email, s.name, s.role, r.label as rooli, s.active
  from booking.staff s join booking.roles r on r.code = s.role order by r.sort_order, s.name;
-- Mitä oikeuksia kukin rooli antaa:
select role_code, string_agg(permission, ', ' order by permission) as oikeudet from booking.role_permissions group by role_code order by role_code;

-- Lisähenkilöt, roolimuutokset ja käytöstä poisto: hallinnan Käyttäjät-näkymä (vain admin) kun ensimmäinen admin on olemassa.
-- (Käytöstä poisto hallinnasta estää myös kirjautumisen Authissa; pelkkä SQL-päivitys active = false ei estä Auth-kirjautumista, vain pääsyn hallintaan.)
--
-- UUDEN ROOLIN LISÄÄMINEN (ei koodimuutoksia; esim. "kirjanpitäjä", joka saa vain lukea ja kirjata maksuja):
--   insert into booking.roles (code, label, description, is_staff, sort_order) values ('bookkeeper', 'Kirjanpitäjä', 'Maksut', true, 25);
--   insert into booking.role_permissions (role_code, permission) values ('bookkeeper', 'payments.manage');
--   -- sen jälkeen rooli on valittavissa hallinnan Käyttäjät-näkymässä (roolin vaihto). Oikeuslista: ks. booking.role_permissions / docs/roolit-ja-kb.md
