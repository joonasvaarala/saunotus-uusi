# 1. Skeeman `booking` avaaminen REST-rajapintaan (kertaluonteinen, käsin)

Migraatiot luovat skeeman, mutta PostgREST (Supabasen REST) näkee vain "Exposed schemas" -listalla olevat skeemat.

**Dashboard:** Project Settings → Data API → *Exposed schemas* → lisää `booking` olemassa olevan listan jatkoksi (ÄLÄ poista nykyisiä).
Jätä *Extra search path* ennalleen. Tallenna.

**SQL-vaihtoehto** (Bottiavustus; täydennä nykyinen lista ensin dashboardista!):

```sql
-- esimerkki: jos nykyinen lista on "public, graphql_public", uusi on "public, graphql_public, booking"
alter role authenticator set pgrst.db_schemas = 'public, graphql_public, booking';
notify pgrst, 'reload config';
```

Tarkistus: `curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/public_settings" -H "apikey: $ANON" -H "Content-Profile: booking"` palauttaa JSONin.

Huom: public-skeemaa (Työvuoro-Tapio) ei kosketa mikään migraatio.
