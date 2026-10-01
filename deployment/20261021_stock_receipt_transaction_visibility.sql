-- Existing databases: apply after 20261020_admin_stock_receipt_corrections.sql.
BEGIN;

create or replace function public.post_stock_receipt_v1(receipt_input jsonb,items_input jsonb,settlements_input jsonb default '[]')
returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid; d uuid; request jsonb:=jsonb_build_array(receipt_input,items_input,settlements_input);
begin
 if not coalesce(private.has_permission(auth.uid(),'manageInventory'),false) then raise exception using errcode='42501',message='INVENTORY_FORBIDDEN'; end if;
 if jsonb_array_length(coalesce(settlements_input,'[]'::jsonb))>0 or coalesce((receipt_input->>'amount_paid')::numeric,0)>0 then perform private.require_finance_v1(); end if;
 result:=private.finance_command_v1('receipt:'||(receipt_input->>'idempotency_key'),request); if result is not null then return result; end if;
 if exists(select 1 from public.stock_receipts where idempotency_key=receipt_input->>'idempotency_key') then raise exception using errcode='22023',message='LEGACY_DOCUMENT_EXISTS'; end if;
 result:=private.post_stock_receipt_documents_v1(receipt_input,items_input);
 update public.stock_receipts set due_date=nullif(receipt_input->>'due_date','')::date where id=result;
 -- Register explicitly: a missing/disabled source trigger must never let a
 -- receipt payment be posted as an unrelated movement.
 insert into public.transactions(type,direction,reference,description,stock_receipt_id,supplier_id,location_id,total,due_date,occurred_at,created_by)
 select 'purchase','outgoing',coalesce(reference_number,id::text),coalesce(notes,''),id,supplier_id,location_id,total_cost,due_date,receipt_date,created_by
 from public.stock_receipts where id=result
 on conflict(stock_receipt_id) do nothing;
 select id into d from public.transactions where stock_receipt_id=result;
 if d is null then raise exception using errcode='22023',message='RECEIPT_TRANSACTION_MISSING'; end if;
 perform private.post_document_settlements_v1(d,coalesce(settlements_input,private.legacy_settlements_v1(receipt_input,coalesce((receipt_input->>'amount_paid')::numeric,0))),'receipt:'||result::text);
 insert into private.finance_commands_v1 values('receipt:'||(receipt_input->>'idempotency_key'),request,result);
 return result;
end $$;

create or replace function public.search_transactions_v1(input jsonb default '{}')
returns jsonb language sql stable security invoker set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(rows)),'[]') from (
  select d.* from public.transaction_summary d
  where (nullif(input->>'sale_id','') is null or d.sale_id=(input->>'sale_id')::uuid)
   and (nullif(input->>'installation_id','') is null or d.installation_id=(input->>'installation_id')::uuid)
   and (nullif(input->>'expense_id','') is null or d.expense_id=(input->>'expense_id')::uuid)
   and (nullif(input->>'salary_record_id','') is null or d.salary_record_id=(input->>'salary_record_id')::uuid)
   and (nullif(input->>'location_id','') is null or d.location_id=(input->>'location_id')::uuid)
   and (nullif(input->>'stock_receipt_id','') is null or d.stock_receipt_id=(input->>'stock_receipt_id')::uuid)
   and (nullif(input->>'type','') is null or d.type=input->>'type')
   and (nullif(input->>'status','') is null or d.payment_status=input->>'status')
   and (nullif(input->>'search','') is null or d.reference ilike '%'||(input->>'search')||'%'
    or d.description ilike '%'||(input->>'search')||'%' or d.party_name ilike '%'||(input->>'search')||'%')
   and (nullif(input->>'party_id','') is null or coalesce(d.customer_id,d.supplier_id,d.employee_id)=nullif(input->>'party_id','')::uuid)
   and (nullif(input->>'start','') is null or d.occurred_at >= (input->>'start')::timestamptz)
   and (nullif(input->>'end','') is null or d.occurred_at < (input->>'end')::timestamptz)
   and (nullif(input->>'account_id','') is null or exists(
    select 1 from public.transaction_allocations al join public.transaction_settlements s on s.id=al.settlement_id
    where al.transaction_id=d.id and s.account_id=(input->>'account_id')::uuid))
  order by d.occurred_at desc,d.id desc
  limit least(greatest(coalesce((input->>'limit')::int,50),1),50) offset greatest(coalesce((input->>'offset')::int,0),0)
 ) rows;
$$;
-- Repair missing receipt headers only. Never replay payments, stock or balances.
insert into public.transactions(type,direction,reference,description,stock_receipt_id,supplier_id,location_id,total,due_date,occurred_at,created_by,status)
select 'purchase','outgoing',coalesce(reference_number,id::text),coalesce(notes,''),id,supplier_id,location_id,total_cost,due_date,receipt_date,created_by,
 case when is_void then 'void' else 'posted' end
from public.stock_receipts on conflict(stock_receipt_id) do nothing;

REVOKE ALL ON FUNCTION public.post_stock_receipt_v1(jsonb,jsonb,jsonb), public.search_transactions_v1(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_stock_receipt_v1(jsonb,jsonb,jsonb), public.search_transactions_v1(jsonb) TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
