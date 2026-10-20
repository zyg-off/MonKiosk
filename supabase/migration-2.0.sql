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
