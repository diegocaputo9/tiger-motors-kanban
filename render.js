const MODELS={"11": {"A": "assets/model_a_image.png", "T": "assets/img_11_t.png"}, "6": {"A": "assets/img_6_a.png", "T": "assets/img_6_t.png"}, "1": {"A": "assets/img_1_a.png", "T": "assets/img_1_t.png"}};
function ransom(){return '<div class="attack"><div style="font-size:65px">🔒</div><h1>YOUR PRODUCTION SYSTEM IS LOCKED</h1><h2 style="color:#ff5368">RANSOMWARE INCIDENT — ACCESS DENIED</h2><div class="amount">$100,000 USD in Bitcoin</div><h2 style="color:#ff5368;margin-top:26px">You have 10 days or your system and history will be wiped clean.</h2></div>'}
function dashboard(){
  const plan=currentPlan();
  const t=state.orders.filter(o=>o.model==='T').length,a=state.orders.length-t;
  const spares=state.orders.filter(o=>o.spare).length;
  const controls='<section class="panel"><h2>Instructor dashboard</h2><p>'+plan.runMinutes+'-minute run · '+plan.totalOrders+' vehicles · '+t+' T / '+a+' A · '+spares+' Model T spare tire options · '+(plan.runMinutes===20?'4 / 4 / 4 / 3':'6')+' orders every '+plan.intervalSeconds+' seconds</p><div class="row">'+
    btn('START TIMED RUN','start()','primary',state.start!==null)+btn('TRIGGER RANSOMWARE','attack()','danger',state.attack||state.start===null)+
    btn('RESTORE PRODUCTION','restore()','success',!state.attack)+btn('RESET RUN','reset()')+
    '</div><p class="small muted">The ransomware display is a controlled simulation. It pauses the production clock and disables station transactions. The instructor can restore production from the dashboard.</p></section>';
  const metrics='<div class="grid">'+[['Batches released',state.released+'/'+plan.batchCount],['Vehicles processed',state.completed+'/'+plan.totalOrders],['Station 6 open',queueK(2).length],['Station 1 open',queueK(1).length],['Spare tires pending',state.spares.filter(x=>x.status==='open').length]].map(x=>'<div class="tile"><div>'+x[0]+'</div><div class="big">'+x[1]+'</div></div>').join('')+'</div>';
  return (state.attack?'<div class="incident" role="status"><b>SIMULATED RANSOMWARE ACTIVE</b> — All station work and the production clock are paused. Use Restore Production to resume.</div>':'')+
    controls+settingsPanel()+'<p class="startup-note">Stations 6 and 1 each begin with one Model T starter job. After those starters, further work follows pacemaker pulls.</p>'+metrics;
}
const IMAGE_SIZE={
  '11':{A:[704,609],T:[746,531]},
  '6':{A:[754,540],T:[754,464]},
  '1':{A:[582,409],T:[695,349]}
};
function workActions(action,enabled,remaining,label='Remaining in queue'){
  return '<footer class="work-actions"><p>'+label+': <strong>'+remaining+'</strong></p>'+
    btn(action==='completeSpare'?'COMPLETE SPARE / NEXT':'COMPLETE / NEXT',action+'()','primary huge next-action',!enabled)+
    '</footer>';
}
function station(n){
  const q=n==='11'?queue11():queueK(n==='6'?2:1),o=q[0];
  const name=n==='11'?'Pacemaker':n==='6'?'Cell 2 replenishment':'Cell 1 replenishment';
  let work;
  if(o){
    const [width,height]=IMAGE_SIZE[n][o.model];
    work='<div class="station-work"><div class="build-details">'+
      '<p class="muted">NEXT '+(n==='11'?'VEHICLE':'KANBAN')+'</p>'+
      '<div class="build-model">MODEL '+o.model+'</div><h3 class="build-id">'+o.id+'</h3>'+
      '<p class="build-option '+(n==='11'&&o.spare?'required':'')+'">'+
      (o.startup?'Initial Model T starter job':n==='11'&&o.spare?'SPARE TIRE REQUIRED':'Standard build')+'</p></div>'+
      '<figure class="build-preview"><img alt="Model '+o.model+' subassembly" src="'+MODELS[n][o.model]+
      '" width="'+width+'" height="'+height+'" decoding="async"></figure></div>';
  }else work='<div class="station-work empty-work"><div><h3>Ready for the next job</h3><p>'+
    (state.start===null?'Waiting for the instructor to start production':n==='11'?'Waiting for next scheduled batch':'Waiting for replenishment Kanban')+
    '</p></div></div>';
  return '<section class="panel station-panel"><h2>Station '+n+' — '+name+'</h2>'+work+
    workActions('complete'+n,!!o,q.length)+'</section>';
}
function heijunka(){
  const plan=currentPlan();
  return '<div class="panel"><h2>Heijunka schedule</h2><p>'+scheduleHelp(plan)+'</p>'+Array.from({length:plan.batchCount},(_,b)=>'<div class="batch"><b>Batch '+(b+1)+' — Minute '+(b*plan.intervalSeconds/60)+' — '+(b<state.released?'RELEASED':'WAITING')+'</b><div class="orders">'+state.orders.slice(b*plan.batchSize,(b+1)*plan.batchSize).map(o=>'<div class="order '+(o.model==='T'?'t':'')+'">'+o.id+'<br><b>Model '+o.model+'</b><br>'+(o.spare?'SPARE':'Standard')+'</div>').join('')+'</div></div>').join('')+'</div>';
}
function inventory(){return '<div class="panel"><h2>Supermarket inventory</h2><table><tr><th>Location</th><th>Model A</th><th>Model T</th></tr>'+['S1','S2'].map(s=>'<tr><td>'+s+'</td><td>'+state.inventory[s].A+'</td><td>'+state.inventory[s].T+'</td></tr>').join('')+'</table><p>Starting inventory: eight units per model in each supermarket (illustrative).</p></div>'}
function spare(){
  const q=state.spares.find(x=>x.status==='open');
  const work=q?'<div class="station-work"><div class="build-details"><p class="muted">NEXT SPARE TIRE</p><div class="build-model">SPARE TIRE</div>'+
    '<h3 class="build-id">'+q.id+'</h3><p class="build-option">Model T option order</p></div>'+
    '<figure class="build-preview"><img alt="Spare tire with black tread, blue rim and orange center" src="assets/spare-tire.png" width="1254" height="1254" decoding="async"></figure></div>':
    '<div class="station-work empty-work"><div><h3>Ready for the next spare</h3><p>Waiting for Model T option order</p></div></div>';
  return '<section class="panel station-panel"><h2>Spare Tire Station</h2>'+work+
    workActions('completeSpare',!!q,state.spares.filter(x=>x.status==='open').length,'Pending spares')+'</section>';
}
function eventHistory(){return '<div class="panel"><h2>Event history</h2><table><tr><th>Time</th><th>Event</th><th>Details</th></tr>'+state.events.map(e=>'<tr><td>'+e.time+'</td><td>'+e.type+'</td><td>'+e.details+'</td></tr>').join('')+'</table></div>'}
let renderedContent='',renderedTabs='',renderedScheduleState='';
function render(){
  if(!state)return;
  const isStation=['Station 11','Station 6','Station 1','Spare Tire'].includes(tab);
  document.body.classList.toggle('station-screen',isStation);
  document.getElementById('share').hidden=role!=='instructor'||isStation;
  const nav=document.getElementById('tabs');
  nav.hidden=role!=='instructor';
  const views=role==='instructor'?TABS:[allowedTab];
  const navHTML=views.filter(Boolean).map(t=>btn(t,'setTab('+JSON.stringify(t)+')',tab===t?'active':'')).join('');
  if(navHTML!==renderedTabs){nav.innerHTML=navHTML;renderedTabs=navHTML;}
  const scheduleState=JSON.stringify({state,tab,role,busy,online});
  if(tab==='Dashboard'&&document.getElementById('schedule-form')&&scheduleState===renderedScheduleState)return;
  let h;
  if(state.attack&&(tab!=='Dashboard'||role!=='instructor'))h=ransom();
  else if(tab==='Dashboard')h=dashboard();
  else if(tab==='Heijunka')h=heijunka();
  else if(tab.startsWith('Station '))h=station(tab.slice(8));
  else if(tab==='Spare Tire')h=spare();
  else if(tab==='Inventory')h=inventory();
  else h=eventHistory();
  // Leave an unchanged station's DOM and image intact during background checks.
  if(h!==renderedContent){document.getElementById('app').innerHTML=h;renderedContent=h;}
  renderedScheduleState=scheduleState;
}
function setTab(t){if(!TABS.includes(t)||(role!=='instructor'&&t!==allowedTab))return;tab=t;updateHash();render()}
