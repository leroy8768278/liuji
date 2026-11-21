import SwiftUI

struct ViewPreferencesSheet: View {
    @ObservedObject var preferences: ViewPreferences
    let page: ViewSettingsPage
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var rule = HighlightRule()
    @State private var mapping = ViewerMapping()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(page.title).font(.title2.bold())
            List(selection: $selection) {
                if page == .highlights {
                    ForEach(preferences.highlights) { rule in
                        HStack { Circle().fill(rule.color.color).frame(width: 10, height: 10); Text(rule.title) }.tag(rule.id)
                    }
                } else {
                    ForEach(preferences.mappings) { item in
                        HStack { Text(item.mime); Spacer(); Text(item.viewer.rawValue).foregroundStyle(.secondary) }.tag(item.id)
                    }
                }
            }
            .frame(height: 130)
            HStack {
                Button("新增", systemImage: "plus") { reset() }
                Button("删除", systemImage: "minus") {
                    if let selection { preferences.remove(selection, from: page); reset() }
                }.disabled(selection == nil)
            }
            if page == .highlights {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    GridRow { Text("主机"); TextField("任意主机", text: $rule.host) }
                    GridRow { Text("路径"); TextField("任意路径，或 /api/*", text: $rule.path) }
                    GridRow { Text("状态码"); TextField("任意状态，或 404、5xx", text: $rule.status) }
                    GridRow {
                        Text("标记颜色")
                        Picker("标记颜色", selection: $rule.color) {
                            ForEach(HighlightColor.allCases, id: \.self) { color in Text(color.title).tag(color) }
                        }.labelsHidden().fixedSize()
                    }
                }
                Text(rule.validationError ?? "多个条件同时匹配时，使用列表中第一条符合的规则。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("MIME 类型，例如 application/json", text: $mapping.mime)
                Picker("默认查看器", selection: $mapping.viewer) {
                    ForEach([SessionBodyPresentation.formatted, .raw, .hexadecimal]) { mode in Text(mode.rawValue).tag(mode) }
                }
                Text("适用于该类型的请求和响应。正文无法按指定格式显示时，自动使用可用格式。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if page == .highlights { preferences.save(rule); selection = rule.id }
                    else { preferences.save(mapping); selection = mapping.id }
                }
                .disabled(page == .highlights ? rule.validationError != nil : !mapping.isValid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: selection) { _, id in
            if let item = preferences.highlights.first(where: { $0.id == id }) { rule = item }
            if let item = preferences.mappings.first(where: { $0.id == id }) { mapping = item }
        }
        .padding(22)
        .frame(width: 475)
    }

    private func reset() {
        selection = nil
        rule = HighlightRule()
        mapping = ViewerMapping()
    }
}
