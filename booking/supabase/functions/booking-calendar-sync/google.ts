// Google Calendar -kirjoitus (events.insert / patch / delete). Sama palvelutilin kutsumalli kuin booking-closure-sync.
// Testit antavat feikin fetchille. Tokenia, kalenteri-id:tä tai tapahtuman runkoa ei logiteta täältä.
import { type GReadEvent, type GWriteEvent, type Google, HttpError } from "./core.ts";

const CAL_API = "https://www.googleapis.com/calendar/v3";

export interface TokenSource {
  token(): Promise<string>;
  invalidate?: () => void;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function eventUrl(calendarId: string, eventId?: string): URL {
  return new URL(`${CAL_API}/calendars/${encodeURIComponent(calendarId)}/events${eventId ? `/${encodeURIComponent(eventId)}` : ""}`);
}

async function gwrite(fetchImpl: typeof fetch, tokens: TokenSource, method: "POST" | "PATCH" | "DELETE", url: URL, body?: unknown, etag?: string): Promise<number> {
  for (let attempt = 0; ; attempt++) {
    const res = await fetchImpl(url, {
      method,
      headers: { authorization: `Bearer ${await tokens.token()}`, ...(body ? { "content-type": "application/json" } : {}), ...(etag ? { "if-match": etag } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (res.ok) {
      await res.body?.cancel();
      return res.status;
    }
    let reason = "";
    try {
      reason = (await res.json())?.error?.errors?.[0]?.reason ?? "";
    } catch { /* rungon muoto ei ole osa virhettä */ }
    if (res.status === 401 && attempt === 0) {
      tokens.invalidate?.();
      continue;
    }
    if (res.status === 409 || res.status === 404 || res.status === 410) return res.status;
    const retryable = res.status === 429 || res.status >= 500 || (res.status === 403 && (reason === "rateLimitExceeded" || reason === "userRateLimitExceeded"));
    if (retryable && attempt < 4) {
      await sleep(Math.min(16000, 500 * 2 ** attempt) + Math.floor(Math.random() * 250));
      continue;
    }
    throw new HttpError(res.status, reason);
  }
}

export function createGoogle(fetchImpl: typeof fetch, tokens: TokenSource): Google {
  return {
    async getEvent(calendarId, eventId): Promise<GReadEvent> {
      // A missing event is a deletion ONLY if events.list confirms calendar access.
      // 404 alone can also mean lost sharing/wrong calendar; never free a room on that evidence.
      let missing = false;
      for (let attempt = 0; attempt < 5; attempt++) {
        const url = eventUrl(calendarId, missing ? undefined : eventId);
        if (missing) { url.searchParams.set("maxResults", "1"); url.searchParams.set("showDeleted", "true"); }
        const res = await fetchImpl(url, { headers: { authorization: `Bearer ${await tokens.token()}` } });
        if (res.ok) {
          if (missing) { await res.body?.cancel(); return { id: eventId, status: "cancelled" }; }
          return await res.json() as GReadEvent;
        }
        let reason = "";
        try { reason = (await res.json())?.error?.errors?.[0]?.reason ?? ""; } catch { /* no payload logging */ }
        if (!missing && (res.status === 404 || res.status === 410)) { missing = true; continue; }
        if (res.status === 401 && attempt === 0) { tokens.invalidate?.(); continue; }
        if ((res.status === 429 || res.status >= 500 || (res.status === 403 && ["rateLimitExceeded", "userRateLimitExceeded"].includes(reason))) && attempt < 4) {
          await sleep(Math.min(16000, 500 * 2 ** attempt)); continue;
        }
        throw new HttpError(res.status, reason);
      }
      throw new Error("google_training_read_retries_exhausted");
    },
    async insertEvent(calendarId, ev: GWriteEvent) {
      const status = await gwrite(fetchImpl, tokens, "POST", eventUrl(calendarId), ev);
      if (status === 404 || status === 410) throw new HttpError(status, "");
      return status === 409 ? "exists" : "created";
    },
    async patchEvent(calendarId, eventId, ev, etag) {
      const status = await gwrite(fetchImpl, tokens, "PATCH", eventUrl(calendarId, eventId), ev, etag);
      return status === 404 || status === 410 ? "missing" : "patched";
    },
    async deleteEvent(calendarId, eventId) {
      const status = await gwrite(fetchImpl, tokens, "DELETE", eventUrl(calendarId, eventId));
      return status === 404 || status === 410 ? "gone" : "deleted";
    },
  };
}
