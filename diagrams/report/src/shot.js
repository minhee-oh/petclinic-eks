const { chromium } = require('playwright');
(async()=>{const [,,inp,out,w,h]=process.argv;const b=await chromium.launch();const p=await b.newPage({viewport:{width:+w,height:+h},deviceScaleFactor:2});
await p.goto('file://'+require('path').resolve(inp),{waitUntil:'networkidle'});await p.evaluate(()=>document.fonts.ready);
const el=await p.$('#fig'); if(el) await el.screenshot({path:out}); else await p.screenshot({path:out}); 
console.log(await p.evaluate(()=>[...document.fonts].filter(f=>f.status=='loaded').map(f=>f.family).slice(0,3).join(',')));await b.close();})();
