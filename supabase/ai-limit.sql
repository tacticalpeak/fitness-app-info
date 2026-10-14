-- Tactical Peak: KI-Tageslimit pro Nutzer
-- Einmal im Supabase SQL Editor ausführen. Mehrfaches Ausführen schadet nicht.
-- Die Edge Functions rufen ai_use(p_user, p_cost, p_limit) auf.
-- Ergebnis true = Anfrage erlaubt (und gezählt), false = Tageslimit erreicht.

create table if not exists public.ai_usage_daily (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  units integer not null default 0,
  primary key (user_id, day)
);

-- Nur der Server (Service Role) darf die Tabelle lesen und schreiben, Nutzer nicht
alter table public.ai_usage_daily enable row level security;

create or replace function public.ai_use(p_user uuid, p_cost integer, p_limit integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day date := (now() at time zone 'Europe/Berlin')::date;
  v_units integer;
begin
  if p_cost > p_limit then
    return false;
  end if;

  insert into public.ai_usage_daily as u (user_id, day, units)
  values (p_user, v_day, p_cost)
  on conflict (user_id, day)
  do update set units = u.units + excluded.units
  where u.units + excluded.units <= p_limit
  returning u.units into v_units;

  return found;
end;
$$;

-- Nur die Edge Functions (Service Role) dürfen die Funktion aufrufen
revoke all on function public.ai_use(uuid, integer, integer) from public, anon, authenticated;
grant execute on function public.ai_use(uuid, integer, integer) to service_role;

