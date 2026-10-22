// Vuorotarjouksen vastaussivu. Tekstit tulevat JSON-rajapinnasta ja kirjoitetaan textContentillä.
// Poletti on sivun osoitteessa. Henkilö päätellään palvelimella poletista.

export const API = "https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/shift-offer-engine";

const DONE = new Set(["accepted", "already_taken", "already_filled", "already_yours", "declined", "snoozed"]);
const QUIET = new Set(["bad_token", "not_owner", "not_recipient", "load_error"]);

export function el(doc, tag, className, text) {
  const node = doc.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function tone(result) {
  if (!result) return "";
  if (result === "accepted" || result === "already_yours" || result === "snoozed" || result === "declined") return " ok";
  return " bad";
}

function button(doc, className, response, label, form, onRespond) {
  const node = el(doc, "button", className, label);
  node.type = "button";
  node.dataset.response = response;
  node.addEventListener("click", (ev) => {
    ev.preventDefault();
    const input = form.querySelector("input");
    const until = input ? input.value || "" : "";
    if (onRespond) onRespond(form.dataset.offerId || "", response, until);
  });
  return node;
}

function card(doc, offer, focus, snoozeOpen, buttons, onRespond) {
  const article = el(doc, "article", "card offer" + (focus ? " focus" : ""));
  if (focus) article.append(el(doc, "p", "kicker", "Tämä tarjous"));
  article.append(el(doc, "h2", null, offer.role_title ?? ""));
  article.append(el(doc, "p", "when", offer.when ?? ""));
  article.append(el(doc, "p", "deadline", "Vastaa viimeistään " + (offer.deadline ?? "")));
  if (!buttons) return article;
  const form = el(doc, "form");
  form.dataset.offerId = offer.offer_id ?? "";
  form.addEventListener("submit", (ev) => ev.preventDefault());
  form.append(button(doc, "btn primary", "accept", "Hyväksy", form, onRespond));
  form.append(button(doc, "btn", "decline", "Kieltäydy", form, onRespond));
  if (offer.snooze_allowed) {
    const details = el(doc, "details", "snooze");
    details.open = snoozeOpen;
    details.append(el(doc, "summary", "btn", "Palaan asiaan"));
    const label = el(doc, "label", "fld", "Päivä");
    const input = el(doc, "input");
    input.type = "date";
    input.required = true;
    label.append(input);
    details.append(label);
    details.append(button(doc, "btn", "snooze", "Vahvista päivä", form, onRespond));
    form.append(details);
  }
  article.append(form);
  return article;
}

export function render(doc, payload, onRespond) {
  const banner = doc.getElementById("banner");
  const title = doc.getElementById("title");
  const stack = doc.getElementById("stack");
  const result = payload && payload.result ? payload.result : null;
  const titleText = payload && payload.title ? payload.title : "Vahvista vastauksesi";
  if (title) title.textContent = titleText;
  if ("title" in doc) doc.title = titleText;
  if (banner) banner.className = "banner" + tone(result);
  if (stack) stack.textContent = "";
  if (!stack || result === "load_error") return;
  const acted = payload && payload.acted ? payload.acted : null;
  const hideId = result && DONE.has(result) && acted ? acted.offer_id : null;
  const focus = payload && payload.focus_offer_id ? payload.focus_offer_id : null;
  const offers = (payload && Array.isArray(payload.offers) ? payload.offers : [])
    .filter((offer) => offer && offer.offer_id !== hideId);
  offers.sort((a, b) => (a.offer_id === focus ? 0 : 1) - (b.offer_id === focus ? 0 : 1));
  const buttons = result !== "bad_token" && result !== "load_error";
  if (acted && result) stack.append(card(doc, acted, false, false, false, onRespond));
  for (const offer of offers) {
    stack.append(card(
      doc,
      offer,
      offer.offer_id === focus,
      payload.snooze_open_offer_id === offer.offer_id,
      buttons,
      onRespond,
    ));
  }
  if (!acted && offers.length === 0 && !QUIET.has(result)) {
    const empty = el(doc, "article", "card");
    empty.append(el(doc, "p", null, "Ei avoimia tarjouksia."));
    stack.append(empty);
  }
}

async function readJson(res) {
  return await res.json();
}

function boot() {
  const token = new URLSearchParams(location.search).get("token") || "";
  const draw = (payload) => render(document, payload, onRespond);
  async function onRespond(offerId, response, until) {
    try {
      const res = await fetch(API + "/api/respond", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ token, offer_id: offerId, response, until }),
      });
      draw(await readJson(res));
    } catch {
      draw({ ok: false, result: "load_error", title: "Vastausta ei voitu kirjata", offers: [] });
    }
  }
  if (!token) {
    draw({ ok: false, result: "bad_token", title: "Linkki ei kelpaa", offers: [] });
    return;
  }
  fetch(API + "/api/offers?token=" + encodeURIComponent(token))
    .then(readJson)
    .then(draw)
    .catch(() => draw({ ok: false, result: "load_error", title: "Sivua ei saatu ladattua", offers: [] }));
}

if (typeof document !== "undefined" && typeof document.getElementById === "function" && document.getElementById("app")) {
  boot();
}
