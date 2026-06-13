import { PrismaClient } from "@prisma/client";
import { PLATFORM_TENANT } from "../env";

/**
 * Single base client (owns the connection pool).
 * Never use this directly for tenant data — use forTenant().
 */
export const prisma = new PrismaClient();

/**
 * Returns a tenant-scoped client. Every operation runs inside a transaction
 * that first sets the Postgres session GUCs RLS reads:
 *   app.current_tenant  -> isolates rows to this tenant (+ global library)
 *   app.is_super_admin   -> bypass for WH Now platform admins
 *
 * set_config(..., is_local => true) keeps the GUC scoped to the transaction,
 * so it cannot leak across pooled connections.
 *
 * NOTE: schema.sql uses FORCE ROW LEVEL SECURITY, so RLS is enforced even for
 * the database owner role that Render provisions — no separate app_user needed,
 * though you may still create a NOBYPASSRLS role for defence in depth.
 */
export function forTenant(tenantId: string, isSuperAdmin = false) {
  return prisma.$extends({
    query: {
      $allModels: {
        async $allOperations({ args, query }) {
          const [, result] = await prisma.$transaction([
            prisma.$executeRaw`
              SELECT
                set_config('app.current_tenant', ${tenantId}, true),
                set_config('app.is_super_admin', ${String(isSuperAdmin)}, true)
            `,
            query(args),
          ]);
          return result;
        },
      },
    },
  });
}

/** Client for reading/writing the GLOBAL master library as WH Now. */
export function forPlatform() {
  return forTenant(PLATFORM_TENANT, true);
}

export type TenantClient = ReturnType<typeof forTenant>;
