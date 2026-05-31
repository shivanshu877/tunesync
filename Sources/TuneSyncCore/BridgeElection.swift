import Foundation

public enum BridgeElection {
    /// Returns true if the local Mac should run the WebSocket bridge.
    /// Rule: lowest senderId among all Macs in the room (including self) bridges.
    public static func shouldBridge(localId: String, peerIds: [String]) -> Bool {
        for pid in peerIds where pid < localId { return false }
        return true
    }
}
