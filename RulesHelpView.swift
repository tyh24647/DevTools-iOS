import SwiftUI

struct RulesHelpView: View {
    var body: some View {
        List {
            Section("Priority") {
                Text("1. Disabled means do not run.\n2. A match in any selected blacklist means do not run.\n3. Run on every webpage allows remaining pages.\n4. Otherwise, a selected AllowList must match.")
            }
            Section("Examples") {
                LabeledContent("Domain & subdomains", value: "example.com")
                Text("Matches example.com and api.example.com, but never notexample.com.")
                LabeledContent("Exact URL", value: "https://example.com/debug")
                Text("Matches the full URL including its query string. Fragments are ignored.")
                LabeledContent("Wildcard", value: "*://*.example.com/*")
                Text("* matches any sequence; ? matches one character. A wildcard is anchored to the entire URL and is case sensitive. *.example.com does not include the bare example.com host.")
                LabeledContent("Regular expression", value: #"/^https:\/\/example\.com\/debug/i"#)
                Text("Use JavaScript regex syntax with optional /pattern/imu flags. Matching uses the normalized URL without its fragment. Patterns are limited to 512 characters, URLs to 4096. Backreferences, lookarounds, repeated complex groups and more than four variable-length repetitions are rejected.")
            }
            Section("Lists") {
                Text("Select several lists to combine them. Unselected lists do not affect matching. An invalid active rule stops injection and is reported in the Safari popup.")
            }
        }
        .textSelection(.enabled)
        .navigationTitle("Matching guide")
    }
}

#Preview {
    NavigationStack { RulesHelpView() }
}
