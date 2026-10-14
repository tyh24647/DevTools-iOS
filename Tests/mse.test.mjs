import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync(new URL('../BrowserResources/mse-capture.js', import.meta.url), 'utf8');
function fixture() {
    const messages = [];
    class MediaSource {
        addSourceBuffer() { return {appendBuffer() {}}; }
    }
    const context = vm.createContext({MediaSource, Blob, ArrayBuffer, Uint8Array, btoa,
        URL:{createObjectURL: () => 'blob:test', revokeObjectURL() {}},
        devtoolsMedia:{postMessage: async raw => { messages.push(JSON.parse(raw)); return true; }}
    });
    context.window = context;
    context.top = context;
    vm.runInContext(source, context);
    return {context, messages};
}
function box(type, length = 16) {
    const data = new Uint8Array(length);
    for (let i = 0; i < 4; i++) data[i + 4] = type.charCodeAt(i);
    return data;
}
test('MSE recording keeps initialization and bounded preroll, then ordered native chunks', async () => {
    const {context:c, messages} = fixture();
    const source = new c.MediaSource();
    const buffer = source.addSourceBuffer('video/mp4; codecs="avc1.42E01E"');
    const url = c.URL.createObjectURL(source);
    buffer.appendBuffer(box('ftyp'));
    for (let i = 0; i < 10; i++) buffer.appendBuffer(box('moof'));
    await c.__DTMSE.start(url, 'native-id');
    buffer.appendBuffer(box('moof', 300000));
    await c.__DTMSE.stop('native-id');
    const chunks = messages.filter(m => m.type === 'blob-chunk');
    assert.equal(chunks.length, 7);
    assert.deepEqual(chunks.map(m => m.sequence), [0,1,2,3,4,5,6]);
    assert.ok(chunks.every(m => Buffer.from(m.data,'base64').length <= 256*1024));
    assert.equal(messages.at(-1).type, 'blob-end');
    buffer.appendBuffer(box('moof'));
    assert.equal(messages.length, 8);
});
test('unknown blobs and missing initialization report recoverable errors', async () => {
    const {context:c, messages} = fixture();
    assert.equal(await c.__DTMSE.start('blob:unknown','id'), false);
    const source = new c.MediaSource();
    source.addSourceBuffer('video/mp4').appendBuffer(box('moof'));
    assert.equal(await c.__DTMSE.start(c.URL.createObjectURL(source),'id2'), false);
    assert.equal(messages.filter(m => m.type === 'blob-error').length, 2);
});
test('revoked object URLs are removed from capture lookup', async () => {
    const {context:c, messages} = fixture();
    const url = c.URL.createObjectURL(new c.MediaSource());
    c.URL.revokeObjectURL(url);
    await c.__DTMSE.start(url, 'id');
    assert.equal(messages[0].type, 'blob-error');
});
