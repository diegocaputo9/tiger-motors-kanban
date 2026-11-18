'use strict';
const DEFAULT_SCHEDULE={runMinutes:40,tCount:20,aCount:10,pattern:'TTATTA'};
const SHORT_SCHEDULE={runMinutes:20,tCount:11,aCount:4,pattern:'TTATTATTTATTATT'};
let scheduleDraft=null,scheduleGeneration=null;
const editedScheduleFields=new WeakSet();
function runPlan(minutes=40){
  return Number(minutes)===20?{runMinutes:20,totalOrders:15,batchSize:4,batchCount:4,intervalSeconds:300}:
    {runMinutes:40,totalOrders:30,batchSize:6,batchCount:5,intervalSeconds:480};
}
function currentPlan(){return state?.schedule||runPlan(state?.config?.runMinutes);}
function batchPreview(sequence,plan){return sequence.match(new RegExp('.{1,'+plan.batchSize+'}','g')).join(' · ');}
function savedSchedule(){
  if(state?.config)return {runMinutes:40,...state.config};
  const orders=state?.orders||[];
  if(orders.length!==30)return {...DEFAULT_SCHEDULE};
  const sequence=orders.map(o=>o.model).join('');
  const pattern=sequence.slice(0,6).repeat(5)===sequence?sequence.slice(0,6):sequence;
  const tCount=orders.filter(o=>o.model==='T').length;
  return {runMinutes:40,tCount,aCount:30-tCount,pattern};
}
function getScheduleDraft(){
  if(!scheduleDraft||scheduleGeneration!==state.generation){
    const c=savedSchedule();scheduleDraft={runMinutes:String(c.runMinutes),tCount:String(c.tCount),aCount:String(c.aCount),pattern:c.pattern};
    scheduleGeneration=state.generation;
  }
  return scheduleDraft;
}
function suggestedPattern(tCount,total=30,batchSize=6){
  const length=total%batchSize===0&&Number.isInteger(tCount*batchSize/total)?batchSize:total;
  const t=tCount*length/total;
  return Array.from({length},(_,i)=>Math.ceil((i+1)*t/length)>Math.ceil(i*t/length)?'T':'A').join('');
}
function checkSchedule(d=getScheduleDraft()){
  if(!['20','40'].includes(String(d.runMinutes)))return {field:'run-40',error:'Choose a 20-minute or 40-minute run.'};
  const plan=runPlan(d.runMinutes),total=plan.totalOrders;
  if(!/^\d+$/.test(d.tCount)||Number(d.tCount)>total)return {field:'mix-t-count',error:'Enter a whole-number Model T quantity from 0 to '+total+'.'};
  if(!/^\d+$/.test(d.aCount)||Number(d.aCount)>total)return {field:'mix-a-count',error:'Enter a whole-number Model A quantity from 0 to '+total+'.'};
  const tCount=Number(d.tCount),aCount=Number(d.aCount);
  if(tCount+aCount!==total)return {field:'mix-t-count',error:'Model T and Model A quantities must total '+total+'.'};
  const pattern=d.pattern.toUpperCase().replace(/\s/g,'');
  if(!new RegExp('^[TA]{1,'+total+'}$').test(pattern))return {field:'mix-pattern',error:'Enter 1 to '+total+' letters using only T and A.'};
  const sequence=pattern.repeat(total).slice(0,total);
  const actualT=[...sequence].filter(x=>x==='T').length;
  if(actualT!==tCount)return {field:'mix-pattern',error:'This pattern produces '+actualT+' T and '+(total-actualT)+' A. Change it to match your chosen mix.'};
  return {config:{runMinutes:plan.runMinutes,tCount,aCount,pattern},sequence,plan};
}
function scheduleIsDirty(){
  const result=checkSchedule(),saved=savedSchedule();
  return !result.config||Object.keys(result.config).some(k=>result.config[k]!==saved[k]);
}
function scheduleHelp(plan){return plan.runMinutes===20?
  '15 vehicles, in batches of 4, 4, 4 and 3 at minutes 0, 5, 10 and 15.':
  '30 vehicles, in five batches of six at minutes 0, 8, 16, 24 and 32.';}
function settingsPanel(){
  const d=getScheduleDraft(),result=checkSchedule(d),plan=runPlan(d.runMinutes),total=plan.totalOrders;
  const locked=state.start!==null||busy||!online;
  const preview=result.sequence?batchPreview(result.sequence,plan):'Preview appears when the mix and pattern agree.';
  return '<section class="panel schedule-panel"><form id="schedule-form" method="post" aria-labelledby="schedule-heading">'+
    '<fieldset '+(locked?'disabled':'')+'><legend id="schedule-heading">Production run &amp; demand mix</legend>'+
    '<fieldset class="run-options"><legend>Run length</legend>'+[40,20].map(m=>'<div class="run-choice"><input id="run-'+m+'" type="radio" name="runMinutes" value="'+m+'" '+(Number(d.runMinutes)===m?'checked ':'')+'required aria-describedby="run-help"><label for="run-'+m+'">'+m+' minutes'+(m===40?' · 30 orders (default)':' · 15 orders')+'</label></div>').join('')+'</fieldset>'+
    '<p id="run-help" class="small muted">Changing run length loads its default mix. You can then edit the quantities and pattern.</p>'+
    '<p id="mix-help" class="muted">'+scheduleHelp(plan)+' Changing a quantity suggests a matching pattern; you can edit it.</p>'+
    '<div class="schedule-fields">'+
    '<div><label for="mix-t-count">Model T quantity</label><input id="mix-t-count" name="tCount" type="number" min="0" max="'+total+'" step="1" inputmode="numeric" required aria-invalid="false" aria-describedby="mix-help" value="'+escapeHTML(d.tCount)+'"></div>'+
    '<div><label for="mix-a-count">Model A quantity</label><input id="mix-a-count" name="aCount" type="number" min="0" max="'+total+'" step="1" inputmode="numeric" required aria-invalid="false" aria-describedby="mix-help" value="'+escapeHTML(d.aCount)+'"></div>'+
    '<div class="pattern-field"><label for="mix-pattern">Repeating pattern</label><input id="mix-pattern" name="pattern" type="text" required maxlength="60" pattern="[TtAa\\s]+" autocapitalize="characters" autocorrect="off" spellcheck="false" aria-invalid="false" aria-describedby="pattern-help" value="'+escapeHTML(d.pattern)+'"></div></div>'+
    '<p id="pattern-help" class="small muted">Use T and A. The pattern repeats to fill '+total+' orders. You may also enter the full '+total+'-letter sequence.</p>'+
    '<p class="schedule-preview-label">Batch preview</p><output id="mix-preview" class="sequence-preview">'+escapeHTML(preview)+'</output>'+
    '<p id="mix-error" class="schedule-error" role="status" aria-live="polite"></p>'+
    '<div class="row"><button id="apply-schedule" type="submit" class="primary">APPLY SETTINGS</button><button id="schedule-defaults" type="button">USE '+(plan.runMinutes===20?'11T:4A':'20T:10A')+' DEFAULTS</button></div>'+
    '</fieldset><p class="small muted schedule-lock-note">'+(state.start!==null?'Reset Run to change the duration or mix. Saved settings stay selected between runs.':'Apply settings, or press Start Timed Run to apply them and start production.')+'</p></form></section>';
}
function clearScheduleErrors(){
  for(const id of ['run-40','run-20','mix-t-count','mix-a-count','mix-pattern']){
    const input=el(id);if(!input)continue;
    input.setCustomValidity('');input.setAttribute('aria-invalid','false');
    input.setAttribute('aria-describedby',id.startsWith('run-')?'run-help':id==='mix-pattern'?'pattern-help':'mix-help');
  }
  if(el('mix-error'))el('mix-error').textContent='';
}
function showScheduleError(result,focus=false){
  clearScheduleErrors();
  const input=el(result.field);if(!input)return;
  input.setCustomValidity(result.error);input.setAttribute('aria-invalid','true');
  input.setAttribute('aria-describedby',input.getAttribute('aria-describedby')+' mix-error');
  el('mix-error').textContent=result.error;
  if(focus){input.focus();input.reportValidity();}
}
function updateSchedulePreview(){
  const result=checkSchedule();
  if(el('mix-preview'))el('mix-preview').textContent=result.sequence?batchPreview(result.sequence,result.plan):'Preview appears when the mix and pattern agree.';
}
function useScheduleDefaults(minutes){
  const c=Number(minutes)===20?SHORT_SCHEDULE:DEFAULT_SCHEDULE;
  scheduleDraft={runMinutes:String(c.runMinutes),tCount:String(c.tCount),aCount:String(c.aCount),pattern:c.pattern};
  // Replace only the form's contents so the rest of the dashboard stays in place.
  el('schedule-form').innerHTML=new DOMParser().parseFromString(settingsPanel(),'text/html').getElementById('schedule-form').innerHTML;
  clearScheduleErrors();
}
document.addEventListener('change',e=>{
  if(e.target.name!=='runMinutes'||!e.target.closest('#schedule-form'))return;
  useScheduleDefaults(e.target.value);el('run-'+e.target.value).focus();
});
document.addEventListener('input',e=>{
  const names={'mix-t-count':'tCount','mix-a-count':'aCount','mix-pattern':'pattern'};
  const field=names[e.target.id];if(!field)return;
  const d=getScheduleDraft(),plan=runPlan(d.runMinutes),total=plan.totalOrders;
  d[field]=e.target.value;editedScheduleFields.add(e.target);clearScheduleErrors();
  if(field!=='pattern'&&/^\d+$/.test(e.target.value)&&Number(e.target.value)<=total){
    const n=Number(e.target.value),other=field==='tCount'?'aCount':'tCount';
    d[other]=String(total-n);d.pattern=suggestedPattern(Number(d.tCount),total,plan.batchSize);
    el(other==='tCount'?'mix-t-count':'mix-a-count').value=d[other];el('mix-pattern').value=d.pattern;
  }
  updateSchedulePreview();
});
document.addEventListener('focusout',e=>{
  if(!e.target.closest?.('#schedule-form')||!editedScheduleFields.has(e.target))return;
  const result=checkSchedule();if(result.error)showScheduleError(result);
});
document.addEventListener('invalid',e=>{
  if(!e.target.closest?.('#schedule-form'))return;
  e.target.setAttribute('aria-invalid','true');
  e.target.setAttribute('aria-describedby',(e.target.id==='mix-pattern'?'pattern-help':'mix-help')+' mix-error');
  el('mix-error').textContent=e.target.validationMessage;
},true);
document.addEventListener('submit',e=>{if(e.target.id==='schedule-form'){e.preventDefault();applySchedule();}});
document.addEventListener('click',e=>{if(e.target.id==='schedule-defaults')useScheduleDefaults(getScheduleDraft().runMinutes);});
async function applySchedule(){
  if(role!=='instructor'||state.start!==null||busy||!online)return false;
  const result=checkSchedule();
  if(result.error){showScheduleError(result,true);return false;}
  if(!el('schedule-form').reportValidity())return false;
  const ok=await command('configure',result.config);
  if(ok)message('Production duration, mix and pattern saved.');
  return ok;
}
