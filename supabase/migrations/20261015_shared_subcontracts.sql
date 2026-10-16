-- Shared subcontract allocations: owner-controlled, expense-backed, separate from hourly crew.
create table if not exists public.crew_shared_subcontracts (
 id uuid primary key default gen_random_uuid(),
 project_id uuid not null references public.projects(id) on delete cascade,
 budget numeric(12,2) not null check(budget>=0),
 include_materials boolean not null default false,
 finalized boolean not null default false,
 created_at timestamptz not null default now(),
 unique(project_id)
);
create table if not exists public.crew_shared_participants (
 subcontract_id uuid not null references public.crew_shared_subcontracts(id) on delete cascade,
 assignment_id uuid not null references public.assignments(id) on delete cascade,
 primary key(subcontract_id,assignment_id),
 unique(assignment_id)
);
create table if not exists public.crew_shared_costs (
 id uuid primary key default gen_random_uuid(),
 subcontract_id uuid not null references public.crew_shared_subcontracts(id) on delete cascade,
 description text not null,
 category text not null check(category in ('equipment','labor','materials','other')),
 amount numeric(12,2) not null check(amount>=0),
 created_at timestamptz not null default now()
);
alter table public.crew_shared_subcontracts enable row level security;
alter table public.crew_shared_participants enable row level security;
alter table public.crew_shared_costs enable row level security;
drop policy if exists owner_shared_subcontracts on public.crew_shared_subcontracts;
create policy owner_shared_subcontracts on public.crew_shared_subcontracts for all to authenticated using (public.is_owner_or_admin()) with check (public.is_owner_or_admin());
drop policy if exists owner_shared_participants on public.crew_shared_participants;
create policy owner_shared_participants on public.crew_shared_participants for all to authenticated using (public.is_owner_or_admin()) with check (public.is_owner_or_admin());
drop policy if exists owner_shared_costs on public.crew_shared_costs;
create policy owner_shared_costs on public.crew_shared_costs for all to authenticated using (public.is_owner_or_admin()) with check (public.is_owner_or_admin());

-- Approval is atomic and refuses to overwrite noncontract or mismatched assignments.
create or replace function public.finalize_shared_subcontract(p_subcontract_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_sub public.crew_shared_subcontracts%rowtype; v_count integer; v_cost numeric; v_share numeric;
begin
 if not public.is_owner_or_admin() then raise exception 'Owner access required'; end if;
 select * into v_sub from public.crew_shared_subcontracts where id=p_subcontract_id for update;
 if not found then raise exception 'Subcontract not found'; end if;
 select count(*) into v_count from public.crew_shared_participants where subcontract_id=p_subcontract_id;
 if v_count<1 then raise exception 'Select at least one participant'; end if;
 if exists(select 1 from public.crew_shared_participants sp join public.assignments a on a.id=sp.assignment_id
 where sp.subcontract_id=p_subcontract_id and (a.project_id<>v_sub.project_id or a.compensation_type<>'contract')) then
 raise exception 'Participants must have fixed-contract assignments on this project'; end if;
 select coalesce(sum(amount),0) into v_cost from public.crew_shared_costs
 where subcontract_id=p_subcontract_id and (category<>'materials' or v_sub.include_materials);
 if v_cost>v_sub.budget then raise exception 'Expenses exceed subcontract budget'; end if;
 v_share:=round((v_sub.budget-v_cost)/v_count,2);
 update public.assignments a set contract_amount=v_share
 from public.crew_shared_participants sp
 where sp.assignment_id=a.id and sp.subcontract_id=p_subcontract_id;
 update public.crew_shared_subcontracts set finalized=true where id=p_subcontract_id;
 return jsonb_build_object('participants',v_count,'expenses',v_cost,'allocation_each',v_share,'unallocated_rounding',v_sub.budget-v_cost-v_share*v_count);
end $$;
revoke all on function public.finalize_shared_subcontract(uuid) from public;
grant execute on function public.finalize_shared_subcontract(uuid) to authenticated;

-- Crew earnings includes finalized contract allocations, not the shared budget.
create or replace function public.crew_private_earnings(p_token text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_employee uuid; v_result jsonb;
begin
 select employee_id into v_employee from public.crew_earnings_sessions
 where token_hash=encode(extensions.digest(p_token,'sha256'),'hex') and expires_at>now();
 if v_employee is null then raise exception 'Session expired'; end if;
 if exists(select 1 from public.crew_pin_credentials where employee_id=v_employee and temporary_hash is not null) then
 raise exception 'Set a private PIN before viewing earnings'; end if;
 with punch_assignment as (
 select t.project_id,t.clock_in,t.clock_out,
 coalesce(t.assignment_id,(select a.id from public.assignments a where a.employee_id=v_employee and a.project_id=t.project_id
 and (a.start_date is null or a.start_date<=(t.clock_in at time zone 'America/New_York')::date)
 and (a.end_date is null or a.end_date>=(t.clock_in at time zone 'America/New_York')::date)
 order by a.created_at desc limit 1)) assignment_id
 from public.time_punches t where t.employee_id=v_employee and t.clock_out is not null and t.clock_out>=t.clock_in
 ), punch_values as (
 select pa.project_id,pa.clock_in,extract(epoch from(pa.clock_out-pa.clock_in))/3600 hours,
 a.compensation_type,a.hourly_rate,a.daily_rate
 from punch_assignment pa join public.assignments a on a.id=pa.assignment_id and a.employee_id=v_employee
 ), project_hours as (
 select project_id,round(coalesce(sum(hours),0)::numeric,2) hours,
 round(coalesce(sum(case when compensation_type='hourly' then hours*coalesce(hourly_rate,0) else 0 end),0)::numeric,2) hourly_earned
 from punch_values group by project_id
 ), project_days as (
 select project_id,sum(daily_rate) daily_earned from (
 select project_id,(clock_in at time zone 'America/New_York')::date work_date,max(coalesce(daily_rate,0)) daily_rate
 from punch_values where compensation_type='daily'
 group by project_id,(clock_in at time zone 'America/New_York')::date
 ) d group by project_id
 ), contracts as (
 select a.project_id,sum(coalesce(a.contract_amount,0)) contract_earned
 from public.assignments a
 where a.employee_id=v_employee and a.compensation_type='contract'
 and (not exists(select 1 from public.crew_shared_participants sp where sp.assignment_id=a.id)
 or exists(select 1 from public.crew_shared_participants sp join public.crew_shared_subcontracts s on s.id=sp.subcontract_id where sp.assignment_id=a.id and s.finalized))
 group by a.project_id
 ), payment_summary as (
 select project_id,sum(amount) paid,
 jsonb_agg(jsonb_build_object('date',payment_date,'amount',amount,'method',payment_method,'reference',reference)
 order by payment_date desc,created_at desc) payment_list
 from public.crew_payments where employee_id=v_employee group by project_id
 ), employee_projects as (
 select project_id from public.assignments where employee_id=v_employee
 union select project_id from public.crew_payments where employee_id=v_employee
 )
 select coalesce(jsonb_agg(jsonb_build_object(
 'project_id',ep.project_id,'project',p.name,'hours',coalesce(ph.hours,0),
 'estimated_earned',coalesce(ph.hourly_earned,0)+coalesce(pd.daily_earned,0)+coalesce(c.contract_earned,0),
 'contract_allocation',coalesce(c.contract_earned,0),
 'paid',coalesce(ps.paid,0),
 'estimated_balance',coalesce(ph.hourly_earned,0)+coalesce(pd.daily_earned,0)+coalesce(c.contract_earned,0)-coalesce(ps.paid,0),
 'payments',coalesce(ps.payment_list,'[]'::jsonb)
 ) order by p.name),'[]'::jsonb) into v_result
 from employee_projects ep join public.projects p on p.id=ep.project_id
 left join project_hours ph on ph.project_id=ep.project_id
 left join project_days pd on pd.project_id=ep.project_id
 left join contracts c on c.project_id=ep.project_id
 left join payment_summary ps on ps.project_id=ep.project_id;
 return v_result;
end $$;
