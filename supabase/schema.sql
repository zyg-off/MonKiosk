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
