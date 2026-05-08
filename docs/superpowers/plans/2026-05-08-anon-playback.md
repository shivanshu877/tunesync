# Anonymous Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** No-sign-in UX. App opens, search works, playback works without YouTube Music sign-in nag.

**Architecture:** Two changes: (a) extend InjectedJS with a MutationObserver that hides sign-in promos / popovers / backdrops as YT Music re-renders them; (b) add a native SwiftUI search bar above the WebView that navigates to `https://music.youtube.com/search?q=<query>`.

**Tech Stack:** SwiftUI, WKWebView, JavaScript (injected).

---

## Task 1: Sign-in modal hider in injected JS

**File:** `Sources/TuneSync/InjectedJS.swift`

- [ ] **Step 1: Add a hider routine + MutationObserver inside the IIFE.**

Append the following inside the existing `(function () { ... })()` block, before the closing `console.info(...)`:

```javascript
// Sign-in nag hider. YT Music throws up a signin promo / popup container
// shortly after landing on the home page, even though playback works
// signed-out. We hide them as they appear so the user never sees a
// blocking dialog.
function hideSigninNag() {
  var sels = [
    "ytmusic-signin-prompt",
    "ytmusic-popup-container",
    "ytmusic-mealbar-promo-renderer",
    "tp-yt-iron-overlay-backdrop",
    "ytmusic-you-there-renderer"
  ];
  sels.forEach(function (sel) {
    document.querySelectorAll(sel).forEach(function (el) {
      el.style.setProperty("display", "none", "important");
      el.setAttribute("aria-hidden", "true");
    });
  });
}

hideSigninNag();
var nagObserver = new MutationObserver(function () { hideSigninNag(); });
nagObserver.observe(document.documentElement, { childList: true, subtree: true });
```

- [ ] **Step 2: Bump injected-version log line to `v0.2.10`.**

Existing line: `console.info("[tunesync] injected (v0.2.9)");` → bump to `v0.2.10`.

- [ ] **Step 3: Build.**

```bash
swift build
```

- [ ] **Step 4: Commit.**

```bash
git add Sources/TuneSync/InjectedJS.swift
git commit -m "feat(player): hide YT Music sign-in nag with MutationObserver"
```

---

## Task 2: Native search bar above WebView

**Files:**
- Modify: `Sources/TuneSync/WebViewHost.swift` (expose a way to load a URL)
- Modify: `Sources/TuneSync/ContentView.swift` (add search bar)

- [ ] **Step 1: Add a binding-driven URL load to `WebViewHost`.**

`WebViewHost` currently loads `https://music.youtube.com/` once in `makeNSView`. We need a way for the search bar to push a new URL. Use a shared `WKWebView` via the coordinator.

Easiest path: add a `weakWebView` reference on `PlayerController` already (`player.attach(to:)` stores it). Expose a small helper on `PlayerController`:

```swift
public func navigate(to url: URL) {
    guard let wv = webView else { return }
    wv.load(URLRequest(url: url))
}
```

Place it next to `applyState`. `webView` is already a stored weak.

- [ ] **Step 2: Add search bar to `ContentView`.**

In `Sources/TuneSync/ContentView.swift`, the body is:

```swift
public var body: some View {
    HStack(spacing: 0) {
        VStack(spacing: 0) {
            WebViewHost(player: rt.player)
                .frame(minWidth: 800, minHeight: 600)
            StatusBar(...)
        }
        ...
    }
}
```

Add a SwiftUI `@State private var searchQuery: String = ""` field and a search field above the WebViewHost:

```swift
public var body: some View {
    HStack(spacing: 0) {
        VStack(spacing: 0) {
            searchBar
            WebViewHost(player: rt.player)
                .frame(minWidth: 800, minHeight: 600)
            StatusBar(...)
        }
        ...
    }
    ...
}

private var searchBar: some View {
    HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
        TextField("Search YouTube Music…", text: $searchQuery, onCommit: submitSearch)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
        if !searchQuery.isEmpty {
            Button(action: { searchQuery = "" }) {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(NSColor.windowBackgroundColor))
}

private func submitSearch() {
    let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return }
    let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
    if let url = URL(string: "https://music.youtube.com/search?q=\(encoded)") {
        rt.player.navigate(to: url)
    }
}
```

`@State private var searchQuery: String = ""` declared inside `ContentView` near `showSidebar`.

- [ ] **Step 3: Build + run quick sanity.**

```bash
swift build
```

- [ ] **Step 4: Commit.**

```bash
git add Sources/TuneSync/PlayerController.swift Sources/TuneSync/ContentView.swift
git commit -m "feat(ui): native search bar above WebView for signed-out search"
```

---

## Task 3: Manual scenarios + version bump

- [ ] **Step 1: Append to `docs/TESTING.md`:**

```markdown
## Anonymous-playback scenarios (post 0.2.10)

### Cold start, no sign-in

1. Clear app data: `xattr -dr com.apple.quarantine /Applications/TuneSync.app && rm -rf ~/Library/WebKit/TuneSync ~/Library/Caches/TuneSync`.
2. Launch. App lands on YT Music home.
3. No sign-in modal blocks the view (it may briefly flash, but disappears).
4. Top of window shows a search bar.

### Search and play

1. Type "lofi" in the search bar; press Enter.
2. WebView navigates to a YT Music search result page.
3. Click any track. Plays without a sign-in prompt.

### Two Macs, neither signed in

1. Both Macs on same Wi-Fi, both signed-out.
2. Mac A plays a track via search. Mac B receives state and plays the same track in sync.
```

- [ ] **Step 2: Bump version.**

`sed -i '' 's/0\.2\.9/0.2.10/g' Makefile`

- [ ] **Step 3: Commit.**

```bash
git add docs/TESTING.md Makefile
git commit -m "build: bump to 0.2.10 for anon-playback release"
```

---

## Self-Review

| Spec section | Task |
| --- | --- |
| Sign-in modal hider | 1 |
| Search bar | 2 |
| Default landing | (kept on `/` — modal hider does the work) |
| Manual tests | 3 |

No placeholders. Names consistent.
