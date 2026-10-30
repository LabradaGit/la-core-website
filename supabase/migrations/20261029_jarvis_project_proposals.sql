-- Jarvis Project Assistant v1: proposals only. No live project data is modified.
-- Apply this migration only after reviewing it in Supabase.
create table if not exists public.jarvis_project_proposals (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  requested_by uuid not null default auth.uid(),
  instruction text not null,
  changes jsonb not null check (jsonb_typeof(changes) = 'array'),
  status text not null default 'draft' check (status in ('draft','approved','rejected','applied')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid,
  applied_at timestamptz,
  constraint nonempty_changes check (jsonb_array_length(changes) > 0)
);
create index if not exists jarvis_project_proposals_project_created_idx
 on public.jarvis_project_proposals(project_id, created_at desc);
alter table public.jarvis_project_proposals enable row level security;
drop policy if exists jarvis_owner_read on public.jarvis_project_proposals;
create policy jarvis_owner_read on public.jarvis_project_proposals
 for select to authenticated using (public.is_owner_or_admin());
drop policy if exists jarvis_owner_insert on public.jarvis_project_proposals;
create policy jarvis_owner_insert on public.jarvis_project_proposals
 for insert to authenticated
 with check (public.is_owner_or_admin() and requested_by = auth.uid() and status = 'draft'
 and reviewed_at is null and reviewed_by is null and applied_at is null);
-- Do not grant client-side update/delete access. Approval/application will require
-- a separate owner-checked RPC that validates allowed fields, stale values,
-- and applies changes in one transaction. No generic dynamic SQL.
