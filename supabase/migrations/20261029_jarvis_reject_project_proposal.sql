-- Owner-only rejection: preserve audit history without modifying a project.
create or replace function public.jarvis_reject_project_proposal(p_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare p public.jarvis_project_proposals%rowtype;
begin
 if not public.is_owner_or_admin() then raise exception 'Owner access required'; end if;
 select * into p from public.jarvis_project_proposals where id=p_id for update;
 if not found then raise exception 'Proposal not found'; end if;
 if p.status <> 'draft' then raise exception 'Only draft proposals may be rejected'; end if;
 update public.jarvis_project_proposals
 set status='rejected', reviewed_at=now(), reviewed_by=auth.uid()
 where id=p_id;
 return jsonb_build_object('proposal_id',p_id,'status','rejected');
end $$;
revoke all on function public.jarvis_reject_project_proposal(uuid) from public;
grant execute on function public.jarvis_reject_project_proposal(uuid) to authenticated;
