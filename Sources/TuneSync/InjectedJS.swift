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
    var el = document.querySelector("ytmusic-player-bar");
    if (el && el.playerApi_ && typeof el.playerApi_.getVideoData === "function") {
      try {
        var data = el.playerApi_.getVideoData();
        if (data && data.video_id) return data.video_id;
      } catch (e) {}
    }
    var link = document.querySelector(".content-info-wrapper a[href*='watch?v=']");
    if (link) {
      var m = link.href.match(/[?&]v=([^&]+)/);
      if (m) return m[1];
    }
    var url = new URL(window.location.href);
    var v = url.searchParams.get("v");
    return v || null;
  }

  function isAdShowing() {
    var bar = document.querySelector("ytmusic-player-bar");
    if (bar && bar.classList.contains("ad-showing")) return true;
    var ad = document.querySelector(".ad-showing, .ytp-ad-player-overlay");
    return !!ad;
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
    // Echo-loop guard: if we just applied remote state, suppress.
    if (Date.now() - lastAppliedAt < COOLDOWN_MS) return;
    var s = snapshot();
    if (!s || !s.videoId) return;
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
