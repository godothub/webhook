# Webhook

A tiny, dependency-free webhook server for Dart that routes requests by **exact path + HTTP method**, and lets you run **shell scripts** (with captured stdout/stderr) safely with **cooldown** and **concurrency** controls.

## Features

- Lightweight HTTP server based on `dart:io`
- Exact route matching: path + methods
- Per-hook cooldown (default: 1 hour) with HTTP 429
- Optional force bypass via `?force=<password>`
- Optional reject-while-running protection with HTTP 409
- Easy JSON responses
- Built-in script runner (file path or inline script) with captured output

## Installation

Add to `pubspec.yaml`:

```yaml
dependencies:
  webhook: ^1.0.0
```

Then import:

```dart
import 'package:webhook/webhook.dart';
```

## Quick Start

```dart
import 'dart:io';

void main() async {
  final server = WebhookServer(
    options: WebhookServerOptions(port: 8888),
  );

  server.addHook(
    Webhook(
      path: '/deploy',
      methods: {'POST'},
      options: HookOptions(
        cooldown: const Duration(minutes: 10),
        rejectIfRunning: true,
        forcePassword: 'let-me-in',
      ),
      handler: (ctx) async {
        final body = await ctx.tryReadJsonBody();

        final result = await ctx.runScript(
          ScriptSpec(
            scriptPath: './scripts/deploy.sh',
            scriptString: 'echo "deploying..."',
          ),
        );

        await ctx.json(200, {
          'message': 'Deploy triggered',
          'request': body,
          'run': result.toJson(),
        });
      },
    ),
  );

  await server.start();
}
```

Run:

```bash
dart run
```

Call:

```bash
curl -X POST http://localhost:8888/deploy \
  -H "Content-Type: application/json" \
  -d '{"ref":"main"}'
```

## Core Concepts

### WebhookServerOptions

Configure bind address and port:

```dart
WebhookServerOptions(
  port: 8888,
  address: InternetAddress.anyIPv4,
)
```

### HookOptions

Per-hook runtime behavior:

- cooldown: minimum interval between successful executions
- workDir: working directory for scripts
- rejectIfRunning: reject concurrent requests
- forcePassword: bypass cooldown via query parameter

```dart
HookOptions(
  cooldown: const Duration(seconds: 30),
  workDir: '/opt/app',
  rejectIfRunning: true,
  forcePassword: 'secret',
)
```

### Script Execution

Resolution order:

1. scriptPath (if exists)
2. scriptString
3. defaultScriptString

```dart
final result = await ctx.runScript(
  ScriptSpec(
    scriptString: 'echo "Hello World"',
  ),
);
```

### RunResult

Includes:

- exitCode
- startedAt / endedAt
- stdoutText / stderrText

Convert to JSON:

```dart
result.toJson();
```
