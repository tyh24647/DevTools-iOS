import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import fs from "node:fs/promises";

const background = await fs.readFile(
    new URL("../SafariExtension/Resources/background.js", import.meta.url),
    "utf8"
);
const rules = await fs.readFile(
    new URL("../SafariExtension/Resources/rule-engine.js", import.meta.url),
    "utf8"
);

function harness() {
    const native = [];
    const scripts = [];
    let listener;
    let snapshotError = false;
    let enabled = false;
    const context = vm.createContext({
        URL,
        setTimeout,
        clearTimeout,
        console,
        Worker: class {
            constructor() {
                throw new Error("Worker unavailable");
            }
        },
        browser: {
            runtime: {
                getURL: (file) => "safari-web-extension://devtools/" + file,
                onMessage: {
                    addListener: (fn) => {
                        listener = fn;
                    }
                },
                async sendNativeMessage(app, message) {
                    native.push(message);
                    if (message.operation === "setEnabled") {
                        enabled = message.value;
                        return { ok: true };
                    }
                    if (snapshotError) {
                        return { error: "Settings unavailable" };
                    }
                    return {
                        config: { enabled, runEverywhere: true, lists: [] },
                        remoteAssetsAllowed: false
                    };
                }
            },
            tabs: {
                query: async () => [{ id: 10, url: "https://example.com/" }],
                get: async (id) => ({ id, url: "https://example.com/" }),
                onRemoved: { addListener: () => {} }
            },
            scripting: {
                async executeScript(details) {
                    scripts.push(details);
                    return [{ result: { active: false } }];
                }
            },
            webNavigation: { onHistoryStateUpdated: { addListener: () => {} } }
        }
    });
    vm.runInContext(rules, context);
    vm.runInContext(background, context);
    return {
        context,
        native,
        scripts,
        send: (...args) => listener(...args),
        breakSnapshot: () => {
            snapshotError = true;
        }
    };
}

test("page and content-script senders cannot mutate settings", async () => {
    const h = harness();
    for (const sender of [
        { url: "https://example.com/" },
        { url: "https://example.com/", frameId: 0, tab: { id: 10 } }
    ]) {
        const result = await h.send({ type: "enabled", value: true }, sender);
        assert.match(result.error, /Unsupported sender/);
    }
    assert.equal(h.native.length, 0);
});
test("top-frame synchronization is read-only", async () => {
    const h = harness();
    await h.send(
        { type: "sync", value: true, pro: true },
        { tab: { id: 10 }, frameId: 0, url: "https://example.com/" }
    );
    assert.deepEqual(
        h.native.map((item) => item.operation),
        ["snapshot"]
    );
});
test("the extension popup can toggle the native global setting", async () => {
    const h = harness();
    const result = await h.send(
        { type: "enabled", value: false },
        { url: "safari-web-extension://devtools/popup.html" }
    );
    assert.equal(result.decision.run, false);
    assert.deepEqual(
        h.native.map((item) => item.operation),
        ["setEnabled", "snapshot"]
    );
});
test("native storage failure requests console teardown", async () => {
    const h = harness();
    h.breakSnapshot();
    const result = await h.send(
        { type: "sync" },
        { tab: { id: 10 }, frameId: 0, url: "https://example.com/" }
    );
    assert.match(result.error, /Settings unavailable/);
    assert.match(h.scripts[0].func.toString(), /stop/);
});
test("an unavailable regex worker fails closed", async () => {
    const h = harness();
    const result = await h.context.evaluateRules(
        {
            enabled: true,
            runEverywhere: true,
            lists: [
                {
                    selected: true,
                    kind: "block",
                    rules: [{ enabled: true, kind: "regex", pattern: "secret" }]
                }
            ]
        },
        "https://example.com/"
    );
    assert.equal(result.run, false);
    assert.equal(result.error, true);
});
