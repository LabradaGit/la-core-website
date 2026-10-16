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

