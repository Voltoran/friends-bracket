-- Password-only administrator access. Run after schema.sql (or migration-002).
-- The owner provisions a random one-use setup key through the private database.
-- No setup key or real password belongs in this file or in the public repository.
begin;
create extension if not exists pgcrypto with schema extensions;
create table bracket_private.admin_auth (
  singleton boolean primary key default true check(singleton),
  password_hash text,
  setup_hash text, setup_expires_at timestamptz,
  failures int not null default 0,
  window_started timestamptz not null default now(),
  locked_until timestamptz
);
insert into bracket_private.admin_auth(singleton) values(true);
create table bracket_private.admin_sessions (
  token_hash text primary key, expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
alter table bracket_private.admin_auth enable row level security;
alter table bracket_private.admin_sessions enable row level security;
revoke all on bracket_private.admin_auth, bracket_private.admin_sessions from public,anon,authenticated;

create function bracket_private.secret_hash(secret text) returns text
language sql immutable set search_path='' as $$
  select encode(sha256(convert_to(coalesce(secret,''),'UTF8')),'hex');
$$;
create or replace function bracket_private.is_organizer() returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from bracket_private.admin_sessions
    where token_hash=bracket_private.secret_hash(current_setting('bracket.admin_token',true)) and expires_at>now());
$$;
create function bracket_private.issue_admin_session() returns jsonb
language plpgsql security definer set search_path='' as $$
declare token text:=encode(extensions.gen_random_bytes(32),'hex'); expiry timestamptz:=now()+interval '12 hours';
begin
  delete from bracket_private.admin_sessions where expires_at<=now();
  insert into bracket_private.admin_sessions(token_hash,expires_at) values(bracket_private.secret_hash(token),expiry);
  return jsonb_build_object('token',token,'expires_at',extract(epoch from expiry));
end $$;
create function bracket_private.password_error(password text) returns text
language sql immutable set search_path='' as $$
  select case when password is null or length(password)<8 then 'Пароль должен содержать минимум 8 символов.'
    when octet_length(password)>72 then 'Пароль слишком длинный: максимум 72 байта (кириллица занимает больше одного байта).' end;
$$;
-- Callers hold the singleton row lock. Return errors instead of raising them,
-- so failed-attempt counters COMMIT on rejected HTTP login requests.
create function bracket_private.check_admin_password(password text) returns text
language plpgsql security definer set search_path='' as $$
declare a bracket_private.admin_auth;
begin
  select * into a from bracket_private.admin_auth where singleton for update;
  if a.locked_until>now() then return 'Слишком много попыток. Повтори вход через 15 минут.'; end if;
  if a.window_started<=now()-interval '15 minutes' then
    update bracket_private.admin_auth set failures=0,window_started=now(),locked_until=null where singleton;
    a.failures:=0;
  end if;
  if a.password_hash is null then return 'Пароль ещё не задан. Открой личную ссылку первой настройки.'; end if;
  if password is null or octet_length(password)>72 or extensions.crypt(password,a.password_hash)<>a.password_hash then
    update bracket_private.admin_auth set failures=failures+1,
      locked_until=case when failures+1>=5 then now()+interval '15 minutes' else null end where singleton;
    return case when a.failures+1>=5 then 'Слишком много попыток. Повтори вход через 15 минут.' else 'Неверный пароль.' end;
  end if;
  update bracket_private.admin_auth set failures=0,window_started=now(),locked_until=null where singleton;
  return null;
end $$;

create function public.bracket_admin_status(p_setup_key text default null) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('configured',password_hash is not null,
    'setup_allowed',coalesce(length(p_setup_key)=64 and setup_expires_at>now() and setup_hash=bracket_private.secret_hash(p_setup_key),false))
  from bracket_private.admin_auth where singleton;
$$;
create function public.bracket_admin_setup(p_setup_key text,p_password text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a bracket_private.admin_auth; error text;
begin
  select * into a from bracket_private.admin_auth where singleton for update;
  if p_setup_key is null or length(p_setup_key)<>64 or a.setup_hash is null or a.setup_expires_at is null or a.setup_expires_at<=now()
    or a.setup_hash<>bracket_private.secret_hash(p_setup_key) then
    return jsonb_build_object('error','Ссылка настройки недействительна, истекла или уже использована.');
  end if;
  error:=bracket_private.password_error(p_password);
  if error is not null then return jsonb_build_object('error',error); end if;
  update bracket_private.admin_auth set password_hash=extensions.crypt(p_password,extensions.gen_salt('bf',12)),
    setup_hash=null,setup_expires_at=null,failures=0,window_started=now(),locked_until=null where singleton;
  delete from bracket_private.admin_sessions;
  return bracket_private.issue_admin_session();
end $$;
create function public.bracket_admin_login(p_password text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare error text;
begin
  error:=bracket_private.check_admin_password(p_password);
  if error is not null then return jsonb_build_object('error',error); end if;
  return bracket_private.issue_admin_session();
end $$;

-- A fixed command list, never dynamic SQL. Only this gateway can establish
-- the request-local admin identity. Public callers cannot set database GUCs.
create function public.bracket_admin(p_session text,p_action text,p_args jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb:='null'::jsonb; error text;
begin
  -- Serialize password rotation with admin requests to prevent old sessions
  -- from authorizing a new action while the password is being changed.
  perform 1 from bracket_private.admin_auth where singleton for update;
  if p_session is null or length(p_session)<>64 or not exists(select 1 from bracket_private.admin_sessions
    where token_hash=bracket_private.secret_hash(p_session) and expires_at>now()) then
    return jsonb_build_object('error','Сессия закончилась. Войди как организатор снова.','code','admin_session_expired');
  end if;
  perform set_config('bracket.admin_token',p_session,true);
  case p_action
    when 'state' then result:=public.bracket_state(p_args->>'p_code');
    when 'create_category' then result:=to_jsonb(public.bracket_create_category(p_args->>'p_name',array(select jsonb_array_elements_text(p_args->'p_entries'))));
    when 'rename' then perform public.bracket_rename((p_args->>'p_category')::uuid,p_args->>'p_name');
    when 'edit_entry' then perform public.bracket_edit_entry((p_args->>'p_match')::uuid,(p_args->>'p_side')::int,p_args->>'p_name');
    when 'start' then perform public.bracket_start((p_args->>'p_category')::uuid);
    when 'close_round' then perform public.bracket_close_round((p_args->>'p_category')::uuid);
    when 'runoff' then result:=to_jsonb(public.bracket_runoff((p_args->>'p_category')::uuid));
    when 'issue_code' then result:=to_jsonb(public.bracket_issue_code(p_args->>'p_label'));
    when 'voters' then result:=public.bracket_voters();
    when 'toggle_voter' then perform public.bracket_toggle_voter((p_args->>'p_voter')::uuid,(p_args->>'p_active')::boolean);
    when 'delete_category' then perform public.bracket_delete_category((p_args->>'p_category')::uuid);
    when 'restore_category' then perform public.bracket_restore_category((p_args->>'p_category')::uuid);
    when 'trash' then result:=public.bracket_trash();
    when 'logout' then delete from bracket_private.admin_sessions where token_hash=bracket_private.secret_hash(p_session);
    when 'change_password' then
      error:=bracket_private.password_error(p_args->>'p_password');
      if error is null then error:=bracket_private.check_admin_password(p_args->>'p_current_password'); end if;
      if error is not null then
        perform set_config('bracket.admin_token','',true);
        return jsonb_build_object('error',error);
      end if;
      update bracket_private.admin_auth set password_hash=extensions.crypt(p_args->>'p_password',extensions.gen_salt('bf',12)),
        setup_hash=null,setup_expires_at=null where singleton;
      delete from bracket_private.admin_sessions;
      result:=bracket_private.issue_admin_session();
    else raise exception 'Неизвестное действие.';
  end case;
  perform set_config('bracket.admin_token','',true);
  return jsonb_build_object('data',result);
end $$;

revoke all on all functions in schema bracket_private from public,anon,authenticated;
-- Retire direct administrator RPC access and email-auth authorization.
revoke all on function public.bracket_create_category(text,text[]),public.bracket_rename(uuid,text),public.bracket_edit_entry(uuid,int,text),
 public.bracket_start(uuid),public.bracket_close_round(uuid),public.bracket_runoff(uuid),public.bracket_issue_code(text),
 public.bracket_voters(),public.bracket_toggle_voter(uuid,boolean),public.bracket_delete_category(uuid),public.bracket_restore_category(uuid),public.bracket_trash()
 from public,anon,authenticated;
revoke all on function public.bracket_admin_status(text),public.bracket_admin_setup(text,text),public.bracket_admin_login(text),public.bracket_admin(text,text,jsonb)
 from public,anon,authenticated;
grant execute on function public.bracket_admin_status(text),public.bracket_admin_setup(text,text),public.bracket_admin_login(text),public.bracket_admin(text,text,jsonb)
 to anon,authenticated;
notify pgrst,'reload schema';
commit;
