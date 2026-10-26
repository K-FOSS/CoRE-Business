'use strict';

function esimData(result) {
 return Array.isArray(result?.data) ? result.data : result?.data ? [result.data] : [];
}
function esimStatus(record) {
 const status=record?.status;
 if(typeof status==='string')return status;
 if(status&&typeof status==='object')return status.value||status.name||status.status||'unknown';
 return record?.esim_installation_status||'unknown';
}
function esimText(record) {
 return [record.id,record.iccid,record.imsi,record.msisdn,record.eid,esimStatus(record),(record.tags||[]).join(' ')].filter(Boolean).join(' ').toLowerCase();
}
function renderESIMs() {
 const root=$('records'),query=$('record-search').value.trim().toLowerCase(),records=(state.esims||[]).filter(record=>!query||esimText(record).includes(query));
 $('section-title').textContent='Telnyx eSIMs';
 $('admin-help').textContent='Manage Telnyx eSIM profiles. Purchases and lifecycle changes use the server-side Telnyx admin API key.';
 $('add-record').hidden=false;$('add-record').textContent='Purchase eSIMs';$('search-label').hidden=false;root.replaceChildren();
 if(!records.length)root.append(node('p','empty',query?'No matching eSIMs.':'No eSIMs returned by Telnyx.'));
 for(const record of records){
  const card=node('article','admin-card'),status=esimStatus(record),head=node('div','service-card-head');
  head.append(node('h3','',record.iccid||record.id||'eSIM'),node('span',`status-pill ${['enabled','active','in-use'].includes(String(status).toLowerCase())?'online':'offline'}`,status));card.append(head);
  card.append(node('p','',`${record.type||'eSIM'} · ${record.id||'No ID'}`));
  card.append(node('p','muted',`IMSI ${record.imsi||'—'} · MSISDN ${record.msisdn||'—'} · EID ${record.eid||'—'}`));
  if(record.sim_card_group_id)card.append(node('p','muted',`Group ${record.sim_card_group_id}`));
  if(record.tags?.length)card.append(node('p','muted',`Tags ${record.tags.join(', ')}`));
  const actions=node('div','dialog-actions');
  const code=node('button','text-button','Show activation code');code.type='button';code.onclick=()=>showESIMActivation(record.id);actions.append(code);
  for(const [action,label] of [['enable','Enable'],['disable','Disable'],['set_standby','Standby']]){const button=node('button',`text-button ${action==='disable'?'danger':''}`,label);button.type='button';button.onclick=()=>changeESIMState(record,action);actions.append(button)}
  card.append(actions);root.append(card);
 }
}
async function loadESIMs(){
 $('records').replaceChildren(node('p','muted','Loading Telnyx eSIMs…'));
 try{state.esims=esimData(await api('/api/esims'));renderESIMs()}catch(error){$('records').replaceChildren(node('p','admin-error',error.message))}
}
async function changeESIMState(record,action){
 if(!await confirmDelete(`${action==='disable'?'Disable':action==='set_standby'?'Put in standby':'Enable'} eSIM ${record.iccid||record.id}? Telnyx processes this asynchronously.`))return;
 try{await api(`/api/esims/${encodeURIComponent(record.id)}/actions/${action}`,'POST');notice('Telnyx eSIM action submitted.');await loadESIMs()}catch(error){notice(error.message)}
}
async function showESIMActivation(id){
 try{const result=await api(`/api/esims/${encodeURIComponent(id)}/activation-code`),data=result?.data||result,dialog=document.createElement('dialog');dialog.className='esim-dialog';const form=document.createElement('form');form.method='dialog';const title=node('h2','','eSIM activation details'),help=node('p','muted','Treat this activation data as sensitive. It is shown only to the authenticated Admin.');const pre=node('pre','esim-code',JSON.stringify(data,null,2));const actions=node('div','dialog-actions'),copy=node('button','dialog-primary','Copy JSON');copy.type='button';copy.onclick=()=>navigator.clipboard?.writeText(JSON.stringify(data,null,2)).then(()=>notice('Activation data copied.'));const close=node('button','','Close');close.value='close';actions.append(copy,close);form.append(title,help,pre,actions);dialog.append(form);document.body.append(dialog);dialog.addEventListener('close',()=>dialog.remove(),{once:true});dialog.showModal()}catch(error){notice(error.message)}
}
function purchaseESIMs(){
 const root=$('edit-fields');root.replaceChildren();$('edit-error').textContent='';$('edit-title').textContent='Purchase Telnyx eSIMs';
 const field=(key,label,type='text',value='')=>{const wrap=node('label','admin-field',label),input=node('input');input.name=key;input.id=`field-${key}`;input.type=type;input.value=value;wrap.append(input);root.append(wrap);return input};
 field('amount','Quantity','number','1');field('sim_card_group_id','SIM card group ID');field('whitelabel_name','White-label name');field('tags','Tags (one per line)','text');
 const status=node('label','admin-field','Initial status'),select=node('select');select.id='field-status';for(const value of ['standby','enabled','disabled']){const option=node('option','',value);option.value=value;select.append(option)}status.append(select);root.append(status);
 $('edit-form').onsubmit=async event=>{event.preventDefault();const amount=Number($('field-amount').value),body={amount,status:select.value};const group=$('field-sim_card_group_id').value.trim(),brand=$('field-whitelabel_name').value.trim(),tags=$('field-tags').value.split('\n').map(item=>item.trim()).filter(Boolean);if(group)body.sim_card_group_id=group;if(brand){body.product='whitelabel';body.whitelabel_name=brand}if(tags.length)body.tags=tags;try{await api('/api/esims/purchase','POST',body);$('edit-record').close();notice('Telnyx eSIM purchase submitted.');await loadESIMs()}catch(error){$('edit-error').textContent=error.message}};$('edit-record').showModal();root.querySelector('input')?.focus();
}
function installESimsTab(){
 const before=document.querySelector('[data-tab="telephony"]');if(!before||document.querySelector('[data-tab="esims"]'))return;const tab=node('button','', 'eSIMs');tab.dataset.tab='esims';tab.type='button';tab.onclick=()=>{state.tab='esims';document.querySelectorAll('[data-tab]').forEach(item=>item.setAttribute('aria-selected',String(item===tab)));$('add-record').onclick=purchaseESIMs;$('record-search').oninput=renderESIMs;loadESIMs()};before.parentNode.insertBefore(tab,before);
}
