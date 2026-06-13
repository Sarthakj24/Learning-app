# CLAUDE.md — project context for Claude Code

WH Now Learn: a multi-tenant warehouse training & competency LMS. Internal use across WH Now warehouses **and** sold as white-labelled SaaS to clients (each client = one tenant).

## Layout
- `apps/api` — Express + Prisma + PostgreSQL (TypeScript, CommonJS).
- `apps/web` — React + Vite (TypeScript).
- `render.yaml` — Render Blueprint.

## Non-negotiable rules
1. **Tenant isolation is enforced by PostgreSQL Row-Level Security**, not by app code. Every tenant-scoped table has `tenant_id` and an RLS policy. The SQL (tables + policies) is `apps/api/prisma/migrations/0001_init/migration.sql`.
2. **Always query tenant data through `req.db`** (the tenant-scoped client from `forTenant` in `src/db/prisma.ts`), never the bare `prisma` client. The bare client has no tenant context → RLS returns nothing.
3. **Never connect the app as a Postgres superuser.** Superusers bypass RLS. The schema uses `FORCE ROW LEVEL SECURITY` so even the table owner is constrained.
4. When adding a **new tenant-scoped table**, add its `tenant_id` column AND an RLS policy in the same migration (follow the Pattern A / Pattern B blocks at the bottom of the migration SQL). Global-readable content (modules, categories, etc.) uses Pattern B (own tenant + platform tenant).
5. **Permissions** are defined in `src/lib/rbac.config.json` and seeded into the DB. Guard routes with `requirePermission('<key>')` after `requireAuth`. Add new permission keys to the config, not inline.
6. The reserved **platform tenant** `00000000-0000-0000-0000-000000000000` owns the GLOBAL master library.

## Common tasks
- New endpoint: add a route in `src/routes/api.routes.ts`, guard it, use `req.db`.
- New model: edit `prisma/schema.prisma` to match, add a migration with table + RLS, run `prisma generate`.
- New permission: add to `rbac.config.json` (catalog + the relevant base role), re-run seed.
- Run checks: `npm run typecheck` (api), `npm run build` (web).

## Roadmap (extend in this order)
Content authoring + versioning → assignment engine → assessments → practical sign-off → certificates → skills/gap analysis → dashboards → notifications → AI features (question-gen, translation, tutor) behind a flag.
