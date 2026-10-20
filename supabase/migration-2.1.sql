-- MonKiosk 2.1 : formules d'abonnement, documents salariés, notifications sur téléphone
-- À coller dans Supabase > SQL Editor, puis "Run". Peut être relancé sans risque.

-- 1. Formule de chaque commerce
alter table public.companies add column if not exists plan text not null default 'essentiel';
alter table public.companies add column if not exists plan_until date;
alter table public.companies add column if not exists plan_status text not null default 'actif';
alter table public.companies add column if not exists stripe_customer text;
alter table public.companies add column if not exists stripe_subscription text;
grant select (id, name, created_at, plan_features, plan, plan_until, plan_status) on public.companies to authenticated;

-- Options réservées (débloquées par la formule ou par l'équipe MonKiosk)
create or replace function public.premium_keys()
returns text[] language sql immutable as $$
  select array['espace','badgeuse','couts','registre','stats','rentabilite','previsions','paie','documents','tablette'];
$$;

-- Ce que contient chaque formule
create or replace function public.plan_features_for(p text)
returns jsonb language sql immutable as $$
  select jsonb_object_agg(k, case
      when p = 'premium' then true
      when p = 'pro' then k in ('espace','badgeuse','couts','registre','stats','rentabilite','previsions','paie')
      else false end)
  from unnest(public.premium_keys()) k;
$$;

create or replace function public.feature_on(cid uuid, d jsonb, fkey text)
returns boolean language sql stable security definer set search_path = public as $$
  select (case when fkey = any(public.premium_keys())
            then coalesce((select (plan_features->>fkey)::boolean from public.companies where id = cid), false)
            else true end)
     and coalesce(d #>> array['settings','modules',fkey], 'true') <> 'false';
$$;
revoke all on function public.feature_on(uuid,jsonb,text) from public, anon, authenticated;

create or replace function public.admin_set_feature(cid uuid, fkey text, enabled boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f jsonb;
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''équipe MonKiosk'; end if;
  if not (fkey = any(public.premium_keys())) then raise exception 'Option inconnue'; end if;
  update public.companies set plan_features = coalesce(plan_features, '{}'::jsonb) || jsonb_build_object(fkey, enabled)
    where id = cid returning plan_features into f;
  return f;
end $$;
revoke all on function public.admin_set_feature(uuid,text,boolean) from public, anon;
grant execute on function public.admin_set_feature(uuid,text,boolean) to authenticated;

-- Appliquer une formule (utilisé par l'administration et par le paiement en ligne)
create or replace function public.apply_plan(cid uuid, p_plan text, p_until date, p_status text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f jsonb;
begin
  if p_plan not in ('essentiel','pro','premium') then raise exception 'Formule inconnue'; end if;
  update public.companies set plan = p_plan, plan_until = p_until, plan_status = coalesce(p_status, 'actif'),
    plan_features = public.plan_features_for(p_plan)
    where id = cid returning plan_features into f;
  if f is null then raise exception 'Commerce introuvable'; end if;
  return f;
end $$;
revoke all on function public.apply_plan(uuid,text,date,text) from public, anon, authenticated;
grant execute on function public.apply_plan(uuid,text,date,text) to service_role;

create or replace function public.admin_set_plan(cid uuid, p_plan text, p_until date)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''équipe MonKiosk'; end if;
  return public.apply_plan(cid, p_plan, p_until, 'actif');
end $$;
revoke all on function public.admin_set_plan(uuid,text,date) from public, anon;
grant execute on function public.admin_set_plan(uuid,text,date) to authenticated;

-- Fin de période sans renouvellement : retour à la formule Essentielle
create or replace function public.expire_plans()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with x as (
    update public.companies set plan = 'essentiel', plan_status = 'expiré', plan_features = public.plan_features_for('essentiel')
    where plan <> 'essentiel' and plan_until is not null and plan_until < (now() at time zone 'Europe/Paris')::date
    returning 1)
  select count(*) into n from x;
  return n;
end $$;
revoke all on function public.expire_plans() from public, anon, authenticated;

drop function if exists public.admin_companies();
create or replace function public.admin_companies()
returns table (id uuid, name text, created_at timestamptz, owner_email text, features jsonb, member_count int, plan text, plan_until date, plan_status text)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''équipe MonKiosk'; end if;
  perform public.expire_plans();
  return query select c.id, c.name, c.created_at,
    (select u.email::text from public.members m join auth.users u on u.id = m.user_id where m.company_id = c.id and m.role = 'owner' order by m.created_at limit 1),
    c.plan_features, (select count(*)::int from public.members m where m.company_id = c.id), c.plan, c.plan_until, c.plan_status
  from public.companies c order by c.created_at desc;
end $$;
revoke all on function public.admin_companies() from public, anon;
grant execute on function public.admin_companies() to authenticated;

-- Formule du commerce ouvert (vérifie aussi l'échéance)
create or replace function public.my_plan(cid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not public.is_member(cid) then raise exception 'Non connecté'; end if;
  perform public.expire_plans();
  select plan, plan_until, plan_status, plan_features into r from public.companies where id = cid;
  return jsonb_build_object('plan', r.plan, 'until', r.plan_until, 'status', r.plan_status, 'features', r.plan_features);
end $$;
revoke all on function public.my_plan(uuid) from public, anon;
grant execute on function public.my_plan(uuid) to authenticated;

-- 2. Réglages de la plateforme (prix, liens de paiement), lisibles par tous les comptes
create table if not exists public.platform_config (
  id int primary key default 1 check (id = 1),
  data jsonb not null default '{}'::jsonb
);
alter table public.platform_config enable row level security;
insert into public.platform_config (id, data) values (1, '{
  "plans": {
    "essentiel": {"name": "Essentiel", "price": 0, "link": ""},
    "pro": {"name": "Pro", "price": 29, "link": ""},
    "premium": {"name": "Premium", "price": 49, "link": ""}
  },
  "portal": "", "contact": ""
}'::jsonb) on conflict (id) do nothing;
drop policy if exists "config_read" on public.platform_config;
create policy "config_read" on public.platform_config for select to authenticated using (true);
revoke all on public.platform_config from anon, authenticated;
grant select on public.platform_config to authenticated;

create or replace function public.admin_set_config(cfg jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d jsonb;
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''équipe MonKiosk'; end if;
  if jsonb_typeof(cfg) <> 'object' then raise exception 'Réglages invalides'; end if;
  update public.platform_config set data = cfg where id = 1 returning data into d;
  return d;
end $$;
revoke all on function public.admin_set_config(jsonb) from public, anon;
grant execute on function public.admin_set_config(jsonb) to authenticated;

-- 3. Notifications sur téléphone (même appli fermée)
create table if not exists public.push_subscriptions (
  endpoint text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  keys jsonb not null,
  created_at timestamptz not null default now(),
  primary key (endpoint, company_id)
);
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon, authenticated;

-- Clés d'envoi : créées et lues uniquement par le service d'envoi
create table if not exists public.push_keys (
  id int primary key default 1 check (id = 1),
  public_key text not null,
  private_key text not null
);
alter table public.push_keys enable row level security;
revoke all on public.push_keys from anon, authenticated;

create or replace function public.push_subscribe(cid uuid, sub jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member(cid) then raise exception 'Non connecté'; end if;
  if coalesce(sub->>'endpoint', '') !~ '^https://' or sub->'keys'->>'p256dh' is null or sub->'keys'->>'auth' is null then
    raise exception 'Abonnement invalide'; end if;
  -- Un même téléphone peut suivre plusieurs commerces, mais un seul compte à la fois
  delete from public.push_subscriptions where endpoint = sub->>'endpoint' and (company_id = cid or user_id <> auth.uid());
  insert into public.push_subscriptions (endpoint, user_id, company_id, keys)
    values (sub->>'endpoint', auth.uid(), cid, sub->'keys');
  return true;
end $$;
create or replace function public.push_unsubscribe(cid uuid, p_endpoint text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  delete from public.push_subscriptions where endpoint = p_endpoint and company_id = cid and user_id = auth.uid();
  return true;
end $$;
do $$ declare f text; begin
  foreach f in array array['push_subscribe(uuid,jsonb)','push_unsubscribe(uuid,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

-- 4. Documents salariés (contrats, attestations, arrêts...)
-- Rangement : <commerce>/<salarié>/<fichier>. Le patron voit tout ; chaque salarié ne voit que son dossier.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 10485760,
  array['application/pdf','image/jpeg','image/png','image/webp','image/heic','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.doc_access(p_name text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare parts text[]; cid uuid; r record;
begin
  parts := string_to_array(p_name, '/');
  if coalesce(array_length(parts, 1), 0) <> 3 or parts[1] !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  cid := parts[1]::uuid;
  select role, employee_id into r from public.members where company_id = cid and user_id = auth.uid();
  if not found then return false; end if;
  if r.role = 'owner' then return true; end if;
  if not coalesce((select (plan_features->>'documents')::boolean from public.companies where id = cid), false) then return false; end if;
  return r.employee_id is not null and parts[2] = r.employee_id;
end $$;
create or replace function public.doc_owner(p_name text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare parts text[];
begin
  parts := string_to_array(p_name, '/');
  if coalesce(array_length(parts, 1), 0) <> 3 or parts[1] !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  return exists (select 1 from public.members where company_id = parts[1]::uuid and user_id = auth.uid() and role = 'owner');
end $$;
do $$ declare f text; begin
  foreach f in array array['doc_access(text)','doc_owner(text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

drop policy if exists "docs_read" on storage.objects;
drop policy if exists "docs_add" on storage.objects;
drop policy if exists "docs_delete" on storage.objects;
create policy "docs_read" on storage.objects for select to authenticated
  using (bucket_id = 'documents' and public.doc_access(name));
create policy "docs_add" on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and public.doc_access(name));
create policy "docs_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and public.doc_owner(name));
