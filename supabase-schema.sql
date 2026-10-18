-- Prime Auto Motors shared database schema
-- Run this entire file in Supabase SQL Editor for your project.
create extension if not exists pgcrypto;

create table if not exists public.inventory (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  sku text not null,
  category text not null default '',
  price numeric(12,2) not null check (price >= 0),
  qty integer not null default 0 check (qty >= 0),
  low integer not null default 5 check (low >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(owner_id, sku)
);

create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  receipt_id text not null,
  customer text not null default 'Walk-in customer',
  total numeric(12,2) not null check (total >= 0),
  created_at timestamptz not null default now(),
  unique(owner_id, receipt_id)
);

create table if not exists public.sale_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  sale_id uuid not null references public.sales(id) on delete cascade,
  sku text not null,
  name text not null,
  price numeric(12,2) not null check (price >= 0),
  qty integer not null check (qty > 0),
  line_total numeric(12,2) not null check (line_total >= 0)
);

alter table public.inventory enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;

drop policy if exists "Owners manage their inventory" on public.inventory;
create policy "Owners manage their inventory" on public.inventory
for all to authenticated using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

drop policy if exists "Owners read their sales" on public.sales;
create policy "Owners read their sales" on public.sales
for select to authenticated using (owner_id = (select auth.uid()));

drop policy if exists "Owners read their sale items" on public.sale_items;
create policy "Owners read their sale items" on public.sale_items
for select to authenticated using (owner_id = (select auth.uid()));

-- Atomic checkout: validates stock, reduces quantities and saves the sale
-- as one database transaction. Call only while signed in.
create or replace function public.complete_sale(p_items jsonb, p_customer text default 'Walk-in customer')
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_owner uuid := auth.uid();
  v_sale_id uuid;
  v_receipt text;
  v_total numeric(12,2) := 0;
  v_item jsonb;
  v_part public.inventory%rowtype;
  v_qty integer;
  v_customer text := coalesce(nullif(trim(p_customer), ''), 'Walk-in customer');
  v_items jsonb := '[]'::jsonb;
begin
  if v_owner is null then
    raise exception 'Sign in is required.';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'The cart is empty.';
  end if;

  -- Lock each matching stock row to avoid two checkouts selling the same stock.
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item->>'qty')::integer;
    if v_qty is null or v_qty < 1 then
      raise exception 'Invalid item quantity.';
    end if;
    select * into v_part from public.inventory
      where owner_id = v_owner and sku = (v_item->>'sku')
      for update;
    if not found then
      raise exception 'Part not found: %', (v_item->>'sku');
    end if;
    if v_part.qty < v_qty then
      raise exception 'Not enough stock for % (available: %).', v_part.name, v_part.qty;
    end if;
    v_total := v_total + (v_part.price * v_qty);
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'sku', v_part.sku, 'name', v_part.name, 'price', v_part.price,
      'qty', v_qty, 'line_total', v_part.price * v_qty
    ));
  end loop;

  v_receipt := 'PAM-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  insert into public.sales(owner_id, receipt_id, customer, total)
    values (v_owner, v_receipt, v_customer, v_total)
    returning id into v_sale_id;

  for v_item in select value from jsonb_array_elements(v_items)
  loop
    update public.inventory set qty = qty - (v_item->>'qty')::integer, updated_at = now()
      where owner_id = v_owner and sku = (v_item->>'sku');
    insert into public.sale_items(owner_id, sale_id, sku, name, price, qty, line_total)
      values (v_owner, v_sale_id, v_item->>'sku', v_item->>'name',
        (v_item->>'price')::numeric, (v_item->>'qty')::integer, (v_item->>'line_total')::numeric);
  end loop;

  return jsonb_build_object(
    'id', v_sale_id, 'receipt_id', v_receipt, 'customer', v_customer,
    'total', v_total, 'items', v_items, 'created_at', now()
  );
end;
$$;

grant execute on function public.complete_sale(jsonb, text) to authenticated;
