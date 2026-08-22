-- SIH 26183 synthetic/demo seed data.
-- Every value below is synthetic. It is NOT law-enforcement intelligence and does NOT assert ownership of any real VASP.

begin;

insert into cases (case_reference, fraud_type, description)
values ('SIH-DEMO-001', 'investment_scam', 'Synthetic MVP investigation used for integration testing only.')
on conflict (case_reference) do nothing;

insert into wallets (address, chain, type) values
('0x1111111111111111111111111111111111111111', 'ethereum', 'reported_wallet'),
('0x2222222222222222222222222222222222222222', 'ethereum', 'intermediary'),
('0x3333333333333333333333333333333333333333', 'ethereum', 'unknown')
on conflict (address, chain) do update set type = excluded.type;

insert into case_wallets (case_id, wallet_id, type)
select c.id, w.id,
  case w.address
    when '0x1111111111111111111111111111111111111111' then 'reported_wallet'::wallet_type
    when '0x2222222222222222222222222222222222222222' then 'intermediary'::wallet_type
    else 'unknown'::wallet_type
  end
from cases c cross join wallets w
where c.case_reference = 'SIH-DEMO-001'
  and w.address in (
    '0x1111111111111111111111111111111111111111',
    '0x2222222222222222222222222222222222222222',
    '0x3333333333333333333333333333333333333333'
  )
on conflict (case_id, wallet_id) do update set type = excluded.type;

insert into transactions (transaction_hash, chain, from_wallet_id, to_wallet_id, asset, amount, block_number, timestamp, status)
select
  '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'ethereum', wf.id, wt.id, 'ETH', 1.250000000000000000, 12345678,
  '2026-08-22T14:30:00Z'::timestamptz, 'confirmed'
from wallets wf, wallets wt
where wf.address = '0x1111111111111111111111111111111111111111'
  and wt.address = '0x2222222222222222222222222222222222222222'
on conflict (transaction_hash, chain) do nothing;

insert into transactions (transaction_hash, chain, from_wallet_id, to_wallet_id, asset, amount, block_number, timestamp, status)
select
  '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'ethereum', wf.id, wt.id, 'ETH', 0.750000000000000000, 12345690,
  '2026-08-22T14:35:00Z'::timestamptz, 'confirmed'
from wallets wf, wallets wt
where wf.address = '0x2222222222222222222222222222222222222222'
  and wt.address = '0x3333333333333333333333333333333333333333'
on conflict (transaction_hash, chain) do nothing;

insert into case_transactions (case_id, transaction_id, hop)
select c.id, t.id,
  case t.transaction_hash
    when '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' then 1
    else 2
  end
from cases c
join transactions t on t.chain = 'ethereum'
where c.case_reference = 'SIH-DEMO-001'
  and t.transaction_hash in (
    '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  )
on conflict (case_id, transaction_id) do update set hop = excluded.hop;

insert into risk_assessments (case_id, score, level)
select c.id, 72, 'high'
from cases c
where c.case_reference = 'SIH-DEMO-001'
  and not exists (select 1 from risk_assessments ra where ra.case_id = c.id);

insert into risk_indicators (risk_assessment_id, code, description, severity, evidence)
select ra.id, 'MULTI_HOP',
       'Funds moved through multiple intermediary wallets in the synthetic graph.',
       'medium', array['Synthetic demo transaction path']
from risk_assessments ra join cases c on c.id = ra.case_id
where c.case_reference = 'SIH-DEMO-001'
on conflict (risk_assessment_id, code) do nothing;

insert into risk_indicators (risk_assessment_id, code, description, severity, evidence)
select ra.id, 'RAPID_MOVEMENT',
       'Synthetic transactions occur within a short time interval.',
       'high', array['Synthetic demo timestamps']
from risk_assessments ra join cases c on c.id = ra.case_id
where c.case_reference = 'SIH-DEMO-001'
on conflict (risk_assessment_id, code) do nothing;

insert into investigation_events (case_id, event_type, event_data)
select id, 'demo_seeded', jsonb_build_object('source', 'synthetic_demo_data', 'version', 'mvp-1')
from cases where case_reference = 'SIH-DEMO-001';

commit;
