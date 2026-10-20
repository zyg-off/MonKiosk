-- MonKiosk 1.5 : options par commerce, fonctions réservées (activées par l'équipe MonKiosk),
-- code de pointage du jour, pertes par produit saisies par les salariés.
-- À coller une fois dans Supabase > SQL Editor > New query, puis "Run". Sans risque si relancé.

-- Fonctions premium débloquées par l'équipe MonKiosk, et secret du code de pointage
alter table public.companies add column if not exists plan_features jsonb not null default '{}'::jsonb;
alter table public.companies add column if not exists punch_secret uuid not null default gen_random_uuid();

-- Les patrons ne peuvent modifier que le nom ; le secret et le code d'accès ne sont plus lisibles directement
revoke select, insert, update, delete on public.companies from anon, authenticated;
grant select (id, name, created_at, plan_features) on public.companies to authenticated;
grant update (name) on public.companies to authenticated;

-- Administrateurs de la plateforme MonKiosk
create table if not exists public.platform_admins (user_id uuid primary key references auth.users(id) on delete cascade);
alter table public.platform_admins enable row level security;

create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid());
$$;

-- Une option est active si elle est autorisée (débloquée pour les options réservées) et pas désactivée par le patron
create or replace function public.feature_on(cid uuid, d jsonb, fkey text)
returns boolean language sql stable security definer set search_path = public as $$
  select (case when fkey in ('espace','badgeuse','couts','registre','stats')
            then coalesce((select (plan_features->>fkey)::boolean from public.companies where id = cid), false)
            else true end)
     and coalesce(d #>> array['settings','modules',fkey], 'true') <> 'false';
$$;

-- Code du jour (4 chiffres), différent chaque jour et pour chaque commerce
create or replace function public.daily_code_for(cid uuid, d date)
returns text language sql stable security definer set search_path = public as $$
  select lpad(((('x' || substr(md5(punch_secret::text || d::text), 1, 7))::bit(28)::int) % 10000)::text, 4, '0')
  from public.companies where id = cid;
$$;
create or replace function public.punch_code(cid uuid)
returns text language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff(cid) then raise exception 'Réservé aux responsables'; end if;
  return public.daily_code_for(cid, (now() at time zone 'Europe/Paris')::date);
end $$;

create or replace function public.get_join_code(cid uuid)
returns text language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff(cid) then raise exception 'Réservé aux responsables'; end if;
  return (select join_code from public.companies where id = cid);
end $$;

-- Administration MonKiosk
create or replace function public.admin_companies()
returns table (id uuid, name text, created_at timestamptz, owner_email text, features jsonb, member_count int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''équipe MonKiosk'; end if;
  return query select c.id, c.name, c.created_at,
    (select u.email::text from public.members m join auth.users u on u.id = m.user_id where m.company_id = c.id and m.role = 'owner' order by m.created_at limit 1),
    c.plan_features, (select count(*)::int from public.members m where m.company_id = c.id)
  from public.companies c order by c.created_at desc;
end $$;
create or replace function public.admin_set_feature(cid uuid, fkey text, enabled boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f jsonb;
begin
  if not public.is_platform_admin() then raise exception 'Réservé à l''équipe MonKiosk'; end if;
  if fkey not in ('espace','badgeuse','couts','registre','stats') then raise exception 'Option inconnue'; end if;
  update public.companies set plan_features = coalesce(plan_features, '{}'::jsonb) || jsonb_build_object(fkey, enabled)
    where id = cid returning plan_features into f;
  return f;
end $$;

-- Rejoindre : seulement si l'espace salarié est activé
create or replace function public.join_preview(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c_id uuid; c_name text; d jsonb; emps jsonb;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select co.id, co.name, cd.data into c_id, c_name, d
    from public.companies co join public.company_data cd on cd.company_id = co.id where co.join_code = upper(trim(p_code));
  if c_id is null then raise exception 'Code invalide'; end if;
  if not public.feature_on(c_id, d, 'espace') then raise exception 'L''espace salarié n''est pas activé pour ce commerce'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', e->>'id', 'name', e->>'name') order by e->>'name'), '[]'::jsonb) into emps
    from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e
    where not exists (select 1 from public.members m where m.company_id = c_id and m.employee_id = e->>'id' and m.user_id <> auth.uid());
  return jsonb_build_object('company', c_name, 'employees', emps);
end $$;

create or replace function public.join_company(p_code text, p_employee text)
returns uuid language plpgsql security definer set search_path = public as $$
declare c_id uuid; d jsonb;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select co.id, cd.data into c_id, d
    from public.companies co join public.company_data cd on cd.company_id = co.id where co.join_code = upper(trim(p_code));
  if c_id is null then raise exception 'Code invalide'; end if;
  if not public.feature_on(c_id, d, 'espace') then raise exception 'L''espace salarié n''est pas activé pour ce commerce'; end if;
  if not exists (select 1 from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = p_employee) then
    raise exception 'Salarié introuvable'; end if;
  if exists (select 1 from public.members where company_id = c_id and employee_id = p_employee and user_id <> auth.uid()) then
    raise exception 'Ce salarié a déjà un compte'; end if;
  if exists (select 1 from public.members where company_id = c_id and user_id = auth.uid() and role <> 'employee') then
    raise exception 'Tu es déjà responsable de ce commerce'; end if;
  insert into public.members (company_id, user_id, role, employee_id) values (c_id, auth.uid(), 'employee', p_employee)
    on conflict (company_id, user_id) do update set employee_id = excluded.employee_id;
  return c_id;
end $$;

-- Espace salarié
create or replace function public.employee_view(cid uuid, p_day text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare eid text; d jsonb; nm text; wk jsonb;
begin
  select m.employee_id into eid from public.members m where m.company_id = cid and m.user_id = auth.uid() and m.role = 'employee';
  if eid is null then raise exception 'Accès salarié introuvable'; end if;
  select cd.data, co.name into d, nm from public.company_data cd join public.companies co on co.id = cd.company_id where cd.company_id = cid;
  if not public.feature_on(cid, d, 'espace') then raise exception 'L''espace salarié n''est pas activé pour ce commerce'; end if;
  select coalesce(jsonb_object_agg(w.key, jsonb_build_object(eid, w.value->eid)), '{}'::jsonb) into wk
    from jsonb_each(coalesce(d->'weeks', '{}'::jsonb)) w
    where w.value ? eid and w.key >= to_char(current_date - 7, 'YYYY-MM-DD');
  return jsonb_build_object(
    'shop', coalesce(d->>'shop', nm),
    'employee', (select jsonb_build_object('id', e->>'id', 'name', e->>'name', 'poste', e->>'poste', 'contract', e->'contract')
                   from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = eid limit 1),
    'features', jsonb_build_object(
      'badgeuse', public.feature_on(cid, d, 'badgeuse'), 'conges', public.feature_on(cid, d, 'conges'),
      'annonces', public.feature_on(cid, d, 'annonces'), 'taches', public.feature_on(cid, d, 'taches'),
      'hygiene', public.feature_on(cid, d, 'hygiene'), 'pertes', public.feature_on(cid, d, 'pertes')),
    'postes', coalesce(d->'postes', '[]'::jsonb),
    'weeks', wk,
    'leaves', (select coalesce(jsonb_agg(l), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'leaves', '[]'::jsonb)) l where l->>'emp' = eid),
    'notes', coalesce(d->'notes', '[]'::jsonb),
    'lists', coalesce(d->'lists', '[]'::jsonb),
    'done', coalesce(d->'done'->p_day, '{}'::jsonb),
    'equipments', coalesce(d->'equipments', '[]'::jsonb),
    'products', (select coalesce(jsonb_agg(jsonb_build_object('id', p->>'id', 'name', p->>'name', 'unit', p->>'unit', 'price', p->'price')), '[]'::jsonb)
                   from jsonb_array_elements(coalesce(d->'products', '[]'::jsonb)) p),
    'losses', coalesce(d->'lossDays'->p_day, '{}'::jsonb),
    'punches', (select coalesce(jsonb_agg(p), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'punches', '[]'::jsonb)) p
                  where p->>'emp' = eid and left(p->>'at', 10) >= to_char(current_date - 14, 'YYYY-MM-DD'))
  );
end $$;

create or replace function public.employee_action(cid uuid, p_action text, p_payload jsonb, p_day text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare eid text; d jsonb; nid text; nowiso text; v numeric; q numeric; prod jsonb; pid text;
begin
  select m.employee_id into eid from public.members m where m.company_id = cid and m.user_id = auth.uid() and m.role = 'employee';
  if eid is null then raise exception 'Accès salarié introuvable'; end if;
  select data into d from public.company_data where company_id = cid for update;
  if not public.feature_on(cid, d, 'espace') then raise exception 'L''espace salarié n''est pas activé pour ce commerce'; end if;
  nid := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
  nowiso := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  if p_action = 'punch' then
    if not public.feature_on(cid, d, 'badgeuse') then raise exception 'La badgeuse n''est pas activée'; end if;
    if coalesce(p_payload->>'kind', '') not in ('in', 'out') then raise exception 'Pointage invalide'; end if;
    if coalesce(p_payload->>'code', '') <> public.daily_code_for(cid, (now() at time zone 'Europe/Paris')::date) then
      raise exception 'Code du jour incorrect'; end if;
    d := jsonb_set(d, '{punches}', coalesce(d->'punches', '[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('id', nid, 'emp', eid, 'kind', p_payload->>'kind', 'at', nowiso)));
  elsif p_action = 'leave' then
    if not public.feature_on(cid, d, 'conges') then raise exception 'Les congés ne sont pas activés'; end if;
    if coalesce(p_payload->>'type', '') not in ('Congés payés', 'Maladie', 'Formation', 'Absence') then raise exception 'Motif invalide'; end if;
    if (p_payload->>'from') is null or (p_payload->>'to') is null or (p_payload->>'to') < (p_payload->>'from') then raise exception 'Dates invalides'; end if;
    d := jsonb_set(d, '{leaves}', coalesce(d->'leaves', '[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('id', nid, 'emp', eid, 'type', p_payload->>'type', 'from', p_payload->>'from', 'to', p_payload->>'to', 'status', 'attente')));
  elsif p_action = 'task' then
    if not public.feature_on(cid, d, 'taches') then raise exception 'Les checklists ne sont pas activées'; end if;
    if not (coalesce(d->'done', '{}'::jsonb) ? p_day) then
      d := jsonb_set(d, '{done}', coalesce(d->'done', '{}'::jsonb) || jsonb_build_object(p_day, '{}'::jsonb)); end if;
    d := jsonb_set(d, array['done', p_day, p_payload->>'task'], to_jsonb(coalesce((p_payload->>'done')::boolean, false)));
  elsif p_action = 'temp' then
    if not public.feature_on(cid, d, 'hygiene') then raise exception 'Les relevés ne sont pas activés'; end if;
    v := (p_payload->>'val')::numeric;
    d := jsonb_set(d, '{temps}', coalesce(d->'temps', '[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('id', nid, 'at', nowiso, 'equip', p_payload->>'equip', 'val', v, 'by', eid)));
  elsif p_action = 'loss' then
    if not public.feature_on(cid, d, 'pertes') then raise exception 'Les pertes ne sont pas activées'; end if;
    pid := p_payload->>'product';
    select p into prod from jsonb_array_elements(coalesce(d->'products', '[]'::jsonb)) p where p->>'id' = pid limit 1;
    if prod is null then raise exception 'Produit introuvable'; end if;
    q := greatest(0, coalesce((p_payload->>'qty')::numeric, 0));
    if not (coalesce(d->'lossDays', '{}'::jsonb) ? p_day) then
      d := jsonb_set(d, '{lossDays}', coalesce(d->'lossDays', '{}'::jsonb) || jsonb_build_object(p_day, '{}'::jsonb)); end if;
    if q = 0 then
      d := jsonb_set(d, array['lossDays', p_day], (d->'lossDays'->p_day) - pid);
    else
      d := jsonb_set(d, array['lossDays', p_day, pid],
        jsonb_build_object('q', q, 'v', round(q * coalesce((prod->>'price')::numeric, 0), 2), 'by', eid));
    end if;
  else
    raise exception 'Action inconnue';
  end if;
  update public.company_data set data = d, updated_at = now(), updated_by = auth.uid() where company_id = cid;
  return public.employee_view(cid, p_day);
end $$;

do $$ declare f text; begin
  foreach f in array array['feature_on(uuid,jsonb,text)','daily_code_for(uuid,date)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
  end loop;
  foreach f in array array['is_platform_admin()','punch_code(uuid)','get_join_code(uuid)','admin_companies()','admin_set_feature(uuid,text,boolean)',
                           'join_preview(text)','join_company(text,text)','employee_view(uuid,text)','employee_action(uuid,text,jsonb,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;
