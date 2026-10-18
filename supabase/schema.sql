-- Drzewo rodziny – struktura bazy i funkcje.
-- Dane dostępne są wyłącznie przez funkcje poniżej, które sprawdzają hasło.
-- Tabele mają włączone RLS bez żadnych reguł, więc klucz publiczny nie daje do nich dostępu.

create extension if not exists pgcrypto with schema extensions;
do $$ begin
  create extension if not exists pg_net with schema extensions;
exception when others then raise notice 'pg_net niedostępne – powiadomienia wyłączone';
end $$;

create table if not exists public.tree_config (
  id int primary key default 1 check (id = 1),
  family_hash text,
  admin_hash text,
  ntfy_topic text,
  site_url text,
  base jsonb
);
create table if not exists public.tree_changes (
  id text primary key,
  ts timestamptz not null default now(),
  device text,
  author text,
  status text not null check (status in ('pending','approved','rejected','undone')),
  aseq bigint,
  data jsonb not null
);
create index if not exists tree_changes_status on public.tree_changes (status);
create sequence if not exists public.tree_aseq;
create table if not exists public.tree_photos (
  id uuid primary key default gen_random_uuid(),
  created timestamptz not null default now(),
  data text not null
);

alter table public.tree_config  enable row level security;
alter table public.tree_changes enable row level security;
alter table public.tree_photos  enable row level security;
revoke all on public.tree_config, public.tree_changes, public.tree_photos from anon, authenticated;
revoke all on sequence public.tree_aseq from anon, authenticated;

-- 'admin', 'family' albo null
create or replace function public.tree_role(p_pw text) returns text
language plpgsql stable security definer set search_path = public, extensions as $$
declare c public.tree_config;
begin
  select * into c from public.tree_config where id = 1;
  if p_pw is null or p_pw = '' or c.id is null then return null; end if;
  if c.admin_hash is not null and crypt(p_pw, c.admin_hash) = c.admin_hash then return 'admin'; end if;
  if c.family_hash is not null and crypt(p_pw, c.family_hash) = c.family_hash then return 'family'; end if;
  return null;
end $$;

create or replace function public.tree_require(p_pw text, p_admin boolean default false) returns text
language plpgsql stable security definer set search_path = public, extensions as $$
declare r text := public.tree_role(p_pw);
begin
  if r is null then raise exception 'bad_password'; end if;
  if p_admin and r <> 'admin' then raise exception 'not_admin'; end if;
  return r;
end $$;

-- Rodzina widzi zatwierdzone zmiany i własne oczekujące; administrator widzi wszystkie oczekujące.
create or replace function public.tree_load(p_pw text, p_device text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r text := public.tree_require(p_pw);
begin
  return jsonb_build_object(
    'role', r,
    'base', (select base from public.tree_config where id = 1),
    'changes', coalesce((
      select jsonb_agg(c.data || jsonb_build_object(
               'id', c.id, 'ts', (extract(epoch from c.ts) * 1000)::bigint,
               'author', c.author, 'status', c.status, 'aseq', c.aseq,
               'mine', c.device = p_device) order by c.ts)
      from public.tree_changes c
      where c.status = 'approved'
         or (c.status = 'pending' and (r = 'admin' or c.device = p_device))), '[]'::jsonb));
end $$;

create or replace function public.tree_submit(p_pw text, p_device text, p_author text, p_change jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  r text := public.tree_require(p_pw);
  cfg public.tree_config;
  recent int;
  st text := case when r = 'admin' then 'approved' else 'pending' end;
begin
  if p_change->>'id' is null or length(p_change::text) > 200000 then raise exception 'bad_change'; end if;
  select count(*) into recent from public.tree_changes where status = 'pending' and ts > now() - interval '10 minutes';
  insert into public.tree_changes (id, device, author, status, aseq, data)
  values (p_change->>'id', p_device, left(coalesce(p_author, ''), 80), st,
          case when st = 'approved' then nextval('public.tree_aseq') end,
          p_change - array['id','ts','author','status','aseq','mine']);
  -- Powiadomienie: najwyżej jedno na 10 minut, żeby nie zasypać telefonu.
  if st = 'pending' and recent = 0 then
    select * into cfg from public.tree_config where id = 1;
    if cfg.ntfy_topic is not null and cfg.ntfy_topic <> '' then
      begin
        perform net.http_post(
          url := 'https://ntfy.sh/',
          body := jsonb_build_object('topic', cfg.ntfy_topic, 'title', 'Drzewo rodziny',
                    'message', 'Nowe zmiany czekają na zatwierdzenie' || coalesce(' (od: ' || nullif(p_author, '') || ')', ''),
                    'click', cfg.site_url, 'tags', jsonb_build_array('deciduous_tree')));
      exception when others then null;
      end;
    end if;
  end if;
  return jsonb_build_object('status', st);
end $$;

-- Rodzina może wycofać własne, jeszcze niezatwierdzone zmiany.
create or replace function public.tree_withdraw(p_pw text, p_device text, p_ids text[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.tree_require(p_pw);
  update public.tree_changes set status = 'undone'
  where id = any(p_ids) and device = p_device and status = 'pending';
end $$;

-- Administrator: zatwierdzanie, odrzucanie, poprawki i cofanie. Kolejność na liście = kolejność zatwierdzania.
create or replace function public.tree_admin_update(p_pw text, p_updates jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u jsonb;
begin
  perform public.tree_require(p_pw, true);
  for u in select value from jsonb_array_elements(p_updates) loop
    update public.tree_changes set
      status = u->>'status',
      aseq = case when u->>'status' = 'approved' and status <> 'approved' then nextval('public.tree_aseq') else aseq end,
      data = coalesce(u->'data', data)
    where id = u->>'id';
  end loop;
end $$;

create or replace function public.tree_put_photo(p_pw text, p_data text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare new_id uuid;
begin
  perform public.tree_require(p_pw);
  if p_data not like 'data:image/%' or length(p_data) > 3000000 then raise exception 'bad_photo'; end if;
  insert into public.tree_photos (data) values (p_data) returning id into new_id;
  return new_id;
end $$;

create or replace function public.tree_photos(p_pw text, p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public.tree_require(p_pw);
  return coalesce((select jsonb_object_agg(id::text, data) from public.tree_photos where id = any(p_ids)), '{}'::jsonb);
end $$;

-- Ustawienia: hasła, temat ntfy, adres strony. Wywoływane tylko z SQL Editora.
create or replace function public.tree_setup(family_password text, admin_password text, ntfy_topic text, site_url text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if length(family_password) < 4 or length(admin_password) < 8 or family_password = admin_password then
    raise exception 'Hasło rodzinne musi mieć min. 4 znaki, hasło administratora min. 8 znaków i muszą być różne.';
  end if;
  insert into public.tree_config (id) values (1) on conflict (id) do nothing;
  update public.tree_config set
    family_hash = crypt(family_password, gen_salt('bf', 8)),
    admin_hash  = crypt(admin_password,  gen_salt('bf', 8)),
    ntfy_topic  = tree_setup.ntfy_topic,
    site_url    = tree_setup.site_url
  where id = 1;
end $$;

create or replace function public.tree_set_base(p_base jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.tree_config (id, base) values (1, p_base)
  on conflict (id) do update set base = excluded.base;
$$;

revoke execute on function public.tree_role(text), public.tree_require(text, boolean),
  public.tree_setup(text, text, text, text), public.tree_set_base(jsonb),
  public.tree_load(text, text), public.tree_submit(text, text, text, jsonb),
  public.tree_withdraw(text, text, text[]), public.tree_admin_update(text, jsonb),
  public.tree_put_photo(text, text), public.tree_photos(text, uuid[]) from public, anon, authenticated;
grant execute on function public.tree_load(text, text), public.tree_submit(text, text, text, jsonb),
  public.tree_withdraw(text, text, text[]), public.tree_admin_update(text, jsonb),
  public.tree_put_photo(text, text), public.tree_photos(text, uuid[]) to anon, authenticated;
