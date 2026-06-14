import { Router } from "express";
import bcrypt from "bcryptjs";
import jwt from "jsonwebtoken";
import { z } from "zod";
import { forTenant } from "../db/prisma";
import { env, PLATFORM_TENANT } from "../env";
import { requireAuth } from "../middleware/auth";
import type { AuthContext } from "../middleware/types";

export const authRouter = Router();

const loginSchema = z.object({
  workspace: z.string().min(1), // tenant slug
  email: z.string().min(1),
  password: z.string().min(1),
});

/**
 * Login is a trusted server operation, so it looks up the tenant + user with a
 * super-admin-scoped client (the only way to read across tenants before we know
 * which tenant the caller belongs to). Nothing here is driven by client-supplied
 * tenant ids — only the verified slug/email/password.
 */
authRouter.post("/login", async (req, res) => {
  const parsed = loginSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: "Invalid request" });
  const { workspace, email, password } = parsed.data;

  const lookup = forTenant(PLATFORM_TENANT, true);

  const tenant = await lookup.tenants.findUnique({ where: { slug: workspace } });
  if (!tenant) return res.status(401).json({ error: "Invalid credentials" });

  const user = await lookup.users.findFirst({
    where: { tenant_id: tenant.id, email },
    include: {
      user_roles: { include: { roles: { include: { role_permissions: true } } } },
    },
  });
  if (!user || !user.password_hash || user.status === "disabled") {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  const ok = await bcrypt.compare(password, user.password_hash);
  if (!ok) return res.status(401).json({ error: "Invalid credentials" });

  const permissions = new Set<string>();
  let isSuperAdmin = false;
  for (const ur of user.user_roles) {
    if (ur.roles.base_role === "super_admin") isSuperAdmin = true;
    for (const rp of ur.roles.role_permissions) permissions.add(rp.permission_key);
  }

  const payload: AuthContext = {
    userId: user.id,
    tenantId: user.tenant_id,
    isSuperAdmin,
    permissions: [...permissions],
  };
  const token = jwt.sign(payload, env.JWT_SECRET, { expiresIn: env.JWT_EXPIRES_IN as any });

  await lookup.users.update({
    where: { id: user.id },
    data: { last_login_at: new Date() },
  });

  res.json({
    token,
    user: {
      id: user.id,
      fullName: user.full_name,
      email: user.email,
      tenant: { id: tenant.id, name: tenant.name, slug: tenant.slug },
      isSuperAdmin,
      permissions: payload.permissions,
    },
  });
});

authRouter.get("/me", requireAuth, async (req, res) => {
  const me = await req.db!.users.findUnique({
    where: { id: req.auth!.userId },
    select: { id: true, full_name: true, email: true, language: true },
  });
  res.json({ ...req.auth, profile: me });
});
