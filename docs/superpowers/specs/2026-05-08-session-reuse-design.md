# Session Reuse — Design

Status: draft
Date: 2026-05-08
Scope: let TuneSync borrow an existing YouTube Music session from the user's main browser (Chrome / Brave / Safari / Edge) so they don't have to sign in twice.

## Problem

Even with anonymous playback (#1) working, signed-in features (library, personalized mixes, history) require auth. Asking the user to sign in *inside the app's WKWebView* means a second login flow, second 2FA, second device prompt. Most users already have YT Music open in their main browser; we should reuse that.

## Goals

- One-click "Use my Brave / Chrome / Safari session" → app loads YT Music signed in.
- No password / token prompt inside the app.
- Reversible: user can revoke at any time, cookies are wiped.
- Honest: explicit consent, explicit listing of what gets read.

## Non-goals

- Background or silent cookie scraping. Always user-initiated.
- Cross-account: only the browser's currently active YT Music session is imported.
- Persisting the imported session beyond the WKWebView's data store lifetime.

## Constraints / risks

- Chrome / Brave / Edge encrypt their cookie store using a key in the macOS Keychain (`Chrome Safe Storage` / `Brave Safe Storage`). Reading triggers a Keychain prompt the first time. Acceptable, but must be communicated.
- Safari stores cookies in a binary format under `~/Library/Cookies/Cookies.binarycookies`. Read access is sandbox-restricted; entitlement needed.
- TuneSync is currently ad-hoc-signed (per Makefile / README). Sandboxing isn't enforced today, so reading is mechanically possible. Long-term hardening (notarization, App Sandbox) would force a different approach (e.g., a browser extension that pushes cookies in).

## Approach

### A. Import flow (recommended for v1)

1. User clicks "Import session" in TuneSync settings.
2. Sheet shows: "Pick a browser to import from: Brave / Chrome / Safari / Edge". Lists only browsers detected on disk.
3. User picks one. App reads only the cookies for `*.youtube.com` and `*.google.com` (the auth set YT Music needs).
4. App writes those cookies into the WKWebView's `WKWebsiteDataStore` cookie jar.
5. WebView reloads. User is signed in.
6. A "Clear imported session" button wipes the data store.

### B. Browser extension (defer to v2)

A small browser extension exports cookies on demand to a localhost endpoint TuneSync exposes. Avoids Keychain prompts and Safari sandbox issues. More work; deferred.

## Components

- `Sources/TuneSync/SessionImport/CookieReader.swift` (new). One reader per browser:
  - `ChromiumCookieReader` (Chrome, Brave, Edge — same SQLite + Keychain model, profile path differs).
  - `SafariCookieReader` (binarycookies parser).
- `Sources/TuneSync/SessionImport/CookieImportSheet.swift` (new). SwiftUI sheet with browser picker + status.
- `Sources/TuneSync/WebViewHost.swift`. Inject cookies into `WKHTTPCookieStore` before first load (or trigger reload after import).
- `Sources/TuneSync/ContentView.swift`. Settings link to open the sheet.

### Chromium cookie reader detail

Path: `~/Library/Application Support/<Browser>/Default/Cookies` (SQLite). Encrypted-value column needs the Keychain item `<Browser> Safe Storage` (service name string varies per browser). PBKDF2-decrypt with `iter=1003`, `salt="saltysalt"` per Chromium source. Same algorithm for all Chromium-based browsers.

Filter rows: `host_key LIKE '%.youtube.com'` OR `host_key LIKE '%.google.com'`.

### Safari cookie reader detail

Parse `Cookies.binarycookies` (well-documented format). No encryption. May require Full Disk Access permission, which we surface as an explicit prompt in the sheet with a deep link to System Settings.

## UX / consent

The import sheet must clearly state:

> TuneSync will read your YouTube and Google cookies from {Browser} so it can sign you in. macOS may show a Keychain prompt; that's normal. Cookies are stored only inside TuneSync's WebView and removed when you click "Clear imported session" or quit the app (if "remember session" is off).

A "remember after quit" toggle (default off).

## Privacy / safety

- Read scope: only `*.youtube.com`, `*.google.com`. Code-reviewed query, not a wildcard.
- No network exfil. Cookies never leave the local process.
- "Clear imported session" wipes the WebView data store entirely.
- Logs (`Log.session`) record *that* an import happened, never cookie values.

## Testing

### Unit

- `ChromiumCookieReaderTests` — given a fixture SQLite DB and a known key, decrypts a row correctly. Use a static fixture, not a real browser.
- `SafariCookieReaderTests` — parse a fixture binarycookies file.
- Filter test — only YouTube/Google cookies are returned.

### Manual

1. Sign into YT Music in Brave on the test Mac. Click "Import session" → Brave. Approve Keychain prompt. Verify TuneSync's player shows signed-in state.
2. Same for Chrome.
3. Same for Safari (with FDA granted).
4. "Clear imported session" returns to anonymous state.

## Rollout

Significant PR; multiple files. Land on its own. Bump minor version (0.3.0). README gets a "Session import" section.

## Out of scope / follow-ups

- Browser extension method (B).
- Auto-refresh when browser cookies rotate.
- Firefox support (Firefox uses its own SQLite at `cookies.sqlite`, plaintext — easy add later).
