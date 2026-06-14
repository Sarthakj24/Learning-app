import rbac from "./rbac.config.json";

export type BaseRole = "super_admin" | "client_admin" | "manager" | "user";

interface RoleDef {
  label: string;
  level: number;
  scope: string;
  permissions: string[];
  optionalGrants?: { permissions: string[] };
}

const baseRoles = rbac.baseRoles as Record<BaseRole, RoleDef>;

export const ALL_PERMISSIONS: { key: string; description: string }[] =
  rbac.permissions;

/** Permissions granted by a base role ('*' expands to every permission). */
export function permissionsForBaseRole(role: BaseRole): string[] {
  const def = baseRoles[role];
  if (!def) return [];
  if (def.permissions.includes("*")) {
    return ALL_PERMISSIONS.map((p) => p.key);
  }
  return def.permissions;
}

/** True if the permission set satisfies the required permission. */
export function can(perms: string[], permission: string): boolean {
  return perms.includes("*") || perms.includes(permission);
}

export const RBAC = rbac;
