import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source=fs.readFileSync(new URL('../BrowserResources/media-discovery.js',import.meta.url),'utf8');
test('frame request observation detects signed HLS without altering network or player APIs',()=>{
    const messages=[];
    let observe;
    const fetch=()=>{};
    const context=vm.createContext({URL,fetch,location:{protocol:'https:',href:'https://player.example/embed'},
        document:{title:'Frame player',querySelectorAll:()=>[]},
        performance:{getEntriesByType:()=>[{name:'https://cdn.example/master.m3u8?token=private'},{name:'https://player.example/embed'}]},
        PerformanceObserver:class{constructor(callback){observe=callback;}observe(){}disconnect(){}},
        webkit:{messageHandlers:{dtMedia:{postMessage:payload=>{messages.push(payload);return Promise.resolve();}}}},
        setInterval:()=>1,clearInterval(){},addEventListener(){}});
    vm.runInContext(source,context);
    assert.equal(context.fetch,fetch);
    const media=messages.filter(message=>message.type==='media-discovery');
    assert.equal(media.length,1);
    assert.equal(media[0].hls,true);
    assert.equal(media[0].page,'https://player.example/embed');
    assert.equal(media[0].url,'https://cdn.example/master.m3u8?token=private');
    observe({getEntries:()=>[{name:media[0].url},{name:'https://cdn.example/segment.ts'},{name:'https://cdn.example/other.m3u8'}]});
    assert.equal(messages.filter(message=>message.type==='media-discovery').length,2);
    assert.ok(messages.find(message=>message.type==='media-diagnostics').summary.includes('Observer active'));
});
