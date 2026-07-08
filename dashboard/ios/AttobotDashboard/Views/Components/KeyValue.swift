import SwiftUI

/// Label/value list with a fixed-width muted key (120pt). Mirrors the RN
/// `KeyValue` component / web `.kv <dl>`.
struct KeyValue: View {
    let items: [(String, AnyView)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 12) {
                    Text(item.0)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 120, alignment: .leading)
                    item.1
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
            }
        }
    }
}
