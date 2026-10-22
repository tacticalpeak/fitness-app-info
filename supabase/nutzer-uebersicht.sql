-- Tactical Peak: Nutzer-Übersicht für Excel (Marketing und Kostenrechnung)
-- Einmal im Supabase SQL Editor ausführen: New query -> alles einfügen -> Run.
-- Mehrfaches Ausführen schadet nicht. Es werden keine Nutzerdaten verändert.
--
-- Danach gibt es zwei fertige Listen im Bereich "auswertung":
--   auswertung.nutzer           eine Zeile pro Nutzer
--   auswertung.monatsuebersicht eine Zeile pro Monat (Neuanmeldungen, Abos, KI-Kosten)
--
-- Als Excel-Datei holen (SQL Editor -> New query):
--   select * from auswertung.nutzer;
--   Run -> rechts über dem Ergebnis "Export" -> "Download CSV" -> Datei in Excel öffnen.
--
-- Die Listen sind nur für dich im Supabase-Dashboard sichtbar, nicht über die App.

-- ---------------------------------------------------------------------
-- 0. Tabellen, die die Auswertung liest. Fehlen sie noch, werden sie leer angelegt
--    (genau so wie in ai-limit.sql und ai_log.sql, damit später nichts kollidiert).
-- ---------------------------------------------------------------------
create table if not exists public.app_settings (
  key text primary key,
  value text not null
);
alter table public.app_settings enable row level security;

create table if not exists public.subscriptions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  active_until timestamptz not null,
  source text not null default 'manuell'
);
alter table public.subscriptions enable row level security;

-- Neu: Abo-Art, Abo-Beginn und Preis. Später trägt der App Store sie automatisch ein,
-- bis dahin kannst du sie im Table Editor bei "subscriptions" von Hand eintragen.
--   plan      = 'monatlich' oder 'jaehrlich'
--   started_at = Beginn des Abos
--   price_eur = Preis pro Zahlung (z. B. 9.99 im Monat oder 79.99 im Jahr)
alter table public.subscriptions add column if not exists plan text;
alter table public.subscriptions add column if not exists started_at timestamptz;
alter table public.subscriptions add column if not exists price_eur numeric(10, 2);

create table if not exists public.ai_trial (
  user_id uuid primary key references auth.users (id) on delete cascade,
  started_at timestamptz not null default now()
);
alter table public.ai_trial enable row level security;

create table if not exists public.ai_credit_purchases (
  transaction_id text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  units integer not null,
  created_at timestamptz not null default now()
);
alter table public.ai_credit_purchases enable row level security;

-- KI-Kosten: ältere Fassung (ai-limit.sql) schreibt in ai_usage_log, neuere (ai_log.sql) in ai_usage
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

create table if not exists public.ai_usage (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id uuid not null,
  fn text not null,
  model text not null,
  input_tokens integer not null default 0,
  output_tokens integer not null default 0,
  cost_usd numeric(12, 6) not null default 0
);
alter table public.ai_usage enable row level security;

-- ---------------------------------------------------------------------
-- 1. Eigener Bereich für Auswertungen (nicht über die App erreichbar)
-- ---------------------------------------------------------------------
create schema if not exists auswertung;
revoke all on schema auswertung from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Eine Zeile pro Nutzer
-- ---------------------------------------------------------------------
create or replace view auswertung.nutzer as
with
testphase as (
  select coalesce((select nullif(regexp_replace(value, '[^0-9]', '', 'g'), '')::integer
                     from public.app_settings where key = 'testphase_tage'), 7) as tage
),
ki as (
  select user_id, created_at, cost_usd from public.ai_usage
  union all
  select user_id, created_at, cost_usd from public.ai_usage_log
),
ki_pro_nutzer as (
  select
    user_id,
    count(*) as anfragen,
    sum(cost_usd) as kosten,
    sum(cost_usd) filter (where created_at >= now() - interval '30 days') as kosten_30,
    sum(cost_usd) filter (where created_at >= date_trunc('month', now() at time zone 'Europe/Berlin') at time zone 'Europe/Berlin') as kosten_monat,
    max(created_at) as letzte
  from ki
  group by user_id
),
extra as (
  select user_id, count(*) as kaeufe, sum(units) as einheiten
  from public.ai_credit_purchases
  group by user_id
),
daten as (
  select
    user_id,
    max(updated_at) as zuletzt_aktiv,
    (array_agg(value::jsonb) filter (where key = 'athlete_profile_v1'))[1] as profil,
    (array_agg(value::jsonb) filter (where key = 'athlete_goals_v1'))[1] as ziele,
    (array_agg(value::jsonb) filter (where key = 'athlete_logs_v1'))[1] as trainings,
    bool_or(key = 'athlete_ai_consent_v1' and value::jsonb = 'true'::jsonb) as ki_einwilligung
  from public.user_data
  group by user_id
),
training as (
  select
    d.user_id,
    count(*) as anzahl,
    count(*) filter (where (l ->> 'date') >= to_char(now() - interval '30 days', 'YYYY-MM-DD')) as anzahl_30,
    max(left(l ->> 'date', 10)) as letztes
  from daten d
  cross join lateral jsonb_array_elements(case when jsonb_typeof(d.trainings) = 'array' then d.trainings else '[]'::jsonb end) l
  group by d.user_id
),
hauptziel as (
  select distinct on (d.user_id)
    d.user_id,
    g ->> 'title' as titel,
    g ->> 'category' as kategorie,
    left(g ->> 'targetDate', 10) as zieldatum
  from daten d
  cross join lateral jsonb_array_elements(case when jsonb_typeof(d.ziele) = 'array' then d.ziele else '[]'::jsonb end) g
  order by d.user_id, coalesce((g ->> 'priority')::boolean, false) desc, g ->> 'createdAt'
)
select
  -- Status: Abo monatlich, Abo jährlich, Abo (Art offen), Abo beendet, Testversion, Test abgelaufen, nur registriert
  case
    when s.active_until > now() and s.plan = 'monatlich' then 'Abo monatlich'
    when s.active_until > now() and s.plan in ('jaehrlich', 'jährlich') then 'Abo jährlich'
    when s.active_until > now() then 'Abo (Art offen)'
    when s.user_id is not null then 'Abo beendet'
    when t.started_at is not null and now() < t.started_at + make_interval(days => tp.tage) then 'Testversion'
    when t.started_at is not null then 'Test abgelaufen'
    else 'nur registriert'
  end as status,
  u.email as e_mail,
  d.profil ->> 'name' as name,
  (u.created_at at time zone 'Europe/Berlin')::date as registriert_am,
  (u.last_sign_in_at at time zone 'Europe/Berlin')::date as letzte_anmeldung,
  (d.zuletzt_aktiv at time zone 'Europe/Berlin')::date as zuletzt_aktiv,
  (u.email_confirmed_at is not null) as e_mail_bestaetigt,

  -- Testphase und Abo
  (t.started_at at time zone 'Europe/Berlin')::date as test_beginn,
  ((t.started_at + make_interval(days => tp.tage)) at time zone 'Europe/Berlin')::date as test_ende,
  s.plan as abo_art,
  (s.started_at at time zone 'Europe/Berlin')::date as abo_beginn,
  (s.active_until at time zone 'Europe/Berlin')::date as abo_bis,
  s.price_eur as abo_preis_eur,
  case
    when s.active_until <= now() then 0
    when s.plan = 'monatlich' then s.price_eur
    when s.plan in ('jaehrlich', 'jährlich') then round(s.price_eur / 12, 2)
  end as umsatz_pro_monat_eur,
  s.source as abo_quelle,

  -- KI-Kosten (in US-Dollar, so rechnet der KI-Anbieter ab)
  coalesce(k.anfragen, 0) as ki_anfragen_gesamt,
  round(coalesce(k.kosten, 0), 4) as ki_kosten_usd_gesamt,
  round(coalesce(k.kosten_monat, 0), 4) as ki_kosten_usd_dieser_monat,
  round(coalesce(k.kosten_30, 0), 4) as ki_kosten_usd_30_tage,
  (k.letzte at time zone 'Europe/Berlin')::date as letzte_ki_anfrage,
  coalesce(e.kaeufe, 0) as extra_pakete_gekauft,
  coalesce(e.einheiten, 0) as extra_einheiten_gekauft,

  -- Nutzung
  coalesce(tr.anzahl, 0) as trainings_gesamt,
  coalesce(tr.anzahl_30, 0) as trainings_30_tage,
  tr.letztes as letztes_training,
  case when jsonb_typeof(d.ziele) = 'array' then jsonb_array_length(d.ziele) else 0 end as ziele_anzahl,
  hz.titel as hauptziel,
  hz.kategorie as ziel_kategorie,
  hz.zieldatum as ziel_datum,
  coalesce(d.ki_einwilligung, false) as ki_einwilligung,

  -- Profil (für Zielgruppen)
  nullif(d.profil ->> 'age', '') as alter_jahre,
  nullif(d.profil ->> 'sex', '') as geschlecht,
  nullif(d.profil ->> 'experience', '') as erfahrung,
  nullif(d.profil ->> 'daysPerWeek', '') as trainingstage_pro_woche,
  nullif(d.profil ->> 'levelStrength', '') as level_kraft,
  nullif(d.profil ->> 'levelCrossfit', '') as level_crossfit,
  nullif(d.profil ->> 'levelRunning', '') as level_laufen,

  u.id as nutzer_id
from auth.users u
cross join testphase tp
left join public.subscriptions s on s.user_id = u.id
left join public.ai_trial t on t.user_id = u.id
left join ki_pro_nutzer k on k.user_id = u.id
left join extra e on e.user_id = u.id
left join daten d on d.user_id = u.id
left join training tr on tr.user_id = u.id
left join hauptziel hz on hz.user_id = u.id
order by u.created_at desc;

-- ---------------------------------------------------------------------
-- 3. Eine Zeile pro Monat
-- ---------------------------------------------------------------------
create or replace view auswertung.monatsuebersicht as
with
monate as (
  select to_char(created_at at time zone 'Europe/Berlin', 'YYYY-MM') as monat from auth.users
  union
  select to_char(created_at at time zone 'Europe/Berlin', 'YYYY-MM') from public.ai_usage
  union
  select to_char(created_at at time zone 'Europe/Berlin', 'YYYY-MM') from public.ai_usage_log
  union
  select to_char(started_at at time zone 'Europe/Berlin', 'YYYY-MM') from public.ai_trial
  union
  select to_char(started_at at time zone 'Europe/Berlin', 'YYYY-MM') from public.subscriptions where started_at is not null
),
ki as (
  select user_id, created_at, cost_usd from public.ai_usage
  union all
  select user_id, created_at, cost_usd from public.ai_usage_log
)
select
  m.monat,
  (select count(*) from auth.users u
    where to_char(u.created_at at time zone 'Europe/Berlin', 'YYYY-MM') = m.monat) as neue_nutzer,
  (select count(*) from public.ai_trial t
    where to_char(t.started_at at time zone 'Europe/Berlin', 'YYYY-MM') = m.monat) as neue_testphasen,
  (select count(*) from public.subscriptions s
    where s.plan = 'monatlich'
      and to_char(s.started_at at time zone 'Europe/Berlin', 'YYYY-MM') = m.monat) as neue_abos_monatlich,
  (select count(*) from public.subscriptions s
    where s.plan in ('jaehrlich', 'jährlich')
      and to_char(s.started_at at time zone 'Europe/Berlin', 'YYYY-MM') = m.monat) as neue_abos_jaehrlich,
  (select count(distinct k.user_id) from ki k
    where to_char(k.created_at at time zone 'Europe/Berlin', 'YYYY-MM') = m.monat) as nutzer_mit_ki,
  (select count(*) from ki k
    where to_char(k.created_at at time zone 'Europe/Berlin', 'YYYY-MM') = m.monat) as ki_anfragen,
  (select round(coalesce(sum(k.cost_usd), 0), 2) from ki k
    where to_char(k.created_at at time zone 'Europe/Berlin', 'YYYY-MM') = m.monat) as ki_kosten_usd
from monate m
order by m.monat desc;

-- Nur für dich im Dashboard, nie über die App
revoke all on all tables in schema auswertung from public, anon, authenticated;
