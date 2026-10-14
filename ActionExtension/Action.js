var ExtensionPreprocessingJS = {
    run: function (arguments) {
        arguments.completionFunction({ url: window.location.href, title: document.title });
    },
    finalize: function (arguments) {
        // No downloaded JavaScript or settings are accepted from the webpage. The extension
        // resolves this opaque ticket against a short-lived record in its private App Group.
        if (typeof arguments.ticket === "string") {
            document.dispatchEvent(new CustomEvent("DevToolsNativeRefresh", { detail: arguments.ticket }));
        }
    }
};
