import 'package:dart_acp_codex/dart_acp_codex.dart';
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

void main() {
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
