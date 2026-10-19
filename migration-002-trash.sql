-- Adds a recoverable trash. Existing data is preserved.
begin;
alter table bracket_private.categories add column if not exists deleted_at timestamptz;
create or replace function public.bracket_state(p_code text default null) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare person bracket_private.voters; result jsonb;
begin
  select * into person from bracket_private.voters where code_hash=bracket_private.code_hash(p_code) and active;
  select jsonb_build_object('organizer', bracket_private.is_organizer(), 'voter', case when person.id is null then null else jsonb_build_object('label',person.label) end,
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'status',c.status,'round',c.current_round,'rounds',c.rounds,
      'matches',(select jsonb_agg(jsonb_build_object('id',m.id,'round',m.round,'position',m.position,'a',m.side_a,'b',m.side_b,'winner',m.winner,'ballot',m.ballot,
        'votes_a',(select count(*) from bracket_private.votes v where v.match_id=m.id and v.ballot=m.ballot and v.choice=1),
        'votes_b',(select count(*) from bracket_private.votes v where v.match_id=m.id and v.ballot=m.ballot and v.choice=2),
        'my_vote',(select v.choice from bracket_private.votes v where v.match_id=m.id and v.ballot=m.ballot and v.voter_id=person.id)) order by m.round,m.position)
        from bracket_private.matches m where m.category_id=c.id)) order by c.created_at,c.id) from bracket_private.categories c where c.deleted_at is null),'[]'::jsonb)) into result;
  return result;
end $$;

create or replace function public.bracket_vote(p_code text,p_match uuid,p_choice int) returns void language plpgsql security definer set search_path = '' as $$
declare person uuid; game bracket_private.matches; category bracket_private.categories; category_key uuid;
begin
  select id into person from bracket_private.voters where code_hash=bracket_private.code_hash(p_code) and active;
  if person is null then raise exception 'Код не найден или отключён. Попроси новый у организатора.'; end if;
  select category_id into category_key from bracket_private.matches where id=p_match;
  select * into category from bracket_private.categories where id=category_key for update;
  select * into game from bracket_private.matches where id=p_match;
  if game.id is null or category.deleted_at is not null or category.status <> 'active' or game.round <> category.current_round or game.winner is not null then raise exception 'Голосование в этой паре закрыто.'; end if;
  if p_choice not in (1,2) or p_choice is null or game.side_a is null or game.side_b is null then raise exception 'Выбери участника этой пары.'; end if;
  insert into bracket_private.votes(voter_id,match_id,ballot,choice) values(person,p_match,game.ballot,p_choice);
exception when unique_violation then raise exception 'Твой голос в этой паре уже учтён.';
end $$;

create or replace function public.bracket_rename(p_category uuid,p_name text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform bracket_private.require_organizer();
  if p_name is null or length(trim(p_name)) not between 1 and 60 then raise exception 'Название: от 1 до 60 символов.'; end if;
  update bracket_private.categories set name=trim(p_name) where id=p_category and deleted_at is null;
  if not found then raise exception 'Голосование не найдено или удалено.'; end if;
end $$;

create or replace function public.bracket_edit_entry(p_match uuid,p_side int,p_name text) returns void language plpgsql security definer set search_path = '' as $$
declare c bracket_private.categories; m bracket_private.matches;
begin
  perform bracket_private.require_organizer();
  select * into m from bracket_private.matches where id=p_match;
  select * into c from bracket_private.categories where id=m.category_id for update;
  if c.deleted_at is not null or c.status <> 'draft' or m.round <> 1 or c.id is null then raise exception 'Участников можно менять только до старта.'; end if;
  if p_side not in (1,2) or p_side is null or p_name is null or length(trim(p_name)) not between 1 and 80 then raise exception 'Проверь имя участника.'; end if;
  if exists(select 1 from bracket_private.matches x where x.category_id=c.id and x.round=1 and
    ((lower(x.side_a)=lower(trim(p_name)) and not(x.id=p_match and p_side=1)) or
     (lower(x.side_b)=lower(trim(p_name)) and not(x.id=p_match and p_side=2)))) then raise exception 'Такой участник уже есть.'; end if;
  update bracket_private.matches set side_a=case when p_side=1 then trim(p_name) else side_a end,side_b=case when p_side=2 then trim(p_name) else side_b end where id=p_match;
end $$;

create or replace function public.bracket_start(p_category uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform bracket_private.require_organizer();
  update bracket_private.categories set status='active' where id=p_category and status='draft' and deleted_at is null;
  if not found then raise exception 'Категория уже запущена или не найдена.'; end if;
end $$;

create or replace function public.bracket_close_round(p_category uuid) returns void language plpgsql security definer set search_path = '' as $$
declare c bracket_private.categories; m bracket_private.matches; a int; b int; chosen smallint; winning_name text;
begin
  perform bracket_private.require_organizer();
  select * into c from bracket_private.categories where id=p_category for update;
  if c.id is null or c.deleted_at is not null or c.status <> 'active' then raise exception 'Категория не открыта для голосования.'; end if;
  for m in select * from bracket_private.matches where category_id=c.id and round=c.current_round order by position loop
    select count(*) filter(where choice=1),count(*) filter(where choice=2) into a,b from bracket_private.votes where match_id=m.id and ballot=m.ballot;
    if a=b then raise exception 'Есть ничья или пара без голосов. Соберите голоса или запустите переголосование.'; end if;
    chosen:=case when a>b then 1 else 2 end; winning_name:=case chosen when 1 then m.side_a else m.side_b end;
    update bracket_private.matches set winner=chosen where id=m.id;
    if c.current_round < c.rounds then
      update bracket_private.matches set side_a=case when m.position%2=0 then winning_name else side_a end,
      side_b=case when m.position%2=1 then winning_name else side_b end where category_id=c.id and round=c.current_round+1 and position=m.position/2;
    end if;
  end loop;
  update bracket_private.categories set status=case when c.current_round=c.rounds then 'finished' else 'active' end,
    current_round=least(c.current_round+1,c.rounds) where id=c.id;
end $$;

create or replace function public.bracket_runoff(p_category uuid) returns int language plpgsql security definer set search_path = '' as $$
declare c bracket_private.categories; m bracket_private.matches; a int; b int; changed int:=0;
begin
  perform bracket_private.require_organizer();
  select * into c from bracket_private.categories where id=p_category for update;
  if c.id is null or c.deleted_at is not null or c.status <> 'active' then raise exception 'Категория не открыта для голосования.'; end if;
  for m in select * from bracket_private.matches where category_id=c.id and round=c.current_round loop
    select count(*) filter(where choice=1),count(*) filter(where choice=2) into a,b from bracket_private.votes where match_id=m.id and ballot=m.ballot;
    if a=b and a>0 then
      update bracket_private.matches set ballot=ballot+1 where id=m.id; changed:=changed+1;
    end if;
  end loop;
  if changed=0 then raise exception 'Нет пар с равным ненулевым счётом.'; end if;
  return changed;
end $$;

create or replace function public.bracket_delete_category(p_category uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform bracket_private.require_organizer();
  update bracket_private.categories set deleted_at=now() where id=p_category and deleted_at is null;
  if not found then raise exception 'Голосование уже удалено или не найдено.'; end if;
end $$;

create or replace function public.bracket_restore_category(p_category uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform bracket_private.require_organizer();
  update bracket_private.categories set deleted_at=null where id=p_category and deleted_at is not null;
  if not found then raise exception 'Голосование не найдено в корзине.'; end if;
end $$;

create or replace function public.bracket_trash() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform bracket_private.require_organizer();
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'status',status) order by deleted_at desc) from bracket_private.categories where deleted_at is not null),'[]'::jsonb);
end $$;
revoke all on function public.bracket_delete_category(uuid),public.bracket_restore_category(uuid),public.bracket_trash() from public,anon,authenticated;
grant execute on function public.bracket_delete_category(uuid),public.bracket_restore_category(uuid),public.bracket_trash() to authenticated;


notify pgrst,'reload schema';
commit;
