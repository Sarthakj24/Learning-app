-- =====================================================================
-- WH Now Learn — PostgreSQL Schema (multi-tenant LMS)
-- =====================================================================
-- Tenancy model: single shared database. Every tenant-scoped row carries
-- tenant_id. Tenant isolation is enforced by Row-Level Security (RLS),
-- NOT by application code alone.
--
-- GLOBAL (WH Now master library) content is owned by a reserved
-- "platform tenant" with the fixed UUID below. Every tenant can READ
-- platform-tenant content and FORK it (insert a tenant-local copy that
-- references the original via forked_from_*).
--
-- The application must connect as a NON-superuser role (app_user) that
-- does NOT bypass RLS, and must set these session GUCs on every request
-- AFTER authentication:
--   SET app.current_tenant   = '<tenant uuid>';
--   SET app.is_super_admin   = 'true' | 'false';
-- (Use SET LOCAL inside a transaction per request, or a pooled-connection
--  reset hook. Never trust client-supplied tenant ids — derive from the JWT.)
--
-- Reserved platform tenant id: 00000000-0000-0000-0000-000000000000
-- =====================================================================


CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;     -- case-insensitive email

-- ---------------------------------------------------------------------
-- Helper schema + session accessors used by RLS policies
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS app;

CREATE OR REPLACE FUNCTION app.current_tenant() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.current_tenant', true), '')::uuid;
$$;

CREATE OR REPLACE FUNCTION app.is_super_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(current_setting('app.is_super_admin', true), 'false') = 'true';
$$;

CREATE OR REPLACE FUNCTION app.platform_tenant() RETURNS uuid
LANGUAGE sql IMMUTABLE AS $$
  SELECT '00000000-0000-0000-0000-000000000000'::uuid;
$$;

-- updated_at trigger
CREATE OR REPLACE FUNCTION app.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

-- =====================================================================
-- ENUMS
-- =====================================================================
CREATE TYPE tenant_status      AS ENUM ('active','suspended','trial','cancelled');
CREATE TYPE user_status        AS ENUM ('invited','active','disabled');
CREATE TYPE system_role        AS ENUM ('super_admin','client_admin','manager','user');
CREATE TYPE content_scope      AS ENUM ('GLOBAL','TENANT','LOCATION','ROLE','DEPARTMENT');
CREATE TYPE content_status     AS ENUM ('draft','in_review','approved','published','archived');
CREATE TYPE loop_type          AS ENUM ('open','closed');
CREATE TYPE lesson_type        AS ENUM ('text','image','video','pdf','audio','interactive');
CREATE TYPE tag_type           AS ENUM ('client','location','product','software','role','skill','general');
CREATE TYPE assignment_target  AS ENUM ('user','role','department','location','tenant');
CREATE TYPE assignable_type    AS ENUM ('module','course');
CREATE TYPE recurrence_type    AS ENUM ('none','monthly','quarterly','half_yearly','annual');
CREATE TYPE enrollment_status  AS ENUM ('assigned','in_progress','completed','expired','waived');
CREATE TYPE question_type      AS ENUM ('single','multi','boolean','image','scenario','ordering');
CREATE TYPE proficiency_level  AS ENUM ('aware','capable','proficient','expert');
CREATE TYPE signoff_result     AS ENUM ('pass','fail');
CREATE TYPE cert_status        AS ENUM ('active','expired','revoked');
CREATE TYPE notif_channel      AS ENUM ('in_app','email','whatsapp');
CREATE TYPE notif_status       AS ENUM ('pending','sent','failed','read');

-- =====================================================================
-- TENANCY & BILLING
-- =====================================================================
CREATE TABLE plans (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  features      jsonb NOT NULL DEFAULT '{}',   -- { ai:true, white_label:true, api:false ... }
  seat_model    text NOT NULL DEFAULT 'per_seat', -- per_seat | per_location | flat
  price_minor   integer,                        -- price in paise; null = custom
  currency      char(3) NOT NULL DEFAULT 'INR',
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE tenants (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  slug          citext UNIQUE NOT NULL,         -- subdomain
  status        tenant_status NOT NULL DEFAULT 'trial',
  is_platform   boolean NOT NULL DEFAULT false, -- true only for the reserved platform tenant
  branding      jsonb NOT NULL DEFAULT '{}',    -- { logo_url, primary_color, email_sender ... }
  settings      jsonb NOT NULL DEFAULT '{}',    -- { default_language, enabled_languages[] ... }
  plan_id       uuid REFERENCES plans(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_tenants_updated BEFORE UPDATE ON tenants
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE TABLE subscriptions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  plan_id       uuid NOT NULL REFERENCES plans(id),
  status        text NOT NULL DEFAULT 'active',  -- active | past_due | cancelled
  seats         integer NOT NULL DEFAULT 0,
  period_start  date,
  period_end    date,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_subscriptions_tenant ON subscriptions(tenant_id);

-- =====================================================================
-- ORG STRUCTURE
-- =====================================================================
CREATE TABLE locations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name          text NOT NULL,
  code          text,
  address       jsonb,
  parent_id     uuid REFERENCES locations(id),
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_locations_tenant ON locations(tenant_id);

CREATE TABLE departments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name          text NOT NULL,
  location_id   uuid REFERENCES locations(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_departments_tenant ON departments(tenant_id);

-- =====================================================================
-- IDENTITY & RBAC
-- =====================================================================
CREATE TABLE users (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  email           citext,
  phone           text,
  password_hash   text,
  full_name       text NOT NULL,
  status          user_status NOT NULL DEFAULT 'invited',
  language        text NOT NULL DEFAULT 'en',
  default_location_id uuid REFERENCES locations(id),
  department_id   uuid REFERENCES departments(id),
  last_login_at   timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, email)
);
CREATE INDEX idx_users_tenant ON users(tenant_id);
CREATE TRIGGER trg_users_updated BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- Static permission catalog (no tenant; seeded from rbac.config.json)
CREATE TABLE permissions (
  key         text PRIMARY KEY,             -- e.g. 'content.publish'
  description text NOT NULL
);

-- Roles: platform-tenant rows act as global templates; tenants clone them.
CREATE TABLE roles (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name          text NOT NULL,
  base_role     system_role NOT NULL DEFAULT 'user', -- baseline level for permission seeding
  is_template   boolean NOT NULL DEFAULT false,
  description   text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, name)
);
CREATE INDEX idx_roles_tenant ON roles(tenant_id);

CREATE TABLE role_permissions (
  role_id        uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  permission_key text NOT NULL REFERENCES permissions(key) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_key)
);

-- A user holds a role, optionally scoped to a location/department
-- (e.g. a Manager whose authority covers only certain warehouses).
CREATE TABLE user_roles (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id       uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  location_id   uuid REFERENCES locations(id),     -- null = tenant-wide
  department_id uuid REFERENCES departments(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_user_roles_user ON user_roles(user_id);
CREATE INDEX idx_user_roles_tenant ON user_roles(tenant_id);

-- =====================================================================
-- TAXONOMY
-- =====================================================================
CREATE TABLE categories (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE, -- platform tenant = global
  parent_id     uuid REFERENCES categories(id),
  name          text NOT NULL,
  slug          text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, parent_id, slug)
);
CREATE INDEX idx_categories_tenant ON categories(tenant_id);

CREATE TABLE tags (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name          text NOT NULL,
  type          tag_type NOT NULL DEFAULT 'general',
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, type, name)
);
CREATE INDEX idx_tags_tenant ON tags(tenant_id);

-- =====================================================================
-- CONTENT: MODULES, VERSIONS, LESSONS, COURSES
-- =====================================================================
CREATE TABLE modules (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE, -- platform tenant = GLOBAL
  scope                 content_scope NOT NULL DEFAULT 'TENANT',
  category_id           uuid REFERENCES categories(id),
  title                 text NOT NULL,
  description           text,
  language              text NOT NULL DEFAULT 'en',
  loop                  loop_type NOT NULL DEFAULT 'closed',
  status                content_status NOT NULL DEFAULT 'draft',
  current_version_id    uuid,                 -- FK added after module_versions exists
  forked_from_module_id uuid REFERENCES modules(id),
  forked_from_version_id uuid,
  created_by            uuid REFERENCES users(id),
  approved_by           uuid REFERENCES users(id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_modules_tenant ON modules(tenant_id);
CREATE INDEX idx_modules_category ON modules(category_id);
CREATE TRIGGER trg_modules_updated BEFORE UPDATE ON modules
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- Immutable published snapshots. Editing a published module = new version.
CREATE TABLE module_versions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  module_id          uuid NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
  version_no         integer NOT NULL,
  status             content_status NOT NULL DEFAULT 'draft',
  is_material_change boolean NOT NULL DEFAULT false, -- triggers re-acknowledgment/re-cert
  change_note        text,
  published_at       timestamptz,
  published_by       uuid REFERENCES users(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (module_id, version_no)
);
CREATE INDEX idx_module_versions_tenant ON module_versions(tenant_id);
ALTER TABLE modules
  ADD CONSTRAINT fk_modules_current_version
  FOREIGN KEY (current_version_id) REFERENCES module_versions(id);

CREATE TABLE lessons (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  module_version_id uuid NOT NULL REFERENCES module_versions(id) ON DELETE CASCADE,
  order_index       integer NOT NULL DEFAULT 0,
  type              lesson_type NOT NULL DEFAULT 'text',
  title             text,
  body              jsonb,                  -- rich content / interactive payload
  media_url         text,
  language          text NOT NULL DEFAULT 'en',
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_lessons_version ON lessons(module_version_id);
CREATE INDEX idx_lessons_tenant ON lessons(tenant_id);

CREATE TABLE module_tags (
  module_id uuid NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
  tag_id    uuid NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY (module_id, tag_id)
);

CREATE TABLE courses (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  scope       content_scope NOT NULL DEFAULT 'TENANT',
  title       text NOT NULL,
  description text,
  status      content_status NOT NULL DEFAULT 'draft',
  created_by  uuid REFERENCES users(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_courses_tenant ON courses(tenant_id);

CREATE TABLE course_modules (
  course_id      uuid NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
  module_id      uuid NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
  order_index    integer NOT NULL DEFAULT 0,
  is_prerequisite boolean NOT NULL DEFAULT false,
  due_offset_days integer,
  PRIMARY KEY (course_id, module_id)
);

-- =====================================================================
-- SKILLS & COMPETENCY
-- =====================================================================
CREATE TABLE skills (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE, -- platform tenant = global
  name        text NOT NULL,
  description text,
  category_id uuid REFERENCES categories(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, name)
);
CREATE INDEX idx_skills_tenant ON skills(tenant_id);

CREATE TABLE module_skills (
  module_id   uuid NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
  skill_id    uuid NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
  grants_level proficiency_level NOT NULL DEFAULT 'capable',
  PRIMARY KEY (module_id, skill_id)
);

CREATE TABLE role_skill_requirements (
  role_id        uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  skill_id       uuid NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
  required_level proficiency_level NOT NULL DEFAULT 'capable',
  PRIMARY KEY (role_id, skill_id)
);

CREATE TABLE user_skills (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  skill_id    uuid NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
  level       proficiency_level NOT NULL,
  earned_from_version_id uuid REFERENCES module_versions(id),
  earned_at   timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz,
  UNIQUE (user_id, skill_id)
);
CREATE INDEX idx_user_skills_tenant ON user_skills(tenant_id);
CREATE INDEX idx_user_skills_user ON user_skills(user_id);

-- =====================================================================
-- ASSIGNMENT ENGINE
-- =====================================================================
CREATE TABLE assignments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  target_type     assignment_target NOT NULL,
  target_id       uuid,                       -- null when target_type = 'tenant'
  assignable_type assignable_type NOT NULL,
  assignable_id   uuid NOT NULL,
  due_date        date,
  is_mandatory    boolean NOT NULL DEFAULT true,
  recurrence      recurrence_type NOT NULL DEFAULT 'none',
  assigned_by     uuid REFERENCES users(id),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_assignments_tenant ON assignments(tenant_id);

CREATE TABLE assignment_rules (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name            text NOT NULL,
  conditions      jsonb NOT NULL,             -- { role_id, location_id, department_id ... }
  assignable_type assignable_type NOT NULL,
  assignable_id   uuid NOT NULL,
  due_offset_days integer,
  is_mandatory    boolean NOT NULL DEFAULT true,
  recurrence      recurrence_type NOT NULL DEFAULT 'none',
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_assignment_rules_tenant ON assignment_rules(tenant_id);

-- Materialized per-user instance that dashboards read.
CREATE TABLE enrollments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  module_id         uuid NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
  module_version_id uuid REFERENCES module_versions(id),  -- locked at enrollment
  course_id         uuid REFERENCES courses(id),
  status            enrollment_status NOT NULL DEFAULT 'assigned',
  loop              loop_type NOT NULL DEFAULT 'closed',
  due_date          date,
  source_assignment_id uuid REFERENCES assignments(id),
  started_at        timestamptz,
  completed_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, module_id, course_id)
);
CREATE INDEX idx_enrollments_tenant ON enrollments(tenant_id);
CREATE INDEX idx_enrollments_user ON enrollments(user_id);
CREATE INDEX idx_enrollments_status ON enrollments(tenant_id, status);

-- =====================================================================
-- ASSESSMENTS
-- =====================================================================
CREATE TABLE assessments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  module_id        uuid NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
  pass_threshold   integer NOT NULL DEFAULT 70,  -- percent
  num_questions    integer NOT NULL DEFAULT 8,   -- drawn from bank
  time_limit_secs  integer,
  shuffle          boolean NOT NULL DEFAULT true,
  required_for_cert boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_assessments_tenant ON assessments(tenant_id);

CREATE TABLE questions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  assessment_id uuid NOT NULL REFERENCES assessments(id) ON DELETE CASCADE,
  type          question_type NOT NULL DEFAULT 'single',
  prompt        text NOT NULL,
  media_url     text,
  explanation   text,
  difficulty    integer NOT NULL DEFAULT 2,   -- 1..5
  is_active     boolean NOT NULL DEFAULT true,
  ai_generated  boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_questions_assessment ON questions(assessment_id);
CREATE INDEX idx_questions_tenant ON questions(tenant_id);

CREATE TABLE question_options (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id uuid NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
  text        text NOT NULL,
  is_correct  boolean NOT NULL DEFAULT false,
  order_index integer NOT NULL DEFAULT 0
);
CREATE INDEX idx_question_options_q ON question_options(question_id);

CREATE TABLE attempts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  assessment_id uuid NOT NULL REFERENCES assessments(id) ON DELETE CASCADE,
  enrollment_id uuid REFERENCES enrollments(id) ON DELETE SET NULL,
  score         integer,                      -- percent
  passed        boolean,
  answers       jsonb,                        -- { question_id: [option_ids] }
  started_at    timestamptz NOT NULL DEFAULT now(),
  submitted_at  timestamptz
);
CREATE INDEX idx_attempts_user ON attempts(user_id);
CREATE INDEX idx_attempts_tenant ON attempts(tenant_id);

-- =====================================================================
-- PRACTICAL SIGN-OFF
-- =====================================================================
CREATE TABLE practical_checklists (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  module_id   uuid REFERENCES modules(id) ON DELETE CASCADE,
  skill_id    uuid REFERENCES skills(id) ON DELETE CASCADE,
  title       text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_pchecklists_tenant ON practical_checklists(tenant_id);

CREATE TABLE practical_checklist_items (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  checklist_id uuid NOT NULL REFERENCES practical_checklists(id) ON DELETE CASCADE,
  text         text NOT NULL,
  order_index  integer NOT NULL DEFAULT 0
);

CREATE TABLE practical_signoffs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,    -- the learner
  checklist_id  uuid NOT NULL REFERENCES practical_checklists(id),
  enrollment_id uuid REFERENCES enrollments(id) ON DELETE SET NULL,
  signed_by     uuid NOT NULL REFERENCES users(id),                       -- the supervisor
  result        signoff_result NOT NULL,
  item_results  jsonb,                        -- { item_id: pass|fail }
  photo_url     text,
  notes         text,
  signed_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_signoffs_user ON practical_signoffs(user_id);
CREATE INDEX idx_signoffs_tenant ON practical_signoffs(tenant_id);

-- =====================================================================
-- CERTIFICATES, ACKNOWLEDGMENTS
-- =====================================================================
CREATE TABLE certificates (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  module_id         uuid REFERENCES modules(id),
  course_id         uuid REFERENCES courses(id),
  module_version_id uuid REFERENCES module_versions(id),
  enrollment_id     uuid REFERENCES enrollments(id),
  grade_band        text,                     -- e.g. 'Distinction','Pass'
  score             integer,
  verify_code       text UNIQUE NOT NULL,     -- short public code for verify URL
  hash              text NOT NULL,            -- tamper-evidence
  pdf_url           text,
  status            cert_status NOT NULL DEFAULT 'active',
  issued_at         timestamptz NOT NULL DEFAULT now(),
  expires_at        timestamptz
);
CREATE INDEX idx_certs_tenant ON certificates(tenant_id);
CREATE INDEX idx_certs_user ON certificates(user_id);

CREATE TABLE acknowledgments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  module_version_id uuid NOT NULL REFERENCES module_versions(id),
  statement_text    text NOT NULL,            -- "I have read and understood SOP vX"
  ip                inet,
  acknowledged_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, module_version_id)
);
CREATE INDEX idx_ack_tenant ON acknowledgments(tenant_id);

-- =====================================================================
-- NOTIFICATIONS & AUDIT
-- =====================================================================
CREATE TABLE notifications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type        text NOT NULL,                  -- assignment_due | cert_expiring | ...
  payload     jsonb NOT NULL DEFAULT '{}',
  channel     notif_channel NOT NULL DEFAULT 'in_app',
  status      notif_status NOT NULL DEFAULT 'pending',
  sent_at     timestamptz,
  read_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_notifications_user ON notifications(user_id, status);

-- Append-only. tenant_id may be platform tenant for platform-level actions.
CREATE TABLE audit_logs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  actor_user_id uuid REFERENCES users(id),
  action        text NOT NULL,               -- 'module.publish','user.disable', ...
  entity_type   text,
  entity_id     uuid,
  metadata      jsonb NOT NULL DEFAULT '{}',
  ip            inet,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_tenant ON audit_logs(tenant_id, created_at);

-- =====================================================================
-- ROW-LEVEL SECURITY
-- =====================================================================
-- Pattern A (pure tenant isolation): own tenant only (+ super admin bypass).
-- Pattern B (global-readable content): own tenant OR platform tenant for
--   reads; writes restricted to own tenant. Used for the master library.
--
-- All policies are PERMISSIVE; multiple permissive policies on the same
-- command are OR-combined.

-- ---- Pattern A tables ----
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'subscriptions','locations','departments','users','user_roles',
    'user_skills','assignments','assignment_rules','enrollments',
    'assessments','questions','attempts','practical_checklists',
    'practical_signoffs','certificates','acknowledgments',
    'notifications','audit_logs'
  ]
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY;', t);
    EXECUTE format($f$
      CREATE POLICY tenant_isolation ON %I
        USING (app.is_super_admin() OR tenant_id = app.current_tenant())
        WITH CHECK (app.is_super_admin() OR tenant_id = app.current_tenant());
    $f$, t);
  END LOOP;
END $$;

-- ---- Pattern B tables (global-readable master library) ----
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'categories','tags','roles','modules','module_versions','lessons',
    'courses','skills'
  ]
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY;', t);
    -- read: own tenant + platform (global) library
    EXECUTE format($f$
      CREATE POLICY read_own_and_global ON %I FOR SELECT
        USING (app.is_super_admin()
               OR tenant_id IN (app.current_tenant(), app.platform_tenant()));
    $f$, t);
    -- write: own tenant only (forking creates a tenant-local copy)
    EXECUTE format($f$
      CREATE POLICY write_own ON %I FOR INSERT
        WITH CHECK (app.is_super_admin() OR tenant_id = app.current_tenant());
    $f$, t);
    EXECUTE format($f$
      CREATE POLICY update_own ON %I FOR UPDATE
        USING (app.is_super_admin() OR tenant_id = app.current_tenant())
        WITH CHECK (app.is_super_admin() OR tenant_id = app.current_tenant());
    $f$, t);
    EXECUTE format($f$
      CREATE POLICY delete_own ON %I FOR DELETE
        USING (app.is_super_admin() OR tenant_id = app.current_tenant());
    $f$, t);
  END LOOP;
END $$;

-- tenants table: a tenant sees itself (+ the platform tenant); super sees all.
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_self_select ON tenants FOR SELECT
  USING (app.is_super_admin()
         OR id IN (app.current_tenant(), app.platform_tenant()));
CREATE POLICY tenant_self_update ON tenants FOR UPDATE
  USING (app.is_super_admin() OR id = app.current_tenant())
  WITH CHECK (app.is_super_admin() OR id = app.current_tenant());
CREATE POLICY tenant_super_insert ON tenants FOR INSERT
  WITH CHECK (app.is_super_admin());
CREATE POLICY tenant_super_delete ON tenants FOR DELETE
  USING (app.is_super_admin());

-- Association/lookup tables without tenant_id rely on their parent's RLS
-- (role_permissions, module_tags, course_modules, module_skills,
--  role_skill_requirements, question_options, practical_checklist_items).
-- 'permissions' and 'plans' are non-tenant catalogs: readable by all,
-- writable only by super admin.
ALTER TABLE plans ENABLE ROW LEVEL SECURITY;
CREATE POLICY plans_read ON plans FOR SELECT USING (true);
CREATE POLICY plans_write ON plans FOR ALL
  USING (app.is_super_admin()) WITH CHECK (app.is_super_admin());

-- =====================================================================
-- APPLICATION DB ROLE (must NOT bypass RLS)
-- =====================================================================
-- Run once by a superuser; the app connects as app_user.
--   CREATE ROLE app_user LOGIN PASSWORD '...' NOSUPERUSER NOBYPASSRLS;
--   GRANT USAGE ON SCHEMA app, public TO app_user;
--   GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
--   ALTER DEFAULT PRIVILEGES IN SCHEMA public
--     GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;

-- =====================================================================
-- SEED: reserved platform tenant (owns the GLOBAL master library)
-- =====================================================================
INSERT INTO tenants (id, name, slug, status, is_platform)
VALUES ('00000000-0000-0000-0000-000000000000','WH Now Platform','platform','active',true)
ON CONFLICT (id) DO NOTHING;


-- =====================================================================
-- USAGE NOTE — per-request session setup (application side):
--   BEGIN;
--     SET LOCAL app.current_tenant = '<tenant-uuid-from-jwt>';
--     SET LOCAL app.is_super_admin = 'false';
--     -- ... queries ...
--   COMMIT;
-- For super-admin impersonation, set is_super_admin = 'true' AND log it
-- to audit_logs (action='impersonate').
-- =====================================================================
