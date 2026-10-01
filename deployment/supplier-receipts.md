# Supplier receipts in Operations

Operations → Inventory and Stock → Supplier receipts opens the purchase history for the selected branch (or all accessible branches). Search by reference or supplier, open a receipt, then admins with inventory and treasury permissions can use Edit stock receipt or Delete stock receipt. The same secured commands, stock-use restrictions, atomic replacement and retained audit history apply as in Transactions.

## Existing production database

Apply `supabase/migrations/20261021_stock_receipt_transaction_visibility.sql` after `20261020_admin_stock_receipt_corrections.sql`. Prerequisite: the unified transaction migration `20261011_unified_transactions.sql` and subsequent migrations are already installed. Do not use the generated fresh setup against an existing database.

The new migration makes receipt posting explicitly register its purchase document before payment, even when its source trigger is missing or disabled. Payment is allocated to that document in the same transaction. It adds branch/receipt filtering to transaction search and inserts only missing historical purchase headers. Existing records, inventory, treasury balances and payment entries are preserved. Reapplying the patch does not duplicate documents or replay money.

Historical payment matching is not guessed. A missing header without an existing linked settlement is shown as unpaid until its ledger evidence is reconciled. Never pay it a second time solely to fix display. This patch does not infer a payment from `stock_receipts.amount_paid`, which may be a legacy projection.

Build and deploy the updated client after applying SQL. The previously uploaded web build and macOS ZIP do not contain this Operations entry. No live database changes were made during implementation.

## Read-only check for a reported missing receipt

Run this in the SQL editor using the actual receipt reference:

```sql
select r.id as receipt_id, r.reference_number, r.receipt_date,
       r.total_cost, r.amount_paid as receipt_recorded_paid,
       t.id as transaction_id, t.status,
       s.amount_paid as linked_paid, s.amount_due
from public.stock_receipts r
left join public.transactions t on t.stock_receipt_id = r.id
left join public.transaction_summary s on s.id = t.id
where r.reference_number = 'REPLACE_WITH_RECEIPT_REFERENCE';
```

If no receipt exists, capture the failed stock receipt request response before retrying with a new receipt. Clear transaction type/date/account filters when checking Documents and Money movements.
