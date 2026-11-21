import SwiftUI

struct SessionFindSheet: View {
    let session: CaptureSession
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var matchIndex = 0
    @State private var index: SessionFindIndex?

    var body: some View {
        VStack(spacing: 0) {
            header
            WorkspaceTheme.rule.frame(height: 1)

            if let index, !query.isEmpty {
                results(index.search(query))
            } else if index == nil {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder("输入要查找的文字", hint: "搜索请求地址、标头和正文预览。")
            }

            WorkspaceTheme.rule.frame(height: 1)
            HStack(spacing: 12) {
                if index?.limitedBody == true {
                    Text("正文查找覆盖已保留文本的开头。")
                        .font(.system(size: 11))
                        .foregroundStyle(WorkspaceTheme.muted)
                }
                Spacer()
                Button { dismiss() } label: {
                    Text("完成").padding(.horizontal, 15).frame(height: 30)
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(WorkspaceButtonStyle(prominent: true))
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(WorkspaceTheme.chrome)
        }
        .frame(width: 610, height: 470)
        .foregroundStyle(WorkspaceTheme.ink)
        .background(WorkspaceTheme.canvas)
        .onChange(of: query) { matchIndex = 0 }
        .task(id: session.id) {
            index = SessionFindIndex(session)
            searchFocused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 5) {
                Text("查找会话")
                    .font(.system(size: 19, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(session.url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(WorkspaceTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.url)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(WorkspaceTheme.muted)
                    .accessibilityHidden(true)
                TextField("搜索文字", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .disableAutocorrection(true)
                    .accessibilityLabel("搜索会话文字")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(WorkspaceTheme.muted)
                        .accessibilityLabel("清除查找文字")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(WorkspaceTheme.canvas, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(WorkspaceTheme.rule) }
        }
        .padding(17)
        .background(WorkspaceTheme.chrome)
    }

    @ViewBuilder
    private func results(_ report: SessionFindIndex.Report) -> some View {
        if report.total == 0 {
            placeholder("没有匹配结果", hint: "试试另一段文字。")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("\(report.total.formatted()) 处匹配")
                        .font(.system(size: 11, weight: .semibold))
                    if report.total > report.snippets.count {
                        Text("显示前 \(report.snippets.count) 处")
                            .font(.system(size: 11))
                            .foregroundStyle(WorkspaceTheme.muted)
                    }
                    Spacer()
                    Text("\(matchIndex + 1) / \(report.snippets.count)").font(.caption.monospacedDigit())
                    Button { move(by: -1, count: report.snippets.count) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .accessibilityLabel("上一处匹配").keyboardShortcut("g", modifiers: [.command, .option])
                    Button { move(by: 1, count: report.snippets.count) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel("下一处匹配").keyboardShortcut("g", modifiers: .command)
                }
                .padding(.horizontal, 17)
                .frame(height: 32)
                WorkspaceTheme.rule.frame(height: 1)
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(report.snippets) { snippet in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(snippet.scope)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(WorkspaceTheme.muted)
                                    let match = Text(verbatim: snippet.match).bold().foregroundColor(WorkspaceTheme.accent)
                                    Text("\(snippet.before)\(match)\(snippet.after)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                }
                                .padding(.horizontal, 17)
                                .padding(.vertical, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(snippet.id == matchIndex ? WorkspaceTheme.accentFill : .clear)
                                .id(snippet.id)
                                WorkspaceTheme.rule.frame(height: 1)
                            }
                        }
                    }
                    .id(query)
                    .onChange(of: matchIndex) { _, next in scroll.scrollTo(next, anchor: .center) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func move(by delta: Int, count: Int) {
        guard count > 0 else { return }
        matchIndex = (matchIndex + delta + count) % count
    }

    private func placeholder(_ title: String, hint: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(WorkspaceTheme.accent)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(hint).font(.system(size: 11)).foregroundStyle(WorkspaceTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SessionFindIndex {
    struct Snippet: Identifiable {
        let id: Int
        let scope: String
        let before: String
        let match: String
        let after: String
    }

    struct Report {
        let total: Int
        let snippets: [Snippet]
    }

    private struct Document {
        let scope: String
        let text: NSString

        init(_ scope: String, _ text: String) {
            self.scope = scope
            self.text = text as NSString
        }
    }

    let limitedBody: Bool
    private let documents: [Document]
    private static let bodyBudget = 256 * 1_024
    private static let resultLimit = 100

    init(_ session: CaptureSession) {
        var documents = [Document("请求地址", session.url)]
        documents += session.requestHeaders.map { Document("请求标头", "\($0.name): \($0.value)") }
        documents += session.responseHeaders.map { Document("响应标头", "\($0.name): \($0.value)") }
        var limited = false
        if !session.isTunnel {
            let bodies = [
                ("请求正文", session.requestBody, session.requestPreviewHeaders, session.requestBodyBytes ?? session.requestBody.count),
                ("响应正文", session.responseBody, session.responsePreviewHeaders, session.responseBytes)
            ].compactMap { name, data, headers, count -> (String, String, Bool)? in
                guard !data.isEmpty, let text = CaptureBodyDecoding.previewText(data, headers: headers) else { return nil }
                return (name, text, count > data.count)
            }
            let budget = Self.bodyBudget / max(1, bodies.count)
            for (name, text, incomplete) in bodies {
                var prefix = text.utf8.prefix(budget)
                let clipped = prefix.endIndex != text.utf8.endIndex
                while prefix.endIndex.samePosition(in: text.unicodeScalars) == nil {
                    prefix = prefix.dropLast()
                }
                documents.append(Document(name, String(decoding: prefix, as: UTF8.self)))
                limited = limited || incomplete || clipped
            }
        }
        self.documents = documents
        limitedBody = limited
    }

    func contains(_ query: String) -> Bool {
        !query.isEmpty && documents.contains { $0.text.range(of: query, options: .caseInsensitive).location != NSNotFound }
    }

    func search(_ query: String) -> Report {
        guard !query.isEmpty else { return Report(total: 0, snippets: []) }
        var total = 0
        var snippets: [Snippet] = []
        for document in documents {
            let text = document.text
            var start = 0
            while start < text.length {
                let range = NSRange(location: start, length: text.length - start)
                let match = text.range(of: query, options: .caseInsensitive, range: range)
                guard match.location != NSNotFound, match.length > 0 else { break }
                if snippets.count < Self.resultLimit {
                    snippets.append(Self.snippet(total, document: document, match: match))
                }
                total += 1
                start = NSMaxRange(match)
            }
        }
        return Report(total: total, snippets: snippets)
    }

    private static func snippet(_ id: Int, document: Document, match: NSRange) -> Snippet {
        let text = document.text
        let end = NSMaxRange(match)
        let leading = NSRange(location: max(0, match.location - 42), length: min(42, match.location))
        let trailing = NSRange(location: end, length: min(58, text.length - end))
        let before = leading.length == 0 ? leading : text.rangeOfComposedCharacterSequences(for: leading)
        let after = trailing.length == 0 ? trailing : text.rangeOfComposedCharacterSequences(for: trailing)
        return Snippet(id: id, scope: document.scope,
                       before: (before.location > 0 ? "…" : "") + singleLine(text.substring(with: before)),
                       match: singleLine(text.substring(with: match)),
                       after: singleLine(text.substring(with: after)) + (NSMaxRange(after) < text.length ? "…" : ""))
    }

    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
