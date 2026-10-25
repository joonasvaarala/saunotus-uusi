-- botgw hätäkatkaisu (ops, käsin ajettava; ei migraatio). Ajetaan heti tarvittaessa: kaikki bottiavaimet ja Työvuoro-Tapion herätys pois.
-- Palautus: avaimen uudelleenmyöntö (koodari_otto.md §5) ja wake_targets.active=true vain Joonaksen luvalla.
-- Edge-tason katkaisu erikseen: supabase secrets set BOTGW_DISABLED=1 (bot-gateway palauttaa 503 kutsumatta tietokantaa).
-- Hätäkatkaisu: kaikki bottiavaimet ja Työvuoro-Tapion herätys pois heti.
update botgw.bot_clients set active = false;
update botgw.wake_targets set active = false;
