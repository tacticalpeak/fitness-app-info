-- Tactical Peak: KI-Limits, Testphase, Abo und Verbrauchsmessung
-- Einmal im Supabase SQL Editor ausführen. Mehrfaches Ausführen schadet nicht.
--
-- Alle Grenzen stehen in der Tabelle "app_settings" und lassen sich dort im Table Editor ändern:
--   limit_tag          = 10  KI-Einheiten pro Tag
--   limit_monat        = 30  KI-Einheiten pro Kalendermonat (deutsche Zeit)
--   neuplanungen_monat = 2   Pläne verwerfen und neu erstellen pro Monat
--   testphase_tage     = 7   Länge der Testphase
--   paywall            = aus Testphase und Abo sind abgeschaltet, alle dürfen alles.
--                             Auf "an" stellen, sobald die App mit Abo im App Store ist.
--   extra_paket        = aus Kauf von Extra-Paketen anbieten ("an", sobald der Kauf im App Store eingerichtet ist)
--   extra_paket_einheiten = 15  Einheiten pro Extra-Paket
-- 1 Einheit = 1 KI-Anfrage (z. B. 1 Trainingswoche, 1 Recherche, 1 Wochenrückblick).

-- ---------------------------------------------------------------------
-- 0. Einstellungen
-- ---------------------------------------------------------------------
create table if not exists public.app_settings (
  key text primary key,
  value text not null
);
alter table public.app_settings enable row level security;

insert into public.app_settings (key, value) values
  ('limit_tag', '10'),
  ('limit_monat', '30'),
  ('neuplanungen_monat', '2'),
  ('testphase_tage', '7'),
  ('paywall', 'aus'),
  ('extra_paket', 'aus'),
  ('extra_paket_einheiten', '15')
on conflict (key) do nothing;

create or replace function public.setting_int(p_key text, p_default integer)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select nullif(regexp_replace(value, '[^0-9]', '', 'g'), '')::integer
                     from public.app_settings where key = p_key), p_default);
$$;

-- ---------------------------------------------------------------------
-- 1. Zähler pro Nutzer und Tag
-- ---------------------------------------------------------------------
create table if not exists public.ai_usage_daily (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  units integer not null default 0,
  primary key (user_id, day)
);
alter table public.ai_usage_daily enable row level security;

-- Extra-Guthaben aus gekauften Extra-Paketen. Verfällt nicht und wird erst nach dem Monatslimit verbraucht.
create table if not exists public.ai_credits (
  user_id uuid primary key references auth.users (id) on delete cascade,
  units integer not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.ai_credits enable row level security;

-- Jeder Kauf wird mit seiner Transaktionsnummer gespeichert, damit er nie doppelt gutgeschrieben wird
create table if not exists public.ai_credit_purchases (
  transaction_id text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  units integer not null,
  created_at timestamptz not null default now()
);
alter table public.ai_credit_purchases enable row level security;

-- Prüft Tages- und Monatsgrenze und zählt die Anfrage.
-- Ergebnis: 'ok' (erlaubt und gezählt), 'day' (Tagesgrenze erreicht), 'month' (Monatsgrenze erreicht)
-- Die Grenzen aus app_settings haben Vorrang vor den übergebenen Werten.
create or replace function public.ai_use_check(p_user uuid, p_cost integer, p_day_limit integer, p_month_limit integer)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day date := (now() at time zone 'Europe/Berlin')::date;
  v_month_start date := date_trunc('month', v_day)::date;
  v_day_limit integer := public.setting_int('limit_tag', p_day_limit);
  v_month_limit integer := public.setting_int('limit_monat', p_month_limit);
  v_today integer;
  v_month integer;
begin
  -- Gleichzeitige Anfragen desselben Nutzers nacheinander abarbeiten
  perform pg_advisory_xact_lock(hashtext('ai_use:' || p_user::text));

  select coalesce(sum(units) filter (where day = v_day), 0), coalesce(sum(units), 0)
    into v_today, v_month
    from public.ai_usage_daily
   where user_id = p_user and day >= v_month_start;

  if v_today + p_cost > v_day_limit then
    return 'day';
  end if;
  if v_month + p_cost > v_month_limit then
    -- Monatslimit erreicht: Extra-Guthaben verwenden, falls vorhanden
    update public.ai_credits
       set units = units - p_cost, updated_at = now()
     where user_id = p_user and units >= p_cost;
    if not found then
      return 'month';
    end if;
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

-- Ältere Funktionen rufen noch ai_use(Nutzer, Kosten, Tageslimit) auf. Auch für sie gelten die Grenzen oben.
create or replace function public.ai_use(p_user uuid, p_cost integer, p_limit integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.ai_use_check(p_user, p_cost, 10, 30) = 'ok';
end;
$$;

-- Extra-Paket gutschreiben (später automatisch nach dem Kauf im App Store, zum Testen auch von Hand im SQL Editor).
-- Gibt das neue Guthaben zurück. Dieselbe Transaktionsnummer wird nur einmal gutgeschrieben.
create or replace function public.ai_grant_credits(p_user uuid, p_transaction text, p_units integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_units integer;
begin
  insert into public.ai_credit_purchases (transaction_id, user_id, units)
  values (left(p_transaction, 120), p_user, p_units)
  on conflict (transaction_id) do nothing;
  if found then
    insert into public.ai_credits as c (user_id, units) values (p_user, p_units)
    on conflict (user_id) do update set units = c.units + excluded.units, updated_at = now();
  end if;
  select units into v_units from public.ai_credits where user_id = p_user;
  return coalesce(v_units, 0);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Testphase und Abo
-- ---------------------------------------------------------------------
-- Aktive Abos. Später trägt der Zahlungsdienst (App Store) sie automatisch ein.
-- Bis dahin kannst du hier Tester von Hand freischalten (user_id und active_until).
create table if not exists public.subscriptions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  active_until timestamptz not null,
  source text not null default 'manuell'
);
alter table public.subscriptions enable row level security;

-- Beginn der Testphase (startet mit der ersten KI-Anfrage)
create table if not exists public.ai_trial (
  user_id uuid primary key references auth.users (id) on delete cascade,
  started_at timestamptz not null default now()
);
alter table public.ai_trial enable row level security;

-- Ergebnis: 'pro' (Abo oder Paywall aus), 'trial' (in der Testphase), 'expired' (Testphase vorbei)
create or replace function public.ai_access(p_user uuid, p_start boolean)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_started timestamptz;
begin
  if coalesce((select lower(value) from public.app_settings where key = 'paywall'), 'aus') <> 'an' then
    return 'pro';
  end if;
  if exists (select 1 from public.subscriptions where user_id = p_user and active_until > now()) then
    return 'pro';
  end if;
  select started_at into v_started from public.ai_trial where user_id = p_user;
  if v_started is null then
    if p_start then
      insert into public.ai_trial (user_id) values (p_user) on conflict (user_id) do nothing;
    end if;
    return 'trial';
  end if;
  if now() < v_started + make_interval(days => public.setting_int('testphase_tage', 7)) then
    return 'trial';
  end if;
  return 'expired';
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Gezählte Aktionen: Neuplanungen, Ziele und Recherchen in der Testphase
-- ---------------------------------------------------------------------
create table if not exists public.ai_events (
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null,
  action_id text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, kind, action_id)
);
alter table public.ai_events enable row level security;

-- Zählt eine Aktion. Dieselbe action_id zählt nur einmal (z. B. eine Neuplanung über mehrere Wochen).
-- p_period: 'month' = pro Kalendermonat, 'all' = insgesamt
-- Ergebnis: true = erlaubt, false = Grenze erreicht
create or replace function public.ai_event(p_user uuid, p_kind text, p_action text, p_limit integer, p_period text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_count integer;
  v_action text := left(coalesce(p_action, ''), 60);
begin
  perform pg_advisory_xact_lock(hashtext('ai_event:' || p_user::text));
  if exists (select 1 from public.ai_events where user_id = p_user and kind = p_kind and action_id = v_action) then
    return true;
  end if;
  if p_period = 'month' then
    v_from := date_trunc('month', now() at time zone 'Europe/Berlin') at time zone 'Europe/Berlin';
  else
    v_from := '-infinity'::timestamptz;
  end if;
  select count(*) into v_count from public.ai_events
   where user_id = p_user and kind = p_kind and created_at >= v_from;
  if v_count >= p_limit then
    return false;
  end if;
  insert into public.ai_events (user_id, kind, action_id) values (p_user, p_kind, v_action);
  delete from public.ai_events where user_id = p_user and created_at < now() - interval '400 days';
  return true;
end;
$$;

-- Für die App: eigener Stand (Abo/Testphase und verbrauchte Einheiten). Liefert nur Daten des angemeldeten Nutzers.
create or replace function public.my_access()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_day date := (now() at time zone 'Europe/Berlin')::date;
  v_month_start date := date_trunc('month', v_day)::date;
  v_started timestamptz;
  v_trial_days integer := public.setting_int('testphase_tage', 7);
  v_today integer;
  v_month integer;
  v_replans integer;
begin
  if v_user is null then
    return null;
  end if;
  select started_at into v_started from public.ai_trial where user_id = v_user;
  select coalesce(sum(units) filter (where day = v_day), 0), coalesce(sum(units), 0)
    into v_today, v_month
    from public.ai_usage_daily
   where user_id = v_user and day >= v_month_start;
  select count(*) into v_replans from public.ai_events
   where user_id = v_user and kind = 'replan'
     and created_at >= date_trunc('month', now() at time zone 'Europe/Berlin') at time zone 'Europe/Berlin';
  return json_build_object(
    'status', public.ai_access(v_user, false),
    'trial_days_left', case when v_started is null then v_trial_days
      else greatest(0, ceil(extract(epoch from (v_started + make_interval(days => v_trial_days) - now())) / 86400))::integer end,
    'day_used', v_today,
    'day_limit', public.setting_int('limit_tag', 10),
    'month_used', v_month,
    'month_limit', public.setting_int('limit_monat', 30),
    'replans_used', v_replans,
    'replans_limit', public.setting_int('neuplanungen_monat', 2),
    'extra_units', coalesce((select units from public.ai_credits where user_id = v_user), 0),
    'extra_pack_enabled', coalesce((select lower(value) from public.app_settings where key = 'extra_paket'), 'aus') = 'an',
    'extra_pack_units', public.setting_int('extra_paket_einheiten', 15)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Verbrauchsmessung: Tokens und Kosten jeder KI-Anfrage
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
-- 5. Rechte: nur die Edge Functions (Service Role) dürfen das benutzen.
--    Ausnahme: my_access() darf jeder angemeldete Nutzer für sich selbst abfragen.
-- ---------------------------------------------------------------------
revoke all on function public.setting_int(text, integer) from public, anon, authenticated;
revoke all on function public.ai_use_check(uuid, integer, integer, integer) from public, anon, authenticated;
revoke all on function public.ai_use(uuid, integer, integer) from public, anon, authenticated;
revoke all on function public.ai_access(uuid, boolean) from public, anon, authenticated;
revoke all on function public.ai_event(uuid, text, text, integer, text) from public, anon, authenticated;
revoke all on function public.ai_log(uuid, text, text, integer, integer, numeric) from public, anon, authenticated;
revoke all on function public.my_access() from public, anon;

grant execute on function public.setting_int(text, integer) to service_role;
grant execute on function public.ai_use_check(uuid, integer, integer, integer) to service_role;
grant execute on function public.ai_use(uuid, integer, integer) to service_role;
grant execute on function public.ai_access(uuid, boolean) to service_role;
grant execute on function public.ai_event(uuid, text, text, integer, text) to service_role;
grant execute on function public.ai_log(uuid, text, text, integer, integer, numeric) to service_role;
grant execute on function public.my_access() to authenticated, service_role;
revoke all on function public.ai_grant_credits(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.ai_grant_credits(uuid, text, integer) to service_role;

revoke all on public.ai_credits, public.ai_credit_purchases from anon, authenticated;
revoke all on public.app_settings, public.ai_usage_daily, public.ai_usage_log,
  public.subscriptions, public.ai_trial, public.ai_events from anon, authenticated;
revoke all on public.ai_kosten_pro_tag, public.ai_kosten_pro_nutzer from anon, authenticated;
grant select on public.ai_kosten_pro_tag, public.ai_kosten_pro_nutzer to service_role;
