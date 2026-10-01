# Admin stock receipt corrections

On an existing database with Unified Transactions and security hardening installed,
run the entire `supabase/migrations/20261020_admin_stock_receipt_corrections.sql`
as project owner before deploying the updated application. This additive migration
does not change existing quantities, costs, records or balances. Do not run fresh
setup on an existing database. The fresh bootstrap also includes this migration.

In Transactions, open a posted Vendor purchase. Active admins with inventory and
treasury management permissions see Edit stock receipt and Delete stock receipt.
Both actions require a reason. Deleting cancels the receipt and reverses its
inventory and allocated payments; it retains the receipt, lines and audit trail.
Editing uses the existing receipt form, prefilled with supplier, location,
reference, notes, due date, quantities and unit costs. Select the corrected payment
plan explicitly. One command reverses the original and posts its replacement;
failure rolls back every stock, payment and document change.

The original is marked void, and the replacement links to it through
`replaces_receipt_id`. Old dates are preserved. Repeating an unchanged request
does not post another receipt or payment. Managers and other roles cannot bypass
the admin check by calling the RPC directly.

Stock sold, transferred or adjusted away after receipt, vendor returns, applied
credits, shared payments and unapplied payment remainders require reconciliation
before correction. These checks preserve historical costs and other documents'
payments. Reconcile dependent operations rather than forcing a direct table update.

Inventory analytics category details now include unsold products, unit cost and
stock cost. The branch filter uses that branch's recorded weighted cost; the
all-branches view combines quantity-weighted inventory costs. Legacy company-wide
records use `products.cost` when no recorded balances are available. Unknown costs
show a dash, and recorded zero cost stays zero. Selling/wholesale prices are not
used for the new cost columns. Existing report totals retain their current meaning.

Validation uses local PostgreSQL-compatible PGlite and focused Flutter tests.
No live database changes, production build or upload are performed with this
feature implementation. Deploy the SQL first, then build and deploy the app.
