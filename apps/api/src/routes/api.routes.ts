import { Router } from "express";
import { z } from "zod";
import { requireAuth, requirePermission, requireSuperAdmin } from "../middleware/auth";

export const apiRouter = Router();
apiRouter.use(requireAuth); // everything below requires a valid token

/* ----------------------------- Tenants (super admin) ----------------------------- */
apiRouter.get("/tenants", requireSuperAdmin, async (req, res) => {
  const tenants = await req.db!.tenants.findMany({
    where: { is_platform: false },
    select: { id: true, name: true, slug: true, status: true, created_at: true,
      _count: { select: { users: true, locations: true } } },
    orderBy: { created_at: "desc" },
  });
  res.json(tenants);
});

const tenantSchema = z.object({ name: z.string().min(1), slug: z.string().min(2) });
apiRouter.post("/tenants", requireSuperAdmin, async (req, res) => {
  const p = tenantSchema.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: "Invalid request" });
  const tenant = await req.db!.tenants.create({ data: { ...p.data, status: "trial" } });
  res.status(201).json(tenant);
});

/* -------------------------------- Locations -------------------------------- */
// RLS scopes results to the caller's tenant automatically.
apiRouter.get("/locations", requirePermission("user.view"), async (req, res) => {
  const locations = await req.db!.locations.findMany({ orderBy: { name: "asc" } });
  res.json(locations);
});

const locationSchema = z.object({ name: z.string().min(1), code: z.string().optional() });
apiRouter.post("/locations", requirePermission("location.manage"), async (req, res) => {
  const p = locationSchema.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: "Invalid request" });
  // tenant_id comes from the token; RLS WITH CHECK rejects any other tenant.
  const loc = await req.db!.locations.create({
    data: { ...p.data, tenant_id: req.auth!.tenantId },
  });
  res.status(201).json(loc);
});

/* ---------------------------------- Users ---------------------------------- */
apiRouter.get("/users", requirePermission("user.view"), async (req, res) => {
  const users = await req.db!.users.findMany({
    select: { id: true, full_name: true, email: true, status: true, last_login_at: true,
      user_roles: { select: { roles: { select: { name: true } } } } },
    orderBy: { full_name: "asc" },
  });
  res.json(users);
});

/* --------------------------------- Modules --------------------------------- */
// Returns the caller's tenant modules PLUS the GLOBAL master library (RLS rule).
apiRouter.get("/modules", requirePermission("content.view"), async (req, res) => {
  const modules = await req.db!.modules.findMany({
    select: { id: true, title: true, scope: true, status: true, language: true, tenant_id: true,
      categories: { select: { name: true } } },
    orderBy: { title: "asc" },
  });
  res.json(modules);
});

const moduleSchema = z.object({
  title: z.string().min(1),
  description: z.string().optional(),
  loop: z.enum(["open", "closed"]).default("closed"),
});
apiRouter.post("/modules", requirePermission("content.author"), async (req, res) => {
  const p = moduleSchema.safeParse(req.body);
  if (!p.success) return res.status(400).json({ error: "Invalid request" });
  const mod = await req.db!.modules.create({
    data: { ...p.data, tenant_id: req.auth!.tenantId, scope: "TENANT", status: "draft",
      created_by: req.auth!.userId },
  });
  res.status(201).json(mod);
});
