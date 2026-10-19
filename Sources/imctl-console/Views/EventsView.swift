import SwiftUI

struct EventsView: View {
    @Environment(ConsoleModel.self) private var model
    @State private var filter = ""
    @State private var from = ""

    var rows: [EventRow] {
        filter.isEmpty ? model.events : model.events.filter { $0.kind.contains(filter) || $0.payload.contains(filter) }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading) {
            HStack(spacing: 12) {
                Toggle("实时跟踪（每 3 s event.replay）", isOn: $model.tailing)
                Button("拉取一次") { Task { await model.tailOnce() } }
                Spacer()
                Text("游标 \(model.lastEventId) · \(rows.count) 条").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                TextField("从事件 id 之后重放", text: $from).frame(width: 160)
                Button("重置游标") { model.resetTail(from: Int64(from) ?? 0); Task { await model.tailOnce() } }
                TextField("过滤 kind / payload", text: $filter).frame(width: 200)
                Spacer()
            }
            if let hint = model.daemonHint { Text(hint).font(.caption).foregroundStyle(.orange) }
            if let e = model.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            Table(rows) {
                TableColumn("id") { Text("\($0.id)") }.width(60)
                TableColumn("时间") { Text(Date(timeIntervalSince1970: Double($0.tsMs) / 1000), style: .time) }.width(80)
                TableColumn("kind") { Text($0.kind) }.width(160)
                TableColumn("payload") { Text($0.payload).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled) }
            }
        }
    }
}
