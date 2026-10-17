#!/usr/bin/env python3
"""Generoi ../fonts.ts ja ../photos.ts (lahjakortti-PDF:n upotetut kirjasimet ja kuva).

Ajo: python3 build_assets.py   (vaatii fonttools; kirjasinlähteet: FONT_DIR, oletus Google Fonts -kansio)
Kirjasimet ovat SIL OFL 1.1 -lisensoituja (Cormorant Garamond, Lato, IBM Plex Mono). Osajoukko: latin-1 + WinAnsi-lisämerkit,
vain kern/lnum-ominaisuudet (tasakorkeat numerot; ei ligatuureja). Kuva: ovi-kaari.jpg (sivuston oven veistos, rajattu kaareen sopivaksi).
"""
import base64, os
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools import subset
import io

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_DIR = os.environ.get("FONT_DIR", "/usr/share/fonts/truetype/sand-box/google/")
UNI = (list(range(0x20, 0x7F)) + list(range(0xA0, 0x100)) +
       [0x20AC, 0x2013, 0x2014, 0x2018, 0x2019, 0x201A, 0x201C, 0x201D, 0x201E, 0x2022, 0x2026, 0x2020, 0x2021, 0x2030, 0x2039, 0x203A, 0x2122,
        0x0152, 0x0153, 0x0160, 0x0161, 0x0178, 0x017D, 0x017E, 0x0192, 0x02C6, 0x02DC])
FONTS = {  # avain: (tiedosto, muuttuvan fontin akseli)
    "cormorant-500": ("Cormorant Garamond/CormorantGaramond-VariableFont_wght.ttf", {"wght": 500}),
    "cormorant-600": ("Cormorant Garamond/CormorantGaramond-VariableFont_wght.ttf", {"wght": 600}),
    "cormorant-italic-500": ("Cormorant Garamond/CormorantGaramond-Italic-VariableFont_wght.ttf", {"wght": 500}),
    "lato-regular": ("Lato/Lato-Regular.ttf", None),
    "lato-bold": ("Lato/Lato-Bold.ttf", None),
    "plexmono-semibold": ("IBM Plex Mono/IBMPlexMono-SemiBold.ttf", None),
}

def make(path, loc):
    f = TTFont(os.path.join(FONT_DIR, path))
    if loc: f = instancer.instantiateVariableFont(f, loc, updateFontNames=True)
    o = subset.Options(); o.layout_features = ["kern", "lnum"]; o.glyph_names = False; o.hinting = False; o.name_IDs = [1, 2, 3, 4, 6]
    o.notdef_outline = True; o.drop_tables += ["DSIG"]
    s = subset.Subsetter(o); s.populate(unicodes=UNI); s.subset(f)
    b = io.BytesIO(); f.save(b); return b.getvalue()

out = "// Generoitu tiedosto (assets/build_assets.py) - EI käsin muokattavaksi. Cormorant Garamond, Lato ja IBM Plex Mono (SIL OFL 1.1), latin-1 + WinAnsi-lisämerkit, kern + lnum.\nexport const FONT_B64: Record<string, string> = {\n"
for k, (p, loc) in FONTS.items():
    b = make(p, loc); print(k, len(b)); out += f'  "{k}": "{base64.b64encode(b).decode()}",\n'
open(os.path.join(HERE, "..", "fonts.ts"), "w").write(out + "};\n")
jpg = open(os.path.join(HERE, "ovi-kaari.jpg"), "rb").read(); print("photo", len(jpg))
open(os.path.join(HERE, "..", "photos.ts"), "w").write(
    "// Generoitu tiedosto (assets/build_assets.py). Sivuston oven veistoskuva (JPG, base64), upotetaan PDF:ään kerran.\nexport const PHOTO_B64: Record<string, string> = {\n"
    f'  "photo_arch": "{base64.b64encode(jpg).decode()}",\n' + "};\n")
