/* Lives in a WKContentWorld isolated from website scripts. Requests can ask for a
   native save dialog; binary ingress still needs a native, tab-owned recording ID. */
addEventListener("message", async (event) => {
    if (event.source !== window || event.data?.channel !== "devtools-media-request") {
        return;
    }
    const id = event.data.id;
    try {
        const result = await webkit.messageHandlers.dtMedia.postMessage(event.data.payload);
        window.postMessage({channel:"devtools-media-reply",id,result},"*");
    } catch (error) {
        window.postMessage({channel:"devtools-media-reply",id,error:error.message},"*");
    }
});
