// MonKiosk : active automatiquement la formule après un paiement Polar.
// À créer dans Supabase > Edge Functions sous le nom « polar-webhook »,
// avec « Verify JWT » désactivé (c'est Polar qui appelle, pas un utilisateur).
// Secret à ajouter dans Edge Functions > Secrets : POLAR_WEBHOOK_SECRET (le secret du webhook, commence par whsec_).
import { createClient } from 'npm:@supabase/supabase-js@2.57.4';

const PLANS = ['essentiel', 'pro', 'premium'];
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

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
  };
}

const day = (iso) => (iso ? String(iso).slice(0, 10) : null);
const ENDED = ['canceled', 'unpaid', 'incomplete_expired'];

export async function handle(req, db, secret) {
  if (req.method !== 'POST') return json({ error: 'Méthode non autorisée' }, 405);
  const raw = await req.text();
  if (!(await verifySignature(raw, req.headers, secret))) return json({ error: 'Signature invalide' }, 403);
  const event = JSON.parse(raw), type = String(event.type || ''), o = event.data || {};
  const isSub = type.startsWith('subscription.');
  const subId = isSub ? o.id : o.subscription_id;

  // 1. Premier paiement : la référence « commerce__formule » vient du lien de paiement MonKiosk
  const [cid, plan] = String((o.metadata && o.metadata.reference_id) || '').split('__');
  const known = /^[0-9a-f-]{36}$/.test(cid || '') && PLANS.includes(plan);
  if (known && (type === 'order.paid' || type === 'order.created' || type === 'subscription.created' || type === 'subscription.active')) {
    if (!isSub || o.status === 'active' || o.status === 'trialing') {
      await db.applyPlan(cid, plan, null, 'actif');
      await db.setBilling(cid, o.customer_id || null, subId || null);
      return json({ ok: true, cid, plan });
    }
  }

  // 2. Vie de l'abonnement : résiliation, impayé, réactivation
  if (isSub && subId) {
    const co = await db.bySubscription(subId);
    if (!co) return json({ ignored: 'abonnement inconnu' });
    if (type === 'subscription.revoked' || ENDED.includes(o.status)) {
      await db.applyPlan(co.id, 'essentiel', null, 'résilié');
      return json({ ok: true, downgraded: co.id });
    }
    const until = o.cancel_at_period_end ? day(o.current_period_end || o.ends_at) : null;
    await db.applyPlan(co.id, co.plan, until, o.status === 'past_due' ? 'impayé' : 'actif');
    return json({ ok: true, updated: co.id });
  }

  return json({ ignored: type });
}

if (!Deno.env.get('MONKIOSK_TEST')) {
  const db = supabaseDb();
  Deno.serve((req) => handle(req, db, Deno.env.get('POLAR_WEBHOOK_SECRET')).catch((e) => json({ error: String(e && e.message || e) }, 500)));
}
