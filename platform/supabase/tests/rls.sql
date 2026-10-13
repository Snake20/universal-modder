-- RLS tests. Run: platform/supabase/tests/run.sh (applies shim + migrations to a throwaway database).
\set ON_ERROR_STOP on
set client_min_messages = notice;

-- helpers --------------------------------------------------------------------------------------
create function pg_temp.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(uid::text, ''), false);
  perform set_config('request.jwt.claim.role', case when uid is null then 'anon' else 'authenticated' end, false);
end $$;

create function pg_temp.expect_count(label text, q text, n bigint) returns void language plpgsql as $$
declare got bigint;
begin
  execute 'select count(*) from (' || q || ') t' into got;
  if got <> n then raise exception 'FAIL %: expected % rows, got %', label, n, got; end if;
  raise notice 'ok   %', label;
end $$;

create function pg_temp.expect_denied(label text, q text) returns void language plpgsql as $$
declare affected bigint;
begin
  begin
    execute q;
    get diagnostics affected = row_count;
  exception when insufficient_privilege or check_violation then
    raise notice 'ok   % (denied)', label; return;
  end;
  if affected = 0 then raise notice 'ok   % (0 rows affected)', label; return; end if;
  raise exception 'FAIL %: statement succeeded on % rows', label, affected;
end $$;

-- seed (as superuser, bypasses RLS) -------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'creator@test'),
  ('00000000-0000-0000-0000-00000000000b', 'player@test'),
  ('00000000-0000-0000-0000-00000000000c', 'mod@test');
update profiles set handle = 'creator', role = 'creator' where id = '00000000-0000-0000-0000-00000000000a';
update profiles set handle = 'player' where id = '00000000-0000-0000-0000-00000000000b';
update profiles set handle = 'moderator', role = 'moderator' where id = '00000000-0000-0000-0000-00000000000c';

insert into games (id, slug, name, steam_appid) values
  ('10000000-0000-0000-0000-000000000001', 'test-game', 'Test Game', '480');
insert into known_file_hashes (sha256, source) values (repeat('ab', 32), 'moderator');

insert into mashups (id, slug, owner_id, title, visibility) values
  ('20000000-0000-0000-0000-000000000001', 'live-mash', '00000000-0000-0000-0000-00000000000a', 'Live mashup', 'draft'),
  ('20000000-0000-0000-0000-000000000002', 'secret-mash', '00000000-0000-0000-0000-00000000000a', 'Draft mashup', 'draft');
insert into mashup_versions (id, mashup_id, version, status) values
  ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', '1.0.0', 'published'),
  ('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', '1.1.0', 'in_review'),
  ('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', '0.1.0', 'scanning');
update mashups set latest_version_id = '30000000-0000-0000-0000-000000000001', visibility = 'listed'
  where id = '20000000-0000-0000-0000-000000000001';
insert into version_games values ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'testgame');
insert into scan_results (version_id, check_name, outcome) values ('30000000-0000-0000-0000-000000000002', 'clamav', 'pass');
insert into install_events (version_id, event) values ('30000000-0000-0000-0000-000000000001', 'install');
insert into api_tokens (user_id, name, token_hash) values ('00000000-0000-0000-0000-00000000000a', 'cli', repeat('cd', 32));

-- every public table has RLS ---------------------------------------------------------------------
select pg_temp.expect_count('RLS enabled on every public table',
  $$ select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity $$, 0);

-- anon ---------------------------------------------------------------------------------------------
set role anon; select pg_temp.as_user(null);
select pg_temp.expect_count('anon sees listed mashups only', 'select * from mashups', 1);
select pg_temp.expect_count('anon sees published versions only', 'select * from mashup_versions', 1);
select pg_temp.expect_count('anon discover view', 'select * from mashups_public', 1);
select pg_temp.expect_count('anon sees version games', 'select * from version_games', 1);
select pg_temp.expect_count('anon sees no scan results', 'select * from scan_results', 0);
select pg_temp.expect_denied('anon cannot read known game hashes', 'select * from known_file_hashes');
select pg_temp.expect_denied('anon cannot read install events', 'select * from install_events');
select pg_temp.expect_denied('anon cannot create a mashup',
  $$ insert into mashups (slug, owner_id, title) values ('x-x-x', '00000000-0000-0000-0000-00000000000b', 'nope') $$);
reset role;

-- regular user -----------------------------------------------------------------------------------
set role authenticated; select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select pg_temp.expect_count('player cannot see another creator''s draft', $$ select * from mashups where slug = 'secret-mash' $$, 0);
select pg_temp.expect_denied('player cannot promote themselves', $$ update profiles set role = 'moderator' where id = auth.uid() $$);
select pg_temp.expect_denied('player cannot edit someone else''s mashup', $$ update mashups set title = 'pwned' where slug = 'live-mash' $$);
select pg_temp.expect_denied('player cannot publish a version', $$ update mashup_versions set status = 'published' $$);
select pg_temp.expect_denied('player cannot create a mashup for someone else',
  $$ insert into mashups (slug, owner_id, title) values ('stolen', '00000000-0000-0000-0000-00000000000a', 'stolen') $$);
select pg_temp.expect_denied('player cannot self-feature',
  $$ insert into mashups (slug, owner_id, title, featured) values ('mine-1', auth.uid(), 'mine', true) $$);
insert into ratings (mashup_id, user_id, stars) values ('20000000-0000-0000-0000-000000000001', auth.uid(), 5);
select pg_temp.expect_count('player can rate a listed mashup', 'select * from ratings', 1);
insert into comments (id, mashup_id, user_id, body)
  values ('40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', auth.uid(), 'great');
select pg_temp.expect_denied('player cannot read raw token hashes', 'select token_hash from api_tokens');
select pg_temp.expect_count('player sees none of the creator''s tokens', 'select id from api_tokens', 0);
select pg_temp.expect_denied('player cannot read takedowns', 'select * from takedown_requests');
reset role;

-- creator ----------------------------------------------------------------------------------------
set role authenticated; select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select pg_temp.expect_count('creator sees own drafts', 'select * from mashups', 2);
select pg_temp.expect_count('creator sees all own versions', 'select * from mashup_versions', 3);
select pg_temp.expect_count('creator sees scan results for own versions', 'select * from scan_results', 1);
select pg_temp.expect_count('creator sees own token (without hash)', 'select id, name from api_tokens', 1);
select pg_temp.expect_count('creator analytics via function', $$ select * from creator_stats('20000000-0000-0000-0000-000000000001') $$, 1);
select pg_temp.expect_denied('creator cannot rate own mashup',
  $$ insert into ratings (mashup_id, user_id, stars) values ('20000000-0000-0000-0000-000000000001', auth.uid(), 5) $$);
select pg_temp.expect_denied('creator cannot list a mashup with no published version',
  $$ update mashups set visibility = 'listed' where slug = 'secret-mash' $$);
select pg_temp.expect_denied('creator cannot touch install counters', $$ update mashups set install_count = 1e9 $$);
update mashups set title = 'Live mashup v2' where slug = 'live-mash';
select pg_temp.expect_count('creator can edit own title', $$ select * from mashups where title = 'Live mashup v2' $$, 1);
reset role;

-- moderator --------------------------------------------------------------------------------------
set role authenticated; select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select pg_temp.expect_count('moderator sees review queue', $$ select * from mashup_versions where status = 'in_review' $$, 1);
update comments set hidden = true where id = '40000000-0000-0000-0000-000000000001';
update mashups set visibility = 'removed' where slug = 'live-mash';
reset role;

set role authenticated; select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select pg_temp.expect_denied('author cannot unhide a moderated comment',
  $$ update comments set hidden = false where id = '40000000-0000-0000-0000-000000000001' $$);
reset role;
set role authenticated; select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select pg_temp.expect_denied('creator cannot relist a removed mashup', $$ update mashups set visibility = 'listed' where slug = 'live-mash' $$);
reset role;
set role anon; select pg_temp.as_user(null);
select pg_temp.expect_count('removed mashup disappears for anon', 'select * from mashups', 0);
reset role;

\echo ALL RLS TESTS PASSED
