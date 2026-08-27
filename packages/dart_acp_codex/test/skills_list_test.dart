import 'package:dart_acp_codex/src/app_server/backend.dart';
import 'package:dart_acp_codex/src/app_server/json_values.dart';
import 'package:dart_acp_codex/src/bridge/commands.dart';
import 'package:test/test.dart';

/// `skills/list` groups skills per working directory (`data[].skills[]`),
/// repeating user-level skills under every cwd. The old parser read names off
/// the GROUPS, so it always found nothing — the desktop client's command
/// picker listed only the built-ins while the CLI's own composer showed the
/// user's skills. Shapes below are verbatim from codex 0.150 app-server.
void main() {
  test('parses the per-cwd grouped shape, deduplicated and enabled-only', () {
    final response = CodexJsonObject.from(<String, Object?>{
      'data': <Object?>[
        <String, Object?>{
          'cwd': '/ws',
          'skills': <Object?>[
            <String, Object?>{
              'name': 'probe-skill',
              'description': 'Probe skill for integration testing.',
              'path': '/Users/u/.codex/skills/probe-skill/SKILL.md',
              'scope': 'user',
              'enabled': true,
              'pluginId': null,
            },
            <String, Object?>{
              'name': 'openai-templates:analytics',
              'description': 'Create a spreadsheet using the template.',
              'interface': <String, Object?>{
                'displayName': 'Analytics Dashboard',
                'shortDescription': 'Create spreadsheets with the template',
              },
              'enabled': true,
            },
            <String, Object?>{
              'name': 'disabled-skill',
              'description': 'Should not be listed.',
              'enabled': false,
            },
          ],
        },
        <String, Object?>{
          'cwd': '/other',
          'skills': <Object?>[
            // The same user-level skill repeats under every cwd.
            <String, Object?>{
              'name': 'probe-skill',
              'description': 'Probe skill for integration testing.',
              'enabled': true,
            },
          ],
        },
      ],
    });

    final skills = CodexCommands.parseSkills(response).toList();

    expect(skills.map((s) => s.name), [
      'probe-skill',
      'openai-templates:analytics',
    ]);
    expect(skills.first.description, 'Probe skill for integration testing.');
    // The interface's short description reads better in a picker than the
    // model-facing description.
    expect(skills.last.description, 'Create spreadsheets with the template');
  });

  test('accepts a flat list too', () {
    final response = CodexJsonObject.from(<String, Object?>{
      'skills': <Object?>[
        <String, Object?>{'name': 'flat-skill', 'description': 'Flat.'},
      ],
    });
    expect(CodexCommands.parseSkills(response).single.name, 'flat-skill');
  });

  test('malformed responses read as no skills', () {
    for (final body in <Map<String, Object?>>[
      <String, Object?>{},
      <String, Object?>{'data': 'nope'},
      <String, Object?>{
        'data': <Object?>[42, null, 'x'],
      },
    ]) {
      expect(
        CodexCommands.parseSkills(CodexJsonObject.from(body)),
        isEmpty,
        reason: '$body',
      );
    }
  });

  test('skills publish into the command list with their own descriptions', () {
    const commands = CodexCommands(_NoBackend());
    final update = commands
        .availableCommands(
          skills: const [
            CodexSkill(name: 'probe-skill', description: 'Probes.'),
          ],
        )
        .toJson();
    final names = [
      for (final c in update['availableCommands'] as List<Object?>)
        (c as Map<Object?, Object?>)['name'],
    ];
    expect(names, contains('probe-skill'));
    expect(names, contains('review'));
  });
}

final class _NoBackend implements CodexBackend {
  const _NoBackend();

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not used');
}
