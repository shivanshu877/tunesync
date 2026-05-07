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
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
        }
        .frame(width: 280)
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
