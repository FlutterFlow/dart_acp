import 'dart:async';

import 'package:dart_acp_codex/dart_acp_codex.dart';
import 'package:dart_acp_codex/src/app_server/json_rpc_backend.dart';
import 'package:test/test.dart';

import 'helpers/fake_backend.dart';

ContentBlock _text(String value) => ContentBlockText(TextContent(text: value));

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Map<Object?, Object?> _errorData(Object error) {
  expect(error, isA<JsonRpcRequestException>());
  final data = (error as JsonRpcRequestException).data;
  expect(data, isA<Map<Object?, Object?>>(), reason: 'bare $error');
  return data! as Map<Object?, Object?>;
}

Matcher _isDeadSession = predicate<Object>((error) {
  final data = _errorData(error);
  return data['sessionDead'] == true && (data['message'] as String).isNotEmpty;
}, 'a session-dead JSON-RPC error');

Future<({CodexAcpClient client, FakeCodexBackend backend, SessionId session})>
_startSession({void Function(FakeCodexBackend backend)? configure}) async {
  final backend = FakeCodexBackend();
  configure?.call(backend);
  final client = await CodexAcpClient.start(
    backend: backend,
    options: CodexAcpClientOptions(environment: const <String, String>{}),
  );
  final created = await client.agent.createSession(
    NewSessionRequest(cwd: '/workspace', mcpServers: const <McpServer>[]),
  );
  return (client: client, backend: backend, session: created.sessionId);
}

/// A minimal app server over the real [CodexJsonRpcBackend] transport.
///
/// The fake backend can only close its streams, which models a crash that
/// lands between requests. A real crash usually lands *during* one — the
/// process reaches EOF while `turn/start` is still awaiting its response —
/// and the connection rejects that request before any stream is done. Only a
/// real transport can reproduce that ordering.
final class _FakeAppServer {
  _FakeAppServer(this._peer) {
    _subscription = _peer.readable.listen(_handle);
  }

  final AcpDuplexStream<Object?> _peer;
  late final StreamSubscription<Object?> _subscription;
  final Completer<void> _sawTurnStart = Completer<void>();

  /// Completes when `turn/start` has arrived and been deliberately left
  /// unanswered.
  Future<void> get pendingTurnStart => _sawTurnStart.future;

  void _handle(Object? message) {
    if (message is! Map<Object?, Object?>) {
      return;
    }
    final id = message['id'];
    final method = message['method'];
    if (id == null || method is! String) {
      return;
    }
    if (method == 'turn/start') {
      // Answer nothing: the process is about to die with this in flight.
      if (!_sawTurnStart.isCompleted) {
        _sawTurnStart.complete();
      }
      return;
    }
    unawaited(
      _peer.writable.write(<String, Object?>{
        'id': id,
        'result': _result(method),
      }),
    );
  }

  Map<String, Object?> _result(String method) => switch (method) {
    'initialize' => <String, Object?>{'codexHome': '/tmp/codex-home'},
    'model/list' => <String, Object?>{
      'data': <Object?>[
        <String, Object?>{
          'id': 'gpt-test',
          'displayName': 'GPT Test',
          'description': 'Deterministic fake model',
          'isDefault': true,
          'defaultReasoningEffort': 'medium',
          'supportedReasoningEfforts': <Object?>[
            <String, Object?>{'reasoningEffort': 'medium'},
          ],
          'inputModalities': <Object?>['text'],
          'contextWindow': 128000,
        },
      ],
      'nextCursor': null,
    },
    'thread/start' => <String, Object?>{
      'thread': <String, Object?>{'id': 'thread-1'},
      'cwd': '/workspace',
      'model': 'gpt-test',
      'reasoningEffort': 'medium',
      'sandbox': <String, Object?>{'type': 'workspaceWrite'},
    },
    'skills/list' => <String, Object?>{'data': <Object?>[]},
    'mcpServerStatus/list' => <String, Object?>{'data': <Object?>[]},
    _ => <String, Object?>{},
  };

  /// Reaches EOF, the way an app-server process exiting does.
  Future<void> crash() => _peer.writable.close();

  Future<void> dispose() => _subscription.cancel();
}

void main() {
  test('a crash while turn/start is pending fails the FIRST prompt as a dead '
      'session', () async {
    final pair = acpInProcessTransportPair<Object?>();
    final server = _FakeAppServer(pair.right);
    addTearDown(server.dispose);
    final backend = CodexJsonRpcBackend.connect(pair.left);
    final agent = CodexAgent(
      backend: backend,
      options: CodexAdapterOptions(environment: const <String, String>{}),
    );
    final connection = await AcpClientApp.v1(
      implementation: Implementation(name: 'test-client', version: '1.0.0'),
      capabilities: ClientCapabilities(
        fs: FileSystemCapabilities(readTextFile: false, writeTextFile: false),
        terminal: false,
      ),
    ).connectWith(agent.app);
    addTearDown(connection.close);
    await agent.initialized;
    final created = await connection.client.agent.createSession(
      NewSessionRequest(cwd: '/workspace', mcpServers: const <McpServer>[]),
    );

    final turn = connection.client.agent.sendPrompt(
      PromptRequest(
        sessionId: created.sessionId,
        prompt: <ContentBlock>[_text('hello')],
      ),
    );
    await server.pendingTurnStart;
    await server.crash();

    // The point of the test: the FIRST prompt carries the marker, so the
    // client replaces the session without also discarding a second message.
    await expectLater(turn, throwsA(_isDeadSession));
  });

  test('an app server that dies mid-turn fails the turn as a dead '
      'session', () async {
    final started = await _startSession();
    final turn = started.client.agent.sendPrompt(
      PromptRequest(
        sessionId: started.session,
        prompt: <ContentBlock>[_text('hello')],
      ),
    );
    await _flush();
    expect(started.backend.count('turn/start'), 1);

    // The app server exits: its streams end under a turn that is waiting for
    // `turn/completed`, which otherwise never arrives and never settles.
    await started.backend.close();

    await expectLater(turn, throwsA(_isDeadSession));
  });

  test('a prompt after the app server exits fails fast, not as invalid '
      'params', () async {
    final started = await _startSession();
    await started.backend.close();
    await _flush();

    await expectLater(
      started.client.agent.sendPrompt(
        PromptRequest(
          sessionId: started.session,
          prompt: <ContentBlock>[_text('anyone there?')],
        ),
      ),
      throwsA(_isDeadSession),
    );
    // Nothing was handed to the dead process.
    expect(started.backend.count('turn/start'), 0);
  });

  test('an unknown session on a live app server is still a params '
      'error', () async {
    final started = await _startSession();
    addTearDown(started.client.close);

    await expectLater(
      started.client.agent.sendPrompt(
        PromptRequest(
          sessionId: SessionId('no-such-thread'),
          prompt: <ContentBlock>[_text('hello')],
        ),
      ),
      throwsA(
        predicate<Object>((error) {
          final data = _errorData(error);
          return (error as JsonRpcRequestException).code == -32602 &&
              data['sessionId'] == 'no-such-thread' &&
              data['sessionDead'] == null;
        }, 'an invalid-params error naming the session'),
      ),
    );
  });

  test('a handler failure names its cause instead of "Internal '
      'error"', () async {
    final started = await _startSession(
      configure: (backend) => backend.on('turn/start', (_) {
        throw StateError('app server refused the turn');
      }),
    );
    addTearDown(started.client.close);

    await expectLater(
      started.client.agent.sendPrompt(
        PromptRequest(
          sessionId: started.session,
          prompt: <ContentBlock>[_text('hello')],
        ),
      ),
      throwsA(
        predicate<Object>(
          (error) => _errorData(
            error,
          )['details'].toString().contains('app server refused the turn'),
          'an internal error carrying the underlying cause',
        ),
      ),
    );
  });

  test('a stream error names its cause without claiming the session is '
      'dead', () async {
    final started = await _startSession();
    addTearDown(started.client.close);
    final turn = started.client.agent.sendPrompt(
      PromptRequest(
        sessionId: started.session,
        prompt: <ContentBlock>[_text('hello')],
      ),
    );
    await _flush();

    started.backend.emitNotificationError(StateError('framing went wrong'));

    await expectLater(
      turn,
      throwsA(
        predicate<Object>((error) {
          final data = _errorData(error);
          return data['sessionDead'] == null &&
              (data['message'] as String).contains('framing went wrong');
        }, 'an internal error naming the stream failure'),
      ),
    );
  });
}
