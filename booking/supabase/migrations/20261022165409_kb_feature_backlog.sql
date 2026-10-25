-- HISTORY-SYNC: applied in production, do not rerun. Tuotannon versio 20261022165409 (kb_feature_backlog), Supabase sxbofnuisemspgquoxyv.
-- Lähde: tuotannon supabase_migrations.schema_migrations.statements[1] (md5 fa33e0250ebc76e55f9acc9e8add3df1, 5318 merkkiä).
-- Runko on tuotannon lause sanatarkasti rivien "execute $hs_20261022165409$" ja "$hs_20261022165409$;" välissä.
-- Vartija: jos taulu kb.feature_backlog on olemassa, migraatio on jo ajettu ja koko tiedosto ohitetaan (uudelleenajo = no-op, ei katalogimuutoksia).
-- Lause luo taulun ilman if not exists -ehtoja ja lisää 18 alkuriviä; myöhemmin 20261025130308_backlog_categories_v2 muuttaa taulua ja rivejä,
-- joten sellaisenaan uudelleen ajettuna se kaatuisi tai lisäisi tuplarivejä.
do $hs$
begin
  if to_regclass('kb.feature_backlog') is not null then
    raise notice 'history-sync 20261022165409: jo ajettu, ohitetaan';
    return;
  end if;
  execute $hs_20261022165409$
create table kb.feature_backlog (
  id bigint generated always as identity primary key,
  position integer not null,
  title text not null,
  description text,
  area text,
  status text not null default 'queued' check (status in ('queued','approved','in_progress','done','cancelled','on_hold')),
  needs_approval boolean not null default true,
  owner_bot text not null default 'Koodari',
  target_date date,
  notes text,
  decided_by text not null default 'Joonas',
  decided_at date not null default current_date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table kb.feature_backlog is 'Joonaksen yksi ja ainoa ominaisuuksien todo-lista. Järjestys = position (1 = seuraavaksi). Toteutus Koodarille vasta Joonaksen luvalla (needs_approval). Ylläpitäjä: Bottiavustus.';
create index feature_backlog_position_idx on kb.feature_backlog (position) where status not in ('done','cancelled');
create or replace function kb.feature_backlog_touch() returns trigger language plpgsql set search_path = '' as $$ begin new.updated_at := now(); return new; end $$;
create trigger feature_backlog_touch before update on kb.feature_backlog for each row execute function kb.feature_backlog_touch();
alter table kb.feature_backlog enable row level security;
create policy feature_backlog_read on kb.feature_backlog for select to authenticated using (true);
grant select on kb.feature_backlog to authenticated;
grant select, insert, update on kb.feature_backlog to service_role;
do $$ begin if exists (select 1 from pg_roles where rolname='backup_reader') then execute 'grant select on kb.feature_backlog to backup_reader'; end if; end $$;
insert into kb.feature_backlog (position, title, description, area, target_date, needs_approval, notes) values
(1,'Hallinnan navigaatio ja mobiilisivupalkki','Tilaukset omaksi navigaationapiksi; Varaukset pois navigaatiosta ja välilehdeksi Tilausten alle (tulevat varaukset lähin ensin, järjestys vaihdettavissa suotimista; tilausten oletusjärjestys pidetään). Mobiilissa hyvin kapea vasemman laidan ikonipalkki, alalaidan nuolesta selitystekstit näkyviin.','hallinta','2026-10-24',true,null),
(2,'Saatavuushaun nopeutus','Varauskalenterin saatavuushaun nopeuttaminen.','varausjärjestelmä',null,true,'Joonas nosti kakkoseksi 22.10.'),
(3,'Tekstieditorin vaihto Quilliin','Trix korvataan Quillilla kaikkialla (Viestit, tuotekuvaukset). Ladataan vasta tarvittaessa, vendoroitu, sama sallittu HTML, taaksepäin yhteensopiva.','hallinta','2026-10-24',true,null),
(4,'Viestien toimitustapa','Jokaiselle viestille valinta: ajastettu lähetys tai ohjeet tilauksen yhteydessä (ei erillistä lähetystä; lyhyt versio näkyvissä, pitkä viesti asiakkaan tilaussivulta).','hallinta','2026-10-24',true,null),
(5,'Tilaussivun tyylien yhtenäistäminen','Asiakkaan oman tilaussivun kaikki sisällöt samoilla fonttityyleillä; maksuosio (Visma Pay, MobilePay, lahjakortti) samalla laatikko- ja otsikkotyylillä kuin muut laatikot.','asiakkaan tilaussivu','2026-10-24',true,null),
(6,'Vuorotarjousten viimeistely ja käyttöönotto','Koodin tarkistus (sähköposti milloin vain, WhatsApp 8–21, yölähetykset iltaan/aamuun, Joonas ja Otto botin kautta), henkilökunnan sähköpostit sallituiksi, WhatsApp Meta-julkaisun jälkeen. Bottiavustus saa kytkeä päälle, kun valmista; sen jälkeen Työvuoro-Tapio hallinnoi.','työvuorot',null,false,'Joonas antoi luvan kytkeä päälle 22.10.'),
(7,'Lisämyynti kassalla ja tilaussivulla','Varauksen yhteydessä ehdotetaan sopivia lisiä (pyyhkeet, juomat, hoidot); myös muistutusviestissä ennen saapumista.','myynti',null,true,null),
(8,'Automaattinen arvostelujen keruu','Palautepyyntö: tyytyväiset ohjataan Googleen, tyytymättömät antavat palautteen ensin meille.','myynti',null,true,null),
(9,'Henkilökunnan päivänäkymä ja muistiinpanot','Päivän saapujat, lisätilaukset ja erityistoiveet; varaukseen sisäiset muistiinpanot seuraavalle työntekijälle.','hallinta',null,true,null),
(10,'Vuoro- ja tehtäväilmoitukset henkilökunnalle','Ilmoitus työntekijälle, kun vuoroon tulee varaus, muutos tai tehtävä; kytkeytyy Työvuoro-Tapion tietoihin ja WhatsAppiin.','työvuorot',null,true,null),
(11,'Johdon raporttinäkymä','Täyttöaste, myynti tuotteittain, lisämyynnin osuus, uudet vs palaavat asiakkaat, vertailu viime vuoteen; viikkoraportti sähköpostiin.','raportointi',null,true,null),
(12,'Jonotuslista täysiin vuoroihin','Asiakas liittyy jonoon; peruutuksessa paikka tarjotaan automaattisesti.','varausjärjestelmä',null,true,null),
(13,'Hiljaisten aikojen tarjoukset','Tyhjät vuorot muutaman päivän päässä tarjotaan alennuksella sivustolla tai markkinointiluvan antaneille.','myynti',null,true,null),
(14,'Lahjakorttikampanjat','Ajastetut kampanjat juhlapyhiin; yrityksille massalahjakortit omalla lomakkeella. Mieluiten ennen joulusesonkia.','myynti',null,true,null),
(15,'Asiakasryhmät ja uutiskirje','Markkinointiluvan antaneiden ryhmittely ja kohdennetut viestit hallinnasta.','markkinointi',null,true,null),
(16,'Kanta-asiakkuus','Leima- tai pisteohjelma, saldo tilaussivulla.','myynti',null,true,null),
(17,'Hallinta PWA-sovellukseksi','Hallinta asennettavaksi sovellukseksi siirron yhteydessä.','hallinta','2026-11-01',true,null),
(18,'Sisäinen tietopankki','Henkilökunnan sisäinen tietopankki.','henkilökunta',null,true,null);
$hs_20261022165409$;
end $hs$;
