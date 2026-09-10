const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
let plugin;
vm.runInNewContext(readFileSync(__dirname + '/client.js', 'utf8'), {
  window: {__ModuleLoader__: {load({factory}) { plugin = factory(() => ({})); }}}
});
const ref = {attachmentId: 'sha256:' + 'a'.repeat(64), mediaType: 'image/png', bytes: 100};
const result = (attachment = ref, isError = false) => ({type:'tool-result', isError, content:[{type:'image',attachment}]});
assert.equal(plugin.toolImages([result(), result()]).size, 1);
assert.equal(plugin.toolImages([result(ref, true)]).size, 0);
assert.equal(plugin.toolImages([{type:'image', attachment:ref}]).size, 0);
assert.equal(plugin.toolImages([result({...ref,attachmentId:'/tmp/private.png'})]).size, 0);
assert.equal(plugin.toolImages([result({...ref,mediaType:'text/html'})]).size, 0);
assert.equal(plugin.toolImages([{type:'tool-result',content:[result()]}]).size, 1);
const def = plugin.galleryDefinition;
const event = {type:'tool/result',seq:35,surfaceOp:'append',data:{turn:1,message:{content:[result()]}}};
assert.equal(def.match({...event,surfaceOp:'replace'}), null);
assert.equal(def.match({...event,type:'user/message'}), null);
const context = {key:'gallery:1',id:'1',matches:[{event}],start:{location:{kind:'turn',turn:{data:new Map([['turn-tail',{closing:{finalNode:{seq:40}}}]])}}}};
const node = def.buildViewNode(context);
assert.equal(node.data.images.length,1);
assert.ok(node.anchorSeq > 40 && node.anchorSeq < 40.1);
assert.equal(def.buildViewNode({...context,matches:[{event:{...event,surfaceOp:'replace'}}]}),null);
assert.equal(def.buildViewNode({...context,matches:[]}),null);
assert.equal(def.buildViewNode({...context,start:{location:{kind:'unresolved'}}}),null);
assert.equal(def.buildViewNode({...context,start:{location:{kind:'turn',turn:{data:new Map()}}}}),null);
console.log('PASS: durable images, deduplication, failures, malformed refs, nested results, replacement exclusion, turn placement and incomplete history');
