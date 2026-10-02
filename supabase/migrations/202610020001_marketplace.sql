-- Apply only to a new Supabase project dedicated to ARTZZY STORE.
create extension if not exists pgcrypto with schema extensions;
create type public.marketplace_role as enum ('customer', 'admin');
create type public.inventory_status as enum ('available', 'reserved', 'sold', 'rented', 'disabled');
create type public.order_kind as enum ('buy', 'rent');
create type public.order_state as enum ('pending_payment', 'paid', 'cancelled', 'expired', 'refund_required', 'refunded');
create type public.payment_state as enum ('pending', 'paid', 'failed', 'expired', 'refunded');
create type public.rental_state as enum ('active', 'expired', 'ended');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  role public.marketplace_role not null default 'customer',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.games (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  description text,
  cover_image_url text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete restrict,
  title text not null,
  description text not null default '',
  features text[] not null default '{}',
  cover_image_url text,
  buy_price numeric(10,2) check (buy_price is null or buy_price >= 0),
  status public.inventory_status not null default 'available',
  credential_payload jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.rental_plans (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  label text not null,
  duration_days integer not null check (duration_days > 0 and duration_days <= 365),
  price numeric(10,2) not null check (price > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(account_id, duration_days)
);
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references auth.users(id) on delete restrict,
  account_id uuid not null references public.accounts(id) on delete restrict,
  kind public.order_kind not null,
  rental_plan_id uuid references public.rental_plans(id) on delete restrict,
  amount numeric(10,2) not null check (amount > 0),
  status public.order_state not null default 'pending_payment',
  reservation_expires_at timestamptz not null default (now() + interval '30 minutes'),
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint rent_has_plan check ((kind = 'rent' and rental_plan_id is not null) or (kind = 'buy' and rental_plan_id is null))
);
create unique index one_pending_reservation_per_account on public.orders(account_id) where status = 'pending_payment';
create index orders_customer_created_idx on public.orders(customer_id, created_at desc);
create index orders_status_reservation_idx on public.orders(status, reservation_expires_at);
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete restrict,
  provider text not null default 'billplz' check (provider = 'billplz'),
  provider_bill_id text unique,
  amount numeric(10,2) not null check (amount > 0),
  status public.payment_state not null default 'pending',
  provider_paid_at timestamptz,
  raw_verified_callback jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.rentals (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete restrict,
  account_id uuid not null references public.accounts(id) on delete restrict,
  customer_id uuid not null references auth.users(id) on delete restrict,
  started_at timestamptz not null,
  expires_at timestamptz not null,
  status public.rental_state not null default 'active',
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  constraint valid_rental_period check (expires_at > started_at)
);
create index rentals_account_expiry_idx on public.rentals(account_id, expires_at desc);
create index rentals_customer_expiry_idx on public.rentals(customer_id, expires_at desc);
create table public.admin_audit_log (
  id bigint generated always as identity primary key,
  admin_id uuid references auth.users(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}',
  created_at timestamptz not null default now()
);

create function public.is_marketplace_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'admin');
$$;
create function public.create_profile_for_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id, display_name) values (new.id, coalesce(new.raw_user_meta_data->>'name', ''));
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.create_profile_for_new_user();

alter table public.profiles enable row level security;
alter table public.games enable row level security;
alter table public.accounts enable row level security;
alter table public.rental_plans enable row level security;
alter table public.orders enable row level security;
alter table public.payments enable row level security;
alter table public.rentals enable row level security;
alter table public.admin_audit_log enable row level security;
create policy "profiles read self or admins" on public.profiles for select using (id = (select auth.uid()) or public.is_marketplace_admin());
create policy "profiles update own display name" on public.profiles for update using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy "active games are public" on public.games for select using (is_active or public.is_marketplace_admin());
create policy "public account projection" on public.accounts for select using (status = 'available' or public.is_marketplace_admin());
create policy "rental plans are public" on public.rental_plans for select using (is_active or public.is_marketplace_admin());
create policy "orders read owner or admins" on public.orders for select using (customer_id = (select auth.uid()) or public.is_marketplace_admin());
create policy "payments read owner through order or admins" on public.payments for select using (exists (select 1 from public.orders o where o.id = order_id and (o.customer_id = (select auth.uid()) or public.is_marketplace_admin())));
create policy "rentals read owner or admins" on public.rentals for select using (customer_id = (select auth.uid()) or public.is_marketplace_admin());
create policy "audit read admins" on public.admin_audit_log for select using (public.is_marketplace_admin());

-- Deliberately allow-list public fields. Never select credential_payload in a public query.
create view public.public_account_catalog as
select a.id, a.title, a.description, a.features, a.cover_image_url, nullif(a.buy_price, 0) as buy_price,
       (select min(rp.price) from public.rental_plans rp where rp.account_id = a.id and rp.is_active) as rent_price,
       g.name as game_name, g.slug as game_slug, a.created_at,
       lower(a.title || ' ' || a.description || ' ' || g.name || ' ' || array_to_string(a.features, ' ')) as search_text
from public.accounts a join public.games g on g.id = a.game_id
where a.credential_payload is not null and g.is_active and (a.status = 'available'
  or (a.status = 'reserved' and not exists (select 1 from public.orders o where o.account_id = a.id and o.status = 'pending_payment' and o.reservation_expires_at > now()))
  or (a.status = 'rented' and exists (select 1 from public.rentals r where r.account_id = a.id and r.status = 'active' and r.expires_at <= now())));
grant select on public.public_account_catalog to anon, authenticated;
grant select on public.games, public.rental_plans to anon, authenticated;
grant select, update (display_name) on public.profiles to authenticated;
grant select on public.orders, public.payments, public.rentals to authenticated;
revoke all on public.accounts, public.admin_audit_log from anon, authenticated;
revoke all on public.orders, public.payments, public.rentals from anon;

create function public.reserve_checkout(p_account_id uuid, p_kind public.order_kind, p_rental_plan_id uuid default null)
returns table(order_id uuid, amount numeric, currency text)
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_account public.accounts%rowtype;
  v_amount numeric(10,2);
begin
  if v_user is null then raise exception 'Sign in required'; end if;
  select * into v_account from public.accounts a where a.id = p_account_id for update;
  if not found then raise exception 'Account unavailable'; end if;
  update public.orders o set status = 'expired', updated_at = now()
    where o.account_id = p_account_id and o.status = 'pending_payment' and o.reservation_expires_at <= now();
  if v_account.status = 'reserved' and not exists (select 1 from public.orders o where o.account_id = p_account_id and o.status = 'pending_payment') then
    update public.accounts set status = 'available', updated_at = now() where id = p_account_id;
    v_account.status := 'available';
  end if;
  if v_account.status in ('disabled','sold') then raise exception 'Account unavailable'; end if;
  if v_account.credential_payload is null then raise exception 'Account delivery details are not configured'; end if;
  if v_account.status = 'rented' and not exists (
      select 1 from public.rentals r where r.account_id = p_account_id and r.status = 'active' and r.expires_at > now()
  ) then
    update public.accounts set status = 'available', updated_at = now() where id = p_account_id;
    v_account.status := 'available';
  end if;
  if v_account.status <> 'available' then raise exception 'Account unavailable'; end if;
  if p_kind = 'buy' then
    if p_rental_plan_id is not null or coalesce(v_account.buy_price, 0) <= 0 then raise exception 'Purchase unavailable'; end if;
    v_amount := v_account.buy_price;
  else
    select rp.price into v_amount from public.rental_plans rp where rp.id = p_rental_plan_id and rp.account_id = p_account_id and rp.is_active;
    if p_rental_plan_id is null or coalesce(v_amount, 0) <= 0 then raise exception 'Rental unavailable'; end if;
  end if;
  insert into public.orders(customer_id, account_id, kind, rental_plan_id, amount)
    values (v_user, p_account_id, p_kind, p_rental_plan_id, v_amount) returning id into order_id;
  update public.accounts set status = 'reserved', updated_at = now() where id = p_account_id;
  insert into public.payments(order_id, amount) values (order_id, v_amount);
  return query select order_id, v_amount, 'MYR'::text;
end;
$$;

create function public.attach_billplz_bill(p_order_id uuid, p_bill_id text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.payments p set provider_bill_id = p_bill_id, updated_at = now()
    from public.orders o where p.order_id = o.id and o.id = p_order_id
      and o.customer_id = auth.uid() and o.status = 'pending_payment' and p.provider_bill_id is null;
  if not found then raise exception 'Order unavailable'; end if;
end;
$$;

create function public.apply_checkout_creation_failure(p_order_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_account_id uuid;
begin
  update public.orders set status = 'cancelled', updated_at = now()
    where id = p_order_id and status = 'pending_payment' returning account_id into v_account_id;
  if v_account_id is not null then
    update public.accounts set status = 'available', updated_at = now() where id = v_account_id and status = 'reserved';
  end if;
end;
$$;

create function public.apply_verified_billplz_payment(p_bill_id text, p_paid boolean, p_amount_cents integer, p_callback jsonb)
returns text language plpgsql security definer set search_path = '' as $$
declare v_order public.orders%rowtype; v_pay public.payments%rowtype; v_account public.accounts%rowtype;
begin
  select * into v_pay from public.payments where provider_bill_id = p_bill_id for update;
  if not found then raise exception 'Unknown bill'; end if;
  select * into v_order from public.orders where id = v_pay.order_id for update;
  if v_pay.status = 'paid' then return 'already_processed'; end if;
  if p_amount_cents <> round(v_pay.amount * 100)::integer then raise exception 'Payment amount mismatch'; end if;
  if not p_paid then
    update public.payments set status = 'failed', raw_verified_callback = p_callback, updated_at = now() where id = v_pay.id;
    update public.orders set status = 'cancelled', updated_at = now() where id = v_order.id and status = 'pending_payment';
    update public.accounts set status = 'available', updated_at = now() where id = v_order.account_id and status = 'reserved';
    return 'failed';
  end if;
  if v_order.status <> 'pending_payment' or v_order.reservation_expires_at <= now() then
    update public.payments set status = 'paid', provider_paid_at = now(), raw_verified_callback = p_callback, updated_at = now() where id = v_pay.id;
    update public.orders set status = 'refund_required', paid_at = now(), updated_at = now() where id = v_order.id;
    return 'refund_required';
  end if;
  select * into v_account from public.accounts where id = v_order.account_id for update;
  if v_account.status <> 'reserved' then
    update public.payments set status = 'paid', provider_paid_at = now(), raw_verified_callback = p_callback, updated_at = now() where id = v_pay.id;
    update public.orders set status = 'refund_required', paid_at = now(), updated_at = now() where id = v_order.id;
    return 'refund_required';
  end if;
  update public.payments set status = 'paid', provider_paid_at = now(), raw_verified_callback = p_callback, updated_at = now() where id = v_pay.id;
  update public.orders set status = 'paid', paid_at = now(), updated_at = now() where id = v_order.id;
  if v_order.kind = 'buy' then
    update public.accounts set status = 'sold', updated_at = now() where id = v_order.account_id;
  else
    insert into public.rentals(order_id, account_id, customer_id, started_at, expires_at)
      select v_order.id, v_order.account_id, v_order.customer_id, now(), now() + make_interval(days => rp.duration_days)
      from public.rental_plans rp where rp.id = v_order.rental_plan_id;
    update public.accounts set status = 'rented', updated_at = now() where id = v_order.account_id;
  end if;
  return 'paid';
end;
$$;

create function public.get_owned_account_credentials(p_order_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select a.credential_payload
  from public.orders o join public.accounts a on a.id = o.account_id
  left join public.rentals r on r.order_id = o.id
  where o.id = p_order_id and o.customer_id = (select auth.uid()) and o.status = 'paid'
    and a.credential_payload is not null
    and (o.kind = 'buy' or (r.status = 'active' and r.expires_at > now()));
$$;

create function public.get_my_orders()
returns table(order_id uuid, kind public.order_kind, amount numeric, order_status public.order_state,
  game_name text, account_title text, paid_at timestamptz, created_at timestamptz, server_now timestamptz,
  rental_id uuid, rental_status public.rental_state, rental_started_at timestamptz, rental_expires_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select o.id, o.kind, o.amount, o.status, g.name, a.title, o.paid_at, o.created_at, now(),
         r.id, case when r.id is null then null when r.status = 'active' and r.expires_at <= now() then 'expired'::public.rental_state else r.status end,
         r.started_at, r.expires_at
    from public.orders o join public.accounts a on a.id = o.account_id join public.games g on g.id = a.game_id
    left join public.rentals r on r.order_id = o.id
   where o.customer_id = (select auth.uid())
   order by o.created_at desc;
$$;

create function public.admin_extend_rental(p_rental_id uuid, p_days integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_days < 1 or p_days > 365 then raise exception 'Extension must be 1 to 365 days'; end if;
  update public.rentals set expires_at = greatest(expires_at, now()) + make_interval(days => p_days)
    where id = p_rental_id and status = 'active';
  if not found then raise exception 'Active rental not found'; end if;
end;
$$;
create function public.admin_end_rental(p_rental_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_rental public.rentals%rowtype;
begin
  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found'; end if;
  update public.rentals set status = 'ended', ended_at = now() where id = p_rental_id and status = 'active';
  if found then
    update public.accounts set status = 'available', updated_at = now()
      where id = v_rental.account_id and status = 'rented'
        and not exists (select 1 from public.rentals r where r.account_id = v_rental.account_id and r.status = 'active' and r.expires_at > now());
  end if;
end;
$$;

revoke all on function public.reserve_checkout(uuid, public.order_kind, uuid) from public, anon;
grant execute on function public.reserve_checkout(uuid, public.order_kind, uuid) to authenticated;
revoke all on function public.attach_billplz_bill(uuid, text) from public, anon;
grant execute on function public.attach_billplz_bill(uuid, text) to authenticated;
revoke all on function public.apply_checkout_creation_failure(uuid) from public, anon, authenticated;
grant execute on function public.apply_checkout_creation_failure(uuid) to service_role;
revoke all on function public.apply_verified_billplz_payment(text, boolean, integer, jsonb) from public, anon, authenticated;
grant execute on function public.apply_verified_billplz_payment(text, boolean, integer, jsonb) to service_role;
revoke all on function public.get_owned_account_credentials(uuid) from public, anon;
grant execute on function public.get_owned_account_credentials(uuid) to authenticated;
revoke all on function public.get_my_orders() from public, anon;
grant execute on function public.get_my_orders() to authenticated;
revoke all on function public.admin_extend_rental(uuid, integer) from public, anon, authenticated;
grant execute on function public.admin_extend_rental(uuid, integer) to service_role;
revoke all on function public.admin_end_rental(uuid) from public, anon, authenticated;
grant execute on function public.admin_end_rental(uuid) to service_role;
revoke all on function public.is_marketplace_admin() from public, anon;
grant execute on function public.is_marketplace_admin() to authenticated, service_role;
comment on column public.accounts.credential_payload is 'Secret access data; never expose in the public API.';

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('store-media', 'store-media', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy "public can view store images" on storage.objects for select using (bucket_id = 'store-media');
create policy "admins can upload store images" on storage.objects for insert to authenticated with check (bucket_id = 'store-media' and public.is_marketplace_admin());
create policy "admins can update store images" on storage.objects for update to authenticated using (bucket_id = 'store-media' and public.is_marketplace_admin()) with check (bucket_id = 'store-media' and public.is_marketplace_admin());
create policy "admins can delete store images" on storage.objects for delete to authenticated using (bucket_id = 'store-media' and public.is_marketplace_admin());
