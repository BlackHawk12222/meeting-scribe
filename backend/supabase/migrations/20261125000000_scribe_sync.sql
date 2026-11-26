-- Scribe accounts (0.7.3.2): encrypted backup + sync.
-- The server only ever stores CIPHERTEXT (AES-GCM, sealed on the Mac with a key the server never
-- sees) plus a few labels: the item kind, a random per-Mac device id, timestamps.
-- Row-level security: every signed-in user can read and write ONLY their own rows.

-- One row per (account, kind): dictionary, vocabulary, learned_fixes, styles, settings,
-- people, voiceprints.
create table if not exists public.sync_items (
    user_id     uuid        not null default auth.uid() references auth.users (id) on delete cascade,
    kind        text        not null check (kind ~ '^[a-z_]{1,32}$'),
    ciphertext  text        not null check (ciphertext like 'v1.%' and length(ciphertext) <= 8000000),
    device_id   text        check (device_id is null or length(device_id) <= 64),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    primary key (user_id, kind)
);

-- The key check: a fixed phrase sealed with the account's key, so a typed recovery key can be
-- verified on a new Mac. Reveals nothing about the key.
create table if not exists public.sync_keys (
    user_id    uuid        primary key default auth.uid() references auth.users (id) on delete cascade,
    key_check  text        not null check (key_check like 'v1.%' and length(key_check) <= 1000),
    created_at timestamptz not null default now()
);

-- The server sets updated_at (clients can't backdate it).
create or replace function public.scribe_touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

drop trigger if exists sync_items_touch on public.sync_items;
create trigger sync_items_touch
    before insert or update on public.sync_items
    for each row execute function public.scribe_touch_updated_at();

alter table public.sync_items enable row level security;
alter table public.sync_keys  enable row level security;
alter table public.sync_items force row level security;
alter table public.sync_keys  force row level security;

-- sync_items: own rows only.
drop policy if exists "own rows: select" on public.sync_items;
drop policy if exists "own rows: insert" on public.sync_items;
drop policy if exists "own rows: update" on public.sync_items;
drop policy if exists "own rows: delete" on public.sync_items;
create policy "own rows: select" on public.sync_items for select to authenticated
    using ((select auth.uid()) = user_id);
create policy "own rows: insert" on public.sync_items for insert to authenticated
    with check ((select auth.uid()) = user_id);
create policy "own rows: update" on public.sync_items for update to authenticated
    using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own rows: delete" on public.sync_items for delete to authenticated
    using ((select auth.uid()) = user_id);

-- sync_keys: own row only. Insert once; update allowed (same user) so a re-created key can replace it.
drop policy if exists "own key: select" on public.sync_keys;
drop policy if exists "own key: insert" on public.sync_keys;
drop policy if exists "own key: update" on public.sync_keys;
drop policy if exists "own key: delete" on public.sync_keys;
create policy "own key: select" on public.sync_keys for select to authenticated
    using ((select auth.uid()) = user_id);
create policy "own key: insert" on public.sync_keys for insert to authenticated
    with check ((select auth.uid()) = user_id);
create policy "own key: update" on public.sync_keys for update to authenticated
    using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "own key: delete" on public.sync_keys for delete to authenticated
    using ((select auth.uid()) = user_id);

-- No access at all for signed-out (anon) requests.
revoke all on public.sync_items from anon;
revoke all on public.sync_keys  from anon;
grant select, insert, update, delete on public.sync_items to authenticated;
grant select, insert, update, delete on public.sync_keys  to authenticated;

-- "Delete account and cloud data": removes the caller's rows and their sign-in account.
-- security definer so it may delete from auth.users, but it only ever touches auth.uid().
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := auth.uid();
begin
    if uid is null then
        raise exception 'not signed in';
    end if;
    delete from public.sync_items where user_id = uid;
    delete from public.sync_keys  where user_id = uid;
    delete from auth.users        where id = uid;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
