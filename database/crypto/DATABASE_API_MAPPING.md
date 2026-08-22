# SIH 26183 — Database ↔ API Mapping

This mapping follows the SIH 26183 API contract. Database-native IDs are UUIDs; blockchain-native identifiers remain TEXT.

## Core mapping

| API field | Backend model field | Database column | PostgreSQL type |
|---|---|---|---|
| `id` (case) | `Case.id` | `cases.id` | `uuid` |
| `case_id` | `Case.id` | `cases.id` | `uuid` |
| `case_reference` | `Case.case_reference` | `cases.case_reference` | `text` |
| `fraud_type` | `Case.fraud_type` | `cases.fraud_type` | `text` |
| `description` | `Case.description` | `cases.description` | `text, nullable` |
| `status` | `Case.status` | `cases.status` | `case_status` |
| `created_at` | model `created_at` | corresponding `created_at` | `timestamptz` |
| `updated_at` | model `updated_at` | `cases.updated_at` | `timestamptz` |
| `wallet.id` | `Wallet.id` | `wallets.id` | `uuid` |
| `wallet_address` | `Wallet.address` | `wallets.address` | `text` |
| `wallet.chain` | `Wallet.chain` | `wallets.chain` | `blockchain_chain` |
| `wallet.type` | `Wallet.type` | `wallets.type` / `case_wallets.type` | `wallet_type` |
| `transaction.id` | `Transaction.id` | `transactions.id` | `uuid` |
| `transaction_hash` | `Transaction.transaction_hash` | `transactions.transaction_hash` | `text` |
| `transaction.chain` | `Transaction.chain` | `transactions.chain` | `blockchain_chain` |
| `from_address` | derived from `Transaction.from_wallet_id` | `wallets.address` | `text` |
| `to_address` | derived from `Transaction.to_wallet_id` | `wallets.address` | `text` |
| `asset` | `Transaction.asset` | `transactions.asset` | `text` |
| `amount` | `Transaction.amount` | `transactions.amount` | `numeric(78,36)` |
| `block_number` | `Transaction.block_number` | `transactions.block_number` | `bigint, nullable` |
| `timestamp` | `Transaction.timestamp` | `transactions.timestamp` | `timestamptz, nullable` |
| `transaction.status` | `Transaction.status` | `transactions.status` | `transaction_status` |
| transaction `case_id` | `CaseTransaction.case_id` | `case_transactions.case_id` | `uuid` |
| transaction `hop` | `CaseTransaction.hop` | `case_transactions.hop` | `integer` |
| `entity_id` | `Entity.id` | `entities.id` | `uuid` |
| `entity_name` | `Entity.name` | `entities.name` | `text` |
| `entity_type` | `Entity.type` | `entities.type` | `entity_type` |
| label confidence | `WalletEntityLabel.confidence` | `wallet_entity_labels.confidence` | `numeric(5,4)` |
| attribution `id` | `Attribution.id` | `attributions.id` | `uuid` |
| attribution `wallet_address` | derived via `wallet_id` | `wallets.address` | `text` |
| attribution `match_type` | `Attribution.match_type` | `attributions.match_type` | `attribution_match_type` |
| attribution `confidence` | `Attribution.confidence` | `attributions.confidence` | `numeric(5,4)` |
| attribution `evidence` | `Attribution.evidence` | `attributions.evidence` | `text[]` |
| `risk.id` | `RiskAssessment.id` | `risk_assessments.id` | `uuid` |
| `risk.score` | `RiskAssessment.score` | `risk_assessments.score` | `integer` |
| `risk.level` | `RiskAssessment.level` | `risk_assessments.level` | `risk_level` |
| indicator `id` | `RiskIndicator.id` | `risk_indicators.id` | `uuid` |
| indicator `code` | `RiskIndicator.code` | `risk_indicators.code` | `text` |
| indicator `description` | `RiskIndicator.description` | `risk_indicators.description` | `text` |
| indicator `severity` | `RiskIndicator.severity` | `risk_indicators.severity` | `risk_indicator_severity` |
| indicator `evidence` | `RiskIndicator.evidence` | `risk_indicators.evidence` | `text[]` |

## Serialization rules

1. `transactions.amount` is PostgreSQL `NUMERIC`, not floating point. Flask must serialize it as a JSON string such as `"1.250000000000000000"`.
2. UUIDs are serialized as JSON strings.
3. `TIMESTAMPTZ` values are serialized as ISO 8601 UTC strings.
4. `wallet_address` and `transaction_hash` are always strings.
5. `chain` is currently only `ethereum`.
6. Risk scores are integers from 0 to 100.
7. Confidence values are stored as 0–1 decimals and returned as JSON numbers.
8. SQL NULL becomes JSON `null`; empty strings must not be used as NULL substitutes.

## Graph mapping

The backend graph response should be built from `case_wallets`, `case_transactions`, `transactions`, and `wallets`.

- Graph node `id` → `wallets.id` serialized as a string.
- Graph node `address` → `wallets.address`.
- Graph node `type` → `case_wallets.type`.
- Graph edge `source` → source wallet node ID.
- Graph edge `target` → destination wallet node ID.
- Graph edge `transaction_hash` → `transactions.transaction_hash`.
- Graph edge `amount` → serialized `transactions.amount`.
- Graph edge `asset` → `transactions.asset`.
- Graph edge `timestamp` → `transactions.timestamp`.
- Graph edge `hop` → `case_transactions.hop`.

The frontend consumes the API graph response and does not query these tables directly.

## Relationship rules

- `transactions.from_wallet_id` → `wallets.id`.
- `transactions.to_wallet_id` → `wallets.id`.
- `case_transactions.case_id` → `cases.id`.
- `case_transactions.transaction_id` → `transactions.id`.
- `attributions.case_id` → `cases.id`.
- `attributions.wallet_id` → `wallets.id`.
- `attributions.entity_id` → `entities.id`.
- `risk_assessments.case_id` → `cases.id`.
- `risk_indicators.risk_assessment_id` → `risk_assessments.id`.
- `wallet_entity_labels.wallet_id` → `wallets.id`.
- `wallet_entity_labels.entity_id` → `entities.id`.

Persistent entity labels are intentionally separate from investigation-specific attribution results.

## Nullability

| Field category | Null policy |
|---|---|
| Primary keys | Never NULL |
| Case reference / fraud type | Never NULL |
| Wallet address / chain / type | Never NULL |
| Transaction hash / chain / addresses / asset / amount | Never NULL |
| Block number | NULL when provider does not supply it |
| Transaction timestamp | NULL when provider does not supply it |
| Case description | NULL when omitted |
| Attribution evidence | Empty array when no evidence strings are recorded |
| Risk indicator evidence | Empty array when no evidence strings are recorded |
| Optional first/last seen timestamps | NULL until observed |

## Existing repository note

The repository currently contains an older disaster-relief MVP schema. The SIH 26183 cryptocurrency schema is isolated under `database/crypto/` so the existing relief tables are not overwritten or silently changed.
