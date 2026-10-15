import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The robot refused or could not serve the video.
class WhepException implements Exception {
  const WhepException(this.message, {this.unauthorized = false});

  final String message;

  /// The robot rejected the token.
  final bool unauthorized;

  @override
  String toString() => message;
}

/// WHEP signalling (WebRTC-HTTP egress) with the robot's MediaMTX: POST the SDP offer, get the
/// answer, DELETE the session when done. Basic auth, user `teleop`, the teleop token.
class Whep {
  Whep(this.endpoint, this.token, {this.timeout = const Duration(seconds: 20)});

  static const user = 'teleop';

  final Uri endpoint;
  final String token;

  /// The first answer may take seconds: the robot starts its encoder for the first viewer.
  final Duration timeout;

  /// The session on the robot (the answer's Location), to DELETE when done.
  Uri? session;

  String get _authorization => 'Basic ${base64Encode(utf8.encode('$user:$token'))}';

  /// POSTs the offer (with all ICE candidates) and returns the SDP answer.
  Future<String> offer(String sdp) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      return await _offer(http, sdp).timeout(timeout);
    } on TimeoutException {
      throw const WhepException('no answer from the robot');
    } on SocketException catch (error) {
      throw WhepException(error.message);
    } on HttpException catch (error) {
      throw WhepException(error.message);
    } finally {
      http.close(force: true);
    }
  }

  Future<String> _offer(HttpClient http, String sdp) async {
    final body = utf8.encode(sdp);
    final request = await http.postUrl(endpoint);
    request.headers
      ..contentType = ContentType('application', 'sdp')
      ..set(HttpHeaders.authorizationHeader, _authorization);
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    if (response.statusCode == HttpStatus.unauthorized) {
      throw const WhepException('wrong token', unauthorized: true);
    }
    if (response.statusCode != HttpStatus.created && response.statusCode != HttpStatus.ok) {
      throw WhepException('HTTP ${response.statusCode}${_reason(text)}');
    }
    final location = response.headers.value(HttpHeaders.locationHeader);
    session = location == null ? null : endpoint.resolve(location);
    return text;
  }

  /// MediaMTX explains errors as {"status": "error", "error": "..."}.
  static String _reason(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json['error'] is String) return ': ${json['error']}';
    } on FormatException {
      // not JSON
    }
    return '';
  }

  /// Ends the session on the robot; best effort (an abandoned one times out there).
  Future<void> close() async {
    final target = session;
    session = null;
    if (target == null) return;
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await http.deleteUrl(target);
      request.headers.set(HttpHeaders.authorizationHeader, _authorization);
      final response = await request.close().timeout(const Duration(seconds: 3));
      await response.drain<void>().timeout(const Duration(seconds: 3));
    } on Exception {
      // the robot is gone or the session expired: nothing left to end
    } finally {
      http.close(force: true);
    }
  }
}
