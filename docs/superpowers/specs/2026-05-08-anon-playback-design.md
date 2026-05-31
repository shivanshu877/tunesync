# Anonymous Playback — Design

Status: draft
Date: 2026-05-08
Scope: TuneSync usable end-to-end without YouTube Music sign-in. Two Macs in a room can sync playback even if neither is logged in.

## Problem

Today the WKWebView lands on `music.youtube.com`, which auto-redirects to a sign-in wall for full features. Skips, library, history, recommendations — all gated. A first-launch user sees a sign-in nag and may bounce. Per-Mac sign-in is also a friction point for casual rooms.

## Goals

- App opens to a working YT Music player without sign-in.
- A non-signed-in host can play any public song / video by ID, and guests sync.
- Sign-in remains available for users who want personalized features.

## Non-goals

- Working around YT Music's signed-out limits (skip count, ad load). Those are policy.
- Bypassing ads. Covered separately by spec #3.
- Playlists / library without sign-in.

## Approach

YT Music's signed-out mode actually plays public tracks if you navigate directly to `https://music.youtube.com/watch?v=<id>`. The sign-in wall mainly triggers on the home/library landing pages. Two changes:

### 1. Default landing page

Change initial URL from `https://music.youtube.com` to a known-good public track or to `https://music.youtube.com/watch?v=<seed>` where `<seed>` is a stable public video. First-launch UX: a small "what do you want to play?" search bar that issues a YT Music search URL (`/search?q=...`), which works signed-out for browsing.

Better: open to `/watch?v=<seed>` with a small toolbar overlay above the WebView containing a search box. Search submits to `/search?q=<query>` inside the same WebView.

### 2. Bypass sign-in nag

YT Music shows a sign-in modal on landing. Inject CSS to hide the modal and a small JS `MutationObserver` to dismiss it when it reappears. Already half-done in `InjectedJS.swift`; extend it.

```js
// hide signin promo / modal
var hide = document.querySelectorAll(
  "ytmusic-signin-prompt, ytmusic-popup-container, tp-yt-iron-overlay-backdrop"
);
hide.forEach(function(el) { el.style.display = "none"; });
```

Run this in a `MutationObserver` on `document.body`.

### 3. Search UX

A native SwiftUI search field above the WebView. Submitting navigates the WebView to `https://music.youtube.com/search?q=<query>`. User clicks a result; player starts; sync engine picks up `videoId` from URL as before.

This avoids relying on YT Music's signed-out home page (which is sometimes empty).

## Components

- `Sources/TuneSync/ContentView.swift` — add search bar above WebView host.
- `Sources/TuneSync/WebViewHost.swift` — accept an initial URL prop (today probably hard-coded).
- `Sources/TuneSync/InjectedJS.swift` — sign-in modal hider via MutationObserver.

## Sign-in still works

Users who want sign-in click the existing YT Music "Sign in" link in the top-right. That flow remains untouched. We hide *prompts*, not the sign-in button.

## Testing

### Manual

1. Fresh install (cleared WebView cookies). App opens to a search-able state with a public track loaded.
2. Search "lo-fi". Click first result. Plays without sign-in prompt blocking.
3. Two Macs both signed-out, same room. Host plays. Guest syncs.

### Unit

- N/A — UX change. Existing PlayerController tests cover the sync side.

## Open questions

- Pick a "seed" public track that is unlikely to be region-blocked or removed. Or skip seed and land on `/search` with an empty query, which YT Music renders as a search page.

## Rollout

Single small PR. No protocol change. Bump patch version.

## Out of scope / follow-ups

- Personalized recommendations without sign-in (impossible).
- Library import from a signed-in account on another device — covered by session-reuse spec (#2).
