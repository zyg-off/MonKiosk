// MonKiosk : paiement avec Polar.
// À créer dans Supabase > Edge Functions sous le nom « polar », avec « Verify JWT » désactivé.
// Elle fait deux choses :
//  1. reçoit les messages de Polar (paiement, résiliation…) et active ou bloque la formule du commerce ;
//  2. déclare chaque jour à Polar le nombre de salariés du commerce, pour le prix « par salarié ».
// Secrets à ajouter dans Edge Functions > Secrets :
//  POLAR_WEBHOOK_SECRET : le secret du webhook Polar (commence par whsec_)
//  POLAR_ACCESS_TOKEN   : un jeton d'organisation Polar avec le droit « events:write » (commence par polar_oat_)
//  POLAR_SANDBOX        : mettre 1 pendant les essais en mode bac à sable, à supprimer ensuite
import { createClient } from 'npm:@supabase/supabase-js@2.57.4';

const PLANS = ['essentiel', 'pro', 'premium'];
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const b64 = (bytes) => btoa(String.fromCharCode(...bytes));
function b64decode(s) { try { return Uint8Array.from(atob(s), (c) => c.charCodeAt(0)); } catch (_) { return null; } }
async function hmac(keyBytes, text) {
  const key = await crypto.subtle.importKey('raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64(new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(text))));
}
const same = (a, b) => a.length === b.length && [...a].reduce((acc, c, i) => acc | (c.charCodeAt(0) ^ b.charCodeAt(i)), 0) === 0;

// Vérifie que la requête vient bien de Polar (norme « Standard Webhooks »)
export async function verifySignature(raw, headers, secret, nowSec = Math.floor(Date.now() / 1000)) {
  const id = headers.get('webhook-id'), ts = headers.get('webhook-timestamp'), sig = headers.get('webhook-signature');
  if (!id || !ts || !sig || !secret || Math.abs(nowSec - Number(ts)) > 300) return false;
  const content = `${id}.${ts}.${raw}`;
  // Deux formats de secret existent chez Polar : on accepte les deux
  const keys = [b64decode(secret.replace(/^whsec_/, '')), new TextEncoder().encode(secret)].filter(Boolean);
  const expected = await Promise.all(keys.map((k) => hmac(k, content)));
  const given = sig.split(' ').map((p) => p.split(',')).filter((p) => p[0] === 'v1').map((p) => p[1]);
  return given.some((g) => expected.some((e) => same(g, e)));
}

export function supabaseDb() {
  const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
  return {
    async applyPlan(cid, plan, until, status) {
      const { error } = await db.rpc('apply_plan', { cid, p_plan: plan, p_until: until, p_status: status });
      if (error) throw new Error(error.message);
    },
    async setBilling(cid, customer, subscription) {
      const { error } = await db.from('companies').update({ stripe_customer: customer, stripe_subscription: subscription }).eq('id', cid);
      if (error) throw new Error(error.message);
    },
    async bySubscription(sub) {
      const { data } = await db.from('companies').select('id,plan').eq('stripe_subscription', sub).maybeSingle();
      return data;
    },
    async userFromToken(token) { const { data } = await db.auth.getUser(token); return data && data.user; },
    async isMember(cid, uid) {
      const { data } = await db.from('members').select('user_id').eq('company_id', cid).eq('user_id', uid).maybeSingle();
      return !!data;
    },
    async billing(cid) {
      const [{ data: c }, { data: d }] = await Promise.all([
        db.from('companies').select('stripe_customer,plan').eq('id', cid).maybeSingle(),
        db.from('company_data').select('data').eq('company_id', cid).maybeSingle(),
      ]);
      const emps = d && d.data && Array.isArray(d.data.employees) ? d.data.employees.length : 0;
      return c ? { customer: c.stripe_customer, plan: c.plan, employees: emps } : null;
    },
  };
}

export const polarApi = {
  async ingest(event) {
    const base = Deno.env.get('POLAR_SANDBOX') ? 'https://sandbox-api.polar.sh' : 'https://api.polar.sh';
    const r = await fetch(`${base}/v1/events/ingest`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${Deno.env.get('POLAR_ACCESS_TOKEN')}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ events: [event] }),
    });
    if (!r.ok) throw new Error('Polar ' + r.status + ' ' + (await r.text()).slice(0, 200));
  },
};

const day = (iso) => (iso ? String(iso).slice(0, 10) : null);
const ENDED = ['canceled', 'unpaid', 'incomplete_expired'];

// Messages envoyés par Polar
export async function webhook(raw, headers, db, secret) {
  if (!(await verifySignature(raw, headers, secret))) return json({ error: 'Signature invalide' }, 403);
  const event = JSON.parse(raw), type = String(event.type || ''), o = event.data || {};
  const isSub = type.startsWith('subscription.');
  const subId = isSub ? o.id : o.subscription_id;

  // Paiement : la référence « commerce__formule » vient du lien de paiement MonKiosk
  const [cid, plan] = String((o.metadata && o.metadata.reference_id) || '').split('__');
  const known = /^[0-9a-f-]{36}$/.test(cid || '') && PLANS.includes(plan);
  if (known && (type === 'order.paid' || type === 'order.created' || type === 'subscription.created' || type === 'subscription.active')) {
    if (!isSub || o.status === 'active' || o.status === 'trialing') {
      await db.applyPlan(cid, plan, null, 'actif');
      await db.setBilling(cid, o.customer_id || null, subId || null);
      return json({ ok: true, cid, plan });
    }
  }

  // Vie de l'abonnement : résiliation, impayé, réactivation
  if (isSub && subId) {
    const co = await db.bySubscription(subId);
    if (!co) return json({ ignored: 'abonnement inconnu' });
    if (type === 'subscription.revoked' || ENDED.includes(o.status)) {
      await db.applyPlan(co.id, 'aucune', null, 'résilié');
      return json({ ok: true, blocked: co.id });
    }
    const until = o.cancel_at_period_end ? day(o.current_period_end || o.ends_at) : null;
    await db.applyPlan(co.id, co.plan === 'aucune' ? 'essentiel' : co.plan, until, o.status === 'past_due' ? 'impayé' : 'actif');
    return json({ ok: true, updated: co.id });
  }
  return json({ ignored: type });
}

// Nombre de salariés, envoyé à Polar (le prix par salarié prend le maximum du mois)
export async function usage(req, body, db, polar) {
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  const user = token ? await db.userFromToken(token) : null;
  if (!user) return json({ error: 'Non connecté' }, 401);
  const cid = String(body.company_id || '');
  if (!(await db.isMember(cid, user.id))) return json({ error: 'Accès refusé' }, 403);
  const b = await db.billing(cid);
  if (!b || !b.customer || b.plan === 'aucune') return json({ skipped: 'pas d\'abonnement Polar' });
  await polar.ingest({ name: 'salaries', customer_id: b.customer, external_id: `${cid}-${new Date().toISOString().slice(0, 10)}-${b.employees}`, metadata: { salaries: b.employees } });
  return json({ ok: true, employees: b.employees });
}

export async function handle(req, db, polar, secret) {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Méthode non autorisée' }, 405);
  const raw = await req.text();
  if (req.headers.get('webhook-signature')) return webhook(raw, req.headers, db, secret);
  let body = {};
  try { body = JSON.parse(raw || '{}'); } catch (_) { /* rien */ }
  if (body.action === 'usage') return usage(req, body, db, polar);
  return json({ error: 'Requête inconnue' }, 400);
}

if (!Deno.env.get('MONKIOSK_TEST')) {
  const db = supabaseDb();
  Deno.serve((req) => handle(req, db, polarApi, Deno.env.get('POLAR_WEBHOOK_SECRET')).catch((e) => json({ error: String(e && e.message || e) }, 500)));
}
