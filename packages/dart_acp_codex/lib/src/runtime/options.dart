import 'dart:collection';
import 'dart:io';

import '../app_server/json_values.dart';
import '../config/authentication.dart';
import '../config/modes.dart';
import 'diagnostics.dart';

/// The Codex app-server reviewer for eligible approval requests.
enum CodexApprovalsReviewer {
  /// Route approval requests to the ACP client for human review.
  user('user'),

  /// Let Codex's native automatic reviewer decide eligible requests.
  autoReview('auto_review');

  const CodexApprovalsReviewer(this.appServerValue);

  /// Wire value sent to Codex app-server.
  final String appServerValue;
}

/// Runtime configuration for a local adapter.
final class CodexAdapterOptions {
  /// Creates validated runtime options.
  CodexAdapterOptions({
    this.executable,
    CodexJsonObject? configuration,
    this.modelProvider,
    this.defaultAuthentication,
    Map<String, String>? environment,
    this.workspaceWriteApprovalsReviewer = CodexApprovalsReviewer.user,
    this.shutdownTimeout = const Duration(seconds: 2),
    this.maximumStderrTailCharacters = 2048,
    this.maximumAppServerLineBytes = defaultMaximumAppServerLineBytes,
    this.mcpRevivePollInterval = const Duration(milliseconds: 300),
    this.mcpRevivePollAttempts = 30,
    this.onDiagnostic,
  }) : configuration = configuration ?? CodexJsonObject.empty,
       environment = UnmodifiableMapView<String, String>(
         Map<String, String>.of(environment ?? Platform.environment),
       ) {
    if (executable case final String path when path.trim().isEmpty) {
      throw const CodexConfigurationException(
        'Executable path must not be empty.',
      );
    }
    if (shutdownTimeout <= Duration.zero) {
      throw const CodexConfigurationException(
        'Shutdown timeout must be positive.',
      );
    }
    if (maximumStderrTailCharacters <= 0) {
      throw const CodexConfigurationException(
        'Maximum stderr tail characters must be positive.',
      );
    }
    if (maximumAppServerLineBytes <= 0) {
      throw const CodexConfigurationException(
        'Maximum app-server line bytes must be positive.',
      );
    }
    if (mcpRevivePollInterval <= Duration.zero) {
      throw const CodexConfigurationException(
        'MCP revive poll interval must be positive.',
      );
    }
    if (mcpRevivePollAttempts < 0) {
      throw const CodexConfigurationException(
        'MCP revive poll attempts must not be negative.',
      );
    }
  }

  /// Explicit executable path or command.
  final String? executable;

  /// Base app-server configuration.
  final CodexJsonObject configuration;

  /// Optional model-provider id.
  final String? modelProvider;

  /// Authentication attempted when a session requires it.
  final CodexAuthentication? defaultAuthentication;

  /// Child environment.
  final Map<String, String> environment;

  /// Reviewer used for standard workspace-write turns.
  ///
  /// Read-only and plan turns always remain human-reviewed. Full-access turns
  /// keep their `never` approval policy, so this setting does not widen their
  /// permissions.
  final CodexApprovalsReviewer workspaceWriteApprovalsReviewer;

  /// Resolves the app-server reviewer for a turn.
  ///
  /// Automatic review is deliberately limited to the standard collaboration
  /// mode in a workspace-write sandbox. This keeps read-only and plan turns on
  /// explicit human review even when an embedded client opts workspace work
  /// into automatic review.
  CodexApprovalsReviewer resolveApprovalsReviewer({
    required CodexAgentMode agentMode,
    required CodexCollaborationMode collaborationMode,
  }) =>
      agentMode == CodexAgentMode.workspaceWrite &&
          collaborationMode == CodexCollaborationMode.standard
      ? workspaceWriteApprovalsReviewer
      : CodexApprovalsReviewer.user;

  /// Graceful child shutdown timeout.
  final Duration shutdownTimeout;

  /// Maximum stderr characters retained for process-failure context.
  final int maximumStderrTailCharacters;

  /// Largest single app-server message accepted, in bytes excluding its
  /// newline. A longer message fails the connection.
  ///
  /// The cap exists to stop a runaway peer, not to bound legitimate output.
  /// `thread/resume` answers with the thread's ENTIRE turn history as one
  /// message, every command's aggregated output included, so a long-lived
  /// thread outgrows any modest cap and then fails on every reopen. The
  /// previous implicit 16 MiB (the SDK's NDJSON default) did exactly that.
  final int maximumAppServerLineBytes;

  /// 256 MiB.
  ///
  /// A month-long, 122-turn thread already resumes as a single 14.9 MiB
  /// message, and the resume grows with every command the thread runs. This
  /// leaves more than an order of magnitude of headroom while still stopping
  /// a peer that never ends its line before it exhausts memory.
  static const int defaultMaximumAppServerLineBytes = 256 * 1024 * 1024;

  /// How often the pre-turn MCP revive re-checks server health while waiting
  /// for a reloaded server to come back up.
  final Duration mcpRevivePollInterval;

  /// How many health re-checks the pre-turn MCP revive makes before giving
  /// up on the reload and letting the turn run (and suppressing further
  /// revive attempts for a while).
  final int mcpRevivePollAttempts;

  /// Receives redacted diagnostics.
  final void Function(CodexDiagnostic diagnostic)? onDiagnostic;
}
