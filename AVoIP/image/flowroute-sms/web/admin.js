'use strict';
const $=id=>document.getElementById(id);
const state={tab:'sms',sms:[],catalog:{providers:[],dids:[],extensions:[],version:0},audit:[],info:{}};
const node=(tag,cls='',text='')=>{const item=document.createElement(tag);item.className=cls;item.textContent=text;return item};
function notice(text){$('snackbar').textContent=text;$('snackbar').classList.add('visible');setTimeout(()=>$('snackbar').classList.remove('visible'),5000)}
async function api(path,method='GET',body){const response=await fetch(path,{method,cache:'no-store',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined});if(!response.ok)throw Error((await response.text()).trim()||'Request failed');return response.status===204?null:response.json()}
async function load(){try{[state.sms,state.catalog,state.audit,state.info]=await Promise.all([api('/api/providers'),api('/api/sip'),api('/api/audit'),api('/api/admin')]);render()}catch(error){notice(error.message)}}
const fields={
 sms:[['id','Provider ID'],['name','Display name'],['type','Provider','select',['flowroute','twilio','telnyx']],['numbers','SMS numbers (one per line)','area'],['key_env','Access key credential reference'],['secret_env','Secret credential reference'],['public_key_env','Telnyx verification key reference'],['webhook_url','Inbound webhook URL'],['enabled','Enabled','checkbox']],
 providers:[['id','Provider ID'],['name','Display name'],['host','Provider SIP hostname'],['egress_prefix','Dialed-number egress prefix (digits; sent as prefix*destination)'],['supported_codecs','Codecs supported by this upstream provider (one per line: OPUS, G722, PCMU, PCMA)','area'],['codec_order','Preferred upstream codec order (subset of supported codecs; one per line)','area'],['cidrs','Allowed signaling networks (one CIDR per line)','area'],['yvr_gateway','YVR FreeSWITCH gateway'],['yxl_gateway','YXL FreeSWITCH gateway'],['verified','Verified caller IDs: number | verification evidence | expiry (optional)','area']],
 dids:[['number','DID'],['allowed_providers','Allowed inbound provider IDs (one per line)','area'],['site','Destination site','select',['yvr','yxl']],['kind','Destination type','select',['ivr','extension','did','sip']],['destination','Destination extension, DID or SIPS address (leave empty for IVR)'],['fax_detection_enabled','Detect fax after answer','checkbox'],['outbound_provider','Outbound provider for DID forwarding'],['caller_id','Verified caller ID for DID forwarding'],['codec_order','DID-specific codec order override (one per line; leave empty to inherit provider order)','area']],
 extensions:[['extension','Extension number'],['display_name','Display name'],['assigned_user','Assigned Authentik user ID or username (optional)'],['enabled','Extension enabled','checkbox'],['outbound_enabled','Outbound calling enabled','checkbox'],['authorized_caller_ids','Authorized verified caller IDs, in preference order (one E.164 number per line)','area'],['authorized_providers','Authorized upstream providers, in preference order (one provider ID per line)','area'],['site','Outbound egress site','select',['yvr','yxl']],['allowed_destinations','Allowed exact E.164 destinations (one per line; empty uses the platform NANP policy)','area'],['blocked_destinations','Blocked exact E.164 destinations (one per line)','area']]
};
function rowsFor(tab){return tab==='sms'?state.sms:tab==='audit'?state.audit:state.catalog[tab]||[]}
function recordText(tab,record){return tab==='sms'?`${record.id} ${record.name} ${record.type} ${(record.numbers||[]).join(' ')}`:tab==='providers'?`${record.id} ${record.name} ${record.host} ${(record.cidrs||[]).join(' ')}`:tab==='dids'?`${record.number} ${record.site} ${record.kind} ${record.destination} ${(record.allowed_providers||[]).join(' ')}`:tab==='extensions'?`${record.extension} ${record.display_name||''} ${record.assigned_user||''} ${record.site} ${(record.authorized_providers||[record.provider]).join(' ')} ${(record.authorized_caller_ids||[record.caller_id]).join(' ')} ${(record.allowed_destinations||[]).join(' ')} ${(record.blocked_destinations||[]).join(' ')}`:`${record.actor} ${record.action} ${record.object_id}`}
function extensionReadiness(record){
 const problems=[];
 const providers=record.authorized_providers||[record.provider].filter(Boolean);
 const callerIDs=record.authorized_caller_ids||[record.caller_id].filter(Boolean);
 const enabled=record.enabled!==false,outbound=record.outbound_enabled!==false;
 if(!enabled)problems.push('Extension is disabled');
 if(enabled&&!outbound)problems.push('Outbound calling is disabled');
 if(!providers.length)problems.push('No upstream provider is authorized');
 if(!callerIDs.length)problems.push('No caller ID is authorized');
 const eligible=providers.filter(id=>{const provider=state.catalog.providers.find(item=>item.id===id);return provider?.gateways?.[record.site]&&callerIDs.some(number=>provider.verified_caller_ids?.some(item=>item.number===number&&(!item.expires_at||Date.parse(item.expires_at)>Date.now()))) });
 if(!eligible.length)problems.push('No authorized provider has a site gateway and current verification for an authorized caller ID');
 return problems;
}
function addRoutePreview(card,record){
 const form=node('form','route-preview');
 const destination=node('input');destination.type='tel';destination.inputMode='tel';destination.required=true;destination.placeholder='+1…';destination.setAttribute('aria-label',`Destination for extension ${record.extension}`);
 const callerID=node('input');callerID.type='tel';callerID.inputMode='tel';callerID.value=(record.authorized_caller_ids||[record.caller_id]).filter(Boolean)[0]||'';callerID.setAttribute('aria-label',`Caller ID for extension ${record.extension}`);
 const submit=node('button','text-button','Preview route');submit.type='submit';
 const result=node('p','route-preview-result','Preview uses the current Admin policy. Provider health is not checked.');result.setAttribute('role','status');
 form.append(destination,callerID,submit);form.onsubmit=async event=>{event.preventDefault();submit.disabled=true;result.textContent='Checking route…';try{const preview=await api('/api/routing/preview','POST',{extension:record.extension,destination:destination.value.trim(),caller_id:callerID.value.trim(),site:record.site});if(preview.allowed){const codecs=preview.codec_order?.length?` · Codecs ${preview.codec_order.join(' → ')}`:'';const egress=preview.egress_destination?` · Sent as ${preview.egress_destination}`:'';result.textContent=`Allowed · ${preview.normalized_destination} · Caller ID ${preview.normalized_caller_id} · ${preview.selected_provider}${egress}${codecs} · Revision ${preview.policy_revision} · Provider health ${preview.provider_health}`}else result.textContent=`Denied · ${preview.denial_reason||'policy_denied'} · Revision ${preview.policy_revision}`}catch(error){result.textContent=error.message}finally{submit.disabled=false}};
 card.append(form,result);
}
function addInboundRoutePreview(card,record){
 const form=node('form','route-preview');
 const provider=node('select');provider.required=true;provider.setAttribute('aria-label',`Inbound provider for DID ${record.number}`);
 const placeholder=node('option','','Select inbound provider');placeholder.value='';placeholder.disabled=true;placeholder.selected=true;provider.append(placeholder);
 for(const item of state.catalog.providers){const assigned=(record.allowed_providers||[]).includes(item.id);const option=node('option','',`${item.name||item.id}${assigned?'':' · not assigned to this DID'}`);option.value=item.id;provider.append(option)}
 if(record.allowed_providers?.length)provider.value=record.allowed_providers[0];
 const source=node('input');source.placeholder='Optional source IP';source.setAttribute('aria-label',`Optional source IP for DID ${record.number}`);source.inputMode='text';
 const submit=node('button','text-button','Preview inbound route');submit.type='submit';
 const result=node('p','route-preview-result','Preview uses the current Admin policy and does not place a call. Provider health is not checked.');result.setAttribute('role','status');
 form.append(provider,source,submit);form.onsubmit=async event=>{event.preventDefault();submit.disabled=true;result.textContent='Checking inbound route…';try{const preview=await api('/api/routing/inbound-preview','POST',{did:record.number,inbound_provider:provider.value,site:record.site,...(source.value.trim()?{source_ip:source.value.trim()}:{})});if(preview.allowed){const destination=preview.destination?` ${preview.destination}`:'';result.textContent=`Allowed · ${preview.normalized_did} · ${preview.inbound_provider} · Route ${preview.destination_kind}${destination} · Revision ${preview.policy_revision} · Provider health ${preview.provider_health}`}else result.textContent=`Denied · ${preview.denial_reason||'policy_denied'} · Revision ${preview.policy_revision}`}catch(error){result.textContent=error.message}finally{submit.disabled=false}};
 card.append(form,result);
}
function render(){
 const tab=state.tab,root=$('records'),query=$('record-search').value.trim().toLowerCase();
 $('routing-mode').textContent=state.info.routing_enabled?(state.info.snapshot_ready?'Routing enabled':'Routing snapshot unavailable'):'Routing not activated';
 $('active-site').textContent=state.info.site?`Active site: ${state.info.site.toUpperCase()}`:'Active site unavailable';
 $('section-title').textContent={sms:'SMS providers',providers:'SIP providers',dids:'DID routing',extensions:'Extensions',audit:'Activity'}[tab];
 $('add-record').hidden=tab==='audit'||(tab!=='sms'&&state.catalog.source==='config');
 $('add-record').textContent=tab==='providers'||tab==='sms'?'Add provider':tab==='dids'?'Add DID':tab==='extensions'?'Add extension':'Add assignment';
 $('search-label').hidden=tab==='audit';
 $('admin-help').textContent=tab==='sms'?'Credentials stay in the platform secret store. Configuration-managed accounts are read only.':state.catalog.source==='config'?'Routing is managed by configuration. Change the configured catalog to update these records.':tab==='providers'?'Verify number ownership before approving caller IDs. Declare the codecs supported by the carrier, then set an optional ordered preference from that list. A digits-only egress prefix is applied by Kamailio after authorization. Gateways must be provisioned in FreeSWITCH.':tab==='extensions'?'Manage extension outbound authorization, user assignment and exact E.164 destination restrictions. Disabled extensions or outbound permission are rejected by Kamailio. Registration status and failures are available in Homer; this page does not change SIP passwords or endpoint credentials.':tab==='dids'?'Allow specific upstream providers and choose a destination. An optional DID codec order overrides provider preferences and must be supported by each authorized provider. Routing changes require the managed routing integration to be enabled.':'Recent administrative changes.';
 root.replaceChildren();
 const rows=rowsFor(tab).map((record,index)=>({record,index})).filter(({record})=>!query||recordText(tab,record).toLowerCase().includes(query));
 if(!rows.length)root.append(node('p','empty',query?'No matching records.':'No records yet.'));
 for(const {record,index} of rows){
  const card=node('article','admin-card'),title=tab==='extensions'?(record.display_name||`Extension ${record.extension}`):(record.name||record.number||record.extension||record.action);
  card.append(node('h3','',title));
  let summary='';
  if(tab==='sms')summary=`${record.type} · ${record.enabled?'Enabled':'Disabled'} · ${record.can_send?'Sending ready':'Credentials not ready'}`;
  else if(tab==='providers')summary=`${record.host} · ${(record.cidrs||[]).length} signaling networks · ${Object.keys(record.gateways||{}).length} site gateways · ${record.egress_prefix?`prefix ${record.egress_prefix}`:'no egress prefix'} · ${(record.codec_order||[]).length?`codecs ${(record.codec_order||[]).join(' → ')}`:(record.supported_codecs||[]).length?`supported ${(record.supported_codecs||[]).join(', ')}`:'no codec restriction'}`;
  else if(tab==='dids')summary=`${record.site.toUpperCase()} · ${record.kind} · ${record.destination||'Existing IVR'} · ${(record.codec_order||[]).length?`codecs ${(record.codec_order||[]).join(' → ')}`:'inherits provider codec order'}`;
  else if(tab==='extensions')summary=`${record.extension} · ${record.enabled===false?'Disabled':'Enabled'} · Outbound ${record.outbound_enabled===false?'disabled':'enabled'}`;
  else summary=`${record.actor} · ${new Date(record.at).toLocaleString()}`;
  card.append(node('p','',summary));
  if(tab==='extensions'){
   const callerIDs=record.authorized_caller_ids||[record.caller_id].filter(Boolean),providers=record.authorized_providers||[record.provider].filter(Boolean);
   card.append(node('p','',`Caller IDs ${callerIDs.join(', ')||'none'} · Providers ${providers.join(' → ')||'none'} · Egress ${String(record.site||'unknown').toUpperCase()}${record.assigned_user?` · Assigned user ${record.assigned_user}`:''}`));
   if(record.allowed_destinations?.length)card.append(node('p','','Allowed destinations: '+record.allowed_destinations.join(', ')));
   if(record.blocked_destinations?.length)card.append(node('p','','Blocked destinations: '+record.blocked_destinations.join(', ')));
   const problems=extensionReadiness(record);
   card.append(node('p',problems.length?'extension-readiness warning':'extension-readiness',problems.length?`Configuration needs attention: ${problems.join('; ')}`:'Catalog authorization is configured. Live provider availability and registration are reported by SIP runtime events.'));
   addRoutePreview(card,record);
  }
  if(tab==='dids')addInboundRoutePreview(card,record);
  if(record.numbers?.length)card.append(node('p','',record.numbers.join(', ')));
  if((tab==='sms'&&record.source!=='admin')||(tab!=='sms'&&state.catalog.source==='config'))card.append(node('small','',`Managed by ${record.source||'configuration'}`));
  else if(tab!=='audit'){const actions=node('div','dialog-actions'),edit=node('button','text-button','Edit'),remove=node('button','text-button danger','Delete');edit.onclick=()=>editRecord(record,index);remove.onclick=()=>removeRecord(record,index);actions.append(edit,remove);card.append(actions)}
  root.append(card);
 }
 document.querySelectorAll('[data-tab]').forEach(item=>item.setAttribute('aria-selected',String(item.dataset.tab===tab)));
}
function editRecord(record={},index=-1){
 const tab=state.tab,values={...record},root=$('edit-fields');
 if(tab==='extensions'){values.authorized_caller_ids=record.authorized_caller_ids||[record.caller_id].filter(Boolean);values.authorized_providers=record.authorized_providers||[record.provider].filter(Boolean)}
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
    if(tab==='providers'){result.cidrs=lines(result.cidrs);result.supported_codecs=lines(result.supported_codecs).map(value=>value.toUpperCase());result.codec_order=lines(result.codec_order).map(value=>value.toUpperCase());result.gateways={};if(result.yvr_gateway)result.gateways.yvr=result.yvr_gateway;if(result.yxl_gateway)result.gateways.yxl=result.yxl_gateway;result.verified_caller_ids=lines(result.verified).map(line=>{const [number,evidence,expiry]=line.split('|').map(x=>x.trim());return {number,evidence,...(expiry?{expires_at:new Date(expiry).toISOString()}:{})}});delete result.yvr_gateway;delete result.yxl_gateway;delete result.verified}
    if(tab==='dids'){result.allowed_providers=lines(result.allowed_providers);result.codec_order=lines(result.codec_order).map(value=>value.toUpperCase())}
    if(tab==='extensions'){result.allowed_destinations=lines(result.allowed_destinations);result.blocked_destinations=lines(result.blocked_destinations);result.authorized_caller_ids=lines(result.authorized_caller_ids);result.authorized_providers=lines(result.authorized_providers)}
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
