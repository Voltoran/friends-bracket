-- Respect the API safeupdate guard when revoking all admin sessions.
-- This migration only replaces function definitions; no user data is deleted.
begin;
create or replace function public.bracket_admin_setup(p_setup_key text,p_password text) returns jsonb
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
  delete from bracket_private.admin_sessions where true;
  return bracket_private.issue_admin_session();
end $$;

create or replace function public.bracket_admin(p_session text,p_action text,p_args jsonb default '{}'::jsonb) returns jsonb
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
      delete from bracket_private.admin_sessions where true;
      result:=bracket_private.issue_admin_session();
    else raise exception 'Неизвестное действие.';
  end case;
  perform set_config('bracket.admin_token','',true);
  return jsonb_build_object('data',result);
end $$;
notify pgrst,'reload schema';
commit;
