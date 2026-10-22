#!/usr/bin/env bash
# Johku-synkka Varmistajalla. Ei sudoa. Lukitsee päällekkäiset ajot.
# Salaisuudet: ~/.secrets/johku.env ja ~/.secrets/johku_sync.env (chmod 600).
# Hälytys: jos ~/valvonta/lib.sh määrittelee funktion alert, sitä kutsutaan.
set -u
cd "$(dirname "$0")"
umask 077
LOCK="${HOME}/.johku-sync.lock"
mkdir -p "${HOME}/.johku-sync"
exec 9>>"$LOCK"
if ! flock -n 9; then
  echo "johku-sync: edellinen ajo kesken" >&2
  exit 75
fi
if ! python3 sync.py "$@"; then
  msg="johku-sync failed"
  echo "$msg" >&2
  if [[ -f "${HOME}/valvonta/lib.sh" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/valvonta/lib.sh"
    if declare -F alert >/dev/null 2>&1; then
      alert "$msg"
    fi
  fi
  exit 1
fi
