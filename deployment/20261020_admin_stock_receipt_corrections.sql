-- Admin corrections retain original receipts and reverse stock/payments atomically.
BEGIN;
ALTER TABLE public.stock_receipts
 ADD COLUMN IF NOT EXISTS is_void boolean NOT NULL DEFAULT false,
 ADD COLUMN IF NOT EXISTS void_reason text,
 ADD COLUMN IF NOT EXISTS replaces_receipt_id uuid REFERENCES public.stock_receipts(id) ON DELETE RESTRICT;

CREATE OR REPLACE FUNCTION private.void_stock_receipt_impl_v1(input jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
 actor uuid := private.require_finance_v1();
 d public.transactions%rowtype; receipt public.stock_receipts%rowtype;
 result uuid; item record; payment record; stock numeric; cost numeric;
 remaining_value numeric; target_receipt uuid;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=actor AND role='admin' AND is_active)
  OR NOT coalesce(private.has_permission(actor,'manageInventory'),false) THEN
  RAISE EXCEPTION USING errcode='42501',message='ADMIN_RECEIPT_PERMISSION_REQUIRED';
 END IF;
 result := private.finance_command_v1('receipt-void:'||(input->>'idempotency_key'),input);
 IF result IS NOT NULL THEN RETURN result; END IF;
 IF nullif(btrim(input->>'reason'),'') IS NULL THEN
  RAISE EXCEPTION USING errcode='22023',message='RECEIPT_REASON_REQUIRED'; END IF;
 SELECT * INTO d FROM public.transactions WHERE id=(input->>'transaction_id')::uuid FOR UPDATE;
 IF NOT FOUND OR d.type<>'purchase' OR d.status<>'posted' THEN
  RAISE EXCEPTION USING errcode='22023',message='RECEIPT_NOT_EDITABLE'; END IF;
 IF NOT private.has_location_access(actor,d.location_id) THEN
  RAISE EXCEPTION USING errcode='42501',message='LOCATION_FORBIDDEN'; END IF;
 target_receipt := d.stock_receipt_id;
 SELECT * INTO receipt FROM public.stock_receipts WHERE id=target_receipt FOR UPDATE;
 IF NOT FOUND OR receipt.is_void THEN
  RAISE EXCEPTION USING errcode='22023',message='RECEIPT_NOT_EDITABLE'; END IF;
 IF EXISTS(SELECT 1 FROM public.vendor_return_items v JOIN public.stock_receipt_items i
  ON i.id=v.receipt_item_id WHERE i.receipt_id=target_receipt)
  OR EXISTS(SELECT 1 FROM public.transaction_credits WHERE transaction_id=d.id OR credit_transaction_id=d.id) THEN
  RAISE EXCEPTION USING errcode='22023',message='RECEIPT_RETURNS_OR_CREDITS_REQUIRE_RECONCILIATION'; END IF;

 -- Lock affected products before balances, like checkout. Reject concurrent edits.
 PERFORM 1 FROM public.products p WHERE p.id IN
  (SELECT i.product_id FROM public.stock_receipt_items i WHERE i.receipt_id=target_receipt)
  ORDER BY p.id FOR UPDATE NOWAIT;
 PERFORM 1 FROM public.inventory_balances b WHERE b.location_id=d.location_id AND b.product_id IN
  (SELECT i.product_id FROM public.stock_receipt_items i WHERE i.receipt_id=target_receipt)
  ORDER BY b.product_id FOR UPDATE;
 -- Do not rewrite costs of goods already sold, transferred or adjusted away.
 IF EXISTS(SELECT 1 FROM public.inventory_movements m JOIN public.stock_receipt_items i
  ON i.product_id=m.product_id AND i.receipt_id=target_receipt
  WHERE m.location_id=d.location_id AND m.created_at>=receipt.created_at AND m.quantity_delta<0
   AND m.receipt_id IS DISTINCT FROM target_receipt
   AND NOT EXISTS(SELECT 1 FROM public.stock_receipts cancelled WHERE cancelled.id=m.receipt_id AND cancelled.is_void)) THEN
  RAISE EXCEPTION USING errcode='22023',message='RECEIPT_STOCK_ALREADY_USED'; END IF;

 FOR item IN SELECT * FROM public.stock_receipt_items i WHERE i.receipt_id=target_receipt ORDER BY i.product_id LOOP
  SELECT b.quantity,b.weighted_unit_cost INTO stock,cost FROM public.inventory_balances b
   WHERE b.product_id=item.product_id AND b.location_id=d.location_id;
  remaining_value := stock*cost-item.quantity*item.unit_cost;
  IF stock IS NULL OR stock<item.quantity OR remaining_value < -greatest(stock*0.0001,0.0001) THEN
   RAISE EXCEPTION USING errcode='22023',message='RECEIPT_STOCK_RECONCILIATION_REQUIRED'; END IF;
  IF stock=item.quantity AND abs(remaining_value)>greatest(stock*0.0001,0.0001) THEN
   RAISE EXCEPTION USING errcode='22023',message='RECEIPT_STOCK_RECONCILIATION_REQUIRED'; END IF;
  UPDATE public.inventory_balances SET quantity=stock-item.quantity,
   weighted_unit_cost=CASE WHEN stock=item.quantity THEN 0
    ELSE round(greatest(remaining_value,0)/(stock-item.quantity),4) END,updated_at=now()
   WHERE product_id=item.product_id AND location_id=d.location_id;
  INSERT INTO public.inventory_movements(product_id,location_id,movement_type,quantity_delta,
   unit_cost_snapshot,receipt_id,notes,actor_id)
   VALUES(item.product_id,d.location_id,'adjustment',-item.quantity,item.unit_cost,target_receipt,
    'Receipt cancellation: '||(input->>'reason'),actor);
  PERFORM private.sync_product_inventory(item.product_id);
 END LOOP;

 FOR payment IN SELECT DISTINCT s.* FROM public.transaction_settlements s
  JOIN public.transaction_allocations a ON a.settlement_id=s.id
  WHERE a.transaction_id=d.id AND s.reversed_settlement_id IS NULL
   AND NOT EXISTS(SELECT 1 FROM public.transaction_settlements r WHERE r.reversed_settlement_id=s.id) LOOP
  IF EXISTS(SELECT 1 FROM public.transaction_allocations WHERE settlement_id=payment.id AND transaction_id<>d.id)
   OR (SELECT coalesce(sum(amount),0) FROM public.transaction_allocations
    WHERE settlement_id=payment.id AND transaction_id=d.id)<>payment.amount THEN
   RAISE EXCEPTION USING errcode='22023',message='SHARED_SETTLEMENT_REQUIRES_REALLOCATION'; END IF;
  PERFORM public.reverse_transaction_settlement_v1(jsonb_build_object('settlement_id',payment.id,
   'reason',input->>'reason','idempotency_key',(input->>'idempotency_key')||':'||payment.id::text));
 END LOOP;
 UPDATE public.transactions SET status='void' WHERE id=d.id;
 UPDATE public.stock_receipts SET is_void=true,void_reason=input->>'reason' WHERE id=target_receipt;
 PERFORM private.sync_transaction_v1(d.id);
 INSERT INTO private.finance_commands_v1 VALUES('receipt-void:'||(input->>'idempotency_key'),input,target_receipt);
 INSERT INTO public.audit_events(actor_id,action,entity_type,entity_id,location_id,before_data,after_data)
  VALUES(actor,'stock_receipt_cancelled','stock_receipt',target_receipt,d.location_id,to_jsonb(receipt),input);
 RETURN target_receipt;
EXCEPTION WHEN lock_not_available OR deadlock_detected THEN
 RAISE EXCEPTION USING errcode='40001',message='RECEIPT_CHANGED_REFRESH_AND_RETRY';
END $$;

CREATE OR REPLACE FUNCTION public.void_stock_receipt_v1(input jsonb)
RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT private.void_stock_receipt_impl_v1(input);
$$;

CREATE OR REPLACE FUNCTION public.replace_stock_receipt_v1(
 input jsonb,receipt_input jsonb,items_input jsonb,settlements_input jsonb DEFAULT '[]'
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor uuid:=private.require_finance_v1(); result uuid; original uuid;
 request jsonb:=jsonb_build_array(input,receipt_input,items_input,settlements_input);
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=actor AND role='admin' AND is_active)
  OR NOT coalesce(private.has_permission(actor,'manageInventory'),false) THEN
  RAISE EXCEPTION USING errcode='42501',message='ADMIN_RECEIPT_PERMISSION_REQUIRED'; END IF;
 result:=private.finance_command_v1('receipt-replace:'||(input->>'idempotency_key'),request);
 IF result IS NOT NULL THEN RETURN result; END IF;
 IF jsonb_typeof(items_input) IS DISTINCT FROM 'array' OR jsonb_array_length(items_input)=0 THEN
  RAISE EXCEPTION USING errcode='22023',message='RECEIPT_ITEMS_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(items_input) row_input WHERE
  nullif(row_input->>'quantity','') IS NULL OR nullif(row_input->>'unit_cost','') IS NULL OR
  (row_input->>'quantity')::numeric<=0 OR (row_input->>'unit_cost')::numeric<0 OR
  row_input->>'quantity' IN ('NaN','Infinity','-Infinity') OR
  row_input->>'unit_cost' IN ('NaN','Infinity','-Infinity')) THEN
  RAISE EXCEPTION USING errcode='22023',message='INVALID_RECEIPT_ITEMS'; END IF;
 -- Server controls fresh receipt identity and nested idempotency keys.
 original:=private.void_stock_receipt_impl_v1(input||jsonb_build_object('idempotency_key',(input->>'idempotency_key')||':old'));
 result:=public.post_stock_receipt_v1((receipt_input-'id')||jsonb_build_object(
  'idempotency_key',(input->>'idempotency_key')||':new'),items_input,settlements_input);
 UPDATE public.stock_receipts SET replaces_receipt_id=original WHERE id=result;
 INSERT INTO private.finance_commands_v1 VALUES('receipt-replace:'||(input->>'idempotency_key'),request,result);
 INSERT INTO public.audit_events(actor_id,action,entity_type,entity_id,before_data,after_data)
  VALUES(actor,'stock_receipt_corrected','stock_receipt',result,jsonb_build_object('original_receipt_id',original),request);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION private.void_stock_receipt_impl_v1(jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.void_stock_receipt_v1(jsonb),
 public.replace_stock_receipt_v1(jsonb,jsonb,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.void_stock_receipt_v1(jsonb),
 public.replace_stock_receipt_v1(jsonb,jsonb,jsonb,jsonb) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
