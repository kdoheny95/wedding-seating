-- Wedding seating chart. Everything lives in the private "wedding" schema,
-- which the API does not expose. The page reaches it only through the three
-- public functions below, and each one checks the family link code first.

create schema if not exists wedding;
revoke all on schema wedding from public;
revoke all on schema wedding from anon, authenticated;

create table if not exists wedding.settings (
  id int primary key default 1 check (id = 1),
  key_hash text not null,
  version bigint not null default 1,
  meta jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists wedding.seat_tables (
  id text primary key check (char_length(id) between 1 and 64),
  num int not null unique check (num between 1 and 29),
  seats int not null check (seats between 0 and 30)
);

create table if not exists wedding.guests (
  id text primary key check (char_length(id) between 1 and 64),
  name text not null check (char_length(btrim(name)) between 1 and 120),
  tbl int not null default 0 check (tbl between 0 and 29),
  ord double precision not null default 0
);

create table if not exists wedding.changes (
  id bigint generated always as identity primary key,
  at bigint not null,
  by text check (by is null or char_length(by) <= 60),
  dev text check (dev is null or char_length(dev) <= 40),
  text text not null check (char_length(text) between 1 and 300)
);

alter table wedding.settings enable row level security;
alter table wedding.seat_tables enable row level security;
alter table wedding.guests enable row level security;
alter table wedding.changes enable row level security;
revoke all on all tables in schema wedding from public, anon, authenticated;
revoke all on all sequences in schema wedding from public, anon, authenticated;

create or replace function wedding.check_key(p_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from wedding.settings s
    where s.id = 1
      and s.key_hash = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex')
  ) then
    raise exception 'bad key' using errcode = '28000';
  end if;
end
$$;
revoke all on function wedding.check_key(text) from public, anon, authenticated;

-- Everything the page needs in one call.
create or replace function public.wedding_state(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r jsonb;
begin
  perform wedding.check_key(p_key);
  select jsonb_build_object(
    'version', s.version,
    'meta', s.meta,
    'tables', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'num', t.num, 'seats', t.seats) order by t.num)
      from wedding.seat_tables t), '[]'::jsonb),
    'guests', coalesce((
      select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'table', g.tbl, 'order', g.ord) order by g.id)
      from wedding.guests g), '[]'::jsonb),
    'changes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id::text, 'at', c.at, 'by', c.by, 'dev', c.dev, 'text', c.text) order by c.id desc)
      from (select * from wedding.changes order by id desc limit 300) c), '[]'::jsonb)
  )
  into r
  from wedding.settings s
  where s.id = 1;
  return r;
end
$$;

-- A cheap check the page runs every few seconds to see if anyone else changed something.
create or replace function public.wedding_version(p_key text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v bigint;
begin
  perform wedding.check_key(p_key);
  select s.version into v from wedding.settings s where s.id = 1;
  return v;
end
$$;

-- Applies a batch of edits in one transaction and returns the new version.
-- Each op: {"op": "set" | "update" | "delete", "c": "guests" | "tables" | "changes", "id": "...", "d": {...}}
create or replace function public.wedding_apply(p_key text, p_ops jsonb)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v bigint;
  op jsonb;
  kind text;
  col text;
  did text;
  d jsonb;
begin
  perform wedding.check_key(p_key);
  if p_ops is null or jsonb_typeof(p_ops) <> 'array' then
    raise exception 'ops must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_ops) > 400 then
    raise exception 'too many ops' using errcode = '22023';
  end if;

  -- one writer at a time, so batches never interleave
  perform 1 from wedding.settings s where s.id = 1 for update;

  for op in select e.value from jsonb_array_elements(p_ops) as e loop
    kind := op->>'op';
    col := op->>'c';
    did := op->>'id';
    d := coalesce(op->'d', '{}'::jsonb);

    if col = 'guests' then
      if kind = 'set' then
        insert into wedding.guests as g (id, name, tbl, ord)
        values (did, btrim(d->>'name'), coalesce((d->>'table')::int, 0), coalesce((d->>'order')::float8, 0))
        on conflict (id) do update set name = excluded.name, tbl = excluded.tbl, ord = excluded.ord;
      elsif kind = 'update' then
        update wedding.guests g set
          name = coalesce(btrim(d->>'name'), g.name),
          tbl = coalesce((d->>'table')::int, g.tbl),
          ord = coalesce((d->>'order')::float8, g.ord)
        where g.id = did;
      elsif kind = 'delete' then
        delete from wedding.guests g where g.id = did;
      else
        raise exception 'bad op' using errcode = '22023';
      end if;

    elsif col = 'tables' then
      if kind = 'set' then
        insert into wedding.seat_tables as t (id, num, seats)
        values (did, (d->>'num')::int, (d->>'seats')::int)
        on conflict (id) do update set num = excluded.num, seats = excluded.seats;
      elsif kind = 'update' then
        update wedding.seat_tables t set
          num = coalesce((d->>'num')::int, t.num),
          seats = coalesce((d->>'seats')::int, t.seats)
        where t.id = did;
      elsif kind = 'delete' then
        delete from wedding.seat_tables t where t.id = did;
      else
        raise exception 'bad op' using errcode = '22023';
      end if;

    elsif col = 'changes' then
      -- only new entries; the server trims old ones itself
      if kind = 'set' and coalesce(btrim(d->>'text'), '') <> '' then
        insert into wedding.changes (at, by, dev, text)
        values (
          (extract(epoch from clock_timestamp()) * 1000)::bigint,
          nullif(left(btrim(coalesce(d->>'by', '')), 60), ''),
          nullif(left(coalesce(d->>'dev', ''), 40), ''),
          left(btrim(d->>'text'), 300)
        );
      end if;

    else
      raise exception 'bad collection' using errcode = '22023';
    end if;
  end loop;

  delete from wedding.changes c
  where c.id <= (select c2.id from wedding.changes c2 order by c2.id desc offset 250 limit 1);

  update wedding.settings s set version = s.version + 1, updated_at = now()
  where s.id = 1
  returning s.version into v;
  return v;
end
$$;

revoke all on function public.wedding_state(text) from public;
revoke all on function public.wedding_version(text) from public;
revoke all on function public.wedding_apply(text, jsonb) from public;
grant execute on function public.wedding_state(text) to anon, authenticated;
grant execute on function public.wedding_version(text) to anon, authenticated;
grant execute on function public.wedding_apply(text, jsonb) to anon, authenticated;
