import SwiftUI
import TuneSyncCore

public struct ConnectionManagerView: View {
    @ObservedObject var rt: AppRuntime
    @State private var roomDraft: String = ""

    public init(rt: AppRuntime) {
        self.rt = rt
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    roomSection
                    connectedSection
                    discoveredSection
                    diagnosticsSection
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
        }
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { roomDraft = rt.currentRoom }
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.2.fill")
                .foregroundColor(.accentColor)
            Text("Connection Manager")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var roomSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("ROOM")
            HStack(spacing: 8) {
                TextField("default", text: $roomDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyRoom() }
                Button("Switch") { applyRoom() }
                    .disabled(roomDraft.trimmingCharacters(in: .whitespaces).isEmpty
                              || roomDraft == rt.currentRoom)
            }
            Text("Only Macs in the same room sync. Switching drops all peers.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("CONNECTED (\(rt.connectedPeers.count))")
            if rt.connectedPeers.isEmpty {
                Text("No peers connected.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(rt.connectedPeers, id: \.senderId) { peer in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(peer.senderId.prefix(8))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Kick") { rt.kickPeer(peer.senderId) }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                            .font(.system(size: 11))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var discoveredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("NEARBY (\(rt.discoveredPeers.count))")
            if rt.discoveredPeers.isEmpty {
                Text("No other Macs discovered yet.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(rt.discoveredPeers, id: \.senderId) { peer in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.gray.opacity(0.5))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(peer.senderId.prefix(8))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Connect") { rt.reconnectPeer(peer.senderId) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("DIAGNOSTICS")

            // My current state
            VStack(alignment: .leading, spacing: 4) {
                Text("This Mac (\(String(rt.senderId.prefix(8))))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                if let s = rt.lastLocalState {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(s.playing ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text("\(s.videoId.prefix(11)) @ \(formatT(s.t))")
                            .font(.system(size: 11, design: .monospaced))
                    }
                } else {
                    Text("No state yet — waiting for YT Music")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                if let d = rt.lastDiag {
                    if let why = d.skipped {
                        Text("JS skipped last report: \(why)")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                    if d.ad == true {
                        Text("Ad detected — outbound suppressed")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.04))
            .cornerRadius(6)

            // Last 8 sync events
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent sync events")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                if rt.syncHistory.isEmpty {
                    Text("No events yet.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(rt.syncHistory.suffix(8).enumerated().reversed()), id: \.offset) { _, e in
                        historyRow(e)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.04))
            .cornerRadius(6)
        }
    }

    private func historyRow(_ e: SyncEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(e.direction.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(directionColor(e.direction))
                .frame(width: 50, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(e.videoId.prefix(11)) @ \(formatT(e.t)) \(e.playing ? "▶" : "⏸")")
                    .font(.system(size: 10, design: .monospaced))
                if let n = e.note {
                    Text(n)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Text(formatAge(e.at))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private func directionColor(_ d: SyncEntry.Direction) -> Color {
        switch d {
        case .sent: return .blue
        case .recv: return .purple
        case .applied: return .green
        case .skipped: return .orange
        }
    }

    private func formatT(_ t: Double) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatAge(_ d: Date) -> String {
        let dt = Date().timeIntervalSince(d)
        if dt < 1 { return "now" }
        if dt < 60 { return "\(Int(dt))s" }
        return "\(Int(dt / 60))m"
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .tracking(0.5)
    }

    private func applyRoom() {
        let trimmed = roomDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != rt.currentRoom else { return }
        rt.changeRoom(trimmed)
    }
}
