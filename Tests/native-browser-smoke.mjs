import {chromium} from 'playwright';
import fs from 'node:fs';
import http from 'node:http';
import assert from 'node:assert/strict';
const root = new URL('../BrowserResources/', import.meta.url);
const read = path => fs.readFileSync(new URL(path,root),'utf8');
let script = read('native-bootstrap.js');
const config = {enabled:true,runEverywhere:true,lists:[],pro:false,console:{},plugins:[{id:"css-editor",name:"Page CSS editor",kind:"eruda",enabled:true,source:read("css-editor-plugin.js")},{id:"login-script",name:"Login fixture",kind:"userscript",enabled:true,source:"// ==UserScript==\n// @match http://127.0.0.1/*\n// @grant none\n// ==/UserScript==\nwindow.__userscriptRan = true;"}]};
for (const [token, value] of [
    ['__MSE__',read('mse-capture.js')],['__RULES__',read('rule-engine.js')],
    ['__USER_SCRIPTS__',read('userscripts.js')],['__RUNTIME__',read('page-runtime.js')],
    ['__RULE_SOURCE__',JSON.stringify(read('rule-engine.js'))],
    ['__ASSETS__',read('vendor/eruda.js') + read('resource-timing.js') + read('console-ui.js')],
    ['__SOURCE_FORMAT__',read('source-formatting.js')],['__MEDIA__',read('media-resources.js')],
    ['__CONFIG__',JSON.stringify(config)]
]) script = script.replaceAll(token,()=>value);
const server = http.createServer((req,res) => { if(req.url === '/redirect') { res.writeHead(302,{Location:'/login'}); res.end(); return; } res.end('<!doctype html><html><head><title>Native fixture</title></head><body><video src="/live.m3u8" width="320" height="200"></video></body></html>'); });
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser = await chromium.launch({executablePath:process.env.DEVTOOLS_BROWSER_PATH,headless:true,args:['--no-sandbox']});
try {
    const page = await browser.newPage();
    const errors=[];
    page.on('pageerror', error=>errors.push(error.message));
    page.on('console', message=>{if(message.type()==='error' && message.text().includes('[DevTools userscript]')) errors.push(message.text());});
    await page.addInitScript(`window.__mediaRequests=[];addEventListener('message',e=>{if(e.data?.channel==='devtools-media-request'){window.__mediaRequests.push(e.data.payload);window.postMessage({channel:'devtools-media-reply',id:e.data.id,result:true},'*')}});`);
    await page.addInitScript(script);
    await page.goto(`http://127.0.0.1:${server.address().port}/redirect`);
    await page.waitForFunction(()=>globalThis.__DTNativeStatus?.active, null, {timeout:5000});
    assert.ok(page.url().endsWith("/login"));
    await page.waitForFunction(()=>window.__userscriptRan === true);
    assert.equal(await page.evaluate(()=>!!__DTAssets.eruda.get("css-editor")),true);
    assert.equal(await page.evaluate(()=>__DTNativeStatus.hidden),true);
    assert.notEqual(await page.evaluate(()=>getComputedStyle(__DTAssets.eruda.get('css-editor').element.get(0)).backgroundColor),'rgba(0, 0, 0, 0)');
    assert.equal(await page.evaluate(()=>__DTAssets.eruda.get().config.get('displaySize')<=75),true);
    assert.equal(await page.evaluate(()=>!!__DTMedia && !!__DTMSE && !!__DTSourceFormatting),true);
    const inspection = await page.evaluate(()=>{
        let blocked=0;
        const block=event=>{blocked++;event.preventDefault();};
        document.addEventListener('contextmenu',block);
        document.addEventListener('keydown',block);
        const contextAllowed=document.body.dispatchEvent(new Event('contextmenu',{bubbles:true,cancelable:true}));
        const shortcutAllowed=document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'F12',bubbles:true,cancelable:true}));
        document.removeEventListener('contextmenu',block);
        document.removeEventListener('keydown',block);
        return {blocked,contextAllowed,shortcutAllowed};
    });
    assert.deepEqual(inspection,{blocked:0,contextAllowed:true,shortcutAllowed:true});
    const initialButtons = await page.locator('[data-devtools-progress-ring]').count();
    await page.evaluate(()=>{
        for(const src of [null,'',location.href]) {
            const video=document.createElement('video');
            if(src!==null)video.setAttribute('src',src);
            document.body.append(video);
        }
        __DTMedia.refresh();
    });
    assert.equal(await page.locator('[data-devtools-progress-ring]').count(),initialButtons + 3);
    await page.evaluate(()=>{for(const video of [...document.querySelectorAll('video')].slice(1))video.remove();__DTMedia.refresh();});
    const mediaURL = await page.evaluate(()=>document.querySelector('video').src);
    const control = page.locator('button').filter({has:page.locator('[data-devtools-progress-ring]')});
    await page.evaluate(url=>__DTMedia.status(url,'Downloading',0.25,true,false,true),mediaURL);
    assert.equal(await control.locator('progress').getAttribute('value'),'0.25');
    assert.equal(await control.isEnabled(),false);
    await page.evaluate(url=>__DTMedia.status(url,'Finalizing movie',1,true,false,false),mediaURL);
    assert.equal(await control.locator('progress').getAttribute('value'),'0.99');
    await page.evaluate(url=>__DTMedia.status(url,'Saved',1,false,false,false),mediaURL);
    assert.equal(await control.locator('progress').getAttribute('value'),'1');
    assert.equal(await control.getAttribute('aria-label'),'Video saved');
    await page.evaluate(url=>__DTMedia.status(url,'Recording live segments',null,true,true,true),mediaURL);
    assert.equal(await control.getAttribute('aria-label'),'Stop recording');
    await control.click();
    await page.waitForFunction(()=>__mediaRequests.some(request=>request.type==='stop'));
    assert.equal(await page.evaluate(url=>__mediaRequests.find(request=>request.type==='stop').url===url,mediaURL),true);
    await page.evaluate(url=>__DTMedia.status(url,'Finishing captured media',null,true,true,false),mediaURL);
    assert.equal(await control.isEnabled(),false);
    assert.equal(await control.getAttribute('aria-label'),'Finalizing recording');
    await page.evaluate(()=>__DTNativeUpdate({enabled:false,runEverywhere:true,lists:[],console:{}},''));
    await page.waitForFunction(()=>__DTNativeStatus?.active===false);
    await page.evaluate(config=>__DTNativeUpdate(config,'show'),config);
    await page.waitForFunction(()=>__DTNativeStatus?.active===true && !__DTNativeStatus.hidden);
    assert.deepEqual(errors,[]);
    console.log('Native browser bootstrap: initialization, teardown, re-enable passed; live Stop and circular progress passed; no uncaught errors');
} finally {await browser.close(); server.close();}
