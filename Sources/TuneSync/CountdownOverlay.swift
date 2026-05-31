import SwiftUI

/// Big translucent banner that appears when a scheduled play is pending.
/// Counts down to zero, shows network-delay status, then fades out the
/// instant the schedule fires (every Mac in the room hits play together).
public struct CountdownOverlay: View {
    @ObservedObject var rt: AppRuntime
    @State private var now: Date = Date()

    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    public init(rt: AppRuntime) {
        self.rt = rt
    }

    public var body: some View {
        Group {
            if let target = rt.scheduledAtMs {
                let nowMs = Int64(now.timeIntervalSince1970 * 1000)
                let remainingMs = max(0, target - nowMs)
                if remainingMs > 0 {
                    panel(remainingMs: remainingMs)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .onReceive(tick) { now = $0 }
        .animation(.easeOut(duration: 0.25), value: rt.scheduledAtMs)
    }

    @ViewBuilder
    private func panel(remainingMs: Int64) -> some View {
        let secs = Double(remainingMs) / 1000.0
        let bigDigit = Int(ceil(secs))

        VStack(spacing: 10) {
            Text(bigDigit > 0 ? "\(bigDigit)" : "GO")
                .font(.system(size: 84, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3), value: bigDigit)

            Text("Playing on every Mac in the room")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.85))

            if rt.networkDelayMs > 200 {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 11))
                    Text("Your network was \(rt.networkDelayMs) ms slow — syncing")
                        .font(.system(size: 12))
                }
                .foregroundColor(.yellow)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.4))
                .cornerRadius(20)
                .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(minWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        )
    }
}
