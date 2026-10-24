// booking_153 sääntö 8: henkilökunnan oma sivu. Pysyvä henkilökohtainen linkki (?token=), ei kirjautumista.
// Näyttää vain token-haltijan omat avoimet ja vastatut vuorot; vastauksen voi muuttaa (kieltäytyminen → hyväksyntä).
// Kaikki teksti kirjoitetaan textContentillä. Tekstit FI + EN (?lang=en). Avaimet ui.vuoro_oma.* (pending-import-53).

export const API = "https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/shift-offer-engine";

export const TEXTS = {
  fi: {
    title: "Omat vuorot",
    intro: "Hei {{var:name}}. Tässä ovat sinulle tarjotut vuorot.",
    open_title: "Avoimet tarjoukset",
    done_title: "Vastatut",
    none_open: "Ei avoimia tarjouksia.",
    none_done: "Ei vastattuja vuoroja.",
    deadline: "Vastaa viimeistään {{var:deadline}}",
    accept: "Hyväksy",
    decline: "Kieltäydy",
    change_accept: "Otankin vuoron",
    status_accepted: "Hyväksyit vuoron",
    status_declined: "Kieltäydyit",
    status_closed: "Tarjous on päättynyt",
    status_filled_other: "Vuoro on jo mennyt",
    status_expired: "Vastausaika päättyi",
    result_accepted: "Vuoro on nyt sinun. Kiitos.",
    result_declined: "Vastaus kirjattu. Kiitos.",
    result_already_taken: "Vuoro on jo mennyt toiselle.",
    result_already_yours: "Vuoro on jo sinun.",
    result_error: "Vastausta ei voitu kirjata. Yritä hetken päästä uudelleen.",
    bad_token: "Linkki ei kelpaa. Pyydä uusi linkki vuorovastaavalta.",
    load_error: "Sivua ei saatu ladattua. Yritä hetken päästä uudelleen.",
    help: "Hyväksytyn vuoron perumisesta sovi suoraan vuorovastaavan kanssa, puh. 010 299 2866.",
    lang_other: "English",
    role_heater: "Lämmitysvuoro",
    role_therapist: "Hoitajavuoro",
    role_reception: "Vastaanottovuoro",
    role_other: "Vuoro",
  },
  en: {
    title: "My shifts",
    intro: "Hi {{var:name}}. Here are the shifts offered to you.",
    open_title: "Open offers",
    done_title: "Answered",
    none_open: "No open offers.",
    none_done: "No answered shifts.",
    deadline: "Please answer by {{var:deadline}}",
    accept: "Accept",
    decline: "Decline",
    change_accept: "I'll take it after all",
    status_accepted: "You accepted the shift",
    status_declined: "You declined",
    status_closed: "The offer has ended",
    status_filled_other: "The shift has already been taken",
    status_expired: "The answer time has passed",
    result_accepted: "The shift is now yours. Thank you.",
    result_declined: "Answer recorded. Thank you.",
    result_already_taken: "The shift has already been taken by someone else.",
    result_already_yours: "The shift is already yours.",
    result_error: "The answer could not be recorded. Please try again shortly.",
    bad_token: "The link is not valid. Please ask the shift coordinator for a new link.",
    load_error: "The page could not be loaded. Please try again shortly.",
    help: "To cancel a shift you have accepted, please contact the shift coordinator, tel. 010 299 2866.",
    lang_other: "Suomeksi",
    role_heater: "Heating shift",
    role_therapist: "Therapist shift",
    role_reception: "Reception shift",
    role_other: "Shift",
  },
};

export function langFrom(search) {
  return new URLSearchParams(search || "").get("lang") === "en" ? "en" : "fi";
}

export function tr(lang, key, vars) {
  const raw = (TEXTS[lang] && TEXTS[lang][key]) ?? TEXTS.fi[key] ?? "";
  return raw.replace(/\{\{var:([a-z_]+)\}\}/g, (_, k) => (vars && vars[k] != null ? String(vars[k]) : ""));
}

function wall(iso, lang, withWeekday) {
  const d = new Date(iso);
  if (!iso || Number.isNaN(d.getTime())) return "";
  const opts = { timeZone: "Europe/Helsinki", day: "numeric", month: "numeric", year: "numeric", hour: "2-digit", minute: "2-digit", hourCycle: "h23" };
  if (withWeekday) opts.weekday = "short";
  return new Intl.DateTimeFormat(lang === "en" ? "en-GB" : "fi-FI", opts).format(d);
}

export function whenText(item, lang) {
  const start = wall(item.starts_at, lang, true);
  const end = item.ends_at ? new Intl.DateTimeFormat(lang === "en" ? "en-GB" : "fi-FI", { timeZone: "Europe/Helsinki", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date(item.ends_at)) : "";
  return end ? `${start}–${end}` : start;
}

function el(doc, tag, className, text) {
  const node = doc.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function roleTitle(lang, role) {
  return tr(lang, role === "heater" || role === "therapist" || role === "reception" ? `role_${role}` : "role_other");
}

function button(doc, className, label, offerId, response, onRespond) {
  const b = el(doc, "button", className, label);
  b.type = "button";
  b.dataset.response = response;
  b.dataset.offerId = offerId;
  b.addEventListener("click", (ev) => { ev.preventDefault(); if (onRespond) onRespond(offerId, response); });
  return b;
}

function card(doc, lang, item, open, onRespond) {
  const a = el(doc, "article", "card offer");
  a.append(el(doc, "h2", null, roleTitle(lang, item.role_type)));
  a.append(el(doc, "p", "when", whenText(item, lang)));
  if (open && item.deadline_at) a.append(el(doc, "p", "deadline", tr(lang, "deadline", { deadline: wall(item.deadline_at, lang, false) })));
  if (!open) a.append(el(doc, "p", "status " + String(item.my_status || ""), tr(lang, "status_" + String(item.my_status || "closed"))));
  const form = el(doc, "form");
  form.addEventListener("submit", (ev) => ev.preventDefault());
  if (open) {
    form.append(button(doc, "btn primary", tr(lang, "accept"), item.offer_id, "accept", onRespond));
    if (item.can_decline) form.append(button(doc, "btn", tr(lang, "decline"), item.offer_id, "decline", onRespond));
  } else if (item.can_accept) {
    form.append(button(doc, "btn primary", tr(lang, "change_accept"), item.offer_id, "accept", onRespond));
  }
  if (form.children && form.children.length) a.append(form);
  return a;
}

export function render(doc, lang, page, result) {
  const set = (id, text) => { const n = doc.getElementById(id); if (n) n.textContent = text; return n; };
  set("title", tr(lang, "title"));
  if ("title" in doc) doc.title = tr(lang, "title");
  set("open-title", tr(lang, "open_title"));
  set("done-title", tr(lang, "done_title"));
  set("help", tr(lang, "help"));
  const banner = doc.getElementById("banner");
  const open = doc.getElementById("open");
  const done = doc.getElementById("done");
  if (open) open.textContent = "";
  if (done) done.textContent = "";
  if (!page || page.ok !== true) {
    set("intro", tr(lang, page && page.error === "load_error" ? "load_error" : "bad_token"));
    if (banner) banner.className = "banner bad";
    return;
  }
  const msg = result ? tr(lang, "result_" + (["accepted", "declined", "already_taken", "already_yours"].includes(result) ? result : "error")) : "";
  set("intro", msg || tr(lang, "intro", { name: page.name || "" }));
  if (banner) banner.className = "banner" + (result ? (result === "accepted" || result === "declined" || result === "already_yours" ? " ok" : " bad") : "");
  const onRespond = render.onRespond;
  const openList = Array.isArray(page.open) ? page.open : [];
  const doneList = Array.isArray(page.answered) ? page.answered : [];
  if (open) {
    for (const item of openList) open.append(card(doc, lang, item, true, onRespond));
    if (!openList.length) open.append(el(doc, "p", "muted", tr(lang, "none_open")));
  }
  if (done) {
    for (const item of doneList) done.append(card(doc, lang, item, false, onRespond));
    if (!doneList.length) done.append(el(doc, "p", "muted", tr(lang, "none_done")));
  }
}

function boot() {
  const params = new URLSearchParams(location.search);
  const token = params.get("token") || "";
  const lang = langFrom(location.search);
  document.documentElement.lang = lang;
  const other = document.getElementById("lang");
  if (other) {
    const next = new URLSearchParams(location.search);
    if (lang === "en") next.delete("lang"); else next.set("lang", "en");
    other.textContent = tr(lang, "lang_other");
    other.setAttribute("href", "?" + next.toString());
    other.setAttribute("hreflang", lang === "en" ? "fi" : "en");
  }
  render.onRespond = async (offerId, response) => {
    try {
      const res = await fetch(API + "/api/my/respond", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ token, offer_id: offerId, response }),
      });
      const body = await res.json();
      render(document, lang, body && body.page ? body.page : { ok: false, error: "bad_token" }, body && body.result ? body.result : "error");
    } catch {
      render(document, lang, { ok: false, error: "load_error" }, null);
    }
  };
  if (!token) { render(document, lang, { ok: false, error: "bad_token" }, null); return; }
  fetch(API + "/api/my?token=" + encodeURIComponent(token))
    .then((r) => r.json())
    .then((page) => render(document, lang, page, null))
    .catch(() => render(document, lang, { ok: false, error: "load_error" }, null));
}

if (typeof document !== "undefined" && typeof document.getElementById === "function" && document.getElementById("app")) {
  boot();
}
