import AppKit
import SwiftUI

struct ProxyToolsSheet: View {
    let onSave: (ProxyRuleSet) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProxyRuleSet
    @State private var kind: ProxyToolKind
    @State private var selection: [ProxyToolKind: UUID]

    init(
        initialKind: ProxyToolKind,
        rules: ProxyRuleSet,
        initialRule: ProxyRule? = nil,
        onSave: @escaping (ProxyRuleSet) -> Void
    ) {
        var draft = rules
        var selection: [ProxyToolKind: UUID] = [:]
        if var initialRule, initialRule.kind == initialKind {
            if draft.rules.contains(where: { $0.id == initialRule.id }) { initialRule.id = UUID() }
            draft.rules.append(initialRule)
            selection[initialKind] = initialRule.id
        }
        self.onSave = onSave
        _kind = State(initialValue: initialKind)
        _draft = State(initialValue: draft)
        _selection = State(initialValue: selection)
    }

    private var visibleRules: [ProxyRule] { draft.rules.filter { $0.kind == kind } }

    private var activeRule: ProxyRule? {
        visibleRules.first { $0.id == selection[kind] } ?? visibleRules.first
    }

    private var invalidRule: ProxyRule? { draft.rules.first { $0.validationError != nil } }

    var body: some View {
        VStack(spacing: 0) {
            header
            WorkspaceTheme.rule.frame(height: 1)
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 182)
                WorkspaceTheme.rule.frame(width: 1)
                workspace
            }
            WorkspaceTheme.rule.frame(height: 1)
            footer
        }
        .frame(width: 830, height: 560)
        .background(WorkspaceTheme.canvas)
        .foregroundStyle(WorkspaceTheme.ink)
        .tint(WorkspaceTheme.accent)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(WorkspaceTheme.accent)
                .frame(width: 36, height: 36)
                .background(WorkspaceTheme.accentFill, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            Text("代理工具")
                .font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .background(WorkspaceTheme.chrome)
    }

    private var sidebar: some View {
        VStack(spacing: 5) {
            ForEach(ProxyToolKind.allCases) { item in
                let count = draft.rules.filter { $0.kind == item }.count
                Button {
                    kind = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 17)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 12, weight: .semibold))
                            Text(item.englishName).font(.system(size: 10))
                                .foregroundStyle(WorkspaceTheme.muted)
                        }
                        Spacer(minLength: 1)
                        if count > 0 {
                            Text(count, format: .number)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(WorkspaceTheme.muted)
                                .accessibilityLabel("\(count) 条规则")
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 44)
                    .foregroundStyle(kind == item ? WorkspaceTheme.brand : WorkspaceTheme.ink)
                    .background(kind == item ? WorkspaceTheme.accentFill : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(kind == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .background(WorkspaceTheme.sidebar)
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(kind.title)
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: addRule) {
                        Label("添加规则", systemImage: "plus")
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                    }
                    .buttonStyle(WorkspaceButtonStyle())
                }
                Text(kind.description)
                    .font(.system(size: 12))
                    .foregroundStyle(WorkspaceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if kind == .allowList {
                    Toggle("启用白名单", isOn: $draft.allowListEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 12, weight: .medium))
                    if draft.allowListEnabled && !visibleRules.contains(where: \.isEnabled) {
                        Text("没有已启用的白名单规则时，代理会拒绝所有请求。")
                            .font(.system(size: 11))
                            .foregroundStyle(WorkspaceTheme.warning)
                    }
                }
            }
            .padding(.horizontal, 19)
            .padding(.vertical, 15)

            WorkspaceTheme.rule.frame(height: 1)
            if let activeRule {
                HStack(spacing: 0) {
                    ruleList(activeID: activeRule.id)
                        .frame(width: 216)
                    WorkspaceTheme.rule.frame(width: 1)
                    ProxyRuleEditor(rule: ruleBinding(activeRule), chooseFile: { chooseFile(activeRule.id) },
                                    remove: { removeRule(activeRule.id) })
                        .id(activeRule.id)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ruleList(activeID: UUID) -> some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                ForEach(visibleRules) { rule in
                    let isActive = rule.id == activeID
                    HStack(spacing: 7) {
                        Button {
                            selection[kind] = rule.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.host.isEmpty ? "新规则" : rule.host)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(isActive ? WorkspaceTheme.brand : WorkspaceTheme.ink)
                                    .truncationMode(.middle)
                                Text(rule.path.isEmpty ? ruleSummary(rule) : rule.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(WorkspaceTheme.muted)
                                    .truncationMode(.middle)
                            }
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 45)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isActive ? .isSelected : [])

                        if rule.validationError != nil {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(WorkspaceTheme.warning)
                                .accessibilityLabel("需要修正")
                        }
                        Toggle("启用 \(rule.host.isEmpty ? "新规则" : rule.host)", isOn: ruleBinding(rule).isEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.mini)
                    }
                    .padding(.horizontal, 8)
                    .background(isActive ? WorkspaceTheme.accentFill : WorkspaceTheme.canvas,
                                in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(9)
        }
        .frame(maxHeight: .infinity)
        .background(WorkspaceTheme.chrome)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: kind.icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(WorkspaceTheme.accent)
                .frame(width: 46, height: 46)
                .background(WorkspaceTheme.accentFill, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            Text("暂无规则").font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if let invalidRule {
                Button {
                    kind = invalidRule.kind
                    selection[kind] = invalidRule.id
                } label: {
                    Label("定位待修正的规则", systemImage: "exclamationmark.circle")
                        .foregroundStyle(WorkspaceTheme.warning)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Text("取消").padding(.horizontal, 13).frame(height: 30)
            }
            .buttonStyle(WorkspaceButtonStyle())
            .keyboardShortcut(.cancelAction)
            Button {
                onSave(draft)
                dismiss()
            } label: {
                Text("保存规则").padding(.horizontal, 13).frame(height: 30)
            }
            .buttonStyle(WorkspaceButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
            .disabled(invalidRule != nil)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(WorkspaceTheme.chrome)
    }

    private func ruleSummary(_ rule: ProxyRule) -> String {
        switch rule.kind {
        case .dnsOverride: return "→ 127.0.0.1"
        case .blockList: return "阻止"
        case .allowList: return "允许"
        default: return "待填写路径"
        }
    }

    private func ruleBinding(_ rule: ProxyRule) -> Binding<ProxyRule> {
        Binding {
            draft.rules.first { $0.id == rule.id } ?? rule
        } set: { updated in
            if let index = draft.rules.firstIndex(where: { $0.id == rule.id }) {
                draft.rules[index] = updated
            }
        }
    }

    private func addRule() {
        var rule = ProxyRule(kind: kind)
        if kind == .dnsOverride { rule.value = "127.0.0.1" }
        draft.rules.append(rule)
        selection[kind] = rule.id
    }

    private func removeRule(_ id: UUID) {
        let ids = visibleRules.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        draft.rules.removeAll { $0.id == id }
        let remaining = visibleRules.map(\.id)
        selection[kind] = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
    }

    private func chooseFile(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "选择映射文件"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let path = panel.url?.standardizedFileURL.path,
                  let index = draft.rules.firstIndex(where: { $0.id == id }) else { return }
            draft.rules[index].value = path
        }
    }
}

private struct ProxyRuleEditor: View {
    @Binding var rule: ProxyRule
    let chooseFile: () -> Void
    let remove: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("规则设置")
                        .font(.system(size: 13, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(role: .destructive, action: remove) {
                        Label("移除规则", systemImage: "trash")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(WorkspaceTheme.failure)
                    }
                    .buttonStyle(.borderless)
                    .help("移除规则")
                }
                field("匹配主机", example: hostExample, text: $rule.host)
                fields
                if let message = rule.validationError {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(WorkspaceTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var fields: some View {
        switch rule.kind {
        case .noCaching, .blockCookies:
            pathField(allowsPrefix: true)
            localAliasHint
        case .mapRemote:
            pathField(allowsPrefix: true)
            field("目标 URL", example: "http://127.0.0.1:3000/api", text: $rule.value)
        case .mapLocal:
            pathField(allowsPrefix: false)
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("响应文件")
                HStack(spacing: 7) {
                    Text(rule.value.isEmpty ? "请选择文件" : rule.value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(rule.value.isEmpty ? WorkspaceTheme.muted : WorkspaceTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(rule.value)
                    Button("选择文件…", action: chooseFile)
                        .controlSize(.small)
                }
                .padding(8)
                .background(WorkspaceTheme.chrome, in: RoundedRectangle(cornerRadius: 6))
            }
        case .rewrite:
            pathField(allowsPrefix: true)
            Picker("改写字段", selection: $rule.rewriteField) {
                ForEach(ProxyRewriteField.allCases) { field in Text(field.title).tag(field) }
            }
            .font(.system(size: 11, weight: .semibold))
            if rule.rewriteField == .path {
                field("替换路径", example: "/v2/status", text: $rule.value)
            } else {
                field("标头名称", example: "X-Debug-Scenario", text: $rule.headerName)
                field("标头值", example: "development", text: $rule.value)
            }
            localAliasHint
        case .dnsOverride:
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("本机地址")
                Text("127.0.0.1")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
        case .blockList, .allowList:
            EmptyView()
        }
    }

    @ViewBuilder
    private var localAliasHint: some View {
        let host = rule.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        if name.hasSuffix(".test") || name.hasSuffix(".localhost") {
            Text("开发域名通过域名覆盖或远程映射连接本机后，此规则生效。")
                .font(.system(size: 11))
                .foregroundStyle(WorkspaceTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pathField(allowsPrefix: Bool) -> some View {
        field("匹配路径", example: allowsPrefix ? "/api/status 或 /api/*" : "/api/status", text: $rule.path)
    }

    private var hostExample: String {
        if rule.kind.isHostList { return "example.com 或 *.example.com" }
        switch rule.kind {
        case .noCaching, .blockCookies, .rewrite: return "localhost"
        default: return "api.test"
        }
    }

    private func field(_ title: String, example: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(title)
            TextField(title, text: text, prompt: Text(example))
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel(title)
                .disableAutocorrection(true)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WorkspaceTheme.muted)
            .accessibilityHidden(true)
    }
}

private extension ProxyToolKind {
    var englishName: String {
        switch self {
        case .noCaching: return "No Caching"
        case .blockCookies: return "Block Cookies"
        case .mapRemote: return "Map Remote"
        case .mapLocal: return "Map Local"
        case .rewrite: return "Rewrite"
        case .dnsOverride: return "DNS Override"
        case .blockList: return "Block List"
        case .allowList: return "Allow List"
        }
    }

    var isHostList: Bool { self == .allowList || self == .blockList }
}
