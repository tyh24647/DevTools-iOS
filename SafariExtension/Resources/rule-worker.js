importScripts("rule-engine.js");
self.onmessage = (event) => {
    self.postMessage(DevToolsRules.evaluate(event.data.config, event.data.url));
};
