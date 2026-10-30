-- Atomic, approval-first application of strictly allowlisted project fields.
-- Requires the staging migration 20261029_jarvis_project_proposals.sql.
create or replace function public.jarvis_apply_project_proposal(p_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
 p public.jarvis_project_proposals%rowtype;
 item jsonb; k text; before_value jsonb; after_value jsonb;
 current_value jsonb; updates jsonb := '{}'::jsonb; applied integer := 0;
 allowed text[] := array['name','address','description','notes','status','start_date','target_completion_date','contract_amount'];
begin
 if not public.is_owner_or_admin() then raise exception 'Owner access required'; end if;
 select * into p from public.jarvis_project_proposals where id=p_id for update;
 if not found then raise exception 'Proposal not found'; end if;
 if p.status <> 'draft' then raise exception 'Proposal is not a draft'; end if;
 perform 1 from public.projects where id=p.project_id for update;
 if not found then raise exception 'Project not found'; end if;
 for item in select value from jsonb_array_elements(p.changes) loop
   if jsonb_typeof(item) <> 'object' then raise exception 'Invalid change'; end if;
   k := item->>'field';
   if k is null or not (k = any(allowed)) then raise exception 'Unsupported project field: %', k; end if;
   if not (item ? 'old' and item ? 'new') then raise exception 'Old/new values required'; end if;
   if updates ? k then raise exception 'Duplicate field: %',k; end if;
   execute format('select to_jsonb(%I) from public.projects where id=$1',k)
     into current_value using p.project_id;
   before_value := item->'old'; after_value := item->'new';
   if current_value is distinct from before_value then raise exception 'Project field % changed since proposal creation',k; end if;
   if k = 'status' and (jsonb_typeof(after_value) <> 'string' or
     after_value #>> '{}' not in ('lead','scheduled','active','on_hold','completed','cancelled')) then
      raise exception 'Invalid project status';
   end if;
   if k = 'contract_amount' and after_value <> 'null'::jsonb and
      (jsonb_typeof(after_value) <> 'number' or (after_value #>> '{}')::numeric < 0) then
      raise exception 'Invalid contract amount';
   end if;
   updates := updates || jsonb_build_object(k,after_value);
   applied := applied+1;
 end loop;
 -- jsonb_populate_record performs native column type validation without dynamic SQL.
 update public.projects set
  name=coalesce((updates->>'name'),name),
  address=case when updates ? 'address' then updates->>'address' else address end,
  description=case when updates ? 'description' then updates->>'description' else description end,
  notes=case when updates ? 'notes' then updates->>'notes' else notes end,
  status=coalesce((updates->>'status'),status),
  start_date=case when updates ? 'start_date' then (updates->>'start_date')::date else start_date end,
  target_completion_date=case when updates ? 'target_completion_date' then (updates->>'target_completion_date')::date else target_completion_date end,
  contract_amount=case when updates ? 'contract_amount' then (updates->>'contract_amount')::numeric else contract_amount end
 where id=p.project_id;
 update public.jarvis_project_proposals
 set status='applied', reviewed_at=now(), reviewed_by=auth.uid(), applied_at=now()
 where id=p_id;
 return jsonb_build_object('project_id',p.project_id,'fields_applied',applied);
end $$;
revoke all on function public.jarvis_apply_project_proposal(uuid) from public;
grant execute on function public.jarvis_apply_project_proposal(uuid) to authenticated;
