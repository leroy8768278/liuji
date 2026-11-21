import SwiftUI

struct SessionActivitySheet: View {
    @ObservedObject var store: CaptureStore
    let errors: Bool
    @Environment(\.dismiss) private var dismiss

    private var rows: [CaptureSession] {
        store.liveSessions.reversed().filter {
            errors ? $0.error != nil || ($0.statusCode ?? 0) >= 400 : !$0.finished
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(errors ? "会话错误" : "已录制的活动连接").font(.title2.bold())
            if rows.isEmpty {
                Text(errors ? "当前录制中没有错误。" : "当前录制中没有活动连接。")
                    .foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                List(rows) { session in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(session.method)  \(session.url)").lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            if let error = session.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let code = session.statusCode { Text(String(code)).monospacedDigit() }
                        if !errors { Button("终止") { store.terminate(session.id) } }
                    }
                }
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22).frame(width: 640, height: 350)
    }
}
