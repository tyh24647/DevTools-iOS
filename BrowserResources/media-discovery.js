// Isolated, passive request observation: never replaces player or network methods.
(() => {
    if(!/^https?:$/.test(location.protocol))return;
    const seen=new Set(),metadata=new Map();
    let lastReport="",observing=false;
    function inspect(raw,video=null) {
        if(typeof raw!=="string"||!raw.trim())return;
        let url;try{url=new URL(raw,location.href);}catch{return;}
        if(!/^https?:$/.test(url.protocol)||url.username||url.password||url.href===location.href)return;
        const hls=/\.m3u8(?:[?#&]|$)/i.test(url.href);
        if(!hls&&!/\.(mp4|mov|m4v|webm)(?:[?#&]|$)/i.test(url.href))return;
        const duration=video&&Number.isFinite(video.duration)&&video.duration>0?video.duration:null;
        if((seen.has(url.href)&&(!duration||metadata.get(url.href)===duration))||seen.size>=200)return;
        seen.add(url.href);if(duration)metadata.set(url.href,duration);
        globalThis.webkit?.messageHandlers?.dtMedia?.postMessage({type:"media-discovery",url:url.href,page:location.href,hls,duration,title:document.title.slice(0,160)}).catch(()=>{});
    }
    function scan() {
        for(const entry of performance.getEntriesByType("resource"))inspect(entry.name);
        for(const video of document.querySelectorAll("video,video source"))inspect(video.currentSrc||video.src,video);
        const videos=[...document.querySelectorAll("video")].slice(0,10);
        const players=videos.map((video,index)=>{
            const src=video.currentSrc||video.src;
            const kind=video.srcObject?String(video.srcObject.constructor?.name||"srcObject"):src?.startsWith("blob:")?"buffer/blob":src?.startsWith("http")?"URL":"no source";
            const tracks=video.srcObject?.getTracks?.().map(track=>`${track.kind}: ${track.readyState}, enabled ${track.enabled}, muted ${track.muted}`).join("; ")||"";
            return `Video ${index+1}: ${kind}; ready ${video.readyState}/4; error ${video.error?.code||0}; ${video.paused?"paused":"playing"}; pixels ${video.videoWidth}×${video.videoHeight}; ${tracks}`;
        });
        const summary=`Observer ${observing?"active":"polling"}; ${performance.getEntriesByType("resource").length} resource requests; ${seen.size} media URLs.\n${players.join("\n")}`;
        if(summary!==lastReport){
            lastReport=summary;
            globalThis.webkit?.messageHandlers?.dtMedia?.postMessage({type:"media-diagnostics",summary}).catch(()=>{});
        }
    }
    const observer=new PerformanceObserver(list=>{for(const entry of list.getEntries())inspect(entry.name);});
    try{observer.observe({type:"resource",buffered:true});observing=true;}catch{}
    const timer=setInterval(scan,1000);
    addEventListener("pagehide",()=>{observer.disconnect();clearInterval(timer);},{once:true});
    scan();
})();
