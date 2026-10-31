#!/usr/bin/env bash
# Lataa config/env/test.env tai config/env/prod.env ja rakentaa julkaistavan sivuston.
# Ympäristön omat arvot eivät periydy: tiedosto on ainoa lähde SITE_ENV:lle, SITE_URL:lle ja Supabase-avaimille.
#
#   npm run build:test     # GitHub Pages -testi, Supabase DEV
#   npm run build:prod     # saunotus.fi, Supabase PROD (dist/ SFTP:llä, ei Actions-deployta)
#
# Tulostus GitHub Actionsia varten (ei rakenna):
#   bash scripts/build-site.sh --print-env test >> "$GITHUB_ENV"
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
print_only=0
if [[ "${1:-}" == "--print-env" ]]; then
  print_only=1
  shift
fi
name=${1:-}
if [[ "$name" != "test" && "$name" != "prod" ]]; then
  echo "build-site: käyttö: scripts/build-site.sh [--print-env] test|prod" >&2
  exit 2
fi
file="$root/config/env/${name}.env"
if [[ ! -f "$file" ]]; then
  echo "build-site: puuttuu $file" >&2
  exit 2
fi

unset SITE_ENV SITE_URL BOOKING_SUPABASE_URL BOOKING_ANON_KEY
got_site_env=0
got_site_url=0
got_supabase_url=0
got_anon_key=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    echo "build-site: virheellinen rivi tiedostossa ${name}.env" >&2
    exit 2
  fi
  key="${BASH_REMATCH[1]}"
  val="${BASH_REMATCH[2]}"
  case "$key" in
    SITE_ENV|SITE_URL|BOOKING_SUPABASE_URL|BOOKING_ANON_KEY) ;;
    *) echo "build-site: avainta $key ei sallita ympäristötiedostossa" >&2; exit 2 ;;
  esac
  if [[ "$val" == *"'"* || "$val" == *'"'* || "$val" == *$'\n'* || "$val" == *" "* ]]; then
    echo "build-site: avaimen $key arvo ei ole pelkkä tunnus tai osoite" >&2
    exit 2
  fi
  case "$key" in
    SITE_ENV)
      if [[ "$got_site_env" == 1 ]]; then echo "build-site: SITE_ENV kahdesti" >&2; exit 2; fi
      got_site_env=1 ;;
    SITE_URL)
      if [[ "$got_site_url" == 1 ]]; then echo "build-site: SITE_URL kahdesti" >&2; exit 2; fi
      got_site_url=1 ;;
    BOOKING_SUPABASE_URL)
      if [[ "$got_supabase_url" == 1 ]]; then echo "build-site: BOOKING_SUPABASE_URL kahdesti" >&2; exit 2; fi
      got_supabase_url=1 ;;
    BOOKING_ANON_KEY)
      if [[ "$got_anon_key" == 1 ]]; then echo "build-site: BOOKING_ANON_KEY kahdesti" >&2; exit 2; fi
      got_anon_key=1 ;;
  esac
  printf -v "$key" '%s' "$val"
  export "$key"
done < "$file"

missing=""
[[ "$got_site_env" == 1 ]] || missing+=" SITE_ENV"
[[ "$got_site_url" == 1 ]] || missing+=" SITE_URL"
[[ "$got_supabase_url" == 1 ]] || missing+=" BOOKING_SUPABASE_URL"
[[ "$got_anon_key" == 1 ]] || missing+=" BOOKING_ANON_KEY"
if [[ -n "$missing" ]]; then
  echo "build-site: ${name}.env:sta puuttuu:${missing}" >&2
  exit 2
fi
if [[ "$SITE_ENV" != "$name" ]]; then
  echo "build-site: ${name}.env asettaa SITE_ENV=${SITE_ENV}, odotettiin ${name}" >&2
  exit 2
fi

if [[ "$print_only" == 1 ]]; then
  printf 'SITE_ENV=%s\n' "$SITE_ENV"
  printf 'SITE_URL=%s\n' "$SITE_URL"
  printf 'BOOKING_SUPABASE_URL=%s\n' "$BOOKING_SUPABASE_URL"
  printf 'BOOKING_ANON_KEY=%s\n' "$BOOKING_ANON_KEY"
  exit 0
fi

cd "$root"
exec node scripts/build-pages.mjs
