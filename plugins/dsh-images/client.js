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
  // Only durable tool-result attachments enter the gallery. Never interpret a
  // filesystem path or a Markdown URL as an image download capability.
  function toolImages(content, images = new Map()) {
    for (const part of Array.isArray(content) ? content : []) {
      if (part?.type !== 'tool-result' || part.isError) continue;
      for (const child of Array.isArray(part.content) ? part.content : []) {
        const ref = child?.type === 'image' ? child.attachment : null;
        if (ref && /^sha256:[a-f0-9]{64}$/.test(ref.attachmentId) &&
            /^image\//.test(ref.mediaType) && Number.isSafeInteger(ref.bytes) && ref.bytes > 0) {
          images.set(ref.attachmentId, ref);
        }
      }
      toolImages(part.content, images);
    }
    return images;
  }
  const galleryDefinition = {
    kind: 'dsh-image-gallery', target: 'chat',
    match(event) {
      if (!['turn/start', 'turn/end', 'tool/result', 'assistant/message'].includes(event.type)) return null;
      if (['tool/result', 'assistant/message'].includes(event.type) && event.surfaceOp !== 'append') return null;
      if (!Number.isSafeInteger(event.data?.turn)) return null;
      return {id: String(event.data.turn), role: event.type === 'turn/start' ? 'start' : 'update'};
    },
    start() { return {}; },
    update(context) { return context.state; },
    buildViewNode(context) {
      const location = context.start?.location ?? context.matches[0]?.location;
      if (!location || !['turn', 'step'].includes(location.kind)) return null;
      const tail = location.turn.data.get('turn-tail');
      const images = new Map();
      for (const {event} of context.matches) {
        if (event.type === 'tool/result' && event.surfaceOp === 'append') {
          toolImages(event.data?.message?.content, images);
        }
      }
      if (!images.size || !tail?.closing) return null;
      // Between the final assistant and the action footer (+0.1). This keeps
      // the gallery outside compact process disclosure and preserves Branch.
      return {key: context.key, id: context.id, kind: 'dsh-image-gallery', target: 'chat',
        anchorSeq: tail.closing.finalNode.seq + 0.075, location, visibility: 'visible',
        data: {images: [...images.values()]}};
    }
  };
  function ImageGallery({node, loadImage}) {
    return h('section', {'aria-label': 'Agent image output',
      style: {padding: '12px 0', display: 'flex', flexWrap: 'wrap', gap: 12}},
      ...node.data.images.map(attachment => h(Picture,
        {key: attachment.attachmentId, attachment, resolve: loadImage})));
  }
  return {inject: ['slots', 'uiConversation'], galleryDefinition, toolImages, apply(ctx) {
    ctx.uiConversation.events.register(galleryDefinition);
    ctx.slots.inject('conversation.chat.node', () => ctx.slots.register(
      {name: 'conversation.chat.node', key: 'dsh-image-gallery'}, ImageGallery));
  }};
}});
