window.__ModuleLoader__.load({id:'dsh-voice', factory(require) {
  const React = require('react'); const h = React.createElement;
  const style = {border:0,borderRadius:16,padding:'7px 10px',background:'var(--dsw-alias-interactive-bg-hover)',color:'inherit',cursor:'pointer',font:'inherit',fontSize:13};
  function Voice({sessionId, send}) {
    const [phase,setPhase]=React.useState('idle'), [seconds,setSeconds]=React.useState(0), [error,setError]=React.useState('');
    const [levels,setLevels]=React.useState(Array(18).fill(.05)), [discard,setDiscard]=React.useState(false);
    const ref=React.useRef({});
    function releaseDevices(s) {
      clearInterval(s.timer);s.stream?.getTracks().forEach(t=>t.stop());s.audioContext?.close().catch(()=>{});s.audioContext=null;
    }
    function clear() {
      const s=ref.current;s.dead=true;s.held=false;s.abort?.abort();
      if(s.recorder?.state==='recording')s.recorder.stop();
      releaseDevices(s);ref.current={};
    }
    function cancel() {clear();setPhase('idle');setDiscard(false);setError('');setLevels(Array(18).fill(.05));}
    React.useEffect(()=>{setPhase('idle');setError('');setSeconds(0);return()=>clear();},[sessionId]);
    React.useEffect(()=>{const hide=()=>{if(document.hidden&&(ref.current.held||ref.current.keyboard))cancel();};document.addEventListener('visibilitychange',hide);return()=>document.removeEventListener('visibilitychange',hide);},[]);
    async function transcribe(s) {
      setPhase(s.text?'sending':'transcribing');setError('');s.abort=new AbortController();
      const timeout=setTimeout(()=>s.abort.abort(),180000);
      try {
        if(!s.text) {
          const response=await fetch('/pocket-voice/transcribe',{method:'POST',headers:{'Content-Type':s.blob.type},body:s.blob,credentials:'same-origin',signal:s.abort.signal});
          const result=await response.json();if(!response.ok)throw new Error(result.error||'Transcription failed.');s.text=result.text;
        }
        if(s.dead)return;
        setPhase('sending');await send(s.text,s.requestId,s.abort.signal);
        if(s.dead)return;
        ref.current={};setPhase('idle');setLevels(Array(18).fill(.05));
      } catch(e) {if(!s.dead){setError(s.text?'Send not confirmed. Check the conversation before retrying.':e.name==='AbortError'?'Transcription timed out. Please retry.':e.message);setPhase('retry');}}
      finally {clearTimeout(timeout);}
    }
    async function start(s) {
      setError('');setPhase('permission');setDiscard(false);s.requestId=crypto.randomUUID();
      try {
        if(!navigator.mediaDevices?.getUserMedia||!window.MediaRecorder)throw new Error('Recording requires HTTPS and microphone support.');
        const stream=await navigator.mediaDevices.getUserMedia({audio:true});
        if(s.dead){stream.getTracks().forEach(t=>t.stop());return;}s.stream=stream;
        const mime=['audio/mp4','audio/webm;codecs=opus','audio/ogg;codecs=opus'].find(t=>MediaRecorder.isTypeSupported(t));
        const recorder=new MediaRecorder(stream,mime?{mimeType:mime,audioBitsPerSecond:64000}:{audioBitsPerSecond:64000});s.recorder=recorder;s.chunks=[];s.size=0;
        // Actual microphone amplitude; the analyser is never connected to speakers.
        const AudioContext=window.AudioContext||window.webkitAudioContext;
        if(AudioContext){s.audioContext=new AudioContext();s.analyser=s.audioContext.createAnalyser();s.analyser.fftSize=256;s.source=s.audioContext.createMediaStreamSource(stream);s.source.connect(s.analyser);s.samples=new Uint8Array(256);s.audioContext.resume().catch(()=>{});}
        recorder.ondataavailable=e=>{if(e.data.size){s.chunks.push(e.data);s.size+=e.data.size;if(s.size>8*1024*1024){cancel();setError('Recording is too large. Try a shorter message.');}}};
        recorder.onerror=()=>{cancel();setError('Recording failed. Please try again.');};
        recorder.onstop=()=>{releaseDevices(s);if(s.dead)return;s.held=false;s.keyboard=false;s.blob=new Blob(s.chunks,{type:recorder.mimeType});transcribe(s);};
        recorder.start(250);s.started=Date.now();setSeconds(0);setPhase('recording');
        s.timer=setInterval(()=>{
          if(s.dead)return;
          setSeconds(Math.floor((Date.now()-s.started)/1000));
          if(s.analyser){s.analyser.getByteTimeDomainData(s.samples);const rms=Math.sqrt(s.samples.reduce((sum,x)=>sum+((x-128)/128)**2,0)/s.samples.length);setLevels(old=>[...old.slice(1),Math.max(.05,Math.min(1,rms*5))]);}
          if(Date.now()-s.started>=120000&&recorder.state==='recording'){if(s.discard)cancel();else recorder.stop();}
        },50);
      } catch(e){if(!s.dead){releaseDevices(s);s.held=false;s.keyboard=false;setError(e.name==='NotAllowedError'?'Microphone permission was denied. Enable it in your browser settings.':e.message);setPhase('idle');}}
    }
    function finish() {const s=ref.current;s.held=false;s.keyboard=false;if(s.discard||!s.started||Date.now()-s.started<350){cancel();return;}if(s.recorder?.state==='recording')s.recorder.stop();}
    const active=phase==='recording'||phase==='permission';
    const mic=h('svg',{width:20,height:20,viewBox:'0 0 24 24',fill:'none',stroke:'currentColor',strokeWidth:1.8,'aria-hidden':true},h('rect',{x:9,y:2,width:6,height:12,rx:3}),h('path',{d:'M5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8'}));
    return h('div',{style:{display:'flex',gap:7,alignItems:'center',position:'relative'},'data-pocket-voice':''},
      h('button',{type:'button',style:{...style,padding:0,width:38,height:38,borderRadius:19,touchAction:'none',userSelect:'none',background:active?(discard?'#df4455':'#3268ee'):style.background,color:active?'white':'inherit'},title:'Hold to record · release to send · slide left to cancel','aria-label':active?'Finish voice message':'Hold to record',disabled:!['idle','recording','permission'].includes(phase),
        onContextMenu:e=>e.preventDefault(),
        onPointerDown:e=>{if(e.button!==0||phase!=='idle')return;e.preventDefault();e.currentTarget.setPointerCapture(e.pointerId);clear();const s=ref.current;s.held=true;s.x=e.clientX;start(s);},
        onPointerMove:e=>{const s=ref.current;if(s.held&&e.clientX-s.x < -65){s.discard=true;setDiscard(true);}},
        onPointerUp:e=>{const s=ref.current;if(!s.held)return;e.preventDefault();finish();},
        onPointerCancel:()=>{if(ref.current.held)cancel();},onLostPointerCapture:()=>{if(ref.current.held)cancel();},
        onKeyDown:e=>{if(e.key==='Escape'){cancel();return;}if((e.key===' '||e.key==='Enter')&&!e.repeat){e.preventDefault();if(active)finish();else if(phase==='idle'){clear();ref.current.keyboard=true;start(ref.current);}}},
        onClick:e=>{if(e.detail===0){if(active)finish();else if(phase==='idle'){clear();ref.current.keyboard=true;start(ref.current);}}}
      },discard?'×':mic),
      active&&h('div',{style:{display:'flex',flexDirection:'column',gap:3,minWidth:125}},
        h('div',{'aria-label':'Live microphone level',style:{display:'flex',gap:2,height:24,alignItems:'center'}},...levels.map((level,i)=>h('span',{key:i,style:{width:3,height:Math.max(3,level*24),borderRadius:2,background:discard?'#df4455':'#5488ff'}})),h('span',{style:{fontSize:12,fontVariantNumeric:'tabular-nums',marginLeft:5}},`${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`)),
        h('span',{style:{fontSize:10,color:discard?'#df4455':'inherit'}},discard?'Release to delete':'‹ Slide left to cancel')),
      ['transcribing','sending'].includes(phase)&&h('span',{role:'status',style:{fontSize:12}},phase==='sending'?'Sending…':'Transcribing…'),
      phase==='retry'&&h('button',{type:'button',style,onClick:()=>transcribe(ref.current)},ref.current.text?'Retry sending':'Retry transcription'),
      phase!=='idle'&&phase!=='sending'&&!ref.current.held&&h('button',{type:'button',style,'aria-label':'Cancel voice message',onClick:cancel},'×'),
      error&&h('div',{role:'alert',style:{position:'absolute',bottom:46,right:0,width:260,padding:12,borderRadius:12,background:'var(--dsw-alias-bg-module-platform, #222)',color:'var(--dsw-alias-label-primary, white)',boxShadow:'0 4px 18px #0003',fontSize:12}},error,h('button',{type:'button',style,onClick:()=>setError(''),'aria-label':'Dismiss voice error'},'×')));
  }
  return {inject:['slots','sessions'],apply(ctx){ctx.slots.inject('conversation.input.right',()=>ctx.slots.register({name:'conversation.input.right',id:'pocket-voice',order:50,inject(sessionId){return {sessionId,async send(text,requestId,signal){
    const response=await fetch('/api/session/prompt',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},signal,body:JSON.stringify({type:'client-request',rpcId:requestId,method:'session/prompt',payload:{args:{request:{sessionId,requestId,mode:'queue',clientTimeZone:Intl.DateTimeFormat().resolvedOptions().timeZone,content:[{type:'text',text}]}}}})});
    const result=await response.json();if(!response.ok||!result.result?.ok)throw new Error('Voice message send not confirmed.');
  }}}},Voice));}};
}});
