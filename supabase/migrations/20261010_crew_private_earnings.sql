-- LA Core crew earnings security foundation.
-- REVIEW AND RUN IN SUPABASE SQL EDITOR BEFORE ENABLING EARNINGS UI.
-- Existing crew clock functions and tables are not modified.
create extension if not exists pgcrypto;

create table if not exists public.crew_pin_credentials (
 employee_id uuid primary key references public.employees(id) on delete cascade,
 pin_hash text,
 temporary_hash text,
 temporary_expires_at timestamptz,
 failed_attempts integer not null default 0,
 locked_until timestamptz,
 updated_at timestamptz not null default now()
);
create table if not exists public.crew_earnings_sessions (
 token_hash text primary key,
 employee_id uuid not null references public.employees(id) on delete cascade,
 expires_at timestamptz not null,
 created_at timestamptz not null default now()
);
create table if not exists public.crew_payments (
 id uuid primary key default gen_random_uuid(),
 employee_id uuid not null references public.employees(id),
 project_id uuid not null references public.projects(id),
 assignment_id uuid references public.assignments(id),
 amount numeric(12,2) not null check (amount > 0),
 payment_date date not null,
 payment_method text not null check (payment_method in ('Zelle','Check','Cash','Other')),
 reference text,
 note text,
 created_at timestamptz not null default now(),
 created_by uuid default auth.uid()
);
create index if not exists crew_payments_employee_project_idx on public.crew_payments(employee_id,project_id,payment_date desc);
create index if not exists crew_sessions_employee_idx on public.crew_earnings_sessions(employee_id);
alter table public.crew_pin_credentials enable row level security;
alter table public.crew_earnings_sessions enable row level security;
alter table public.crew_payments enable row level security;
revoke all on public.crew_pin_credentials, public.crew_earnings_sessions, public.crew_payments from anon, authenticated;
grant select,insert,update,delete on public.crew_payments to authenticated;
drop policy if exists crew_payments_owner on public.crew_payments;
create policy crew_payments_owner on public.crew_payments for all to authenticated
 using (public.is_owner_or_admin()) with check (public.is_owner_or_admin());

-- Owner can issue a one-time temporary PIN but cannot read the permanent PIN.
create or replace function public.owner_issue_crew_temp_pin(p_employee_id uuid)
returns text language plpgsql security definer set search_path=public
as $$
declare v_pin text;
begin
 if not public.is_owner_or_admin() then raise exception 'Not authorized'; end if;
 if not exists(select 1 from public.employees where id=p_employee_id and active=true) then raise exception 'Employee not active'; end if;
 v_pin:=lpad((floor(random()*1000000)::int)::text,6,'0');
 insert into public.crew_pin_credentials(employee_id,temporary_hash,temporary_expires_at,failed_attempts,locked_until)
 values(p_employee_id,crypt(v_pin,gen_salt('bf')),now()+interval '24 hours',0,null)
 on conflict(employee_id) do update set temporary_hash=excluded.temporary_hash,
 temporary_expires_at=excluded.temporary_expires_at,failed_attempts=0,locked_until=null;
 delete from public.crew_earnings_sessions where employee_id=p_employee_id;
 return v_pin;
end $$;

-- PIN sign-in: constant-time hash verification by pgcrypto, rate-limited per employee.
-- A temporary PIN only authorizes setting a permanent PIN, never viewing earnings.
create or replace function public.crew_pin_login(p_employee_id uuid,p_pin text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare c public.crew_pin_credentials%rowtype; v_temp boolean; v_token text;
begin
 if p_pin !~ '^[0-9]{6}$' then raise exception 'Invalid credentials'; end if;
 select * into c from public.crew_pin_credentials where employee_id=p_employee_id for update;
 if not found or (c.locked_until is not null and c.locked_until>now()) then raise exception 'Invalid credentials or temporarily locked'; end if;
 v_temp:=c.temporary_hash is not null and c.temporary_expires_at>now() and crypt(p_pin,c.temporary_hash)=c.temporary_hash;
 if not v_temp and (c.pin_hash is null or crypt(p_pin,c.pin_hash)<>c.pin_hash) then
   update public.crew_pin_credentials set failed_attempts=failed_attempts+1,
   locked_until=case when failed_attempts+1>=5 then now()+interval '15 minutes' else null end where employee_id=p_employee_id;
   raise exception 'Invalid credentials';
 end if;
 update public.crew_pin_credentials set failed_attempts=0,locked_until=null where employee_id=p_employee_id;
 v_token:=encode(gen_random_bytes(32),'hex');
 insert into public.crew_earnings_sessions(token_hash,employee_id,expires_at)
 values(encode(digest(v_token,'sha256'),'hex'),p_employee_id,now()+interval '30 days');
 return jsonb_build_object('token',v_token,'requires_pin_change',v_temp);
end $$;

create or replace function public.crew_set_private_pin(p_token text,p_new_pin text)
returns boolean language plpgsql security definer set search_path=public
as $$
declare v_employee uuid;
begin
 if p_new_pin !~ '^[0-9]{6}$' then raise exception 'PIN must be 6 digits'; end if;
 select employee_id into v_employee from public.crew_earnings_sessions
 where token_hash=encode(digest(p_token,'sha256'),'hex') and expires_at>now();
 if v_employee is null then raise exception 'Session expired'; end if;
 update public.crew_pin_credentials set pin_hash=crypt(p_new_pin,gen_salt('bf')),
 temporary_hash=null,temporary_expires_at=null,updated_at=now() where employee_id=v_employee;
 delete from public.crew_earnings_sessions where employee_id=v_employee
 and token_hash<>encode(digest(p_token,'sha256'),'hex');
 return true;
end $$;

-- Private project-by-project view. Never expose raw compensation tables to anonymous crew clients.
create or replace function public.crew_private_earnings(p_token text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_employee uuid; v_result jsonb;
begin
 select employee_id into v_employee from public.crew_earnings_sessions
 where token_hash=encode(digest(p_token,'sha256'),'hex') and expires_at>now();
 if v_employee is null then raise exception 'Session expired'; end if;
 if exists(select 1 from public.crew_pin_credentials where employee_id=v_employee and temporary_hash is not null) then
 raise exception 'Set a private PIN before viewing earnings'; end if;
 with a as (
 select id,project_id,compensation_type,hourly_rate,daily_rate,contract_amount
 from public.assignments where employee_id=v_employee
 ), calc as (
 select a.id,a.project_id,a.compensation_type,
 coalesce(sum(extract(epoch from (t.clock_out-t.clock_in))/3600),0) as hours,
 count(distinct (t.clock_in at time zone 'America/New_York')::date) as days,
 case when a.compensation_type='hourly' then coalesce(sum(extract(epoch from (t.clock_out-t.clock_in))/3600),0)*coalesce(a.hourly_rate,0)
 when a.compensation_type='daily' then count(distinct (t.clock_in at time zone 'America/New_York')::date)*coalesce(a.daily_rate,0)
 else 0 end as earned
 from a left join public.time_punches t on t.employee_id=v_employee and t.project_id=a.project_id
 and t.clock_out is not null and (t.assignment_id=a.id or t.assignment_id is null)
 group by a.id,a.project_id,a.compensation_type,a.hourly_rate,a.daily_rate
 )
 select coalesce(jsonb_agg(jsonb_build_object(
 'project_id',calc.project_id,'project',p.name,'compensation_type',calc.compensation_type,
 'hours',round(calc.hours::numeric,2),'days',calc.days,'estimated_earned',round(calc.earned::numeric,2),
 'paid',coalesce(pay.paid,0),'estimated_balance',round(calc.earned::numeric-coalesce(pay.paid,0),2),
 'last_payment',pay.last_payment,'payments',coalesce(pay.payment_list,'[]'::jsonb)
 )), '[]'::jsonb) into v_result
 from calc join public.projects p on p.id=calc.project_id
 left join lateral (
 select sum(cp.amount) paid,
 (array_agg(jsonb_build_object('date',cp.payment_date,'amount',cp.amount,'method',cp.payment_method,'reference',cp.reference)
 order by cp.payment_date desc,cp.created_at desc))[1] last_payment,
 jsonb_agg(jsonb_build_object('date',cp.payment_date,'amount',cp.amount,'method',cp.payment_method,'reference',cp.reference)
 order by cp.payment_date desc,cp.created_at desc) payment_list
 from public.crew_payments cp where cp.employee_id=v_employee and cp.project_id=calc.project_id
 ) pay on true;
 return v_result;
end $$;

revoke all on function public.owner_issue_crew_temp_pin(uuid) from public;
grant execute on function public.owner_issue_crew_temp_pin(uuid) to authenticated;
revoke all on function public.crew_pin_login(uuid,text),public.crew_set_private_pin(text,text),public.crew_private_earnings(text) from public;
grant execute on function public.crew_pin_login(uuid,text),public.crew_set_private_pin(text,text),public.crew_private_earnings(text) to anon,authenticated;
