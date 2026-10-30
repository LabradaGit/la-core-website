# Jarvis Project Assistant — pre-deployment checklist

**Status:** Development branch only. Not deployed or validated against production Supabase.

## Migration order
1. `20261029_jarvis_project_proposals.sql`
2. `20261029_jarvis_apply_project_proposal.sql`
3. `20261029_jarvis_reject_project_proposal.sql`

## Manual acceptance tests (use disposable test project, authenticated owner)
- Unauthenticated visitor cannot read proposals or invoke either RPC.
- Non-owner authenticated user cannot create/read/apply/reject proposals.
- Owner can stage draft; original project remains unchanged.
- Preview displays exact old/new values, including NULL and decimal contract amounts.
- Owner can reject; proposal becomes rejected, project unchanged; subsequent apply fails.
- Owner can approve; only allowlisted project columns change, and status updates the `active` flag.
- Reapplying same proposal fails and does not change project.
- Change the project after staging; stale proposal must fail atomically.
- Unsupported fields, duplicate fields, invalid status, negative contract amount, invalid date, blank project name all fail without modifying project.
- Verify browser console and Supabase SQL logs; check mobile layout.
- Ensure existing project editor, subcontract allocations, crew payments, and owner sign-in still work.

## Limitations
- This is a structured review form, **not yet** natural-language parsing or ChatGPT-to-Supabase access.
- Existing project table structure is inferred from `owner.html`; verify actual database constraints and column types before applying migrations.
- No service-role keys belong in client-side JavaScript.
- Deploy only after passing tests in a nonproduction Supabase environment.
