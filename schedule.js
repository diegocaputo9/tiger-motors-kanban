'use strict';
const DEFAULT_SCHEDULE={tCount:20,aCount:10,pattern:'TTATTA'};
let scheduleDraft=null,scheduleGeneration=null;
const editedScheduleFields=new WeakSet();
function savedSchedule(){
  if(state?.config)return state.config;
  const orders=state?.orders||[];
  if(orders.length!==30)return {...DEFAULT_SCHEDULE};
  const sequence=orders.map(o=>o.model).join('');
  const pattern=sequence.slice(0,6).repeat(5)===sequence?sequence.slice(0,6):sequence;
  const tCount=orders.filter(o=>o.model==='T').length;
  return {tCount,aCount:30-tCount,pattern};
}
function getScheduleDraft(){
  if(!scheduleDraft||scheduleGeneration!==state.generation){
    const c=savedSchedule();scheduleDraft={tCount:String(c.tCount),aCount:String(c.aCount),pattern:c.pattern};
    scheduleGeneration=state.generation;
  }
  return scheduleDraft;
}
function suggestedPattern(tCount){
  const length=tCount%5===0?6:30;
  const t=tCount*length/30;
  return Array.from({length},(_,i)=>Math.ceil((i+1)*t/length)>Math.ceil(i*t/length)?'T':'A').join('');
}
function checkSchedule(d=getScheduleDraft()){
  if(!/^\d+$/.test(d.tCount)||Number(d.tCount)>30)return {field:'mix-t-count',error:'Enter a whole-number Model T quantity from 0 to 30.'};
  if(!/^\d+$/.test(d.aCount)||Number(d.aCount)>30)return {field:'mix-a-count',error:'Enter a whole-number Model A quantity from 0 to 30.'};
  const tCount=Number(d.tCount),aCount=Number(d.aCount);
  if(tCount+aCount!==30)return {field:'mix-t-count',error:'Model T and Model A quantities must total 30.'};
  const pattern=d.pattern.toUpperCase().replace(/\s/g,'');
  if(!/^[TA]{1,30}$/.test(pattern))return {field:'mix-pattern',error:'Enter 1 to 30 letters using only T and A.'};
  const sequence=pattern.repeat(30).slice(0,30);
  const actualT=[...sequence].filter(x=>x==='T').length;
  if(actualT!==tCount)return {field:'mix-pattern',error:'This pattern produces '+actualT+' T and '+(30-actualT)+' A. Change it to match your chosen mix.'};
  return {config:{tCount,aCount,pattern},sequence};
}
function scheduleIsDirty(){
  const result=checkSchedule(),saved=savedSchedule();
  return !result.config||result.config.tCount!==saved.tCount||result.config.aCount!==saved.aCount||result.config.pattern!==saved.pattern;
}
function settingsPanel(){
  const d=getScheduleDraft(),result=checkSchedule(d),locked=state.start!==null||busy||!online;
  const preview=result.sequence?result.sequence.match(/.{1,6}/g).join(' · '):'Preview appears when the mix and pattern agree.';
  return '<section class="panel schedule-panel"><form id="schedule-form" method="post" aria-labelledby="schedule-heading">'+
    '<fieldset '+(locked?'disabled':'')+'><legend id="schedule-heading">Production mix &amp; pattern</legend>'+
    '<p id="mix-help" class="muted">30 vehicles, in five batches of six. Changing a quantity suggests a matching pattern; you can edit it.</p>'+
    '<div class="schedule-fields">'+
    '<div><label for="mix-t-count">Model T quantity</label><input id="mix-t-count" name="tCount" type="number" min="0" max="30" step="1" inputmode="numeric" required aria-invalid="false" aria-describedby="mix-help" value="'+escapeHTML(d.tCount)+'"></div>'+
    '<div><label for="mix-a-count">Model A quantity</label><input id="mix-a-count" name="aCount" type="number" min="0" max="30" step="1" inputmode="numeric" required aria-invalid="false" aria-describedby="mix-help" value="'+escapeHTML(d.aCount)+'"></div>'+
    '<div class="pattern-field"><label for="mix-pattern">Repeating pattern</label><input id="mix-pattern" name="pattern" type="text" required maxlength="60" pattern="[TtAa\\s]+" autocapitalize="characters" autocorrect="off" spellcheck="false" aria-invalid="false" aria-describedby="pattern-help" value="'+escapeHTML(d.pattern)+'"></div></div>'+
    '<p id="pattern-help" class="small muted">Use T and A. The pattern repeats to fill 30 orders. You may also enter the full 30-letter sequence.</p>'+
    '<p class="schedule-preview-label">Batch preview</p><output id="mix-preview" class="sequence-preview">'+escapeHTML(preview)+'</output>'+
    '<p id="mix-error" class="schedule-error" role="status" aria-live="polite"></p>'+
    '<div class="row"><button id="apply-schedule" type="submit" class="primary">APPLY SETTINGS</button><button id="schedule-defaults" type="button">USE 20T:10A DEFAULTS</button></div>'+
    '</fieldset><p class="small muted schedule-lock-note">'+(state.start!==null?'Reset Run to change the mix. Saved settings stay selected between runs.':'Apply settings, or press Start Timed Run to apply them and start production.')+'</p></form></section>';
}
function clearScheduleErrors(){
  for(const id of ['mix-t-count','mix-a-count','mix-pattern']){
    const input=el(id);if(!input)continue;
    input.setCustomValidity('');input.setAttribute('aria-invalid','false');
    input.setAttribute('aria-describedby',id==='mix-pattern'?'pattern-help':'mix-help');
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
  if(el('mix-preview'))el('mix-preview').textContent=result.sequence?result.sequence.match(/.{1,6}/g).join(' · '):'Preview appears when the mix and pattern agree.';
}
document.addEventListener('input',e=>{
  const names={'mix-t-count':'tCount','mix-a-count':'aCount','mix-pattern':'pattern'};
  const field=names[e.target.id];if(!field)return;
  const d=getScheduleDraft();d[field]=e.target.value;editedScheduleFields.add(e.target);clearScheduleErrors();
  if(field!=='pattern'&&/^\d+$/.test(e.target.value)&&Number(e.target.value)<=30){
    const n=Number(e.target.value),other=field==='tCount'?'aCount':'tCount';
    d[other]=String(30-n);d.pattern=suggestedPattern(Number(d.tCount));
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
document.addEventListener('click',e=>{
  if(e.target.id!=='schedule-defaults')return;
  scheduleDraft={tCount:'20',aCount:'10',pattern:'TTATTA'};
  for(const [id,name] of [['mix-t-count','tCount'],['mix-a-count','aCount'],['mix-pattern','pattern']])el(id).value=scheduleDraft[name];
  clearScheduleErrors();updateSchedulePreview();
});
async function applySchedule(){
  if(role!=='instructor'||state.start!==null||busy||!online)return false;
  const result=checkSchedule();
  if(result.error){showScheduleError(result,true);return false;}
  if(!el('schedule-form').reportValidity())return false;
  const ok=await command('configure',result.config);
  if(ok)message('Production mix and pattern saved.');
  return ok;
}
