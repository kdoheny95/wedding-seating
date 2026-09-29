# Wedding seating chart

The venue floor plan with every guest's name at their chair. Anyone with the family link can open it on a phone or computer, move people, and add or remove seats. Nobody needs an account.

## How it fits together

- `index.html` is the whole page: the floor plan, the controls, and the code that saves changes.
- The seating lives in Supabase, in the `wedding` schema of the DNA Automate project. The API can't read that schema directly. The page goes through three functions (`wedding_state`, `wedding_version` and `wedding_apply`), and each one checks the code at the end of the family link before it does anything.
- Railway runs `server.js`, which only serves the page. This repo holds no guest data and no secrets.
- Every few seconds the page checks whether someone else changed something, so everyone sees the same chart.

## The family link

`https://YOUR-RAILWAY-DOMAIN/#CODE`

The code isn't stored here. Supabase keeps only a hash of it. Once a phone has opened the full link, it remembers the code, so opening the plain address on that phone works too.

To change the code (say the link got passed around too far), run this in the Supabase SQL editor, then send the new link:

```sql
update wedding.settings
set key_hash = encode(sha256(convert_to('NEW-CODE-HERE', 'UTF8')), 'hex')
where id = 1;
```

Anyone still using the old link will see "This link doesn't work anymore."

## Changing the page

Push to `main`. Railway redeploys on its own.

## After the wedding

Delete the Railway service, then run this in Supabase:

```sql
drop function if exists public.wedding_state(text), public.wedding_version(text), public.wedding_apply(text, jsonb);
drop schema if exists wedding cascade;
```

`supabase/wedding_seating.sql` recreates the database side if you ever need it again.
