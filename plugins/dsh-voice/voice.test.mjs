import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {createHandler,MAX_BYTES} from './index.js';
async function server(t, options={}) {
 const handler=createHandler({requestRejection:r=>r.headers.authorization==='test'?undefined:401},options);
 const s=http.createServer(handler);await new Promise(r=>s.listen(0,'127.0.0.1',r));t.after(()=>{s.closeAllConnections();s.close();});
 return (body='audio',headers={},signal)=>fetch(`http://127.0.0.1:${s.address().port}`,{method:'POST',headers:{authorization:'test','Content-Type':'audio/mp4',...headers},body,signal});
}
test('auth is checked before upstream',async t=>{let called=false;const post=await server(t,{fetchImpl:async()=>{called=true;}});assert.equal((await post('a',{authorization:''})).status,401);assert.equal(called,false);});
test('forwards multipart audio and returns text only',async t=>{const post=await server(t,{fetchImpl:async(url,req)=>{assert.equal(url.searchParams.get('task'),'transcribe');assert.equal(url.searchParams.get('vad_filter'),'true');assert.equal(await req.body.get('audio_file').text(),'audio');return Response.json({text:' Hello ',language:'en',segments:['private']});}});const response=await post();assert.deepEqual(await response.json(),{text:'Hello',language:'en'});});
test('rejects unsupported, empty and oversized input',async t=>{const post=await server(t,{fetchImpl:()=>{throw Error('must not call');}});assert.equal((await post('a',{'Content-Type':'text/plain'})).status,415);assert.equal((await post('')).status,400);assert.equal((await post(Buffer.alloc(MAX_BYTES+1))).status,413);});
test('empty speech does not become a prompt',async t=>{const post=await server(t,{fetchImpl:async()=>Response.json({text:' '})});assert.equal((await post()).status,422);});
test('upstream failure hides internal errors and permits retry',async t=>{let n=0;const post=await server(t,{fetchImpl:async()=>{if(n++===0)throw Error('private URL');return Response.json({text:'retry'});}});const r=await post();assert.equal(r.status,502);assert.ok(!(await r.text()).includes('private'));assert.equal((await post()).status,200);});
test('concurrent recordings are bounded and a timeout releases the seat',async t=>{let entered;const enteredPromise=new Promise(r=>entered=r);const post=await server(t,{timeout:100,fetchImpl:async(_u,{signal})=>{entered();await new Promise((_,reject)=>signal.addEventListener('abort',()=>reject(Error('aborted'))));}});const first=post();await enteredPromise;assert.equal((await post()).status,429);assert.equal((await first).status,504);assert.equal((await post()).status,504);});

test('browser sends only voice text with a stable request identity, without editing drafts', async()=>{
 const {readFile}=await import('node:fs/promises');const {runInNewContext}=await import('node:vm');
 let plugin, sent;runInNewContext(await readFile(new URL('./client.js',import.meta.url),'utf8'),{
   window:{__ModuleLoader__:{load:({factory})=>{plugin=factory(()=>({createElement(){}}));}}},
   fetch:async(path,options)=>{sent={path,options,body:JSON.parse(options.body)};return Response.json({result:{ok:true}});},Intl
 });
 let entry;plugin.apply({slots:{inject:(_n,fn)=>fn(),register:e=>{entry=e;}}});
 const props=entry.inject('voice-test-session');await props.send('Just the voice message','stable-id');
 assert.equal(sent.path,'/api/session/prompt');assert.equal(sent.options.credentials,'same-origin');
 assert.equal(sent.body.payload.args.request.sessionId,'voice-test-session');
 assert.equal(sent.body.payload.args.request.requestId,'stable-id');
 assert.deepEqual(sent.body.payload.args.request.content,[{type:'text',text:'Just the voice message'}]);
 await props.send('Just the voice message','stable-id');assert.equal(sent.body.payload.args.request.requestId,'stable-id');
});

async function gestureHarness({ delayedPermission = false } = {}) {
 const {readFile}=await import('node:fs/promises');const {runInNewContext}=await import('node:vm');
 let plugin,Component,clock=1000,resolvePermission;let stops=0,recordings=0,uploads=0;const sent=[];
 const stream={getTracks:()=>[{stop(){stops++;}}]};
 const permission=delayedPermission?new Promise(r=>resolvePermission=r):Promise.resolve(stream);
 const react={createElement:(type,props,...children)=>({type,props,children}),useState:value=>[value,()=>{}],useRef:value=>({current:value}),useEffect:()=>{}};
 class Recorder {
  static isTypeSupported(){return true;}
  constructor(){this.state='inactive';this.mimeType='audio/mp4';}
  start(){this.state='recording';recordings++;}
  stop(){this.state='inactive';this.ondataavailable?.({data:new Blob(['test audio'])});this.onstop?.();}
 }
 runInNewContext(await readFile(new URL('./client.js',import.meta.url),'utf8'),{
  window:{MediaRecorder:Recorder,__ModuleLoader__:{load:({factory})=>plugin=factory(()=>react)}},MediaRecorder:Recorder,
  navigator:{mediaDevices:{getUserMedia:()=>permission}},crypto:{randomUUID:()=> 'gesture-id'},Date:{now:()=>clock},
  Blob,AbortController,setTimeout,clearTimeout,setInterval:()=>1,clearInterval:()=>{},
  fetch:async()=>{uploads++;return Response.json({text:'Please say hello.'});}
 });
 plugin.apply({slots:{inject:(_n,fn)=>fn(),register:(_e,c)=>Component=c}});
 const tree=Component({sessionId:'test',send:async(text,id)=>sent.push({text,id})});
 const button=tree.children.find(x=>x?.props?.onPointerDown).props;
 const event=x=>({button:0,clientX:x,pointerId:1,preventDefault(){},currentTarget:{setPointerCapture(){}}});
 const settle=()=>new Promise(r=>setImmediate(r));
 return {button,event,settle,sent,advance:()=>clock=2500,grant:()=>resolvePermission(stream),stats:()=>({stops,recordings,uploads})};
}
test('hold then release transcribes and sends once',async()=>{
 const h=await gestureHarness();h.button.onPointerDown(h.event(200));await h.settle();h.advance();h.button.onPointerUp(h.event(200));await h.settle();
 assert.equal(h.stats().uploads,1);assert.deepEqual(h.sent,[{text:'Please say hello.',id:'gesture-id'}]);assert.ok(h.stats().stops>0);
 h.button.onLostPointerCapture();await h.settle();assert.equal(h.sent.length,1);
});
test('slide left discards without uploading or sending',async()=>{
 const h=await gestureHarness();h.button.onPointerDown(h.event(200));await h.settle();h.advance();h.button.onPointerMove(h.event(110));h.button.onPointerUp(h.event(110));await h.settle();
 assert.equal(h.stats().uploads,0);assert.equal(h.sent.length,0);assert.ok(h.stats().stops>0);
});
test('release before microphone permission never starts a late recording',async()=>{
 const h=await gestureHarness({delayedPermission:true});h.button.onPointerDown(h.event(200));h.button.onPointerUp(h.event(200));h.grant();await h.settle();
 assert.equal(h.stats().recordings,0);assert.equal(h.stats().uploads,0);assert.ok(h.stats().stops>0);
});
test('OS pointer cancellation discards recording',async()=>{
 const h=await gestureHarness();h.button.onPointerDown(h.event(200));await h.settle();h.button.onPointerCancel();await h.settle();assert.equal(h.stats().uploads,0);assert.equal(h.sent.length,0);
});
