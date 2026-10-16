-- LA Core PIN function repair, after crew_pin_hash / crew_pin_verify helpers.
-- Does not change time clock, employee records or payments.

create or replace function public.owner_issue_crew_temp_pin(p_employee_id uuid)
returns text language plpgsql security definer set search_path=public
as $$
declare v_pin text;
begin
 if not public.is_owner_or_admin() then raise exception 'Not authorized'; end if;
 if not exists(select 1 from public.employees where id=p_employee_id and active=true) then raise exception 'Employee not active'; end if;
 v_pin:=lpad((floor(random()*1000000)::int)::text,6,'0');
 insert into public.crew_pin_credentials(employee_id,temporary_hash,temporary_expires_at,failed_attempts,locked_until)
 values(p_employee_id,public.crew_pin_hash(v_pin),now()+interval '24 hours',0,null)
 on conflict(employee_id) do update set temporary_hash=excluded.temporary_hash,
 temporary_expires_at=excluded.temporary_expires_at,failed_attempts=0,locked_until=null;
 delete from public.crew_earnings_sessions where employee_id=p_employee_id;
 return v_pin;
end $$;

-- PIN sign-in: bcrypt verification, rate-limited per employee. A temporary PIN supersedes an old permanent PIN.
-- A temporary PIN only authorizes setting a permanent PIN, never viewing earnings.
create or replace function public.crew_pin_login(p_employee_id uuid,p_pin text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare c public.crew_pin_credentials%rowtype; v_temp boolean; v_token text;
begin
 if p_pin !~ '^[0-9]{6}$' then raise exception 'Invalid credentials'; end if;
 select * into c from public.crew_pin_credentials where employee_id=p_employee_id for update;
 if not found or (c.locked_until is not null and c.locked_until>now()) then raise exception 'Invalid credentials or temporarily locked'; end if;
 v_temp:=c.temporary_hash is not null and c.temporary_expires_at>now() and public.crew_pin_verify(p_pin,c.temporary_hash);
 if not v_temp and (c.temporary_hash is not null or c.pin_hash is null or not public.crew_pin_verify(p_pin,c.pin_hash)) then
   update public.crew_pin_credentials set failed_attempts=failed_attempts+1,
   locked_until=case when failed_attempts+1>=5 then now()+interval '15 minutes' else null end where employee_id=p_employee_id;
   return jsonb_build_object('error','Invalid credentials');
 end if;
 update public.crew_pin_credentials set failed_attempts=0,locked_until=null where employee_id=p_employee_id;
 v_token:=encode(extensions.gen_random_bytes(32),'hex');
 insert into public.crew_earnings_sessions(token_hash,employee_id,expires_at)
 values(encode(extensions.digest(v_token,'sha256'),'hex'),p_employee_id,now()+interval '30 days');
 return jsonb_build_object('token',v_token,'requires_pin_change',v_temp);
end $$;

create or replace function public.crew_set_private_pin(p_token text,p_new_pin text)
returns boolean language plpgsql security definer set search_path=public
as $$
declare v_employee uuid;
begin
 if p_new_pin !~ '^[0-9]{6}$' then raise exception 'PIN must be 6 digits'; end if;
 select employee_id into v_employee from public.crew_earnings_sessions
 where token_hash=encode(extensions.digest(p_token,'sha256'),'hex') and expires_at>now();
 if v_employee is null then raise exception 'Session expired'; end if;
 if not exists(select 1 from public.crew_pin_credentials where employee_id=v_employee and temporary_hash is not null and temporary_expires_at>now()) then raise exception 'A new temporary PIN is required to set a private PIN'; end if;
 update public.crew_pin_credentials set pin_hash=public.crew_pin_hash(p_new_pin),
 temporary_hash=null,temporary_expires_at=null,updated_at=now() where employee_id=v_employee;
 delete from public.crew_earnings_sessions where employee_id=v_employee;
 return true;
end $$;


-- Earnings token validation uses the same extension-qualified digest.
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
   select t.id,t.project_id,t.clock_in,t.clock_out,
     coalesce(t.assignment_id, (
       select a.id from public.assignments a
       where a.employee_id=v_employee and a.project_id=t.project_id
       and (a.start_date is null or a.start_date <= (t.clock_in at time zone 'America/New_York')::date)
       and (a.end_date is null or a.end_date >= (t.clock_in at time zone 'America/New_York')::date)
       order by a.created_at desc limit 1
     )) assignment_id
   from public.time_punches t
   where t.employee_id=v_employee and t.clock_out is not null and t.clock_out>=t.clock_in
 ), punch_values as (
   select pa.project_id,pa.clock_in,
     extract(epoch from(pa.clock_out-pa.clock_in))/3600 as hours,
     a.compensation_type,a.hourly_rate,a.daily_rate
   from punch_assignment pa join public.assignments a on a.id=pa.assignment_id and a.employee_id=v_employee
 ), project_hours as (
   select project_id,round(coalesce(sum(hours),0)::numeric,2) hours,
     round(coalesce(sum(case when compensation_type='hourly' then hours*coalesce(hourly_rate,0) else 0 end),0)::numeric,2) hourly_earned
   from punch_values group by project_id
 ), project_days as (
   select project_id,sum(daily_rate) daily_earned from (
     select project_id,(clock_in at time zone 'America/New_York')::date work_date,
       max(coalesce(daily_rate,0)) daily_rate
     from punch_values where compensation_type='daily'
     group by project_id,(clock_in at time zone 'America/New_York')::date
   ) days group by project_id
 ), payment_summary as (
   select project_id,sum(amount) paid,
    jsonb_agg(jsonb_build_object('date',payment_date,'amount',amount,'method',payment_method,'reference',reference)
      order by payment_date desc,created_at desc) payment_list
   from public.crew_payments where employee_id=v_employee group by project_id
 ), employee_projects as (
   select distinct project_id from public.assignments where employee_id=v_employee
   union select distinct project_id from public.crew_payments where employee_id=v_employee
 )
 select coalesce(jsonb_agg(jsonb_build_object(
   'project_id',ep.project_id,'project',p.name,
   'hours',coalesce(ph.hours,0),
   'estimated_earned',coalesce(ph.hourly_earned,0)+coalesce(pd.daily_earned,0),
   'paid',coalesce(ps.paid,0),
   'estimated_balance',coalesce(ph.hourly_earned,0)+coalesce(pd.daily_earned,0)-coalesce(ps.paid,0),
   'payments',coalesce(ps.payment_list,'[]'::jsonb),
   'note','Fixed contracts and track-only shifts are excluded from automatic earnings calculations'
  ) order by p.name),'[]'::jsonb) into v_result
 from employee_projects ep join public.projects p on p.id=ep.project_id
 left join project_hours ph on ph.project_id=ep.project_id
 left join project_days pd on pd.project_id=ep.project_id
 left join payment_summary ps on ps.project_id=ep.project_id;
 return v_result;
end $$;

