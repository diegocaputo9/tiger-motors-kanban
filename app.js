'use strict';
const TABS=['Dashboard','Heijunka','Station 11','Station 6','Station 1','Spare Tire','Inventory','History'];
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
let tab='Dashboard',state=null,room=null,key=null,role=null,stationKey=null;
let revision=-1,clockOffset=0,busy=false,online=false,lastContact=0;
let channel=null,realtimeReady=false,refreshing=null,refreshAgain=false,pending=null;
const db=window.supabase.createClient(KANBAN_CONFIG.url,KANBAN_CONFIG.publishableKey,{
  auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false},
  global:{fetch:(url,options)=>fetch(url,{...options,signal:AbortSignal.timeout(12000)})}
});
const el=id=>document.getElementById(id);
const escapeHTML=value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function message(text=''){el('messages').textContent=text;}
function status(){
  const label=role==='instructor'?'Instructor':'Station';
  el('connection').textContent=!room?'Choose or create a training room.':!online?
    'CONNECTION LOST — controls paused. Reconnecting…':
    `${realtimeReady?'LIVE':'CONNECTED · periodic sync'} — ${label} · ${busy?'Saving…':'shared production state'}`;
  el('connection').classList.toggle('disconnected',!!room&&!online);
}
function repaint(){if(state)render();status();}
function updateHash(){
  const p=new URLSearchParams({room,key,tab});
  window.history.replaceState(null,'','#'+p);
}
function makeLink(access,view){
  const url=new URL(location.href);url.search='';url.hash=new URLSearchParams({room,key:access,tab:view});return url.href;
}
function showLinks(){
  el('share').hidden=false;
  el('room-name').textContent='Room '+room.slice(0,8)+' · '+(role==='instructor'?'Instructor access':'Station access');
  el('access-note').textContent=role==='instructor'?
    'Bookmark this page for instructor access. Open the station links on your other devices.':
    'This device can complete station work. The instructor controls Start, Reset, the interruption and Restore.';
  const entries=role==='instructor'?[['Instructor',key,'Dashboard']]:[];
  for(const view of TABS.filter(t=>t!=='Dashboard'))entries.push([view,stationKey,view]);
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
  clockOffset=data.serverTime-((sentAt+lastContact)/2);
  if(data.revision>=revision){state=data.state;revision=data.revision;}
  const first=role===null;role=data.role;stationKey=data.stationKey;
  if(first){el('setup').hidden=true;showLinks();subscribe();}
  repaint();
}
async function rpc(name,args){
  const {data,error}=await db.rpc(name,args);
  if(error){const e=new Error(error.message);e.uncertain=!error.code||error.code==='PGRST000';throw e;}
  return data;
}
async function refresh(){
  if(!room)return;
  if(refreshing){refreshAgain=true;return refreshing;}
  refreshing=(async()=>{
    try{const sent=Date.now();const data=await rpc('kanban_room_action',{p_room:room,p_key:key});applySnapshot(data,sent);}
    catch(e){online=false;repaint();if(!state)message('Unable to join this room. Check the link and internet connection. '+e.message);}
    finally{refreshing=null;}
  })();
  await refreshing;
  if(refreshAgain){refreshAgain=false;setTimeout(refresh,100);}
}
function subscribe(){
  channel=db.channel('kanban:'+stationKey)
    .on('broadcast',{event:'changed'},()=>refresh())
    .subscribe(s=>{realtimeReady=s==='SUBSCRIBED';status();if(realtimeReady)refresh();});
}
async function join(params){
  if(!UUID.test(params.get('room')||'')||!UUID.test(params.get('key')||''))throw new Error('The room link is incomplete.');
  room=params.get('room');key=params.get('key');
  tab=TABS.includes(params.get('tab'))?params.get('tab'):'Dashboard';
  updateHash();status();await refresh();
}
function queue11(){return state.orders.filter(o=>o.status==='released');}
function queueK(cell){return state.kanbans.filter(k=>k.cell===cell&&k.status==='open');}
function countdown(){
  if(!online)return 'Waiting for connection';
  if(state.start===null)return 'STOPPED — waiting for instructor to start';
  if(state.attack)return 'Production clock paused';
  if(state.released===5)return 'All batches released';
  const ms=Math.max(0,state.released*480000-(Date.now()+clockOffset-state.start-state.paused));
  return 'Next batch in '+String(Math.floor(ms/60000)).padStart(2,'0')+':'+String(Math.floor(ms%60000/1000)).padStart(2,'0');
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
el('create-room').addEventListener('click',async()=>{
  el('create-room').disabled=true;message();
  const button=el('create-room');
  // Keep the same keys on retry: a lost response must not create another room.
  if(!button.roomKeys)button.roomKeys={p_room:crypto.randomUUID(),p_instructor:crypto.randomUUID(),p_station:crypto.randomUUID()};
  try{
    const keys=button.roomKeys;
    await rpc('kanban_create_room',keys);
    await join(new URLSearchParams({room:keys.p_room,key:keys.p_instructor,tab:'Dashboard'}));
    el('share').open=true;
  }catch(e){message('Could not create the room. '+e.message);}
  finally{el('create-room').disabled=false;}
});
el('join-room').addEventListener('submit',async e=>{
  e.preventDefault();message();
  try{const url=new URL(el('room-link').value);const p=new URLSearchParams(url.hash.slice(1));
    if(!UUID.test(p.get('room')||'')||!UUID.test(p.get('key')||''))throw new Error('Paste a complete room link.');
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
  if(room&&Date.now()-lastContact>6000){online=false;repaint();}
  if(pending&&!busy){await sendPending();return;}
  await refresh();
},2000);
setInterval(()=>{const timer=el('timer');if(timer&&state)timer.textContent=countdown();},250);
document.addEventListener('DOMContentLoaded',()=>{
  if(location.hash)join(new URLSearchParams(location.hash.slice(1))).catch(e=>message(e.message));
});
