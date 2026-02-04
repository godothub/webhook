import 'dart:io';
import 'package:webhook/webhook.dart';

Future<void> main(List<String> args) async {
  final forcePassword = args.isNotEmpty ? args[0] : null;

  // Open log file in append mode
  final logFile = File('${Directory.current.path}/godothub_hooks.log');
  final logSink = logFile.openWrite(mode: FileMode.append);

  void writeLog(String line) {
    logSink.writeln(line);
    logSink.flush(); // ensure log is written immediately
  }

  // Ensure log file is properly closed on process exit
  ProcessSignal.sigint.watch().listen((_) async {
    await logSink.flush();
    await logSink.close();
    exit(0);
  });

  final server = WebhookServer(options: WebhookServerOptions(port: 8000));

  server.addHook(
    Webhook(
      path: '/deploy-website',
      options: HookOptions(
        workDir: '/opt/caddy',
        cooldown: const Duration(minutes: 30),
        forcePassword: forcePassword,
      ),
      handler: (ctx) async {
        final start = DateTime.now();

        int status = 500;
        RunResult? result;

        try {
          result = await ctx.runScript(ScriptSpec(scriptPath: './dep.sh'));

          status = result.exitCode == 0 ? 200 : 500;
          await ctx.json(status, result.toJson());
        } catch (e) {
          status = 500;
          await ctx.json(500, {'error': e.toString()});
        } finally {
          final end = DateTime.now();
          final durationMs = end.difference(start).inMilliseconds;

          final req = ctx.req;
          final method = req.method;
          final uri = req.uri.toString();
          final clientIp =
              req.connectionInfo?.remoteAddress.address ?? 'unknown';

          writeLog(
            '[ACCESS] '
            'time=${end.toIso8601String()} '
            'ip=$clientIp '
            'method=$method '
            'url=$uri '
            'status=$status '
            'exitCode=${result?.exitCode ?? 'N/A'} '
            'durationMs=$durationMs',
          );
        }
      },
    ),
  );

  await server.start();
}
