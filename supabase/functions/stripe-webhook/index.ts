// MonKiosk : active automatiquement la formule après un paiement Stripe.
// À créer dans Supabase > Edge Functions sous le nom « stripe-webhook »,
// avec « Verify JWT » désactivé (c'est Stripe qui appelle, pas un utilisateur).
// Secret à ajouter dans Edge Functions > Secrets : STRIPE_WEBHOOK_SECRET (commence par whsec_).
import { createClient } from 'npm:@supabase/supabase-js@2.57.4';

const PLANS = ['essentiel', 'pro', 'premium'];
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

// Vérifie que la requête vient bien de Stripe (signature HMAC-SHA256)
export async function verifySignature(raw, header, secret, nowSec = Math.floor(Date.now() / 1000)) {
  if (!header || !secret) return false;
  const parts = header.split(',').map((p) => p.split('='));
  const t = (parts.find((p) => p[0] === 't') || [])[1];
  const sigs = parts.filter((p) => p[0] === 'v1').map((p) => p[1]);
  if (!t || !sigs.length || Math.abs(nowSec - Number(t)) > 300) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${t}.${raw}`)));
  const hex = Array.from(mac, (b) => b.toString(16).padStart(2, '0')).join('');
  return sigs.some((s) => s.length === hex.length && [...s].reduce((acc, c, i) => acc | (c.charCodeAt(0) ^ hex.charCodeAt(i)), 0) === 0);
}

export function supabaseDb() {
  const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
  return {
    async applyPlan(cid, plan, until, status) {
      const { error } = await db.rpc('apply_plan', { cid, p_plan: plan, p_until: until, p_status: status });
      if (error) throw new Error(error.message);
    },
    async setStripe(cid, customer, subscription) {
      const { error } = await db.from('companies').update({ stripe_customer: customer, stripe_subscription: subscription }).eq('id', cid);
      if (error) throw new Error(error.message);
    },
    async bySubscription(sub) {
      const { data } = await db.from('companies').select('id,plan').eq('stripe_subscription', sub).maybeSingle();
      return data;
    },
  };
}

const day = (sec) => (sec ? new Date(sec * 1000).toISOString().slice(0, 10) : null);

export async function handle(req, db, secret) {
  if (req.method !== 'POST') return json({ error: 'Méthode non autorisée' }, 405);
  const raw = await req.text();
  if (!(await verifySignature(raw, req.headers.get('Stripe-Signature'), secret))) return json({ error: 'Signature invalide' }, 400);
  const event = JSON.parse(raw);
  const o = (event.data && event.data.object) || {};

  if (event.type === 'checkout.session.completed') {
    const [cid, plan] = String(o.client_reference_id || '').split('__');
    if (!/^[0-9a-f-]{36}$/.test(cid || '') || !PLANS.includes(plan)) return json({ ignored: 'référence inconnue' });
    await db.applyPlan(cid, plan, null, 'actif');
    await db.setStripe(cid, o.customer || null, o.subscription || null);
    return json({ ok: true, cid, plan });
  }

  if (event.type === 'customer.subscription.updated' || event.type === 'customer.subscription.deleted') {
    const co = await db.bySubscription(o.id);
    if (!co) return json({ ignored: 'abonnement inconnu' });
    if (event.type === 'customer.subscription.deleted' || ['canceled', 'unpaid', 'incomplete_expired'].includes(o.status)) {
      await db.applyPlan(co.id, 'essentiel', null, 'résilié');
      return json({ ok: true, downgraded: co.id });
    }
    const end = o.current_period_end || (o.items && o.items.data && o.items.data[0] && o.items.data[0].current_period_end);
    const status = o.status === 'past_due' ? 'impayé' : 'actif';
    await db.applyPlan(co.id, co.plan, o.cancel_at_period_end ? day(end) : null, status);
    return json({ ok: true, updated: co.id });
  }

  return json({ ignored: event.type });
}

if (!Deno.env.get('MONKIOSK_TEST')) {
  const db = supabaseDb();
  Deno.serve((req) => handle(req, db, Deno.env.get('STRIPE_WEBHOOK_SECRET')).catch((e) => json({ error: String(e && e.message || e) }, 500)));
}
