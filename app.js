'use strict';
const TABS=['Dashboard','Heijunka','Station 11','Station 6','Station 1','Spare Tire','Inventory','History'];
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DEVICE_ACCESS='tm-permanent-device-v1';
let tab='Dashboard',state=null,room=null,key=null,role=null,broadcastKey=null;
let allowedTab=null,stationLinks={};
let revision=-1,busy=false,online=false,lastContact=0;
let serverEpoch=Date.now(),clockAnchor=performance.now();
let channel=null,realtimeReady=false,refreshing=null,refreshAgain=false,pending=null;
let accessToOpen=null,joining=false;
const db=window.supabase.createClient(KANBAN_CONFIG.url,KANBAN_CONFIG.publishableKey,{
  auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false},
  global:{fetch:(url,options)=>fetch(url,{...options,signal:AbortSignal.timeout(12000)})}
});
const el=id=>document.getElementById(id);
const escapeHTML=value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function message(text=''){el('messages').textContent=text;}
function status(){
  const label=role==='instructor'?'Instructor':'Station';
  el('connection').textContent=!key?'Open your permanent instructor or station link.':!online?
    'CONNECTION LOST — controls paused. Reconnecting…':
    `${realtimeReady?'LIVE':'CONNECTED'} — ${allowedTab||label} · ${busy?'Saving…':'production synchronized'}`;
  el('connection').classList.toggle('disconnected',!!room&&!online);
}
function repaint(){if(state)render();status();updateClocks();}
function updateHash(){
  const p=new URLSearchParams({key,tab});
  window.history.replaceState(null,'','#'+p);
  if(role)try{localStorage.setItem(DEVICE_ACCESS,JSON.stringify({key,tab}));}catch{}
}
function makeLink(access,view){
  const url=new URL(KANBAN_CONFIG.siteUrl||location.href);url.search='';url.hash=new URLSearchParams({key:access,tab:view});return url.href;
}
function showLinks(){
  el('share').hidden=role!=='instructor';
  if(role!=='instructor'){el('device-links').replaceChildren();return;}
  el('room-name').textContent='One permanent production line · reuse these links for every run';
  el('access-note').textContent=role==='instructor'?
    'Bookmark the instructor link and send each station link once. Reset Run starts over without changing any links.':
    'This device can complete station work. The instructor controls Start, Reset, the interruption and Restore.';
  const entries=role==='instructor'?[['Instructor',key,'Dashboard']]:[];
  for(const view of TABS.filter(t=>t!=='Dashboard')){
    if(stationLinks[view])entries.push([view,stationLinks[view],view]);
  }
  el('device-links').replaceChildren(...entries.map(([label,access,view])=>{
    const row=document.createElement('div');row.className='device-link';
    const a=document.createElement('a');a.textContent=label;a.href=makeLink(access,view);
    const button=document.createElement('button');button.type='button';button.textContent='Copy link';
    button.setAttribute('aria-label','Copy '+label+' link');
    button.addEventListener('click',async()=>{
      try{await navigator.clipboard.writeText(a.href);button.textContent='Copied';setTimeout(()=>button.textContent='Copy link',1800);}
      catch{window.prompt('Copy this '+label+' link:',a.href);}
    });row.append(a,button);return row;
  }));
}
function applySnapshot(data,sentAt){
  lastContact=Date.now();online=true;
  serverEpoch=data.serverTime+Math.max(0,lastContact-sentAt)/2;
  clockAnchor=performance.now();
  if(data.revision>=revision){state=data.state;revision=data.revision;}
  const first=role===null;role=data.role;broadcastKey=data.broadcastKey;
  allowedTab=data.allowedTab;stationLinks=data.stationLinks||{};
  if(role!=='instructor'&&allowedTab&&tab!==allowedTab){tab=allowedTab;updateHash();}
  if(first){message();el('setup').hidden=true;showLinks();subscribe();}
  updateHash();
  repaint();
}
async function rpc(name,args){
  const {data,error}=await db.rpc(name,args);
  if(error){const e=new Error(error.message);e.uncertain=!error.code||error.code==='PGRST000';throw e;}
  return data;
}
async function refresh(){
  if(!room||!key)return;
  if(refreshing){refreshAgain=true;return refreshing;}
  refreshing=(async()=>{
    try{const sent=Date.now();const data=await rpc('kanban_room_action',{p_room:room,p_key:key});applySnapshot(data,sent);}
    catch(e){online=false;repaint();if(!state)message('Unable to open this screen. Check your permanent link and internet connection. '+e.message);}
    finally{refreshing=null;}
  })();
  await refreshing;
  if(refreshAgain){refreshAgain=false;setTimeout(refresh,100);}
}
function subscribe(){
  channel=db.channel('kanban:'+broadcastKey)
    .on('broadcast',{event:'changed'},()=>refresh())
    .subscribe(s=>{realtimeReady=s==='SUBSCRIBED';status();if(realtimeReady)refresh();});
}
async function join(params){
  if(!UUID.test(params.get('key')||''))throw new Error('Open a complete instructor or station link.');
  accessToOpen=new URLSearchParams(params);
  key=params.get('key');
  if(joining)return;
  joining=true;
  try{
    if(!room){const info=await rpc('kanban_session_info',{});if(!UUID.test(info.sessionId||''))throw new Error('The production line is not configured.');room=info.sessionId;}
    tab=TABS.includes(params.get('tab'))?params.get('tab'):'Dashboard';
    updateHash();status();await refresh();
  }finally{joining=false;}
}
function queue11(){return state.orders.filter(o=>o.status==='released');}
function queueK(cell){return state.kanbans.filter(k=>k.cell===cell&&k.status==='open');}
function countdown(){
  if(!online)return 'Waiting for connection';
  if(state.start===null)return 'STOPPED — waiting for instructor to start';
  if(state.attack)return 'Production clock paused';
  if(state.released===5)return 'All batches released';
  const ms=Math.max(0,state.released*480000-(serverNow()-state.start-state.paused));
  return 'Next batch in '+String(Math.floor(ms/60000)).padStart(2,'0')+':'+String(Math.floor(ms%60000/1000)).padStart(2,'0');
}
function serverNow(){return serverEpoch+performance.now()-clockAnchor;}
const wallClockFormat=new Intl.DateTimeFormat('en-US',{
  timeZone:'America/Chicago',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false,timeZoneName:'short'
});
const durationFormat=typeof Intl.DurationFormat==='function'?
  new Intl.DurationFormat('en-US',{style:'digital',hoursDisplay:'always'}):null;
function formatElapsed(start,end){
  const endMs=Math.max(start,Math.trunc(end));
  let duration;
  if(globalThis.Temporal?.Instant){
    duration=Temporal.Instant.fromEpochMilliseconds(endMs).since(
      Temporal.Instant.fromEpochMilliseconds(start),{largestUnit:'hours',smallestUnit:'seconds',roundingMode:'floor'});
  }else{
    // Fixed elapsed seconds, not calendar arithmetic; works on older tablet browsers.
    const seconds=Math.floor((endMs-start)/1000);
    duration={hours:Math.floor(seconds/3600),minutes:Math.floor(seconds/60)%60,seconds:seconds%60};
  }
  if(durationFormat)return durationFormat.format(duration);
  return [duration.hours,duration.minutes,duration.seconds].map(n=>String(n).padStart(2,'0')).join(':');
}
function updateClocks(){
  const now=serverNow();
  el('wall-clock').textContent=wallClockFormat.format(now);
  el('wall-clock').dateTime=new Date(now).toISOString();
  el('run-clock').textContent=!state?'00:00:00':!online?'Waiting for connection':state.start===null?'00:00:00':
    formatElapsed(state.start,(state.attack?state.attackStart:now)-state.paused);
  el('run-clock-label').textContent=state?.attack?'Run time · paused':'Run time';
  el('batch-clock').textContent=state?countdown():'Waiting for production';
}
function btn(label,action,cls='',disabled=false){
  const admin=/^(start|attack|restore|reset)\(/.test(action);
  if(admin&&role!=='instructor')return '';
  const mutation=admin||/^complete/.test(action);
  const blocked=disabled||(mutation&&(!online||busy));
  return '<button class="'+cls+'" '+(blocked?'disabled ':'')+'onclick="'+action.replace(/"/g,'&quot;')+'">'+label+'</button>';
}
function currentItem(action){
  if(action==='complete11')return queue11()[0]?.id;
  if(action==='complete6')return queueK(2)[0]?.id;
  if(action==='complete1')return queueK(1)[0]?.id;
  if(action==='completeSpare')return state.spares.find(x=>x.status==='open')?.id;
  return null;
}
async function command(action){
  if(busy||!online||!state)return;
  if(pending){message('Resolve the previous action before sending another.');return;}
  pending={p_room:room,p_key:key,p_action:action,p_request:crypto.randomUUID(),p_generation:state.generation,p_item:currentItem(action)||null};
  await sendPending();
}
async function sendPending(){
  busy=true;message();repaint();
  try{const sent=Date.now();const data=await rpc('kanban_room_action',pending);pending=null;applySnapshot(data,sent);}
  catch(e){
    if(e.uncertain){online=false;message('The action could not be confirmed. Reconnecting and checking the same request…');}
    else{pending=null;message(e.message);await refresh();}
  }finally{busy=false;repaint();}
}
function start(){return command('start');}
function reset(){if(confirm('Reset the shared run on ALL connected devices?'))return command('reset');}
function attack(){return command('attack');}
function restore(){return command('restore');}
function complete11(){return command('complete11');}
function complete6(){return command('complete6');}
function complete1(){return command('complete1');}
function completeSpare(){return command('completeSpare');}
document.addEventListener('keydown',e=>{
  if(e.key!=='Enter'||e.repeat||!state||state.attack||e.target.closest('button,input,textarea,select,summary,a'))return;
  const f={'Station 11':complete11,'Station 6':complete6,'Station 1':complete1,'Spare Tire':completeSpare}[tab];
  if(f){e.preventDefault();f();}
});
el('join-room').addEventListener('submit',async e=>{
  e.preventDefault();message();
  try{const url=new URL(el('room-link').value);const p=new URLSearchParams(url.hash.slice(1));
    if(!UUID.test(p.get('key')||''))throw new Error('Paste a complete instructor or station link.');
    // Reload clears the previous room subscription and any in-flight requests.
    const target=new URL(location.href);target.hash=p;location.replace(target);location.reload();
  }catch(err){message(err.message);}
});
window.addEventListener('online',()=>refresh());
window.addEventListener('offline',()=>{online=false;repaint();});
document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh();});
window.addEventListener('pageshow',()=>{if(room)refresh();});
window.addEventListener('hashchange',()=>location.reload());
setInterval(async()=>{
  if(!room&&accessToOpen&&!joining){join(accessToOpen).catch(e=>message(e.message));return;}
  if(room&&key&&Date.now()-lastContact>6000){online=false;repaint();}
  if(pending&&!busy){await sendPending();return;}
  await refresh();
},2000);
setInterval(updateClocks,250);
document.addEventListener('DOMContentLoaded',()=>{
  updateClocks();
  let params=new URLSearchParams(location.hash.slice(1));
  if(!params.get('key'))try{const saved=JSON.parse(localStorage.getItem(DEVICE_ACCESS)||'null');if(saved?.key)params=new URLSearchParams(saved);}catch{}
  if(params.get('key'))join(params).catch(e=>message(e.message));
});
