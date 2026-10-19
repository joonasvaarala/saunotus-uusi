"""Jaetut tarkistukset Tapio-havuhattu-varmuuskopiolle.

Ei verkkoa eikä tietokantayhteyttä. Salaisuuksia ei tulosteta.
"""
from __future__ import annotations

import re
from datetime import date, datetime, timedelta, timezone

PROJECT_REF = "sxbofnuisemspgquoxyv"
FILENAME_RE = re.compile(
    r"^tapio-havuhattu_(\d{4})-(\d{2})-(\d{2})_(\d{4})\.dump\.tar\.age$"
)
AGE_PUBLIC_RE = re.compile(r"^age1[0-9a-z]{20,120}$")
FOLDER_ID_RE = re.compile(r"^[A-Za-z0-9_-]{10,128}$")
REQUIRED_SCHEMAS = (
    "public",
    "kb",
    "booking",
    "auth",
    "storage",
    "supabase_migrations",
)
OPTIONAL_SCHEMAS = ("cron",)
# (skeema, taulu, pakollinen). booking.bookings ei ole olemassa:
# varaukset ovat booking.reservations.
KEY_TABLES = (
    ("booking", "orders", True),
    ("booking", "payments", True),
    ("booking", "gift_cards", True),
    ("booking", "reservations", True),
    ("kb", "products", True),
    ("booking", "bookings", False),
)
RESTORE_DB = "backup_restore_test"
ALLOWED_RESTORE_HOSTS = frozenset({"localhost", "127.0.0.1", "::1", "postgres"})
IDENT_RE = re.compile(r"^[a-z_][a-z0-9_]*$")


class BackupError(SystemExit):
    """Käyttäjälle näkyvä virhe. SystemExit pitää unittestissä napattavana."""


def utc_today() -> date:
    return datetime.now(timezone.utc).date()


def sub_months(day: date, months: int) -> date:
    if months < 0:
        raise BackupError("kuukausimäärä ei voi olla negatiivinen")
    month_index = day.year * 12 + (day.month - 1) - months
    year, month0 = divmod(month_index, 12)
    month = month0 + 1
    # Päivä ei ole kuukauden 1. päivän laskennassa oleellinen, mutta pidetään kelvollisena.
    last = [31, 29 if year % 4 == 0 and (year % 100 != 0 or year % 400 == 0) else 28,
            31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    return date(year, month, min(day.day, last))


def assert_flat_name(name: str) -> None:
    if not isinstance(name, str) or name != name.strip() or not name:
        raise BackupError(f"turvatarkistus: tyhjä tai reunavälejä sisältävä nimi {name!r}")
    if "/" in name or "\\" in name or name in {".", ".."} or ".." in name:
        raise BackupError(f"turvatarkistus: polku ei ole yksittäinen tiedostonimi {name!r}")


def filename_date(name: str) -> date | None:
    """Palauttaa päivän, jos nimi on kuvion mukainen ja kalenteripäivä on kelvollinen."""
    match = FILENAME_RE.match(name)
    if not match:
        return None
    try:
        return date(int(match.group(1)), int(match.group(2)), int(match.group(3)))
    except ValueError:
        return None


def retention_action(name: str, today: date, daily_days: int = 30, monthly_months: int = 12) -> str:
    """keep, delete tai ignore. Virheellinen päivä tai vieras nimi ei koskaan ole delete."""
    if daily_days < 2:
        raise BackupError("päiväraja on alle 2, säilytystä ei ajeta")
    if monthly_months < 1:
        raise BackupError("kuukausiraja puuttuu")
    assert_flat_name(name)
    if FILENAME_RE.match(name) is None:
        return "ignore"
    day = filename_date(name)
    if day is None:
        return "ignore"
    if day > today:
        return "keep"
    if day >= today - timedelta(days=daily_days):
        return "keep"
    if day.day == 1 and day >= sub_months(today, monthly_months):
        return "keep"
    return "delete"


def retention_plan(
    names: list[str],
    today: date,
    daily_days: int = 30,
    monthly_months: int = 12,
    min_keep: int = 1,
    max_delete: int = 400,
) -> dict:
    keep: list[str] = []
    delete: list[str] = []
    ignore: list[str] = []
    for name in names:
        action = retention_action(name, today, daily_days, monthly_months)
        if action == "keep":
            keep.append(name)
        elif action == "delete":
            # Toinen portti: poistolistan jäsenen on täsmättävä kuvioon ja kelvolliseen päivään.
            if filename_date(name) is None:
                raise BackupError(f"turvatarkistus esti poiston: {name}")
            delete.append(name)
        else:
            ignore.append(name)
    if max_delete < 1:
        raise BackupError("max_delete on alle 1")
    if len(delete) > max_delete:
        raise BackupError(
            f"poistolista {len(delete)} ylittää rajan {max_delete}. "
            "Mitään ei poistettu. Nosta BACKUP_RETENTION_MAX_DELETE vain jos lista on oikea."
        )
    if (keep or delete) and len(keep) < min_keep:
        raise BackupError(
            f"säilytys jättäisi {len(keep)} kuvion mukaista tiedostoa, minimi on {min_keep}. "
            "Mitään ei poistettu."
        )
    return {"keep": keep, "delete": delete, "ignore": ignore}


def check_restore_target(url: str, source_url: str | None = None) -> None:
    """Kieltää tuotannon ja kaiken muun paitsi paikallisen ylläpitokannan."""
    from urllib.parse import urlparse

    if not url or not url.strip():
        raise BackupError("RESTORE_TARGET_URL puuttuu")
    if source_url and url.strip() == source_url.strip():
        raise BackupError("palautuksen kohde on sama osoite kuin varmuuskopion lähde")
    lowered = url.lower()
    if "supabase" in lowered or PROJECT_REF in lowered:
        raise BackupError("palautus tuotantoon tai Supabase-osoitteeseen on kielletty")
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if host not in ALLOWED_RESTORE_HOSTS:
        raise BackupError(f"palautuksen kone {host or '(tyhjä)'} ei ole sallittujen listalla")
    database = (parsed.path or "").lstrip("/")
    if database != "postgres":
        raise BackupError("palautuksen ylläpitokannan nimen on oltava postgres")
    if parsed.username is None or parsed.password is None:
        raise BackupError("palautusosoitteesta puuttuu käyttäjä tai salasana")


def quote_ident(name: str) -> str:
    if not IDENT_RE.match(name):
        raise BackupError(f"virheellinen tunniste: {name!r}")
    return '"' + name + '"'


def redact(text: str) -> str:
    text = re.sub(r"postgres(?:ql)?://\S+", "postgresql://REDACTED", text, flags=re.I)
    text = re.sub(r"(?i)(password\s*=\s*)\S+", r"\1REDACTED", text)
    text = re.sub(r"(?i)(authorization:\s*bearer\s+)\S+", r"\1REDACTED", text)
    return text


# pg_dump ei kirjoita tyhjää public-skeemaa TOC:iin. Muut skeemat ja publicin objektit näkyvät.
_TOC_SCHEMA_RE = re.compile(
    r"(?:SCHEMA - |TABLE DATA |SEQUENCE SET |MATERIALIZED VIEW |FK CONSTRAINT |"
    r"TABLE |VIEW |SEQUENCE |FUNCTION |PROCEDURE |INDEX |CONSTRAINT |TYPE |DOMAIN |"
    r"ACL |COMMENT |POLICY |TRIGGER )([a-z_][a-z0-9_]*) "
)


def schemas_in_toc(list_text: str) -> set[str]:
    found: set[str] = set()
    for line in list_text.splitlines():
        if not line or line.startswith(";"):
            continue
        for match in _TOC_SCHEMA_RE.finditer(line + " "):
            name = match.group(1)
            if name != "-":
                found.add(name)
    return found


def toc_entry_count(list_text: str) -> int:
    return sum(1 for line in list_text.splitlines() if line and not line.startswith(";"))
