const $ = (id) => document.getElementById(id);
let currentURL = "";
async function send(message) {
    $("error").textContent = "";
    try {
        const result = await browser.runtime.sendMessage(message);
        if (result?.error) {
            throw new Error(result.error);
        }
        if (result.config) {
            $("enabled").checked = result.config.enabled;
            $("plan").textContent = result.config.pro ? "Pro" : "Free";
            const chosen = $("lists").value;
            $("lists").replaceChildren(
                ...result.config.lists.map((list) => {
                    const option = document.createElement("option");
                    option.value = list.id;
                    option.textContent = `${list.kind === "block" ? "Blacklist" : "AllowList"}: ${list.name}${list.selected ? "" : " (inactive)"}`;
                    return option;
                })
            );
            if ([...$("lists").options].some((option) => option.value === chosen)) {
                $("lists").value = chosen;
            }
            $("add").disabled = !result.config.lists.length;
        }
        currentURL = result.url || currentURL;
        $("status").textContent = [
            result.decision?.reason,
            result.status?.hidden ? "Console hidden." : "",
            ...(result.status?.warnings || [])
        ]
            .filter(Boolean)
            .join(" ");
        $("version").textContent = result.status?.versions?.eruda
            ? `Eruda ${result.status.versions.eruda}`
            : "Safari console";
        $("show").disabled = !result.decision?.run;
        $("hide").disabled = !result.status?.active;
        return result;
    } catch (error) {
        $("error").textContent = error.message;
    }
}
function updatePattern() {
    try {
        const url = new URL(currentURL);
        $("pattern").value =
            $("kind").value === "domain"
                ? url.hostname
                : $("kind").value === "wildcard"
                  ? `${url.origin}/*`
                  : url.href;
        if ($("kind").value === "regex") {
            $("pattern").value = `^${url.origin.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/`;
        }
    } catch {
        $("pattern").value = "";
    }
}
$("enabled").addEventListener("change", () => send({ type: "enabled", value: $("enabled").checked }));
$("show").addEventListener("click", () => send({ type: "show" }));
$("hide").addEventListener("click", () => send({ type: "hide" }));
$("kind").addEventListener("change", updatePattern);
$("add").addEventListener("click", async () => {
    const result = await send({
        type: "add",
        listID: $("lists").value,
        kind: $("kind").value,
        pattern: $("pattern").value.trim()
    });
    if (result) {
        $("status").textContent = `Rule saved. ${result.decision?.reason || ""}`;
    }
});
send({ type: "status" }).then(updatePattern);
