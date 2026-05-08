import Foundation

public enum BridgeAssets {
    public static let indexHTML: String = #"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <title>TuneSync Web</title>
  <link rel="stylesheet" href="/style.css">
</head>
<body>
  <header>
    <h1>TuneSync <span id="room"></span></h1>
    <div id="status">connecting…</div>
  </header>
  <main>
    <div id="player"></div>
    <div id="now-playing">
      <div id="track">—</div>
      <div id="meta"></div>
    </div>
  </main>
  <script src="https://www.youtube.com/iframe_api"></script>
  <script src="/app.js"></script>
</body>
</html>
"""#

    public static let styleCSS: String = #"""
* { box-sizing: border-box; }
body {
  margin: 0; font: 14px/1.4 -apple-system, system-ui, sans-serif;
  background: #111; color: #eee;
}
header {
  padding: 12px 16px; border-bottom: 1px solid #333;
  display: flex; justify-content: space-between; align-items: center;
}
h1 { margin: 0; font-size: 16px; font-weight: 600; }
#status { font-size: 12px; color: #888; }
main { padding: 16px; max-width: 720px; margin: 0 auto; }
#player { aspect-ratio: 16/9; background: #000; margin-bottom: 16px; }
#track { font-size: 18px; font-weight: 600; }
#meta { font-size: 12px; color: #888; margin-top: 4px; }
"""#

    public static let appJS: String = #"""
(function () {
  var status = document.getElementById('status');
  var trackEl = document.getElementById('track');
  var metaEl = document.getElementById('meta');
  var roomEl = document.getElementById('room');

  var ws = null;
  var player = null;
  var senderId = "web-" + Math.random().toString(36).slice(2, 10);
  var lastVideoId = null;
  var clockOffsetMs = 0;
  var pendingPings = {};

  function connect() {
    var proto = (location.protocol === 'https:') ? 'wss:' : 'ws:';
    ws = new WebSocket(proto + '//' + location.host + '/ws');
    ws.onopen = function () {
      status.textContent = 'connected';
      send({ kind: 'hello', senderId: senderId, displayName: navigator.userAgent.slice(0, 60), host: false });
      setInterval(sendPing, 5000);
    };
    ws.onmessage = function (ev) {
      try { handle(JSON.parse(ev.data)); } catch (e) { console.error(e); }
    };
    ws.onclose = function () {
      status.textContent = 'disconnected';
      setTimeout(connect, 2000);
    };
    ws.onerror = function () { status.textContent = 'error'; };
  }

  function send(msg) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(msg)); }

  function sendPing() {
    var nonce = Date.now();
    pendingPings[nonce] = Date.now();
    send({ kind: 'ping', senderId: senderId, nonce: nonce, t0: Date.now() });
  }

  function handle(m) {
    if (m.kind === 'state') applyState(m);
    else if (m.kind === 'pong') {
      var t3 = Date.now();
      var rtt = (t3 - m.t0) - (m.t2 - m.t1);
      var off = ((m.t1 - m.t0) + (m.t2 - t3)) / 2;
      if (Math.abs(rtt) < 1000) clockOffsetMs = Math.round(off);
    } else if (m.kind === 'welcome') {
      if (m.room) roomEl.textContent = '· ' + m.room;
    }
  }

  function applyState(s) {
    if (!player || typeof player.loadVideoById !== 'function') return;
    if (s.adOnHost) {
      player.mute();
      player.pauseVideo();
      return;
    } else {
      player.unMute();
    }
    if (s.videoId && s.videoId !== lastVideoId) {
      lastVideoId = s.videoId;
      player.loadVideoById(s.videoId, s.t || 0);
      trackEl.textContent = s.videoId;
    }
    var doApply = function () {
      var current = player.getCurrentTime ? player.getCurrentTime() : 0;
      var diff = current - (s.t || 0);
      if (Math.abs(diff) > 0.5) {
        player.seekTo(s.t, true);
      } else if (Math.abs(diff) > 0.05) {
        player.setPlaybackRate(diff > 0 ? 0.95 : 1.05);
        setTimeout(function () { player.setPlaybackRate(1.0); }, 500);
      }
      if (s.playing) player.playVideo(); else player.pauseVideo();
    };
    if (typeof s.applyAtMs === 'number') {
      var localTarget = s.applyAtMs - clockOffsetMs;
      var wait = localTarget - Date.now();
      if (wait > 0 && wait < 1000) { setTimeout(doApply, wait); return; }
    }
    doApply();
  }

  window.onYouTubeIframeAPIReady = function () {
    player = new YT.Player('player', {
      width: '100%', height: '100%',
      playerVars: { playsinline: 1, controls: 1 },
      events: {
        onReady: function () { connect(); }
      }
    });
  };
})();
"""#

    public static func mimeType(for path: String) -> String {
        if path.hasSuffix(".html")  { return "text/html; charset=utf-8" }
        if path.hasSuffix(".css")   { return "text/css; charset=utf-8" }
        if path.hasSuffix(".js")    { return "application/javascript; charset=utf-8" }
        return "application/octet-stream"
    }

    public static func body(for path: String) -> Data? {
        switch path {
        case "/", "/index.html": return Data(indexHTML.utf8)
        case "/style.css":       return Data(styleCSS.utf8)
        case "/app.js":          return Data(appJS.utf8)
        default: return nil
        }
    }
}
