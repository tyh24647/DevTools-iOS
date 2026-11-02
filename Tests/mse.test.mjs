import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync(new URL('../BrowserResources/mse-capture.js', import.meta.url), 'utf8');
function fixture(append = () => {}, extras = {}) {
    const messages = [];
    class MediaSource {
        addSourceBuffer() { return {appendBuffer: append}; }
    }
    class ManagedMediaSource extends MediaSource {}
    const context = vm.createContext({...extras, MediaSource, ManagedMediaSource, Blob, ArrayBuffer, Uint8Array, btoa,
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

test('capture inspection failure does not interrupt the player append operation', () => {
    let appended = 0;
    const {context:c} = fixture(() => { appended++; return 42; });
    const buffer = new c.ManagedMediaSource().addSourceBuffer('video/mp4');
    const opaque = {get buffer() {throw new Error('Not readable by capture');}};
    assert.equal(buffer.appendBuffer(opaque),42);
    assert.equal(appended,1);
});
test('player append errors retain their original behavior', () => {
    const expected = new Error('Original player failure');
    const {context:c} = fixture(() => {throw expected;});
    const buffer = new c.ManagedMediaSource().addSourceBuffer('video/mp4');
    assert.throws(()=>buffer.appendBuffer(box('ftyp')),error=>error===expected);
});


function liveFixture({supported = 'video/mp4', recorderAvailable = true, state = 'live', enabled = true, muted = false, ready = 4} = {}) {
    const video = {kind: 'video', readyState: state, enabled, muted, stop() { throw new Error('Player track must stay alive'); }};
    class MediaStream {
        getVideoTracks() { return [video]; }
        getTracks() { return [video]; }
    }
    class MediaRecorder {
        static instances = [];
        static isTypeSupported(type) { return type === supported; }
        constructor(stream, options) { this.stream = stream; this.mimeType = options.mimeType; this.state = 'inactive'; MediaRecorder.instances.push(this); }
        start(timeslice) { this.state = 'recording'; this.timeslice = timeslice; }
        stop() {
            this.state = 'inactive';
            queueMicrotask(() => {
                this.ondataavailable({data: new Blob(['final'])});
                this.onstop();
            });
        }
    }
    const result = fixture(() => {}, {MediaStream, ...(recorderAvailable ? {MediaRecorder} : {})});
    const stream = new MediaStream();
    const url = result.context.__DTMSE.sourceURL({srcObject: stream, readyState: ready, videoWidth: 320, videoHeight: 180});
    return {...result, stream, url, video, MediaRecorder};
}
test('live MediaStream captures ordered chunks and final Stop bytes without stopping player tracks', async () => {
    const {context:c, messages, stream, url, video, MediaRecorder} = liveFixture();
    assert.equal(c.__DTMSE.sourceURL({srcObject:stream,readyState:4,videoWidth:320,videoHeight:180}),url);
    assert.equal(c.__DTMSE.streamForURL(url),stream);
    assert.equal(await c.__DTMSE.start(url,'live-id'),true);
    const recorder = MediaRecorder.instances[0];
    assert.equal(recorder.stream,stream);
    assert.equal(recorder.timeslice,1000);
    // A delayed first Blob read must not be overtaken by later data or Stop.
    let release;
    const delayed = new Blob(['first']);
    delayed.slice = () => ({arrayBuffer: () => new Promise(resolve => { release = () => resolve(new TextEncoder().encode('first').buffer); })});
    recorder.ondataavailable({data:delayed});
    recorder.ondataavailable({data:new Blob(['second'])});
    await Promise.resolve();
    const stopping = c.__DTMSE.stop('live-id');
    const repeated = c.__DTMSE.stop('live-id');
    assert.equal(messages.length,0);
    release();
    await Promise.all([stopping,repeated]);
    assert.deepEqual(messages.filter(m=>m.type==='blob-chunk').map(m=>m.sequence),[0,1,2]);
    assert.equal(messages.filter(m=>m.type==='blob-chunk').map(m=>Buffer.from(m.data,'base64').toString()).join(''),'firstsecondfinal');
    assert.equal(messages.at(-1).type,'blob-end');
    assert.equal(video.readyState,'live');
});
test('live capture feature detection, ended tracks, and WebM fallback', async () => {
    for (const options of [{recorderAvailable:false},{supported:null},{state:'ended'}]) {
        const {context:c,messages,url} = liveFixture(options);
        assert.equal(await c.__DTMSE.start(url,'unsupported'),false);
        assert.equal(messages.at(-1).type,'blob-error');
    }
    const {context:c,messages,url} = liveFixture({supported:'video/webm'});
    await c.__DTMSE.start(url,'fallback');
    await c.__DTMSE.stop('fallback');
    assert.equal(messages[0].mime,'video/webm');
});
test('oversized recorder data stops encoding and reports retained capture', async () => {
    const {context:c,messages,url,MediaRecorder} = liveFixture();
    await c.__DTMSE.start(url,'overflow');
    const recorder = MediaRecorder.instances[0];
    recorder.ondataavailable({data:{size:16*1024*1024+1}});
    await c.__DTMSE.stop('overflow');
    assert.equal(recorder.state,'inactive');
    assert.equal(messages.at(-1).type,'blob-error');
    assert.match(messages.at(-1).reason,/16 MB/);
});
test('natural recorder end flushes video and audio together as one container', async () => {
    const {context:c,messages,url,stream,MediaRecorder} = liveFixture();
    const audio = {kind:'audio',readyState:'live'};
    stream.getTracks = () => [...stream.getVideoTracks(),audio];
    await c.__DTMSE.start(url,'natural');
    const recorder = MediaRecorder.instances[0];
    assert.equal(recorder.stream.getTracks().length,2);
    recorder.ondataavailable({data:new Blob(['combined-container'])});
    recorder.stop();
    await c.__DTMSE.stop('natural');
    assert.ok(messages.filter(m=>m.type==='blob-chunk').every(m=>m.stream===0));
    assert.equal(messages.at(-1).type,'blob-end');
});

test('disabled, muted and undecoded video cannot start a misleading recording', async () => {
 for(const options of [{enabled:false},{muted:true},{ready:0}]) {
  const {context:c,messages,url,MediaRecorder}=liveFixture(options);
  assert.equal(await c.__DTMSE.start(url,'no-picture'),false);
  assert.equal(MediaRecorder.instances.length,0);
  assert.equal(messages.at(-1).type,'blob-error');
 }
});
