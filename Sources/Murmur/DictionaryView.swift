import SwiftUI

struct DictionaryView: View {
    @ObservedObject var store: DictionaryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One term per line. When a dictation contains something that matches or sounds like one of these, Murmur uses the exact spelling you give here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $store.termsText)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text("Saved automatically.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(minWidth: 380, minHeight: 320)
    }
}
