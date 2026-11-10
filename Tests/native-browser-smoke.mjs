import { chromium } from "playwright";
import fs from "node:fs";
import http from "node:http";
import assert from "node:assert/strict";

const root = new URL("../BrowserResources/", import.meta.url);
const read = (path) => fs.readFileSync(new URL(path, root), "utf8");
let script = read("native-bootstrap.js");
const config = {
    enabled: true,
    runEverywhere: true,
    lists: [],
    pro: false,
    console: {},
    plugins: [
        {
            id: "css-editor",
            name: "Page CSS editor",
            kind: "eruda",
            enabled: true,
            source: read("css-editor-plugin.js")
        },
        {
            id: "login-script",
            name: "Login fixture",
            kind: "userscript",
            enabled: true,
            source: [
                "// ==UserScript==",
                "// @match http://127.0.0.1/*",
                "// @grant none",
                "// ==/UserScript==",
                "window.__userscriptRan = true;",
                "window.__userscriptMediaBridge = typeof globalThis.devtoolsMedia;"
            ].join("\n")
        }
    ]
};

for (const [token, value] of [
    ["__RULES__", read("rule-engine.js")],
    ["__USER_SCRIPTS__", read("userscripts.js")],
    ["__RUNTIME__", read("page-runtime.js")],
    ["__RULE_SOURCE__", JSON.stringify(read("rule-engine.js"))],
    ["__ASSETS__", read("vendor/eruda.js") + read("resource-timing.js") + read("console-ui.js")],
    ["__SOURCE_FORMAT__", read("source-formatting.js")],
    ["__CONFIG__", JSON.stringify(config)]
]) {
    script = script.replaceAll(token, () => value);
}

const server = http.createServer((request, response) => {
    if (request.url === "/redirect") {
        response.writeHead(302, { Location: "/login" });
        response.end();
        return;
    }
    response.setHeader("Content-Type", "text/html; charset=utf-8");
    response.end("<!doctype html><html><head><title>Native fixture</title></head><body><video controls width=\"320\" height=\"200\"></video><audio controls></audio></body></html>");
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const browser = await chromium.launch({
    executablePath: process.env.DEVTOOLS_BROWSER_PATH,
    headless: true,
    args: ["--no-sandbox"]
});

try {
    const page = await browser.newPage();
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    page.on("console", (message) => {
        if (message.type() === "error" && message.text().includes("[DevTools userscript]")) {
            errors.push(message.text());
        }
    });
    const snapshotMediaAPIs = () => {
        window.__originalMediaAPIs = {
            createObjectURL: URL.createObjectURL,
            appendBuffer: globalThis.SourceBuffer?.prototype.appendBuffer,
            mediaRecorder: globalThis.MediaRecorder
        };
    };
    await page.addInitScript(`(${snapshotMediaAPIs.toString()})();\n${script}`);
    await page.goto(`http://127.0.0.1:${server.address().port}/redirect`);
    await page.waitForFunction(() => globalThis.__DTNativeStatus?.active, null, { timeout: 5000 });
    assert.ok(page.url().endsWith("/login"));
    await page.waitForFunction(() => window.__userscriptRan === true);
    assert.equal(await page.evaluate(() => window.__userscriptMediaBridge), "undefined");
    assert.equal(await page.evaluate(() => !!__DTAssets.eruda.get("css-editor")), true);
    assert.equal(await page.evaluate(() => __DTNativeStatus.hidden), true);
    assert.notEqual(
        await page.evaluate(() => getComputedStyle(__DTAssets.eruda.get("css-editor").element.get(0)).backgroundColor),
        "rgba(0, 0, 0, 0)"
    );
    assert.equal(await page.evaluate(() => __DTAssets.eruda.get().config.get("displaySize") <= 75), true);
    assert.equal(await page.evaluate(() => !!globalThis.__DTSourceFormatting), true);
    assert.deepEqual(await page.evaluate(() => ({
        bridge: typeof globalThis.devtoolsMedia,
        mediaUI: typeof globalThis.__DTMedia,
        capture: typeof globalThis.__DTMSE,
        objectURLUnchanged: URL.createObjectURL === window.__originalMediaAPIs.createObjectURL,
        sourceBufferUnchanged: globalThis.SourceBuffer?.prototype.appendBuffer === window.__originalMediaAPIs.appendBuffer,
        mediaRecorderUnchanged: globalThis.MediaRecorder === window.__originalMediaAPIs.mediaRecorder
    })), {
        bridge: "undefined",
        mediaUI: "undefined",
        capture: "undefined",
        objectURLUnchanged: true,
        sourceBufferUnchanged: true,
        mediaRecorderUnchanged: true
    });
    assert.equal(await page.locator("[data-devtools-progress-ring]").count(), 0);
    assert.equal(await page.getByRole("button", { name: /download|record/i }).count(), 0);
    assert.equal(await page.locator("video[controls]").count(), 1);
    assert.equal(await page.locator("audio[controls]").count(), 1);

    const inspection = await page.evaluate(() => {
        let blocked = 0;
        const block = (event) => {
            blocked++;
            event.preventDefault();
        };
        document.addEventListener("contextmenu", block);
        document.addEventListener("keydown", block);
        const contextAllowed = document.body.dispatchEvent(new Event("contextmenu", { bubbles: true, cancelable: true }));
        const shortcutAllowed = document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "F12", bubbles: true, cancelable: true }));
        document.removeEventListener("contextmenu", block);
        document.removeEventListener("keydown", block);
        return { blocked, contextAllowed, shortcutAllowed };
    });
    assert.deepEqual(inspection, { blocked: 0, contextAllowed: true, shortcutAllowed: true });
    await page.evaluate(() => {
        __DTNativeUpdate({ enabled: false, runEverywhere: true, lists: [], console: {} }, "");
    });
    await page.waitForFunction(() => __DTNativeStatus?.active === false);
    await page.evaluate((next) => __DTNativeUpdate(next, "show"), config);
    await page.waitForFunction(() => __DTNativeStatus?.active === true && !__DTNativeStatus.hidden);
    assert.deepEqual(errors, []);
    console.log("Native browser bootstrap: debugger, CSS panel, userscript, source formatting, teardown and re-enable passed; native media bridge, capture hooks and download controls are absent.");
} finally {
    await browser.close();
    server.close();
}
