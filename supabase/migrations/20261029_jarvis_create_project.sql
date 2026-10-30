-- 017 - Owner-approved new project creation for Jarvis
-- Run in Supabase SQL Editor before using the new form.
create or replace function public.jarvis_create_project(
 p_name text, p_address text default null, p_status text default 'lead',
 p_amount numeric default 0, p_start_date date default null,
 p_target_date date default null, p_description text default null,
 p_owner_notes text default null
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare new_id uuid;
begin
 if not public.is_owner_or_admin() then raise exception 'Owner/admin access required'; end if;
 if p_name is null or length(btrim(p_name)) < 2 or length(p_name)>200 then
  raise exception 'Project name must contain 2 to 200 characters'; end if;
 if p_status is null or p_status not in ('lead','scheduled','active','on_hold','completed','cancelled') then
  raise exception 'Invalid project status'; end if;
 if p_amount is null or p_amount < 0 then raise exception 'Invalid contract amount'; end if;
 insert into public.projects(
  name,address,project_status,original_contract_amount,start_date,
  target_completion_date,project_description,owner_notes,active
 ) values (
  btrim(p_name),nullif(btrim(p_address),''),p_status,p_amount,p_start_date,
  p_target_date,nullif(btrim(p_description),''),nullif(btrim(p_owner_notes),''),
  p_status in ('scheduled','active','on_hold')
 ) returning id into new_id;
 return new_id;
end $$;
revoke all on function public.jarvis_create_project(text,text,text,numeric,date,date,text,text) from public,anon;
grant execute on function public.jarvis_create_project(text,text,text,numeric,date,date,text,text) to authenticated;
