import fs from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { execFileSync } from "node:child_process";

const root = path.resolve(import.meta.dirname, "..");
const resources = path.join(root, "SafariExtension/Resources");
const manifest = JSON.parse(await fs.readFile(path.join(resources, "manifest.json"), "utf8"));
const catalog = JSON.parse(await fs.readFile(path.join(resources, "tool-catalog.json"), "utf8"));
const required = [
    ...manifest.background.scripts,
    ...manifest.content_scripts.flatMap((x) => x.js),
    manifest.action.default_popup,
    ...Object.values(manifest.icons),
    ...catalog.assets.map((x) => x.file)
];
for (const file of required) {
    await fs.access(path.join(resources, file));
}
for (const file of (await fs.readdir(resources)).filter((name) => name.endsWith(".js"))) {
    new vm.Script(await fs.readFile(path.join(resources, file), "utf8"), { filename: file });
}
new vm.Script(await fs.readFile(path.join(root, "ActionExtension/Action.js"), "utf8"));
for (const asset of catalog.assets) {
    new vm.Script(await fs.readFile(path.join(resources, asset.file), "utf8"), { filename: asset.file });
}
console.log("Validated MV3 resources, script syntax and " + catalog.assets.length + " bundled packages.");

const browserResources = path.join(root, "BrowserResources");
const read = async (file) => fs.readFile(path.join(browserResources, file), "utf8");
let bootstrap = await read("native-bootstrap.js");
const rules = await read("rule-engine.js");
const embedded = [
    ["__MSE__", await read("mse-capture.js")],
    ["__RULES__", rules],
    ["__USER_SCRIPTS__", await read("userscripts.js")],
    ["__RUNTIME__", await read("page-runtime.js")],
    ["__RULE_SOURCE__", JSON.stringify(rules)],
    ["__ASSETS__", (await Promise.all(["eruda", "vue", "code", "dom", "timing", "fps", "features", "vconsole", "vueVConsole", "vueLegacy"].map((id) =>
        read("vendor/" + id + ".js")
    ))).join("\n") + await read("resource-timing.js") + await read("console-ui.js")],
    ["__SOURCE_FORMAT__", await read("source-formatting.js")],
    ["__MEDIA__", await read("media-resources.js")],
    ["__CONFIG__", JSON.stringify({enabled:true,runEverywhere:true,lists:[],plugins:[],console:{}})]
];
for (const [token, source] of embedded) {
    bootstrap = bootstrap.replaceAll(token, () => source);
}
new vm.Script(bootstrap, { filename: "assembled-native-bootstrap.js" });
console.log("Validated native browser bootstrap and bundled scripts.");

execFileSync("python3", [path.join(root, "Scripts/validate-project.py")], { stdio: "inherit" });
