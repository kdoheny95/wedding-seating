-- Planning tools: meal choices, VIP guests, seating rules, and the menu.
-- meal: the guest's meal choice, one of the menu items in settings.meta.meals
-- vip: guests who should sit up front, near the couple and the dance floor
-- rules: two guests who should sit next to each other ('next'), at the same table ('same'),
--        not next to each other ('notnext'), or at different tables ('apart')

alter table wedding.guests add column if not exists meal text;
alter table wedding.guests add column if not exists vip boolean not null default false;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'guests_meal_check' and conrelid = 'wedding.guests'::regclass) then
    alter table wedding.guests add constraint guests_meal_check check (meal is null or char_length(meal) between 1 and 40);
  end if;
end
$$;

create table if not exists wedding.rules (
  id text primary key check (char_length(id) between 1 and 64),
  a text not null references wedding.guests (id) on delete cascade,
  b text not null references wedding.guests (id) on delete cascade,
  kind text not null check (kind in ('next', 'same', 'notnext', 'apart')),
  created_at timestamptz not null default now(),
  check (a <> b)
);
alter table wedding.rules enable row level security;
revoke all on wedding.rules from public, anon, authenticated;

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
      select jsonb_agg(jsonb_build_object('id', t.id, 'num', t.num, 'seats', t.seats, 'kind', t.kind,
                                          'end', t.end_side, 'link', t.link, 'x', t.x, 'y', t.y, 'sides', t.sides) order by t.num)
      from wedding.seat_tables t), '[]'::jsonb),
    'guests', coalesce((
      select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'table', g.tbl, 'order', g.ord, 'meal', g.meal, 'vip', g.vip) order by g.id)
      from wedding.guests g), '[]'::jsonb),
    'rules', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'a', x.a, 'b', x.b, 'kind', x.kind) order by x.created_at, x.id)
      from wedding.rules x), '[]'::jsonb),
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

create or replace function public.wedding_apply(p_key text, p_ops jsonb)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v bigint;
  op jsonb;
  opk text;
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
    opk := op->>'op';
    col := op->>'c';
    did := op->>'id';
    d := coalesce(op->'d', '{}'::jsonb);

    if col = 'guests' then
      if opk = 'set' then
        insert into wedding.guests as g (id, name, tbl, ord, meal, vip)
        values (did, btrim(d->>'name'), coalesce((d->>'table')::int, 0), coalesce((d->>'order')::float8, 0),
                nullif(btrim(d->>'meal'), ''), coalesce((d->>'vip')::boolean, false))
        on conflict (id) do update set
          name = excluded.name,
          tbl = excluded.tbl,
          ord = excluded.ord,
          meal = case when d ? 'meal' then excluded.meal else g.meal end,
          vip = case when d ? 'vip' then excluded.vip else g.vip end;
      elsif opk = 'update' then
        update wedding.guests g set
          name = coalesce(btrim(d->>'name'), g.name),
          tbl = coalesce((d->>'table')::int, g.tbl),
          ord = coalesce((d->>'order')::float8, g.ord),
          meal = case when d ? 'meal' then nullif(btrim(d->>'meal'), '') else g.meal end,
          vip = case when d ? 'vip' then coalesce((d->>'vip')::boolean, false) else g.vip end
        where g.id = did;
      elsif opk = 'delete' then
        delete from wedding.guests g where g.id = did;
      else
        raise exception 'bad op' using errcode = '22023';
      end if;

    elsif col = 'tables' then
      if opk = 'set' then
        insert into wedding.seat_tables as t (id, num, seats, kind, end_side, link, x, y, sides)
        values (did, (d->>'num')::int, (d->>'seats')::int, coalesce(d->>'kind', 'round'), d->>'end',
                (d->>'link')::int, (d->>'x')::float8, (d->>'y')::float8, nullif(d->'sides', 'null'::jsonb))
        on conflict (id) do update set
          num = excluded.num,
          seats = excluded.seats,
          kind = case when d ? 'kind' then excluded.kind else t.kind end,
          end_side = case when d ? 'end' then excluded.end_side else t.end_side end,
          link = case when d ? 'link' then excluded.link else t.link end,
          x = case when d ? 'x' then excluded.x else t.x end,
          y = case when d ? 'y' then excluded.y else t.y end,
          sides = case when d ? 'sides' then excluded.sides else t.sides end;
      elsif opk = 'update' then
        update wedding.seat_tables t set
          num = coalesce((d->>'num')::int, t.num),
          seats = coalesce((d->>'seats')::int, t.seats),
          kind = coalesce(d->>'kind', t.kind),
          end_side = case when d ? 'end' then d->>'end' else t.end_side end,
          link = case when d ? 'link' then (d->>'link')::int else t.link end,
          x = case when d ? 'x' then (d->>'x')::float8 else t.x end,
          y = case when d ? 'y' then (d->>'y')::float8 else t.y end,
          sides = case when d ? 'sides' then nullif(d->'sides', 'null'::jsonb) else t.sides end
        where t.id = did;
      elsif opk = 'delete' then
        delete from wedding.seat_tables t where t.id = did;
      else
        raise exception 'bad op' using errcode = '22023';
      end if;

    elsif col = 'rules' then
      if opk = 'set' then
        -- a rule about someone who was just removed is dropped, not an error
        if exists (select 1 from wedding.guests g where g.id = d->>'a') and exists (select 1 from wedding.guests g where g.id = d->>'b') then
          insert into wedding.rules as x (id, a, b, kind)
          values (did, d->>'a', d->>'b', d->>'kind')
          on conflict (id) do update set a = excluded.a, b = excluded.b, kind = excluded.kind;
        end if;
      elsif opk = 'delete' then
        delete from wedding.rules x where x.id = did;
      else
        raise exception 'bad op' using errcode = '22023';
      end if;

    elsif col = 'meta' then
      -- the page may only change the menu
      if opk <> 'update' or not (d ? 'meals') then
        raise exception 'bad op' using errcode = '22023';
      end if;
      if jsonb_typeof(d->'meals') <> 'array' or jsonb_array_length(d->'meals') > 20
         or exists (select 1 from jsonb_array_elements(d->'meals') e
                    where jsonb_typeof(e) <> 'string' or char_length(btrim(e #>> '{}')) not between 1 and 40) then
        raise exception 'bad meals' using errcode = '22023';
      end if;
      update wedding.settings s set meta = s.meta || jsonb_build_object('meals', d->'meals') where s.id = 1;

    elsif col = 'changes' then
      -- only new entries; the server trims old ones itself
      if opk = 'set' and coalesce(btrim(d->>'text'), '') <> '' then
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
revoke all on function public.wedding_apply(text, jsonb) from public;
grant execute on function public.wedding_state(text) to anon, authenticated;
grant execute on function public.wedding_apply(text, jsonb) to anon, authenticated;
