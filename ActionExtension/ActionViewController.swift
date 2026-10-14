import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Reused by six separate Action Extension targets, giving Safari six independently named rows.
final class ActionViewController: UIViewController {
    private var hosted: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        show(AnyView(ProgressView("Opening DevTools…").padding()))
        Task { @MainActor in
            do {
                let url = try await sharedURL()
                let action = (Bundle.main.object(forInfoDictionaryKey: "DevToolsAction") as? String) ?? "show"
                if action == "addAllow" || action == "addBlock" {
                    let configuration = try SharedStore.shared.read()
                    show(AnyView(ActionRuleView(url: url, kind: action == "addAllow" ? .allow : .block,
                                               configuration: configuration, complete: finish, cancel: cancel)))
                } else {
                    let command = PageCommand(url: url.absoluteString, action: action)
                    try SharedStore.shared.update { config in
                        if action == "enable" {
                            config.enabled = true
                        } else if action == "disable" {
                            config.enabled = false
                        }
                        config.commands.append(command)
                    }
                    finish(command.id)
                }
            } catch {
                show(AnyView(ActionErrorView(message: error.localizedDescription, close: cancel)))
            }
        }
    }

    @MainActor
    private func show(_ content: AnyView) {
        hosted?.willMove(toParent: nil)
        hosted?.view.removeFromSuperview()
        hosted?.removeFromParent()
        let host = UIHostingController(rootView: content.tint(.blue))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
        hosted = host
    }

    /// Safari supplies the actual document URL via its preprocessing script. Other share hosts
    /// may supply public.url; list edits work there, but showing a Safari page needs Safari itself.
    private func sharedURL() async throws -> URL {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
            if let item = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil),
               let dictionary = item as? [String: Any],
               let results = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
               let value = results["url"] as? String, let url = validURL(value) {
                return url
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil)
            if let url = item as? URL, let result = validURL(url.absoluteString) {
                return result
            }
            if let text = item as? String, let result = validURL(text) {
                return result
            }
        }
        throw StorageError.invalidInput("Share an HTTP or HTTPS webpage from Safari to use this action.")
    }

    private func validURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else {
            return nil
        }
        return url
    }

    @MainActor
    private func finish(_ ticket: String) {
        let item = NSExtensionItem()
        let arguments: NSDictionary = [NSExtensionJavaScriptFinalizeArgumentKey: ["ticket": ticket]]
        item.attachments = [NSItemProvider(item: arguments, typeIdentifier: UTType.propertyList.identifier)]
        extensionContext?.completeRequest(returningItems: [item], completionHandler: nil)
    }

    @MainActor
    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}

struct ActionErrorView: View {
    let message: String
    let close: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView("DevTools could not continue", systemImage: "exclamationmark.triangle", description: Text(message))
                .toolbar {
                    Button("Close", action: close)
                }
        }
    }
}

struct ActionRuleView: View {
    let url: URL
    let kind: ListKind
    let configuration: AppConfiguration
    let complete: (String) -> Void
    let cancel: () -> Void
    @State private var listID: String
    @State private var ruleKind: RuleKind = .domain
    @State private var pattern: String
    @State private var newName = ""
    @State private var error: String?

    init(url: URL, kind: ListKind, configuration: AppConfiguration,
         complete: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.url = url
        self.kind = kind
        self.configuration = configuration
        self.complete = complete
        self.cancel = cancel
        _listID = State(initialValue: configuration.lists.first(where: { $0.kind == kind && $0.selected })?.id
                        ?? configuration.lists.first(where: { $0.kind == kind })?.id ?? "new")
        _pattern = State(initialValue: url.host ?? url.absoluteString)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Page") {
                    Text(url.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(3)
                }
                Section("Destination") {
                    Picker(kind.title, selection: $listID) {
                        ForEach(configuration.lists.filter { $0.kind == kind }) { list in
                            Text(list.name + (list.selected ? "" : " (inactive)")).tag(list.id)
                        }
                        Text("Create a new list…").tag("new")
                    }
                    if listID == "new" {
                        TextField("New list name", text: $newName)
                    } else if configuration.lists.first(where: { $0.id == listID })?.selected == false {
                        Text("This list is inactive. Select it in the app when you want its rules to apply.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("Match", selection: $ruleKind) {
                        ForEach(RuleKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    TextField("Pattern", text: $pattern, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Blacklists take priority over AllowLists. Wildcards match the entire URL; regular expressions support i, m and u flags.")
                }
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Add to \(kind.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save)
                        .disabled(pattern.isEmpty || (listID == "new" && newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .onChange(of: ruleKind) { _, newValue in
                switch newValue {
                case .domain:
                    pattern = url.host ?? ""
                case .url:
                    pattern = url.absoluteString
                case .wildcard:
                    pattern = "\(url.scheme ?? "https")://\(url.host ?? "")/*"
                case .regex:
                    pattern = "^" + NSRegularExpression.escapedPattern(for: url.absoluteString)
                }
            }
        }
    }

    private func save() {
        do {
            let rule = SiteRule(kind: ruleKind, pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines))
            try RuleValidator.validate(rule)
            let command = PageCommand(url: url.absoluteString, action: "refresh")
            try SharedStore.shared.update { config in
                var destination = listID
                if listID == "new" {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty && name.count <= 80 else {
                        throw StorageError.invalidInput("Use a list name between 1 and 80 characters.")
                    }
                    let list = RuleList(name: name, kind: kind)
                    config.lists.append(list)
                    destination = list.id
                }
                guard let index = config.lists.firstIndex(where: { $0.id == destination && $0.kind == kind }) else {
                    throw StorageError.invalidInput("That list was changed or deleted. Reopen this action.")
                }
                if !config.lists[index].rules.contains(where: { $0.kind == rule.kind && $0.pattern == rule.pattern }) {
                    config.lists[index].rules.append(rule)
                }
                config.commands.append(command)
            }
            complete(command.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
