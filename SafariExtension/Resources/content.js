(() => {
    let inFlight = false;
    let lastNative = 0;
    let lastURL = "";
    let interval;
    let pendingTicket = "";
    async function sync(ticket = "", force = false) {
        if (ticket) {
            pendingTicket = ticket;
        }
        if (inFlight || document.visibilityState === "hidden") {
            return;
        }
        if (!force && !pendingTicket && location.href === lastURL && Date.now() - lastNative < 10000) {
            return;
        }
        inFlight = true;
        lastURL = location.href;
        lastNative = Date.now();
        const sentTicket = pendingTicket;
        pendingTicket = "";
        try {
            const response = await browser.runtime.sendMessage({ type: "sync", ticket: sentTicket });
            if (response?.error) {
                console.warn("DevTools:", response.error);
            }
        } catch {
            // Preserve the share action if Safari temporarily suspends native messaging.
            pendingTicket ||= sentTicket;
        } finally {
            inFlight = false;
        }
    }
    function activate() {
        clearInterval(interval);
        if (document.visibilityState !== "hidden") {
            sync("", true);
            interval = setInterval(() => sync(), 1500);
        }
    }
    document.addEventListener("visibilitychange", activate);
    window.addEventListener("pageshow", activate);
    window.addEventListener("pagehide", () => clearInterval(interval));
    window.addEventListener("focus", () => sync("", true));
    // A forged DOM event can only request a read. Native validates the URL-bound ticket.
    document.addEventListener("DevToolsNativeRefresh", (event) => {
        const ticket = typeof event.detail === "string" ? event.detail.slice(0, 64) : "";
        sync(ticket, true);
    });
    activate();
})();
