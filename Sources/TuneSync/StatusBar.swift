import SwiftUI

public struct StatusBar: View {
    @Binding public var peerCount: Int
    @Binding public var lastWriter: String?
    @Binding public var adShowing: Bool

    public init(peerCount: Binding<Int>, lastWriter: Binding<String?>, adShowing: Binding<Bool>) {
        self._peerCount = peerCount
        self._lastWriter = lastWriter
        self._adShowing = adShowing
    }

    public var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(peerCount > 0 ? Color.green : Color.yellow)
                .frame(width: 8, height: 8)
            Text(peerCount > 0
                 ? "\(peerCount) peer\(peerCount == 1 ? "" : "s")"
                 : "solo mode")
                .font(.system(size: 12, weight: .medium))
            if let writer = lastWriter, !writer.isEmpty {
                Text("· last change by \(writer)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if adShowing {
                Text("ad — sync paused")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
            }
            Text("room: default")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(NSColor.separatorColor)), alignment: .top)
    }
}
