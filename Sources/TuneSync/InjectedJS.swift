import Foundation

enum InjectedJS {
    static let source: String = #"""
(function () {
  if (window.__TUNESYNC_INSTALLED__) return;
  window.__TUNESYNC_INSTALLED__ = true;

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
      playing: !v.paused && !v.ended && v.readyState > 2,
      ad: isAdShowing(),
    };
  }

  function reportState() {
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
    if (videoId && videoId !== current) {
      var dest = "https://music.youtube.com/watch?v=" + encodeURIComponent(videoId) + "&t=" + Math.floor(t || 0);
      window.location.href = dest;
      return true;
    }
    if (typeof t === "number" && Math.abs((v.currentTime || 0) - t) > 0.6) {
      try { v.currentTime = t; } catch (e) {}
    }
    if (playing && v.paused) { v.play().catch(function () {}); }
    if (!playing && !v.paused) { v.pause(); }
    return true;
  };

  window.tunesyncSnapshot = function () { return snapshot(); };

  setInterval(hookVideo, 1000);
  hookVideo();

  setInterval(reportState, 5000);

  console.info("[tunesync] injected");
})();
"""#
}
