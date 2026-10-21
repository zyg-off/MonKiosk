-- MonKiosk 2.2 : plus de formule gratuite. Un commerce sans abonnement actif est bloqué.
-- À coller dans Supabase > SQL Editor, puis "Run". Peut être relancé sans risque.

-- 1. « aucune » = pas d'abonnement : c'est l'état d'un nouveau commerce
alter table public.companies alter column plan set default 'aucune';
alter table public.companies alter column plan_status set default 'aucune';

-- Une seule fois : les commerces qui avaient la formule Essentielle gratuite par défaut passent sans abonnement
do $$ begin
  if coalesce((select data->>'v22' from public.platform_config where id = 1), '') <> 'ok' then
    update public.companies set plan = 'aucune', plan_status = 'aucune', plan_features = public.plan_features_for('aucune')
      where plan = 'essentiel' and stripe_subscription is null and plan_until is null;
    update public.platform_config set data = data || '{"v22":"ok"}'::jsonb where id = 1;
  end if;
end $$;

-- Prix : un prix de base par commerce et un prix par salarié
update public.platform_config set data = jsonb_set(data, '{plans,essentiel}',
  coalesce(data->'plans'->'essentiel', '{}'::jsonb) || '{"name":"Essentiel","price":4.99,"per_employee":3}'::jsonb, true)
where id = 1 and coalesce((data->'plans'->'essentiel'->>'price')::numeric, 0) = 0;

-- 2. Le commerce est-il actif ? (l'équipe MonKiosk n'est jamais bloquée, pour pouvoir aider)
create or replace function public.company_active(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_platform_admin() or exists (
    select 1 from public.companies c where c.id = cid
      and c.plan in ('essentiel','pro','premium')
      and c.plan_status not in ('aucune','résilié','expiré')
      and (c.plan_until is null or c.plan_until >= (now() at time zone 'Europe/Paris')::date));
$$;
revoke all on function public.company_active(uuid) from public, anon;
grant execute on function public.company_active(uuid) to authenticated;

-- Toutes les options (et l'espace salarié) s'arrêtent sans abonnement
create or replace function public.feature_on(cid uuid, d jsonb, fkey text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.company_active(cid)
     and (case when fkey = any(public.premium_keys())
            then coalesce((select (plan_features->>fkey)::boolean from public.companies where id = cid), false)
            else true end)
     and coalesce(d #>> array['settings','modules',fkey], 'true') <> 'false';
$$;
revoke all on function public.feature_on(uuid,jsonb,text) from public, anon, authenticated;

-- Les données du commerce ne sont lisibles et modifiables qu'avec un abonnement actif
drop policy if exists "data_select" on public.company_data;
create policy "data_select" on public.company_data for select to authenticated
  using (public.is_staff(company_id) and public.company_active(company_id));
drop policy if exists "data_update" on public.company_data;
create policy "data_update" on public.company_data for update to authenticated
  using (public.is_staff(company_id) and public.company_active(company_id))
  with check (public.is_staff(company_id) and public.company_active(company_id));

-- 3. Formules : « aucune » possible (fin d'abonnement, retrait par l'administration)
create or replace function public.apply_plan(cid uuid, p_plan text, p_until date, p_status text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f jsonb;
begin
  if p_plan not in ('aucune','essentiel','pro','premium') then raise exception 'Formule inconnue'; end if;
  update public.companies set plan = p_plan, plan_until = p_until,
    plan_status = case when p_plan = 'aucune' then coalesce(nullif(p_status, 'actif'), 'aucune') else coalesce(p_status, 'actif') end,
    plan_features = public.plan_features_for(p_plan)
    where id = cid returning plan_features into f;
  if f is null then raise exception 'Commerce introuvable'; end if;
  return f;
end $$;
revoke all on function public.apply_plan(uuid,text,date,text) from public, anon, authenticated;
grant execute on function public.apply_plan(uuid,text,date,text) to service_role;

-- Échéance passée sans renouvellement : le commerce est bloqué
create or replace function public.expire_plans()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with x as (
    update public.companies set plan = 'aucune', plan_status = 'expiré', plan_features = public.plan_features_for('aucune')
    where plan <> 'aucune' and plan_until is not null and plan_until < (now() at time zone 'Europe/Paris')::date
    returning 1)
  select count(*) into n from x;
  return n;
end $$;
revoke all on function public.expire_plans() from public, anon, authenticated;

create or replace function public.my_plan(cid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not public.is_member(cid) then raise exception 'Non connecté'; end if;
  perform public.expire_plans();
  select plan, plan_until, plan_status, plan_features into r from public.companies where id = cid;
  return jsonb_build_object('plan', r.plan, 'until', r.plan_until, 'status', r.plan_status, 'features', r.plan_features,
    'active', public.company_active(cid), 'admin', public.is_platform_admin());
end $$;
revoke all on function public.my_plan(uuid) from public, anon;
grant execute on function public.my_plan(uuid) to authenticated;
