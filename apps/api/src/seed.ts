import bcrypt from "bcryptjs";
import { forTenant } from "./db/prisma";
import { PLATFORM_TENANT, env } from "./env";
import {
  ALL_PERMISSIONS,
  permissionsForBaseRole,
  type BaseRole,
} from "./lib/rbac";

// Super-admin-scoped client: RLS WITH CHECK lets it write to any tenant.
const db = forTenant(PLATFORM_TENANT, true);

async function ensurePermissions() {
  for (const p of ALL_PERMISSIONS) {
    await db.permissions.upsert({
      where: { key: p.key },
      update: { description: p.description },
      create: { key: p.key, description: p.description },
    });
  }
}

async function ensureRole(tenantId: string, name: string, baseRole: BaseRole) {
  const role = await db.roles.upsert({
    where: { tenant_id_name: { tenant_id: tenantId, name } },
    update: { base_role: baseRole },
    create: { tenant_id: tenantId, name, base_role: baseRole, is_template: tenantId === PLATFORM_TENANT },
  });
  // reset + attach permissions for this base role
  await db.role_permissions.deleteMany({ where: { role_id: role.id } });
  const perms = permissionsForBaseRole(baseRole);
  await db.role_permissions.createMany({
    data: perms.map((permission_key) => ({ role_id: role.id, permission_key })),
    skipDuplicates: true,
  });
  return role;
}

async function ensureUser(
  tenantId: string,
  email: string,
  fullName: string,
  roleId: string,
  password: string,
) {
  const user = await db.users.upsert({
    where: { tenant_id_email: { tenant_id: tenantId, email } },
    update: { full_name: fullName, status: "active" },
    create: {
      tenant_id: tenantId,
      email,
      full_name: fullName,
      status: "active",
      password_hash: bcrypt.hashSync(password, 10),
    },
  });
  const existing = await db.user_roles.findFirst({ where: { user_id: user.id, role_id: roleId } });
  if (!existing) {
    await db.user_roles.create({ data: { tenant_id: tenantId, user_id: user.id, role_id: roleId } });
  }
  return user;
}

async function main() {
  const pwd = env.SEED_SUPERADMIN_PASSWORD;
  await ensurePermissions();

  // --- Platform: super admin ---
  const superRole = await ensureRole(PLATFORM_TENANT, "Super Admin", "super_admin");
  await ensureUser(PLATFORM_TENANT, "admin@whnow.in", "WH Now Admin", superRole.id, pwd);

  // A GLOBAL master-library module owned by the platform tenant
  const globalModule = await db.modules.findFirst({
    where: { tenant_id: PLATFORM_TENANT, title: "Forklift Safety & Pre-use Check" },
  });
  if (!globalModule) {
    await db.modules.create({
      data: { tenant_id: PLATFORM_TENANT, title: "Forklift Safety & Pre-use Check",
        scope: "GLOBAL", status: "published", loop: "closed" },
    });
  }

  // --- Demo client tenant ---
  const acme = await db.tenants.upsert({
    where: { slug: "acme" },
    update: { name: "Acme Logistics", status: "active" },
    create: { name: "Acme Logistics", slug: "acme", status: "active" },
  });

  const adminRole = await ensureRole(acme.id, "Client Admin", "client_admin");
  const managerRole = await ensureRole(acme.id, "Warehouse Manager", "manager");
  const userRole = await ensureRole(acme.id, "Operator", "user");

  await ensureUser(acme.id, "admin@acme.in", "Rhea Kapoor", adminRole.id, pwd);
  await ensureUser(acme.id, "manager@acme.in", "Rahul K.", managerRole.id, pwd);
  await ensureUser(acme.id, "operator@acme.in", "Imran A.", userRole.id, pwd);

  for (const name of ["Bhiwandi Hub", "Sriperumbudur", "Mysuru DC"]) {
    const exists = await db.locations.findFirst({ where: { tenant_id: acme.id, name } });
    if (!exists) await db.locations.create({ data: { tenant_id: acme.id, name } });
  }

  const acmeModule = await db.modules.findFirst({
    where: { tenant_id: acme.id, title: "Acme Dock Safety SOP" },
  });
  if (!acmeModule) {
    await db.modules.create({
      data: { tenant_id: acme.id, title: "Acme Dock Safety SOP", scope: "TENANT",
        status: "published", loop: "closed" },
    });
  }

  console.log("Seed complete.");
  console.log(`  Super admin : workspace=platform  email=admin@whnow.in  pwd=${pwd}`);
  console.log(`  Client admin: workspace=acme      email=admin@acme.in   pwd=${pwd}`);
  console.log(`  Manager     : workspace=acme      email=manager@acme.in pwd=${pwd}`);
  console.log(`  Operator    : workspace=acme      email=operator@acme.in pwd=${pwd}`);
}

main()
  .catch((e) => { console.error(e); process.exit(1); })
  .finally(async () => { await (await import("./db/prisma")).prisma.$disconnect(); });
