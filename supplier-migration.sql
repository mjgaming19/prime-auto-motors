-- Prime Auto Motors: supplier directory
-- Run once in Supabase Dashboard > SQL Editor > New query.
-- This does not modify existing stock, sales, POS, authentication, or payment records.

create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  contact_person text not null default '',
  phone text not null default '',
  email text not null default '',
  category text not null default '',
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.suppliers enable row level security;

drop policy if exists "Authenticated users manage suppliers" on public.suppliers;
create policy "Authenticated users manage suppliers"
on public.suppliers
for all
to authenticated
using (true)
with check (true);

grant select, insert, update, delete on public.suppliers to authenticated;
