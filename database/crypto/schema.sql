-- SIH 26183 — Cryptocurrency Investigation MVP
-- PostgreSQL / Supabase
-- Isolated schema for the cryptocurrency investigation service.
-- This file intentionally does NOT replace the existing disaster-relief schema.

create extension if not exists "pgcrypto";

-- Canonical enums from API_CONTRACT.md
do $$ begin
  create type blockchain_chain as enum ('ethereum');
exception when duplicate_object then null; end $$;

do $$ begin
  create type case_status as enum ('open', 'closed');
exception when duplicate_object then null; end $$;

do $$ begin
  create type wallet_type as enum ('reported_wallet', 'intermediary', 'exchange', 'vasp', 'unknown');
exception when duplicate_object then null; end $$;

do $$ begin
  create type entity_type as enum ('vasp', 'exchange', 'bridge', 'defi_protocol', 'unknown');
exception when duplicate_object then null; end $$;

do $$ begin
  create type attribution_match_type as enum ('known_address', 'entity_label', 'behavioral_match', 'cluster_match', 'unknown');
exception when duplicate_object then null; end $$;

do $$ begin
  create type risk_level as enum ('low', 'medium', 'high', 'critical');
exception when duplicate_object then null; end $$;

do $$ begin
  create type risk_indicator_severity as enum ('low', 'medium', 'high', 'critical');
exception when duplicate_object then null; end $$;

do $$ begin
  create type transaction_status as enum ('pending', 'confirmed', 'failed', 'unknown');
exception when duplicate_object then null; end $$;

-- 1. CASES
create table if not exists cases (
  id uuid primary key default gen_random_uuid(),
  case_reference text not null unique,
  fraud_type text not null,
  description text,
  status case_status not null default 'open',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table cases is 'SIH 26183 cryptocurrency investigation cases.';

-- 2. WALLETS
create table if not exists wallets (
  id uuid primary key default gen_random_uuid(),
  address text not null,
  chain blockchain_chain not null,
  type wallet_type not null default 'unknown',
  first_seen_at timestamptz,
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  unique (address, chain),
  check (length(trim(address)) > 0)
);

comment on column wallets.address is 'Blockchain-native wallet address. TEXT, never numeric.';

-- Case-specific wallet role avoids treating an investigative role as universal truth.
create table if not exists case_wallets (
  case_id uuid not null references cases(id) on delete cascade,
  wallet_id uuid not null references wallets(id) on delete restrict,
  type wallet_type not null default 'unknown',
  created_at timestamptz not null default now(),
  primary key (case_id, wallet_id)
);

-- 3. TRANSACTIONS
create table if not exists transactions (
  id uuid primary key default gen_random_uuid(),
  transaction_hash text not null,
  chain blockchain_chain not null,
  from_wallet_id uuid not null references wallets(id) on delete restrict,
  to_wallet_id uuid not null references wallets(id) on delete restrict,
  asset text not null,
  amount numeric(78, 36) not null,
  block_number bigint,
  timestamp timestamptz,
  status transaction_status not null default 'unknown',
  created_at timestamptz not null default now(),
  unique (transaction_hash, chain),
  check (length(trim(transaction_hash)) > 0),
  check (length(trim(asset)) > 0),
  check (amount >= 0)
);

comment on column transactions.amount is 'Exact NUMERIC representation. Flask must serialize this as a JSON string.';

-- A blockchain transaction can be relevant to multiple investigations.
create table if not exists case_transactions (
  case_id uuid not null references cases(id) on delete cascade,
  transaction_id uuid not null references transactions(id) on delete restrict,
  hop integer not null default 0 check (hop >= 0),
  created_at timestamptz not null default now(),
  primary key (case_id, transaction_id)
);

-- 4. ENTITIES / VASPs
create table if not exists entities (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  type entity_type not null default 'unknown',
  verification_status text not null default 'reference'
    check (verification_status in ('reference', 'verified', 'unverified')),
  created_at timestamptz not null default now(),
  unique (name, type)
);

-- Persistent reference labels. These are not investigation conclusions.
create table if not exists wallet_entity_labels (
  id uuid primary key default gen_random_uuid(),
  wallet_id uuid not null references wallets(id) on delete cascade,
  entity_id uuid not null references entities(id) on delete cascade,
  source text not null,
  confidence numeric(5, 4) not null default 0 check (confidence >= 0 and confidence <= 1),
  created_at timestamptz not null default now(),
  unique (wallet_id, entity_id, source)
);

-- 5. INVESTIGATION ATTRIBUTIONS
create table if not exists attributions (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references cases(id) on delete cascade,
  wallet_id uuid not null references wallets(id) on delete restrict,
  entity_id uuid not null references entities(id) on delete restrict,
  match_type attribution_match_type not null default 'unknown',
  confidence numeric(5, 4) not null check (confidence >= 0 and confidence <= 1),
  evidence text[] not null default '{}',
  created_at timestamptz not null default now()
);

-- 6. RISK ASSESSMENTS
create table if not exists risk_assessments (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references cases(id) on delete cascade,
  score integer not null check (score >= 0 and score <= 100),
  level risk_level not null,
  created_at timestamptz not null default now()
);

create table if not exists risk_indicators (
  id uuid primary key default gen_random_uuid(),
  risk_assessment_id uuid not null references risk_assessments(id) on delete cascade,
  code text not null,
  description text not null,
  severity risk_indicator_severity not null,
  evidence text[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (risk_assessment_id, code)
);

-- 7. INVESTIGATION EVENTS / AUDIT TRAIL
create table if not exists investigation_events (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references cases(id) on delete cascade,
  event_type text not null,
  event_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check (jsonb_typeof(event_data) = 'object')
);

-- 8. TARGETED INDEXES
create index if not exists idx_wallets_address on wallets(address);
create index if not exists idx_wallets_chain on wallets(chain);
create index if not exists idx_transactions_hash on transactions(transaction_hash);
create index if not exists idx_transactions_chain on transactions(chain);
create index if not exists idx_transactions_timestamp on transactions(timestamp);
create index if not exists idx_transactions_from_wallet on transactions(from_wallet_id);
create index if not exists idx_transactions_to_wallet on transactions(to_wallet_id);
create index if not exists idx_case_wallets_wallet on case_wallets(wallet_id);
create index if not exists idx_case_transactions_case on case_transactions(case_id);
create index if not exists idx_case_transactions_transaction on case_transactions(transaction_id);
create index if not exists idx_wallet_entity_labels_entity on wallet_entity_labels(entity_id);
create index if not exists idx_attributions_case on attributions(case_id);
create index if not exists idx_attributions_wallet on attributions(wallet_id);
create index if not exists idx_attributions_entity on attributions(entity_id);
create index if not exists idx_risk_assessments_case on risk_assessments(case_id);
create index if not exists idx_risk_indicators_assessment on risk_indicators(risk_assessment_id);
create index if not exists idx_investigation_events_case_created on investigation_events(case_id, created_at desc);

-- 9. CASE updated_at maintenance
create or replace function set_case_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_cases_updated_at on cases;
create trigger trg_cases_updated_at
before update on cases
for each row execute function set_case_updated_at();

-- 10. BACKEND GRAPH CONVENIENCE VIEW
create or replace view investigation_transaction_graph as
select
  ct.case_id,
  t.id as transaction_id,
  fw.id as source_wallet_id,
  fw.address as source_address,
  fw.type as source_type,
  tw.id as target_wallet_id,
  tw.address as target_address,
  tw.type as target_type,
  t.transaction_hash,
  t.amount,
  t.asset,
  t.timestamp,
  ct.hop
from case_transactions ct
join transactions t on t.id = ct.transaction_id
join wallets fw on fw.id = t.from_wallet_id
join wallets tw on tw.id = t.to_wallet_id;

comment on view investigation_transaction_graph is 'Backend-facing graph source. Frontend consumes the API graph response, not this view directly.';

-- 11. RLS
alter table cases enable row level security;
alter table wallets enable row level security;
alter table case_wallets enable row level security;
alter table transactions enable row level security;
alter table case_transactions enable row level security;
alter table entities enable row level security;
alter table wallet_entity_labels enable row level security;
alter table attributions enable row level security;
alter table risk_assessments enable row level security;
alter table risk_indicators enable row level security;
alter table investigation_events enable row level security;

-- No broad anonymous policies are created. The Flask backend should use its server-side Supabase credential.
