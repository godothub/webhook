import 'dart:io';
import 'package:webhook/webhook.dart';

/// Entry point for the webhook server example.
///
/// Usage:
///   dart run bin/main.dart `<`FORCE_PASSWORD`>`
///
/// Notes:
/// - If FORCE_PASSWORD is not provided, the `?force=...` query parameter will not work.
/// - This example exposes a single webhook endpoint:
///     /build-docs  (GET, POST)
///   which runs a two-step script pipeline and returns JSON output for both steps.
Future<void> main(List<String> args) async {
  // Force password is passed as the first CLI argument.
  // When set, requests can bypass cooldown via `?force=<FORCE_PASSWORD>`.
  final forcePassword = args.isNotEmpty ? args[0] : null;

  if (forcePassword == null || forcePassword.isEmpty) {
    stderr.writeln(
      '[WARN] FORCE_PASSWORD is not provided, so the `force` query parameter is disabled.\n'
      'Usage: dart run bin/main.dart <FORCE_PASSWORD>',
    );
  } else {
    stdout.writeln(
      '[INFO] FORCE_PASSWORD is set (from command-line arguments).',
    );
  }

  // Create and configure the webhook server.
  final server = WebhookServer(options: WebhookServerOptions(port: 3333));

  // Register a webhook endpoint for building documentation.
  server.addHook(
    Webhook(
      path: '/build-docs',
      methods: {'GET', 'POST'},
      options: HookOptions(
        cooldown: const Duration(hours: 1),

        // Use the current directory as the working directory.
        // This is the default behavior, but keeping it explicit improves clarity.
        workDir: Directory.current.path,

        // Enables `?force=<password>` to bypass cooldown when the password matches.
        forcePassword: forcePassword,

        // Reject concurrent requests while the hook is executing.
        rejectIfRunning: true,
      ),
      handler: (ctx) async {
        // Optionally read JSON body for routing/parameters (GET returns null).
        final body = await ctx.tryReadJsonBody();
        final target = body?['target']?.toString() ?? 'default';

        // Step 1:
        // Prefer running a script file if it exists; otherwise fall back to an inline script.
        final r1 = await ctx.runScript(
          ScriptSpec(
            shell: 'bash',
            scriptPath: 'scripts/build_docs.sh',
            scriptString:
                'echo "Script path not found, falling back to inline script: build $target"',
            // shellArgs: ['-lc'], // Optional: override shell arguments if desired.
          ),
        );

        // Step 2:
        // Run a second script step (e.g., upload artifacts, refresh cache, etc.).
        final r2 = await ctx.runScript(
          ScriptSpec(
            shell: 'bash',
            scriptString: 'echo "Second step for $target"',
          ),
        );

        // Aggregate result and respond with structured JSON.
        final ok = r1.exitCode == 0 && r2.exitCode == 0;
        await ctx.json(ok ? 200 : 500, {
          'ok': ok,
          'step1': r1.toJson(),
          'step2': r2.toJson(),
        });
      },
    ),
  );

  // Start serving requests.
  await server.start();
}
