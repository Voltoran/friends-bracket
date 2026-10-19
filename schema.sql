-- Friends Bracket, initial schema. Run once in the Supabase SQL editor.
begin;
create schema if not exists bracket_private;
revoke all on schema bracket_private from public, anon, authenticated;

create table bracket_private.organizers (email text primary key check(email = lower(email)));
create table bracket_private.categories (
  id uuid primary key default gen_random_uuid(), name text not null check(length(name) between 1 and 60),
  status text not null default 'draft' check(status in ('draft','active','finished')),
  current_round int not null default 1, rounds int not null check(rounds between 2 and 4),
  created_at timestamptz not null default now(), deleted_at timestamptz
);
create table bracket_private.matches (
  id uuid primary key default gen_random_uuid(), category_id uuid not null references bracket_private.categories on delete cascade,
  round int not null, position int not null, side_a text, side_b text, winner smallint check(winner in (1,2)),
  ballot int not null default 1, unique(category_id, round, position)
);
create table bracket_private.voters (
  id uuid primary key default gen_random_uuid(), label text not null check(length(label) between 1 and 60),
  code_hash text not null unique, active boolean not null default true, created_at timestamptz not null default now()
);
create table bracket_private.votes (
  voter_id uuid not null references bracket_private.voters, match_id uuid not null references bracket_private.matches on delete cascade,
  ballot int not null, choice smallint not null check(choice in (1,2)), created_at timestamptz not null default now(),
  primary key(voter_id,match_id,ballot)
);
create index votes_match on bracket_private.votes(match_id,ballot);
alter table bracket_private.organizers enable row level security;
alter table bracket_private.categories enable row level security;
alter table bracket_private.matches enable row level security;
alter table bracket_private.voters enable row level security;
alter table bracket_private.votes enable row level security;
revoke all on all tables in schema bracket_private from public, anon, authenticated;

create function bracket_private.is_organizer() returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from auth.users u join bracket_private.organizers o on lower(u.email)=o.email
    where u.id=auth.uid() and u.email_confirmed_at is not null);
$$;
create function bracket_private.require_organizer() returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not bracket_private.is_organizer() then raise exception 'Вход доступен только организатору.' using errcode='42501'; end if;
end $$;
create function bracket_private.code_hash(code text) returns text language sql immutable set search_path = '' as $$
  select encode(sha256(convert_to(upper(regexp_replace(coalesce(code,''),'[[:space:]-]','','g')),'UTF8')),'hex');
$$;

create function public.bracket_state(p_code text default null) returns jsonb language plpgsql stable security definer set search_path = '' as $$
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

create function public.bracket_vote(p_code text,p_match uuid,p_choice int) returns void language plpgsql security definer set search_path = '' as $$
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

create function public.bracket_create_category(p_name text,p_entries text[]) returns uuid language plpgsql security definer set search_path = '' as $$
declare category_key uuid; count_entries int; total_rounds int; r int; i int;
begin
  perform bracket_private.require_organizer();
  count_entries:=cardinality(p_entries);
  if count_entries is null or count_entries not in (4,8,16) then raise exception 'Нужно 4, 8 или 16 участников.'; end if;
  if p_name is null or length(trim(p_name)) not between 1 and 60 then raise exception 'Название: от 1 до 60 символов.'; end if;
  if exists(select 1 from unnest(p_entries) x where x is null or length(trim(x)) not between 1 and 80) then raise exception 'Имя участника: от 1 до 80 символов.'; end if;
  if (select count(distinct lower(trim(x))) from unnest(p_entries) x) <> count_entries then raise exception 'Участники не должны повторяться.'; end if;
  total_rounds:=case count_entries when 4 then 2 when 8 then 3 else 4 end;
  insert into bracket_private.categories(name,rounds) values(trim(p_name),total_rounds) returning id into category_key;
  for r in 1..total_rounds loop
    for i in 0..(count_entries / (2^r)::int - 1) loop
      insert into bracket_private.matches(category_id,round,position,side_a,side_b)
      values(category_key,r,i,case when r=1 then trim(p_entries[2*i+1]) end,case when r=1 then trim(p_entries[2*i+2]) end);
    end loop;
  end loop;
  return category_key;
end $$;

create function public.bracket_rename(p_category uuid,p_name text) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform bracket_private.require_organizer();
  if p_name is null or length(trim(p_name)) not between 1 and 60 then raise exception 'Название: от 1 до 60 символов.'; end if;
  update bracket_private.categories set name=trim(p_name) where id=p_category and deleted_at is null;
  if not found then raise exception 'Голосование не найдено или удалено.'; end if;
end $$;

create function public.bracket_edit_entry(p_match uuid,p_side int,p_name text) returns void language plpgsql security definer set search_path = '' as $$
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

create function public.bracket_start(p_category uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform bracket_private.require_organizer();
  update bracket_private.categories set status='active' where id=p_category and status='draft' and deleted_at is null;
  if not found then raise exception 'Категория уже запущена или не найдена.'; end if;
end $$;

create function public.bracket_close_round(p_category uuid) returns void language plpgsql security definer set search_path = '' as $$
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

create function public.bracket_runoff(p_category uuid) returns int language plpgsql security definer set search_path = '' as $$
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

create function public.bracket_issue_code(p_label text) returns text language plpgsql security definer set search_path = '' as $$
declare code text;
begin
  perform bracket_private.require_organizer();
  if p_label is null or length(trim(p_label)) not between 1 and 60 then raise exception 'Имя: от 1 до 60 символов.'; end if;
  code:=upper(replace(gen_random_uuid()::text,'-',''));
  insert into bracket_private.voters(label,code_hash) values(trim(p_label),bracket_private.code_hash(code));
  return code;
end $$;
create function public.bracket_voters() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform bracket_private.require_organizer();
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'label',label,'active',active) order by created_at) from bracket_private.voters),'[]'::jsonb);
end $$;
create function public.bracket_toggle_voter(p_voter uuid,p_active boolean) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform bracket_private.require_organizer();
  update bracket_private.voters set active=p_active where id=p_voter;
end $$;

revoke all on all functions in schema bracket_private from public,anon,authenticated;
revoke all on function public.bracket_state(text),public.bracket_vote(text,uuid,int),public.bracket_create_category(text,text[]),
  public.bracket_rename(uuid,text),public.bracket_edit_entry(uuid,int,text),public.bracket_start(uuid),public.bracket_close_round(uuid),public.bracket_runoff(uuid),
  public.bracket_issue_code(text),public.bracket_voters(),public.bracket_toggle_voter(uuid,boolean) from public,anon,authenticated;
grant execute on function public.bracket_state(text),public.bracket_vote(text,uuid,int) to anon,authenticated;
grant execute on function public.bracket_create_category(text,text[]),public.bracket_rename(uuid,text),public.bracket_edit_entry(uuid,int,text),
  public.bracket_start(uuid),public.bracket_close_round(uuid),public.bracket_runoff(uuid),public.bracket_issue_code(text),public.bracket_voters(),public.bracket_toggle_voter(uuid,boolean) to authenticated;

create function public.bracket_delete_category(p_category uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform bracket_private.require_organizer();
  update bracket_private.categories set deleted_at=now() where id=p_category and deleted_at is null;
  if not found then raise exception 'Голосование уже удалено или не найдено.'; end if;
end $$;
create function public.bracket_restore_category(p_category uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  perform bracket_private.require_organizer();
  update bracket_private.categories set deleted_at=null where id=p_category and deleted_at is not null;
  if not found then raise exception 'Голосование не найдено в корзине.'; end if;
end $$;
create function public.bracket_trash() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform bracket_private.require_organizer();
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'status',status) order by deleted_at desc) from bracket_private.categories where deleted_at is not null),'[]'::jsonb);
end $$;
revoke all on function public.bracket_delete_category(uuid),public.bracket_restore_category(uuid),public.bracket_trash() from public,anon,authenticated;
grant execute on function public.bracket_delete_category(uuid),public.bracket_restore_category(uuid),public.bracket_trash() to authenticated;

notify pgrst,'reload schema';
commit;
