/** Authenticated, bounded audio relay. Reuses the existing home-rig ASR. */
export const name = 'pocket-voice';
export const inject = ['webServer', 'connection'];
export const MAX_BYTES = 8 * 1024 * 1024;
export const TYPES = new Set(['audio/mp4', 'audio/x-m4a', 'audio/webm', 'audio/ogg', 'audio/wav', 'audio/x-wav', 'audio/aiff', 'audio/x-aiff']);
export function createHandler(connection, { endpoint = process.env.POCKET_DSH_ASR_URL || 'http://127.0.0.1:9000/asr', fetchImpl = fetch, timeout = 180000 } = {}) {
  let busy = false;
  return async (req, res) => {
    const json = (status, body) => { if (!res.destroyed) { res.writeHead(status, {'Content-Type': 'application/json', 'Cache-Control': 'no-store'}); res.end(JSON.stringify(body)); } };
    const rejected = connection.requestRejection(req);
    if (rejected !== undefined) return json(rejected, {error: 'Sign in to DSH again.'});
    if (req.method !== 'POST') return json(405, {error: 'POST required.'});
    const type = (req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
    if (!TYPES.has(type)) return json(415, {error: 'Unsupported audio format.'});
    if (Number(req.headers['content-length']) > MAX_BYTES) return json(413, {error: 'Recording exceeds 8 MB.'});
    if (busy) return json(429, {error: 'Whisper is busy. Please retry shortly.'});
    busy = true;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeout);
    const disconnect = () => { if (!res.writableEnded) controller.abort(); };
    res.on('close', disconnect);
    try {
      const chunks = []; let size = 0;
      for await (const chunk of req) {
        size += chunk.length;
        if (size > MAX_BYTES) { json(413, {error: 'Recording exceeds 8 MB.'}); return; }
        if (controller.signal.aborted) throw new Error('Transcription timed out.');
        chunks.push(chunk);
      }
      if (!size) return json(400, {error: 'The recording is empty.'});
      const form = new FormData();
      form.append('audio_file', new Blob(chunks, {type}), 'recording.' + ({'audio/mp4':'m4a','audio/x-m4a':'m4a','audio/webm':'webm','audio/ogg':'ogg','audio/wav':'wav','audio/x-wav':'wav','audio/aiff':'aiff','audio/x-aiff':'aiff'}[type]));
      const url = new URL(endpoint); url.search = new URLSearchParams({encode:'true',task:'transcribe',output:'json',vad_filter:'true'}).toString();
      const response = await fetchImpl(url, {method:'POST', body:form, signal:controller.signal, redirect:'error'});
      if (!response.ok) throw new Error('Whisper could not process this recording. Please retry.');
      const result = await response.json();
      if (typeof result.text !== 'string') throw new Error('Invalid response from Whisper.');
      const text = result.text.trim();
      if (!text) return json(422, {error:'No speech detected. Try recording again.'});
      json(200, {text, language:result.language || ''});
    } catch (error) {
      json(controller.signal.aborted ? 504 : 502, {error: controller.signal.aborted ? 'Transcription timed out or was cancelled. Please retry.' : (error.message.startsWith('Whisper') || error.message.startsWith('Invalid response') ? error.message : 'Home rig is unavailable. Keep the recording and retry.')});
    } finally { clearTimeout(timer); res.off('close', disconnect); busy = false; }
  };
}
export function apply(ctx) {
  ctx.effect(() => ctx.webServer.register({kind:'exact', path:'/pocket-voice/transcribe', handler:createHandler(ctx.connection)}));
}
