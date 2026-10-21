// Replace pasted public media URLs with authenticated uploads owned by the
// current user. The API converts those object IDs into short-lived provider
// URLs served by the dedicated media proxy.
const legacyMediaField = document.createElement('textarea');
legacyMediaField.id = 'media-urls';
legacyMediaField.hidden = true;
document.body.append(legacyMediaField);

const originalProviderUpdate = window.updateProviders;
window.updateProviders = function () {
  originalProviderUpdate();
  const selected = state.senders.find(sender => sender.number === $('number').value && sender.provider_id === ($('provider').value || sender.provider_id));
  $('media-label').hidden = selected?.provider_type !== 'twilio';
  $('media-files').hidden = selected?.provider_type !== 'twilio';
};

const originalComposer = $('composer').onsubmit;
$('composer').onsubmit = async event => {
  event.preventDefault();
  const files = [...$('media-files').files];
  if (!files.length) return originalComposer(event);
  const button = $('send');
  button.disabled = true;
  try {
    const mediaIds = [];
    for (const file of files) {
      const form = new FormData();
      form.append('file', file, file.name);
      const response = await fetch('/api/media', {method: 'POST', body: form});
      if (!response.ok) throw Error((await response.text()).trim() || 'Attachment upload failed');
      mediaIds.push((await response.json()).id);
    }
    const body = $('body').value;
    const candidates = state.senders.filter(sender => sender.number === $('number').value);
    const provider = candidates.length > 1 ? $('provider').value : candidates[0]?.provider_id;
    const response = await fetch('/api/messages', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({from: $('number').value, to: state.remote, body, provider_id: provider, media_ids: mediaIds})});
    if (!response.ok) throw Error((await response.text()).trim() || 'Send failed');
    $('body').value = '';
    $('media-files').value = '';
    notice('Message sent');
    await refresh();
    renderThread(true);
  } catch (error) {
    notice(error.message);
  } finally {
    button.disabled = !state.canSend;
  }
};
