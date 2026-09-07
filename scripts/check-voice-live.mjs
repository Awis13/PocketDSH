import fs from 'node:fs/promises';
const base='http://127.0.0.1:3080';
const log=await fs.readFile(process.env.HOME+'/.dsh/web.stdout.log','utf8');
const urls=[...log.matchAll(/http:\/\/127\.0\.0\.1:3080\/\?token=[^\s\x1b]+/g)];
if(!urls.length)throw Error('No launch URL');
const login=await fetch(urls.at(-1)[0],{redirect:'manual'});
const cookie=login.headers.getSetCookie().map(v=>v.split(';')[0]).join('; ');
if(!cookie)throw Error('No authentication cookie');
const headers={Origin:base,Cookie:cookie};
if(process.argv.includes('--sessions')){
 const response=await fetch(base+'/api/session/list',{method:'POST',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify({type:'client-request',rpcId:crypto.randomUUID(),method:'session/list',payload:{args:{_request:{}}}})});
 const r=await response.json();if(!r.result?.ok)throw Error('Session list failed');
 console.log(JSON.stringify({sessions:r.result.value.items.length,running:r.result.value.items.filter(x=>x.running).map(x=>({id:x.id,title:x.title,status:x.status}))}));
}else{
 const unauth=await fetch(base+'/pocket-voice/transcribe',{method:'POST',headers:{Origin:base,'Content-Type':'audio/aiff'},body:'x'});if(unauth.status!==401)throw Error('Expected unauthenticated rejection, got '+unauth.status);
 const audio=await fs.readFile('/tmp/pocket-dsh-voice-check.aiff');
 const start=Date.now();
 const response=await fetch(base+'/pocket-voice/transcribe',{method:'POST',headers:{...headers,'Content-Type':'audio/aiff'},body:audio,signal:AbortSignal.timeout(180000)});
 const result=await response.json();if(!response.ok || !result.text?.includes('latest changes'))throw Error(JSON.stringify(result));
 console.log(JSON.stringify({status:response.status,text:result.text,elapsedSeconds:(Date.now()-start)/1000,unauthenticatedStatus:unauth.status}));
}
