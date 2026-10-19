-- Replace new runoffs with a persisted random decision on nonzero ties.
-- Existing votes, ballots, winners and current rounds are preserved.
begin;
alter table bracket_private.matches add column if not exists decided_randomly boolean not null default false;
create or replace function public.bracket_close_round(p_category uuid) returns void language plpgsql security definer set search_path='' as $$
declare c bracket_private.categories; m bracket_private.matches; a int; b int; chosen smallint; winning_name text;
begin
  perform bracket_private.require_organizer();
  select * into c from bracket_private.categories where id=p_category for update;
  if c.id is null or c.deleted_at is not null or c.status<>'active' then raise exception 'Категория не открыта для голосования.'; end if;
  for m in select * from bracket_private.matches where category_id=c.id and round=c.current_round and winner is null order by position loop
    select count(*) filter(where choice=1),count(*) filter(where choice=2) into a,b from bracket_private.votes where match_id=m.id and ballot=m.ballot;
    if a+b=0 then raise exception 'Есть пара без голосов. Соберите хотя бы один голос в каждой паре перед завершением раунда.'; end if;
    chosen:=case when a=b then (get_byte(extensions.gen_random_bytes(1),0)%2+1)::smallint when a>b then 1 else 2 end;
    winning_name:=case chosen when 1 then m.side_a else m.side_b end;
    update bracket_private.matches set winner=chosen,decided_randomly=(a=b) where id=m.id;
    if c.current_round<c.rounds then
      update bracket_private.matches set side_a=case when m.position%2=0 then winning_name else side_a end,
        side_b=case when m.position%2=1 then winning_name else side_b end
        where category_id=c.id and round=c.current_round+1 and position=m.position/2;
    end if;
  end loop;
  update bracket_private.categories set status=case when c.current_round=c.rounds then 'finished' else 'active' end,
    current_round=least(c.current_round+1,c.rounds) where id=c.id;
end $$;

-- Old browser tabs get an explanatory error instead of resetting ballots.
create or replace function public.bracket_runoff(p_category uuid) returns int language plpgsql security definer set search_path='' as $$
begin
  perform bracket_private.require_organizer();
  raise exception 'Переголосование заменено жеребьёвкой при завершении раунда. Обновите страницу.';
end $$;

-- Add the reason to public results without changing other state fields or grants.
do $migration$
declare definition text; anchor text:=$anchor$'winner',m.winner,$anchor$;
begin
  definition:=pg_get_functiondef('public.bracket_state(text)'::regprocedure);
  if position('m.decided_randomly' in definition)=0 then
    if position(anchor in definition)=0 then raise exception 'State function differs: review migration.'; end if;
    execute replace(definition,anchor,anchor||$field$'random',m.decided_randomly,$field$);
  end if;
end $migration$;
notify pgrst,'reload schema';
commit;
