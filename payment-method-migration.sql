-- Prime Auto Motors: add payment method tracking
-- Run this once in Supabase Dashboard > SQL Editor > New query.
alter table public.sales
  add column if not exists payment_method text not null default 'Koko';

alter table public.sales
  drop constraint if exists sales_payment_method_check;

alter table public.sales
  add constraint sales_payment_method_check
  check (payment_method in ('Koko', 'Cash', 'Card'));
