import { chromium } from "playwright";
import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";
import assert from "node:assert/strict";

const root = path.resolve(import.meta.dirname, "..");
const resources = path.join(root, "SafariExtension/Resources");
const server = http.createServer(async (req, res) => {
    if (req.url === "/data.json") {
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify({ ok: true }));
        return;
    }
    res.setHeader("Content-Type", "text/html");
    res.end(
        '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body><h1>DevTools fixture</h1><p id="message">A real page under inspection.</p><div id="app"></div></body></html>'
    );
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = "http://127.0.0.1:" + server.address().port;
const browser = await chromium.launch({
    executablePath: process.env.DEVTOOLS_BROWSER_PATH || undefined,
    headless: true,
    args: ["--no-sandbox"]
});
let count = 0;
try {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.goto(origin);
    await page.evaluate(() => {
        globalThis.__DTExpectedURL = location.href;
        globalThis.eruda = { ownedByPage: true };
    });
    const load = async (file) => {
        await page.addScriptTag({ path: path.join(resources, file) });
    };
    for (const file of ["page-runtime.js", "resource-timing.js", "vendor/eruda.js"]) {
        await load(file);
    }
    const config = {
        pro: false,
        console: {
            displaySize: 55,
            transparency: 0.98,
            theme: "Material Palenight",
            rememberPosition: true,
            positionX: 263.807642,
            positionY: 0,
            backend: "eruda",
            vueAdapter: "modern",
            vue: true,
            resourceTiming: true,
            code: true,
            dom: true,
            timing: true,
            fps: false,
            features: false
        }
    };
    let state = await page.evaluate(
        (c) => __DevToolsRuntime.apply(c, { run: true }, "show", location.href),
        config
    );
    assert.equal(state.active, true);
    assert.equal(state.versions.eruda, "3.4.3");
    assert.equal(await page.evaluate(() => globalThis.eruda.ownedByPage), true);
    assert.equal(await page.locator("#eruda").count(), 1);
    const applied = await page.evaluate(() => ({
        console: __DTAssets.eruda.get("console").config.get("maxLogNum"),
        theme: __DTAssets.eruda.get().config.get("theme"),
        size: __DTAssets.eruda.get().config.get("displaySize")
    }));
    assert.deepEqual(applied, { console: "infinite", theme: "Material Palenight", size: 55 });
    count++;
    await page.evaluate((c) => __DevToolsRuntime.apply(c, { run: true }, "hide"), config);
    assert.equal(
        await page.evaluate(() => __DTAssets.eruda.get("entryBtn")._$el.get(0).style.display),
        "none"
    );
    await page.evaluate((c) => __DevToolsRuntime.apply(c, { run: true }, "show"), config);
    count++;
    for (const id of ["vue", "code", "dom", "timing", "fps", "features"]) {
        await load("vendor/" + id + ".js");
    }
    config.pro = true;
    config.console.fps = true;
    config.console.features = true;
    state = await page.evaluate((c) => __DevToolsRuntime.apply(c, { run: true }, "show"), config);
    assert.equal(state.active, true);
    assert.deepEqual(state.warnings, []);
    assert.equal(await page.evaluate(() => !!__DTAssets.eruda.get("vue")), true);
    assert.equal(await page.evaluate(() => !!__DTAssets.eruda.get("resource timing")), true);
    await page.evaluate(async () => {
        await fetch("/data.json");
        __DTAssets.eruda.show("resource timing");
    });
    await page.waitForTimeout(900);
    const timing = await page.locator("#eruda").evaluate((el) => el.shadowRoot.textContent);
    assert.match(timing, /data\.json/);
    await fs.mkdir(path.join(root, "Documentation/Previews"), { recursive: true });
    await page.screenshot({ path: path.join(root, "Documentation/Previews/eruda-resource-timing.png") });
    count++;
    await page.evaluate(
        (c) => __DevToolsRuntime.apply(c, { run: false, reason: "Blacklist" }, "show"),
        config
    );
    assert.equal(await page.locator("#eruda").count(), 0);
    assert.equal(await page.evaluate(() => globalThis.eruda.ownedByPage), true);
    count++;
    // Legacy and vConsole adapters are separate choices and evaluated on clean documents.
    for (const backend of ["legacy", "vconsole"]) {
        await page.goto(origin + "/" + backend);
        await page.evaluate(() => {
            globalThis.__DTExpectedURL = location.href;
        });
        for (const file of ["page-runtime.js", "resource-timing.js"]) {
            await load(file);
        }
        config.console = {
            ...config.console,
            code: false,
            dom: false,
            timing: false,
            fps: false,
            features: false,
            resourceTiming: false
        };
        if (backend === "legacy") {
            await load("vendor/eruda.js");
            await load("vendor/vueLegacy.js");
            config.console.backend = "eruda";
            config.console.vueAdapter = "legacy";
        } else {
            await load("vendor/vconsole.js");
            await load("vendor/vueVConsole.js");
            config.console.backend = "vconsole";
        }
        state = await page.evaluate((c) => __DevToolsRuntime.apply(c, { run: true }, "show"), config);
        assert.equal(state.active, true);
        assert.deepEqual(state.warnings, []);
        count++;
    }
    console.log("Browser integration checks passed: " + count);
    console.log("Uncaught page errors: " + JSON.stringify(errors));
    if (errors.length) {
        process.exitCode = 1;
    }
} finally {
    await browser.close();
    server.close();
}
