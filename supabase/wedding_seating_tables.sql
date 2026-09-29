-- Tables can now change shape, move, be added and be removed.
-- kind: round (60 inch), round72, long (8 foot, up and down), longh (8 foot, sideways), sweet
-- x, y: the table's center on the drawn floor plan
-- link: the table this one is pushed up against (long tables in a row)
-- end_side: which end of a long table gets the extra chair when the seat count is odd

alter table wedding.seat_tables
  add column if not exists kind text not null default 'round',
  add column if not exists end_side text,
  add column if not exists link int,
  add column if not exists x double precision,
  add column if not exists y double precision;

alter table wedding.seat_tables drop constraint if exists seat_tables_kind_check;
alter table wedding.seat_tables add constraint seat_tables_kind_check
  check (kind in ('round', 'round72', 'long', 'longh', 'sweet'));
alter table wedding.seat_tables drop constraint if exists seat_tables_end_check;
alter table wedding.seat_tables add constraint seat_tables_end_check
  check (end_side is null or end_side in ('top', 'bottom', 'left', 'right'));
alter table wedding.seat_tables drop constraint if exists seat_tables_link_check;
alter table wedding.seat_tables add constraint seat_tables_link_check
  check (link is null or (link between 1 and 99 and link <> num));
alter table wedding.seat_tables drop constraint if exists seat_tables_xy_check;
alter table wedding.seat_tables add constraint seat_tables_xy_check
  check ((x is null or (x > -100000 and x < 100000)) and (y is null or (y > -100000 and y < 100000)));
alter table wedding.seat_tables drop constraint if exists seat_tables_num_check;
alter table wedding.seat_tables add constraint seat_tables_num_check check (num between 1 and 99);
alter table wedding.guests drop constraint if exists guests_tbl_check;
alter table wedding.guests add constraint guests_tbl_check check (tbl between 0 and 99);

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
                                          'end', t.end_side, 'link', t.link, 'x', t.x, 'y', t.y) order by t.num)
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
        insert into wedding.guests as g (id, name, tbl, ord)
        values (did, btrim(d->>'name'), coalesce((d->>'table')::int, 0), coalesce((d->>'order')::float8, 0))
        on conflict (id) do update set name = excluded.name, tbl = excluded.tbl, ord = excluded.ord;
      elsif opk = 'update' then
        update wedding.guests g set
          name = coalesce(btrim(d->>'name'), g.name),
          tbl = coalesce((d->>'table')::int, g.tbl),
          ord = coalesce((d->>'order')::float8, g.ord)
        where g.id = did;
      elsif opk = 'delete' then
        delete from wedding.guests g where g.id = did;
      else
        raise exception 'bad op' using errcode = '22023';
      end if;

    elsif col = 'tables' then
      if opk = 'set' then
        insert into wedding.seat_tables as t (id, num, seats, kind, end_side, link, x, y)
        values (did, (d->>'num')::int, (d->>'seats')::int, coalesce(d->>'kind', 'round'), d->>'end',
                (d->>'link')::int, (d->>'x')::float8, (d->>'y')::float8)
        on conflict (id) do update set
          num = excluded.num,
          seats = excluded.seats,
          kind = case when d ? 'kind' then excluded.kind else t.kind end,
          end_side = case when d ? 'end' then excluded.end_side else t.end_side end,
          link = case when d ? 'link' then excluded.link else t.link end,
          x = case when d ? 'x' then excluded.x else t.x end,
          y = case when d ? 'y' then excluded.y else t.y end;
      elsif opk = 'update' then
        update wedding.seat_tables t set
          num = coalesce((d->>'num')::int, t.num),
          seats = coalesce((d->>'seats')::int, t.seats),
          kind = coalesce(d->>'kind', t.kind),
          end_side = case when d ? 'end' then d->>'end' else t.end_side end,
          link = case when d ? 'link' then (d->>'link')::int else t.link end,
          x = case when d ? 'x' then (d->>'x')::float8 else t.x end,
          y = case when d ? 'y' then (d->>'y')::float8 else t.y end
        where t.id = did;
      elsif opk = 'delete' then
        delete from wedding.seat_tables t where t.id = did;
      else
        raise exception 'bad op' using errcode = '22023';
      end if;

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
