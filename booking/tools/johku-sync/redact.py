"""Poista henkilötiedot ja lahjakorttikoodit teksteistä, jotka saa tulostaa."""
import re

_EMAIL = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
_CODE = re.compile(r"\b[A-Z0-9]{4}(?:-?[A-Z0-9]{4}){2}\b")
_PHONE = re.compile(r"(?:\+|00|0)\d[\d\-\s]{6,}\d")


def redact(text: str, limit: int = 500) -> str:
    s = "" if text is None else str(text)
    s = _EMAIL.sub("[email]", s)
    s = _CODE.sub("[code]", s)
    s = _PHONE.sub("[phone]", s)
    s = s.replace("\n", " ")
    return s[:limit]
