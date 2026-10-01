-- Product metadata saves include these columns even when their values are null/0.
-- Their migrations added columns after the original UPDATE column allowlist.
-- Keep RLS and the stock/cost restrictions; do not grant table-wide UPDATE.
BEGIN;
GRANT UPDATE (supplier_id, commission_percent)
  ON public.products TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
