import type { Request, Response, NextFunction } from "express";
import jwt from "jsonwebtoken";
import { env } from "../env";
import { forTenant } from "../db/prisma";
import { can } from "../lib/rbac";
import type { AuthContext } from "./types";

/** Verifies the JWT, attaches req.auth and a tenant-scoped req.db. */
export function requireAuth(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing bearer token" });
  }
  try {
    const payload = jwt.verify(header.slice(7), env.JWT_SECRET) as AuthContext;
    req.auth = payload;
    // Tenant context is derived from the verified token, never from the client.
    req.db = forTenant(payload.tenantId, payload.isSuperAdmin);
    next();
  } catch {
    return res.status(401).json({ error: "Invalid or expired token" });
  }
}

/** Guards a route by permission key. Use after requireAuth. */
export function requirePermission(permission: string) {
  return (req: Request, res: Response, next: NextFunction) => {
    if (!req.auth) return res.status(401).json({ error: "Not authenticated" });
    if (!can(req.auth.permissions, permission)) {
      return res.status(403).json({ error: `Requires permission: ${permission}` });
    }
    next();
  };
}

/** Restricts a route to WH Now super admins. */
export function requireSuperAdmin(req: Request, res: Response, next: NextFunction) {
  if (!req.auth?.isSuperAdmin) {
    return res.status(403).json({ error: "Super admin only" });
  }
  next();
}
