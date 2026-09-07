import fs from 'node:fs/promises';
const base='http://127.0.0.1:3080';
const log=await fs.readFile(process.env.HOME+'/.dsh/web.stdout.log','utf8');
const urls=[...log.matchAll(/http:\/\/127\.0\.0\.1:3080\/\?token=[^\s\x1b]+/g)];
if(!urls.length)throw Error('No launch URL');
const login=await fetch(urls.at(-1)[0],{redirect:'manual'});
const cookie=login.headers.getSetCookie().map(v=>v.split(';')[0]).join('; ');
if(!cookie)throw Error('No authentication cookie');
const headers={Origin:base,Cookie:cookie};

const response=await fetch(base+'/api/session/list',{method:'POST',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify({type:'client-request',rpcId:crypto.randomUUID(),method:'session/list',payload:{args:{_request:{}}}})});
const result=await response.json();
const session=result.result.value.items.find(s=>(s.projections?.values?.title?.title??s.projections?.values?.title)==='Model selection check');
if(!session)throw Error('Test session missing');
// Node's native WebSocket cannot set handshake headers; use the installed ws package.
const {default:WebSocket}=await import(process.env.DSH_WS_MODULE || 'ws');
const socket=new WebSocket('ws://127.0.0.1:3080/api/remote.mux',{headers});
const timeout=setTimeout(()=>{socket.terminate();console.error('Stream timed out');process.exitCode=1},15000);
socket.on('error',e=>{clearTimeout(timeout);console.error(e.message);process.exitCode=1});
socket.on('open',()=>socket.send(JSON.stringify({type:'open',streamId:'turn-watch',endpoint:'session/follow',payload:{args:{request:{address:{kind:'session',sessionId:session.sessionId},maxMessages:100}}}})));
socket.on('message',raw=>{const f=JSON.parse(raw);if(f.type==='error')throw Error('Stream rejected');if(f.value?.type!=='snapshot')return;
 const events=f.value.records.map(r=>r.event);const input=events.find(e=>e.type==='user/message'&&e.data.source?.rpcId);
 if(!input||!events.some(e=>e.seq>input.seq&&e.type==='turn/end'))throw Error('No correlated durable completion');
 console.log('PASS independent authenticated follow stream and durable request/end records');clearTimeout(timeout);socket.close();});
