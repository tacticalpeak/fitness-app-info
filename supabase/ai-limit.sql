-- Tactical Peak: KI-Limits und Verbrauchsmessung
-- Einmal im Supabase SQL Editor ausführen. Mehrfaches Ausführen schadet nicht.
--
-- Grenzen pro Nutzer: 15 Einheiten pro Tag, 60 Einheiten pro Kalendermonat (deutsche Zeit).
-- 1 Einheit = 1 KI-Anfrage (z. B. 1 Trainingswoche, 1 Recherche, 1 Wochenrückblick).

-- ---------------------------------------------------------------------
-- 1. Zähler pro Nutzer und Tag
-- ---------------------------------------------------------------------
create table if not exists public.ai_usage_daily (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  units integer not null default 0,
  primary key (user_id, day)
);

-- Nur der Server (Service Role) darf die Tabelle lesen und schreiben, Nutzer nicht
alter table public.ai_usage_daily enable row level security;

-- Prüft Tages- und Monatsgrenze und zählt die Anfrage.
-- Ergebnis: 'ok' (erlaubt und gezählt), 'day' (Tagesgrenze erreicht), 'month' (Monatsgrenze erreicht)
create or replace function public.ai_use_check(p_user uuid, p_cost integer, p_day_limit integer, p_month_limit integer)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day date := (now() at time zone 'Europe/Berlin')::date;
  v_month_start date := date_trunc('month', v_day)::date;
  v_today integer;
  v_month integer;
begin
  -- Gleichzeitige Anfragen desselben Nutzers nacheinander abarbeiten
  perform pg_advisory_xact_lock(hashtext('ai_use:' || p_user::text));

  select coalesce(sum(units) filter (where day = v_day), 0), coalesce(sum(units), 0)
    into v_today, v_month
    from public.ai_usage_daily
   where user_id = p_user and day >= v_month_start;

  if v_today + p_cost > p_day_limit then
    return 'day';
  end if;
  if v_month + p_cost > p_month_limit then
    return 'month';
  end if;

  insert into public.ai_usage_daily as u (user_id, day, units)
  values (p_user, v_day, p_cost)
  on conflict (user_id, day)
  do update set units = u.units + excluded.units;

  -- Alte Zähler aufräumen (älter als 2 Monate)
  delete from public.ai_usage_daily where user_id = p_user and day < v_month_start - 62;

  return 'ok';
end;
$$;

-- Ältere Funktionen rufen noch ai_use(Nutzer, Kosten, Tageslimit) auf.
-- Auch für sie gelten jetzt höchstens 15 pro Tag und 60 pro Monat.
create or replace function public.ai_use(p_user uuid, p_cost integer, p_limit integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.ai_use_check(p_user, p_cost, least(p_limit, 15), 60) = 'ok';
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Verbrauchsmessung: Tokens und Kosten jeder KI-Anfrage
-- ---------------------------------------------------------------------
create table if not exists public.ai_usage_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id uuid references auth.users (id) on delete cascade,
  fn text not null,
  model text,
  input_tokens integer not null default 0,
  output_tokens integer not null default 0,
  cost_usd numeric(10, 5) not null default 0
);

alter table public.ai_usage_log enable row level security;
create index if not exists ai_usage_log_created_idx on public.ai_usage_log (created_at);

-- Speichert eine Messung und löscht Einträge, die älter als 90 Tage sind
create or replace function public.ai_log(
  p_user uuid,
  p_fn text,
  p_model text,
  p_input integer,
  p_output integer,
  p_cost numeric
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.ai_usage_log (user_id, fn, model, input_tokens, output_tokens, cost_usd)
  values (p_user, left(p_fn, 40), left(p_model, 60), greatest(0, p_input), greatest(0, p_output), greatest(0, p_cost));
  delete from public.ai_usage_log where created_at < now() - interval '90 days';
end;
$$;

-- Auswertung pro Tag und Funktion (im Table Editor oder SQL Editor ansehen)
create or replace view public.ai_kosten_pro_tag
with (security_invoker = true)
as
select
  (created_at at time zone 'Europe/Berlin')::date as tag,
  fn as funktion,
  count(*) as anfragen,
  round(sum(cost_usd), 2) as kosten_usd,
  round(avg(cost_usd), 4) as kosten_pro_anfrage_usd,
  round(avg(input_tokens)) as eingabe_tokens_schnitt,
  round(avg(output_tokens)) as ausgabe_tokens_schnitt
from public.ai_usage_log
group by 1, 2
order by 1 desc, 2;

-- Auswertung pro Nutzer und Monat (ohne Namen, nur die interne Nutzer-ID)
create or replace view public.ai_kosten_pro_nutzer
with (security_invoker = true)
as
select
  to_char(created_at at time zone 'Europe/Berlin', 'YYYY-MM') as monat,
  user_id,
  count(*) as anfragen,
  round(sum(cost_usd), 2) as kosten_usd
from public.ai_usage_log
group by 1, 2
order by 1 desc, 4 desc;

-- ---------------------------------------------------------------------
-- 3. Rechte: nur die Edge Functions (Service Role) dürfen das alles benutzen
-- ---------------------------------------------------------------------
revoke all on function public.ai_use_check(uuid, integer, integer, integer) from public, anon, authenticated;
revoke all on function public.ai_use(uuid, integer, integer) from public, anon, authenticated;
revoke all on function public.ai_log(uuid, text, text, integer, integer, numeric) from public, anon, authenticated;
grant execute on function public.ai_use_check(uuid, integer, integer, integer) to service_role;
grant execute on function public.ai_use(uuid, integer, integer) to service_role;
grant execute on function public.ai_log(uuid, text, text, integer, integer, numeric) to service_role;

revoke all on public.ai_usage_daily, public.ai_usage_log from anon, authenticated;
revoke all on public.ai_kosten_pro_tag, public.ai_kosten_pro_nutzer from anon, authenticated;
grant select on public.ai_kosten_pro_tag, public.ai_kosten_pro_nutzer to service_role;
