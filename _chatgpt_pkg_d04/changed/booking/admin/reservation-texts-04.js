// Varausdialogin ja maksulinkin FI/EN-varatekstit, site_texts ohittaa ne.
import { orderText } from './orders-texts.js';
import { getLang } from './talous-i18n.js';
export const RESERVATION04_TEXTS = {
  "ui.admin.res.order_no": {
    "fi": "Tilaus #{{var:no}}",
    "en": "Order #{{var:no}}"
  },
  "ui.admin.res.summary_label": {
    "fi": "Varauksen yhteenveto",
    "en": "Booking summary"
  },
  "ui.admin.res.persons_shared": {
    "fi": "{{var:n}} hlö · yleinen vuoro",
    "en": "{{var:n}} people · shared session"
  },
  "ui.admin.res.persons_private": {
    "fi": "{{var:n}} hlö · yksityisvuoro",
    "en": "{{var:n}} people · private session"
  },
  "ui.admin.res.hold_until": {
    "fi": "Pito päättyy klo {{var:time}}",
    "en": "Hold expires at {{var:time}}"
  },
  "ui.admin.res.customer": {
    "fi": "Asiakas",
    "en": "Customer"
  },
  "ui.admin.res.call": {
    "fi": "Soita asiakkaalle: {{var:phone}}",
    "en": "Call the customer: {{var:phone}}"
  },
  "ui.admin.res.email": {
    "fi": "Lähetä sähköpostia: {{var:email}}",
    "en": "Email the customer: {{var:email}}"
  },
  "ui.admin.res.customer_message": {
    "fi": "Asiakkaan viesti",
    "en": "Message from the customer"
  },
  "ui.admin.res.payment_title": {
    "fi": "Tilaus ja maksu",
    "en": "Order and payment"
  },
  "ui.admin.res.contents_title": {
    "fi": "Varauksen sisältö",
    "en": "Booking contents"
  },
  "ui.admin.res.more_details": {
    "fi": "Lisätiedot",
    "en": "More details"
  },
  "ui.admin.res.move_title": {
    "fi": "Siirrä toiseen tilaan",
    "en": "Move to another space"
  },
  "ui.admin.res.move_reason": {
    "fi": "Siirron syy (valinnainen)",
    "en": "Reason for the move (optional)"
  },
  "ui.admin.res.move_button": {
    "fi": "Siirrä tilaan {{var:space}}",
    "en": "Move to {{var:space}}"
  },
  "ui.admin.res.move_help": {
    "fi": "Siirto onnistuu, jos kohdetila on vapaa ja tuotteella on sille sääntö.",
    "en": "The move works if the target space is free and the product has a rule for it."
  },
  "ui.admin.res.other_actions": {
    "fi": "Muut toiminnot",
    "en": "Other actions"
  },
  "ui.admin.res.no_show_title": {
    "fi": "Merkitäänkö varaus tilaan Ei saapunut?",
    "en": "Mark the booking as no-show?"
  },
  "ui.admin.res.no_show_text": {
    "fi": "Asiakas ei saapunut varaukseen. Maksuja ei hyvitetä automaattisesti.",
    "en": "The customer did not arrive. Payments are not refunded automatically."
  },
  "ui.admin.res.no_show_submit": {
    "fi": "Merkitse: ei saapunut",
    "en": "Mark as no-show"
  },
  "ui.admin.orders.link_set_deadline": {
    "fi": "Aseta takaraja",
    "en": "Set a deadline"
  },
  "ui.admin.orders.link_deadline_help": {
    "fi": "Ilman takarajaa linkki on voimassa, kunnes tilaus on maksettu tai linkki korvataan uudella.",
    "en": "Without a deadline the link stays valid until the order is paid or the link is replaced."
  },
  "ui.admin.orders.link_deadline_days": {
    "fi": "Takaraja (päivää)",
    "en": "Deadline (days)"
  },
  "ui.admin.orders.link_deadline_bad": {
    "fi": "Takarajan on oltava {{var:min}}–{{var:max}} päivää.",
    "en": "The deadline must be {{var:min}}–{{var:max}} days."
  },
  "ui.admin.orders.link_no_deadline": {
    "fi": "Linkillä ei ole takarajaa.",
    "en": "The link has no deadline."
  },
  "ui.admin.orders.link_valid_until": {
    "fi": "Linkki on voimassa {{var:date}} asti.",
    "en": "The link is valid until {{var:date}}."
  }
};
export function reservationText(key, vars) {
  const live = orderText(key, vars);
  if (live !== key) return live;
  const fallback = RESERVATION04_TEXTS[key]?.[getLang()] ?? RESERVATION04_TEXTS[key]?.fi;
  if (!fallback) return key;
  return fallback.replace(/\{\{var:(\w+)\}\}/g, (_, name) => String(vars?.[name] ?? ''));
}
