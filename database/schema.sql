-- ============================================================
-- DISASTER RELIEF MVP — SUPABASE SCHEMA
-- Flow: Shelter -> Report -> Verification/Priority -> Volunteer
--       -> Assignment -> Route -> Delivery -> Inventory update
-- ============================================================
-- Run this in Supabase SQL Editor (Project > SQL Editor > New query)

-- Needed for gen_random_uuid()
create extension if not exists "pgcrypto";

-- ------------------------------------------------------------
-- ENUM TYPES (keeps status fields consistent, not overbuilt)
-- ------------------------------------------------------------
create type user_role as enum ('admin', 'shelter_manager', 'volunteer', 'reporter');
create type report_status as enum ('pending', 'verified', 'rejected', 'in_progress', 'resolved');
create type priority_level as enum ('low', 'medium', 'high', 'critical');
create type volunteer_status as enum ('available', 'busy', 'offline');
create type assignment_status as enum ('assigned', 'accepted', 'enroute', 'completed', 'cancelled');
create type road_status as enum ('clear', 'blocked', 'partially_blocked', 'unknown');
create type delivery_status as enum ('pending', 'picked_up', 'delivered', 'failed');

-- ------------------------------------------------------------
-- 1. USERS (extends Supabase auth.users)
-- ------------------------------------------------------------
create table users (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  phone text,
  role user_role not null default 'reporter',
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 2. SHELTERS
-- ------------------------------------------------------------
create table shelters (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  latitude double precision,
  longitude double precision,
  capacity int,
  current_occupancy int default 0,
  contact_phone text,
  manager_id uuid references users(id),
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 3. RESOURCES (catalog of resource types: food, water, medicine..)
-- ------------------------------------------------------------
create table resources (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,        -- e.g. "Drinking Water (5L)", "First Aid Kit"
  unit text not null default 'unit' -- e.g. 'liters', 'kg', 'pcs'
);

-- ------------------------------------------------------------
-- 4. REPORTS (need requests coming from a shelter or a reporter)
-- ------------------------------------------------------------
create table reports (
  id uuid primary key default gen_random_uuid(),
  shelter_id uuid references shelters(id) on delete set null,
  reported_by uuid references users(id),
  resource_id uuid references resources(id),
  quantity_needed int,
  description text,
  latitude double precision,
  longitude double precision,
  status report_status not null default 'pending',
  priority priority_level,              -- set during verification step
  verified_by uuid references users(id),
  verified_at timestamptz,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 5. VOLUNTEERS (profile extends users with role='volunteer')
-- ------------------------------------------------------------
create table volunteers (
  id uuid primary key references users(id) on delete cascade,
  vehicle_type text,               -- 'bike', 'car', 'truck', 'on_foot'
  vehicle_capacity int,
  status volunteer_status not null default 'available',
  current_latitude double precision,
  current_longitude double precision,
  updated_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 6. ROAD_REPORTS (route/road condition info, feeds into routing)
-- ------------------------------------------------------------
create table road_reports (
  id uuid primary key default gen_random_uuid(),
  reported_by uuid references users(id),
  latitude double precision not null,
  longitude double precision not null,
  status road_status not null default 'unknown',
  description text,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 7. ASSIGNMENTS (report handed to a volunteer)
-- ------------------------------------------------------------
create table assignments (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references reports(id) on delete cascade,
  volunteer_id uuid references volunteers(id),
  status assignment_status not null default 'assigned',
  assigned_at timestamptz not null default now(),
  accepted_at timestamptz,
  completed_at timestamptz,
  notes text
);

-- ------------------------------------------------------------
-- 8. DELIVERIES (the physical drop-off tied to an assignment)
-- ------------------------------------------------------------
create table deliveries (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references assignments(id) on delete cascade,
  resource_id uuid references resources(id),
  quantity_delivered int,
  status delivery_status not null default 'pending',
  proof_photo_url text,
  delivered_at timestamptz,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 9. INVENTORY (per-shelter stock, updated after delivery)
-- ------------------------------------------------------------
create table inventory (
  id uuid primary key default gen_random_uuid(),
  shelter_id uuid not null references shelters(id) on delete cascade,
  resource_id uuid not null references resources(id),
  quantity int not null default 0,
  updated_at timestamptz not null default now(),
  unique (shelter_id, resource_id)
);

-- ============================================================
-- USEFUL INDEXES (query patterns your APIs will actually hit)
-- ============================================================
create index idx_reports_status on reports(status);
create index idx_reports_priority on reports(priority);
create index idx_reports_shelter on reports(shelter_id);
create index idx_assignments_report on assignments(report_id);
create index idx_assignments_volunteer on assignments(volunteer_id);
create index idx_deliveries_assignment on deliveries(assignment_id);
create index idx_inventory_shelter on inventory(shelter_id);
create index idx_volunteers_status on volunteers(status);

-- ============================================================
-- TRIGGER: auto-update inventory when a delivery is marked 'delivered'
-- (This is the "Delivery -> Inventory update" step of your flow)
-- ============================================================
create or replace function fn_update_inventory_on_delivery()
returns trigger as $$
declare
  v_shelter_id uuid;
begin
  if new.status = 'delivered' and (old.status is distinct from 'delivered') then
    select r.shelter_id into v_shelter_id
    from assignments a
    join reports r on r.id = a.report_id
    where a.id = new.assignment_id;

    if v_shelter_id is not null then
      insert into inventory (shelter_id, resource_id, quantity)
      values (v_shelter_id, new.resource_id, coalesce(new.quantity_delivered, 0))
      on conflict (shelter_id, resource_id)
      do update set
        quantity = inventory.quantity + coalesce(new.quantity_delivered, 0),
        updated_at = now();
    end if;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_delivery_inventory
after update on deliveries
for each row
execute function fn_update_inventory_on_delivery();

-- ============================================================
-- BASIC ROW LEVEL SECURITY (enable now, refine policies later)
-- ============================================================
alter table users enable row level security;
alter table shelters enable row level security;
alter table reports enable row level security;
alter table resources enable row level security;
alter table volunteers enable row level security;
alter table road_reports enable row level security;
alter table assignments enable row level security;
alter table deliveries enable row level security;
alter table inventory enable row level security;

-- MVP-friendly starter policies: any authenticated user can read everything.
-- Tighten per-role (admin/volunteer/shelter_manager) once Member 3's auth is in.
create policy "Authenticated read access" on shelters for select using (auth.role() = 'authenticated');
create policy "Authenticated read access" on reports for select using (auth.role() = 'authenticated');
create policy "Authenticated read access" on resources for select using (auth.role() = 'authenticated');
create policy "Authenticated read access" on volunteers for select using (auth.role() = 'authenticated');
create policy "Authenticated read access" on road_reports for select using (auth.role() = 'authenticated');
create policy "Authenticated read access" on assignments for select using (auth.role() = 'authenticated');
create policy "Authenticated read access" on deliveries for select using (auth.role() = 'authenticated');
create policy "Authenticated read access" on inventory for select using (auth.role() = 'authenticated');

-- Authenticated users can insert reports and road_reports (reporting is open)
create policy "Authenticated insert" on reports for insert with check (auth.role() = 'authenticated');
create policy "Authenticated insert" on road_reports for insert with check (auth.role() = 'authenticated');

-- ============================================================
-- SEED DATA (a few resource types to get started)
-- ============================================================
insert into resources (name, unit) values
  ('Drinking Water', 'liters'),
  ('Dry Ration Kit', 'kits'),
  ('First Aid Kit', 'kits'),
  ('Blankets', 'pcs'),
  ('Baby Food', 'kits');