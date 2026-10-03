-- Switch the marketplace from credential delivery and payment checkout to
-- seller-arranged sales and owner-approved hourly rentals.

drop function if exists public.get_owned_account_credentials(uuid);
drop function if exists public.reserve_checkout(uuid, public.order_kind, uuid);

alter table public.accounts add column if not exists rent_hourly_price numeric(10,2)
  check (rent_hourly_price is null or rent_hourly_price > 0);

create table if not exists public.manual_rental_requests (
  id uuid primary key default gen_random_uuid(),
  access_token_hash text not null unique,
  account_id uuid not null references public.accounts(id) on delete restrict,
  game_name text not null,
  account_title text not null,
  customer_name text not null,
  customer_telegram text,
  duration_hours integer not null check (duration_hours between 1 and 168),
  hourly_rate numeric(10,2) not null check (hourly_rate > 0),
  total_price numeric(10,2) not null check (total_price > 0),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'ended')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  started_at timestamptz,
  expires_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint approved_rental_has_times check (status <> 'approved' or (started_at is not null and expires_at is not null and expires_at > started_at))
);
create index if not exists manual_rental_requests_status_created_idx on public.manual_rental_requests(status, created_at desc);
create index if not exists manual_rental_requests_account_expiry_idx on public.manual_rental_requests(account_id, expires_at desc);
alter table public.manual_rental_requests enable row level security;
revoke all on public.manual_rental_requests from anon, authenticated;
grant all on public.manual_rental_requests to service_role;

create or replace view public.public_account_catalog as
select a.id, a.title, a.description, a.features, a.cover_image_url,
       nullif(a.buy_price, 0) as buy_price,
       a.rent_hourly_price::numeric as rent_price,
       g.name as game_name, g.slug as game_slug, a.created_at,
       lower(a.title || ' ' || a.description || ' ' || g.name || ' ' || array_to_string(a.features, ' ')) as search_text
from public.accounts a join public.games g on g.id = a.game_id
where g.is_active and (a.status = 'available'
  or (a.status = 'reserved' and not exists (
    select 1 from public.orders o where o.account_id = a.id and o.status = 'pending_payment' and o.reservation_expires_at > now()))
  or (a.status = 'rented' and (
    exists (select 1 from public.manual_rental_requests mr where mr.account_id = a.id and mr.status = 'approved' and mr.expires_at <= now())
    or exists (select 1 from public.rentals r where r.account_id = a.id and r.status = 'active' and r.expires_at <= now())
  )));

-- Replacing the view first removes its dependency on this private field.
alter table public.accounts drop column if exists credential_payload;

create or replace function public.create_manual_rental_request(
  p_account_id uuid,
  p_duration_hours integer,
  p_customer_name text,
  p_customer_telegram text,
  p_access_token_hash text
) returns table(request_id uuid, game_name text, account_title text, hourly_rate numeric, total_price numeric)
language plpgsql security definer set search_path = '' as $$
declare v_account public.accounts%rowtype; v_game_name text; v_total numeric(10,2);
begin
  if p_duration_hours < 1 or p_duration_hours > 168 then raise exception 'Choose between 1 and 168 hours.'; end if;
  if length(trim(coalesce(p_customer_name, ''))) < 1 or length(trim(coalesce(p_customer_name, ''))) > 100 then raise exception 'Enter your name.'; end if;
  if p_customer_telegram is not null and (length(trim(p_customer_telegram)) < 2 or length(trim(p_customer_telegram)) > 64) then raise exception 'Check your optional Telegram username.'; end if;
  if length(coalesce(p_access_token_hash, '')) <> 64 then raise exception 'Invalid request token.'; end if;

  select a.* into v_account from public.accounts a where a.id = p_account_id for update;
  if not found then raise exception 'This account is no longer available.'; end if;
  if v_account.status = 'rented' and not exists (
    select 1 from public.manual_rental_requests mr where mr.account_id = p_account_id and mr.status = 'approved' and mr.expires_at > now()
  ) and not exists (
    select 1 from public.rentals r where r.account_id = p_account_id and r.status = 'active' and r.expires_at > now()
  ) then
    update public.accounts set status = 'available', updated_at = now() where id = p_account_id;
    v_account.status := 'available';
  end if;
  if v_account.status = 'reserved' and not exists (
    select 1 from public.orders o where o.account_id = p_account_id and o.status = 'pending_payment' and o.reservation_expires_at > now()
  ) then
    update public.accounts set status = 'available', updated_at = now() where id = p_account_id;
    v_account.status := 'available';
  end if;
  if v_account.status <> 'available' then raise exception 'This account is currently unavailable.'; end if;
  if coalesce(v_account.rent_hourly_price, 0) <= 0 then raise exception 'Renting is not available for this account.'; end if;
  if exists (
    select 1 from public.manual_rental_requests mr
    where p_customer_telegram is not null and lower(mr.customer_telegram) = lower(trim(p_customer_telegram))
      and mr.created_at > now() - interval '1 hour' and mr.status = 'pending'
    group by mr.customer_telegram having count(*) >= 5
  ) then raise exception 'Too many pending requests. Please message the seller on Telegram.'; end if;
  select g.name into v_game_name from public.games g where g.id = v_account.game_id and g.is_active;
  if v_game_name is null then raise exception 'This game is not available.'; end if;
  v_total := round(v_account.rent_hourly_price * p_duration_hours, 2);
  return query
    insert into public.manual_rental_requests(access_token_hash, account_id, game_name, account_title, customer_name,
      customer_telegram, duration_hours, hourly_rate, total_price)
    values (p_access_token_hash, p_account_id, v_game_name, v_account.title, trim(p_customer_name),
      nullif(trim(p_customer_telegram), ''), p_duration_hours, v_account.rent_hourly_price, v_total)
    returning id, manual_rental_requests.game_name, manual_rental_requests.account_title,
      manual_rental_requests.hourly_rate, manual_rental_requests.total_price;
end;
$$;

create or replace function public.approve_manual_rental_request(p_request_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_request public.manual_rental_requests%rowtype; v_account public.accounts%rowtype;
begin
  select * into v_request from public.manual_rental_requests where id = p_request_id for update;
  if not found or v_request.status <> 'pending' then raise exception 'Pending rental request not found.'; end if;
  select * into v_account from public.accounts where id = v_request.account_id for update;
  if not found then raise exception 'Account no longer exists.'; end if;
  if v_account.status = 'rented' and not exists (
    select 1 from public.manual_rental_requests mr where mr.account_id = v_account.id and mr.status = 'approved' and mr.expires_at > now()
  ) and not exists (
    select 1 from public.rentals r where r.account_id = v_account.id and r.status = 'active' and r.expires_at > now()
  ) then
    update public.accounts set status = 'available', updated_at = now() where id = v_account.id;
    v_account.status := 'available';
  end if;
  if v_account.status = 'reserved' and not exists (
    select 1 from public.orders o where o.account_id = v_account.id and o.status = 'pending_payment' and o.reservation_expires_at > now()
  ) then
    update public.accounts set status = 'available', updated_at = now() where id = v_account.id;
    v_account.status := 'available';
  end if;
  if v_account.status <> 'available' then raise exception 'This account has already been rented or is unavailable.'; end if;
  update public.manual_rental_requests set status = 'rejected', responded_at = now(), updated_at = now()
    where account_id = v_account.id and status = 'pending' and id <> v_request.id;
  update public.manual_rental_requests set status = 'approved', started_at = now(),
    expires_at = now() + make_interval(hours => v_request.duration_hours), responded_at = now(), updated_at = now()
    where id = v_request.id and status = 'pending';
  update public.accounts set status = 'rented', updated_at = now() where id = v_account.id;
end;
$$;

create or replace function public.reject_manual_rental_request(p_request_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.manual_rental_requests set status = 'rejected', responded_at = now(), updated_at = now()
    where id = p_request_id and status = 'pending';
  if not found then raise exception 'Pending rental request not found.'; end if;
end;
$$;

revoke all on function public.create_manual_rental_request(uuid, integer, text, text, text) from public, anon, authenticated;
revoke all on function public.approve_manual_rental_request(uuid) from public, anon, authenticated;
revoke all on function public.reject_manual_rental_request(uuid) from public, anon, authenticated;
grant execute on function public.create_manual_rental_request(uuid, integer, text, text, text) to service_role;
grant execute on function public.approve_manual_rental_request(uuid) to service_role;
grant execute on function public.reject_manual_rental_request(uuid) to service_role;
