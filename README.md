# WH Now Learn

Multi-tenant warehouse training & competency platform. Monorepo:

- `apps/api` — Node/Express + Prisma + PostgreSQL. Tenant isolation enforced by **PostgreSQL Row-Level Security** (not app code alone).
- `apps/web` — React + Vite frontend.
- `render.yaml` — one-click Render Blueprint (database + API + web).

This is a working **MVP skeleton** (auth, multi-tenancy + RLS, RBAC, a few resource endpoints, seed, and a login→dashboard frontend). It maps to Sprint 0–1 of the build plan; extend it from here.

---

## Architecture in one minute

- Every tenant-scoped table has `tenant_id`. RLS policies (in `apps/api/prisma/migrations/0001_init/migration.sql`) restrict every row to the caller's tenant. The WH Now **global library** lives under a reserved "platform tenant" (`00000000-…-0000`) that all tenants can read and fork.
- The API connects, then sets two session variables per request inside a transaction: `app.current_tenant` and `app.is_super_admin`. RLS reads those. See `apps/api/src/db/prisma.ts` (`forTenant`).
- Three enforcement layers: **RLS** (DB) → **RBAC permissions** (`requirePermission`) → **scope** (managers limited to their locations). Permissions live in `apps/api/src/lib/rbac.config.json`.

> **Critical:** the app must connect as a **non-superuser** Postgres role. Superusers bypass RLS. Render's default DB user is non-superuser and the schema uses `FORCE ROW LEVEL SECURITY`, so isolation holds out of the box. See `apps/api/prisma/app_user.sql` for optional hardening.

---

## Run locally

Prerequisites: Node 20+, a local PostgreSQL with the `pgcrypto` and `citext` extensions available (both ship with standard Postgres).

```bash
# 1) API
cd apps/api
cp .env.example .env                # set DATABASE_URL + JWT_SECRET
npm install
npx prisma migrate deploy           # creates tables + RLS policies
npm run seed                        # creates super admin + demo "acme" tenant
npm run dev                         # http://localhost:10000

# 2) Web (new terminal)
cd apps/web
cp .env.example .env                # VITE_API_URL=http://localhost:10000
npm install
npm run dev                         # http://localhost:5173
```

Seeded demo accounts (password = `SEED_SUPERADMIN_PASSWORD`, default `changeme123`):

| Role        | Workspace | Email             |
|-------------|-----------|-------------------|
| Super admin | platform  | admin@whnow.in    |
| Client admin| acme      | admin@acme.in     |
| Manager     | acme      | manager@acme.in   |
| Operator    | acme      | operator@acme.in  |

---

## Push to GitHub

```bash
cd whnow-learn
git init
git add .
git commit -m "WH Now Learn — initial scaffold"
git branch -M main
git remote add origin https://github.com/<your-org>/whnow-learn.git
git push -u origin main
```

---

## Deploy on Render (Blueprint)

1. Push the repo to GitHub (above).
2. In Render: **New + → Blueprint**, pick the repo. Render reads `render.yaml` and provisions the database, the API, and the static web site.
3. Set `SEED_SUPERADMIN_PASSWORD` on the **whnow-learn-api** service (it's marked `sync: false`). `JWT_SECRET` is generated automatically.
4. First deploy runs `prisma migrate deploy` (tables + RLS) → seed → server start. The web build injects the API URL automatically.
5. After it's live, tighten `WEB_ORIGIN` on the API from `*` to your web service URL (e.g. `https://whnow-learn-web.onrender.com`).

Render free Postgres expires after ~90 days — move to a paid plan before production.

---

## What's implemented vs. next

**In:** login + JWT, tenant context + RLS, RBAC permission catalog + guards, super-admin tenant management, locations/users/modules endpoints, idempotent seed, login→dashboard UI.

**Next (per the sprint plan):** content authoring + versioning, assignment engine, assessments, practical sign-off, certificates, skills/gap analysis, dashboards, notifications. Companion design docs: the spec, `schema.prisma`, the RBAC config, the sprint plan, and the wireframes.

---

## Endpoints (current)

| Method | Path | Guard |
|---|---|---|
| GET  | `/health` | — |
| POST | `/auth/login` | — |
| GET  | `/auth/me` | auth |
| GET  | `/api/tenants` | super admin |
| POST | `/api/tenants` | super admin |
| GET  | `/api/locations` | `user.view` |
| POST | `/api/locations` | `location.manage` |
| GET  | `/api/users` | `user.view` |
| GET  | `/api/modules` | `content.view` |
| POST | `/api/modules` | `content.author` |
