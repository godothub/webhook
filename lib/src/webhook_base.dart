import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A request handler invoked when a webhook route matches an incoming HTTP request.
typedef HookHandler = Future<void> Function(HookContext ctx);

/// Configuration for the HTTP server that hosts webhook endpoints.
class WebhookServerOptions {
  /// TCP port to listen on.
  final int port;

  /// IP address to bind to (defaults to all IPv4 interfaces).
  final InternetAddress address;

  WebhookServerOptions({this.port = 8888, InternetAddress? address})
    : address = address ?? InternetAddress.anyIPv4;
}

/// Runtime behavior options for a single webhook.
class HookOptions {
  /// Minimum interval between two successful executions of the same hook.
  /// Requests arriving earlier will be rejected with HTTP 429 unless forced.
  final Duration cooldown;

  /// Working directory used when launching scripts (defaults to current directory).
  final String workDir;

  /// Whether to reject a request if this hook is already executing.
  /// When enabled, concurrent requests receive HTTP 409.
  final bool rejectIfRunning;

  /// Optional force password used via query parameter `?force=xxx`.
  /// When provided and matched, cooldown is bypassed.
  final String? forcePassword;

  HookOptions({
    this.cooldown = const Duration(hours: 1),
    String? workDir,
    this.rejectIfRunning = true,
    this.forcePassword,
  }) : workDir = workDir ?? Directory.current.path;
}

/// Script execution specification.
///
/// Resolution order:
/// 1) If [scriptPath] exists under the working directory (or is absolute), execute it.
/// 2) Otherwise execute [scriptString] if provided and non-empty.
/// 3) Otherwise execute [defaultScriptString].
class ScriptSpec {
  /// Shell executable used to run the script (defaults to `bash`).
  final String shell;

  /// Script file path. Only executed if the file exists.
  final String? scriptPath;

  /// Inline script content used when [scriptPath] is missing or does not exist.
  final String? scriptString;

  /// Fallback inline script content when both [scriptPath] and [scriptString] are unavailable.
  final String defaultScriptString;

  /// Additional shell arguments (e.g. `['-lc']`).
  final List<String> shellArgs;

  ScriptSpec({
    this.shell = 'bash',
    this.scriptPath,
    this.scriptString,
    this.defaultScriptString = "echo 'Hello'",
    this.shellArgs = const [],
  });
}

/// Result of a script execution.
class RunResult {
  /// Process exit code (0 indicates success).
  final int exitCode;

  /// Execution start time.
  final DateTime startedAt;

  /// Execution end time.
  final DateTime endedAt;

  /// Captured stdout output.
  final String stdoutText;

  /// Captured stderr output.
  final String stderrText;

  RunResult({
    required this.exitCode,
    required this.startedAt,
    required this.endedAt,
    required this.stdoutText,
    required this.stderrText,
  });

  /// Converts this result into a JSON-friendly map.
  Map<String, dynamic> toJson() => {
    'ok': exitCode == 0,
    'exitCode': exitCode,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
    'durationMs': endedAt.difference(startedAt).inMilliseconds,
    'stdout': stdoutText,
    'stderr': stderrText,
  };
}

/// Internal state tracked per webhook (cooldown + running flag).
class _HookState {
  DateTime? lastRunAt;
  bool running = false;
}

/// Defines a webhook endpoint and its handler.
class Webhook {
  /// Exact URL path to match (e.g. `/deploy`).
  final String path;

  /// Allowed HTTP methods (uppercased).
  final Set<String> methods;

  /// Behavior options for this hook.
  final HookOptions options;

  /// Handler executed when a request matches this hook.
  final HookHandler handler;

  final _HookState _state = _HookState();

  Webhook({
    required this.path,
    Set<String>? methods,
    HookOptions? options,
    required this.handler,
  }) : methods = (methods ?? {'GET', 'POST'})
           .map((e) => e.toUpperCase())
           .toSet(),
       options = options ?? HookOptions();

  /// Returns true if [req] matches this webhook by path and method.
  bool match(HttpRequest req) =>
      req.uri.path == path && methods.contains(req.method.toUpperCase());
}

/// A per-request context passed to a [HookHandler].
class HookContext {
  /// The raw HTTP request.
  final HttpRequest req;

  /// The matched webhook definition.
  final Webhook hook;

  HookContext(this.req, this.hook);

  /// Convenience access to query parameters.
  Map<String, String> get query => req.uri.queryParameters;

  /// Attempts to read a JSON request body.
  ///
  /// Returns null if:
  /// - method is GET
  /// - Content-Type is not `application/json`
  /// - body is empty
  Future<Map<String, dynamic>?> tryReadJsonBody() async {
    if (req.method.toUpperCase() == 'GET') return null;

    final ct = req.headers.contentType;
    if (ct == null || ct.mimeType != 'application/json') return null;

    final text = await utf8.decoder.bind(req).join();
    if (text.trim().isEmpty) return null;

    return jsonDecode(text) as Map<String, dynamic>;
  }

  /// Core script runner (can be called multiple times within a handler).
  ///
  /// - Uses [workDirOverride] if provided; otherwise uses [hook.options.workDir].
  /// - Captures stdout/stderr and returns a [RunResult].
  /// - Throws [StateError] if the working directory does not exist.
  Future<RunResult> runScript(
    ScriptSpec spec, {
    String? workDirOverride,
  }) async {
    final workDir = workDirOverride ?? hook.options.workDir;

    if (!await Directory(workDir).exists()) {
      throw StateError('Working directory does not exist: $workDir');
    }

    String? resolvedPath;
    if (spec.scriptPath != null && spec.scriptPath!.trim().isNotEmpty) {
      final f = File(_resolvePath(workDir, spec.scriptPath!));
      if (await f.exists()) resolvedPath = f.path;
    }

    final startedAt = DateTime.now();
    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();

    late Process proc;

    if (resolvedPath != null) {
      proc = await Process.start(spec.shell, [
        ...spec.shellArgs,
        resolvedPath,
      ], workingDirectory: workDir);
    } else {
      final script = (spec.scriptString?.trim().isNotEmpty ?? false)
          ? spec.scriptString!
          : spec.defaultScriptString;

      // If shellArgs are not provided, default to `bash -lc "<script>"`.
      final args = spec.shellArgs.isEmpty
          ? ['-lc', script]
          : [...spec.shellArgs, script];

      proc = await Process.start(spec.shell, args, workingDirectory: workDir);
    }

    proc.stdout.transform(utf8.decoder).listen(stdoutBuf.write);
    proc.stderr.transform(utf8.decoder).listen(stderrBuf.write);

    final exitCode = await proc.exitCode;
    final endedAt = DateTime.now();

    return RunResult(
      exitCode: exitCode,
      startedAt: startedAt,
      endedAt: endedAt,
      stdoutText: stdoutBuf.toString(),
      stderrText: stderrBuf.toString(),
    );
  }

  /// Resolves [p] against [base] when [p] is a relative path.
  /// Absolute POSIX paths and Windows drive paths are returned unchanged.
  String _resolvePath(String base, String p) {
    if (p.startsWith('/') || p.contains(':\\')) return p;
    return '$base${Platform.pathSeparator}$p';
  }

  /// Writes a JSON response in a best-effort manner.
  /// Any exceptions (e.g. response already closed) are swallowed.
  Future<void> json(int status, Map<String, dynamic> body) async {
    try {
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(body));
      await req.response.close();
    } catch (_) {
      // Ignore: the response may already be closed.
    }
  }
}

/// A lightweight webhook server that routes requests by exact path + method.
class WebhookServer {
  /// Server-level options (bind address and port).
  final WebhookServerOptions options;

  final List<Webhook> _hooks = [];
  HttpServer? _server;

  WebhookServer({WebhookServerOptions? options})
    : options = options ?? WebhookServerOptions();

  /// Registers a new webhook.
  void addHook(Webhook hook) => _hooks.add(hook);

  /// Starts listening and dispatching requests.
  ///
  /// Throws [StateError] if the server is already started.
  Future<void> start() async {
    if (_server != null) throw StateError('Server already started');

    final server = await HttpServer.bind(options.address, options.port);
    _server = server;

    stdout.writeln(
      '[INFO] Listening on http://${server.address.address}:${server.port}',
    );

    await for (final req in server) {
      // Fire-and-forget per-request dispatch to keep accepting new connections.
      unawaited(_dispatch(req));
    }
  }

  Future<void> _dispatch(HttpRequest req) async {
    Webhook? hook;

    try {
      hook = _hooks.firstWhere((h) => h.match(req));
    } catch (_) {
      await _safeJson(req, 404, {'error': 'Not Found'});
      return;
    }

    try {
      if (hook.options.rejectIfRunning && hook._state.running) {
        await _safeJson(req, 409, {'error': 'Already running'});
        return;
      }

      final now = DateTime.now();

      // Cooldown bypass via `?force=...` if configured.
      final force = req.uri.queryParameters['force'];
      final forceOk =
          hook.options.forcePassword != null &&
          force == hook.options.forcePassword;

      final last = hook._state.lastRunAt;
      if (last != null) {
        final since = now.difference(last);
        if (since < hook.options.cooldown && !forceOk) {
          await _safeJson(req, 429, {
            'error': 'Cooldown',
            'lastRunAt': last.toIso8601String(),
            'retryAfterSeconds': (hook.options.cooldown - since).inSeconds,
            'hint': 'Use ?force=<password> to bypass cooldown.',
          });
          return;
        }
      }

      hook._state.running = true;

      final ctx = HookContext(req, hook);
      await hook.handler(ctx);

      hook._state.lastRunAt = DateTime.now();
    } catch (e, st) {
      stderr.writeln('[ERROR] $e\n$st');
      await _safeJson(req, 500, {'error': e.toString()});
    } finally {
      hook._state.running = false;
    }
  }

  /// Writes a JSON response safely (errors are ignored).
  Future<void> _safeJson(
    HttpRequest req,
    int status,
    Map<String, dynamic> body,
  ) async {
    try {
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(body));
      await req.response.close();
    } catch (_) {
      // Ignore: the response may already be closed.
    }
  }
}
