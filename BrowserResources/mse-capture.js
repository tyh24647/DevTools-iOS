/* Capture media containers and user-selected live MediaStreams. */
(function () {
    "use strict";
    if (globalThis.__DTMSE || window.top !== window) {
        return;
    }
    const sources = new Map(), active = new Map();
    const originalURL = URL.createObjectURL;
    const originalRevoke = URL.revokeObjectURL;
    const constructors = [...new Set([globalThis.MediaSource,globalThis.ManagedMediaSource].filter(Boolean))];
    const isSource = object => constructors.some(Type => object instanceof Type);
    const isStream = object => typeof globalThis.MediaStream === "function" && object instanceof MediaStream;
    const objectURLs = new WeakMap(), streamVideos = new WeakMap();
    let nextTrack = 0;
    function bytes(value) {
        return value instanceof ArrayBuffer ? new Uint8Array(value).slice() :
            new Uint8Array(value.buffer, value.byteOffset, value.byteLength).slice();
    }
    function base64(value) {
        let string = "";
        for (let at = 0; at < value.length; at += 8192) {
            string += String.fromCharCode(...value.subarray(at, at + 8192));
        }
        return btoa(string);
    }
    function send(record, track, data) {
        if (record.stopping) {
            return;
        }
        record.queued += data.length;
        if (record.queued > 16 * 1024 * 1024) {
            record.stopping = true;
            if (record.recorder?.state === "recording") record.recorder.stop();
            record.queue = record.queue.catch(() => {}).then(() => globalThis.devtoolsMedia.postMessage(JSON.stringify({
                type: "blob-error", recording: record.id, reason: "Media ingress exceeded the 16 MB queue; captured data is preserved."
            })));
            return;
        }
        record.queue = record.queue.then(async () => {
            const stream = record.tracks.indexOf(track);
            for (let at = 0; at < data.length; at += 256 * 1024) {
                const chunk = data.subarray(at, at + 256 * 1024);
                await globalThis.devtoolsMedia.postMessage(JSON.stringify({
                    type: "blob-chunk", recording: record.id, stream, sequence: record.sequences[stream]++,
                    mime: track.mime, data: base64(chunk)
                }));
            }
            record.queued -= data.length;
        }).catch((error) => {
            record.stopping = true;
            if (record.recorder?.state === "recording") record.recorder.stop();
            return globalThis.devtoolsMedia.postMessage(JSON.stringify({type: "blob-error", recording: record.id, reason: error.message})).catch(() => {});
        });
    }
    async function startStream(source, id) {
        const report = reason => globalThis.devtoolsMedia.postMessage(JSON.stringify({type: "blob-error", recording: id, reason}));
        if (typeof globalThis.MediaRecorder !== "function") {
            await report("Live MediaStream recording is unavailable in this browser.");
            return false;
        }
        if (!source.getVideoTracks().some(track => track.readyState === "live")) {
            await report("This video stream has ended. Start playback before recording.");
            return false;
        }
        const liveTracks = source.getVideoTracks().filter(track => track.readyState === "live");
        if (liveTracks.every(track => track.enabled === false)) {
            await report("The page has disabled its video track. Start the live video in the webpage before recording.");
            return false;
        }
        if (liveTracks.every(track => track.muted === true)) {
            await report("The live video track is not receiving picture data yet. Wait for playback, then try again.");
            return false;
        }
        const video = streamVideos.get(source);
        if (video && (video.readyState < 2 || !video.videoWidth || !video.videoHeight)) {
            await report("The player has not decoded a video frame yet. Start playback and wait for the picture before recording.");
            return false;
        }
        const mime = ["video/mp4", "video/webm;codecs=vp8,opus", "video/webm"].find(type => MediaRecorder.isTypeSupported(type));
        if (!mime) {
            await report("This browser cannot record the stream as MP4 or WebM.");
            return false;
        }
        let recorder;
        try { recorder = new MediaRecorder(source, {mimeType: mime}); }
        catch (error) { await report("Could not record this live stream: " + error.message); return false; }
        const track = {mime: recorder.mimeType || mime};
        const record = {id, source, tracks: [track], sequences: [0], queue: Promise.resolve(), queued: 0,
            stopping: false, recorder, intake: Promise.resolve(), pending: 0, failure: null};
        let resolveStop;
        record.done = new Promise(resolve => { resolveStop = resolve; });
        const fail = reason => {
            record.failure ||= reason;
            if (recorder.state !== "inactive") recorder.stop();
        };
        recorder.ondataavailable = event => {
            if (!event.data.size || record.failure) return;
            if (record.pending + event.data.size > 16 * 1024 * 1024) {
                fail("Live recording exceeded the 16 MB queue; captured data is preserved.");
                return;
            }
            record.pending += event.data.size;
            // Serialize Blob reads too: the final data event must reach native storage before blob-end.
            record.intake = record.intake.then(async () => {
                for (let at = 0; at < event.data.size && !record.stopping; at += 256 * 1024) {
                    const data = new Uint8Array(await event.data.slice(at, at + 256 * 1024).arrayBuffer());
                    send(record, track, data);
                    await record.queue;
                }
            }).catch(error => fail("Live recording failed: " + error.message))
                .finally(() => { record.pending -= event.data.size; });
        };
        recorder.onerror = event => fail("Live recorder failed: " + (event.error?.message || "unknown encoding error"));
        recorder.onstop = async () => {
            try {
                await record.intake;
                await record.queue;
                record.stopping = true;
                await globalThis.devtoolsMedia.postMessage(JSON.stringify({type: record.failure ? "blob-error" : "blob-end",
                    recording: id, reason: record.failure || "Live stream recording stopped"}));
            } catch { /* Native ingress may already have closed after a navigation/error. */ }
            finally { active.delete(id); resolveStop(true); }
        };
        active.set(id, record);
        try { recorder.start(1000); }
        catch (error) { active.delete(id); resolveStop(true); await report("Could not start live recording: " + error.message); return false; }
        // The player owns its tracks. Stopping the recorder must never stop those tracks.
        return true;
    }
    for (const Type of constructors) {
        const originalAdd = Type.prototype.addSourceBuffer;
        if (!originalAdd) continue;
        Type.prototype.addSourceBuffer = function (mime) {
            const buffer = originalAdd.call(this, mime);
            try {
            if(buffer.__dtCaptured)return buffer;
            buffer.__dtCaptured=true;
            const track = { source: this, mime, id: nextTrack++, initialization: null, recent: [] };
            const originalAppend = buffer.appendBuffer;
            buffer.appendBuffer = function (value) {
                const result = originalAppend.call(this, value);
                try {
                const data = bytes(value);
                const box = data.length >= 8 ? String.fromCharCode(...data.subarray(4, 8)) : "";
                if (!track.initialization && (box === "ftyp" || box === "moov" || /webm/i.test(mime))) {
                    if (data.length <= 2 * 1024 * 1024) {
                        track.initialization = data;
                    }
                } else {
                    track.recent.push(data);
                    while (track.recent.length > 4 || track.recent.reduce((sum, value) => sum + value.length, 0) > 2 * 1024 * 1024) {
                        track.recent.shift();
                    }
                }
                for (const record of active.values()) {
                    if (record.source === track.source) {
                        if (!record.tracks.includes(track)) {
                            record.tracks.push(track);
                            record.sequences.push(0);
                        }
                        send(record, track, data);
                    }
                }
                } catch(error) {
                    for(const record of active.values()) if(record.source===track.source) {
                        globalThis.devtoolsMedia?.postMessage(JSON.stringify({type:"blob-error",recording:record.id,reason:"Capture failed; webpage playback was preserved: "+error.message})).catch(()=>{});
                    }
                }
                return result;
            };
            this.__dtTracks ||= [];
            this.__dtTracks.push(track);
            } catch {}
            return buffer;
        };
    }
    URL.createObjectURL = function (object) {
        const url = originalURL.call(this, object);
        if (isSource(object)) {
            sources.set(url, object);
        } else if (object instanceof Blob && /^(video|audio)\/(mp4|webm)/i.test(object.type)) {
            sources.set(url, object);
        }
        return url;
    };
    URL.revokeObjectURL = function (url) {
        sources.delete(url);
        return originalRevoke.call(this, url);
    };
    globalThis.__DTMSE = {
        sourceURL(video) {
            const source=video.srcObject;
            if(!source || (!isSource(source) && !isStream(source)))return null;
            if(isStream(source) && !video.closest?.("#eruda,dialog[data-devtools-preview]"))streamVideos.set(source,video);
            if(!objectURLs.has(source)) {const url="blob:devtools-source-"+nextTrack++;objectURLs.set(source,url);sources.set(url,source);}
            return objectURLs.get(source);
        },
        videoForURL(url) { return streamVideos.get(sources.get(url)) || null; },
        streamForURL(url) { const source = sources.get(url); return isStream(source) ? source : null; },
        async start(url, id) {
            const source = sources.get(url);
            if (!source) {
                await globalThis.devtoolsMedia.postMessage(JSON.stringify({type: "blob-error", recording: id,
                    reason: "This player has not exposed a supported media container or live MediaStream. DRM and opaque socket protocols cannot be converted generically."}));
                return false;
            }
            if (isStream(source)) return startStream(source, id);
            const tracks = source.__dtTracks || [{ mime: source.type, source }];
            const record = { id, source, tracks: [...tracks], sequences: tracks.map(() => 0), queue: Promise.resolve(), queued: 0, stopping: false };
            active.set(id, record);
            if (source instanceof Blob) {
                const reader = source.stream().getReader();
                while (!record.stopping) {
                    const chunk = await reader.read();
                    if (chunk.done) {
                        break;
                    }
                    send(record, tracks[0], chunk.value);
                    await record.queue;
                }
                await this.stop(id);
            } else {
                for (const track of tracks) {
                    if (!track.initialization) {
                        await globalThis.devtoolsMedia.postMessage(JSON.stringify({type: "blob-error", recording: id, reason: "No bounded media initialization header was captured. Reload the video, then record again."}));
                        active.delete(id);
                        return false;
                    }
                    send(record, track, track.initialization);
                    for (const chunk of track.recent) {
                        send(record, track, chunk);
                    }
                }
                await record.queue;
            }
            return true;
        },
        async stop(id) {
            const record = active.get(id);
            if (!record) {
                return true;
            }
            if (record.recorder) {
                if (record.recorder.state !== "inactive") record.recorder.stop();
                return record.done;
            }
            record.stopping = true;
            await record.queue;
            await globalThis.devtoolsMedia.postMessage(JSON.stringify({type: "blob-end", recording: id, reason: "Media source stopped"}));
            active.delete(id);
            return true;
        }
    };
})();
