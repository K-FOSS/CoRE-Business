'use strict';
const $=id=>document.getElementById(id);
const state={tab:'sms',sms:[],catalog:{providers:[],dids:[],extensions:[],version:0},audit:[],info:{}};
const node=(tag,cls='',text='')=>{const item=document.createElement(tag);item.className=cls;item.textContent=text;return item};
function notice(text){$('snackbar').textContent=text;$('snackbar').classList.add('visible');setTimeout(()=>$('snackbar').classList.remove('visible'),5000)}
async function api(path,method='GET',body){const response=await fetch(path,{method,cache:'no-store',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined});if(!response.ok)throw Error((await response.text()).trim()||'Request failed');return response.status===204?null:response.json()}
async function load(){try{[state.sms,state.catalog,state.audit,state.info]=await Promise.all([api('/api/providers'),api('/api/sip'),api('/api/audit'),api('/api/admin')]);render()}catch(error){notice(error.message)}}
const fields={
 sms:[['id','Provider ID'],['name','Display name'],['type','Provider','select',['flowroute','twilio','telnyx']],['numbers','SMS numbers (one per line)','area'],['key_env','Access key credential reference'],['secret_env','Secret credential reference'],['public_key_env','Telnyx verification key reference'],['webhook_url','Inbound webhook URL'],['enabled','Enabled','checkbox']],
 providers:[['id','Provider ID'],['name','Display name'],['host','Provider SIP hostname'],['cidrs','Allowed signaling networks (one CIDR per line)','area'],['yvr_gateway','YVR FreeSWITCH gateway'],['yxl_gateway','YXL FreeSWITCH gateway'],['verified','Verified caller IDs: number | verification evidence | expiry (optional)','area']],
 dids:[['number','DID'],['allowed_providers','Allowed inbound provider IDs (one per line)','area'],['site','Destination site','select',['yvr','yxl']],['kind','Destination type','select',['ivr','extension','did','sip']],['destination','Destination extension, DID or SIPS address (leave empty for IVR)'],['fax_detection_enabled','Detect fax after answer','checkbox'],['outbound_provider','Outbound provider for DID forwarding'],['caller_id','Verified caller ID for DID forwarding']],
 extensions:[['extension','Extension number'],['display_name','Display name'],['enabled','Extension enabled','checkbox'],['outbound_enabled','Outbound calling enabled','checkbox'],['caller_id','Authorized verified caller ID'],['provider','Authorized upstream provider ID'],['site','Outbound egress site','select',['yvr','yxl']]]
};
function rowsFor(tab){return tab==='sms'?state.sms:tab==='audit'?state.audit:state.catalog[tab]||[]}
function recordText(tab,record){return tab==='sms'?`${record.id} ${record.name} ${record.type} ${(record.numbers||[]).join(' ')}`:tab==='providers'?`${record.id} ${record.name} ${record.host} ${(record.cidrs||[]).join(' ')}`:tab==='dids'?`${record.number} ${record.site} ${record.kind} ${record.destination} ${(record.allowed_providers||[]).join(' ')}`:tab==='extensions'?`${record.extension} ${record.display_name||''} ${record.site} ${record.provider} ${record.caller_id}`:`${record.actor} ${record.action} ${record.object_id}`}
function render(){
 const tab=state.tab,root=$('records'),query=$('record-search').value.trim().toLowerCase();
 $('routing-mode').textContent=state.info.routing_enabled?(state.info.snapshot_ready?'Routing enabled':'Routing snapshot unavailable'):'Routing not activated';
 $('active-site').textContent=state.info.site?`Active site: ${state.info.site.toUpperCase()}`:'Active site unavailable';
 $('section-title').textContent={sms:'SMS providers',providers:'SIP providers',dids:'DID routing',extensions:'Extensions',audit:'Activity'}[tab];
 $('add-record').hidden=tab==='audit'||(tab!=='sms'&&state.catalog.source==='config');
 $('add-record').textContent=tab==='providers'||tab==='sms'?'Add provider':tab==='dids'?'Add DID':tab==='extensions'?'Add extension':'Add assignment';
 $('search-label').hidden=tab==='audit';
 $('admin-help').textContent=tab==='sms'?'Credentials stay in the platform secret store. Configuration-managed accounts are read only.':state.catalog.source==='config'?'Routing is managed by configuration. Change the configured catalog to update these records.':tab==='providers'?'Verify number ownership with the provider before approving caller IDs. Gateways must be provisioned in FreeSWITCH.':tab==='extensions'?'Manage extension outbound authorization. Disabled extensions or outbound permission are omitted from the routing snapshot and rejected by Kamailio. Registration status and failures are available in Homer; this page does not change SIP passwords or endpoint credentials.':tab==='dids'?'Allow specific upstream providers and choose a destination. Routing changes require the managed routing integration to be enabled.':'Recent administrative changes.';
 root.replaceChildren();
 const rows=rowsFor(tab).map((record,index)=>({record,index})).filter(({record})=>!query||recordText(tab,record).toLowerCase().includes(query));
 if(!rows.length)root.append(node('p','empty',query?'No matching records.':'No records yet.'));
 for(const {record,index} of rows){
  const card=node('article','admin-card'),title=tab==='extensions'?(record.display_name||`Extension ${record.extension}`):(record.name||record.number||record.extension||record.action);
  card.append(node('h3','',title));
  let summary='';
  if(tab==='sms')summary=`${record.type} · ${record.enabled?'Enabled':'Disabled'} · ${record.can_send?'Sending ready':'Credentials not ready'}`;
  else if(tab==='providers')summary=`${record.host} · ${(record.cidrs||[]).length} signaling networks · ${Object.keys(record.gateways||{}).length} site gateways`;
  else if(tab==='dids')summary=`${record.site.toUpperCase()} · ${record.kind} · ${record.destination||'Existing IVR'}`;
  else if(tab==='extensions')summary=`${record.extension} · ${record.enabled===false?'Disabled':'Enabled'} · Outbound ${record.outbound_enabled===false?'disabled':'enabled'}`;
  else summary=`${record.actor} · ${new Date(record.at).toLocaleString()}`;
  card.append(node('p','',summary));
  if(tab==='extensions')card.append(node('p','',`Caller ID ${record.caller_id} · Provider ${record.provider} · Egress ${record.site.toUpperCase()}`));
  if(record.numbers?.length)card.append(node('p','',record.numbers.join(', ')));
  if((tab==='sms'&&record.source!=='admin')||(tab!=='sms'&&state.catalog.source==='config'))card.append(node('small','',`Managed by ${record.source||'configuration'}`));
  else if(tab!=='audit'){const actions=node('div','dialog-actions'),edit=node('button','text-button','Edit'),remove=node('button','text-button danger','Delete');edit.onclick=()=>editRecord(record,index);remove.onclick=()=>removeRecord(record,index);actions.append(edit,remove);card.append(actions)}
  root.append(card);
 }
 document.querySelectorAll('[data-tab]').forEach(item=>item.setAttribute('aria-selected',String(item.dataset.tab===tab)));
}
function editRecord(record={},index=-1){
 const tab=state.tab,values={...record},root=$('edit-fields');
 if(tab==='providers'){values.yvr_gateway=record.gateways?.yvr||'';values.yxl_gateway=record.gateways?.yxl||'';values.verified=(record.verified_caller_ids||[]).map(v=>`${v.number} | ${v.evidence} | ${v.expires_at||''}`).join('\n')}
 root.replaceChildren();$('edit-error').textContent='';$('edit-title').textContent=`${index<0?'Add':'Edit'} ${tab==='extensions'?'extension':tab==='dids'?'DID':'record'}`;
 for(const [key,label,type,options] of fields[tab]){
  const wrapper=node('label','admin-field',label),input=node(type==='area'?'textarea':type==='select'?'select':'input');input.name=key;input.id=`field-${key}`;
  if(type==='select')for(const option of options){const choice=node('option','',option);choice.value=option;input.append(choice)}
  if(type==='checkbox'){input.type='checkbox';input.checked=key==='fax_detection_enabled'?values[key]!==false:key==='enabled'||key==='outbound_enabled'?values[key]!==false:!!values[key]}
  else input.value=Array.isArray(values[key])?values[key].join('\n'):values[key]||'';
  if(index>=0&&(key==='id'||key==='number'||key==='extension'))input.readOnly=true;
  wrapper.append(input);root.append(wrapper);
 }
 $('edit-form').onsubmit=async event=>{
  event.preventDefault();const result={};
  for(const [key,,type] of fields[tab]){const input=$(`field-${key}`);result[key]=type==='checkbox'?input.checked:input.value.trim()}
  const lines=value=>value.split('\n').map(x=>x.trim()).filter(Boolean);
  try{
   if(tab==='sms'){result.numbers=lines(result.numbers);result.version=record.version||0;await api(`/api/providers/${encodeURIComponent(result.id)}`,'PUT',result)}
   else{
    if(tab==='providers'){result.cidrs=lines(result.cidrs);result.gateways={};if(result.yvr_gateway)result.gateways.yvr=result.yvr_gateway;if(result.yxl_gateway)result.gateways.yxl=result.yxl_gateway;result.verified_caller_ids=lines(result.verified).map(line=>{const [number,evidence,expiry]=line.split('|').map(x=>x.trim());return {number,evidence,...(expiry?{expires_at:new Date(expiry).toISOString()}:{})}});delete result.yvr_gateway;delete result.yxl_gateway;delete result.verified}
    if(tab==='dids')result.allowed_providers=lines(result.allowed_providers);
    const catalog=structuredClone(state.catalog);if(index<0)catalog[tab].push(result);else catalog[tab][index]={...catalog[tab][index],...result};await api('/api/sip','PUT',catalog);
   }
   $('edit-record').close();notice(state.info.routing_enabled?'Saved. SIP replicas refresh the published authorization snapshot shortly.':'Saved. Managed SIP routing is not activated.');await load();
  }catch(error){$('edit-error').textContent=error.message}
 };
 $('edit-record').showModal();root.querySelector('input,select,textarea')?.focus();
}
async function removeRecord(record,index){if(!await confirmDelete('Delete this configuration record? Existing calls are not ended.'))return;try{if(state.tab==='sms')await api(`/api/providers/${encodeURIComponent(record.id)}`,'DELETE');else{const catalog=structuredClone(state.catalog);catalog[state.tab].splice(index,1);await api('/api/sip','PUT',catalog)}await load()}catch(error){notice(error.message)}}
function confirmDelete(description){return new Promise(resolve=>{const dialog=$('confirm-action');dialog.returnValue='cancel';$('confirm-description').textContent=description;dialog.onclose=()=>resolve(dialog.returnValue==='delete');dialog.showModal()})}
document.querySelectorAll('[data-tab]').forEach(item=>item.onclick=()=>{state.tab=item.dataset.tab;render()});
$('add-record').onclick=()=>editRecord();$('cancel-edit').onclick=()=>$('edit-record').close();$('record-search').oninput=render;load();
