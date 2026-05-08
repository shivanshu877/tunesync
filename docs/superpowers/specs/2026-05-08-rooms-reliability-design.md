# Rooms Reliability — Design

Status: draft
Date: 2026-05-08
Scope: TuneSync `PeerMesh` hardening. No protocol break. Backwards compatible.

## Problem

Mesh connectivity is unreliable across the full failure surface: discovery sometimes silent, dial races leave duplicate or zero connections, dead TCP connections undetected, Wi-Fi switch and sleep-wake do not recover, and ghost peers linger after room changes. Users see "all of the above" depending on environment.

## Goals

- A peer that should be reachable on the same Wi-Fi connects within ~5 s of launch.
- A connected peer survives Wi-Fi reassociation and Mac sleep-wake without app restart.
- A dead peer is removed from the connected list within ~25 s of going away.
- No duplicate peer entries, no ghost peers after room change or kick/rejoin.
- Diagnostics surface enough state to debug the remaining tail in the field.

## Non-goals

- Cross-subnet discovery. mDNS / Bonjour same-LAN only.
- Auth / encryption beyond LAN trust model.
- Persisting room across launches (already handled in app prefs).
- Sync correctness — covered by separate spec (#5).

## Root-cause map

| Symptom | Cause | Fix |
| --- | --- | --- |
| No discovery | `NWListener` / `NWBrowser` can enter `.failed` silently; never restarted | Watch `stateUpdateHandler`; restart on `.failed` with backoff |
| Discovered, never connect | Both peers dial each other simultaneously; second `NWConnection` overwrites or races first | Tie-break: only the lower `senderId` dials, the higher only listens |
| Random drops | No TCP keepalive, no app-level liveness | Enable `NWProtocolTCP.Options.enableKeepalive`; add `.ping` / `.pong`; drop after silence window |
| Ghost / duplicate peers | Multi-conn race leaves orphan; `discovered` not pruned when TXT disappears | Single-connection invariant per peer; prune `discovered` on browse cycle that omits it |
| Wi-Fi switch / sleep | No path or wake hook | `NWPathMonitor` triggers full mesh restart on path change; `NSWorkspace.didWakeNotification` triggers restart |
| Stale peers after room change | mDNS cache may serve stale TXT before re-listen | 500 ms gap between cancel and re-listen; re-broadcast hello on first browse cycle |

## Architecture

All edits land in `Sources/TuneSyncCore/PeerMesh.swift` and `Sources/TuneSyncCore/Models.swift`. App-side adds a diagnostics view-model field; no new top-level component.

### New internal types (PeerMesh)

- `MeshSupervisor` — private inner type. Owns listener, browser, path monitor, and restart backoff schedule (1 s → 2 s → 5 s → 10 s, cap). Single source of truth for "is the mesh up". Restart counter exposed for diagnostics.
- `LivenessTracker` — per-peer `lastSeen` and `lastPingSent` timestamps. Driven by a 5 s timer. Sends `.ping` every 10 s of silence; drops peer after 25 s with no inbound traffic.

### Wire protocol additions

`SyncMessage` gains two cases:

```swift
case ping(PingMessage)   // { senderId, nonce }
case pong(PongMessage)   // { senderId, nonce }
```

These are mesh-internal. `SyncEngine.handleRemote` ignores them. Peers running older builds will fail to decode and skip — already handled by the existing `try? JSONDecoder().decode` guard, no crash, no behavior change for them.

### Dial tie-break

In `handleBrowse`, when a new discovered peer is found:

```
if senderId < discoveredId { dial }   // we are the dialer
else { wait for incoming hello }      // they will dial us
```

Removes the simultaneous-dial race entirely. If the higher-id peer never receives a dial within 5 s (e.g. asymmetric reachability), it falls back and dials.

### Hello collision

If `.hello` arrives for a `senderId` already in `peers`:

- Keep the older connection (lower `connectedAt`).
- Cancel the new one.
- Update `displayName` / `isHost` from the newer hello payload.

### Path / wake handling

- `NWPathMonitor` watches default path. On `.satisfied` → `.unsatisfied` transition, mark mesh degraded but do not tear down (transient blips). On `.unsatisfied` for ≥ 3 s, full restart. On any interface change (Wi-Fi network name, primary interface), full restart immediately.
- `NSWorkspace.shared.notificationCenter.addObserver(forName: .NSWorkspaceDidWake)` → full restart. `.willSleep` → graceful `.bye` broadcast then teardown.

### Room change

Existing flow already cancels listener/browser. Add a 500 ms `DispatchQueue.asyncAfter` before `startListener` / `startBrowser` to let the mDNS goodbye propagate. Re-broadcast hello to any peer that arrives in the first browse cycle to short-circuit handshake.

## Data flow

Unchanged for `.state` / `.hello` / `.bye`. New `.ping` / `.pong` are consumed inside `PeerMesh.handleIncomingBytes` and never reach the delegate.

## Diagnostics surface

Extend `ConnectionManagerView` diagnostics panel with:

- Listener state, browser state.
- Current `NWPath` status (interface, ipv4/ipv6, expensive flag).
- Per-peer: `lastPongMs`, `lastInboundMs`, `connDurationS`.
- Counters: listener restarts, browser restarts, path-triggered restarts, ping timeouts.

These are already partly present from the recent diagnostics commit; this expands the existing struct rather than introducing a new view.

## Testing

### Unit (`Tests/TuneSyncCoreTests/`)

- `PeerMeshTieBreakTests` — given two `senderId`s, only the lower dials.
- `PeerMeshLivenessTests` — inject clock; verify ping after 10 s silence, drop after 25 s.
- `PeerMeshHelloCollisionTests` — second hello for known peer keeps original connection.
- `PeerMeshRoomChangeTests` — room rename clears `discovered` and `peers`.

### Manual two-Mac (`docs/TESTING.md`)

Add scenarios:

1. Wi-Fi flip on one Mac (forget + rejoin same SSID). Mesh recovers within 10 s.
2. Sleep one Mac for 2 min, wake. Both reappear without restart.
3. Room rename on one side. Other side's stale peer entry clears within one browse cycle.
4. Kick + reconnect within 30 s. No duplicate entry.

## Rollout

Single PR, targets `master` after current `bug-fix-pb` lands. No migration. Bump to `0.2.8` on release.

## Out of scope / follow-ups

- Sync drift tightening — spec #5.
- Cross-subnet — would require Multipeer or a relay; deferred.
- Encryption — LAN trust model unchanged for now.
