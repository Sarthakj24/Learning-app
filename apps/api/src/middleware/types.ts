import type { TenantClient } from "../db/prisma";

export interface AuthContext {
  userId: string;
  tenantId: string;
  isSuperAdmin: boolean;
  permissions: string[];
}

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      auth?: AuthContext;
      db?: TenantClient;
    }
  }
}

export {};
