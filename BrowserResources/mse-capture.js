/* Capture decoded-container ingress, not arbitrary WebSocket application messages. */
(function () {
    "use strict";
    if (globalThis.__DTMSE || window.top !== window) {
        return;
    }
    const sources = new Map(), active = new Map();
    const originalURL = URL.createObjectURL;
    const originalRevoke = URL.revokeObjectURL;
    const originalAdd = globalThis.MediaSource?.prototype.addSourceBuffer;
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
            return globalThis.devtoolsMedia.postMessage(JSON.stringify({type: "blob-error", recording: record.id, reason: error.message})).catch(() => {});
        });
    }
    if (originalAdd) {
        MediaSource.prototype.addSourceBuffer = function (mime) {
            const buffer = originalAdd.call(this, mime);
            const track = { source: this, mime, id: nextTrack++, initialization: null, recent: [] };
            const originalAppend = buffer.appendBuffer;
            buffer.appendBuffer = function (value) {
                const data = bytes(value);
                const result = originalAppend.call(this, value);
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
                return result;
            };
            this.__dtTracks ||= [];
            this.__dtTracks.push(track);
            return buffer;
        };
    }
    URL.createObjectURL = function (object) {
        const url = originalURL.call(this, object);
        if (globalThis.MediaSource && object instanceof MediaSource) {
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
        async start(url, id) {
            const source = sources.get(url);
            if (!source) {
                await globalThis.devtoolsMedia.postMessage(JSON.stringify({type: "blob-error", recording: id,
                    reason: "This blob was not created by a supported MP4/WebM media source. WebRTC, DRM and opaque socket protocols cannot be converted generically."}));
                return false;
            }
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
            record.stopping = true;
            await record.queue;
            await globalThis.devtoolsMedia.postMessage(JSON.stringify({type: "blob-end", recording: id, reason: "Media source stopped"}));
            active.delete(id);
            return true;
        }
    };
})();
