import SwiftUI

struct BreakpointPendingRow: View {
    let store: CaptureStore
    let session: CaptureSession
    @State private var name = ""
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup {
                let fields = session.breakpointPhase == .response ? session.responseHeaders : session.requestHeaders
                Text(fields.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
                    .font(.caption.monospaced()).textSelection(.enabled)
                if session.allowsBreakpointHeaderEdit == true {
                    TextField("X-Debug- 标头名", text: $name)
                    TextField("标头值", text: $value)
                    Button("应用修改并继续") {
                        store.resolveBreakpoint(session.id, proceed: true, edit: CaptureHeader(name: name, value: value))
                    }.disabled(CaptureHeader(name: name, value: value).validatedBreakpointHeader == nil)
                }
            } label: {
                Text("\(session.breakpointPhase?.title ?? "请求") · \(session.method)  \(session.url)")
                    .lineLimit(2).truncationMode(.middle)
            }
            HStack {
                Spacer()
                Button("中止") { store.resolveBreakpoint(session.id, proceed: false) }
                Button("原样放行") { store.resolveBreakpoint(session.id, proceed: true) }
            }
        }
        .font(.caption)
        .textFieldStyle(.roundedBorder)
        .padding(8)
        .background(WorkspaceTheme.sidebar, in: RoundedRectangle(cornerRadius: 7))
    }
}
