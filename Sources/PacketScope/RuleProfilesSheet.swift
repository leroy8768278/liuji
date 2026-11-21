import SwiftUI

struct RuleProfilesSheet: View {
    let currentRules: ProxyRuleSet
    let onApply: (ProxyRuleSet) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("capture.ruleProfiles.v1") private var storedProfiles = Data()
    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var saveError: String?

    private var decodedProfiles: [RuleProfile]? {
        if storedProfiles.isEmpty { return [] }
        return try? JSONDecoder().decode([RuleProfile].self, from: storedProfiles)
    }

    var body: some View {
        let decoded = decodedProfiles
        let profiles = decoded ?? []
        let selected = profiles.first { $0.id == selectedID }
        let profileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicate = profiles.contains { $0.name.caseInsensitiveCompare(profileName) == .orderedSame }

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(WorkspaceTheme.accent)
                    .accessibilityHidden(true)
                Text("规则方案").accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .font(.system(size: 18, weight: .semibold))
            .padding(16)
            .background(WorkspaceTheme.chrome)

            WorkspaceTheme.rule.frame(height: 1)
            if decoded == nil {
                empty("无法读取已保存的方案", symbol: "exclamationmark.circle")
            } else if profiles.isEmpty {
                empty("暂无规则方案", symbol: "square.stack")
            } else {
                List(selection: $selectedID) {
                    ForEach(profiles) { profile in
                        HStack(spacing: 8) {
                            Text(profile.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(profile.name)
                            Spacer(minLength: 0)
                            Text("\(profile.rules.rules.count) 条规则")
                                .font(.system(size: 11))
                        }
                        .padding(.vertical, 4)
                        .tag(profile.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("已保存的规则方案")
            }

            WorkspaceTheme.rule.frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("保存当前规则 · \(currentRules.rules.count) 条")
                    .font(.system(size: 11, weight: .semibold))
                HStack(spacing: 8) {
                    TextField("方案名称", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save(profileName) }
                    Button {
                        save(profileName)
                    } label: {
                        Text("保存为方案").padding(.horizontal, 10).frame(height: 28)
                    }
                    .buttonStyle(WorkspaceButtonStyle())
                    .disabled(decoded == nil || profileName.isEmpty || duplicate)
                }
                if let message = saveError ?? (duplicate ? "已有同名方案。" : nil) {
                    Text(message).font(.system(size: 11)).foregroundStyle(WorkspaceTheme.failure)
                }
            }
            .padding(14)

            WorkspaceTheme.rule.frame(height: 1)
            HStack(spacing: 8) {
                Button(role: .destructive) {
                    guard let selected, let profiles = decodedProfiles else { return }
                    write(profiles.filter { $0.id != selected.id })
                } label: {
                    Label("移除方案", systemImage: "trash")
                        .padding(.horizontal, 10).frame(height: 28)
                }
                .buttonStyle(WorkspaceButtonStyle())
                .disabled(selected == nil)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("关闭").padding(.horizontal, 10).frame(height: 28)
                }
                .buttonStyle(WorkspaceButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button {
                    guard let selected else { return }
                    onApply(selected.rules)
                    dismiss()
                } label: {
                    Text("应用方案").padding(.horizontal, 10).frame(height: 28)
                }
                .buttonStyle(WorkspaceButtonStyle(prominent: true))
                .disabled(selected == nil)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(12)
            .background(WorkspaceTheme.chrome)
        }
        .frame(width: 480, height: 420)
        .background(WorkspaceTheme.canvas)
        .foregroundStyle(WorkspaceTheme.ink)
        .onChange(of: name) { saveError = nil }
        .onChange(of: profiles.map(\.id), initial: true) { _, ids in
            if let selectedID, ids.contains(selectedID) { return }
            selectedID = ids.first
        }
    }

    private func empty(_ title: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(WorkspaceTheme.accent)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func save(_ profileName: String) {
        guard !profileName.isEmpty, let profiles = decodedProfiles,
              !profiles.contains(where: { $0.name.caseInsensitiveCompare(profileName) == .orderedSame }) else { return }
        let profile = RuleProfile(name: profileName, rules: currentRules)
        if write(profiles + [profile]) {
            selectedID = profile.id
            name = ""
        }
    }

    @discardableResult
    private func write(_ profiles: [RuleProfile]) -> Bool {
        do {
            storedProfiles = try JSONEncoder().encode(profiles)
            saveError = nil
            return true
        } catch {
            saveError = "无法保存规则方案。"
            return false
        }
    }
}

private struct RuleProfile: Codable, Identifiable {
    var id = UUID()
    let name: String
    let rules: ProxyRuleSet
}
