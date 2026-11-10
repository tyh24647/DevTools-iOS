/* Safari's isolated background process is the only bridge to native settings. */
const nativeApplication = "com.tyh24647.DevTools";
const tabWork = new Map();
const uiURL = browser.runtime.getURL("popup.html");
let catalogPromise;
async function native(message) {
    const result = await browser.runtime.sendNativeMessage(nativeApplication, message);
    if (!result || result.error) {
        throw new Error(
            result?.error || "No response from DevTools. Open the app and check App Group signing."
        );
    }
    return result;
}
async function catalog() {
    catalogPromise ||= fetch(browser.runtime.getURL("tool-catalog.json")).then((response) => response.json());
    return catalogPromise;
}
async function execute(tabID, details) {
    const results = await browser.scripting.executeScript({
        target: { tabId: tabID, frameIds: [0] },
        world: "MAIN",
        ...details
    });
    return results?.[0]?.result;
}
function assetIDs(config) {
    const options = config.console || {};
    if (!config.pro) {
        return ["eruda"];
    }
    if (options.backend === "vconsole") {
        return ["vconsole", ...(options.vue ? ["vueVConsole"] : [])];
    }
    return [
        "eruda",
        ...(options.vue ? [options.vueAdapter === "legacy" ? "vueLegacy" : "vue"] : []),
        ...["code", "dom", "timing", "fps", "features"].filter((id) => options[id])
    ];
}
async function evaluateRules(config, url) {
    const needsWorker = config.lists?.some(
        (list) => list.selected && list.rules?.some((rule) => rule.enabled && rule.kind === "regex")
    );
    if (!needsWorker) {
        return DevToolsRules.evaluate(config, url);
    }
    // A user regex can become pathological on a hostile URL. Run it outside the Safari
    // background thread and terminate it rather than trying to prove every regex is safe.
    return new Promise((resolve) => {
        let worker;
        try {
            worker = new Worker(browser.runtime.getURL("rule-worker.js"));
        } catch {
            resolve({ run: false, error: true, reason: "The regex evaluator could not start." });
            return;
        }
        let finished = false;
        const finish = (result) => {
            if (finished) {
                return;
            }
            finished = true;
            clearTimeout(timeout);
            worker.terminate();
            resolve(result);
        };
        const timeout = setTimeout(
            () =>
                finish({
                    run: false,
                    error: true,
                    reason: "Rule evaluation timed out. Simplify the active regular expressions."
                }),
            750
        );
        worker.onmessage = (event) => finish(event.data);
        worker.onerror = () =>
            finish({ run: false, error: true, reason: "The regex evaluator could not start." });
        worker.postMessage({ config, url });
    });
}
async function refresh(tabID, requestedURL, ticket, manualCommand) {
    const tab = await browser.tabs.get(tabID);
    const url = tab.url || requestedURL;
    if (!url || !/^https?:\/\//i.test(url)) {
        return { decision: { run: false, reason: "Open an HTTP or HTTPS webpage in Safari." } };
    }
    let snapshot;
    try {
        snapshot = await native({ operation: "snapshot", url, ticket: ticket || "" });
    } catch (error) {
        await execute(tabID, { func: () => globalThis.__DevToolsRuntime?.stop() }).catch(() => {});
        throw error;
    }
    const config = snapshot.config;
    const decision = await evaluateRules(config, url);
    const command = manualCommand || snapshot.command?.action || "";
    const remoteUsed = [];
    if (decision.run) {
        const bundled = await catalog();
        await execute(tabID, {
            func: (expectedURL) => {
                if (location.href === expectedURL) {
                    globalThis.__DTExpectedURL = expectedURL;
                }
            },
            args: [url]
        });
        await execute(tabID, { files: ["page-runtime.js", "resource-timing.js"] });
        for (const id of assetIDs(config)) {
            const present = await execute(tabID, {
                func: (assetID, expectedURL) =>
                    location.href === expectedURL && !!globalThis.__DTAssets?.[assetID],
                args: [id, url]
            });
            if (present) {
                continue;
            }
            const asset = bundled.assets.find((item) => item.id === id);
            if (!asset) {
                continue;
            }
            // Developer builds can use an integrity-checked cache. Strict page CSP may reject
            // inline scripts, so every attempted update has a signed bundled fallback.
            if (snapshot.remoteAssetsAllowed && config.automaticallyInstallUpdates) {
                try {
                    const cached = await native({ operation: "asset", id });
                    if (cached.source) {
                        await execute(tabID, {
                            func: (source, expectedURL) => {
                                if (location.href !== expectedURL) {
                                    return;
                                }
                                const script = document.createElement("script");
                                script.textContent = source;
                                (document.head || document.documentElement).append(script);
                                script.remove();
                            },
                            args: [cached.source, url]
                        });
                    }
                } catch {
                    // Remain usable offline or when the update cache is unavailable.
                }
            }
            const installed = await execute(tabID, {
                func: (assetID) => !!globalThis.__DTAssets?.[assetID],
                args: [id]
            });
            if (installed) {
                remoteUsed.push(id);
            }
            if (!installed) {
                try {
                    await execute(tabID, { files: [asset.file] });
                } catch (error) {
                    if (
                        id !== "eruda" ||
                        !snapshot.remoteAssetsAllowed ||
                        !config.automaticallyInstallUpdates
                    ) {
                        throw error;
                    }
                    // Last-resort personal-development recovery when no local Eruda can load.
                    await execute(tabID, {
                        func: async (expectedURL) => {
                            if (location.href !== expectedURL) {
                                return;
                            }
                            const original = globalThis.eruda;
                            const script = document.createElement("script");
                            script.src = "https://cdn.jsdelivr.net/npm/eruda";
                            script.referrerPolicy = "no-referrer";
                            try {
                                await new Promise((resolve, reject) => {
                                    const timer = setTimeout(
                                        () => reject(new Error("Eruda CDN fallback timed out.")),
                                        8000
                                    );
                                    script.onload = () => {
                                        clearTimeout(timer);
                                        resolve();
                                    };
                                    script.onerror = () => {
                                        clearTimeout(timer);
                                        reject(new Error("The page blocked the Eruda CDN fallback."));
                                    };
                                    (document.head || document.documentElement).append(script);
                                });
                                if (!globalThis.eruda?.init) {
                                    throw new Error("The CDN did not provide Eruda.");
                                }
                                globalThis.__DTAssets ||= {};
                                globalThis.__DTAssets.eruda = globalThis.eruda;
                                globalThis.__DTVersions ||= {};
                                globalThis.__DTVersions.eruda = globalThis.eruda.version;
                            } finally {
                                globalThis.eruda = original;
                                script.remove();
                            }
                        },
                        args: [url]
                    });
                }
            }
        }
    }
    const application = {
        func: async (configuration, result, action, expectedURL) => {
            if (location.href !== expectedURL) {
                return { stale: true };
            }
            if (!globalThis.__DevToolsRuntime) {
                return { active: false };
            }
            return await globalThis.__DevToolsRuntime.apply(configuration, result, action, expectedURL);
        },
        args: [config, decision, command, url]
    };
    let status;
    try {
        status = await execute(tabID, application);
    } catch (error) {
        if (!remoteUsed.length) {
            throw error;
        }
        await execute(tabID, {
            func: (ids) => {
                globalThis.__DevToolsRuntime?.stop();
                for (const id of ids) {
                    delete globalThis.__DTAssets?.[id];
                    delete globalThis.__DTVersions?.[id];
                }
            },
            args: [remoteUsed]
        });
        const bundled = await catalog();
        for (const id of remoteUsed) {
            const asset = bundled.assets.find((item) => item.id === id);
            if (asset) {
                await execute(tabID, { files: [asset.file] });
            }
        }
        status = await execute(tabID, application);
        status.warnings ||= [];
        status.warnings.push(
            "A downloaded package failed to initialize. This page is using the bundled version."
        );
    }
    return { config, decision, status, url, remoteAssetsAllowed: snapshot.remoteAssetsAllowed };
}
function serialRefresh(tabID, url, ticket, command) {
    const previous = tabWork.get(tabID) || Promise.resolve();
    const next = previous.catch(() => {}).then(() => refresh(tabID, url, ticket, command));
    tabWork.set(tabID, next);
    next.finally(() => {
        if (tabWork.get(tabID) === next) {
            tabWork.delete(tabID);
        }
    }).catch(() => {});
    return next;
}
browser.runtime.onMessage.addListener((message, sender) => {
    if (sender.tab && sender.frameId === 0 && message?.type === "sync") {
        return serialRefresh(
            sender.tab.id,
            sender.url,
            typeof message.ticket === "string" ? message.ticket.slice(0, 64) : ""
        ).catch((error) => ({ error: error.message }));
    }
    // A webpage's content script cannot toggle preferences, add rules, or claim Pro.
    if (sender.tab || !sender.url?.startsWith(uiURL)) {
        return Promise.resolve({ error: "Unsupported sender." });
    }
    return (async () => {
        const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
        if (!Number.isInteger(tab?.id)) {
            throw new Error("No active Safari tab.");
        }
        if (message.type === "enabled") {
            await native({ operation: "setEnabled", value: !!message.value });
        } else if (message.type === "add") {
            DevToolsRules.validate({ kind: message.kind, pattern: message.pattern });
            await native({
                operation: "addRule",
                listID: message.listID,
                kind: message.kind,
                pattern: message.pattern
            });
        } else if (!["status", "show", "hide"].includes(message.type)) {
            throw new Error("Unknown action.");
        }
        return await serialRefresh(
            tab.id,
            tab.url,
            "",
            ["show", "hide"].includes(message.type) ? message.type : ""
        );
    })().catch((error) => ({ error: error.message }));
});
browser.tabs.onRemoved.addListener((tabID) => tabWork.delete(tabID));
browser.webNavigation.onHistoryStateUpdated.addListener((details) => {
    if (details.frameId === 0) {
        serialRefresh(details.tabId, details.url).catch(() => {});
    }
});
