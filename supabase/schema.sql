-- =====================================================================
--  לוח פרויקט צבירן - מבנה מסד הנתונים ב-Supabase
--  מריצים פעם אחת: Supabase > SQL Editor > New query > מדביקים > Run
-- =====================================================================

-- 1) טבלאות: כל טבלה = אוסף רשומות. כל רשומה היא id + data (JSON)
create table if not exists public.tasks   (id text primary key, data jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now());
create table if not exists public.issues  (id text primary key, data jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now());
create table if not exists public.changes (id text primary key, data jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now());
create table if not exists public.meta    (id text primary key, data jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now());

-- 2) רשימת המורשים: רק מיילים שמופיעים כאן יכולים לראות ולעדכן את הלוח
create table if not exists public.allowed_users (
  email text primary key,
  added_at timestamptz not null default now()
);

-- 3) בדיקה: האם המשתמש המחובר נמצא ברשימת המורשים
create or replace function public.is_member()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.allowed_users
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- 4) הרשאות (Row Level Security)
alter table public.tasks         enable row level security;
alter table public.issues        enable row level security;
alter table public.changes       enable row level security;
alter table public.meta          enable row level security;
alter table public.allowed_users enable row level security;

drop policy if exists "members read write" on public.tasks;
drop policy if exists "members read write" on public.issues;
drop policy if exists "members read write" on public.changes;
drop policy if exists "members read write" on public.meta;
create policy "members read write" on public.tasks   for all to authenticated using (public.is_member()) with check (public.is_member());
create policy "members read write" on public.issues  for all to authenticated using (public.is_member()) with check (public.is_member());
create policy "members read write" on public.changes for all to authenticated using (public.is_member()) with check (public.is_member());
create policy "members read write" on public.meta    for all to authenticated using (public.is_member()) with check (public.is_member());

-- כל משתמש מחובר יכול לבדוק רק אם המייל שלו עצמו ברשימה
drop policy if exists "see own row" on public.allowed_users;
create policy "see own row" on public.allowed_users for select to authenticated
  using (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));

-- 5) עדכון חלקי של רשומה (משנים רק את השדות שנשלחו, בלי לדרוס עדכון של המשתמש השני)
create or replace function public.merge_doc(tbl text, doc_id text, patch jsonb)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if tbl not in ('tasks','issues','changes','meta') then
    raise exception 'unknown table %', tbl;
  end if;
  execute format('update public.%I set data = data || $1, updated_at = now() where id = $2', tbl)
    using patch, doc_id;
end;
$$;
grant execute on function public.merge_doc(text, text, jsonb) to authenticated;
revoke execute on function public.merge_doc(text, text, jsonb) from anon;

-- 6) עדכונים בזמן אמת: כששותף משנה משהו, זה מופיע אצלך בלי לרענן
do $$
declare t text;
begin
  foreach t in array array['tasks','issues','changes','meta'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- 7) המשתמשים המורשים - מחליפים את המייל השני במייל של השותף
insert into public.allowed_users (email) values
    ('nir@zviran.co.il'),
   ('ilana@zviran.co.il')
on conflict (email) do nothing;
