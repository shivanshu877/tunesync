import Foundation

enum InjectedJS {
    static let source: String = #"""
(function () {
  if (window.__TUNESYNC_INSTALLED__) return;
  window.__TUNESYNC_INSTALLED__ = true;

  // Cooldown to break echo loops: when tunesyncApplyState changes the
  // player, the resulting `seeked` / `play` / `pause` events would
  // otherwise feed back into reportState and broadcast — peers would
  // bounce state back and forth. We mute reportState for COOLDOWN_MS
  // after any apply that actually changed something.
  //
  // BUT: a real user-initiated track change during the cooldown window
  // must NOT be suppressed. We track lastAppliedVideoId and bypass the
  // cooldown when the current videoId differs (= real new track).
  var COOLDOWN_MS = 1500;
  var lastAppliedAt = 0;
  var lastAppliedVideoId = null;
  var lastReportedVideoId = null;

  function post(payload) {
    try {
      window.webkit.messageHandlers.tunesync.postMessage(payload);
    } catch (e) {
      console.error("[tunesync] post failed", e);
    }
  }

  function getVideo() {
    return document.querySelector("video");
  }

  function getVideoId() {
    // 1. URL search param (most reliable when on /watch)
    try {
      var url = new URL(window.location.href);
      var v = url.searchParams.get("v");
      if (v) return v;
    } catch (e) {}

    // 2. Internal player API (may be present on ytmusic-player-bar)
    var el = document.querySelector("ytmusic-player-bar");
    if (el) {
      var api = el.playerApi_ || el.playerApi;
      if (api && typeof api.getVideoData === "function") {
        try {
          var data = api.getVideoData();
          if (data && data.video_id) return data.video_id;
        } catch (e) {}
      }
    }

    // 3. Now-playing card link in the player bar
    var sel = [
      ".content-info-wrapper a[href*='watch?v=']",
      "ytmusic-player-bar a[href*='watch?v=']",
      ".now-playing-info a[href*='watch?v=']",
      "a.ytp-title-link[href*='watch?v=']",
    ].join(", ");
    var link = document.querySelector(sel);
    if (link) {
      var m = link.href.match(/[?&]v=([^&]+)/);
      if (m) return m[1];
    }

    // 4. The HTML5 <video> element's src (often blob:, but if not, may carry the id)
    var v2 = document.querySelector("video");
    if (v2 && v2.src) {
      var m2 = v2.src.match(/[?&]v=([^&]+)/);
      if (m2) return m2[1];
    }

    return null;
  }

  function isAdShowing() {
    var bar = document.querySelector("ytmusic-player-bar");
    return !!(bar && bar.classList.contains("ad-showing"));
  }

  function snapshot() {
    var v = getVideo();
    if (!v) return null;
    return {
      videoId: getVideoId(),
      t: v.currentTime || 0,
      playing: !v.paused && !v.ended,
      ad: isAdShowing(),
    };
  }

  function reportState() {
    var s = snapshot();

    // Real track change = videoId differs from the last one we either
    // applied (from a remote peer) OR the last one we reported. This
    // bypasses the cooldown — a user-initiated track switch is never
    // an echo, so it must propagate even if we just applied something.
    var isTrackChange = !!(s && s.videoId
                           && s.videoId !== lastAppliedVideoId
                           && s.videoId !== lastReportedVideoId);

    var why = null;
    if (!s) why = "no-video";
    else if (!s.videoId) why = "no-video-id";
    else if (!isTrackChange && Date.now() - lastAppliedAt < COOLDOWN_MS) why = "cooldown";

    // Diagnostic ping always — so the native panel knows what's happening.
    post({
      kind: "diag",
      videoId: s ? s.videoId : null,
      t: s ? s.t : null,
      playing: s ? s.playing : null,
      ad: s ? s.ad : null,
      skipped: why,
      trackChange: isTrackChange,
      at: Date.now(),
    });

    if (why) return;
    post({ kind: "state", videoId: s.videoId, t: s.t, playing: s.playing, ad: s.ad });
    lastReportedVideoId = s.videoId;
  }

  var hooked = null;
  function hookVideo() {
    var v = getVideo();
    if (!v || v === hooked) return;
    hooked = v;
    // Added durationchange + emptied + loadstart so we catch the new <video>
    // metadata event the moment YT Music swaps the source for a new track,
    // not a second later when the polling loop next runs.
    ["play", "pause", "seeked", "loadedmetadata", "durationchange",
     "emptied", "loadstart", "ratechange", "ended"].forEach(function (ev) {
      v.addEventListener(ev, function () { reportState(); });
    });
  }

  // Pending scheduled-play timer handle, so we can cancel it if a newer
  // state supersedes (e.g., user pauses before the scheduled play fires).
  var pendingPlayTimeout = null;
  function cancelPending() {
    if (pendingPlayTimeout !== null) {
      clearTimeout(pendingPlayTimeout);
      pendingPlayTimeout = null;
    }
  }

  window.tunesyncApplyState = function (videoId, t, playing, startAtMs) {
    var v = getVideo();
    if (!v) return false;
    var current = getVideoId();

    if (videoId && videoId !== current) {
      lastAppliedAt = Date.now();
      lastAppliedVideoId = videoId;
      var dest = "https://music.youtube.com/watch?v=" + encodeURIComponent(videoId) + "&t=" + Math.floor(t || 0);
      window.location.href = dest;
      return true;
    }

    if (typeof t === "number" && Math.abs((v.currentTime || 0) - t) > 1.0) {
      try { v.currentTime = t; } catch (e) {}
    }

    cancelPending();

    if (playing) {
      var delay = (typeof startAtMs === "number") ? (startAtMs - Date.now()) : 0;
      if (delay > 0) {
        // Scheduled play: pre-pause now (so we don't "play through" the
        // wait window), then arm the timer. All peers do this in
        // lockstep; both fire v.play() at the same wall-clock instant.
        try { if (!v.paused) v.pause(); } catch (e) {}
        pendingPlayTimeout = setTimeout(function () {
          pendingPlayTimeout = null;
          var vv = getVideo();
          if (vv && vv.paused) { vv.play().catch(function () {}); }
        }, delay);
      } else {
        // Either no schedule, or schedule already in the past — play now.
        if (v.paused) { v.play().catch(function () {}); }
      }
    } else {
      // Pause is always immediate.
      if (!v.paused) v.pause();
    }

    lastAppliedAt = Date.now();
    lastAppliedVideoId = videoId || current;
    return true;
  };

  window.tunesyncSnapshot = function () { return snapshot(); };

  setInterval(hookVideo, 1000);
  hookVideo();

  // Aggressive videoId polling: catches track changes that don't fire any
  // of the hooked <video> events (e.g., YT Music re-creates the element
  // and our listeners are gone before we re-hook). 500ms cadence balances
  // responsiveness vs CPU.
  var pollLastSeen = null;
  setInterval(function () {
    var s = snapshot();
    if (!s || !s.videoId) return;
    if (s.videoId !== pollLastSeen) {
      pollLastSeen = s.videoId;
      reportState();
    }
  }, 500);

  // Periodic catch-up for slow drifts (e.g., user lets a song play untouched).
  setInterval(reportState, 5000);

  console.info("[tunesync] injected (v0.2.8)");
})();
"""#
}
