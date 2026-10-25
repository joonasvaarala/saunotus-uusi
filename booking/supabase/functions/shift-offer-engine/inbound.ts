// Saapuvan WhatsApp-viestin käsittely. Ei lue Deno.env:iä eikä soita verkkoon:
// kutsuja antaa tietokannan ja lähetyksen. Oikeudet ja vastausteksti tulevat tietokannasta.
// Tuntemattomalle numerolle ei lähetetä mitään.

import type { ParsedInbound, ReplyButton } from "./whatsapp.ts";

export type Intent =
  | { op: "help" }
  | { op: "own_shifts" }
  | { op: "all_shifts" }
  | { op: "person_shifts"; name: string }
  | { op: "accept"; offer_id?: string; index?: number }
  | { op: "decline"; offer_id?: string; index?: number }
  | { op: "prepare_cancel"; index: number }
  | { op: "prepare_assign"; index: number; name: string }
  | { op: "prepare_unassign"; index: number; name: string }
  | { op: "prepare_time"; index: number; date: string; start: string; end: string }
  | { op: "confirm"; action_id?: string }
  | { op: "abort"; action_id?: string }
  | { op: "unknown" };

export type StoreResult = {
  id: string;
  duplicate: boolean;
  handled: boolean;
  inboundEnabled: boolean;
  staffId: string | null;
  replyTo: string | null;
};

export type ActResult = {
  replyBody: string | null;
  buttons: ReplyButton[];
  shiftId: string | null;
  suppressed: boolean;
};

export type OutboundRecord = {
  staffId: string | null;
  phone: string;
  text: string;
  wamid: string | null;
  shiftId: string | null;
};

export type InboundDeps = {
  store: (message: ParsedInbound) => Promise<StoreResult | null>;
  act: (messageId: string, intent: Intent) => Promise<ActResult>;
  send: (to: string, body: string, buttons: ReplyButton[]) => Promise<{ ok: boolean; wamid: string | null }>;
  markHandled: (messageId: string, intentOp: string) => Promise<void>;
  storeOutbound: (record: OutboundRecord) => Promise<void>;
  log: (event: string, data: Record<string, unknown>) => void;
  // booking_153: tervetuloviesti henkilökunnan ensimmäiseen viestiin (booking.shift_staff_welcome).
  // Tietokanta päättää: asetus, vain kerran, vain 24 h ikkunassa, ei tuntemattomalle eikä bottikanavalle.
  welcome?: (messageId: string) => Promise<WelcomeResult>;
  // soefix B9: tervetuloviesti kirjataan lähetetyksi vasta wamidilla; epäonnistunut lähetys vapauttaa varauksen.
  welcomeSent?: (staffId: string, wamid: string) => Promise<void>;
  welcomeRelease?: (staffId: string) => Promise<void>;
};

export type WelcomeResult = { send: boolean; body: string | null; staffId?: string | null };

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";

function fold(input: string): string {
  return input.trim().toLocaleLowerCase("fi").replace(/\s+/g, " ").replace(/[.!?]+$/g, "");
}

function indexOf(raw: string): number | null {
  if (!/^\d{1,2}$/.test(raw)) return null;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > 30) return null;
  return n;
}

function clock(raw: string): string | null {
  const m = raw.match(/^(\d{1,2})[:.](\d{2})$/);
  if (!m) return null;
  const hour = Number(m[1]);
  const minute = Number(m[2]);
  if (hour > 23 || minute > 59) return null;
  return `${String(hour).padStart(2, "0")}:${m[2]}`;
}

function named(text: string): string | null {
  const name = text.trim().replace(/\s+/g, " ");
  if (name.length < 2 || name.length > 80 || /^\d+$/.test(name)) return null;
  return name;
}

// Painike ohittaa tekstin. Numeroidut muokkauskomennot tunnistetaan ennen yleisiä sanoja.
export function parseIntent(text: string | null, buttonId: string | null): Intent {
  const button = (buttonId ?? "").trim();
  const btn = button.match(new RegExp(`^([adyn]):(${UUID})$`, "i"));
  if (btn) {
    const id = btn[2].toLowerCase();
    const kind = btn[1].toLowerCase();
    if (kind === "a") return { op: "accept", offer_id: id };
    if (kind === "d") return { op: "decline", offer_id: id };
    if (kind === "y") return { op: "confirm", action_id: id };
    return { op: "abort", action_id: id };
  }
  const raw = fold(text ?? "");
  if (!raw) return { op: "unknown" };

  const time = raw.match(/^(?:aika|siirrä|siirra)\s+(\d+)\s+(\d{1,2}\.\d{1,2}\.\d{4})\s+(\d{1,2}[:.]\d{2})\s*[-–]\s*(\d{1,2}[:.]\d{2})$/u);
  if (time) {
    const index = indexOf(time[1]);
    const start = clock(time[3]);
    const end = clock(time[4]);
    if (index && start && end) return { op: "prepare_time", index, date: time[2], start, end };
  }
  const assign = raw.match(/^(?:anna|laita)\s+(\d+)\s+(.+)$/u);
  if (assign) {
    const index = indexOf(assign[1]);
    const name = named(assign[2]);
    if (index && name) return { op: "prepare_assign", index, name };
  }
  const unassign = raw.match(/^(?:pois|poista)\s+(\d+)\s+(.+)$/u);
  if (unassign) {
    const index = indexOf(unassign[1]);
    const name = named(unassign[2]);
    if (index && name) return { op: "prepare_unassign", index, name };
  }
  const cancel = raw.match(/^(?:peru|peruuta)(?:\s+vuoro)?\s+(\d+)$/u);
  if (cancel) {
    const index = indexOf(cancel[1]);
    if (index) return { op: "prepare_cancel", index };
  }
  if (raw === "kaikki vuorot" || raw === "vuorot kaikki" || raw === "kaikkien vuorot") return { op: "all_shifts" };
  const person = raw.match(/^(?:vuorot|näytä vuorot|nayta vuorot)\s+(.+)$/u);
  if (person && person[1] !== "kaikki") {
    const name = named(person[1]);
    if (name) return { op: "person_shifts", name };
  }
  if (/^(?:vuorot|omat vuorot|omat|tulevat|tulevat vuorot|vuoroni|omat työvuorot|omat tyovuorot)$/u.test(raw)) {
    return { op: "own_shifts" };
  }
  const accept = raw.match(/^(?:hyväksy|hyvaksy|otan|otan vuoron)(?:\s+(\d+))?$/u);
  if (accept) {
    const index = accept[1] ? indexOf(accept[1]) : undefined;
    if (accept[1] && !index) return { op: "unknown" };
    return index ? { op: "accept", index } : { op: "accept" };
  }
  const decline = raw.match(/^(?:en ota|hylkää|hylkaa)(?:\s+(\d+))?$/u);
  if (decline) {
    const index = decline[1] ? indexOf(decline[1]) : undefined;
    if (decline[1] && !index) return { op: "unknown" };
    return index ? { op: "decline", index } : { op: "decline" };
  }
  if (/^(?:vahvista|kyllä|kylla)$/u.test(raw)) return { op: "confirm" };
  if (/^(?:peruuta|ei)$/u.test(raw)) return { op: "abort" };
  if (/^(?:apua|ohje|help|komennot|\?)$/u.test(raw)) return { op: "help" };
  return { op: "unknown" };
}

// Tallennus tapahtuu aina. Vastaus vain, kun itsepalvelu on päällä ja numero on yksi aktiivinen työntekijä.
// Tuntematon numero: ei act-kutsua, ei lähetystä, ei outbound-riviä. Rivi jää handled_at-tyhjäksi Tapiolle.
export async function processInboundMessage(message: ParsedInbound, deps: InboundDeps): Promise<void> {
  const stored = await deps.store(message);
  if (!stored?.id) throw new Error("inbound_store_failed");
  deps.log("whatsapp_inbound_stored", {
    duplicate: stored.duplicate,
    handled: stored.handled,
    matched: stored.staffId != null,
    inbound_enabled: stored.inboundEnabled,
    type: message.type,
  });
  if (stored.duplicate && stored.handled) return;
  // soefix B9: myös Metan uudelleentoimitus (duplicate) saa yrittää – tietokanta päättää (already_sent / claimed / not_first).
  if (stored.staffId && deps.welcome) {
    const welcome = await deps.welcome(stored.id).catch(() => ({ send: false, body: null } as WelcomeResult));
    const text = welcome.send ? welcome.body?.trim() ?? "" : "";
    const welcomeStaff = welcome.staffId ?? stored.staffId;
    const release = () => deps.welcomeRelease ? deps.welcomeRelease(welcomeStaff).catch(() => undefined) : Promise.resolve();
    if (text && stored.replyTo) {
      let sent: { ok: boolean; wamid: string | null };
      try {
        sent = await deps.send(stored.replyTo, text, []);
      } catch (e) {
        await release();
        throw e;
      }
      const ok = sent.ok && !!sent.wamid;
      if (ok) {
        if (deps.welcomeSent) await deps.welcomeSent(welcomeStaff, sent.wamid!);
        await deps.storeOutbound({ staffId: stored.staffId, phone: stored.replyTo, text, wamid: sent.wamid, shiftId: null });
      } else {
        await release();
      }
      deps.log("whatsapp_welcome", { sent: ok });
    } else if (welcome.send) {
      await release();
    }
  }
  if (!stored.inboundEnabled || !stored.staffId) return;

  const intent = parseIntent(message.text, message.buttonId);
  const act = await deps.act(stored.id, intent);
  const body = act.replyBody?.trim() ?? "";
  if (!body || act.suppressed || !stored.replyTo) {
    if (!stored.replyTo && body) deps.log("whatsapp_inbound_no_destination", { matched: true });
    return;
  }
  const sent = await deps.send(stored.replyTo, body, act.buttons);
  if (!sent.ok) return;
  await deps.markHandled(stored.id, intent.op);
  await deps.storeOutbound({
    staffId: stored.staffId,
    phone: stored.replyTo,
    text: body,
    wamid: sent.wamid,
    shiftId: act.shiftId,
  });
}
