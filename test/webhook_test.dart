import 'dart:io';

import 'package:test/test.dart';
import 'package:webhook/webhook.dart';

void main() {
  group('Webhook basic tests', () {
    test('Create hook and run simple script', () async {
      final hook = Webhook(path: '/test', handler: (_) async {});

      final request = await _fakeRequest();

      final ctx = HookContext(request, hook);

      final result = await ctx.runScript(
        ScriptSpec(scriptString: 'echo hello'),
      );

      expect(result.exitCode, 0);
      expect(result.stdoutText.trim(), 'hello');
    });
  });
}

Future<HttpRequest> _fakeRequest() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  late HttpRequest captured;

  server.listen((req) {
    captured = req;
  });

  final client = HttpClient();
  final req = await client.get(server.address.address, server.port, '/');
  await req.close();

  await Future.delayed(const Duration(milliseconds: 50));

  await server.close(force: true);
  client.close();

  return captured;
}
