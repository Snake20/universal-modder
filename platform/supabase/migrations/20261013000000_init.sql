-- Mashworks schema v1 (Phase 0 draft; refined in Phases 2–3).
-- Every table in `public` has RLS enabled; tests/rls.sql asserts it. Writes that change review state,
-- signatures, hashes or analytics happen only in Edge Functions using the service role (bypasses RLS).

create extension if not exists pgcrypto;

-- ------------------------------------------------------------------ enums
create type user_role as enum ('user', 'creator', 'moderator', 'admin');
create type mashup_visibility as enum ('draft', 'listed', 'unlisted', 'removed');
create type version_status as enum (
  'uploading', 'scanning', 'scan_failed', 'draft', 'in_review', 'changes_requested',
  'approved', 'published', 'rejected', 'yanked');
create type check_outcome as enum ('pass', 'warn', 'fail');
create type online_mode as enum ('offline', 'lan', 'self-hosted', 'mod-friendly-online');

-- ------------------------------------------------------------------ people
create table profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  handle       text unique not null check (handle ~ '^[a-z0-9_]{3,32}$'),
  display_name text not null default '',
  avatar_url   text,
  bio          text not null default '' check (length(bio) <= 2000),
  role         user_role not null default 'user',
  steam_id     text unique,
  discord_id   text unique,
  created_at   timestamptz not null default now()
);

create function is_moderator() returns boolean
  language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from profiles where id = auth.uid() and role in ('moderator', 'admin'));
$$;

create function handle_new_user() returns trigger
  language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into profiles (id, handle, display_name)
  values (new.id, 'user_' || substr(md5(new.id::text), 1, 16),
          coalesce(new.raw_user_meta_data ->> 'name', ''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- ------------------------------------------------------------------ game catalog
create table games (
  id              uuid primary key default gen_random_uuid(),
  slug            text unique not null,
  name            text not null,
  engine          text,
  steam_appid     text unique,
  epic_id         text unique,
  gog_id          text unique,
  xbox_pfn        text unique,
  anti_cheat      text[] not null default '{}',     -- e.g. {EasyAntiCheat}
  online_only     boolean not null default false,   -- no offline mode at all: mashups rejected
  allowed_modes   online_mode[] not null default '{offline}',
  safety_notes    text not null default '',          -- shown in the launcher warning
  created_at      timestamptz not null default now()
);

-- Hashes of real game files. Packages containing any of these are rejected. Never exposed to clients.
create table known_file_hashes (
  sha256     text primary key check (sha256 ~ '^[0-9a-f]{64}$'),
  sha1       text,
  size_bytes bigint,
  game_id    uuid references games (id) on delete set null,
  source     text not null,                          -- 'launcher-optin', 'moderator', 'depot-manifest'
  created_at timestamptz not null default now()
);
create index on known_file_hashes (sha1);

-- ------------------------------------------------------------------ mashups
create table mashups (
  id                uuid primary key default gen_random_uuid(),
  slug              text unique not null check (slug ~ '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$'),
  owner_id          uuid not null references profiles (id) on delete cascade,
  title             text not null check (length(title) between 3 and 80),
  summary           text not null default '' check (length(summary) <= 280),
  description       text not null default '' check (length(description) <= 20000),
  visibility        mashup_visibility not null default 'draft',
  featured          boolean not null default false,
  latest_version_id uuid,
  install_count     bigint not null default 0,
  rating_avg        numeric(3, 2) not null default 0,
  rating_count      integer not null default 0,
  source_repo       text,                             -- 'owner/repo' when published from GitHub
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index on mashups (visibility, created_at desc);

create table mashup_versions (
  id              uuid primary key default gen_random_uuid(),
  mashup_id       uuid not null references mashups (id) on delete cascade,
  version         text not null,
  status          version_status not null default 'uploading',
  manifest        jsonb,
  online_mode     online_mode,
  upload_path     text,                               -- storage: uploads/<uid>/<upload_id>.mashup (private)
  package_path    text,                               -- storage: packages/<mashup>/<version>.mashup (after signing)
  package_sha256  text,
  size_bytes      bigint,
  signature       jsonb,                              -- {statement, sig, key_id}
  changelog       text not null default '',
  created_at      timestamptz not null default now(),
  published_at    timestamptz,
  unique (mashup_id, version)
);
alter table mashups add constraint mashups_latest_fk
  foreign key (latest_version_id) references mashup_versions (id) on delete set null;

create table version_games (
  version_id uuid not null references mashup_versions (id) on delete cascade,
  game_id    uuid not null references games (id),
  key        text not null,
  primary key (version_id, game_id)
);
create index on version_games (game_id);

create table dependencies (
  id         uuid primary key default gen_random_uuid(),
  version_id uuid not null references mashup_versions (id) on delete cascade,
  dep_key    text not null,
  name       text not null,
  kind       text not null default 'mod',
  version    text not null,
  license    text not null,
  authors    jsonb not null,
  source     jsonb not null,
  sha256     text not null,
  verified   boolean not null default false           -- scanner downloaded it from source and matched sha256
);

create table credits (
  id         uuid primary key default gen_random_uuid(),
  version_id uuid not null references mashup_versions (id) on delete cascade,
  name       text not null,
  role       text not null,
  url        text,
  license    text
);

create table media (
  id         uuid primary key default gen_random_uuid(),
  mashup_id  uuid not null references mashups (id) on delete cascade,
  kind       text not null check (kind in ('image', 'video')),
  path       text not null,
  alt        text not null default '',
  sort       integer not null default 0
);

-- ------------------------------------------------------------------ visibility helpers
create function mashup_is_public(m mashups) returns boolean language sql immutable as $$
  select m.visibility in ('listed', 'unlisted');
$$;

create function can_see_version(v_id uuid) returns boolean
  language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from mashup_versions v join mashups m on m.id = v.mashup_id
    where v.id = v_id and (
      (m.visibility in ('listed', 'unlisted') and v.status in ('published', 'yanked'))
      or m.owner_id = auth.uid()
      or is_moderator()));
$$;

-- ------------------------------------------------------------------ social
create table ratings (
  mashup_id  uuid not null references mashups (id) on delete cascade,
  user_id    uuid not null references profiles (id) on delete cascade,
  stars      smallint not null check (stars between 1 and 5),
  created_at timestamptz not null default now(),
  primary key (mashup_id, user_id)
);

create table comments (
  id         uuid primary key default gen_random_uuid(),
  mashup_id  uuid not null references mashups (id) on delete cascade,
  user_id    uuid not null references profiles (id) on delete cascade,
  parent_id  uuid references comments (id) on delete cascade,
  body       text not null check (length(body) between 1 and 5000),
  hidden     boolean not null default false,
  created_at timestamptz not null default now()
);

create table reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references profiles (id) on delete cascade,
  target_type text not null check (target_type in ('mashup', 'version', 'comment', 'profile')),
  target_id   uuid not null,
  reason      text not null check (reason in ('malware', 'game-files', 'online-cheat', 'license', 'abuse', 'other')),
  details     text not null default '',
  status      text not null default 'open' check (status in ('open', 'actioned', 'dismissed')),
  created_at  timestamptz not null default now()
);

-- ------------------------------------------------------------------ pipeline
create table upload_sessions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles (id) on delete cascade,
  mashup_id   uuid references mashups (id) on delete cascade,
  path        text not null,
  max_bytes   bigint not null default 536870912,
  status      text not null default 'open' check (status in ('open', 'sealed', 'expired')),
  expires_at  timestamptz not null default now() + interval '1 hour',
  created_at  timestamptz not null default now()
);

create table scan_jobs (
  id          bigint generated always as identity primary key,
  version_id  uuid not null references mashup_versions (id) on delete cascade,
  state       text not null default 'queued' check (state in ('queued', 'running', 'done', 'error')),
  attempts    integer not null default 0,
  locked_at   timestamptz,
  created_at  timestamptz not null default now()
);

create table scan_results (
  id          uuid primary key default gen_random_uuid(),
  version_id  uuid not null references mashup_versions (id) on delete cascade,
  check_name  text not null,
  outcome     check_outcome not null,
  details     jsonb not null default '{}',
  created_at  timestamptz not null default now()
);

create table review_actions (
  id           uuid primary key default gen_random_uuid(),
  version_id   uuid not null references mashup_versions (id) on delete cascade,
  moderator_id uuid not null references profiles (id),
  action       text not null check (action in ('approve', 'reject', 'request_changes', 'yank', 'note')),
  notes        text not null default '',
  created_at   timestamptz not null default now()
);

create table api_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles (id) on delete cascade,
  name        text not null,
  token_hash  text not null unique,                   -- sha256 of the token; the token is shown once
  scopes      text[] not null default '{drafts:write}',
  last_used   timestamptz,
  revoked_at  timestamptz,
  created_at  timestamptz not null default now()
);

create table install_events (
  id          bigint generated always as identity primary key,
  version_id  uuid not null references mashup_versions (id) on delete cascade,
  event       text not null check (event in ('install', 'uninstall', 'repair', 'launch', 'error')),
  install_ref uuid,                                    -- random per-install id, not a user id
  created_at  timestamptz not null default now()
);

create table takedown_requests (
  id              uuid primary key default gen_random_uuid(),
  claimant_name   text not null,
  claimant_email  text not null,
  mashup_id       uuid references mashups (id) on delete set null,
  work            text not null,
  infringing_urls text[] not null default '{}',
  good_faith      boolean not null check (good_faith),
  accuracy        boolean not null check (accuracy),
  signature       text not null,
  status          text not null default 'received' check (status in ('received', 'actioned', 'rejected', 'countered')),
  created_at      timestamptz not null default now()
);

create table invites (
  code        text primary key default encode(gen_random_bytes(9), 'base64'),
  host_id     uuid not null references profiles (id) on delete cascade,
  version_id  uuid not null references mashup_versions (id) on delete cascade,
  connect     jsonb not null default '{}',             -- e.g. {"host":"1.2.3.4","port":7777} or a Steam lobby id
  max_uses    integer not null default 8,
  uses        integer not null default 0,
  expires_at  timestamptz not null default now() + interval '24 hours',
  created_at  timestamptz not null default now()
);

-- ------------------------------------------------------------------ RLS
alter table profiles          enable row level security;
alter table games             enable row level security;
alter table known_file_hashes enable row level security;
alter table mashups           enable row level security;
alter table mashup_versions   enable row level security;
alter table version_games     enable row level security;
alter table dependencies      enable row level security;
alter table credits           enable row level security;
alter table media             enable row level security;
alter table ratings           enable row level security;
alter table comments          enable row level security;
alter table reports           enable row level security;
alter table upload_sessions   enable row level security;
alter table scan_jobs         enable row level security;
alter table scan_results      enable row level security;
alter table review_actions    enable row level security;
alter table api_tokens        enable row level security;
alter table install_events    enable row level security;
alter table takedown_requests enable row level security;
alter table invites           enable row level security;

-- Column-level guard: users may edit their profile but never their role or linked ids.
revoke update on profiles from anon, authenticated;
grant update (handle, display_name, avatar_url, bio) on profiles to authenticated;
create policy profiles_read on profiles for select using (true);
create policy profiles_update_own on profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy games_read on games for select using (true);
create policy games_mod_write on games for all to authenticated using (is_moderator()) with check (is_moderator());

-- known_file_hashes, scan_jobs, upload_sessions(write), install_events, takedown_requests(read): no client policies
-- => denied to anon/authenticated; service role only.

-- Creators may edit text fields of their mashup, not counters, featured flag or the latest version pointer.
revoke update on mashups from anon, authenticated;
grant update (title, summary, description, visibility) on mashups to authenticated;
create policy mashups_read on mashups for select
  using (visibility = 'listed' or visibility = 'unlisted' or owner_id = auth.uid() or is_moderator());
create policy mashups_insert_own on mashups for insert to authenticated
  with check (owner_id = auth.uid() and visibility = 'draft' and featured = false);
create policy mashups_update_own on mashups for update to authenticated
  using (owner_id = auth.uid() or is_moderator())
  -- 'removed' is a moderator-only state
  with check ((owner_id = auth.uid() and visibility <> 'removed') or is_moderator());
create policy mashups_delete_own on mashups for delete to authenticated using (owner_id = auth.uid());

-- Versions: read-only to clients. All state changes go through Edge Functions.
create policy versions_read on mashup_versions for select using (can_see_version(id));
create policy version_games_read on version_games for select using (can_see_version(version_id));
create policy dependencies_read on dependencies for select using (can_see_version(version_id));
create policy credits_read on credits for select using (can_see_version(version_id));

create policy media_read on media for select using (
  exists (select 1 from mashups m where m.id = mashup_id
          and (m.visibility in ('listed', 'unlisted') or m.owner_id = auth.uid() or is_moderator())));
create policy media_owner_write on media for all to authenticated
  using (exists (select 1 from mashups m where m.id = mashup_id and m.owner_id = auth.uid()))
  with check (exists (select 1 from mashups m where m.id = mashup_id and m.owner_id = auth.uid()));

create policy ratings_read on ratings for select using (true);
create policy ratings_write_own on ratings for insert to authenticated with check (
  user_id = auth.uid()
  and exists (select 1 from mashups m where m.id = mashup_id and m.visibility = 'listed' and m.owner_id <> auth.uid()));
create policy ratings_update_own on ratings for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy ratings_delete_own on ratings for delete to authenticated using (user_id = auth.uid());

revoke update on comments from anon, authenticated;
grant update (body) on comments to authenticated;
grant update (hidden) on comments to authenticated;   -- policy below limits hidden changes to moderators
create policy comments_read on comments for select
  using (not hidden or user_id = auth.uid() or is_moderator());
create policy comments_insert_own on comments for insert to authenticated with check (
  user_id = auth.uid() and hidden = false
  and exists (select 1 from mashups m where m.id = mashup_id and m.visibility in ('listed', 'unlisted')));
create policy comments_update on comments for update to authenticated
  using (user_id = auth.uid() or is_moderator())
  with check (is_moderator() or user_id = auth.uid());
create policy comments_delete_own on comments for delete to authenticated using (user_id = auth.uid() or is_moderator());

create policy reports_insert_own on reports for insert to authenticated
  with check (reporter_id = auth.uid() and status = 'open');
create policy reports_read on reports for select to authenticated using (reporter_id = auth.uid() or is_moderator());
create policy reports_mod_update on reports for update to authenticated using (is_moderator()) with check (is_moderator());

create policy uploads_read_own on upload_sessions for select to authenticated using (user_id = auth.uid());

create policy scan_results_read on scan_results for select to authenticated using (
  is_moderator() or exists (select 1 from mashup_versions v join mashups m on m.id = v.mashup_id
                            where v.id = version_id and m.owner_id = auth.uid()));
create policy review_actions_read on review_actions for select to authenticated using (
  is_moderator() or exists (select 1 from mashup_versions v join mashups m on m.id = v.mashup_id
                            where v.id = version_id and m.owner_id = auth.uid()));

-- Token hashes are never readable by clients, even the owner's.
revoke select on api_tokens from anon, authenticated;
grant select (id, user_id, name, scopes, last_used, revoked_at, created_at) on api_tokens to authenticated;
revoke update on api_tokens from anon, authenticated;
grant update (revoked_at) on api_tokens to authenticated;
create policy tokens_read_own on api_tokens for select to authenticated using (user_id = auth.uid());
create policy tokens_revoke_own on api_tokens for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy takedown_mod_read on takedown_requests for select to authenticated using (is_moderator());

create policy invites_read_own on invites for select to authenticated using (host_id = auth.uid());
create policy invites_insert_own on invites for insert to authenticated with check (
  host_id = auth.uid() and can_see_version(version_id) and uses = 0);
create policy invites_delete_own on invites for delete to authenticated using (host_id = auth.uid());

-- Moderator-only transitions that column grants cannot express.
create function guard_mashup_update() returns trigger
  language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not is_moderator() and auth.role() <> 'service_role' then
    if old.visibility = 'removed' then
      raise exception 'removed by a moderator; appeal through the takedown flow' using errcode = '42501';
    end if;
    if new.visibility = 'listed' and new.latest_version_id is null then
      raise exception 'a mashup needs a published version before it can be listed' using errcode = '42501';
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger mashups_guard before update on mashups for each row execute function guard_mashup_update();

create function guard_comment_update() returns trigger
  language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.hidden is distinct from old.hidden and not is_moderator() then
    raise exception 'only moderators can hide or unhide comments' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger comments_guard before update on comments for each row execute function guard_comment_update();

-- Creator analytics without exposing raw install events.
create function creator_stats(p_mashup uuid)
  returns table (version text, event text, day date, n bigint)
  language sql stable security definer set search_path = public, pg_temp as $$
  select v.version, e.event, e.created_at::date, count(*)
  from install_events e join mashup_versions v on v.id = e.version_id join mashups m on m.id = v.mashup_id
  where m.id = p_mashup and (m.owner_id = auth.uid() or is_moderator())
  group by 1, 2, 3 order by 3 desc;
$$;

-- Public discover view (security_invoker so RLS on mashups still applies).
create view mashups_public with (security_invoker = true) as
  select m.id, m.slug, m.title, m.summary, m.featured, m.install_count, m.rating_avg, m.rating_count,
         m.created_at, m.updated_at, v.version as latest_version, v.online_mode,
         (select array_agg(g.slug order by g.slug) from version_games vg join games g on g.id = vg.game_id
           where vg.version_id = v.id) as games
  from mashups m left join mashup_versions v on v.id = m.latest_version_id
  where m.visibility = 'listed';

grant usage on schema public to anon, authenticated;
grant select on all tables in schema public to anon, authenticated;
grant insert, delete on mashups, media, ratings, comments, reports, invites to authenticated;
grant update (stars) on ratings to authenticated;
grant update (status) on reports to authenticated;
grant update on games to authenticated;
grant insert, delete on games to authenticated;
-- re-apply the column-limited selects (the blanket grant above re-opened them)
revoke select on api_tokens from anon, authenticated;
grant select (id, user_id, name, scopes, last_used, revoked_at, created_at) on api_tokens to authenticated;
revoke select on known_file_hashes, scan_jobs, install_events from anon, authenticated;
grant execute on function creator_stats(uuid) to authenticated;
