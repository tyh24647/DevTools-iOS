(function () {
    "use strict";
    if(globalThis.__DTMedia || window.top!==window || !/^https?:$/.test(location.protocol)) return;
    const entries=new Map(), videoButtons=new Map();
    let enabled=true;
    let buttonPosition = null;
    let positionRevision = 0;

    // Store normalized viewport coordinates in the app so they survive navigation.
    function placeButton(button, x, y) {
        const width = Math.max(0, innerWidth - 56);
        const height = Math.max(0, innerHeight - 56);
        button.style.left = (4 + Math.max(0, Math.min(1, x)) * width) + "px";
        button.style.top = (4 + Math.max(0, Math.min(1, y)) * height) + "px";
    }

    function saveButtonPosition(button, left, top) {
        buttonPosition = {
            x: Math.max(0, Math.min(1, (left - 4) / Math.max(1, innerWidth - 56))),
            y: Math.max(0, Math.min(1, (top - 4) / Math.max(1, innerHeight - 56)))
        };
        positionRevision++;
        placeButton(button, buttonPosition.x, buttonPosition.y);
    }

    function persistButtonPosition() {
        try {
            globalThis.devtoolsMedia?.postMessage(JSON.stringify({type: "download-button-position-save", ...buttonPosition}))?.catch(() => {});
        } catch {}
    }

    function enableButtonDragging(record) {
        const button = record.button;
        let gesture = null;
        let suppressClick = false;
        button.style.touchAction = "none";
        button.style.webkitUserSelect = "none";
        button.style.userSelect = "none";
        button.style.webkitTouchCallout = "none";
        button.style.cursor = "grab";
        button.addEventListener("contextmenu", event => event.preventDefault());
        button.addEventListener("pointerdown", event => {
            if (!event.isPrimary || event.button !== 0 || gesture) return;
            suppressClick = false;
            const rect = button.getBoundingClientRect();
            const current = gesture = {id: event.pointerId, x: event.clientX, y: event.clientY,
                offsetX: event.clientX - rect.left, offsetY: event.clientY - rect.top, active: false};
            button.setPointerCapture(event.pointerId);
            current.timer = setTimeout(() => {
                if (gesture !== current) return;
                current.active = true;
                record.dragging = true;
                suppressClick = true;
                button.style.cursor = "grabbing";
                button.style.boxShadow = "0 0 0 4px rgba(115,68,181,.35)";
            }, 1000);
        });
        button.addEventListener("pointermove", event => {
            if (!gesture || gesture.id !== event.pointerId) return;
            if (!gesture.active) {
                if (Math.hypot(event.clientX - gesture.x, event.clientY - gesture.y) > 8) {
                    clearTimeout(gesture.timer);
                    suppressClick = true;
                }
                return;
            }
            event.preventDefault();
            saveButtonPosition(button, event.clientX - gesture.offsetX, event.clientY - gesture.offsetY);
        });
        function finish(event) {
            if (!gesture || gesture.id !== event.pointerId) return;
            clearTimeout(gesture.timer);
            if (gesture.active && buttonPosition) persistButtonPosition();
            gesture = null;
            record.dragging = false;
            button.style.cursor = "grab";
            button.style.boxShadow = "";
        }
        button.addEventListener("pointerup", finish);
        button.addEventListener("pointercancel", finish);
        button.addEventListener("lostpointercapture", finish);
        button.addEventListener("click", event => {
            if (!suppressClick) return;
            suppressClick = false;
            event.preventDefault();
            event.stopImmediatePropagation();
        }, true);
        button.addEventListener("keydown", event => {
            const offsets = {ArrowLeft: [-15, 0], ArrowRight: [15, 0], ArrowUp: [0, -15], ArrowDown: [0, 15]};
            const offset = offsets[event.key];
            if (!offset) return;
            event.preventDefault();
            const rect = button.getBoundingClientRect();
            saveButtonPosition(button, rect.left + offset[0], rect.top + offset[1]);
            persistButtonPosition();
        });
        record.cancelDrag = () => {
            if (gesture) finish({pointerId: gesture.id});
        };
    }

    function message(type,url) {
        try {globalThis.devtoolsMedia?.postMessage(JSON.stringify({type,url,title:document.title.slice(0,160),hls:entries.get(url)?.hls||false,mime:entries.get(url)?.mime||""}))?.catch(()=>{});}catch{}
    }
    function normalized(raw) {if(typeof raw!=="string" || !raw.trim())return null;try {const url=new URL(raw,location.href);const page=new URL(location.href);url.hash="";page.hash="";return (/^(https?:|blob:)$/.test(url.protocol) && url.href!==page.href)?url.href:null;}catch{return null;}}
    function isMedia(url) {return /\.(m3u8|mp4|webm|m4v|mov|mkv|mp3|m4a|wav|ogg|png|jpe?g|gif|webp|avif)(?:[?#]|$)/i.test(url);}
    function add(raw,force=false,hls=false,mime="") {
        const url=normalized(raw);if(!url || (!force && !isMedia(url)))return;
        if(entries.has(url)){const entry=entries.get(url);if(mime)entry.mime=mime;if(hls)entry.hls=true;return;}
        if(entries.size>=200)entries.delete(entries.keys().next().value);
        entries.set(url,{url,status:"",progress:null,mime,hls:hls||/\.m3u8(?:[?#]|$)/i.test(url)});

    }
    function request(url) {
        const entry=entries.get(url);if(!entry)return;
        if(entry.busy && entry.live && entry.canStop !== false)message("stop",url);
        else if(!entry.busy)message("save",url);
    }
    function mediaType(url) {
        const entry=entries.get(url);
        if(entry?.mime.startsWith("image/") || /\.(png|jpe?g|gif|webp|avif|svg|bmp)(?:[?#]|$)/i.test(url))return "img";
        if(entry?.mime.startsWith("audio/") || /\.(mp3|m4a|wav|ogg)(?:[?#]|$)/i.test(url))return "audio";
        return "video";
    }
    function preview(url) {
        const dialog=document.createElement("dialog");dialog.dataset.devtoolsPreview="";
        dialog.style.cssText="max-width:min(90vw,640px);width:90vw;border:0;border-radius:16px;padding:20px;z-index:2147483647";
        const media=document.createElement(mediaType(url));
        media.style.cssText="width:100%;max-height:50vh;object-fit:contain";
        if(media.tagName!=="IMG"){media.controls=true;media.preload="metadata";if(media.tagName==="VIDEO"){media.width=480;media.height=270;}}
        const stream=globalThis.__DTMSE?.streamForURL(url);
        if(stream){media.srcObject=stream;media.muted=true;media.playsInline=true;}else media.src=url;
        const status=document.createElement("p");status.textContent=entries.get(url)?.status || "Resource preview";
        const save=document.createElement("button");save.textContent=media.tagName==="VIDEO"?"Save / start recording":"Save resource";save.style.minHeight="44px";save.onclick=()=>{request(url);dialog.close();};
        const share=document.createElement("button");share.textContent="Share";share.style.minHeight="44px";share.onclick=async()=>{
            try{if(globalThis.devtoolsMedia){message("share",url);return;}if(navigator.share)await navigator.share({title:document.title,url});else {await navigator.clipboard.writeText(url);status.textContent="Link copied.";}}catch(error){status.textContent=error.message;}
        };
        const close=document.createElement("button");close.textContent="Close";close.style.minHeight="44px";close.onclick=()=>dialog.close();
        dialog.append(media,status,save,share,close);document.body.append(dialog);
        dialog.addEventListener("close",()=>{if(media.tagName!=="IMG"){media.pause();media.srcObject=null;media.removeAttribute("src");media.load();}dialog.remove();});
        dialog.showModal();
        if(stream)media.play().catch(error=>{status.textContent="Live preview could not start: "+error.message;});
    }
    function resourceSection() {
        const resources=globalThis.__DTAssets?.eruda?.get("resources");
        const root=resources?._$el?.get?.(0) || resources?._$el?.[0];
        if(!root || !entries.size)return;
        let section=root.querySelector("[data-devtools-videos]");
        if(!section) {
            section=document.createElement("section");section.dataset.devtoolsVideos="";section.style.cssText="padding:12px;display:grid;gap:8px;background:transparent";
            const heading=document.createElement("h2");heading.textContent="Video and audio";
            section.append(heading);
            const images=root.querySelector(".eruda-image");
            if(images)root.insertBefore(section,images);else root.append(section);
        }
        for(const image of root.querySelectorAll(".eruda-image img")) {
            if("devtoolsSave" in image.dataset)continue;
            image.dataset.devtoolsSave="";
            image.addEventListener("click",event=>{const url=normalized(image.currentSrc||image.src);if(url){event.preventDefault();event.stopImmediatePropagation();add(url,true,false,"image/unknown");preview(url);}},{capture:true});
        }
        const playable=[...entries].filter(([url])=>mediaType(url)!=="img");
        section.hidden=playable.length===0;
        for(const row of section.querySelectorAll("[data-media-url]"))if(mediaType(row.dataset.mediaUrl)==="img" || !entries.has(row.dataset.mediaUrl))row.remove();
        for(const [url,entry] of playable) {
            let row=[...section.querySelectorAll("[data-media-url]")].find(node=>node.dataset.mediaUrl===url);
            if(!row) {
                row=document.createElement("div");row.dataset.mediaUrl=url;
                const button=document.createElement("button");button.style.cssText="min-height:44px;max-width:100%;overflow-wrap:anywhere;background:transparent;border:0;padding:0;color:inherit;text-align:left";button.onclick=()=>preview(url);
                const liveVideo=globalThis.__DTMSE?.videoForURL(url);
                const video=document.createElement(liveVideo?"canvas":mediaType(url));if(video.tagName!=="IMG")video.preload="metadata";video.width=160;video.height=90;if(video.tagName==="IMG")video.alt="Image resource";
                video.style.cssText="display:block;width:160px;height:90px;object-fit:contain;background:transparent";if(!liveVideo)video.src=url;
                const label=document.createElement("span");button.append(video,label);
                row.append(button);section.append(row);
            }
            const button=row.firstElementChild;
            const thumbnail=button.querySelector("canvas"), liveVideo=globalThis.__DTMSE?.videoForURL(url);
            if(thumbnail && liveVideo?.readyState>=2 && liveVideo.videoWidth) {
                try{thumbnail.getContext("2d").drawImage(liveVideo,0,0,thumbnail.width,thumbnail.height);}catch{}
            }
            button.querySelector("span").textContent=(entry.status?entry.status+" · ":"")+url.split("/").pop().slice(0,100);
        }
    }
    function scan() {
        if (!enabled) {
            for (const record of videoButtons.values()) record.button.hidden=true;
            return;
        }
        for(const entry of performance.getEntriesByType("resource"))add(entry.name);
        for(const node of document.querySelectorAll("video,audio,video source,audio source,img")) {
            if(node.closest("#eruda,dialog[data-devtools-preview]"))continue;
            const raw=node.currentSrc||node.src;add(raw,true,false,node.tagName==="IMG"?"image/unknown":node.tagName==="AUDIO"?"audio/unknown":"video/unknown");
        }
        for(const video of document.querySelectorAll("video")) {
            if(video.closest("#eruda,dialog[data-devtools-preview]"))continue;
            const src=normalized(video.currentSrc||video.src)||globalThis.__DTMSE?.sourceURL(video);
            if(src && globalThis.__DTMSE?.streamForURL(src))add(src,true,false,"video/mediastream");
            let record=videoButtons.get(video);
            if(!record) {
                const button=document.createElement("button");button.type="button";button.setAttribute("aria-label","Download or record this video");
                button.style.cssText="position:fixed;z-index:2147483646;width:48px;height:48px;border-radius:50%;background:#7344b5;color:white;border:0;padding:5px;display:grid;place-items:center;font:22px system-ui";
                const ring=document.createElement("span");ring.dataset.devtoolsProgressRing="";ring.setAttribute("aria-hidden","true");
                ring.style.cssText="position:absolute;inset:0;border-radius:50%;pointer-events:none;mask-image:radial-gradient(transparent 60%,black 62%)";
                const icon=document.createElement("span");icon.dataset.devtoolsMediaIcon="";icon.setAttribute("aria-hidden","true");
                const progress=document.createElement("progress");progress.max=1;progress.setAttribute("aria-label","Video download progress");
                progress.style.cssText="position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);pointer-events:none";
                button.append(ring,icon,progress);
                button.onclick=()=>{
                    const current=normalized(video.currentSrc||video.src)||globalThis.__DTMSE?.sourceURL(video);
                    const candidates=[...entries.values()].filter(entry=>entry.hls||entry.mime.startsWith("video/"));
                    const url=current || (candidates.length===1?candidates[0].url:null);
                    if(url){record.url=url;add(url,true);request(url);}
                    else globalThis.devtoolsMedia?.postMessage(JSON.stringify({type:"media-unavailable",reason:candidates.length>1?"Several media resources were detected. Select the correct video in the Resources panel.":"This player has not exposed a supported media source yet. Start playback, then try again."})).catch(()=>{});
                };
                record={button,url:src};enableButtonDragging(record);videoButtons.set(video,record);document.documentElement.append(button);
                video.addEventListener("emptied",()=>message("unload",record.url));
                video.addEventListener("ended",()=>message("unload",record.url));
            }
            if(src && record.url!==src){if(record.url)message("unload",record.url);record.url=src;}
            const rect=video.getBoundingClientRect(),visible=rect.width>0&&rect.height>0&&rect.bottom>0&&rect.top<innerHeight&&rect.right>0&&rect.left<innerWidth;
            record.button.hidden=!visible;
            if (!record.dragging && buttonPosition) {
                placeButton(record.button, buttonPosition.x, buttonPosition.y);
            } else if (!record.dragging) {
                record.button.style.left=Math.max(4,Math.min(innerWidth-48,rect.right-108))+"px";
                record.button.style.top=Math.max(4,Math.min(innerHeight-48,rect.top+4))+"px";
            }
            const entry=entries.get(src);
            const completed=entry?.status==="Saved";
            const live=!!entry?.busy && !!entry?.live;
            const stopping=live && entry.canStop===false;
            const fraction=completed?1:Number.isFinite(entry?.progress)?Math.max(0,Math.min(entry.busy?0.99:1,entry.progress)):null;
            record.button.querySelector("[data-devtools-media-icon]").textContent=completed?"✓":live?(stopping?"…":"■"):entry?.busy?"↓":"↓";
            record.button.disabled=!!entry?.busy && (!live || stopping);
            const label=live?(stopping?"Finalizing recording":"Stop recording"):completed?"Video saved":entry?.busy?(fraction===null?"Downloading video":`Downloading video: ${Math.round(fraction*100)}%`):"Download or record this video";
            record.button.setAttribute("aria-label",label);
            record.button.title=entry?.status||label;
            const progress=record.button.querySelector("progress");progress.hidden=live||(!entry?.busy&&!completed);
            if(fraction===null)progress.removeAttribute("value");else progress.value=fraction;
            const ring=record.button.querySelector("[data-devtools-progress-ring]");
            const fill=completed?"#22c55e":live?"#ef4444":"#60a5fa";
            ring.style.background=live?fill:`conic-gradient(${fill} ${(fraction??0)*360}deg,rgba(255,255,255,.35) 0)`;
            record.button.style.animation="none";
        }
        for(const [video,record] of videoButtons)if(!video.isConnected){message("unload",record.url);record.cancelDrag();record.button.remove();videoButtons.delete(video);}
        resourceSection();
    }
    const style=document.createElement("style");style.textContent="@keyframes devtools-media-spin {to{transform:rotate(360deg)}}";document.documentElement.append(style);
    const timer=setInterval(scan,1000);
    addEventListener("pagehide",()=>{for(const url of entries.keys())message("unload",url);clearInterval(timer);for(const record of videoButtons.values()){record.cancelDrag();record.button.remove();}});
    globalThis.__DTMedia={
        setEnabled(value){enabled=!!value;scan();},
        add,
        status(url,status,progress,busy,live,canStop=busy){add(url,true);Object.assign(entries.get(url),{status,progress,busy,live,canStop});scan();},
        playableURL(){
            const videos=[...document.querySelectorAll("video")].filter(video=>!video.closest("#eruda,dialog[data-devtools-preview]"));
            const playing=videos.filter(video=>!video.paused && !video.ended);
            const selected=playing.length===1?playing[0]:videos.length===1?videos[0]:null;
            const url=selected?normalized(selected.currentSrc||selected.src):null;
            if(url?.startsWith("http"))return url;
            const candidates=[...entries.values()].filter(entry=>entry.hls||entry.mime.startsWith("video/"));
            return candidates.length===1 && candidates[0].url.startsWith("http")?candidates[0].url:null;
        },
        refresh:scan
    };
    addEventListener("resize", scan);
    // A late native reply must not overwrite a position the user has just moved.
    const initialRevision = positionRevision;
    try {
        globalThis.devtoolsMedia?.postMessage(JSON.stringify({type: "download-button-position-get"}))?.then(position => {
            if (positionRevision !== initialRevision || !Number.isFinite(position?.x) || !Number.isFinite(position?.y)) return;
            buttonPosition = {x: Math.max(0, Math.min(1, position.x)), y: Math.max(0, Math.min(1, position.y))};
            scan();
        }).catch(() => {});
    } catch {}
    scan();
})();
