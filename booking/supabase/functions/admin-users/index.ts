// Supabase Edge Function admin-users (Deno). verify_jwt = true (ks. supabase/config.toml): pyynnöllä pitää olla kelvollinen kirjautuneen käyttäjän JWT.
// Toiminnot (POST, JSON): { action: 'invite', email, name, role } | { action: 'deactivate', user_id } | { action: 'reactivate', user_id }
//
// Turvamalli:
//   1) Kutsuja tunnistetaan OMALLA JWT:llään: booking.is_admin() kutsutaan kutsujan tokenilla (anon-avain + Authorization). Vain admin pääsee eteenpäin.
//   2) Vasta sen jälkeen käytetään service_role-avainta (vain palvelimella, ympäristömuuttuja SUPABASE_SERVICE_ROLE_KEY, ei koskaan selaimelle eikä lokiin)
//      Auth Admin API:in (kutsu, esto) ja booking.svc_*-funktioihin, joissa säännöt ja audit-loki ovat (testattu pgTAP:lla).
//   3) CORS vain ALLOWED_ORIGINS-listan originille; syötteet validoidaan logic.js:ssä; roolit vain sallittulistasta (admin/manager/staff).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { validateRequest, parseAllowedOrigins, corsHeaders, resolveRedirect, mapDbError } from './logic.js';

type Req =
  | { ok: false; status: number; code: string; message: string }
  | { ok: true; action: 'invite'; email: string; name: string; role: string }
  | { ok: true; action: 'deactivate' | 'reactivate'; user_id: string };

const env = (k: string) => Deno.env.get(k) ?? '';
const BAN_FOREVER = '876000h'; // ~100 vuotta; 'none' poistaa eston

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('origin');
  const cors = origin ? corsHeaders(origin, parseAllowedOrigins(env('ALLOWED_ORIGINS'))) : {};
  const reply = (status: number, body: Record<string, unknown>) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...(cors ?? {}) } });

  if (origin && !cors) return new Response(JSON.stringify({ ok: false, code: 'origin_not_allowed', message: 'Origin ei ole sallittu' }), { status: 403, headers: { 'Content-Type': 'application/json' } });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors ?? {} });
  if (req.method !== 'POST') return reply(405, { ok: false, code: 'method_not_allowed', message: 'Vain POST' });

  const url = env('SUPABASE_URL'), anon = env('SUPABASE_ANON_KEY'), service = env('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !anon || !service) { console.error('admin-users: ympäristömuuttujia puuttuu'); return reply(500, { ok: false, code: 'misconfigured', message: 'Palvelun asetukset puuttuvat' }); }
  const auth = req.headers.get('authorization') ?? '';
  if (!/^Bearer [\w-]+\.[\w-]+\.[\w-]+$/.test(auth)) return reply(401, { ok: false, code: 'unauthorized', message: 'Kirjautuminen puuttuu' });

  // 1) kutsujan oikeus omalla tokenilla
  const caller = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false }, db: { schema: 'booking' }, global: { headers: { Authorization: auth } } });
  const { data: userData, error: userErr } = await caller.auth.getUser(auth.slice(7));
  const actor = userData?.user?.id;
  if (userErr || !actor) return reply(401, { ok: false, code: 'unauthorized', message: 'Istunto ei kelpaa' });
  const { data: isAdmin, error: adminErr } = await caller.rpc('is_admin');
  if (adminErr) { console.error('admin-users: is_admin epäonnistui', adminErr.code); return reply(500, { ok: false, code: 'internal', message: 'Palvelinvirhe' }); }
  if (isAdmin !== true) return reply(403, { ok: false, code: 'forbidden', message: 'Vain admin voi hallita käyttäjiä' });

  // 2) syötteen validointi
  let raw: unknown = null;
  try { raw = await req.json(); } catch { /* validateRequest hylkää */ }
  const v = validateRequest(raw) as Req;
  if (!v.ok) return reply(v.status, { ok: false, code: v.code, message: v.message });

  // 3) palvelurooli vasta nyt
  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false }, db: { schema: 'booking' } });
  const fail = (e: unknown) => { const m = mapDbError(e); if (m.status === 500) console.error('admin-users: tietokantavirhe', (e as { code?: string })?.code); return reply(m.status, { ok: false, code: m.code, message: m.message }); };

  try {
    if (v.action === 'invite') {
      const redirectTo = resolveRedirect({ SITE_URL: env('SITE_URL'), INVITE_REDIRECT_URL: env('INVITE_REDIRECT_URL') });
      if (!redirectTo) return reply(500, { ok: false, code: 'misconfigured', message: 'SITE_URL tai INVITE_REDIRECT_URL puuttuu tai ei ole https' });
      const found = await admin.rpc('svc_find_auth_user', { p_email: v.email });
      if (found.error) return fail(found.error);
      let userId: string | null = found.data ?? null;
      let created = false;
      if (!userId) {
        const inv = await admin.auth.admin.inviteUserByEmail(v.email, { redirectTo, data: { name: v.name } });
        if (inv.error || !inv.data?.user?.id) { console.error('admin-users: kutsu epäonnistui', inv.error?.status); return reply(502, { ok: false, code: 'invite_failed', message: 'Kutsun lähetys epäonnistui' }); }
        userId = inv.data.user.id; created = true;
      }
      if (!created) await admin.auth.admin.updateUserById(userId!, { ban_duration: 'none' }).catch(() => {}); // aiemmin käytöstä poistettu tunnus palaa käyttöön kutsulla
      const up = await admin.rpc('svc_staff_upsert', { p_actor: actor, p_user_id: userId, p_name: v.name, p_role: v.role });
      if (up.error) {
        if (created) await admin.auth.admin.deleteUser(userId!).catch(() => {}); // ei jätetä roolitonta Auth-käyttäjää
        return fail(up.error);
      }
      console.log(JSON.stringify({ fn: 'admin-users', action: 'invite', actor, target: userId, role: v.role, created }));
      return reply(200, { ok: true, user_id: userId, invited: created, existing_user: !created });
    }

    if (v.action === 'deactivate') {
      const r = await admin.rpc('svc_staff_set_active', { p_actor: actor, p_user_id: v.user_id, p_active: false }); // säännöt: ei itseä, ei viimeistä adminia
      if (r.error) return fail(r.error);
      const ban = await admin.auth.admin.updateUserById(v.user_id, { ban_duration: BAN_FOREVER });
      if (ban.error) {
        await admin.rpc('svc_staff_set_active', { p_actor: actor, p_user_id: v.user_id, p_active: true }); // peruutus: ei jäädä puolitilaan
        console.error('admin-users: eston asetus epäonnistui', ban.error.status);
        return reply(502, { ok: false, code: 'ban_failed', message: 'Käyttäjän estäminen epäonnistui, muutos peruttiin' });
      }
      console.log(JSON.stringify({ fn: 'admin-users', action: 'deactivate', actor, target: v.user_id }));
      return reply(200, { ok: true, user_id: v.user_id, active: false });
    }

    // reactivate: aktivoi ensin (säännöt/audit), poista sitten Auth-esto
    const r = await admin.rpc('svc_staff_set_active', { p_actor: actor, p_user_id: v.user_id, p_active: true });
    if (r.error) return fail(r.error);
    const unban = await admin.auth.admin.updateUserById(v.user_id, { ban_duration: 'none' });
    if (unban.error) { console.error('admin-users: eston poisto epäonnistui', unban.error.status); return reply(502, { ok: false, code: 'unban_failed', message: 'Esto jäi voimaan Authissa, yritä uudelleen' }); }
    console.log(JSON.stringify({ fn: 'admin-users', action: 'reactivate', actor, target: v.user_id }));
    return reply(200, { ok: true, user_id: v.user_id, active: true });
  } catch (e) {
    console.error('admin-users: odottamaton virhe', (e as Error)?.name);
    return reply(500, { ok: false, code: 'internal', message: 'Palvelinvirhe' });
  }
});
