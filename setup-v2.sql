-- ============================================================
-- setup-v2.sql  —  jalankan SEKALI di Supabase > SQL Editor
-- (aman dijalankan meski setup-pengajuan.sql sudah pernah dijalankan)
-- ============================================================

-- 0) GANTI email di bawah dengan email akun ADMIN kamu (yang dipakai login sekarang)
create table if not exists public.admins (user_id uuid primary key references auth.users(id) on delete cascade);
alter table public.admins enable row level security;   -- tanpa policy = tidak bisa diakses dari aplikasi
insert into public.admins (user_id)
  select id from auth.users where lower(email) = lower('GANTI_DENGAN_EMAIL_ADMIN_KAMU')
  on conflict do nothing;

-- Pengaman: kalau email admin salah, seluruh script dibatalkan supaya kamu tidak terkunci
do $$ begin
  if not exists (select 1 from public.admins) then
    raise exception 'Email admin tidak ditemukan. Ganti GANTI_DENGAN_EMAIL_ADMIN_KAMU di baris atas.';
  end if;
end $$;

create or replace function public.is_admin() returns boolean
  language sql security definer set search_path = public stable
  as $$ select exists (select 1 from public.admins where user_id = auth.uid()) $$;
grant execute on function public.is_admin() to authenticated;

-- 1) Profil kreditur (otomatis dibuat saat mendaftar)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nama text not null default '', email text, hp text not null default '',
  created_at timestamptz not null default now());
alter table public.profiles enable row level security;
drop policy if exists "profil lihat" on public.profiles;
create policy "profil lihat" on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
grant select on public.profiles to authenticated;

create or replace function public.handle_new_user() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, nama, hp)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'nama',''), coalesce(new.raw_user_meta_data->>'hp',''))
  on conflict do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 2) Tabel kredit: hanya admin; kreditur melihat lewat view yang TIDAK memuat modal/untung
alter table public.kredit add column if not exists user_id uuid references auth.users(id) on delete set null;
do $$ declare p record; begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='kredit' loop
    execute format('drop policy %I on public.kredit', p.policyname);
  end loop;
end $$;
alter table public.kredit enable row level security;
create policy "admin kredit" on public.kredit for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke all on public.kredit from anon;

create or replace view public.kredit_saya as
  select id, nama, ket, tgl, dp, angs, bulan, sisa, bayar, tanda
  from public.kredit where user_id = auth.uid();
revoke all on public.kredit_saya from anon;
grant select on public.kredit_saya to authenticated;

-- 3) Pengajuan (kini wajib login sebagai kreditur)
create table if not exists public.pengajuan (
  id bigint generated always as identity primary key,
  nama text not null, hp text not null default '', barang text not null,
  dp numeric not null default 0 check (dp >= 0), ktp text,
  status text not null default 'baru' check (status in ('baru','disetujui','ditolak')),
  created_at timestamptz not null default now());
alter table public.pengajuan add column if not exists user_id uuid references auth.users(id) on delete set null;
alter table public.pengajuan add column if not exists email text;
alter table public.pengajuan alter column ktp drop not null;
alter table public.pengajuan enable row level security;
drop policy if exists "kreditur kirim" on public.pengajuan;
drop policy if exists "admin lihat" on public.pengajuan;
drop policy if exists "admin ubah" on public.pengajuan;
drop policy if exists "admin hapus" on public.pengajuan;
create policy "kreditur kirim" on public.pengajuan for insert to authenticated
  with check (user_id = auth.uid() and status = 'baru');
create policy "lihat pengajuan" on public.pengajuan for select to authenticated
  using (public.is_admin() or user_id = auth.uid());
create policy "admin ubah pengajuan" on public.pengajuan for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "admin hapus pengajuan" on public.pengajuan for delete to authenticated
  using (public.is_admin());
revoke all on public.pengajuan from anon;
grant select, insert, update, delete on public.pengajuan to authenticated;

-- 4) Bukti pembayaran (perlu ACC admin)
create or replace function public.owns_kredit(k bigint) returns boolean
  language sql security definer set search_path = public stable
  as $$ select exists (select 1 from public.kredit where id = k and user_id = auth.uid()) $$;
grant execute on function public.owns_kredit(bigint) to authenticated;

create table if not exists public.pembayaran (
  id bigint generated always as identity primary key,
  kredit_id bigint not null,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  jumlah int not null default 1 check (jumlah between 1 and 120),
  tgl date not null default current_date,
  foto text not null check (foto like 'data:image/jpeg;base64,%' and char_length(foto) < 900000),
  status text not null default 'menunggu' check (status in ('menunggu','disetujui','ditolak')),
  catatan text not null default '',
  created_at timestamptz not null default now());
alter table public.pembayaran enable row level security;
create policy "kreditur kirim bayar" on public.pembayaran for insert to authenticated
  with check (user_id = auth.uid() and status = 'menunggu' and public.owns_kredit(kredit_id));
create policy "lihat bayar" on public.pembayaran for select to authenticated
  using (public.is_admin() or user_id = auth.uid());
create policy "admin ubah bayar" on public.pembayaran for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "admin hapus bayar" on public.pembayaran for delete to authenticated
  using (public.is_admin());
revoke all on public.pembayaran from anon;
grant select, insert, update, delete on public.pembayaran to authenticated;

-- 5) Langganan notifikasi push
create table if not exists public.push_subs (
  endpoint text primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  sub jsonb not null, created_at timestamptz not null default now());
alter table public.push_subs enable row level security;
create policy "push milik sendiri" on public.push_subs for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.push_subs from anon;
grant select, insert, update, delete on public.push_subs to authenticated;

-- 6) (OPSIONAL, untuk notifikasi) jadwal harian 08:00 WIB. Jalankan SETELAH Edge Function
--    'kirim-pengingat' ter-deploy dan extension pg_cron + pg_net aktif
--    (Database > Extensions). Ganti PROJECT_REF dan RAHASIA_CRON.
-- select cron.schedule('pengingat-harian', '0 1 * * *', $$
--   select net.http_post(
--     url := 'https://PROJECT_REF.supabase.co/functions/v1/kirim-pengingat',
--     headers := '{"Content-Type":"application/json","x-cron-secret":"RAHASIA_CRON"}'::jsonb) $$);
