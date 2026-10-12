(() => {
  'use strict';

  const prefix = '__PATH__';
  const fileList = document.querySelector('#sound-list');
  const libraryStatus = document.querySelector('#library-status');
  const editorStatus = document.querySelector('#editor-status');
  const fileName = document.querySelector('#file-name');
  const canvas = document.querySelector('#waveform');
  const context = canvas.getContext('2d');
  const buttons = {
    record: document.querySelector('#record'),
    stopRecording: document.querySelector('#stop-recording'),
    play: document.querySelector('#play'),
    stopPlayback: document.querySelector('#stop-playback'),
    trim: document.querySelector('#trim'),
    save: document.querySelector('#save'),
  };

  let audioContext;
  let buffer;
  let selectionStart = 0;
  let selectionEnd = 0;
  let dragStart = null;
  let source;
  let recorder;
  let recordingStream;
  let currentFile;
  let knownFiles = new Set();

  function getAudioContext() {
    audioContext ??= new AudioContext();
    return audioContext;
  }

  function setStatus(message, error = false) {
    editorStatus.textContent = message;
    editorStatus.dataset.error = String(error);
  }

  function seconds(value) {
    return `${value.toFixed(2)}s`;
  }

  function drawWaveform() {
    const rect = canvas.getBoundingClientRect();
    const ratio = window.devicePixelRatio || 1;
    canvas.width = Math.max(1, Math.floor(rect.width * ratio));
    canvas.height = Math.max(1, Math.floor(rect.height * ratio));
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, rect.width, rect.height);
    if (!buffer) return;

    const data = buffer.getChannelData(0);
    const mid = rect.height / 2;
    const pixels = Math.max(1, Math.floor(rect.width));
    const samplesPerPixel = Math.max(1, Math.floor(data.length / pixels));
    context.fillStyle = getComputedStyle(document.documentElement).color;
    for (let x = 0; x < pixels; x += 1) {
      let peak = 0;
      const from = x * samplesPerPixel;
      const to = Math.min(data.length, from + samplesPerPixel);
      for (let i = from; i < to; i += 1) peak = Math.max(peak, Math.abs(data[i]));
      const height = Math.max(1, peak * (mid - 4));
      context.fillRect(x, mid - height, 1, height * 2);
    }

    if (buffer.duration > 0) {
      const left = selectionStart / buffer.duration * rect.width;
      const right = selectionEnd / buffer.duration * rect.width;
      context.fillStyle = 'rgba(79, 142, 219, 0.24)';
      context.fillRect(left, 0, Math.max(1, right - left), rect.height);
      context.strokeStyle = '#4f8edb';
      context.lineWidth = 2;
      context.strokeRect(left, 1, Math.max(1, right - left), rect.height - 2);
    }
  }

  function updateSelection() {
    if (!buffer) return;
    document.querySelector('#selection').textContent =
      `Selected ${seconds(selectionStart)} to ${seconds(selectionEnd)} of ${seconds(buffer.duration)}. Drag across the waveform to change the selection.`;
    buttons.play.disabled = selectionEnd - selectionStart < 0.02;
    buttons.trim.disabled = selectionEnd - selectionStart < 0.02 || selectionEnd >= buffer.duration;
    buttons.save.disabled = false;
    drawWaveform();
  }

  function setBuffer(value, name = '') {
    buffer = value;
    currentFile = name;
    selectionStart = 0;
    selectionEnd = value.duration;
    fileName.value = name.replace(/\.wav$/i, '');
    document.querySelector('#selection').textContent = '';
    updateSelection();
  }

  async function decodeAudio(blob) {
    const data = await blob.arrayBuffer();
    return getAudioContext().decodeAudioData(data);
  }

  async function loadSound(name) {
    setStatus(`Loading ${name}…`);
    try {
      const response = await fetch(`${prefix}/files/${encodeURIComponent(name)}`, { cache: 'no-store' });
      if (!response.ok) throw new Error(`File request failed (${response.status})`);
      setBuffer(await decodeAudio(await response.blob()), name);
      setStatus(`Loaded ${name}.`);
      for (const item of fileList.querySelectorAll('button')) {
        item.setAttribute('aria-current', String(item.dataset.name === name));
      }
    } catch (error) {
      setStatus(`Could not load ${name}: ${error.message}`, true);
    }
  }

  async function refreshFiles() {
    libraryStatus.textContent = 'Loading sounds…';
    try {
      const response = await fetch(`${prefix}/files/`, { cache: 'no-store' });
      if (!response.ok) throw new Error(`File list request failed (${response.status})`);
      const entries = await response.json();
      const sounds = entries
        .filter(entry => entry.type === 'file' && /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\.wav$/i.test(entry.name))
        .sort((a, b) => a.name.localeCompare(b.name));
      knownFiles = new Set(sounds.map(sound => sound.name));
      fileList.replaceChildren();
      for (const sound of sounds) {
        const item = document.createElement('li');
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = sound.name;
        button.dataset.name = sound.name;
        button.setAttribute('aria-current', String(sound.name === currentFile));
        button.addEventListener('click', () => loadSound(sound.name));
        item.append(button);
        fileList.append(item);
      }
      libraryStatus.textContent = sounds.length ? `${sounds.length} shared WAV file${sounds.length === 1 ? '' : 's'}.` : 'No saved sounds yet.';
    } catch (error) {
      libraryStatus.textContent = `Could not load the library: ${error.message}`;
    }
  }

  function canvasTime(event) {
    const rect = canvas.getBoundingClientRect();
    return Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width)) * buffer.duration;
  }

  canvas.addEventListener('pointerdown', event => {
    if (!buffer) return;
    dragStart = canvasTime(event);
    selectionStart = dragStart;
    selectionEnd = dragStart;
    canvas.setPointerCapture(event.pointerId);
    updateSelection();
  });
  canvas.addEventListener('pointermove', event => {
    if (dragStart === null || !buffer) return;
    const current = canvasTime(event);
    selectionStart = Math.min(dragStart, current);
    selectionEnd = Math.max(dragStart, current);
    updateSelection();
  });
  canvas.addEventListener('pointerup', event => {
    if (dragStart === null) return;
    if (selectionEnd - selectionStart < 0.02) {
      selectionStart = 0;
      selectionEnd = buffer.duration;
    }
    dragStart = null;
    canvas.releasePointerCapture(event.pointerId);
    updateSelection();
  });

  buttons.play.addEventListener('click', async () => {
    if (!buffer) return;
    try {
      const audio = getAudioContext();
      await audio.resume();
      source?.stop();
      source = audio.createBufferSource();
      source.buffer = buffer;
      source.connect(audio.destination);
      source.onended = () => {
        source = null;
        buttons.stopPlayback.disabled = true;
      };
      source.start(0, selectionStart, selectionEnd - selectionStart);
      buttons.stopPlayback.disabled = false;
    } catch (error) {
      setStatus(`Playback failed: ${error.message}`, true);
    }
  });

  buttons.stopPlayback.addEventListener('click', () => {
    source?.stop();
    buttons.stopPlayback.disabled = true;
  });

  buttons.trim.addEventListener('click', () => {
    if (!buffer || selectionEnd - selectionStart < 0.02) return;
    const start = Math.floor(selectionStart * buffer.sampleRate);
    const end = Math.floor(selectionEnd * buffer.sampleRate);
    const trimmed = getAudioContext().createBuffer(1, end - start, buffer.sampleRate);
    trimmed.copyToChannel(buffer.getChannelData(0).slice(start, end), 0);
    setBuffer(trimmed, currentFile);
    setStatus('Trimmed to the selected region. Save to keep the change.');
  });

  buttons.record.addEventListener('click', async () => {
    try {
      const audio = getAudioContext();
      await audio.resume();
      recordingStream = await navigator.mediaDevices.getUserMedia({ audio: true });
      recorder = new MediaRecorder(recordingStream);
      const chunks = [];
      recorder.addEventListener('dataavailable', event => { if (event.data.size) chunks.push(event.data); });
      recorder.addEventListener('stop', async () => {
        recordingStream.getTracks().forEach(track => track.stop());
        recordingStream = null;
        try {
          const recording = new Blob(chunks, { type: recorder.mimeType || 'audio/webm' });
          setBuffer(await decodeAudio(recording));
          setStatus('Recording ready. Trim it and save it to the shared library.');
        } catch (error) {
          setStatus(`Could not decode the recording: ${error.message}`, true);
        }
        buttons.record.disabled = false;
        buttons.stopRecording.disabled = true;
      }, { once: true });
      recorder.start(250);
      buttons.record.disabled = true;
      buttons.stopRecording.disabled = false;
      setStatus('Recording from the selected microphone…');
    } catch (error) {
      recordingStream?.getTracks().forEach(track => track.stop());
      recordingStream = null;
      setStatus(`Microphone access failed: ${error.message}`, true);
    }
  });

  buttons.stopRecording.addEventListener('click', () => {
    if (recorder?.state === 'recording') recorder.stop();
  });

  document.querySelector('#file-input').addEventListener('change', async event => {
    const file = event.target.files[0];
    event.target.value = '';
    if (!file) return;
    if (!file.name.toLowerCase().endsWith('.wav')) {
      setStatus('Import a WAV file. Other formats can be recorded and exported by the browser as WAV.', true);
      return;
    }
    try {
      setBuffer(await decodeAudio(file));
      setStatus(`Imported ${file.name}. Save to add it to the shared library.`);
    } catch (error) {
      setStatus(`Could not open ${file.name}: ${error.message}`, true);
    }
  });

  async function mono8k(bufferToConvert) {
    const rate = 8000;
    const frameCount = Math.max(1, Math.ceil(bufferToConvert.duration * rate));
    const offline = new OfflineAudioContext(1, frameCount, rate);
    const input = offline.createBufferSource();
    input.buffer = bufferToConvert;
    input.connect(offline.destination);
    input.start();
    return offline.startRendering();
  }

  function encodeWav(audio) {
    const samples = audio.getChannelData(0);
    const output = new ArrayBuffer(44 + samples.length * 2);
    const view = new DataView(output);
    const write = (offset, value) => {
      for (let i = 0; i < value.length; i += 1) view.setUint8(offset + i, value.charCodeAt(i));
    };
    write(0, 'RIFF');
    view.setUint32(4, 36 + samples.length * 2, true);
    write(8, 'WAVE');
    write(12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, 8000, true);
    view.setUint32(28, 16000, true);
    view.setUint16(32, 2, true);
    view.setUint16(34, 16, true);
    write(36, 'data');
    view.setUint32(40, samples.length * 2, true);
    for (let i = 0; i < samples.length; i += 1) {
      const sample = Math.max(-1, Math.min(1, samples[i]));
      view.setInt16(44 + i * 2, sample < 0 ? sample * 32768 : sample * 32767, true);
    }
    return new Blob([output], { type: 'audio/wav' });
  }

  buttons.save.addEventListener('click', async () => {
    if (!buffer) return;
    const name = fileName.value.trim();
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(name)) {
      setStatus('Use 1–64 letters, numbers, hyphens, or underscores; the file is saved as .wav.', true);
      return;
    }
    const targetName = `${name}.wav`;
    if (knownFiles.has(targetName) && !window.confirm(`Replace ${targetName}? This changes the shared prompt used by both PBX stacks.`)) return;
    buttons.save.disabled = true;
    setStatus('Converting to mono 8 kHz WAV…');
    try {
      const normalized = await mono8k(buffer);
      const wav = encodeWav(normalized);
      setStatus('Saving to shared storage…');
      const response = await fetch(`${prefix}/files/${encodeURIComponent(targetName)}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'audio/wav' },
        body: wav,
      });
      if (!response.ok) throw new Error(`Save failed (${response.status})`);
      currentFile = targetName;
      fileName.value = name;
      setStatus(`Saved ${currentFile}. Asterisk and FreeSWITCH can now read it.`);
      await refreshFiles();
    } catch (error) {
      setStatus(`Could not save the sound: ${error.message}`, true);
    } finally {
      buttons.save.disabled = false;
    }
  });

  document.querySelector('#refresh').addEventListener('click', refreshFiles);
  window.addEventListener('resize', drawWaveform);
  refreshFiles();
})();
