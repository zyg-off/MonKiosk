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
