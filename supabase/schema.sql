-- MonKiosk : base de données Supabase
-- À coller une seule fois dans Supabase > SQL Editor > New query, puis "Run".

-- 1. Les commerces
create table if not exists public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 120),
  created_by uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- 2. Qui a accès à quel commerce
create table if not exists public.members (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'owner' check (role in ('owner','manager','employee')),
  created_at timestamptz not null default now(),
  primary key (company_id, user_id)
);

-- 3. Les données de chaque commerce (planning, équipe, stock, ventes...)
create table if not exists public.company_data (
  company_id uuid primary key references public.companies(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);

-- 4. Sécurité : chaque compte ne voit que les commerces dont il est membre
alter table public.companies enable row level security;
alter table public.members enable row level security;
alter table public.company_data enable row level security;

create or replace function public.is_member(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where company_id = cid and user_id = auth.uid());
$$;

drop policy if exists "companies_select" on public.companies;
create policy "companies_select" on public.companies for select to authenticated using (public.is_member(id));
drop policy if exists "companies_update" on public.companies;
create policy "companies_update" on public.companies for update to authenticated
  using (exists (select 1 from public.members m where m.company_id = id and m.user_id = auth.uid() and m.role = 'owner'));

drop policy if exists "members_select" on public.members;
create policy "members_select" on public.members for select to authenticated using (user_id = auth.uid() or public.is_member(company_id));

drop policy if exists "data_select" on public.company_data;
create policy "data_select" on public.company_data for select to authenticated using (public.is_member(company_id));
drop policy if exists "data_update" on public.company_data;
create policy "data_update" on public.company_data for update to authenticated
  using (public.is_member(company_id)) with check (public.is_member(company_id));

-- 5. Créer un commerce (le créateur en devient le patron)
create or replace function public.create_company(p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  insert into public.companies (name, created_by) values (trim(p_name), auth.uid()) returning id into cid;
  insert into public.members (company_id, user_id, role) values (cid, auth.uid(), 'owner');
  insert into public.company_data (company_id, data) values (cid, '{}'::jsonb);
  return cid;
end $$;
revoke all on function public.create_company(text) from public, anon;
grant execute on function public.create_company(text) to authenticated;

-- 6. Synchronisation en direct entre le PC, le téléphone et le site
do $$ begin
  alter publication supabase_realtime add table public.company_data;
exception when duplicate_object then null; end $$;


-- ===== Mise à jour 1.4 (incluse pour les nouvelles installations) =====
-- MonKiosk 1.4 : comptes salariés, pointage, plusieurs commerces.
-- À coller une fois dans Supabase > SQL Editor > New query, puis "Run". Sans risque si relancé.

-- Code d'accès de chaque commerce et lien compte <-> fiche salarié
alter table public.companies add column if not exists join_code text;
update public.companies set join_code = upper(substr(md5(random()::text || id::text), 1, 6)) where join_code is null;
alter table public.companies alter column join_code set default upper(substr(md5(random()::text), 1, 6));
create unique index if not exists companies_join_code_key on public.companies(join_code);
alter table public.members add column if not exists employee_id text;

-- Responsables (patron ou manager) : seuls à voir toutes les données
create or replace function public.is_staff(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where company_id = cid and user_id = auth.uid() and role in ('owner','manager'));
$$;

drop policy if exists "members_select" on public.members;
create policy "members_select" on public.members for select to authenticated using (user_id = auth.uid() or public.is_staff(company_id));
drop policy if exists "data_select" on public.company_data;
create policy "data_select" on public.company_data for select to authenticated using (public.is_staff(company_id));
drop policy if exists "data_update" on public.company_data;
create policy "data_update" on public.company_data for update to authenticated
  using (public.is_staff(company_id)) with check (public.is_staff(company_id));

-- Rejoindre un commerce avec son code
create or replace function public.join_preview(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c_id uuid; c_name text; d jsonb; emps jsonb;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select co.id, co.name, cd.data into c_id, c_name, d
    from public.companies co join public.company_data cd on cd.company_id = co.id
    where co.join_code = upper(trim(p_code));
  if c_id is null then raise exception 'Code invalide'; end if;
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
    from public.companies co join public.company_data cd on cd.company_id = co.id
    where co.join_code = upper(trim(p_code));
  if c_id is null then raise exception 'Code invalide'; end if;
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

create or replace function public.regenerate_join_code(cid uuid)
returns text language plpgsql security definer set search_path = public as $$
declare code text;
begin
  if not exists (select 1 from public.members where company_id = cid and user_id = auth.uid() and role = 'owner') then
    raise exception 'Réservé au patron du commerce'; end if;
  code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
  update public.companies set join_code = code where id = cid;
  return code;
end $$;

-- Gestion des comptes par le patron
create or replace function public.company_members(cid uuid)
returns table (user_id uuid, email text, role text, employee_id text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff(cid) then raise exception 'Réservé aux responsables'; end if;
  return query select m.user_id, u.email::text, m.role, m.employee_id
    from public.members m join auth.users u on u.id = m.user_id
    where m.company_id = cid order by m.created_at;
end $$;

create or replace function public.remove_member(cid uuid, uid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.members where company_id = cid and user_id = auth.uid() and role = 'owner') then
    raise exception 'Réservé au patron du commerce'; end if;
  if uid = auth.uid() then raise exception 'Tu ne peux pas retirer ton propre accès'; end if;
  delete from public.members where company_id = cid and user_id = uid and role <> 'owner';
end $$;

-- Espace salarié : uniquement ses propres informations
create or replace function public.employee_view(cid uuid, p_day text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare eid text; d jsonb; nm text; wk jsonb;
begin
  select m.employee_id into eid from public.members m where m.company_id = cid and m.user_id = auth.uid() and m.role = 'employee';
  if eid is null then raise exception 'Accès salarié introuvable'; end if;
  select cd.data, co.name into d, nm from public.company_data cd join public.companies co on co.id = cd.company_id where cd.company_id = cid;
  select coalesce(jsonb_object_agg(w.key, jsonb_build_object(eid, w.value->eid)), '{}'::jsonb) into wk
    from jsonb_each(coalesce(d->'weeks', '{}'::jsonb)) w
    where w.value ? eid and w.key >= to_char(current_date - 7, 'YYYY-MM-DD');
  return jsonb_build_object(
    'shop', coalesce(d->>'shop', nm),
    'employee', (select jsonb_build_object('id', e->>'id', 'name', e->>'name', 'poste', e->>'poste', 'contract', e->'contract')
                   from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = eid limit 1),
    'postes', coalesce(d->'postes', '[]'::jsonb),
    'weeks', wk,
    'leaves', (select coalesce(jsonb_agg(l), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'leaves', '[]'::jsonb)) l where l->>'emp' = eid),
    'notes', coalesce(d->'notes', '[]'::jsonb),
    'lists', coalesce(d->'lists', '[]'::jsonb),
    'done', coalesce(d->'done'->p_day, '{}'::jsonb),
    'equipments', coalesce(d->'equipments', '[]'::jsonb),
    'punches', (select coalesce(jsonb_agg(p), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'punches', '[]'::jsonb)) p
                  where p->>'emp' = eid and left(p->>'at', 10) >= to_char(current_date - 14, 'YYYY-MM-DD'))
  );
end $$;

create or replace function public.employee_action(cid uuid, p_action text, p_payload jsonb, p_day text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare eid text; d jsonb; nid text; nowiso text; v numeric;
begin
  select m.employee_id into eid from public.members m where m.company_id = cid and m.user_id = auth.uid() and m.role = 'employee';
  if eid is null then raise exception 'Accès salarié introuvable'; end if;
  select data into d from public.company_data where company_id = cid for update;
  nid := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
  nowiso := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  if p_action = 'punch' then
    if coalesce(p_payload->>'kind', '') not in ('in', 'out') then raise exception 'Pointage invalide'; end if;
    d := jsonb_set(d, '{punches}', coalesce(d->'punches', '[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('id', nid, 'emp', eid, 'kind', p_payload->>'kind', 'at', nowiso)));
  elsif p_action = 'leave' then
    if coalesce(p_payload->>'type', '') not in ('Congés payés', 'Maladie', 'Formation', 'Absence') then raise exception 'Motif invalide'; end if;
    if (p_payload->>'from') is null or (p_payload->>'to') is null or (p_payload->>'to') < (p_payload->>'from') then raise exception 'Dates invalides'; end if;
    d := jsonb_set(d, '{leaves}', coalesce(d->'leaves', '[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('id', nid, 'emp', eid, 'type', p_payload->>'type', 'from', p_payload->>'from', 'to', p_payload->>'to', 'status', 'attente')));
  elsif p_action = 'task' then
    if not (coalesce(d->'done', '{}'::jsonb) ? p_day) then
      d := jsonb_set(d, '{done}', coalesce(d->'done', '{}'::jsonb) || jsonb_build_object(p_day, '{}'::jsonb)); end if;
    d := jsonb_set(d, array['done', p_day, p_payload->>'task'], to_jsonb(coalesce((p_payload->>'done')::boolean, false)));
  elsif p_action = 'temp' then
    v := (p_payload->>'val')::numeric;
    d := jsonb_set(d, '{temps}', coalesce(d->'temps', '[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('id', nid, 'at', nowiso, 'equip', p_payload->>'equip', 'val', v, 'by', eid)));
  else
    raise exception 'Action inconnue';
  end if;
  update public.company_data set data = d, updated_at = now(), updated_by = auth.uid() where company_id = cid;
  return public.employee_view(cid, p_day);
end $$;

do $$ declare f text; begin
  foreach f in array array['join_preview(text)','join_company(text,text)','regenerate_join_code(uuid)','company_members(uuid)',
                           'remove_member(uuid,uuid)','employee_view(uuid,text)','employee_action(uuid,text,jsonb,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;


-- ===== Mise à jour 1.5 (incluse pour les nouvelles installations) =====
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
drop function if exists public.admin_companies();
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


-- ===== Mise à jour 1.6 (incluse pour les nouvelles installations) =====
-- MonKiosk 1.6 : espace salarié enrichi (collègues du jour, relevés du jour, stock modifiable par l'équipe).
-- À coller une fois dans Supabase > SQL Editor > New query, puis "Run". Sans risque si relancé.

create or replace function public.employee_view(cid uuid, p_day text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare eid text; d jsonb; nm text; wk jsonb; dd date; mk text; di text;
begin
  select m.employee_id into eid from public.members m where m.company_id = cid and m.user_id = auth.uid() and m.role = 'employee';
  if eid is null then raise exception 'Accès salarié introuvable'; end if;
  select cd.data, co.name into d, nm from public.company_data cd join public.companies co on co.id = cd.company_id where cd.company_id = cid;
  if not public.feature_on(cid, d, 'espace') then raise exception 'L''espace salarié n''est pas activé pour ce commerce'; end if;
  dd := coalesce(nullif(p_day, '')::date, (now() at time zone 'Europe/Paris')::date);
  mk := to_char(dd - (extract(isodow from dd)::int - 1), 'YYYY-MM-DD');
  di := (extract(isodow from dd)::int - 1)::text;
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
      'hygiene', public.feature_on(cid, d, 'hygiene'), 'pertes', public.feature_on(cid, d, 'pertes'),
      'stock', public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff')),
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
    'team_today', (select coalesce(jsonb_agg(jsonb_build_object('name', e->>'name', 's', d->'weeks'->mk->(e->>'id')->di->>'s',
                      'e', d->'weeks'->mk->(e->>'id')->di->>'e', 'p', d->'weeks'->mk->(e->>'id')->di->>'p')
                      order by d->'weeks'->mk->(e->>'id')->di->>'s'), '[]'::jsonb)
                    from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e
                    where (d->'weeks'->mk->(e->>'id')->di) is not null and e->>'id' <> eid),
    'temps_today', (select coalesce(jsonb_agg(jsonb_build_object('equip', t->>'equip', 'val', t->'val', 'at', t->>'at') order by t->>'at'), '[]'::jsonb)
                    from jsonb_array_elements(coalesce(d->'temps', '[]'::jsonb)) t where left(t->>'at', 10) >= to_char(dd - 1, 'YYYY-MM-DD')),
    'stock', case when public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff')
               then (select coalesce(jsonb_agg(jsonb_build_object('id', s->>'id', 'name', s->>'name', 'unit', s->>'unit', 'qty', s->'qty', 'min', s->'min', 'cat', s->>'cat')), '[]'::jsonb)
                     from jsonb_array_elements(coalesce(d->'stock', '[]'::jsonb)) s)
               else null end,
    'punches', (select coalesce(jsonb_agg(p), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'punches', '[]'::jsonb)) p
                  where p->>'emp' = eid and left(p->>'at', 10) >= to_char(current_date - 14, 'YYYY-MM-DD'))
  );
end $$;

create or replace function public.employee_action(cid uuid, p_action text, p_payload jsonb, p_day text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare eid text; d jsonb; nid text; nowiso text; v numeric; q numeric; prod jsonb; pid text; item jsonb;
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
  elsif p_action = 'stock' then
    if not (public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff')) then raise exception 'Le stock n''est pas ouvert à l''équipe'; end if;
    select s into item from jsonb_array_elements(coalesce(d->'stock', '[]'::jsonb)) s where s->>'id' = p_payload->>'item' limit 1;
    if item is null then raise exception 'Article introuvable'; end if;
    q := greatest(0, round(coalesce((item->>'qty')::numeric, 0) + coalesce((p_payload->>'delta')::numeric, 0), 2));
    d := jsonb_set(d, '{stock}', (select jsonb_agg(case when s->>'id' = p_payload->>'item' then jsonb_set(s, '{qty}', to_jsonb(q)) else s end)
                                  from jsonb_array_elements(d->'stock') s));
  else
    raise exception 'Action inconnue';
  end if;
  update public.company_data set data = d, updated_at = now(), updated_by = auth.uid() where company_id = cid;
  return public.employee_view(cid, p_day);
end $$;

do $$ declare f text; begin
  foreach f in array array['employee_view(uuid,text)','employee_action(uuid,text,jsonb,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;


-- ===== Mise à jour 1.7 (incluse pour les nouvelles installations) =====
-- MonKiosk 1.7 : disponibilités, signalements, lecture des annonces, annulation des demandes de congé.
-- À coller une fois dans Supabase > SQL Editor > New query, puis "Run". Sans risque si relancé.

create or replace function public.employee_view(cid uuid, p_day text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare eid text; d jsonb; nm text; wk jsonb; dd date; mk text; di text;
begin
  select m.employee_id into eid from public.members m where m.company_id = cid and m.user_id = auth.uid() and m.role = 'employee';
  if eid is null then raise exception 'Accès salarié introuvable'; end if;
  select cd.data, co.name into d, nm from public.company_data cd join public.companies co on co.id = cd.company_id where cd.company_id = cid;
  if not public.feature_on(cid, d, 'espace') then raise exception 'L''espace salarié n''est pas activé pour ce commerce'; end if;
  dd := coalesce(nullif(p_day, '')::date, (now() at time zone 'Europe/Paris')::date);
  mk := to_char(dd - (extract(isodow from dd)::int - 1), 'YYYY-MM-DD');
  di := (extract(isodow from dd)::int - 1)::text;
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
      'hygiene', public.feature_on(cid, d, 'hygiene'), 'pertes', public.feature_on(cid, d, 'pertes'),
      'stock', public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff'),
      'dispos', public.feature_on(cid, d, 'dispos'), 'signalements', public.feature_on(cid, d, 'signalements')),
    'availability', coalesce(d->'availability'->eid, '{}'::jsonb),
    'reports', (select coalesce(jsonb_agg(r order by r->>'at' desc), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'reports', '[]'::jsonb)) r
                  where r->>'emp' = eid and left(r->>'at', 10) >= to_char(dd - 30, 'YYYY-MM-DD')),
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
    'team_today', (select coalesce(jsonb_agg(jsonb_build_object('name', e->>'name', 's', d->'weeks'->mk->(e->>'id')->di->>'s',
                      'e', d->'weeks'->mk->(e->>'id')->di->>'e', 'p', d->'weeks'->mk->(e->>'id')->di->>'p')
                      order by d->'weeks'->mk->(e->>'id')->di->>'s'), '[]'::jsonb)
                    from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e
                    where (d->'weeks'->mk->(e->>'id')->di) is not null and e->>'id' <> eid),
    'temps_today', (select coalesce(jsonb_agg(jsonb_build_object('equip', t->>'equip', 'val', t->'val', 'at', t->>'at') order by t->>'at'), '[]'::jsonb)
                    from jsonb_array_elements(coalesce(d->'temps', '[]'::jsonb)) t where left(t->>'at', 10) >= to_char(dd - 1, 'YYYY-MM-DD')),
    'stock', case when public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff')
               then (select coalesce(jsonb_agg(jsonb_build_object('id', s->>'id', 'name', s->>'name', 'unit', s->>'unit', 'qty', s->'qty', 'min', s->'min', 'cat', s->>'cat')), '[]'::jsonb)
                     from jsonb_array_elements(coalesce(d->'stock', '[]'::jsonb)) s)
               else null end,
    'punches', (select coalesce(jsonb_agg(p), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'punches', '[]'::jsonb)) p
                  where p->>'emp' = eid and left(p->>'at', 10) >= to_char(current_date - 14, 'YYYY-MM-DD'))
  );
end $$;

create or replace function public.employee_action(cid uuid, p_action text, p_payload jsonb, p_day text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare eid text; d jsonb; nid text; nowiso text; v numeric; q numeric; prod jsonb; pid text; item jsonb; dk text; txt text;
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
  elsif p_action = 'stock' then
    if not (public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff')) then raise exception 'Le stock n''est pas ouvert à l''équipe'; end if;
    select s into item from jsonb_array_elements(coalesce(d->'stock', '[]'::jsonb)) s where s->>'id' = p_payload->>'item' limit 1;
    if item is null then raise exception 'Article introuvable'; end if;
    q := greatest(0, round(coalesce((item->>'qty')::numeric, 0) + coalesce((p_payload->>'delta')::numeric, 0), 2));
    d := jsonb_set(d, '{stock}', (select jsonb_agg(case when s->>'id' = p_payload->>'item' then jsonb_set(s, '{qty}', to_jsonb(q)) else s end)
                                  from jsonb_array_elements(d->'stock') s));
  elsif p_action = 'avail' then
    if not public.feature_on(cid, d, 'dispos') then raise exception 'Les disponibilités ne sont pas activées'; end if;
    dk := p_payload->>'day';
    if dk is null or dk not in ('0','1','2','3','4','5','6') then raise exception 'Jour invalide'; end if;
    if not (coalesce(d->'availability', '{}'::jsonb) ? eid) then
      d := jsonb_set(d, '{availability}', coalesce(d->'availability', '{}'::jsonb) || jsonb_build_object(eid, '{}'::jsonb)); end if;
    if coalesce((p_payload->>'off')::boolean, false) then
      d := jsonb_set(d, array['availability', eid, dk], jsonb_build_object('off', true, 'note', left(coalesce(p_payload->>'note', ''), 80)));
    else
      d := jsonb_set(d, array['availability', eid], (d->'availability'->eid) - dk);
    end if;
  elsif p_action = 'report' then
    if not public.feature_on(cid, d, 'signalements') then raise exception 'Les signalements ne sont pas activés'; end if;
    txt := trim(coalesce(p_payload->>'text', ''));
    if length(txt) < 2 or length(txt) > 500 then raise exception 'Décris le problème en quelques mots'; end if;
    d := jsonb_set(d, '{reports}', coalesce(d->'reports', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('id', nid, 'emp', eid, 'at', nowiso,
      'kind', case when p_payload->>'kind' in ('Matériel','Hygiène','Stock','Sécurité','Autre') then p_payload->>'kind' else 'Autre' end, 'text', txt, 'status', 'ouvert')));
  elsif p_action = 'read' then
    d := jsonb_set(d, '{notes}', (select coalesce(jsonb_agg(case when n->>'id' = p_payload->>'note' and not (coalesce(n->'read', '[]'::jsonb) ? eid)
                                   then jsonb_set(n, '{read}', coalesce(n->'read', '[]'::jsonb) || to_jsonb(eid)) else n end), '[]'::jsonb)
                                  from jsonb_array_elements(coalesce(d->'notes', '[]'::jsonb)) n));
  elsif p_action = 'leave_cancel' then
    d := jsonb_set(d, '{leaves}', (select coalesce(jsonb_agg(l), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'leaves', '[]'::jsonb)) l
                                   where not (l->>'id' = p_payload->>'id' and l->>'emp' = eid and l->>'status' = 'attente')));
  else
    raise exception 'Action inconnue';
  end if;
  update public.company_data set data = d, updated_at = now(), updated_by = auth.uid() where company_id = cid;
  return public.employee_view(cid, p_day);
end $$;

do $$ declare f text; begin
  foreach f in array array['employee_view(uuid,text)','employee_action(uuid,text,jsonb,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;


-- ===== Mise à jour 1.8 (incluse pour les nouvelles installations) =====
-- MonKiosk 1.8 : calendrier mensuel salarié, échanges de créneaux entre collègues, téléphone du salarié.
-- À coller une fois dans Supabase > SQL Editor > New query, puis "Run". Sans risque si relancé.

create or replace function public.employee_view(cid uuid, p_day text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare eid text; d jsonb; nm text; wk jsonb; dd date; mk text; di text;
begin
  select m.employee_id into eid from public.members m where m.company_id = cid and m.user_id = auth.uid() and m.role = 'employee';
  if eid is null then raise exception 'Accès salarié introuvable'; end if;
  select cd.data, co.name into d, nm from public.company_data cd join public.companies co on co.id = cd.company_id where cd.company_id = cid;
  if not public.feature_on(cid, d, 'espace') then raise exception 'L''espace salarié n''est pas activé pour ce commerce'; end if;
  dd := coalesce(nullif(p_day, '')::date, (now() at time zone 'Europe/Paris')::date);
  mk := to_char(dd - (extract(isodow from dd)::int - 1), 'YYYY-MM-DD');
  di := (extract(isodow from dd)::int - 1)::text;
  select coalesce(jsonb_object_agg(w.key, jsonb_build_object(eid, w.value->eid)), '{}'::jsonb) into wk
    from jsonb_each(coalesce(d->'weeks', '{}'::jsonb)) w
    where w.value ? eid and w.key >= to_char(date_trunc('month', dd) - interval '62 days', 'YYYY-MM-DD');
  return jsonb_build_object(
    'shop', coalesce(d->>'shop', nm),
    'employee', (select jsonb_build_object('id', e->>'id', 'name', e->>'name', 'poste', e->>'poste', 'contract', e->'contract', 'phone', e->>'phone')
                   from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = eid limit 1),
    'features', jsonb_build_object(
      'badgeuse', public.feature_on(cid, d, 'badgeuse'), 'conges', public.feature_on(cid, d, 'conges'),
      'annonces', public.feature_on(cid, d, 'annonces'), 'taches', public.feature_on(cid, d, 'taches'),
      'hygiene', public.feature_on(cid, d, 'hygiene'), 'pertes', public.feature_on(cid, d, 'pertes'),
      'stock', public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff'),
      'dispos', public.feature_on(cid, d, 'dispos'), 'signalements', public.feature_on(cid, d, 'signalements'),
      'echanges', public.feature_on(cid, d, 'echanges')),
    'swaps', (select coalesce(jsonb_agg(x || jsonb_build_object(
                  'name', (select e->>'name' from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = x->>'emp' limit 1),
                  'vname', (select e->>'name' from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = x->>'volunteer' limit 1))
                  order by x->>'date'), '[]'::jsonb)
              from jsonb_array_elements(coalesce(d->'swaps', '[]'::jsonb)) x
              where x->>'date' >= to_char(dd - 1, 'YYYY-MM-DD') and (x->>'emp' = eid or x->>'volunteer' = eid or x->>'status' = 'ouvert')),
    'availability', coalesce(d->'availability'->eid, '{}'::jsonb),
    'reports', (select coalesce(jsonb_agg(r order by r->>'at' desc), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'reports', '[]'::jsonb)) r
                  where r->>'emp' = eid and left(r->>'at', 10) >= to_char(dd - 30, 'YYYY-MM-DD')),
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
    'team_today', (select coalesce(jsonb_agg(jsonb_build_object('name', e->>'name', 's', d->'weeks'->mk->(e->>'id')->di->>'s',
                      'e', d->'weeks'->mk->(e->>'id')->di->>'e', 'p', d->'weeks'->mk->(e->>'id')->di->>'p')
                      order by d->'weeks'->mk->(e->>'id')->di->>'s'), '[]'::jsonb)
                    from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e
                    where (d->'weeks'->mk->(e->>'id')->di) is not null and e->>'id' <> eid),
    'temps_today', (select coalesce(jsonb_agg(jsonb_build_object('equip', t->>'equip', 'val', t->'val', 'at', t->>'at') order by t->>'at'), '[]'::jsonb)
                    from jsonb_array_elements(coalesce(d->'temps', '[]'::jsonb)) t where left(t->>'at', 10) >= to_char(dd - 1, 'YYYY-MM-DD')),
    'stock', case when public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff')
               then (select coalesce(jsonb_agg(jsonb_build_object('id', s->>'id', 'name', s->>'name', 'unit', s->>'unit', 'qty', s->'qty', 'min', s->'min', 'cat', s->>'cat')), '[]'::jsonb)
                     from jsonb_array_elements(coalesce(d->'stock', '[]'::jsonb)) s)
               else null end,
    'punches', (select coalesce(jsonb_agg(p), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'punches', '[]'::jsonb)) p
                  where p->>'emp' = eid and left(p->>'at', 10) >= to_char(current_date - 14, 'YYYY-MM-DD'))
  );
end $$;

create or replace function public.employee_action(cid uuid, p_action text, p_payload jsonb, p_day text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare eid text; d jsonb; nid text; nowiso text; v numeric; q numeric; prod jsonb; pid text; item jsonb; dk text; txt text; sd date; smk text; sdi text; sh jsonb; sw jsonb;
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
  elsif p_action = 'stock' then
    if not (public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff')) then raise exception 'Le stock n''est pas ouvert à l''équipe'; end if;
    select s into item from jsonb_array_elements(coalesce(d->'stock', '[]'::jsonb)) s where s->>'id' = p_payload->>'item' limit 1;
    if item is null then raise exception 'Article introuvable'; end if;
    q := greatest(0, round(coalesce((item->>'qty')::numeric, 0) + coalesce((p_payload->>'delta')::numeric, 0), 2));
    d := jsonb_set(d, '{stock}', (select jsonb_agg(case when s->>'id' = p_payload->>'item' then jsonb_set(s, '{qty}', to_jsonb(q)) else s end)
                                  from jsonb_array_elements(d->'stock') s));
  elsif p_action = 'avail' then
    if not public.feature_on(cid, d, 'dispos') then raise exception 'Les disponibilités ne sont pas activées'; end if;
    dk := p_payload->>'day';
    if dk is null or dk not in ('0','1','2','3','4','5','6') then raise exception 'Jour invalide'; end if;
    if not (coalesce(d->'availability', '{}'::jsonb) ? eid) then
      d := jsonb_set(d, '{availability}', coalesce(d->'availability', '{}'::jsonb) || jsonb_build_object(eid, '{}'::jsonb)); end if;
    if coalesce((p_payload->>'off')::boolean, false) then
      d := jsonb_set(d, array['availability', eid, dk], jsonb_build_object('off', true, 'note', left(coalesce(p_payload->>'note', ''), 80)));
    else
      d := jsonb_set(d, array['availability', eid], (d->'availability'->eid) - dk);
    end if;
  elsif p_action = 'report' then
    if not public.feature_on(cid, d, 'signalements') then raise exception 'Les signalements ne sont pas activés'; end if;
    txt := trim(coalesce(p_payload->>'text', ''));
    if length(txt) < 2 or length(txt) > 500 then raise exception 'Décris le problème en quelques mots'; end if;
    d := jsonb_set(d, '{reports}', coalesce(d->'reports', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('id', nid, 'emp', eid, 'at', nowiso,
      'kind', case when p_payload->>'kind' in ('Matériel','Hygiène','Stock','Sécurité','Autre') then p_payload->>'kind' else 'Autre' end, 'text', txt, 'status', 'ouvert')));
  elsif p_action = 'read' then
    d := jsonb_set(d, '{notes}', (select coalesce(jsonb_agg(case when n->>'id' = p_payload->>'note' and not (coalesce(n->'read', '[]'::jsonb) ? eid)
                                   then jsonb_set(n, '{read}', coalesce(n->'read', '[]'::jsonb) || to_jsonb(eid)) else n end), '[]'::jsonb)
                                  from jsonb_array_elements(coalesce(d->'notes', '[]'::jsonb)) n));
  elsif p_action = 'leave_cancel' then
    d := jsonb_set(d, '{leaves}', (select coalesce(jsonb_agg(l), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'leaves', '[]'::jsonb)) l
                                   where not (l->>'id' = p_payload->>'id' and l->>'emp' = eid and l->>'status' = 'attente')));
  elsif p_action in ('swap_request', 'swap_volunteer', 'swap_cancel') then
    if not public.feature_on(cid, d, 'echanges') then raise exception 'Les échanges de créneaux ne sont pas activés'; end if;
    if p_action = 'swap_request' then
      sd := (p_payload->>'date')::date;
      if sd < (now() at time zone 'Europe/Paris')::date then raise exception 'Ce jour est déjà passé'; end if;
      smk := to_char(sd - (extract(isodow from sd)::int - 1), 'YYYY-MM-DD'); sdi := (extract(isodow from sd)::int - 1)::text;
      sh := d->'weeks'->smk->eid->sdi;
      if sh is null then raise exception 'Tu ne travailles pas ce jour-là'; end if;
      if exists (select 1 from jsonb_array_elements(coalesce(d->'swaps', '[]'::jsonb)) x where x->>'emp' = eid and x->>'date' = sd::text and x->>'status' in ('ouvert','proposé')) then
        raise exception 'Une demande existe déjà pour ce jour'; end if;
      d := jsonb_set(d, '{swaps}', coalesce(d->'swaps', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('id', nid, 'emp', eid, 'date', sd::text,
        's', sh->>'s', 'e', sh->>'e', 'p', sh->>'p', 'note', left(coalesce(p_payload->>'note', ''), 120), 'status', 'ouvert', 'volunteer', null, 'at', nowiso)));
    else
      select x into sw from jsonb_array_elements(coalesce(d->'swaps', '[]'::jsonb)) x where x->>'id' = p_payload->>'id' limit 1;
      if sw is null then raise exception 'Échange introuvable'; end if;
      if p_action = 'swap_volunteer' then
        if sw->>'emp' = eid or sw->>'status' <> 'ouvert' then raise exception 'Cet échange n''est plus disponible'; end if;
        sd := (sw->>'date')::date; smk := to_char(sd - (extract(isodow from sd)::int - 1), 'YYYY-MM-DD'); sdi := (extract(isodow from sd)::int - 1)::text;
        if (d->'weeks'->smk->eid->sdi) is not null then raise exception 'Tu travailles déjà ce jour-là'; end if;
        sw := sw || jsonb_build_object('volunteer', eid, 'status', 'proposé');
      elsif sw->>'emp' = eid and sw->>'status' in ('ouvert','proposé') then
        sw := null;
      elsif sw->>'volunteer' = eid and sw->>'status' = 'proposé' then
        sw := sw || jsonb_build_object('volunteer', null, 'status', 'ouvert');
      else
        raise exception 'Tu ne peux pas annuler cet échange';
      end if;
      d := jsonb_set(d, '{swaps}', (select coalesce(jsonb_agg(case when x->>'id' = p_payload->>'id' then sw else x end) filter (where x->>'id' <> p_payload->>'id' or sw is not null), '[]'::jsonb)
                                   from jsonb_array_elements(coalesce(d->'swaps', '[]'::jsonb)) x));
    end if;
  elsif p_action = 'profile' then
    d := jsonb_set(d, '{employees}', (select coalesce(jsonb_agg(case when e->>'id' = eid then e || jsonb_build_object('phone', left(trim(coalesce(p_payload->>'phone', '')), 20)) else e end), '[]'::jsonb)
                                      from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e));
  else
    raise exception 'Action inconnue';
  end if;
  update public.company_data set data = d, updated_at = now(), updated_by = auth.uid() where company_id = cid;
  return public.employee_view(cid, p_day);
end $$;

do $$ declare f text; begin
  foreach f in array array['employee_view(uuid,text)','employee_action(uuid,text,jsonb,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;


-- ===== Mise à jour 1.9 (incluse pour les nouvelles installations) =====
-- MonKiosk 1.9 : sécurité des comptes salariés.
--  * L'accès d'un salarié est coupé dès que sa fiche est supprimée de l'équipe.
--  * Pour rejoindre un commerce, il faut le code ET l'adresse e-mail du responsable.
--  * Une fiche peut être réservée à l'adresse e-mail du salarié.
-- À coller une fois dans Supabase > SQL Editor > New query, puis "Run". Sans risque si relancé.

-- Les anciennes fonctions (code seul) sont supprimées
drop function if exists public.join_preview(text);
drop function if exists public.join_company(text, text);

create or replace function public.join_check(p_code text, p_owner_email text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare c_id uuid;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  select co.id into c_id from public.companies co where co.join_code = upper(trim(coalesce(p_code, '')));
  if c_id is null or not exists (
    select 1 from public.members m join auth.users u on u.id = m.user_id
    where m.company_id = c_id and m.role = 'owner' and lower(u.email) = lower(trim(coalesce(p_owner_email, '')))) then
    raise exception 'Code ou e-mail du responsable incorrect';
  end if;
  return c_id;
end $$;

create or replace function public.join_preview(p_code text, p_owner_email text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c_id uuid; c_name text; d jsonb; emps jsonb; me text;
begin
  c_id := public.join_check(p_code, p_owner_email);
  select co.name, cd.data into c_name, d from public.companies co join public.company_data cd on cd.company_id = co.id where co.id = c_id;
  if not public.feature_on(c_id, d, 'espace') then raise exception 'L''espace salarié n''est pas activé pour ce commerce'; end if;
  select lower(email) into me from auth.users where id = auth.uid();
  select coalesce(jsonb_agg(jsonb_build_object('id', e->>'id', 'name', e->>'name') order by e->>'name'), '[]'::jsonb) into emps
    from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e
    where coalesce(nullif(trim(e->>'email'), ''), me) = me
      and not exists (select 1 from public.members m where m.company_id = c_id and m.employee_id = e->>'id' and m.user_id <> auth.uid());
  return jsonb_build_object('company', c_name, 'employees', emps);
end $$;

create or replace function public.join_company(p_code text, p_employee text, p_owner_email text)
returns uuid language plpgsql security definer set search_path = public as $$
declare c_id uuid; d jsonb; emp jsonb; me text;
begin
  c_id := public.join_check(p_code, p_owner_email);
  select cd.data into d from public.company_data cd where cd.company_id = c_id;
  if not public.feature_on(c_id, d, 'espace') then raise exception 'L''espace salarié n''est pas activé pour ce commerce'; end if;
  select e into emp from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = p_employee limit 1;
  if emp is null then raise exception 'Salarié introuvable'; end if;
  select lower(email) into me from auth.users where id = auth.uid();
  if nullif(trim(emp->>'email'), '') is not null and lower(trim(emp->>'email')) <> me then
    raise exception 'Cette fiche est réservée à une autre adresse e-mail'; end if;
  if exists (select 1 from public.members where company_id = c_id and employee_id = p_employee and user_id <> auth.uid()) then
    raise exception 'Ce salarié a déjà un compte'; end if;
  if exists (select 1 from public.members where company_id = c_id and user_id = auth.uid() and role <> 'employee') then
    raise exception 'Tu es déjà responsable de ce commerce'; end if;
  insert into public.members (company_id, user_id, role, employee_id) values (c_id, auth.uid(), 'employee', p_employee)
    on conflict (company_id, user_id) do update set employee_id = excluded.employee_id;
  return c_id;
end $$;

create or replace function public.employee_view(cid uuid, p_day text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare eid text; d jsonb; nm text; wk jsonb; dd date; mk text; di text;
begin
  select m.employee_id into eid from public.members m where m.company_id = cid and m.user_id = auth.uid() and m.role = 'employee';
  if eid is null then raise exception 'Accès salarié introuvable'; end if;
  select cd.data, co.name into d, nm from public.company_data cd join public.companies co on co.id = cd.company_id where cd.company_id = cid;
  if not exists (select 1 from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = eid) then
    delete from public.members where company_id = cid and user_id = auth.uid() and role = 'employee';
    return jsonb_build_object('removed', true);
  end if;
  if not public.feature_on(cid, d, 'espace') then raise exception 'L''espace salarié n''est pas activé pour ce commerce'; end if;
  dd := coalesce(nullif(p_day, '')::date, (now() at time zone 'Europe/Paris')::date);
  mk := to_char(dd - (extract(isodow from dd)::int - 1), 'YYYY-MM-DD');
  di := (extract(isodow from dd)::int - 1)::text;
  select coalesce(jsonb_object_agg(w.key, jsonb_build_object(eid, w.value->eid)), '{}'::jsonb) into wk
    from jsonb_each(coalesce(d->'weeks', '{}'::jsonb)) w
    where w.value ? eid and w.key >= to_char(date_trunc('month', dd) - interval '62 days', 'YYYY-MM-DD');
  return jsonb_build_object(
    'shop', coalesce(d->>'shop', nm),
    'employee', (select jsonb_build_object('id', e->>'id', 'name', e->>'name', 'poste', e->>'poste', 'contract', e->'contract', 'phone', e->>'phone')
                   from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = eid limit 1),
    'features', jsonb_build_object(
      'badgeuse', public.feature_on(cid, d, 'badgeuse'), 'conges', public.feature_on(cid, d, 'conges'),
      'annonces', public.feature_on(cid, d, 'annonces'), 'taches', public.feature_on(cid, d, 'taches'),
      'hygiene', public.feature_on(cid, d, 'hygiene'), 'pertes', public.feature_on(cid, d, 'pertes'),
      'stock', public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff'),
      'dispos', public.feature_on(cid, d, 'dispos'), 'signalements', public.feature_on(cid, d, 'signalements'),
      'echanges', public.feature_on(cid, d, 'echanges')),
    'swaps', (select coalesce(jsonb_agg(x || jsonb_build_object(
                  'name', (select e->>'name' from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = x->>'emp' limit 1),
                  'vname', (select e->>'name' from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = x->>'volunteer' limit 1))
                  order by x->>'date'), '[]'::jsonb)
              from jsonb_array_elements(coalesce(d->'swaps', '[]'::jsonb)) x
              where x->>'date' >= to_char(dd - 1, 'YYYY-MM-DD') and (x->>'emp' = eid or x->>'volunteer' = eid or x->>'status' = 'ouvert')),
    'availability', coalesce(d->'availability'->eid, '{}'::jsonb),
    'reports', (select coalesce(jsonb_agg(r order by r->>'at' desc), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'reports', '[]'::jsonb)) r
                  where r->>'emp' = eid and left(r->>'at', 10) >= to_char(dd - 30, 'YYYY-MM-DD')),
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
    'team_today', (select coalesce(jsonb_agg(jsonb_build_object('name', e->>'name', 's', d->'weeks'->mk->(e->>'id')->di->>'s',
                      'e', d->'weeks'->mk->(e->>'id')->di->>'e', 'p', d->'weeks'->mk->(e->>'id')->di->>'p')
                      order by d->'weeks'->mk->(e->>'id')->di->>'s'), '[]'::jsonb)
                    from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e
                    where (d->'weeks'->mk->(e->>'id')->di) is not null and e->>'id' <> eid),
    'temps_today', (select coalesce(jsonb_agg(jsonb_build_object('equip', t->>'equip', 'val', t->'val', 'at', t->>'at') order by t->>'at'), '[]'::jsonb)
                    from jsonb_array_elements(coalesce(d->'temps', '[]'::jsonb)) t where left(t->>'at', 10) >= to_char(dd - 1, 'YYYY-MM-DD')),
    'stock', case when public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff')
               then (select coalesce(jsonb_agg(jsonb_build_object('id', s->>'id', 'name', s->>'name', 'unit', s->>'unit', 'qty', s->'qty', 'min', s->'min', 'cat', s->>'cat')), '[]'::jsonb)
                     from jsonb_array_elements(coalesce(d->'stock', '[]'::jsonb)) s)
               else null end,
    'punches', (select coalesce(jsonb_agg(p), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'punches', '[]'::jsonb)) p
                  where p->>'emp' = eid and left(p->>'at', 10) >= to_char(current_date - 14, 'YYYY-MM-DD'))
  );
end $$;

create or replace function public.employee_action(cid uuid, p_action text, p_payload jsonb, p_day text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare eid text; d jsonb; nid text; nowiso text; v numeric; q numeric; prod jsonb; pid text; item jsonb; dk text; txt text; sd date; smk text; sdi text; sh jsonb; sw jsonb;
begin
  select m.employee_id into eid from public.members m where m.company_id = cid and m.user_id = auth.uid() and m.role = 'employee';
  if eid is null then raise exception 'Accès salarié introuvable'; end if;
  select data into d from public.company_data where company_id = cid for update;
  if not exists (select 1 from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = eid) then
    delete from public.members where company_id = cid and user_id = auth.uid() and role = 'employee';
    return jsonb_build_object('removed', true);
  end if;
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
  elsif p_action = 'stock' then
    if not (public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff')) then raise exception 'Le stock n''est pas ouvert à l''équipe'; end if;
    select s into item from jsonb_array_elements(coalesce(d->'stock', '[]'::jsonb)) s where s->>'id' = p_payload->>'item' limit 1;
    if item is null then raise exception 'Article introuvable'; end if;
    q := greatest(0, round(coalesce((item->>'qty')::numeric, 0) + coalesce((p_payload->>'delta')::numeric, 0), 2));
    d := jsonb_set(d, '{stock}', (select jsonb_agg(case when s->>'id' = p_payload->>'item' then jsonb_set(s, '{qty}', to_jsonb(q)) else s end)
                                  from jsonb_array_elements(d->'stock') s));
  elsif p_action = 'avail' then
    if not public.feature_on(cid, d, 'dispos') then raise exception 'Les disponibilités ne sont pas activées'; end if;
    dk := p_payload->>'day';
    if dk is null or dk not in ('0','1','2','3','4','5','6') then raise exception 'Jour invalide'; end if;
    if not (coalesce(d->'availability', '{}'::jsonb) ? eid) then
      d := jsonb_set(d, '{availability}', coalesce(d->'availability', '{}'::jsonb) || jsonb_build_object(eid, '{}'::jsonb)); end if;
    if coalesce((p_payload->>'off')::boolean, false) then
      d := jsonb_set(d, array['availability', eid, dk], jsonb_build_object('off', true, 'note', left(coalesce(p_payload->>'note', ''), 80)));
    else
      d := jsonb_set(d, array['availability', eid], (d->'availability'->eid) - dk);
    end if;
  elsif p_action = 'report' then
    if not public.feature_on(cid, d, 'signalements') then raise exception 'Les signalements ne sont pas activés'; end if;
    txt := trim(coalesce(p_payload->>'text', ''));
    if length(txt) < 2 or length(txt) > 500 then raise exception 'Décris le problème en quelques mots'; end if;
    d := jsonb_set(d, '{reports}', coalesce(d->'reports', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('id', nid, 'emp', eid, 'at', nowiso,
      'kind', case when p_payload->>'kind' in ('Matériel','Hygiène','Stock','Sécurité','Autre') then p_payload->>'kind' else 'Autre' end, 'text', txt, 'status', 'ouvert')));
  elsif p_action = 'read' then
    d := jsonb_set(d, '{notes}', (select coalesce(jsonb_agg(case when n->>'id' = p_payload->>'note' and not (coalesce(n->'read', '[]'::jsonb) ? eid)
                                   then jsonb_set(n, '{read}', coalesce(n->'read', '[]'::jsonb) || to_jsonb(eid)) else n end), '[]'::jsonb)
                                  from jsonb_array_elements(coalesce(d->'notes', '[]'::jsonb)) n));
  elsif p_action = 'leave_cancel' then
    d := jsonb_set(d, '{leaves}', (select coalesce(jsonb_agg(l), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'leaves', '[]'::jsonb)) l
                                   where not (l->>'id' = p_payload->>'id' and l->>'emp' = eid and l->>'status' = 'attente')));
  elsif p_action in ('swap_request', 'swap_volunteer', 'swap_cancel') then
    if not public.feature_on(cid, d, 'echanges') then raise exception 'Les échanges de créneaux ne sont pas activés'; end if;
    if p_action = 'swap_request' then
      sd := (p_payload->>'date')::date;
      if sd < (now() at time zone 'Europe/Paris')::date then raise exception 'Ce jour est déjà passé'; end if;
      smk := to_char(sd - (extract(isodow from sd)::int - 1), 'YYYY-MM-DD'); sdi := (extract(isodow from sd)::int - 1)::text;
      sh := d->'weeks'->smk->eid->sdi;
      if sh is null then raise exception 'Tu ne travailles pas ce jour-là'; end if;
      if exists (select 1 from jsonb_array_elements(coalesce(d->'swaps', '[]'::jsonb)) x where x->>'emp' = eid and x->>'date' = sd::text and x->>'status' in ('ouvert','proposé')) then
        raise exception 'Une demande existe déjà pour ce jour'; end if;
      d := jsonb_set(d, '{swaps}', coalesce(d->'swaps', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('id', nid, 'emp', eid, 'date', sd::text,
        's', sh->>'s', 'e', sh->>'e', 'p', sh->>'p', 'note', left(coalesce(p_payload->>'note', ''), 120), 'status', 'ouvert', 'volunteer', null, 'at', nowiso)));
    else
      select x into sw from jsonb_array_elements(coalesce(d->'swaps', '[]'::jsonb)) x where x->>'id' = p_payload->>'id' limit 1;
      if sw is null then raise exception 'Échange introuvable'; end if;
      if p_action = 'swap_volunteer' then
        if sw->>'emp' = eid or sw->>'status' <> 'ouvert' then raise exception 'Cet échange n''est plus disponible'; end if;
        sd := (sw->>'date')::date; smk := to_char(sd - (extract(isodow from sd)::int - 1), 'YYYY-MM-DD'); sdi := (extract(isodow from sd)::int - 1)::text;
        if (d->'weeks'->smk->eid->sdi) is not null then raise exception 'Tu travailles déjà ce jour-là'; end if;
        sw := sw || jsonb_build_object('volunteer', eid, 'status', 'proposé');
      elsif sw->>'emp' = eid and sw->>'status' in ('ouvert','proposé') then
        sw := null;
      elsif sw->>'volunteer' = eid and sw->>'status' = 'proposé' then
        sw := sw || jsonb_build_object('volunteer', null, 'status', 'ouvert');
      else
        raise exception 'Tu ne peux pas annuler cet échange';
      end if;
      d := jsonb_set(d, '{swaps}', (select coalesce(jsonb_agg(case when x->>'id' = p_payload->>'id' then sw else x end) filter (where x->>'id' <> p_payload->>'id' or sw is not null), '[]'::jsonb)
                                   from jsonb_array_elements(coalesce(d->'swaps', '[]'::jsonb)) x));
    end if;
  elsif p_action = 'profile' then
    d := jsonb_set(d, '{employees}', (select coalesce(jsonb_agg(case when e->>'id' = eid then e || jsonb_build_object('phone', left(trim(coalesce(p_payload->>'phone', '')), 20)) else e end), '[]'::jsonb)
                                      from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e));
  else
    raise exception 'Action inconnue';
  end if;
  update public.company_data set data = d, updated_at = now(), updated_by = auth.uid() where company_id = cid;
  return public.employee_view(cid, p_day);
end $$;

do $$ declare f text; begin
  revoke all on function public.join_check(text,text) from public, anon, authenticated;
  foreach f in array array['join_preview(text,text)','join_company(text,text,text)','employee_view(uuid,text)','employee_action(uuid,text,jsonb,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;


-- ===== Mise à jour 2.0 (incluse pour les nouvelles installations) =====
-- MonKiosk 2.0 : rôle manager, pauses, disponibilités ponctuelles, messagerie d'équipe, langue du salarié, historique.
-- À coller une fois dans Supabase > SQL Editor > New query, puis "Run". Sans risque si relancé.

-- Le patron peut nommer un salarié manager (gestion du planning et du stock)
create or replace function public.set_member_role(cid uuid, uid uuid, new_role text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.members where company_id = cid and user_id = auth.uid() and role = 'owner') then
    raise exception 'Réservé au patron du commerce'; end if;
  if new_role not in ('employee', 'manager') then raise exception 'Rôle invalide'; end if;
  update public.members set role = new_role where company_id = cid and user_id = uid and role in ('employee', 'manager');
end $$;

create or replace function public.employee_view(cid uuid, p_day text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare eid text; d jsonb; nm text; wk jsonb; dd date; mk text; di text;
begin
  select m.employee_id into eid from public.members m where m.company_id = cid and m.user_id = auth.uid() and m.role in ('employee','manager');
  if eid is null then raise exception 'Accès salarié introuvable'; end if;
  select cd.data, co.name into d, nm from public.company_data cd join public.companies co on co.id = cd.company_id where cd.company_id = cid;
  if not exists (select 1 from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = eid) then
    delete from public.members where company_id = cid and user_id = auth.uid() and role in ('employee','manager');
    return jsonb_build_object('removed', true);
  end if;
  if not public.feature_on(cid, d, 'espace') then raise exception 'L''espace salarié n''est pas activé pour ce commerce'; end if;
  dd := coalesce(nullif(p_day, '')::date, (now() at time zone 'Europe/Paris')::date);
  mk := to_char(dd - (extract(isodow from dd)::int - 1), 'YYYY-MM-DD');
  di := (extract(isodow from dd)::int - 1)::text;
  select coalesce(jsonb_object_agg(w.key, jsonb_build_object(eid, w.value->eid)), '{}'::jsonb) into wk
    from jsonb_each(coalesce(d->'weeks', '{}'::jsonb)) w
    where w.value ? eid and w.key >= to_char(date_trunc('month', dd) - interval '62 days', 'YYYY-MM-DD');
  return jsonb_build_object(
    'shop', coalesce(d->>'shop', nm),
    'employee', (select jsonb_build_object('id', e->>'id', 'name', e->>'name', 'poste', e->>'poste', 'contract', e->'contract', 'phone', e->>'phone', 'lang', e->>'lang')
                   from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = eid limit 1),
    'features', jsonb_build_object(
      'badgeuse', public.feature_on(cid, d, 'badgeuse'), 'conges', public.feature_on(cid, d, 'conges'),
      'annonces', public.feature_on(cid, d, 'annonces'), 'taches', public.feature_on(cid, d, 'taches'),
      'hygiene', public.feature_on(cid, d, 'hygiene'), 'pertes', public.feature_on(cid, d, 'pertes'),
      'stock', public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff'),
      'dispos', public.feature_on(cid, d, 'dispos'), 'signalements', public.feature_on(cid, d, 'signalements'),
      'echanges', public.feature_on(cid, d, 'echanges'), 'messagerie', public.feature_on(cid, d, 'messagerie')),
    'swaps', (select coalesce(jsonb_agg(x || jsonb_build_object(
                  'name', (select e->>'name' from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = x->>'emp' limit 1),
                  'vname', (select e->>'name' from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = x->>'volunteer' limit 1))
                  order by x->>'date'), '[]'::jsonb)
              from jsonb_array_elements(coalesce(d->'swaps', '[]'::jsonb)) x
              where x->>'date' >= to_char(dd - 1, 'YYYY-MM-DD') and (x->>'emp' = eid or x->>'volunteer' = eid or x->>'status' = 'ouvert')),
    'availability', coalesce(d->'availability'->eid, '{}'::jsonb),
    'avail_dates', coalesce(d->'availDates'->eid, '{}'::jsonb),
    'role', (select m.role from public.members m where m.company_id = cid and m.user_id = auth.uid()),
    'branding', jsonb_build_object('accent', d#>>'{settings,accent}', 'logo', d#>>'{settings,logo}'),
    'messages', (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from (
                   select x, o from jsonb_array_elements(coalesce(d->'messages', '[]'::jsonb)) with ordinality t(x, o)
                   order by o desc limit 100) z),
    'reports', (select coalesce(jsonb_agg(r order by r->>'at' desc), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'reports', '[]'::jsonb)) r
                  where r->>'emp' = eid and left(r->>'at', 10) >= to_char(dd - 30, 'YYYY-MM-DD')),
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
    'team_today', (select coalesce(jsonb_agg(jsonb_build_object('name', e->>'name', 's', d->'weeks'->mk->(e->>'id')->di->>'s',
                      'e', d->'weeks'->mk->(e->>'id')->di->>'e', 'p', d->'weeks'->mk->(e->>'id')->di->>'p')
                      order by d->'weeks'->mk->(e->>'id')->di->>'s'), '[]'::jsonb)
                    from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e
                    where (d->'weeks'->mk->(e->>'id')->di) is not null and e->>'id' <> eid),
    'temps_today', (select coalesce(jsonb_agg(jsonb_build_object('equip', t->>'equip', 'val', t->'val', 'at', t->>'at') order by t->>'at'), '[]'::jsonb)
                    from jsonb_array_elements(coalesce(d->'temps', '[]'::jsonb)) t where left(t->>'at', 10) >= to_char(dd - 1, 'YYYY-MM-DD')),
    'stock', case when public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff')
               then (select coalesce(jsonb_agg(jsonb_build_object('id', s->>'id', 'name', s->>'name', 'unit', s->>'unit', 'qty', s->'qty', 'min', s->'min', 'cat', s->>'cat')), '[]'::jsonb)
                     from jsonb_array_elements(coalesce(d->'stock', '[]'::jsonb)) s)
               else null end,
    'punches', (select coalesce(jsonb_agg(p), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'punches', '[]'::jsonb)) p
                  where p->>'emp' = eid and left(p->>'at', 10) >= to_char(current_date - 62, 'YYYY-MM-DD'))
  );
end $$;

create or replace function public.employee_action(cid uuid, p_action text, p_payload jsonb, p_day text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare eid text; d jsonb; nid text; nowiso text; v numeric; q numeric; prod jsonb; pid text; item jsonb; dk text; txt text; sd date; smk text; sdi text; sh jsonb; sw jsonb; who text; logtxt text;
begin
  select m.employee_id into eid from public.members m where m.company_id = cid and m.user_id = auth.uid() and m.role in ('employee','manager');
  if eid is null then raise exception 'Accès salarié introuvable'; end if;
  select data into d from public.company_data where company_id = cid for update;
  if not exists (select 1 from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = eid) then
    delete from public.members where company_id = cid and user_id = auth.uid() and role in ('employee','manager');
    return jsonb_build_object('removed', true);
  end if;
  if not public.feature_on(cid, d, 'espace') then raise exception 'L''espace salarié n''est pas activé pour ce commerce'; end if;
  nid := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
  select e->>'name' into who from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e where e->>'id' = eid limit 1;
  nowiso := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  if p_action = 'punch' then
    if not public.feature_on(cid, d, 'badgeuse') then raise exception 'La badgeuse n''est pas activée'; end if;
    if coalesce(p_payload->>'kind', '') not in ('in', 'out', 'pause', 'resume') then raise exception 'Pointage invalide'; end if;
    if p_payload->>'kind' in ('in', 'out') and coalesce(p_payload->>'code', '') <> public.daily_code_for(cid, (now() at time zone 'Europe/Paris')::date) then
      raise exception 'Code du jour incorrect'; end if;
    logtxt := case p_payload->>'kind' when 'in' then 'a badgé son arrivée' when 'out' then 'a badgé son départ' when 'pause' then 'est parti en pause' else 'a repris après sa pause' end;
    d := jsonb_set(d, '{punches}', coalesce(d->'punches', '[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('id', nid, 'emp', eid, 'kind', p_payload->>'kind', 'at', nowiso)));
  elsif p_action = 'leave' then
    if not public.feature_on(cid, d, 'conges') then raise exception 'Les congés ne sont pas activés'; end if;
    if coalesce(p_payload->>'type', '') not in ('Congés payés', 'Maladie', 'Formation', 'Absence') then raise exception 'Motif invalide'; end if;
    if (p_payload->>'from') is null or (p_payload->>'to') is null or (p_payload->>'to') < (p_payload->>'from') then raise exception 'Dates invalides'; end if;
    d := jsonb_set(d, '{leaves}', coalesce(d->'leaves', '[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object('id', nid, 'emp', eid, 'type', p_payload->>'type', 'from', p_payload->>'from', 'to', p_payload->>'to', 'status', 'attente')));
    logtxt := 'a demandé un congé (' || (p_payload->>'type') || ') du ' || (p_payload->>'from') || ' au ' || (p_payload->>'to');
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
    logtxt := 'a relevé ' || v::text || ' °C (' || coalesce(p_payload->>'equip', '?') || ')';
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
    logtxt := 'a saisi ' || q::text || ' × ' || (prod->>'name') || ' en pertes';
  elsif p_action = 'stock' then
    if not (public.feature_on(cid, d, 'stock') and public.feature_on(cid, d, 'stock_staff')) then raise exception 'Le stock n''est pas ouvert à l''équipe'; end if;
    select s into item from jsonb_array_elements(coalesce(d->'stock', '[]'::jsonb)) s where s->>'id' = p_payload->>'item' limit 1;
    if item is null then raise exception 'Article introuvable'; end if;
    q := greatest(0, round(coalesce((item->>'qty')::numeric, 0) + coalesce((p_payload->>'delta')::numeric, 0), 2));
    d := jsonb_set(d, '{stock}', (select jsonb_agg(case when s->>'id' = p_payload->>'item' then jsonb_set(s, '{qty}', to_jsonb(q)) else s end)
                                  from jsonb_array_elements(d->'stock') s));
    logtxt := 'a mis le stock de ' || (item->>'name') || ' à ' || q::text;
  elsif p_action = 'avail' then
    if not public.feature_on(cid, d, 'dispos') then raise exception 'Les disponibilités ne sont pas activées'; end if;
    dk := p_payload->>'day';
    if dk is null or dk not in ('0','1','2','3','4','5','6') then raise exception 'Jour invalide'; end if;
    if not (coalesce(d->'availability', '{}'::jsonb) ? eid) then
      d := jsonb_set(d, '{availability}', coalesce(d->'availability', '{}'::jsonb) || jsonb_build_object(eid, '{}'::jsonb)); end if;
    if coalesce((p_payload->>'off')::boolean, false) then
      d := jsonb_set(d, array['availability', eid, dk], jsonb_build_object('off', true, 'note', left(coalesce(p_payload->>'note', ''), 80)));
    else
      d := jsonb_set(d, array['availability', eid], (d->'availability'->eid) - dk);
    end if;
  elsif p_action = 'report' then
    if not public.feature_on(cid, d, 'signalements') then raise exception 'Les signalements ne sont pas activés'; end if;
    txt := trim(coalesce(p_payload->>'text', ''));
    if length(txt) < 2 or length(txt) > 500 then raise exception 'Décris le problème en quelques mots'; end if;
    d := jsonb_set(d, '{reports}', coalesce(d->'reports', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('id', nid, 'emp', eid, 'at', nowiso,
      'kind', case when p_payload->>'kind' in ('Matériel','Hygiène','Stock','Sécurité','Autre') then p_payload->>'kind' else 'Autre' end, 'text', txt, 'status', 'ouvert')));
    logtxt := 'a signalé : ' || left(txt, 80);
  elsif p_action = 'read' then
    d := jsonb_set(d, '{notes}', (select coalesce(jsonb_agg(case when n->>'id' = p_payload->>'note' and not (coalesce(n->'read', '[]'::jsonb) ? eid)
                                   then jsonb_set(n, '{read}', coalesce(n->'read', '[]'::jsonb) || to_jsonb(eid)) else n end), '[]'::jsonb)
                                  from jsonb_array_elements(coalesce(d->'notes', '[]'::jsonb)) n));
  elsif p_action = 'leave_cancel' then
    d := jsonb_set(d, '{leaves}', (select coalesce(jsonb_agg(l), '[]'::jsonb) from jsonb_array_elements(coalesce(d->'leaves', '[]'::jsonb)) l
                                   where not (l->>'id' = p_payload->>'id' and l->>'emp' = eid and l->>'status' = 'attente')));
    logtxt := 'a annulé une demande de congé';
  elsif p_action in ('swap_request', 'swap_volunteer', 'swap_cancel') then
    if not public.feature_on(cid, d, 'echanges') then raise exception 'Les échanges de créneaux ne sont pas activés'; end if;
    if p_action = 'swap_request' then
      sd := (p_payload->>'date')::date;
      if sd < (now() at time zone 'Europe/Paris')::date then raise exception 'Ce jour est déjà passé'; end if;
      smk := to_char(sd - (extract(isodow from sd)::int - 1), 'YYYY-MM-DD'); sdi := (extract(isodow from sd)::int - 1)::text;
      sh := d->'weeks'->smk->eid->sdi;
      if sh is null then raise exception 'Tu ne travailles pas ce jour-là'; end if;
      if exists (select 1 from jsonb_array_elements(coalesce(d->'swaps', '[]'::jsonb)) x where x->>'emp' = eid and x->>'date' = sd::text and x->>'status' in ('ouvert','proposé')) then
        raise exception 'Une demande existe déjà pour ce jour'; end if;
      d := jsonb_set(d, '{swaps}', coalesce(d->'swaps', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('id', nid, 'emp', eid, 'date', sd::text,
        's', sh->>'s', 'e', sh->>'e', 'p', sh->>'p', 'note', left(coalesce(p_payload->>'note', ''), 120), 'status', 'ouvert', 'volunteer', null, 'at', nowiso)));
      logtxt := 'cherche un remplaçant pour le ' || sd::text;
    else
      select x into sw from jsonb_array_elements(coalesce(d->'swaps', '[]'::jsonb)) x where x->>'id' = p_payload->>'id' limit 1;
      if sw is null then raise exception 'Échange introuvable'; end if;
      if p_action = 'swap_volunteer' then
        if sw->>'emp' = eid or sw->>'status' <> 'ouvert' then raise exception 'Cet échange n''est plus disponible'; end if;
        sd := (sw->>'date')::date; smk := to_char(sd - (extract(isodow from sd)::int - 1), 'YYYY-MM-DD'); sdi := (extract(isodow from sd)::int - 1)::text;
        if (d->'weeks'->smk->eid->sdi) is not null then raise exception 'Tu travailles déjà ce jour-là'; end if;
        sw := sw || jsonb_build_object('volunteer', eid, 'status', 'proposé');
        logtxt := 'propose un remplacement le ' || (sw->>'date');
      elsif sw->>'emp' = eid and sw->>'status' in ('ouvert','proposé') then
        sw := null;
      elsif sw->>'volunteer' = eid and sw->>'status' = 'proposé' then
        sw := sw || jsonb_build_object('volunteer', null, 'status', 'ouvert');
      else
        raise exception 'Tu ne peux pas annuler cet échange';
      end if;
      d := jsonb_set(d, '{swaps}', (select coalesce(jsonb_agg(case when x->>'id' = p_payload->>'id' then sw else x end) filter (where x->>'id' <> p_payload->>'id' or sw is not null), '[]'::jsonb)
                                   from jsonb_array_elements(coalesce(d->'swaps', '[]'::jsonb)) x));
    end if;
  elsif p_action = 'avail_date' then
    if not public.feature_on(cid, d, 'dispos') then raise exception 'Les disponibilités ne sont pas activées'; end if;
    sd := (p_payload->>'date')::date;
    if sd < (now() at time zone 'Europe/Paris')::date then raise exception 'Ce jour est déjà passé'; end if;
    if not (coalesce(d->'availDates', '{}'::jsonb) ? eid) then
      d := jsonb_set(d, '{availDates}', coalesce(d->'availDates', '{}'::jsonb) || jsonb_build_object(eid, '{}'::jsonb)); end if;
    if coalesce(p_payload->>'type', '') in ('off', 'extra') then
      d := jsonb_set(d, array['availDates', eid, sd::text], jsonb_build_object('type', p_payload->>'type', 'note', left(coalesce(p_payload->>'note', ''), 80)));
      logtxt := case p_payload->>'type' when 'off' then 'est indisponible le ' else 'est disponible pour des heures en plus le ' end || sd::text;
    else
      d := jsonb_set(d, array['availDates', eid], (d->'availDates'->eid) - sd::text);
    end if;
  elsif p_action = 'message' then
    if not public.feature_on(cid, d, 'messagerie') then raise exception 'La messagerie n''est pas activée'; end if;
    txt := trim(coalesce(p_payload->>'text', ''));
    if length(txt) < 1 or length(txt) > 1000 then raise exception 'Message vide ou trop long'; end if;
    d := jsonb_set(d, '{messages}', (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from (
           select x, o from jsonb_array_elements(coalesce(d->'messages', '[]'::jsonb) ||
             jsonb_build_array(jsonb_build_object('id', nid, 'from', eid, 'name', who, 'at', nowiso, 'text', txt))) with ordinality t(x, o)
           order by o desc limit 300) z));
  elsif p_action = 'lang' then
    if coalesce(p_payload->>'lang', '') not in ('fr', 'pt', 'en') then raise exception 'Langue invalide'; end if;
    d := jsonb_set(d, '{employees}', (select coalesce(jsonb_agg(case when e->>'id' = eid then e || jsonb_build_object('lang', p_payload->>'lang') else e end), '[]'::jsonb)
                                      from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e));
  elsif p_action = 'profile' then
    d := jsonb_set(d, '{employees}', (select coalesce(jsonb_agg(case when e->>'id' = eid then e || jsonb_build_object('phone', left(trim(coalesce(p_payload->>'phone', '')), 20)) else e end), '[]'::jsonb)
                                      from jsonb_array_elements(coalesce(d->'employees', '[]'::jsonb)) e));
  else
    raise exception 'Action inconnue';
  end if;
  if logtxt is not null then
    d := jsonb_set(d, '{log}', (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from (
           select x, o from jsonb_array_elements(coalesce(d->'log', '[]'::jsonb) ||
             jsonb_build_array(jsonb_build_object('at', nowiso, 'who', coalesce(who, 'Salarié'), 'text', logtxt))) with ordinality t(x, o)
           order by o desc limit 400) z));
  end if;
  update public.company_data set data = d, updated_at = now(), updated_by = auth.uid() where company_id = cid;
  return public.employee_view(cid, p_day);
end $$;

do $$ declare f text; begin
  foreach f in array array['set_member_role(uuid,uuid,text)','employee_view(uuid,text)','employee_action(uuid,text,jsonb,text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

-- Nouvelle option réservée : tableau de rentabilité
create or replace function public.feature_on(cid uuid, d jsonb, fkey text)
returns boolean language sql stable security definer set search_path = public as $$
  select (case when fkey in ('espace','badgeuse','couts','registre','stats','rentabilite')
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
  if fkey not in ('espace','badgeuse','couts','registre','stats','rentabilite') then raise exception 'Option inconnue'; end if;
  update public.companies set plan_features = coalesce(plan_features, '{}'::jsonb) || jsonb_build_object(fkey, enabled)
    where id = cid returning plan_features into f;
  return f;
end $$;
revoke all on function public.admin_set_feature(uuid,text,boolean) from public, anon;
grant execute on function public.admin_set_feature(uuid,text,boolean) to authenticated;

-- ===== Version 2.1 =====

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
