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
