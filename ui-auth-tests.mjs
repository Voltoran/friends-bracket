import vm from 'node:vm';
import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
const source=(await fs.readFile(new URL('./app.js',import.meta.url),'utf8')).replace("import {config} from './config.js';",'');
async function app({hash='',configured=true,failLogin=false}={}){
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
      return response({data:null});
    }
    throw new Error('Unexpected request');
  }};
  const api=await vm.runInNewContext(`(async()=>{${source}\nreturn {adminDialog,passwordDialog,joinDialog,logoutAdmin,refresh,rpc,getState:()=>state};})()`,context);
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
