-- 2. Ensimmäinen ylläpitäjä (ajetaan käsin SQL Editorissa tai Bottiavustuksen kautta, MIGRAATIOIDEN JÄLKEEN)
--
-- a) Luo käyttäjä Supabase Authissa: Dashboard → Authentication → Users → Add user → "Create new user"
--    (sähköposti + salasana, ruksi "Auto Confirm User"). Älä käytä sähköpostia jota ei omista.
-- b) Aja alla oleva, vaihda sähköposti ja nimi:
insert into booking.staff (user_id, email, name, role, active)
select id, email, 'Joonas Vaarala', 'admin', true
  from auth.users
 where email = 'JOONAS@ESIMERKKI.FI'      -- <-- vaihda
on conflict (user_id) do update set role = 'admin', active = true;

-- c) Tarkista:
select user_id, email, name, role, active from booking.staff;

-- Lisähenkilöt voi jatkossa lisätä hallinnasta (Asetukset → Henkilökunta) kun ensimmäinen admin on olemassa.
-- Poistettaessa oikeudet: update booking.staff set active = false where email = '...';
