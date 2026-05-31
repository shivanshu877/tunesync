# Ad-Free Renderer — Design

Status: draft (recommend deferral)
Date: 2026-05-08
Scope: explore making TuneSync ad-free without a YT Premium subscription.

## Problem

Free YT Music plays ads between tracks. Ads desync rooms (only one Mac sees the ad), waste time, and feel jarring in a shared-listening context. Users asked: "use Brave so it's ad-free."

## The Brave-renderer ask

"Use Brave instead of WKWebView." Three interpretations:

1. **Embed Chromium / Brave engine in TuneSync.** Bundle CEF or similar. Adds ~150–250 MB to the DMG, big maintenance burden, code-signing complexity, and Brave's adblock isn't trivially separable from the rest of the browser.
2. **Launch external Brave and remote-control it.** Use Brave's CDP (Chrome DevTools Protocol) to drive playback. Loses the in-app feel; users see Brave open, not TuneSync. Sync still works because we control via CDP. Workable but ugly.
3. **Reproduce Brave's adblock inside WKWebView.** Use `WKContentRuleList` with EasyList / EasyPrivacy filter rules. Native to WebKit, no external process. This is the closest "ad-free in-app" option.

## Recommendation: option 3, deferred

Option 3 (content rules in WKWebView) gives ~80% of the benefit with ~5% of the work of options 1 or 2. But it has real risks:

- YT Music's first-party ad delivery is hard to block without breaking playback. Many ads are served from the same `*.googlevideo.com` host as the music itself. Heavy filter rules tend to break the player.
- Ad rules need ongoing maintenance (filter list updates).
- Likely violates YT Music ToS.

These are policy / maintenance concerns, not engineering concerns. The other four specs deliver concrete user-visible wins (rooms work, sync is tight, no sign-in needed, web clients join). Ad-blocking is the lowest-yield, highest-risk slice.

**Proposal:** finish #4, #5, #1, #2, #6 first. Revisit ad-blocking after, with the option to:

- Just recommend YT Premium in the README.
- Or ship a "skip-ad detector": when an ad starts on the host, *all* peers mute and pause; when the ad ends, all resume. This solves the desync pain of ads without blocking them. Probably the right call.

## Skip-ad detector (alternative deliverable)

If we drop ad-blocking entirely and instead lean on the existing ad detection (`isAdShowing()` already in `InjectedJS.swift`), we can:

1. Host detects ad → broadcasts `state` with `playing=false` + a flag `adOnHost=true`.
2. Guests see the flag → mute their player and show an "ad on host" pill in the UI.
3. Host detects ad ended → broadcasts new state, guests unmute and resume.

This is a one-day change inside the sync engine. No legal risk, no maintenance, solves the room-experience problem. Belongs as a follow-up to spec #5.

## Decision required

Two options to put before the user:

- **A. Skip ad-blocking entirely**, fold the skip-ad-detector idea into the sync-tightness spec or as a small follow-up. Recommend YT Premium in README.
- **B. Build content-rule adblock anyway** (option 3). Maintenance burden, ToS risk, may break YT Music. Probably 1-2 weeks of fiddling with filter lists.

Recommendation: **A**. We can ship A inside spec #5 with no extra spec.

## If user picks B (sketch only)

- `Sources/TuneSync/AdBlock/RuleList.swift` — load EasyList for YT, compile to `WKContentRuleList`.
- Update path: fetch rules from a pinned URL on launch, fall back to bundled copy.
- Diagnostics: count blocked requests.
- Testing: manual; no good unit-test surface.

## Out of scope

- Bundling CEF / Chromium.
- External Brave automation.
- Audio-stream sniffing / muxing.
