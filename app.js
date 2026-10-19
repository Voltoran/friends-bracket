import {config} from './config.js';

const $ = (q, root=document) => root.querySelector(q);
const escape = value => String(value ?? '').replace(/[&<>"']/g, x=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[x]));
const load = (key, fallback=null) => {try{return JSON.parse(sessionStorage.getItem(key)) ?? fallback;}catch{return fallback;}};
const save = (key,value) => {try{value === null ? sessionStorage.removeItem(key) : sessionStorage.setItem(key,JSON.stringify(value));}catch{}};
let session=load('bracket-session'), code=load('bracket-code',''), state=null, selected=null, busy=false, loading=false, toastTimer, refreshPromise;
const dialog=$('#dialog');
const roundName=(round,total)=>({0:'Финал',1:'Полуфинал',2:'Четвертьфинал',3:'1/8 финала'}[total-round] || `Раунд ${round}`);
const statusName=c=>({draft:'Скоро старт',active:'Идёт голосование',finished:'Турнир завершён'}[c.status]);
const category=()=>state?.categories.find(c=>c.id===selected);
// Supabase returns the one-time email sign-in session in the URL fragment.
// Remove it before any further navigation or sharing.
const signInHash=new URLSearchParams(location.hash.slice(1));
let signedInFromEmail=false;
if(signInHash.has('access_token')){
  session={access_token:signInHash.get('access_token'),refresh_token:signInHash.get('refresh_token'),expires_at:Number(signInHash.get('expires_at'))||Math.floor(Date.now()/1000)+Number(signInHash.get('expires_in')||3600)};
  save('bracket-session',session);signedInFromEmail=true;history.replaceState(null,'',location.pathname+location.search);
}else if(signInHash.has('error_description')){
  history.replaceState(null,'',location.pathname+location.search);
  setTimeout(()=>toast('Ссылка для входа недействительна или уже использована. Запроси новую.'),100);
}

async function request(path,body,{authenticated=true}={}) {
  if(authenticated && session && session.expires_at*1000<Date.now()+60000) {
    refreshPromise ||= request('/auth/v1/token?grant_type=refresh_token',{refresh_token:session.refresh_token},{authenticated:false})
      .then(data=>{session=data;session.expires_at ||= Math.floor(Date.now()/1000)+data.expires_in;save('bracket-session',session);})
      .catch(()=>{session=null;save('bracket-session',null);throw new Error('Сессия закончилась. Войди в панель организатора снова.');})
      .finally(()=>{refreshPromise=null;});
    await refreshPromise;
  }
  let response;
  try{response=await fetch(config.url+path,{method:'POST',headers:{'Content-Type':'application/json',apikey:config.key,...(authenticated&&session?{Authorization:`Bearer ${session.access_token}`}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(20000)});}
  catch{throw new Error('Не удалось связаться с сервером. Проверь интернет и попробуй ещё раз.');}
  const data=await response.json().catch(()=>null);
  if(!response.ok) {
    if(response.status===429) throw new Error('Слишком много запросов. Подожди минуту и повтори.');
    const message=data?.msg || data?.message || data?.error_description || data?.error;
    if(String(message).includes('Email address not authorized')) throw new Error('Для входа используй почту владельца проекта Supabase.');
    if(String(message).includes('permission denied')) throw new Error('Это действие доступно только организатору.');
    if(/expired|invalid.*token|token.*invalid/i.test(message || '')) throw new Error('Код или сессия истекли. Запроси новый код для входа.');
    throw new Error(message || `Сервер вернул ошибку ${response.status}.`);
  }
  return data;
}
const rpc=(name,args={})=>request(`/rest/v1/rpc/bracket_${name}`,args);
function toast(message){$('#toast').textContent=message;$('#toast').classList.add('show');clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').classList.remove('show'),4500);}
function modal(html){$('#dialog-content').innerHTML=html;if(!dialog.open)dialog.showModal();requestAnimationFrame(()=>$('#dialog-content input, #dialog-content textarea, #dialog-content button')?.focus());}
function formError(error){const target=$('.form-error',dialog);if(target)target.textContent=error.message || String(error);else toast(error.message || String(error));}
function formHandler(callback){$('form',dialog)?.addEventListener('submit',async event=>{event.preventDefault();const btn=$('[type=submit]',event.target);btn.disabled=true;const error=$('.form-error',dialog);if(error)error.textContent='';try{await callback(new FormData(event.target));}catch(e){formError(e);}finally{if(btn.isConnected)btn.disabled=false;}});}

async function refresh({silent=false}={}){
  if(loading)return; loading=true;$('#refresh').disabled=true;
  try{
    const data=await rpc('state',{p_code:code||null});
    state=data;selected=state.categories.some(c=>c.id===selected)?selected:state.categories[0]?.id;
    if(code&&!state.voter){code='';save('bracket-code',null);if(!silent)toast('Код больше не действует. Обратись к организатору.');}
    $('#notice').hidden=true;$('#connection').textContent='На связи';render();
  }catch(e){$('#connection').textContent='Нет связи';if(!silent||!state){$('#notice').hidden=false;$('#notice').textContent=e.message;}if(!state)$('#tournament-title').textContent='Не удалось загрузить турниры';}
  finally{loading=false;$('#refresh').disabled=false;}
}

function render(){
  $('#category-count').textContent=state.categories.length;
  $('#categories').innerHTML=state.categories.map((c,i)=>`<button class="category-button ${c.id===selected?'selected':''}" data-category="${c.id}" aria-current="${c.id===selected?'true':'false'}"><span class="category-icon" aria-hidden="true">${['✳','◈','◉','✦'][i%4]}</span><span class="category-text">${escape(c.name)}<small>${statusName(c)}</small></span><span class="category-arrow" aria-hidden="true">↗</span></button>`).join('') || '<p class="muted">Пока нет категорий</p>';
  $('#join').textContent=state.voter?`${state.voter.label} · выйти`:'Войти по коду ↗';
  $('#admin-open').innerHTML=`<span aria-hidden="true">⚙</span> ${state.organizer?'Панель организатора':'Организатор'}`;
  const c=category();
  if(!c){$('#tournament-title').textContent='Первый турнир впереди';$('#tournament-status').textContent='';$('#summary').innerHTML='';$('#winner-banner').innerHTML='';$('#bracket').innerHTML='<div class="empty-state"><strong>Здесь появится ваша сетка</strong>Организатор добавит категорию и участников.</div>';renderAdmin();return;}
  $('#tournament-title').textContent=c.name;$('#tournament-status').textContent=statusName(c);
  const current=c.matches.filter(m=>m.round===c.round),totalVotes=c.matches.reduce((n,m)=>n+m.votes_a+m.votes_b,0),myVotes=current.filter(m=>m.my_vote).length;
  $('#summary').innerHTML=`<span>${2**c.rounds} участников</span><span>${c.status==='draft'?'Голоса откроются после старта':roundName(c.round,c.rounds)}</span><span>${totalVotes} голосов в сетке</span>${state.voter&&c.status==='active'?`<span>Твой выбор: ${myVotes} из ${current.length} пар</span>`:''}`;
  const final=c.matches.find(m=>m.round===c.rounds);
  $('#winner-banner').innerHTML=c.status==='finished'?`<div class="winner"><span aria-hidden="true">✳</span><div><small>ВАШ ОБЩИЙ ПОБЕДИТЕЛЬ</small><h3>${escape(final.winner===1?final.a:final.b)}</h3></div></div>`:'';
  $('#bracket').innerHTML=Array.from({length:c.rounds},(_,index)=>{
    const round=index+1;
    return `<div class="round-column ${round===c.round?'current':''}"><div class="round-heading"><span>${roundName(round,c.rounds).toUpperCase()}</span><span class="round-number">${String(round).padStart(2,'0')}</span></div><div class="match-list">${c.matches.filter(m=>m.round===round).map(m=>matchHtml(c,m)).join('')}</div></div>`;
  }).join('');renderAdmin();
}
function matchHtml(c,m){
  const open=c.status==='active'&&m.round===c.round&&!m.winner;
  return `<article class="match ${open?'ready':''} ${!m.a?'future':''}"><div class="match-title"><span>Пара ${String(m.position+1).padStart(2,'0')}</span><span class="${m.my_vote?'voted-check':''}">${m.winner?'Завершена':m.my_vote?'✓ Голос принят':open?'Выбери фаворита':!m.a?'Ждём победителей':'Скоро старт'}</span></div>${[1,2].map((side)=>{
    const name=side===1?m.a:m.b,score=side===1?m.votes_a:m.votes_b;
    return `<button class="choice ${!name?'empty':''} ${m.my_vote===side?'picked':''} ${m.winner===side?'won':m.winner?'lost':''}" data-vote="${m.id}" data-side="${side}" ${!open||m.my_vote||busy?'disabled':''} aria-label="${escape(name||'Участник ещё не определён')}${name?`: ${score} голосов`:''}${m.my_vote===side?', твой голос':''}${m.winner===side?', победитель':''}"><span class="choice-number" aria-hidden="true">${m.winner===side?'✓':name?String(m.position*2+side).padStart(2,'0'):'·'}</span><span class="choice-name">${escape(name||'Победитель предыдущей пары')}</span><span class="choice-score">${name?(c.status==='draft'?'—':score):''}</span></button>`;
  }).join('')}${m.ballot>1?`<div class="match-note">Переголосование №${m.ballot-1} · прежние голоса в архиве</div>`:''}</article>`;
}
function renderAdmin(){
  if(!state.organizer){$('#admin-tools').innerHTML='';return;}
  const c=category();
  $('#admin-tools').innerHTML=`<div class="admin-tools"><div class="eyebrow">УПРАВЛЕНИЕ ТУРНИРОМ</div><div class="button-row"><button class="button" data-action="new-category">+ Категория</button><button class="button" data-action="voters">Коды друзей</button>${c?`<button class="button" data-action="rename">Название</button>${c.status==='draft'?'<button class="button" data-action="entries">Участники</button><button class="button green" data-action="start">Открыть голосование</button>':c.status==='active'?'<button class="button" data-action="runoff">Переголосование при ничьей</button><button class="button green" data-action="close">Завершить раунд →</button>':''}`:''}<button class="button" data-action="logout">Выйти из управления</button></div><p>До старта можно изменить имена участников. При закрытии раунда все пары должны иметь победителя.</p></div>`;
}
function joinDialog(){
  if(state?.voter){code='';save('bracket-code',null);refresh();toast('Ты вышел из голосования');return;}
  modal(`<h2>Ты в кругу друзей</h2><p>Введи персональный код от организатора. Он даёт один голос в каждой паре. Выбор после отправки изменить нельзя.</p><form><label for="voter-code">Твой код</label><input id="voter-code" name="code" placeholder="Вставь код приглашения" required maxlength="80" autocomplete="off" autocapitalize="characters" spellcheck="false"><div class="form-error" role="alert"></div><div class="form-actions"><button class="button dark" type="submit">Присоединиться ↗</button></div></form>`);
  formHandler(async data=>{const candidate=data.get('code').trim();const result=await rpc('state',{p_code:candidate});if(!result.voter)throw new Error('Код не найден или отключён. Проверь его у организатора.');code=candidate;save('bracket-code',code);state=result;dialog.close();render();toast(`Привет, ${result.voter.label}! Выбирай фаворитов.`);});
}
function adminDialog(){
  if(state?.organizer){votersDialog();return;}
  modal(`<h2>Вход организатора</h2><p>Введи почту владельца турнира. Пришлём одноразовую ссылку для входа. Друзьям для голосования почта не нужна.</p><form><label for="email">Электронная почта</label><input id="email" name="email" type="email" autocomplete="email" required placeholder="you@example.com"><div class="form-error" role="alert"></div><div class="form-actions"><button class="button dark" type="submit">Получить ссылку</button></div></form>`);
  formHandler(async data=>{const email=data.get('email').trim().toLowerCase();await request('/auth/v1/otp?redirect_to='+encodeURIComponent('https://voltoran.github.io/friends-bracket/'),{email,create_user:true},{authenticated:false});modal('<h2>Проверь почту</h2><p>Письмо со ссылкой для входа отправлено на '+escape(email)+'. Открой ссылку: панель организатора появится на сайте. Если письма нет, проверь «Спам».</p><p>Повторный запрос доступен через минуту. Ссылка одноразовая; не пересылай её другим.</p>');});
}
function newCategory(){
  modal(`<h2>Новый турнир</h2><p>Добавь 4, 8 или 16 участников — по одному на строку. Соседние строки образуют пары первого раунда.</p><form><label for="category-name">Категория</label><input id="category-name" name="name" maxlength="60" required placeholder="Например, любимые фильмы"><label for="entries">Участники</label><textarea id="entries" name="entries" required placeholder="Первый участник&#10;Второй участник&#10;Третий участник&#10;Четвёртый участник"></textarea><div class="form-error" role="alert"></div><div class="form-actions"><button class="button dark" type="submit">Создать сетку</button></div></form>`);
  formHandler(async data=>{const entries=data.get('entries').split('\n').map(x=>x.trim()).filter(Boolean);if(![4,8,16].includes(entries.length))throw new Error('Нужно 4, 8 или 16 участников.');selected=await rpc('create_category',{p_name:data.get('name').trim(),p_entries:entries});dialog.close();await refresh();toast('Сетка создана. Открой голосование, когда всё готово.');});
}
async function votersDialog(){
  modal('<h2>Коды друзей</h2><p>Загружаем список…</p>');
  try{
    const voters=await rpc('voters');
    modal(`<h2>Пригласи своих</h2><p>Создай отдельный код каждому другу. Код показывается один раз; скопируй и отправь его вместе со ссылкой на сайт.</p><form><label for="friend-name">Имя друга</label><input id="friend-name" name="name" maxlength="60" required placeholder="Как его зовут?"><div class="form-error" role="alert"></div><div class="form-actions"><button class="button dark" type="submit">Создать код</button></div></form><div class="voter-list">${voters.map(v=>`<div class="voter-row"><span>${escape(v.label)}${v.active?'':' · отключён'}</span><button class="button" data-toggle-voter="${v.id}" data-active="${!v.active}">${v.active?'Отключить':'Включить'}</button></div>`).join('')||'<p>Пока никто не приглашён.</p>'}</div>`);
    formHandler(async data=>{const label=data.get('name').trim();const issued=await rpc('issue_code',{p_label:label});modal(`<h2>Код для ${escape(label)}</h2><p>Сохрани его сейчас: база хранит только отпечаток кода, восстановить исходный код нельзя. При потере можно создать новый и отключить старый.</p><div class="code-output">${issued.match(/.{1,4}/g).join('-')}</div><div class="form-actions"><button class="button dark" id="copy-invite">Скопировать приглашение</button><button class="button" id="back-voters">Готово</button></div>`);$('#copy-invite').onclick=async()=>{try{await navigator.clipboard.writeText(`Заходи в круг друзей: https://voltoran.github.io/friends-bracket/\nТвой персональный код: ${issued}`);toast('Приглашение скопировано');}catch{toast('Не удалось скопировать. Выдели код и скопируй вручную.');}};$('#back-voters').onclick=votersDialog;});
  }catch(e){modal(`<h2>Не удалось загрузить коды</h2><p>${escape(e.message)}</p>`);}
}
function renameDialog(){const c=category();modal(`<h2>Название категории</h2><form><label for="new-name">Название</label><input id="new-name" name="name" maxlength="60" required value="${escape(c.name)}"><div class="form-error" role="alert"></div><div class="form-actions"><button class="button dark" type="submit">Сохранить</button></div></form>`);formHandler(async data=>{await rpc('rename',{p_category:c.id,p_name:data.get('name')});dialog.close();await refresh();});}
function entriesDialog(){const c=category();modal(`<h2>Участники</h2><p>Нажми на имя, чтобы изменить его до старта турнира.</p><div class="voter-list">${c.matches.filter(m=>m.round===1).map(m=>[1,2].map(side=>`<div class="voter-row"><span>${escape(side===1?m.a:m.b)}</span><button class="button" data-edit-entry="${m.id}" data-side="${side}">Изменить</button></div>`).join('')).join('')}</div>`);}
function editEntry(match,side){const m=category().matches.find(x=>x.id===match);modal(`<h2>Имя участника</h2><form><label for="entry-name">Название</label><input id="entry-name" name="name" maxlength="80" required value="${escape(side===1?m.a:m.b)}"><div class="form-error" role="alert"></div><div class="form-actions"><button class="button dark" type="submit">Сохранить</button></div></form>`);formHandler(async data=>{await rpc('edit_entry',{p_match:match,p_side:side,p_name:data.get('name')});await refresh();entriesDialog();});}
function confirmAction(action){
  const c=category();const specs={start:['Открыть голосование?','После старта имена участников фиксируются. Друзья смогут голосовать по своим кодам.','Открыть','start'],close:['Завершить этот раунд?','Голоса зафиксируются, а победители перейдут дальше. Если в какой-либо паре ничья, раунд останется открытым.','Завершить раунд','close_round'],runoff:['Переголосовать при ничьей?','Только пары с равным ненулевым счётом начнут новое голосование с нуля. Предыдущие голоса останутся в архиве; друзья смогут проголосовать заново.','Начать переголосование','runoff']};
  const [title,description,label,fn]=specs[action];modal(`<h2>${title}</h2><p>${description}</p><form><div class="form-error" role="alert"></div><div class="form-actions"><button class="button dark" type="submit">${label}</button></div></form>`);formHandler(async()=>{await rpc(fn,{p_category:c.id});dialog.close();await refresh();toast('Готово. Сетка обновлена.');});
}
$('#categories').onclick=event=>{const button=event.target.closest('[data-category]');if(button){selected=button.dataset.category;render();}};
$('#bracket').onclick=async event=>{
  const button=event.target.closest('[data-vote]');if(!button||button.disabled||busy)return;
  if(!state.voter){joinDialog();return;}
  busy=true;render();
  try{await rpc('vote',{p_code:code,p_match:button.dataset.vote,p_choice:Number(button.dataset.side)});toast('Голос принят. Спасибо!');}
  catch(e){toast(e.message);}finally{busy=false;await refresh();render();}
};
$('#admin-tools').onclick=event=>{const action=event.target.closest('[data-action]')?.dataset.action;if(!action)return;
  if(action==='new-category')newCategory();else if(action==='voters')votersDialog();else if(action==='rename')renameDialog();else if(action==='entries')entriesDialog();else if(action==='logout'){session=null;save('bracket-session',null);refresh();toast('Выход из управления выполнен');}else confirmAction(action);
};
dialog.addEventListener('click',async event=>{
  const toggle=event.target.closest('[data-toggle-voter]');
  if(toggle){toggle.disabled=true;try{await rpc('toggle_voter',{p_voter:toggle.dataset.toggleVoter,p_active:toggle.dataset.active==='true'});await votersDialog();}catch(e){formError(e);toggle.disabled=false;}}
  const edit=event.target.closest('[data-edit-entry]');if(edit)editEntry(edit.dataset.editEntry,Number(edit.dataset.side));
});
$('#join').onclick=joinDialog;$('#admin-open').onclick=adminDialog;$('#refresh').onclick=()=>refresh();$('#dialog-close').onclick=()=>dialog.close();
$('#rules').onclick=()=>modal(`<h2>Как выбираем победителя</h2><ol class="rules-list"><li>У каждой категории своя сетка. В паре два участника — выбирай одного.</li><li>Персональный код даёт один голос в каждой паре текущего раунда. Изменить отправленный голос нельзя.</li><li>Организатор закрывает раунд. Победитель каждой пары проходит дальше.</li><li>При ничьей организатор может открыть переголосование. В таких парах можно голосовать снова.</li><li>Код предназначен одному человеку. Передав его, ты передаёшь право своего голоса.</li></ol><p>Результаты видны всем по ссылке. Имена голосующих и персональные коды публично не отображаются. Код хранится в этой вкладке до выхода; другая вкладка может попросить ввести его снова.</p>`);
await refresh();
if(signedInFromEmail){
  if(state?.organizer)toast('Вход выполнен. Панель организатора — под сеткой.');
  else if(state){session=null;save('bracket-session',null);toast('У этой почты нет прав организатора.');}
}
setInterval(()=>{if(!document.hidden&&!dialog.open&&!busy)refresh({silent:true});},20000);
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&!busy)refresh({silent:true});});
