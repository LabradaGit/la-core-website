-- Project history foundation. Run once in Supabase SQL Editor.
-- Tracks INSERT/UPDATE/DELETE regardless of whether the writer is Jarvis or the Owner Dashboard.
create table if not exists public.project_change_history (
 id uuid primary key default gen_random_uuid(),
 project_id uuid not null,
 operation text not null check (operation in ('INSERT','UPDATE','DELETE')),
 changed_at timestamptz not null default now(),
 changed_by uuid default auth.uid(),
 old_record jsonb,
 new_record jsonb,
 changes jsonb not null default '{}'::jsonb
);
create index if not exists project_change_history_project_time_idx
 on public.project_change_history(project_id,changed_at desc);
alter table public.project_change_history enable row level security;
revoke all on public.project_change_history from public,anon,authenticated;
grant select on public.project_change_history to authenticated;
drop policy if exists project_history_owner_read on public.project_change_history;
create policy project_history_owner_read on public.project_change_history
 for select to authenticated using (public.is_owner_or_admin());

create or replace function public.record_project_change()
returns trigger language plpgsql security definer set search_path=public
as $$
declare old_json jsonb; new_json jsonb; diff jsonb;
begin
 old_json := case when TG_OP='INSERT' then null else to_jsonb(OLD) end;
 new_json := case when TG_OP='DELETE' then null else to_jsonb(NEW) end;
 if TG_OP='UPDATE' then
  select coalesce(jsonb_object_agg(k,jsonb_build_object('old',old_json->k,'new',new_json->k)),'{}'::jsonb)
    into diff
    from (select key as k from jsonb_object_keys(old_json || new_json) key
          where old_json->key is distinct from new_json->key) d;
  if diff='{}'::jsonb then return NEW; end if;
 else
  diff := '{}'::jsonb;
 end if;
 insert into public.project_change_history(project_id,operation,changed_by,old_record,new_record,changes)
 values (case when TG_OP='DELETE' then OLD.id else NEW.id end,
         TG_OP,auth.uid(),old_json,new_json,diff);
 if TG_OP='DELETE' then return OLD; else return NEW; end if;
end $$;
drop trigger if exists audit_project_changes on public.projects;
create trigger audit_project_changes
 after insert or update or delete on public.projects
 for each row execute function public.record_project_change();

-- Restore ONE allowlisted field from a recorded UPDATE.
-- This does not silently reverse payments, expenses or newer changes.
-- The audit trigger records the restore as another UPDATE.
create or replace function public.jarvis_restore_project_field(p_history_id uuid,p_field text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare h public.project_change_history%rowtype; current_json jsonb;
 allowed text[] := array['name','address','project_description','owner_notes',
 'project_status','start_date','target_completion_date','original_contract_amount'];
 old_value jsonb; new_value jsonb;
begin
 if not public.is_owner_or_admin() then raise exception 'Owner access required'; end if;
 if p_field is null or not(p_field=any(allowed)) then raise exception 'Unsupported restore field'; end if;
 select * into h from public.project_change_history where id=p_history_id;
 if not found or h.operation<>'UPDATE' or not(h.changes ? p_field) then
  raise exception 'No matching update found'; end if;
 perform 1 from public.projects where id=h.project_id for update;
 if not found then raise exception 'Project no longer exists'; end if;
 execute format('select to_jsonb(%I) from public.projects where id=$1',p_field)
  into current_json using h.project_id;
 new_value := h.changes->p_field->'new';
 old_value := h.changes->p_field->'old';
 if current_json is distinct from new_value then
  raise exception 'Field has changed again since this history entry. Review newer history first.';
 end if;
 if p_field='name' and (old_value='null'::jsonb or btrim(old_value #>> '{}')='') then
  raise exception 'Project name cannot be empty'; end if;
 if p_field='project_status' and (old_value #>> '{}') not in
 ('lead','scheduled','active','on_hold','completed','cancelled') then
  raise exception 'Invalid previous status'; end if;
 execute format('update public.projects set %I=$1 where id=$2',p_field)
 using old_value #>> '{}',h.project_id;
 if p_field='project_status' then
  update public.projects set active=(project_status in ('scheduled','active','on_hold'))
  where id=h.project_id;
 end if;
 return jsonb_build_object('project_id',h.project_id,'field',p_field,'restored_to',old_value);
end $$;
revoke all on function public.jarvis_restore_project_field(uuid,text) from public,anon;
grant execute on function public.jarvis_restore_project_field(uuid,text) to authenticated;
