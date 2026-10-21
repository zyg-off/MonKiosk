-- MonKiosk 2.3 : prix par salarié sur toutes les formules, « Boutiques regroupées » réservé à Premium
-- À coller dans Supabase > SQL Editor, puis "Run". Peut être relancé sans risque.

create or replace function public.premium_keys()
returns text[] language sql immutable as $$
  select array['espace','badgeuse','couts','registre','stats','rentabilite','previsions','paie','documents','tablette','multi'];
$$;

-- Premium contient tout ; Pro ne change pas
create or replace function public.plan_features_for(p text)
returns jsonb language sql immutable as $$
  select jsonb_object_agg(k, case
      when p = 'premium' then true
      when p = 'pro' then k in ('espace','badgeuse','couts','registre','stats','rentabilite','previsions','paie')
      else false end)
  from unnest(public.premium_keys()) k;
$$;

-- Les commerces déjà en Premium reçoivent la nouvelle option
update public.companies set plan_features = coalesce(plan_features, '{}'::jsonb) || '{"multi":true}'::jsonb
  where plan = 'premium' and coalesce(plan_features->>'multi', '') <> 'true';

-- 3 € par salarié aussi en Pro et Premium (seulement si aucun prix par salarié n'est déjà réglé)
update public.platform_config set data = jsonb_set(jsonb_set(data,
    '{plans,pro}', coalesce(data->'plans'->'pro', '{"name":"Pro","price":29,"link":""}'::jsonb) || '{"per_employee":3}'::jsonb, true),
    '{plans,premium}', coalesce(data->'plans'->'premium', '{"name":"Premium","price":49,"link":""}'::jsonb) || '{"per_employee":3}'::jsonb, true)
where id = 1 and coalesce((data->'plans'->'pro'->>'per_employee')::numeric, 0) = 0
  and coalesce((data->'plans'->'premium'->>'per_employee')::numeric, 0) = 0;
