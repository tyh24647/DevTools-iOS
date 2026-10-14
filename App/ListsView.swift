import SwiftUI

struct ListsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var creating = false
    @State private var deleting: RuleList?

    var body: some View {
        List {
            ForEach(ListKind.allCases) { kind in
                Section(kind == .allow ? "AllowLists" : "Blacklists") {
                    let lists = model.config.lists.filter {
                        $0.kind == kind
                    }
                    if lists.isEmpty {
                        Text("No \(kind.title)s yet. Tap + to create one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(lists) { list in
                        HStack(spacing: 12) {
                            Button {
                                model.change { config in
                                    if let index = config.lists.firstIndex(where: { $0.id == list.id }) {
                                        config.lists[index].selected.toggle()
                                    }
                                }
                            } label: {
                                Image(systemName: list.selected ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(list.selected ? model.accent : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(list.selected ? "Deselect" : "Select") \(list.name)")
                            NavigationLink {
                                ListDetailView(listID: list.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(list.name)
                                        .font(.headline)
                                    Text("\(list.rules.count) rules · \(list.selected ? "Active" : "Inactive")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                deleting = list
                            }
                        }
                    }
                }
            }
            Section {
                NavigationLink("Pattern examples & matching priority") {
                    RulesHelpView()
                }
            } footer: {
                Text("Select one or more lists using the circles. Blacklists take priority in both running modes.")
            }
        }
        .navigationTitle("Lists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New list", systemImage: "plus") {
                    creating = true
                }
            }
        }
        .sheet(isPresented: $creating) {
            ListEditorView()
        }
        .confirmationDialog("Delete \(deleting?.name ?? "list") and its rules?", isPresented: Binding(get: {
            deleting != nil
        }, set: { shown in
            if !shown {
                deleting = nil
            }
        }), titleVisibility: .visible) {
            Button("Delete list", role: .destructive) {
                let id = deleting?.id
                model.change {
                    $0.lists.removeAll { $0.id == id }
                }
                deleting = nil
            }
        }
        .onAppear {
            model.reload()
        }
    }
}

struct ListDetailView: View {
    @EnvironmentObject private var model: AppModel
    let listID: String
    @State private var addingRule = false
    @State private var editingRule: SiteRule?
    @State private var editingList = false

    private var list: RuleList? {
        model.config.lists.first {
            $0.id == listID
        }
    }

    var body: some View {
        Group {
            if let list {
                List {
                    Section {
                        Toggle("Apply this \(list.kind.title)", isOn: Binding(get: {
                            self.list?.selected ?? false
                        }, set: { value in
                            model.change { config in
                                if let index = config.lists.firstIndex(where: { $0.id == listID }) {
                                    config.lists[index].selected = value
                                }
                            }
                        }))
                    }
                    Section("Rules") {
                        if list.rules.isEmpty {
                            ContentUnavailableView("No rules yet", systemImage: "line.3.horizontal.decrease.circle", description: Text("Add a domain, URL, wildcard or regular expression."))
                        }
                        ForEach(list.rules) { rule in
                            HStack {
                                Button {
                                    editingRule = rule
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(rule.pattern)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(.primary)
                                        Text(rule.kind.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Toggle("Enable rule", isOn: Binding(get: {
                                    self.list?.rules.first(where: { $0.id == rule.id })?.enabled ?? false
                                }, set: { value in
                                    model.change { config in
                                        if let i = config.lists.firstIndex(where: { $0.id == listID }),
                                           let j = config.lists[i].rules.firstIndex(where: { $0.id == rule.id }) {
                                            config.lists[i].rules[j].enabled = value
                                        }
                                    }
                                }))
                                .labelsHidden()
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map {
                                list.rules[$0].id
                            }
                            model.change { config in
                                if let index = config.lists.firstIndex(where: { $0.id == listID }) {
                                    config.lists[index].rules.removeAll {
                                        ids.contains($0.id)
                                    }
                                }
                            }
                        }
                        Button("Add rule", systemImage: "plus.circle.fill") {
                            addingRule = true
                        }
                    }
                }
                .navigationTitle(list.name)
                .toolbar {
                    Button("Edit list", systemImage: "pencil") {
                        editingList = true
                    }
                }
                .sheet(isPresented: $addingRule) {
                    RuleEditorView(listID: listID)
                }
                .sheet(item: $editingRule) { rule in
                    RuleEditorView(listID: listID, existing: rule)
                }
                .sheet(isPresented: $editingList) {
                    ListEditorView(existing: list)
                }
            } else {
                ContentUnavailableView("List deleted", systemImage: "folder.badge.questionmark")
            }
        }
    }
}

struct ListEditorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ads: AdManager
    @Environment(\.dismiss) private var dismiss
    let existing: RuleList?
    @State private var name: String
    @State private var kind: ListKind
    @State private var selected: Bool

    init(existing: RuleList? = nil) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _kind = State(initialValue: existing?.kind ?? .allow)
        _selected = State(initialValue: existing?.selected ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("List name", text: $name)
                Picker("List type", selection: $kind) {
                    ForEach(ListKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                Toggle("Apply this list", isOn: $selected)
            }
            .navigationTitle(existing == nil ? "New list" : "Edit list")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.change { config in
                            if let existing, let index = config.lists.firstIndex(where: { $0.id == existing.id }) {
                                config.lists[index].name = name
                                config.lists[index].kind = kind
                                config.lists[index].selected = selected
                            } else if existing == nil {
                                config.lists.append(RuleList(name: name, kind: kind, selected: selected))
                            } else {
                                throw StorageError.invalidInput("This list was deleted in another view.")
                            }
                        }
                        if model.error == nil {
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
                }
            }
            .safeAreaInset(edge: .bottom) {
                AdFooter()
            }
        }
        .onAppear {
            ads.isEditing = true
        }
        .onDisappear {
            ads.isEditing = false
        }
    }
}

struct RuleEditorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ads: AdManager
    @Environment(\.dismiss) private var dismiss
    let listID: String
    let existing: SiteRule?
    @State private var kind: RuleKind
    @State private var pattern: String
    @State private var validationError: String?

    init(listID: String, existing: SiteRule? = nil) {
        self.listID = listID
        self.existing = existing
        _kind = State(initialValue: existing?.kind ?? .domain)
        _pattern = State(initialValue: existing?.pattern ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Match type", selection: $kind) {
                        ForEach(RuleKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    TextField("Pattern", text: $pattern, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...6)
                } footer: {
                    Text("Use example.com for a domain, https://example.com/* for a wildcard, or /pattern/i for a regex. Blacklists always take priority.")
                }
                if let validationError {
                    Text(validationError)
                        .foregroundStyle(.red)
                }
                NavigationLink("Pattern examples") {
                    RulesHelpView()
                }
            }
            .navigationTitle(existing == nil ? "New rule" : "Edit rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                AdFooter()
            }
        }
        .onAppear {
            ads.isEditing = true
        }
        .onDisappear {
            ads.isEditing = false
        }
    }

    private func save() {
        let rule = SiteRule(id: existing?.id ?? UUID().uuidString, kind: kind,
                            pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines), enabled: existing?.enabled ?? true)
        do {
            try RuleValidator.validate(rule)
            model.change { config in
                guard let i = config.lists.firstIndex(where: { $0.id == listID }) else {
                    throw StorageError.invalidInput("This list was deleted.")
                }
                if let j = config.lists[i].rules.firstIndex(where: { $0.id == rule.id }) {
                    config.lists[i].rules[j] = rule
                } else if !config.lists[i].rules.contains(where: { $0.kind == rule.kind && $0.pattern == rule.pattern }) {
                    config.lists[i].rules.append(rule)
                }
            }
            guard model.error == nil else {
                validationError = model.error
                return
            }
            dismiss()
            if existing == nil {
                ads.listEntryAdded()
            }
        } catch {
            validationError = error.localizedDescription
        }
    }
}
