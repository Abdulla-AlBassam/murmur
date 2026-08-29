import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: HistoryStore

    var body: some View {
        VStack(spacing: 0) {
            if store.entries.isEmpty {
                Spacer()
                Text("No dictations yet")
                    .foregroundStyle(.secondary)
                Text("Hold fn and speak; everything you dictate lands here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                List(store.entries) { entry in
                    HistoryRow(entry: entry)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("\(store.entries.count) of 100 kept")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear History") { store.clear() }
                    .disabled(store.entries.isEmpty)
            }
            .padding(8)
        }
        .frame(minWidth: 440, minHeight: 320)
    }
}

private struct HistoryRow: View {
    let entry: DictationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.text)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text(entry.date.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if entry.raw != nil {
                    Text("cleaned")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("Raw transcript: \(entry.raw ?? "")")
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
        .padding(.vertical, 4)
    }
}
