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
        for (const entry of buttons.values()) {
            entry.container.remove();
        }
        buttons.clear();
    }
    function scan() {
        if (!globalThis.__DevToolsRuntime?.isActive?.()) {
            // Runtime versions without isActive expose the injected Eruda object instead.
            if (!globalThis.__DTAssets?.eruda?.get?.("console")) {
                for (const entry of buttons.values()) {
                    entry.container.hidden = true;
                }
                return;
            }
        }
        for (const video of document.querySelectorAll("video")) {
            let entry = buttons.get(video);
            if (!entry) {
                const container = document.createElement("div");
                container.style.cssText = "position:fixed;z-index:2147483646;display:flex;gap:6px;align-items:center";
                const makeButton = (label, handler) => {
                    const button = document.createElement("button");
                    button.textContent = label;
                    button.style.cssText = "background:#1e1e2e;color:white;border:1px solid #888;border-radius:8px;padding:8px;font:12px sans-serif";
                    button.addEventListener("click", handler);
                    container.append(button);
                    return button;
                };
                const download = makeButton("↓ Download to DevTools", () => {
                    const source = video.currentSrc || video.src;
                    if (!/^https?:\/\//i.test(source)) {
                        alert("This media uses a blob URL. Open the page in the DevTools browser to capture it.");
                        return;
                    }
                    const query = new URLSearchParams({url: source, page: location.href, title: document.title.slice(0, 160)});
                    location.href = "devtools://download?" + query.toString();
                });
                const record = makeButton("Open recorder", () => {
                    const source = video.currentSrc || video.src;
                    if (!/^https?:\/\//i.test(source)) {
                        alert("Open this website in the DevTools browser to record its media buffers. Safari blob URLs and signed-in cookies cannot be transferred.");
                        return;
                    }
                    location.href = "devtools://record?url=" + encodeURIComponent(source);
                });
                document.documentElement.append(container);
                entry = {container, download, record};
                buttons.set(video, entry);
            }
            const rect = video.getBoundingClientRect();
            entry.container.hidden = !video.isConnected || rect.width < 120 || rect.height < 70 || rect.bottom < 0 || rect.top > innerHeight;
            entry.container.style.left = Math.max(4, Math.min(innerWidth - entry.container.offsetWidth - 4, rect.left + 8)) + "px";
            entry.container.style.top = Math.max(4, Math.min(innerHeight - entry.container.offsetHeight - 4, rect.bottom - entry.container.offsetHeight - 8)) + "px";
        }
        for (const [video, entry] of buttons) {
            if (!video.isConnected) {
                entry.container.remove();
                buttons.delete(video);
            }
        }
    }
    window.__DTMediaHandoff = { remove };
    timer = setInterval(scan, 1000);
    addEventListener("pagehide", remove, {once:true});
    scan();
})();
