import SwiftUI

struct LogView: View {
    @Environment(ConsoleModel.self) private var model

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("每次调用的请求 / 结果（\(model.log.count)）")
                Spacer()
                Button("清空") { model.log = [] }
            }
            List(model.log.reversed()) { e in
                VStack(alignment: .leading) {
                    HStack {
                        Text(e.time, style: .time)
                        Text(e.title).bold().foregroundStyle(e.isError ? .red : .primary)
                    }
                    Text(e.body).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }
}
