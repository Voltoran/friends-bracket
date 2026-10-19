-- Read-only participation report. No tournament, vote or session data changes.
begin;
create or replace function bracket_private.voting_progress(p_category uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare c bracket_private.categories; result jsonb;
begin
  perform bracket_private.require_organizer();
  select * into c from bracket_private.categories where id=p_category and deleted_at is null;
  if c.id is null then raise exception 'Голосование не найдено или удалено.'; end if;
  with playable as (
    select id,ballot from bracket_private.matches
    where category_id=c.id and round=c.current_round and side_a is not null and side_b is not null
  ), participation as (
    select v.voter_id,count(*) as voted from bracket_private.votes v
    join playable m on m.id=v.match_id and m.ballot=v.ballot group by v.voter_id
  )
  select jsonb_build_object(
    'category',jsonb_build_object('id',c.id,'name',c.name,'status',c.status,'round',c.current_round,'rounds',c.rounds),
    'total',(select count(*) from playable),
    'voters',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'label',p.label,'active',p.active,'voted',coalesce(v.voted,0)) order by lower(p.label),p.created_at,p.id)
      from bracket_private.voters p left join participation v on v.voter_id=p.id),'[]'::jsonb)
  ) into result;
  return result;
end $$;
revoke all on function bracket_private.voting_progress(uuid) from public,anon,authenticated;

-- Preserve the deployed gateway's authentication and other actions exactly.
do $migration$
declare definition text; anchor text:=$anchor$    when 'voters' then result:=public.bracket_voters();$anchor$;
begin
  definition:=pg_get_functiondef('public.bracket_admin(text,text,jsonb)'::regprocedure);
  if position($needle$when 'voting_progress'$needle$ in definition)=0 then
    if position(anchor in definition)=0 then raise exception 'Admin gateway differs: review migration before applying.'; end if;
    definition:=replace(definition,anchor,anchor||E'\n'||$action$    when 'voting_progress' then result:=bracket_private.voting_progress((p_args->>'p_category')::uuid);$action$);
    execute definition;
  end if;
end $migration$;
notify pgrst,'reload schema';
commit;
