import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_teleop/net/whep.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for the robot's MediaMTX WHEP endpoint; [reply] answers each request.
class FakeRobot {
  FakeRobot._(this._server);

  static Future<FakeRobot> start(Future<void> Function(HttpRequest, String body) reply) async {
    final robot = FakeRobot._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    robot._server.listen((request) async {
      final body = await utf8.decodeStream(request);
      robot.requests.add((request.method, request.uri.path, request.headers, body));
      await reply(request, body);
      await request.response.close();
    });
    return robot;
  }

  final HttpServer _server;
  final requests = <(String, String, HttpHeaders, String)>[];

  Uri get endpoint => Uri.parse('http://127.0.0.1:${_server.port}/camera/whep');

  Future<void> close() => _server.close(force: true);
}

void main() {
  test('posts the offer with the token and ends the session it got', () async {
    final robot = await FakeRobot.start((request, body) async {
      if (request.method == 'POST') {
        request.response
          ..statusCode = HttpStatus.created
          ..headers.set(HttpHeaders.locationHeader, '/camera/whep/0f3c')
          ..headers.contentType = ContentType('application', 'sdp')
          ..write('v=0 answer');
      }
    });
    addTearDown(robot.close);
    final whep = Whep(robot.endpoint, 's3cret:%');
    expect(await whep.offer('v=0 offer'), 'v=0 answer');
    final (method, path, headers, body) = robot.requests.single;
    expect(method, 'POST');
    expect(path, '/camera/whep');
    expect(headers.contentType?.mimeType, 'application/sdp');
    expect(
      headers.value(HttpHeaders.authorizationHeader),
      'Basic ${base64Encode(utf8.encode('teleop:s3cret:%'))}',
    );
    expect(body, 'v=0 offer');
    expect(whep.session, robot.endpoint.resolve('/camera/whep/0f3c'));

    await whep.close();
    expect(robot.requests.last.$1, 'DELETE');
    expect(robot.requests.last.$2, '/camera/whep/0f3c');
    expect(whep.session, isNull);
    await whep.close(); // once only
    expect(robot.requests.length, 2);
  });

  test('a wrong token and other refusals are reported', () async {
    var status = HttpStatus.unauthorized;
    final robot = await FakeRobot.start((request, body) async {
      request.response
        ..statusCode = status
        ..write('{"status":"error","error":"no stream is available on path \'camera\'"}');
    });
    addTearDown(robot.close);
    await expectLater(
      Whep(robot.endpoint, 'nope').offer('v=0'),
      throwsA(isA<WhepException>().having((e) => e.unauthorized, 'unauthorized', isTrue)),
    );
    status = HttpStatus.badRequest;
    await expectLater(
      Whep(robot.endpoint, 'x').offer('v=0'),
      throwsA(
        isA<WhepException>()
            .having((e) => e.unauthorized, 'unauthorized', isFalse)
            .having((e) => e.message, 'message', contains('no stream')),
      ),
    );
  });

  test('a robot without MediaMTX or one that never answers fails in time', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    await expectLater(
      Whep(Uri.parse('http://127.0.0.1:$port/camera/whep'), 'x').offer('v=0'),
      throwsA(isA<WhepException>()),
    );
    final silent = await FakeRobot.start((request, body) => Completer<void>().future);
    addTearDown(silent.close);
    await expectLater(
      Whep(silent.endpoint, 'x', timeout: const Duration(milliseconds: 300)).offer('v=0'),
      throwsA(isA<WhepException>().having((e) => e.message, 'message', contains('no answer'))),
    );
  });
}
