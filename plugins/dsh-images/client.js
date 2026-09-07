window.__ModuleLoader__.load({id:'dsh-images', factory(require) {
  const React = require('react'), h = React.createElement;
  function Picture({attachment, resolve}) {
    const [url,setURL]=React.useState(''),[error,setError]=React.useState(false),[attempt,setAttempt]=React.useState(0);
    const dialog=React.useRef(null);
    React.useEffect(()=>{let active=true;setURL('');setError(false);
      resolve(attachment).then(value=>{if(active)setURL(value)},()=>{if(active)setError(true)});
      return()=>{active=false};
    },[resolve,attachment.attachmentId,attempt]);
    const label=attachment.name || 'Agent image';
    return h('div',null,
      error?h('button',{onClick:()=>setAttempt(attempt+1)},'Retry loading image'):url?
      h('button',{type:'button','aria-label':'Open image: '+label,onClick:()=>dialog.current?.showModal(),style:{padding:0,border:0,background:'transparent',cursor:'zoom-in',maxWidth:'100%'}},
        h('img',{src:url,alt:label,onError:()=>setError(true),style:{display:'block',maxWidth:'100%',width:320,maxHeight:360,objectFit:'contain',borderRadius:14}})):
      h('div',{role:'status',style:{padding:20}},'Loading image…'),
      h('dialog',{ref:dialog,'aria-label':label,style:{border:0,borderRadius:18,padding:16,maxWidth:'92vw',maxHeight:'92vh',background:'#111',color:'white'},onClick:e=>{if(e.target===e.currentTarget)dialog.current.close()}},
        h('button',{type:'button',onClick:()=>dialog.current.close(),'aria-label':'Close image',style:{display:'block',marginLeft:'auto',marginBottom:12}},'Close'),
        url&&h('img',{src:url,alt:label,style:{display:'block',maxWidth:'85vw',maxHeight:'80vh',objectFit:'contain'}})));
  }
  function ImageResult({block, resolve, inspect}) {
    const images=(block.content||[]).filter(b=>b.type==='image'&&b.attachment?.attachmentId);
    const text=(block.content||[]).filter(b=>b.type==='text').map(b=>b.text).join('\n');
    return h('section',{'aria-label':'Agent image output',style:{padding:'12px 0',display:'grid',gap:10}},
      h('div',{style:{fontSize:13,opacity:.7}},block.kind==='tool-result'?(block.isError?'Image could not be attached':'Image attached'):'Opening image…'),
      ...images.map((b,i)=>h(Picture,{key:b.attachment.attachmentId+':'+i,attachment:b.attachment,resolve})),
      h('details',null,h('summary',null,'Image details'),h('pre',{style:{whiteSpace:'pre-wrap',overflowWrap:'anywhere',fontSize:12}},text||block.argsRaw||''),inspect&&h('button',{onClick:inspect},'Inspect')));
  }
  return {inject:['slots','uiConversation'],apply(ctx){
    ctx.slots.inject('tool.call.toolview',()=>ctx.slots.register({name:'tool.call.toolview',key:'read_image',inject(sessionId){return {resolve:attachment=>ctx.uiConversation.imageUrl(sessionId,attachment)}}},ImageResult));
  }};
}});
