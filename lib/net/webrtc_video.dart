import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show
        createLocalMediaStream,
        createPeerConnection,
        MediaStream,
        RTCIceGatheringState,
        RTCPeerConnection,
        RTCPeerConnectionState,
        RTCRtpMediaType,
        RTCRtpTransceiverInit,
        RTCSessionDescription,
        RTCTrackEvent,
        RTCVideoRenderer,
        TransceiverDirection;

import 'whep.dart';

enum VideoLink {
  /// Not wanted, or the robot offers no WebRTC: the JPEG frames show the camera.
  off,

  /// Asking the robot, which may start its encoder first; the JPEG frames show meanwhile.
  connecting,

  /// The WebRTC video plays.
  playing,

  /// It did not work; tried again later, the JPEG frames show meanwhile.
  failed,
}

/// The robot camera over WebRTC: H.264 from the robot's MediaMTX, signalled with WHEP.
///
/// [want] names the robot to play (or none); this keeps trying with growing pauses and reports
/// [link]. Every attempt gets its own renderer, so its first-frame event is always fresh.
class WebRtcVideo extends ChangeNotifier {
  static const _iceGathering = Duration(seconds: 2);
  static const _firstFrame = Duration(seconds: 10);
  static const _disconnectGrace = Duration(seconds: 4);
  static const _statsEvery = Duration(seconds: 2);

  /// Stats polls without a new decoded frame before the video counts as stalled.
  static const _stalledPolls = 3;
  static const _retrySeconds = [5, 15, 30, 60];

  VideoLink link = VideoLink.off;

  /// Why the last attempt failed.
  String error = '';

  Uri? _endpoint;
  String _token = '';
  int _attempt = 0;
  int _failures = 0;
  RTCVideoRenderer? _renderer;
  RTCPeerConnection? _peer;
  Whep? _whep;
  Timer? _retry;
  Timer? _watchdog;
  Timer? _disconnected;
  Timer? _stats;
  bool _disposed = false;

  /// The renderer while the video plays, else null.
  RTCVideoRenderer? get renderer => link == VideoLink.playing ? _renderer : null;

  /// Plays the WHEP [endpoint] with [token], or stops for null. Repeating the same call is free.
  void want(Uri? endpoint, String token) {
    if (endpoint == _endpoint && token == _token) return;
    _endpoint = endpoint;
    _token = token;
    _failures = 0;
    _start();
  }

  @override
  void dispose() {
    _disposed = true;
    _attempt++;
    _retry?.cancel();
    unawaited(_close());
    super.dispose();
  }

  void _start() {
    _retry?.cancel();
    final attempt = ++_attempt;
    unawaited(_run(attempt));
  }

  bool _stale(int attempt) => attempt != _attempt || _disposed;

  Future<void> _run(int attempt) async {
    final endpoint = _endpoint;
    // first, so the screen stops showing the old renderer and takes the JPEG frames again
    _set(endpoint == null ? VideoLink.off : VideoLink.connecting, endpoint == null ? '' : error);
    await _close();
    if (_stale(attempt) || endpoint == null) return;
    try {
      await _open(endpoint, attempt);
    } on WhepException catch (e) {
      _fail(attempt, e.message);
    } catch (e) {
      _fail(attempt, '$e'); // flutter_webrtc reports platform errors as strings
    }
  }

  Future<void> _open(Uri endpoint, int attempt) async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    if (_stale(attempt)) {
      await _dispose(renderer);
      return;
    }
    _renderer = renderer;
    // the first frame, or its size: whichever the platform reports first
    renderer.onFirstFrameRendered = () => _playing(attempt);
    renderer.onResize = () => _playing(attempt);

    final peer = await createPeerConnection({
      'iceServers': <Object>[], // same network as the robot: host candidates are enough
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
    });
    if (_stale(attempt)) {
      await _closePeer(peer);
      return;
    }
    _peer = peer;
    final gathered = Completer<void>();
    peer.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete && !gathered.isCompleted) {
        gathered.complete();
      }
    };
    peer.onConnectionState = (state) => _onConnectionState(attempt, state);
    peer.onTrack = (event) => _onTrack(attempt, renderer, event);
    await peer.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    final offer = await peer.createOffer({
      'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': true},
      'optional': <Object>[],
    });
    await peer.setLocalDescription(offer);
    // the offer carries every candidate (no trickle ICE); on a LAN they are there at once
    await gathered.future.timeout(_iceGathering, onTimeout: () {});
    if (_stale(attempt)) return;
    final local = await peer.getLocalDescription();

    final whep = Whep(endpoint, _token);
    _whep = whep;
    final answer = await whep.offer(local?.sdp ?? offer.sdp ?? '');
    if (_stale(attempt)) {
      unawaited(whep.close());
      return;
    }
    await peer.setRemoteDescription(RTCSessionDescription(answer, 'answer'));
    if (!_stale(attempt) && link == VideoLink.connecting) {
      _watchdog = Timer(_firstFrame, () => _fail(attempt, 'no video'));
    }
  }

  Future<void> _onTrack(int attempt, RTCVideoRenderer renderer, RTCTrackEvent event) async {
    if (_stale(attempt) || event.track.kind != 'video') return;
    try {
      MediaStream stream;
      if (event.streams.isNotEmpty) {
        stream = event.streams.first;
      } else {
        stream = await createLocalMediaStream('robot');
        await stream.addTrack(event.track);
      }
      if (!_stale(attempt)) renderer.srcObject = stream;
    } catch (e) {
      _fail(attempt, '$e');
    }
  }

  void _onConnectionState(int attempt, RTCPeerConnectionState state) {
    if (_stale(attempt)) return;
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        _fail(attempt, 'connection ${state.name.replaceFirst('RTCPeerConnectionState', '')}');
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        // often a short Wi-Fi gap that ICE bridges by itself
        _disconnected ??= Timer(_disconnectGrace, () => _fail(attempt, 'connection lost'));
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _disconnected?.cancel();
        _disconnected = null;
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        break;
    }
  }

  void _playing(int attempt) {
    if (_stale(attempt) || link != VideoLink.connecting) return;
    _watchdog?.cancel();
    _watchdog = null;
    _failures = 0;
    _set(VideoLink.playing, '');
    _watchFrames(attempt);
  }

  /// A picture that froze while the connection stays up (the robot's encoder or camera stopped)
  /// fails the attempt, so the JPEG frames take over.
  void _watchFrames(int attempt) {
    var frames = -1;
    var still = 0;
    var polling = false;
    _stats?.cancel();
    _stats = Timer.periodic(_statsEvery, (_) async {
      final peer = _peer;
      if (polling || peer == null || _stale(attempt)) return;
      polling = true;
      final decoded = await _framesDecoded(peer).timeout(_statsEvery, onTimeout: () => null);
      polling = false;
      if (decoded == null || _stale(attempt)) return;
      still = decoded > frames ? 0 : still + 1;
      frames = decoded;
      if (still >= _stalledPolls) _fail(attempt, 'video stalled');
    });
  }

  /// Frames the video receiver has decoded so far, or null when the stats do not say.
  static Future<int?> _framesDecoded(RTCPeerConnection peer) async {
    try {
      for (final report in await peer.getStats()) {
        final values = report.values;
        if (report.type != 'inbound-rtp' || (values['kind'] ?? values['mediaType']) != 'video') {
          continue;
        }
        final count = values['framesDecoded'] ?? values['bytesReceived'];
        return count is num ? count.toInt() : num.tryParse('$count')?.toInt();
      }
    } catch (_) {
      // the connection is closing
    }
    return null;
  }

  void _fail(int attempt, String reason) {
    if (_stale(attempt)) return;
    _attempt++; // whatever the failed attempt still reports is ignored
    _failures++;
    unawaited(_close());
    final delay = _retrySeconds[min(_failures, _retrySeconds.length) - 1];
    _retry?.cancel();
    _retry = Timer(Duration(seconds: delay), () {
      if (!_disposed && _endpoint != null) _start();
    });
    _set(VideoLink.failed, reason); // last: a listener may start another attempt meanwhile
  }

  void _set(VideoLink next, String reason) {
    if (_disposed || (next == link && reason == error)) return;
    link = next;
    error = reason;
    notifyListeners();
  }

  /// Ends the current attempt: the robot session, the connection, then the renderer.
  Future<void> _close() async {
    for (final timer in [_watchdog, _disconnected, _stats]) {
      timer?.cancel();
    }
    _watchdog = _disconnected = _stats = null;
    final whep = _whep, peer = _peer, renderer = _renderer;
    _whep = null;
    _peer = null;
    _renderer = null;
    if (whep != null) unawaited(whep.close());
    if (peer != null) await _closePeer(peer);
    if (renderer != null) {
      // once the screen has stopped showing it
      unawaited(Future<void>.delayed(const Duration(milliseconds: 300), () => _dispose(renderer)));
    }
  }

  static Future<void> _closePeer(RTCPeerConnection peer) async {
    try {
      await peer.close();
    } catch (_) {
      // already closed
    }
    try {
      await peer.dispose();
    } catch (_) {
      // already gone
    }
  }

  static Future<void> _dispose(RTCVideoRenderer renderer) async {
    try {
      await renderer.dispose();
    } catch (_) {
      // already gone
    }
  }
}
