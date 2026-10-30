-- 016 - Fix Jarvis rollback field typing
-- Replace only the restore function. Existing history and project data remain untouched.
create or replace function public.jarvis_restore_project_field(p_history_id uuid,p_field text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
 h public.project_change_history%rowtype;
 current_json jsonb; old_value jsonb; new_value jsonb;
 allowed text[] := array['name','address','project_description','owner_notes',
 'project_status','start_date','target_completion_date','original_contract_amount'];
begin
 if not public.is_owner_or_admin() then raise exception 'Owner access required'; end if;
 if p_field is null or not (p_field=any(allowed)) then raise exception 'Unsupported restore field'; end if;
 select * into h from public.project_change_history where id=p_history_id;
 if not found or h.operation <> 'UPDATE' or not (h.changes ? p_field) then
  raise exception 'No matching update found';
 end if;
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
  raise exception 'Project name cannot be empty';
 end if;
 if p_field='project_status' and (old_value #>> '{}') not in
 ('lead','scheduled','active','on_hold','completed','cancelled') then
  raise exception 'Invalid previous status';
 end if;
 if p_field='original_contract_amount' then
  execute format('update public.projects set %I=$1::numeric where id=$2',p_field)
   using old_value #>> '{}',h.project_id;
 elsif p_field in ('start_date','target_completion_date') then
  execute format('update public.projects set %I=$1::date where id=$2',p_field)
   using old_value #>> '{}',h.project_id;
 else
  execute format('update public.projects set %I=$1::text where id=$2',p_field)
   using old_value #>> '{}',h.project_id;
 end if;
 if p_field='project_status' then
  update public.projects set active=(project_status in ('scheduled','active','on_hold'))
  where id=h.project_id;
 end if;
 return jsonb_build_object('project_id',h.project_id,'field',p_field,'restored_to',old_value);
end $$;
revoke all on function public.jarvis_restore_project_field(uuid,text) from public,anon;
grant execute on function public.jarvis_restore_project_field(uuid,text) to authenticated;
