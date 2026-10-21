#!/usr/bin/env bash
# Lähettää saman age-varmuuskopion Hetznerille Drive-lähetyksen jälkeen.
# Palvelin hyväksyy vain komennon: upload <nimi>.age (stdin = tiedosto).
# Yksityistä avainta ei tulosteta. Avaintiedosto on oikeuksin 600 ja poistetaan lopuksi.
set -euo pipefail
umask 077

host="${BACKUP_SSH_HOST:-}"
host="${host//[[:space:]]/}"
if [[ -z "$host" ]]; then
  echo "::notice title=Hetzner ohitettu::BACKUP_SSH_HOST puuttuu. Varmuuskopio jää Driveen."
  exit 0
fi

if [[ -z "${BACKUP_SSH_USER:-}" ]]; then
  echo "hetzner: BACKUP_SSH_USER puuttuu" >&2
  exit 1
fi
if [[ -z "${BACKUP_SSH_KEY:-}" ]]; then
  echo "hetzner: BACKUP_SSH_KEY puuttuu" >&2
  exit 1
fi
if [[ -z "${BACKUP_SSH_KNOWN_HOSTS:-}" ]]; then
  echo "hetzner: BACKUP_SSH_KNOWN_HOSTS puuttuu" >&2
  exit 1
fi
if [[ -z "${BACKUP_AGE_DIR:-}" ]]; then
  echo "hetzner: BACKUP_AGE_DIR puuttuu" >&2
  exit 1
fi
if [[ ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$ ]]; then
  echo "hetzner: BACKUP_SSH_HOST ei ole kelvollinen isäntänimi" >&2
  exit 1
fi
if [[ ! "${BACKUP_SSH_USER}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
  echo "hetzner: BACKUP_SSH_USER ei ole kelvollinen käyttäjätunnus" >&2
  exit 1
fi
BACKUP_SSH_HOST="$host"

run_id="${GITHUB_RUN_ID:-}"
attempt="${GITHUB_RUN_ATTEMPT:-1}"
if [[ ! "$run_id" =~ ^[0-9]+$ ]]; then
  echo "hetzner: GITHUB_RUN_ID puuttuu tai ei ole numero" >&2
  exit 1
fi
if [[ ! "$attempt" =~ ^[0-9]+$ ]]; then
  echo "hetzner: GITHUB_RUN_ATTEMPT ei ole numero" >&2
  exit 1
fi
if [[ ! -d "$BACKUP_AGE_DIR" ]]; then
  echo "hetzner: age-hakemistoa ei ole" >&2
  exit 1
fi

shopt -s nullglob
files=("$BACKUP_AGE_DIR"/*.age)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "hetzner: age-tiedostoja ei löydy" >&2
  exit 1
fi
mapfile -t files < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort)

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ ! "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
  echo "hetzner: aikaleima epäonnistui" >&2
  exit 1
fi

name_re='^[A-Za-z0-9._-]+\.age$'
sources=()
remotes=()
declare -A seen=()
for src in "${files[@]}"; do
  if [[ ! -f "$src" ]]; then
    echo "hetzner: ei tavallinen tiedosto" >&2
    exit 1
  fi
  base="$(basename "$src")"
  if [[ ! "$base" =~ $name_re ]]; then
    echo "hetzner: tiedostonimi ei kelpaa palvelimelle" >&2
    exit 1
  fi
  stem="${base%.age}"
  remote="${stem}.${stamp}.r${run_id}.a${attempt}.age"
  if [[ ! "$remote" =~ $name_re ]]; then
    echo "hetzner: etänimi ei kelpaa palvelimelle" >&2
    exit 1
  fi
  if [[ -n "${seen[$remote]:-}" ]]; then
    echo "hetzner: etänimi ei ole uniikki" >&2
    exit 1
  fi
  seen["$remote"]=1
  sources+=("$src")
  remotes+=("$remote")
done

command -v ssh >/dev/null 2>&1 || { echo "hetzner: ssh puuttuu" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "hetzner: python3 puuttuu" >&2; exit 1; }

keydir="$(mktemp -d "${TMPDIR:-/tmp}/tapio-hetzner.XXXXXX")"
chmod 700 "$keydir"
cleanup() {
  local dir="${keydir:-}"
  if [[ "$dir" == *"tapio-hetzner."* && -d "$dir" ]]; then
    rm -rf "$dir"
  fi
}
trap cleanup EXIT

KEY_PATH="$keydir/id" KNOWN_PATH="$keydir/known_hosts" python3 - <<'PY'
import os
from pathlib import Path

def finish(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if not text.endswith("\n"):
        text += "\n"
    return text

key_path = Path(os.environ["KEY_PATH"])
known_path = Path(os.environ["KNOWN_PATH"])
key_path.write_text(finish(os.environ["BACKUP_SSH_KEY"]))
known_path.write_text(finish(os.environ["BACKUP_SSH_KNOWN_HOSTS"]))
os.chmod(key_path, 0o600)
os.chmod(known_path, 0o600)
PY

chmod 600 "$keydir/id" "$keydir/known_hosts"
[[ "$(stat -c '%a' "$keydir/id")" == "600" ]]
[[ "$(stat -c '%a' "$keydir/known_hosts")" == "600" ]]

# Älä jätä avainta ssh-prosessin ympäristöön. Tiedosto riittää ja se poistetaan.
unset BACKUP_SSH_KEY BACKUP_SSH_KNOWN_HOSTS

echo "hetzner: kohde ${BACKUP_SSH_USER}@${BACKUP_SSH_HOST} (${#sources[@]} tiedostoa)"

for i in "${!sources[@]}"; do
  src="${sources[$i]}"
  remote="${remotes[$i]}"
  bytes="$(stat -c '%s' "$src")"
  [[ "$bytes" =~ ^[0-9]+$ ]]
  set +e
  response="$(
    ssh -T \
      -i "$keydir/id" \
      -o UserKnownHostsFile="$keydir/known_hosts" \
      -o GlobalKnownHostsFile=/dev/null \
      -o StrictHostKeyChecking=yes \
      -o BatchMode=yes \
      -o IdentitiesOnly=yes \
      -o PasswordAuthentication=no \
      -o PreferredAuthentications=publickey \
      -o NumberOfPasswordPrompts=0 \
      -o UpdateHostKeys=no \
      -o ConnectTimeout=30 \
      -o LogLevel=ERROR \
      -- \
      "${BACKUP_SSH_USER}@${BACKUP_SSH_HOST}" \
      "upload ${remote}" < "$src"
  )"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "hetzner: ssh epäonnistui (${rc}) tiedostolle ${remote}" >&2
    exit 1
  fi
  response="${response//$'\r'/}"
  if [[ "$response" != "ok ${bytes}" ]]; then
    echo "hetzner: vastaus ei täsmää tiedostolle ${remote} (odotettiin ok ${bytes})" >&2
    exit 1
  fi
  echo "hetzner: ${remote} ok ${bytes}"
done
