// MonKiosk : envoi des notifications sur téléphone (même appli fermée).
// À créer dans Supabase > Edge Functions sous le nom « notify ». Aucun réglage à faire :
// les clés d'envoi sont créées toutes seules au premier usage et restent dans la base.
import { createClient } from 'npm:@supabase/supabase-js@2.57.4';
import webpush from 'npm:web-push@3.6.7';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const clip = (s, n) => String(s || '').replace(/\s+/g, ' ').trim().slice(0, n);

// Base de données (droits du service, jamais exposés au navigateur)
export function supabaseDb() {
  const db = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
  return {
    async userFromToken(token) { const { data } = await db.auth.getUser(token); return data && data.user; },
    async keys() {
      let { data } = await db.from('push_keys').select('public_key,private_key').eq('id', 1).maybeSingle();
      if (!data) {
        const k = webpush.generateVAPIDKeys();
        await db.from('push_keys').upsert({ id: 1, public_key: k.publicKey, private_key: k.privateKey }, { onConflict: 'id', ignoreDuplicates: true });
        ({ data } = await db.from('push_keys').select('public_key,private_key').eq('id', 1).single());
      }
      return data;
    },
    async members(cid) { const { data } = await db.from('members').select('user_id,role,employee_id').eq('company_id', cid); return data || []; },
    async subscriptions(cid, users) {
      const { data } = await db.from('push_subscriptions').select('endpoint,keys,user_id').eq('company_id', cid).in('user_id', users);
      return data || [];
    },
    async forget(endpoint) { await db.from('push_subscriptions').delete().eq('endpoint', endpoint); },
  };
}

export const webPush = {
  async send(sub, payload, keys) {
    webpush.setVapidDetails('https://zyg-off.github.io/MonKiosk/', keys.public_key, keys.private_key);
    await webpush.sendNotification({ endpoint: sub.endpoint, keys: sub.keys }, payload, { TTL: 60 * 60 * 24 });
  },
};

export async function handle(req, db, push) {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Méthode non autorisée' }, 405);
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  const user = token ? await db.userFromToken(token) : null;
  if (!user) return json({ error: 'Non connecté' }, 401);
  const body = await req.json().catch(() => ({}));
  const keys = await db.keys();
  if (body.action === 'key') return json({ key: keys.public_key });

  const cid = String(body.company_id || '');
  const members = await db.members(cid);
  const me = members.find((m) => m.user_id === user.id);
  if (!me) return json({ error: 'Accès refusé' }, 403);

  let targets;
  if (body.action === 'test') targets = [me];
  else if (body.to === 'staff') targets = members.filter((m) => m.role === 'owner' || m.role === 'manager');
  else if (body.to === 'all') targets = members;
  else if (body.to && Array.isArray(body.to.employees) && me.role !== 'employee')
    targets = members.filter((m) => m.employee_id && body.to.employees.includes(m.employee_id));
  else return json({ error: 'Destinataires invalides' }, 400);
  const users = targets.map((m) => m.user_id).filter((u) => body.action === 'test' || u !== user.id);
  if (!users.length) return json({ sent: 0 });

  const payload = JSON.stringify({
    title: clip(body.title, 60) || 'MonKiosk',
    body: clip(body.body, 180),
    tag: clip(body.tag, 40) || undefined,
    url: './',
  });
  const subs = await db.subscriptions(cid, users);
  let sent = 0;
  await Promise.all(subs.map(async (s) => {
    try { await push.send(s, payload, keys); sent++; }
    catch (e) { if (e && (e.statusCode === 404 || e.statusCode === 410)) await db.forget(s.endpoint); }
  }));
  return json({ sent });
}

if (!Deno.env.get('MONKIOSK_TEST')) {
  const db = supabaseDb();
  Deno.serve((req) => handle(req, db, webPush).catch((e) => json({ error: String(e && e.message || e) }, 500)));
}
