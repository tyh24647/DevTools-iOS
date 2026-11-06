import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import {chromium} from 'playwright';

const source = fs.readFileSync(new URL('../BrowserResources/media-resources.js', import.meta.url), 'utf8');

test('media control requires a hold, persists across sites, and stays within a resized viewport', async () => {
    let saved = null;
    const requests = [];
    const server = http.createServer((request, response) => {
        response.setHeader('Content-Type', 'text/html');
        response.end('<video src="/video.mp4" width="320" height="200"></video>');
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const browser = await chromium.launch({headless: true, executablePath: process.env.DEVTOOLS_BROWSER_PATH});
    try {
        const page = await browser.newPage({hasTouch: true, viewport: {width: 600, height: 800}});
        await page.exposeFunction('nativeMedia', payload => {
            requests.push(payload);
            if (payload.type === 'download-button-position-save') saved = {x: payload.x, y: payload.y};
            return payload.type === 'download-button-position-get' ? saved : true;
        });
        await page.addInitScript(() => {
            window.devtoolsMedia = {postMessage: raw => window.nativeMedia(JSON.parse(raw))};
            document.addEventListener('DOMContentLoaded', () => window.installMedia());
        });
        await page.exposeFunction('mediaSource', () => source);
        await page.addInitScript(() => {window.installMedia = async () => (0, eval)(await window.mediaSource());});
        const port = server.address().port;
        await page.goto(`http://127.0.0.1:${port}`);
        const button = page.locator('button').filter({has: page.locator('[data-devtools-progress-ring]')});
        await button.waitFor();
        await button.click();
        await page.waitForFunction(() => !!window.__DTMedia);
        assert.equal(requests.filter(request => request.type === 'save').length, 1);
        const start = await button.boundingBox();
        await page.mouse.move(start.x + 24, start.y + 24);
        await page.mouse.down();
        await page.mouse.move(450, 550);
        await page.mouse.up();
        assert.deepEqual(await button.boundingBox(), start, 'moving before the hold must not drag');
        await page.mouse.move(start.x + 24, start.y + 24);
        await page.mouse.down();
        await page.waitForTimeout(1100);
        await page.mouse.move(450, 550);
        await page.evaluate(() => __DTMedia.refresh());
        const dragged = await button.boundingBox();
        assert.equal(dragged.x, 426);
        assert.equal(dragged.y, 526);
        await page.mouse.up();
        await page.waitForTimeout(100);
        assert.ok(saved);
        assert.equal(requests.filter(request => request.type === 'save').length, 1, 'drag release must not download');
        await page.reload();
        await button.waitFor();
        await page.waitForFunction(() => Math.abs(parseFloat(document.querySelector('[data-devtools-progress-ring]').parentElement.style.left) - 426) < 1);
        assert.deepEqual(await button.boundingBox(), dragged);
        await page.goto(`http://localhost:${port}`);
        await button.waitFor();
        await page.waitForFunction(() => Math.abs(parseFloat(document.querySelector('[data-devtools-progress-ring]').parentElement.style.left) - 426) < 1);
        await page.setViewportSize({width: 300, height: 400});
        await page.evaluate(() => __DTMedia.refresh());
        const resized = await button.boundingBox();
        assert.ok(resized.x >= 4 && resized.x + resized.width <= 300);
        assert.ok(resized.y >= 4 && resized.y + resized.height <= 400);
        await button.focus();
        await page.keyboard.press('ArrowLeft');
        assert.ok((await button.boundingBox()).x < resized.x);
        const touchStart = await button.boundingBox();
        const session = await page.context().newCDPSession(page);
        await session.send('Input.dispatchTouchEvent', {type: 'touchStart', touchPoints: [{x: touchStart.x + 24, y: touchStart.y + 24}]});
        await page.waitForTimeout(1100);
        await session.send('Input.dispatchTouchEvent', {type: 'touchMove', touchPoints: [{x: 70, y: 90}]});
        await session.send('Input.dispatchTouchEvent', {type: 'touchEnd', touchPoints: []});
        await page.waitForTimeout(100);
        const touched = await button.boundingBox();
        assert.ok(Math.abs(touched.x - 46) < 1 && Math.abs(touched.y - 66) < 1);
        assert.equal(requests.filter(request => request.type === 'save').length, 1, 'touch drag must not download');
    } finally {
        await browser.close();
        await new Promise(resolve => server.close(resolve));
    }
});
