/* Safari hands HTTP(S) media to the native browser; it cannot transfer page cookies or blobs. */
(function () {
    "use strict";
    if (window.__DTMediaHandoff || window.top !== window) {
        return;
    }
    let timer;
    const buttons = new Map();
    function remove() {
        clearInterval(timer);
        for (const button of buttons.values()) {
            button.remove();
        }
        buttons.clear();
    }
    function scan() {
        if (!globalThis.__DevToolsRuntime?.isActive?.()) {
            // Runtime versions without isActive expose the injected Eruda object instead.
            if (!globalThis.__DTAssets?.eruda?.get?.("console")) {
                for (const button of buttons.values()) {
                    button.hidden = true;
                }
                return;
            }
        }
        for (const video of document.querySelectorAll("video")) {
            let button = buttons.get(video);
            if (!button) {
                button = document.createElement("button");
                button.textContent = "↓ Open in DevTools recorder";
                button.style.cssText = "position:fixed;z-index:2147483646;background:#1e1e2e;color:white;border:1px solid #888;border-radius:8px;padding:8px;font:12px sans-serif";
                button.addEventListener("click", () => {
                    const source = video.currentSrc || video.src;
                    if (!/^https?:\/\//i.test(source)) {
                        alert("Open this website in the DevTools browser to record its media buffers. Safari blob URLs and signed-in cookies cannot be transferred.");
                        return;
                    }
                    location.href = "devtools://record?url=" + encodeURIComponent(source);
                });
                document.documentElement.append(button);
                buttons.set(video, button);
            }
            const rect = video.getBoundingClientRect();
            button.hidden = !video.isConnected || rect.width < 120 || rect.height < 70 || rect.bottom < 0 || rect.top > innerHeight;
            button.style.left = Math.max(4, Math.min(innerWidth - 220, rect.left + 8)) + "px";
            button.style.top = Math.max(4, Math.min(innerHeight - 45, rect.bottom - 42)) + "px";
        }
        for (const [video, button] of buttons) {
            if (!video.isConnected) {
                button.remove();
                buttons.delete(video);
            }
        }
    }
    window.__DTMediaHandoff = { remove };
    timer = setInterval(scan, 1000);
    addEventListener("pagehide", remove, {once:true});
    scan();
})();
