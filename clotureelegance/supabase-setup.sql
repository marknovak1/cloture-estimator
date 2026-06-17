-- =========================================================
-- MT Clôture Élégance — Fence Estimator
-- Supabase database setup. Run ONCE:
--   Supabase Dashboard -> SQL Editor -> New query -> paste -> Run
-- Safe to re-run (idempotent).
-- =========================================================

-- ---------- PROFILES (user roles) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  role text not null default 'sales' check (role in ('admin','sales')),
  created_at timestamptz default now()
);

-- Auto-create a profile when a user signs up.
-- marknovak77@gmail.com is bootstrapped as ADMIN; everyone else = sales.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, role)
  values (
    new.id,
    new.email,
    case when lower(new.email) = 'marknovak77@gmail.com' then 'admin' else 'sales' end
  )
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Helper: is the current user an admin?
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- ---------- PRODUCTS & PRICING ----------
create table if not exists public.products (
  id text primary key,
  name_fr text not null,
  name_en text not null,
  sort int default 0,
  active boolean default true
);

create table if not exists public.product_heights (
  id bigint generated always as identity primary key,
  product_id text references public.products(id) on delete cascade,
  height_ft numeric not null,
  rate numeric not null,
  unique (product_id, height_ft)
);

create table if not exists public.settings (
  id int primary key default 1,
  walk_gate numeric default 450,
  drive_gate numeric default 1200,
  removal_per_ft numeric default 6,
  slope_pct numeric default 12,
  range_pct numeric default 15,
  min_project numeric default 1500,
  constraint settings_singleton check (id = 1)
);

-- ---------- ESTIMATES ----------
create sequence if not exists public.estimate_seq;

create table if not exists public.estimates (
  id uuid primary key default gen_random_uuid(),
  est_no text unique,
  customer_name text,
  customer_email text,
  customer_phone text,
  customer_postal text,
  message text,
  product_id text,
  product_name text,
  height_ft numeric,
  length_ft numeric,
  walk_gates int default 0,
  drive_gates int default 0,
  terrain text,
  removal boolean default false,
  price_low numeric,
  price_high numeric,
  created_by_email text,
  created_by_uid uuid,
  status text default 'new',
  created_at timestamptz default now()
);

-- Auto estimate number: CE-YYYY-#### (e.g. CE-2026-0001)
create or replace function public.set_estimate_no()
returns trigger language plpgsql as $$
begin
  if new.est_no is null then
    new.est_no := 'CE-' || to_char(now(),'YYYY') || '-' ||
                  lpad(nextval('public.estimate_seq')::text, 4, '0');
  end if;
  return new;
end; $$;

drop trigger if exists trg_estimate_no on public.estimates;
create trigger trg_estimate_no before insert on public.estimates
  for each row execute function public.set_estimate_no();

-- ---------- ROW LEVEL SECURITY ----------
alter table public.profiles        enable row level security;
alter table public.products        enable row level security;
alter table public.product_heights enable row level security;
alter table public.settings        enable row level security;
alter table public.estimates       enable row level security;

-- profiles: read own or admin; admin can update roles
drop policy if exists "profiles read"   on public.profiles;
drop policy if exists "profiles update" on public.profiles;
create policy "profiles read"   on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy "profiles update" on public.profiles for update using (public.is_admin());

-- pricing: readable by everyone (public estimator needs prices), writable by admin only
drop policy if exists "products read"  on public.products;
drop policy if exists "products write" on public.products;
create policy "products read"  on public.products for select using (true);
create policy "products write" on public.products for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "heights read"  on public.product_heights;
drop policy if exists "heights write" on public.product_heights;
create policy "heights read"  on public.product_heights for select using (true);
create policy "heights write" on public.product_heights for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "settings read"  on public.settings;
drop policy if exists "settings write" on public.settings;
create policy "settings read"  on public.settings for select using (true);
create policy "settings write" on public.settings for all using (public.is_admin()) with check (public.is_admin());

-- estimates: anyone may create (public website + sales); read/update = admin all, sales own
drop policy if exists "estimates insert" on public.estimates;
drop policy if exists "estimates read"   on public.estimates;
drop policy if exists "estimates update" on public.estimates;
create policy "estimates insert" on public.estimates for insert with check (true);
create policy "estimates read"   on public.estimates for select using (public.is_admin() or created_by_uid = auth.uid());
create policy "estimates update" on public.estimates for update using (public.is_admin() or created_by_uid = auth.uid());

-- ---------- PRIVILEGES (RLS still gates everything above) ----------
grant usage on schema public to anon, authenticated;
grant select on public.products, public.product_heights, public.settings to anon, authenticated;
grant insert, select on public.estimates to anon, authenticated;
grant update on public.estimates to authenticated;
grant select, update on public.profiles to authenticated;
grant insert, update, delete on public.products, public.product_heights, public.settings to authenticated;
grant usage on sequence public.estimate_seq to anon, authenticated;

-- ---------- SEED DATA (placeholder rates — edit later in the Admin Config page) ----------
insert into public.settings (id) values (1) on conflict (id) do nothing;

insert into public.products (id,name_fr,name_en,sort) values
  ('alu','Clôture ornementale en aluminium','Aluminum ornamental fence',1),
  ('glass','Clôture en verre (Spego)','Glass fence (Spego)',2),
  ('comp','Clôture composite (fibre de bois)','Composite (fiberwood) fence',3),
  ('chain','Clôture à mailles de chaîne (frost)','Chain-link fence (frost)',4)
on conflict (id) do nothing;

insert into public.product_heights (product_id,height_ft,rate) values
  ('alu',4,55),('alu',5,65),('alu',6,75),
  ('glass',3.5,130),('glass',4,145),
  ('comp',6,68),('comp',8,82),
  ('chain',4,26),('chain',5,30),('chain',6,35),('chain',8,48)
on conflict (product_id,height_ft) do nothing;

-- Done. You should see: Success. No rows returned.
