import {chromium} from 'playwright';
import fs from 'node:fs';
import http from 'node:http';
import assert from 'node:assert/strict';
const root = new URL('../BrowserResources/', import.meta.url);
const read = path => fs.readFileSync(new URL(path,root),'utf8');
let script = read('native-bootstrap.js');
const config = {enabled:true,runEverywhere:true,lists:[],pro:false,console:{},plugins:[]};
for (const [token, value] of [
    ['__MSE__',read('mse-capture.js')],['__RULES__',read('rule-engine.js')],
    ['__USER_SCRIPTS__',read('userscripts.js')],['__RUNTIME__',read('page-runtime.js')],
    ['__RULE_SOURCE__',JSON.stringify(read('rule-engine.js'))],
    ['__ASSETS__',read('vendor/eruda.js') + read('resource-timing.js') + read('console-ui.js')],
    ['__SOURCE_FORMAT__',read('source-formatting.js')],['__MEDIA__',read('media-resources.js')],
    ['__CONFIG__',JSON.stringify(config)]
]) script = script.replaceAll(token,()=>value);
const server = http.createServer((req,res) => res.end('<!doctype html><html><head><title>Native fixture</title></head><body><video src="/live.m3u8" width="320" height="200"></video></body></html>'));
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser = await chromium.launch({executablePath:process.env.DEVTOOLS_BROWSER_PATH,headless:true,args:['--no-sandbox']});
try {
    const page = await browser.newPage();
    const errors=[];
    page.on('pageerror', error=>errors.push(error.message));
    await page.addInitScript(`addEventListener('message',e=>{if(e.data?.channel==='devtools-media-request')window.postMessage({channel:'devtools-media-reply',id:e.data.id,result:true},'*')});`);
    await page.addInitScript(script);
    await page.goto(`http://127.0.0.1:${server.address().port}`);
    await page.waitForFunction(()=>globalThis.__DTNativeStatus?.active, null, {timeout:5000});
    assert.equal(await page.evaluate(()=>!!__DTMedia && !!__DTMSE && !!__DTSourceFormatting),true);
    await page.evaluate(()=>__DTNativeUpdate({enabled:false,runEverywhere:true,lists:[],console:{}},''));
    await page.waitForFunction(()=>__DTNativeStatus?.active===false);
    await page.evaluate(config=>__DTNativeUpdate(config,'show'),config);
    await page.waitForFunction(()=>__DTNativeStatus?.active===true && !__DTNativeStatus.hidden);
    assert.deepEqual(errors,[]);
    console.log('Native browser bootstrap: initialization, teardown, re-enable passed; no uncaught errors');
} finally {await browser.close(); server.close();}
