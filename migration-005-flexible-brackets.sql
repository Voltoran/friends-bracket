-- Supports 4–16 entries, including 11. Existing tournaments and grants are preserved.
begin;
create or replace function public.bracket_create_category(p_name text,p_entries text[]) returns uuid language plpgsql security definer set search_path = '' as $$
declare category_key uuid; count_entries int; total_rounds int; r int; i int; capacity int; byes int; entry_index int;
begin
  perform bracket_private.require_organizer();
  count_entries:=cardinality(p_entries);
  if count_entries is null or count_entries not between 4 and 16 or array_ndims(p_entries)<>1 or array_lower(p_entries,1)<>1 then raise exception 'Нужно от 4 до 16 участников.'; end if;
  if p_name is null or length(trim(p_name)) not between 1 and 60 then raise exception 'Название: от 1 до 60 символов.'; end if;
  if exists(select 1 from unnest(p_entries) x where x is null or length(trim(x)) not between 1 and 80) then raise exception 'Имя участника: от 1 до 80 символов.'; end if;
  if (select count(distinct lower(trim(x))) from unnest(p_entries) x) <> count_entries then raise exception 'Участники не должны повторяться.'; end if;
  total_rounds:=case when count_entries<=4 then 2 when count_entries<=8 then 3 else 4 end;
  capacity:=(2^total_rounds)::int; byes:=capacity-count_entries;
  insert into bracket_private.categories(name,rounds) values(trim(p_name),total_rounds) returning id into category_key;
  for r in 1..total_rounds loop
    for i in 0..(capacity / (2^r)::int - 1) loop
      entry_index:=case when i<byes then i+1 else byes+2*(i-byes)+1 end;
      insert into bracket_private.matches(category_id,round,position,side_a,side_b)
      values(category_key,r,i,case when r=1 then trim(p_entries[entry_index]) end,case when r=1 and i>=byes then trim(p_entries[entry_index+1]) end);
    end loop;
  end loop;
  return category_key;
end $$;

create or replace function public.bracket_edit_entry(p_match uuid,p_side int,p_name text) returns void language plpgsql security definer set search_path = '' as $$
declare c bracket_private.categories; m bracket_private.matches;
begin
  perform bracket_private.require_organizer();
  select * into m from bracket_private.matches where id=p_match;
  select * into c from bracket_private.categories where id=m.category_id for update;
  if c.deleted_at is not null or c.status <> 'draft' or m.round <> 1 or c.id is null then raise exception 'Участников можно менять только до старта.'; end if;
  if p_side not in (1,2) or p_side is null or p_name is null or length(trim(p_name)) not between 1 and 80 then raise exception 'Проверь имя участника.'; end if;
  if (p_side=1 and m.side_a is null) or (p_side=2 and m.side_b is null) then raise exception 'Это место для автоматического прохода.'; end if;
  if exists(select 1 from bracket_private.matches x where x.category_id=c.id and x.round=1 and
    ((lower(x.side_a)=lower(trim(p_name)) and not(x.id=p_match and p_side=1)) or
     (lower(x.side_b)=lower(trim(p_name)) and not(x.id=p_match and p_side=2)))) then raise exception 'Такой участник уже есть.'; end if;
  update bracket_private.matches set side_a=case when p_side=1 then trim(p_name) else side_a end,side_b=case when p_side=2 then trim(p_name) else side_b end where id=p_match;
end $$;

create or replace function public.bracket_start(p_category uuid) returns void language plpgsql security definer set search_path = '' as $$
declare m bracket_private.matches;
begin
  perform bracket_private.require_organizer();
  update bracket_private.categories set status='active' where id=p_category and status='draft' and deleted_at is null;
  if not found then raise exception 'Категория уже запущена или не найдена.'; end if;
  for m in select * from bracket_private.matches where category_id=p_category and round=1 and side_a is not null and side_b is null loop
    update bracket_private.matches set winner=1 where id=m.id;
    update bracket_private.matches set side_a=case when m.position%2=0 then m.side_a else side_a end,
      side_b=case when m.position%2=1 then m.side_a else side_b end
      where category_id=p_category and round=2 and position=m.position/2;
  end loop;
end $$;

create or replace function public.bracket_close_round(p_category uuid) returns void language plpgsql security definer set search_path = '' as $$
declare c bracket_private.categories; m bracket_private.matches; a int; b int; chosen smallint; winning_name text;
begin
  perform bracket_private.require_organizer();
  select * into c from bracket_private.categories where id=p_category for update;
  if c.id is null or c.deleted_at is not null or c.status <> 'active' then raise exception 'Категория не открыта для голосования.'; end if;
  for m in select * from bracket_private.matches where category_id=c.id and round=c.current_round and winner is null order by position loop
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
notify pgrst,'reload schema';
commit;
