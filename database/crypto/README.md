# SIH 26183 — Cryptocurrency Investigation Database

This directory contains the PostgreSQL/Supabase database contract for the cryptocurrency investigation MVP.

## Files

- `schema.sql` — reproducible schema for the SIH 26183 investigation domain.
- `seed.sql` — synthetic demo data only.
- `down.sql` — rollback for the SIH 26183 schema.
- `DATABASE_API_MAPPING.md` — API/backend/database field mapping.

## Existing repository protection

The repository also contains an older disaster-relief MVP database. Its existing `database/schema.sql` is not replaced by this work.

The SIH 26183 schema uses the contract table names `cases`, `wallets`, `transactions`, `entities`, `wallet_entity_labels`, `attributions`, `risk_assessments`, `risk_indicators`, and `investigation_events`.

These names do not conflict with the existing relief schema currently in the repository.

## Supabase setup

1. Open the Supabase project SQL Editor.
2. Run `schema.sql`.
3. Run `seed.sql` only when synthetic demo data is wanted.
4. Configure the Flask backend with its server-side Supabase credentials.
5. Never put database credentials in frontend code.
6. Never commit `.env`.

The schema enables RLS but intentionally does not add broad anonymous/authenticated policies. The Flask backend is expected to use its server-side credential for MVP database access.

## Required backend behavior

The backend must:

- use UUIDs as application IDs;
- serialize UUIDs as JSON strings;
- serialize `NUMERIC` cryptocurrency amounts as JSON strings;
- serialize `TIMESTAMPTZ` as ISO 8601 UTC strings;
- use the canonical enum values from the API contract;
- never expose provider-specific blockchain response structures;
- never expose database credentials;
- query through the database layer rather than from the frontend.

## Graph

The `investigation_transaction_graph` view is a backend convenience view. It is not a public frontend data source.

The backend should transform database rows into the exact API contract response: `nodes[]` and `edges[]`.

## Demo data

`seed.sql` uses synthetic addresses, hashes, timestamps, and risk indicators. It contains no claimed real-world VASP association.

## Rollback

Run `down.sql` only after stopping services that depend on this schema and confirming that no other service depends on these objects.

## Definition of done

- [x] UUID application primary keys
- [x] TEXT wallet addresses
- [x] TEXT transaction hashes
- [x] exact NUMERIC cryptocurrency amounts
- [x] TIMESTAMPTZ event timestamps
- [x] canonical MVP enums
- [x] foreign keys with matching UUID types
- [x] graph relationship tables
- [x] entity labels separated from investigation attributions
- [x] structured risk assessments and indicators
- [x] investigation event/audit table
- [x] targeted indexes
- [x] reproducible schema
- [x] synthetic seed data
- [x] API/database mapping
- [x] rollback script
- [x] no secrets
