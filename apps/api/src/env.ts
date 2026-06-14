import "dotenv/config";

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}

export const env = {
  DATABASE_URL: required("DATABASE_URL"),
  JWT_SECRET: required("JWT_SECRET"),
  JWT_EXPIRES_IN: process.env.JWT_EXPIRES_IN ?? "12h",
  WEB_ORIGIN: process.env.WEB_ORIGIN ?? "*",
  PORT: parseInt(process.env.PORT ?? "10000", 10),
  SEED_SUPERADMIN_PASSWORD: process.env.SEED_SUPERADMIN_PASSWORD ?? "changeme123",
};

export const PLATFORM_TENANT = "00000000-0000-0000-0000-000000000000";
