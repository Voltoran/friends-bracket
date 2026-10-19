-- Test all supported sizes without retaining any test records.
begin;
do $$
declare token text:=gen_random_uuid()::text; c uuid; n int; capacity int; byes int; r int; total int; entries text[]; voter text; m bracket_private.matches;
begin
  insert into bracket_private.admin_sessions(token_hash,expires_at) values(bracket_private.secret_hash(token),now()+interval '1 hour');
  perform set_config('bracket.admin_token',token,true);
  voter:=public.bracket_issue_code('Size test');
  for n in 4..16 loop
    select array_agg('Option '||i order by i) into entries from generate_series(1,n) i;
    c:=public.bracket_create_category('Size test '||n,entries);
    select rounds into total from bracket_private.categories where id=c;
    capacity:=(2^total)::int; byes:=capacity-n;
    if (select count(*) from bracket_private.matches where category_id=c)<>capacity-1 then raise exception 'TEST: match count %',n; end if;
    if (select count(side_a)+count(side_b) from bracket_private.matches where category_id=c and round=1)<>n then raise exception 'TEST: entrant count %',n; end if;
    if exists(select 1 from bracket_private.matches where category_id=c and round=1 and side_a is null) then raise exception 'TEST: empty match'; end if;
    if (select count(*) from bracket_private.matches where category_id=c and round=1 and side_b is null)<>byes then raise exception 'TEST: bye count'; end if;
    if byes=0 and exists(select 1 from bracket_private.matches where category_id=c and round=1 and (side_a<>entries[position*2+1] or side_b<>entries[position*2+2])) then raise exception 'TEST: legacy ordering'; end if;
    if byes>0 then
      select * into m from bracket_private.matches where category_id=c and round=1 and position=0;
      begin perform public.bracket_edit_entry(m.id,2,'Extra'); raise exception 'TEST: bye editable'; exception when others then if sqlerrm like 'TEST:%' then raise; end if; end;
      perform public.bracket_edit_entry(m.id,1,'Renamed option');
    end if;
    perform public.bracket_start(c);
    if (select count(*) from bracket_private.matches where category_id=c and round=1 and winner=1)<>byes then raise exception 'TEST: unresolved bye'; end if;
    if byes>0 then
      if (select side_a from bracket_private.matches where category_id=c and round=2 and position=0)<>'Renamed option' then raise exception 'TEST: renamed bye propagation'; end if;
      begin perform public.bracket_vote(voter,m.id,1); raise exception 'TEST: bye vote'; exception when others then if sqlerrm like 'TEST:%' then raise; end if; end;
    end if;
    begin perform public.bracket_close_round(c); raise exception 'TEST: empty votes closed'; exception when others then if sqlerrm like 'TEST:%' then raise; end if; end;
    for r in 1..total loop
      for m in select * from bracket_private.matches where category_id=c and round=r and winner is null loop
        if m.side_a is null or m.side_b is null then raise exception 'TEST: missing opponent % round %',n,r; end if;
        perform public.bracket_vote(voter,m.id,1);
      end loop;
      perform public.bracket_close_round(c);
    end loop;
    if (select status from bracket_private.categories where id=c)<>'finished' then raise exception 'TEST: unfinished'; end if;
    if (select count(*) from bracket_private.votes v join bracket_private.matches x on x.id=v.match_id where x.category_id=c)<>n-1 then raise exception 'TEST: elimination count'; end if;
  end loop;
  begin perform public.bracket_create_category('Invalid',array['A','B','C']); raise exception 'TEST: too few accepted'; exception when others then if sqlerrm like 'TEST:%' then raise; end if; end;
  begin perform public.bracket_create_category('Invalid',array_fill('A',array[17])); raise exception 'TEST: too many accepted'; exception when others then if sqlerrm like 'TEST:%' then raise; end if; end;
  if has_function_privilege('anon','public.bracket_create_category(text,text[])','execute') or has_function_privilege('authenticated','public.bracket_start(uuid)','execute') then raise exception 'TEST: direct admin grant'; end if;
end $$;
rollback;
select 'PASS: all sizes 4–16, including 11; byes, edits, voting guards, round progression, finals and permissions. Test data rolled back.' as result;
