import vm from 'node:vm';
import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
const source=(await fs.readFile(new URL('./app.js',import.meta.url),'utf8')).replace("import {config} from './config.js';",'');
async function app({hash='',configured=true,failLogin=false,progressReport=null}={}){
  const nodes=new Map(),storage=new Map(),calls=[];
  let expired=false;
  const get=q=>{if(!nodes.has(q))nodes.set(q,{innerHTML:'',textContent:'',value:'',open:false,isConnected:true,handlers:{},classList:{add(){},remove(){}},focus(){},scrollIntoView(){},querySelector:get,addEventListener(type,fn){this.handlers[type]=fn;},showModal(){this.open=true;},close(){this.open=false;this.handlers.close?.();}});return nodes.get(q);};
  const response=data=>({ok:true,json:async()=>data});
  const publicState=code=>({organizer:false,voter:code==='TEST-CODE'?{label:'Test friend'}:null,categories:[]});
  const testSession=()=>({token:'a'.repeat(64),expires_at:Date.now()/1000+43200});
  const context={config:{url:'https://test.invalid',key:'public-test'},document:{querySelector:get,addEventListener(){},hidden:false},sessionStorage:{getItem:k=>storage.get(k),setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)},location:{hash,pathname:'/',search:''},history:{replaceState(){context.location.hash='';}},TextEncoder,URLSearchParams,Date,JSON,String,Number,Boolean,Array,Error,AbortSignal,FormData:class{constructor(values){this.values=values;}get(key){return this.values[key];}},requestAnimationFrame:fn=>fn(),setTimeout(){},clearTimeout(){},setInterval(){},fetch:async(url,options)=>{
    const body=JSON.parse(options.body);calls.push({url,...options,body});
    const name=url.split('bracket_')[1];
    if(name==='state')return response(publicState(body.p_code));
    if(name==='admin_status')return response({configured,setup_allowed:body.p_setup_key==='test-setup-key'});
    if(name==='admin_setup'||name==='admin_login')return response(failLogin?{error:'Неверный пароль.'}:testSession());
    if(name==='admin'){
      if(expired)return response({error:'Сессия закончилась.','code':'admin_session_expired'});
      if(body.p_action==='state')return response({data:{...publicState(body.p_args.p_code),organizer:true}});
      if(body.p_action==='change_password')return response({data:testSession()});
      if(body.p_action==='voting_progress')return response({data:progressReport});
      return response({data:null});
    }
    throw new Error('Unexpected request');
  }};
  const api=await vm.runInNewContext(`(async()=>{${source}\nreturn {adminDialog,passwordDialog,joinDialog,logoutAdmin,refresh,rpc,newCategory,matchHtml,entriesDialog,progressDialog,progressStatus,setTestCategory:c=>{state={organizer:true,voter:{label:'Test'},categories:[c]};selected=c.id;render();},getState:()=>state};})()`,context);
  return {...api,get,storage,calls,context,expire:()=>{expired=true;},submit:values=>get('form').handlers.submit({preventDefault(){},target:{...values,querySelector:get}})};
}
let a=await app({configured:false});await a.adminDialog();assert.match(a.get('#dialog-content').innerHTML,/Первая настройка/);assert.ok(!a.get('#dialog-content').innerHTML.includes('type="password"'));
a=await app({configured:false,hash:'#setup=test-setup-key'});assert.equal(a.context.location.hash,'');assert.match(a.get('#dialog-content').innerHTML,/Задай пароль администратора/);
let count=a.calls.length;await a.submit({password:'test-password',repeat:'different'});assert.equal(a.calls.length,count);assert.match(a.get('.form-error').textContent,/не совпадают/);
await a.submit({password:'я'.repeat(40),repeat:'я'.repeat(40)});assert.equal(a.calls.length,count);assert.match(a.get('.form-error').textContent,/длинный/);
await a.submit({password:'test-password',repeat:'test-password'});assert.equal(a.getState().organizer,true);assert.ok(!a.storage.has('bracket-setup-key'));assert.ok(![...a.storage.values()].join('').includes('test-password'));
await a.logoutAdmin();assert.equal(a.getState().organizer,false);assert.ok(a.calls.some(c=>c.body.p_action==='logout'));assert.ok(!a.storage.has('bracket-admin-session'));
a=await app({failLogin:true});await a.adminDialog();assert.ok(!a.get('#dialog-content').innerHTML.includes('type="email"'));await a.submit({password:'incorrect'});assert.match(a.get('.form-error').textContent,/Неверный пароль/);assert.ok(!a.storage.has('bracket-admin-session'));
a=await app();await a.adminDialog();await a.submit({password:'test-password'});assert.equal(a.getState().organizer,true);a.passwordDialog();await a.submit({current:'test-password',password:'test-password-two',repeat:'test-password-two'});assert.ok(a.calls.some(c=>c.body.p_action==='change_password'&&c.body.p_args.p_current_password==='test-password'));
a.expire();await a.refresh();assert.equal(a.getState().organizer,false);assert.ok(!a.storage.has('bracket-admin-session'));await assert.rejects(()=>a.rpc('issue_code',{p_label:'Forbidden'}),/Войди/);
a=await app();a.joinDialog();await a.submit({code:'TEST-CODE'});assert.equal(a.getState().voter.label,'Test friend');assert.equal(a.storage.get('bracket-code'),'"TEST-CODE"');assert.ok(a.calls.every(c=>!c.url.includes('/auth/v1/')));
console.log('PASS: setup gated, setup key removed, password confirmation/length, no password storage, password-only login, server logout, password change, expired-session cleanup, admin action guard, friend code login. HTTP mocked.');
a=await app();await a.adminDialog();await a.submit({password:'test-password'});
for(const n of [4,5,11,16]){a.newCategory();await a.submit({name:'Size test',entries:Array.from({length:n},(_,i)=>'Option '+i).join('\n')});assert.ok(a.calls.some(c=>c.body.p_action==='create_category'&&c.body.p_args.p_entries.length===n));}
for(const n of [3,17]){a.newCategory();const before=a.calls.length;await a.submit({name:'Invalid',entries:Array.from({length:n},(_,i)=>'Option '+i).join('\n')});assert.equal(a.calls.length,before);assert.match(a.get('.form-error').textContent,/от 4 до 16/);}
const fixture={id:'fixture',name:'11 options',round:1,rounds:4,status:'active',matches:Array.from({length:8},(_,i)=>({id:String(i),round:1,position:i,a:'Option '+i,b:i<5?null:'Opponent '+i,winner:i<5?1:null,votes_a:0,votes_b:0,my_vote:null,ballot:1}))};
a.setTestCategory(fixture);assert.match(a.get('#summary').innerHTML,/11 участников/);assert.match(a.get('#summary').innerHTML,/из 3 пар/);
const byeHtml=a.matchHtml(fixture,fixture.matches[0]);assert.match(byeHtml,/Автопроход/);assert.match(byeHtml,/Без соперника/);assert.equal((byeHtml.match(/ disabled/g)||[]).length,2);
const pendingHtml=a.matchHtml(fixture,{...fixture.matches[0],round:2,a:'Waiting',b:null,winner:null});assert.equal((pendingHtml.match(/ disabled/g)||[]).length,2);
a.entriesDialog();assert.equal((a.get('#dialog-content').innerHTML.match(/data-edit-entry=/g)||[]).length,11);
console.log('PASS: creating 4/5/11/16 entries, rejecting 3/17, accurate entrant and playable-pair counts, disabled bye/pending matches, no empty-slot edits. HTTP mocked.');
const progressReport={category:fixture,total:3,voters:[{id:'1',label:'<script>test</script>',active:true,voted:0},{id:'2',label:'Partial',active:false,voted:2},{id:'3',label:'Complete',active:true,voted:3}]};
a=await app({progressReport});await a.adminDialog();await a.submit({password:'test-password'});a.setTestCategory(fixture);assert.match(a.get('#admin-tools').innerHTML,/Кто проголосовал/);
await a.progressDialog();let html=a.get('#dialog-content').innerHTML;
for(const expected of ['Не голосовал','2 из 3 пар','Готово · 3 из 3 пар','код отключён','Обновить список','&lt;script&gt;test&lt;/script&gt;'])assert.ok(html.includes(expected),expected);
assert.ok(!html.includes('<script>'));assert.ok(a.calls.some(c=>c.body.p_action==='voting_progress'&&c.body.p_args.p_category==='fixture'));
count=a.calls.length;await a.get('#progress-refresh').onclick();assert.equal(a.calls.length,count+1);
assert.equal(a.progressStatus({voted:0},{...progressReport,category:{status:'draft'}}),'Голосование ещё не открыто');
assert.equal(a.progressStatus({voted:0},{...progressReport,total:0}),'Нет пар для голосования');
progressReport.voters=[];await a.progressDialog();assert.match(a.get('#dialog-content').innerHTML,/Пока никто не приглашён/);
await a.logoutAdmin();count=a.calls.length;await a.progressDialog('fixture');assert.equal(a.calls.length,count);assert.ok(!a.get('#admin-tools').innerHTML.includes('Кто проголосовал'));
console.log('PASS: private participation dialog, escaped labels, statuses, disabled codes, refresh, empty/draft states and guest guard. HTTP mocked.');
