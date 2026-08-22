-- SIH 26183 — rollback
-- Run only against a database where the SIH 26183 cryptocurrency schema is isolated.

drop view if exists investigation_transaction_graph;

drop trigger if exists trg_cases_updated_at on cases;
drop function if exists set_case_updated_at();

drop table if exists investigation_events;
drop table if exists risk_indicators;
drop table if exists risk_assessments;
drop table if exists attributions;
drop table if exists wallet_entity_labels;
drop table if exists entities;
drop table if exists case_transactions;
drop table if exists transactions;
drop table if exists case_wallets;
drop table if exists wallets;
drop table if exists cases;

drop type if exists transaction_status;
drop type if exists risk_indicator_severity;
drop type if exists risk_level;
drop type if exists attribution_match_type;
drop type if exists entity_type;
drop type if exists wallet_type;
drop type if exists case_status;
drop type if exists blockchain_chain;
