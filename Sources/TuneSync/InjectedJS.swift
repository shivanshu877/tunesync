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
  var COOLDOWN_MS = 1500;
  var lastAppliedAt = 0;

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
    // Narrow signal: only the player bar's own "ad-showing" class. The earlier
    // fallback (querySelector(".ad-showing, .ytp-ad-player-overlay")) matched
    // hidden ad-related elements that exist even when no ad is actually
    // playing, which permanently suppressed outbound state.
    var bar = document.querySelector("ytmusic-player-bar");
    return !!(bar && bar.classList.contains("ad-showing"));
  }

  function snapshot() {
    var v = getVideo();
    if (!v) return null;
    return {
      videoId: getVideoId(),
      t: v.currentTime || 0,
      // NOTE: deliberately not gated on readyState — during a seek the
      // video element briefly drops to a lower readyState, which used to
      // make us report "playing: false" mid-seek and pull peers into a
      // pause/play flap. The simpler check is correct.
      playing: !v.paused && !v.ended,
      ad: isAdShowing(),
    };
  }

  function reportState() {
    var why = null;
    var s = snapshot();
    if (Date.now() - lastAppliedAt < COOLDOWN_MS) why = "cooldown";
    else if (!s) why = "no-video";
    else if (!s.videoId) why = "no-video-id";

    // Always emit a diagnostic ping so the native side knows we're alive
    // and can show what was/wasn't broadcast.
    post({
      kind: "diag",
      videoId: s ? s.videoId : null,
      t: s ? s.t : null,
      playing: s ? s.playing : null,
      ad: s ? s.ad : null,
      skipped: why,
      at: Date.now(),
    });

    if (why) return;
    post({ kind: "state", videoId: s.videoId, t: s.t, playing: s.playing, ad: s.ad });
  }

  var hooked = null;
  function hookVideo() {
    var v = getVideo();
    if (!v || v === hooked) return;
    hooked = v;
    ["play", "pause", "seeked", "loadedmetadata", "ratechange", "ended"].forEach(function (ev) {
      v.addEventListener(ev, function () { reportState(); });
    });
  }

  window.tunesyncApplyState = function (videoId, t, playing) {
    var v = getVideo();
    if (!v) return false;
    var current = getVideoId();
    var changed = false;

    if (videoId && videoId !== current) {
      var dest = "https://music.youtube.com/watch?v=" + encodeURIComponent(videoId) + "&t=" + Math.floor(t || 0);
      lastAppliedAt = Date.now();
      window.location.href = dest;
      return true;
    }

    if (typeof t === "number" && Math.abs((v.currentTime || 0) - t) > 1.0) {
      try { v.currentTime = t; changed = true; } catch (e) {}
    }
    if (playing && v.paused) { v.play().catch(function () {}); changed = true; }
    if (!playing && !v.paused) { v.pause(); changed = true; }

    if (changed) {
      lastAppliedAt = Date.now();
    }
    return true;
  };

  window.tunesyncSnapshot = function () { return snapshot(); };

  setInterval(hookVideo, 1000);
  hookVideo();

  // Periodic catch-up: if no event-driven state has fired (e.g., user is
  // letting a song play untouched), this gets the latest playhead out
  // every 5s. The cooldown guard inside reportState() still applies.
  setInterval(reportState, 5000);

  console.info("[tunesync] injected");
})();
"""#
}
