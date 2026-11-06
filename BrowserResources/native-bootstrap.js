(function () {
    "use strict";
    if (window.top !== window || !/^https?:$/.test(location.protocol)) {
        return;
    }
    let serial = 0;
    const waiting = new Map();
    globalThis.devtoolsMedia = {
        postMessage(raw) {
            const id = `${Date.now()}-${serial++}`;
            return new Promise((resolve, reject) => {
                const timer = setTimeout(() => { waiting.delete(id); reject(new Error("Native media bridge timed out.")); }, 10000);
                waiting.set(id, { resolve, reject, timer });
                window.postMessage({channel:"devtools-media-request", id, payload:JSON.parse(raw)}, "*");
            });
        }
    };
    addEventListener("message", (event) => {
        if (event.source !== window || event.data?.channel !== "devtools-media-reply") {
            return;
        }
        const record = waiting.get(event.data.id);
        if (!record) {
            return;
        }
        waiting.delete(event.data.id);
        clearTimeout(record.timer);
        event.data.error ? record.reject(new Error(event.data.error)) : record.resolve(event.data.result);
    });
    __MSE__
    __RULES__
    __USER_SCRIPTS__
    __RUNTIME__
    let config = __CONFIG__;
    // Register before page scripts. Preserve browser defaults for inspection gestures.
    addEventListener("contextmenu",event=>{
        if(config.enabled)event.stopImmediatePropagation();
    },{capture:true});
    addEventListener("keydown",event=>{
        if(!config.enabled)return;
        const key=event.key.toLowerCase();
        const inspect=key==="f12" || ((event.ctrlKey||event.metaKey) && (event.shiftKey||event.altKey) && ["i","j","c"].includes(key));
        if(inspect)event.stopImmediatePropagation();
    },{capture:true});
    let current = "";
    let generation = 0;
    let hasMedia = false;
    const ruleSource = __RULE_SOURCE__;
    function load() {
        globalThis.__DTExpectedURL = location.href;
        __ASSETS__
        __SOURCE_FORMAT__
    }
    function decide(url) {
        const hasRegex = config.enabled && (config.lists || []).some(list => list.selected && list.rules.some(rule => rule.enabled && rule.kind === "regex"));
        if (!hasRegex) {
            return Promise.resolve(DevToolsRules.evaluate(config, url));
        }
        return new Promise(resolve => {
            let worker, deadline, blob;
            let done = false;
            function finish(value) {
                if (done) {
                    return;
                }
                done = true;
                clearTimeout(deadline);
                worker?.terminate();
                if (blob) {
                    URL.revokeObjectURL(blob);
                }
                resolve(value);
            }
            try {
                blob = URL.createObjectURL(new Blob([ruleSource, "onmessage=e=>postMessage(DevToolsRules.evaluate(e.data.config,e.data.url));"], {type:"text/javascript"}));
                worker = new Worker(blob);
                worker.onmessage = event => finish(event.data);
                worker.onerror = () => finish({run:false, reason:"Regex worker unavailable; excluded."});
                deadline = setTimeout(() => finish({run:false, reason:"Rule matching timed out; excluded."}), 750);
                worker.postMessage({config,url});
            } catch {
                finish({run:false, reason:"Site policy blocks the regex worker; excluded."});
            }
        });
    }
    async function apply(command = "") {
        const token = ++generation, url = location.href;
        if (current && current !== url) {
            __DevToolsRuntime.stop();
            devtoolsMedia.postMessage(JSON.stringify({type:"leave"})).catch(() => {});
        }
        current = url;
        const decision = await decide(url);
        if (token !== generation || url !== location.href) {
            return;
        }
        try {
            if (decision.run) {
                load();
            }
            globalThis.__DTMedia?.setEnabled(decision.run);
            globalThis.__DTNativeStatus = {...decision, ...(await __DevToolsRuntime.apply(config,decision,command,url))};
            if (decision.run) {
                __DTUserscripts.start((config.plugins || []).filter(plugin => plugin.kind === "userscript"));
                if (!hasMedia) {
                    hasMedia = true;
                    __MEDIA__
                }
            }
        } catch (error) {
            globalThis.__DTNativeStatus = {run:false,reason:error.message,error:true};
        }
    }
    globalThis.__DTNativeUpdate = function (next, action) {
        config = next;
        apply(action || "");
    };
    function begin() {
        apply();
        setInterval(() => { if (location.href !== current) { apply(); } }, 500);
    }
    if (document.head) {
        begin();
    } else {
        const observer = new MutationObserver(() => {
            if (document.head) {
                observer.disconnect();
                begin();
            }
        });
        observer.observe(document, {childList:true,subtree:true});
    }
})();
