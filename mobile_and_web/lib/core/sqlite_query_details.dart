import 'dart:convert';
import 'dart:typed_data';

import 'debug_traffic_logger.dart';

/// Detached, redacted detail for one real executor call. Never rereads SQLite.
final class SqliteQueryDetails {
  SqliteQueryDetails._(this.operation, this._request, this._sensitive);

  static const maxBytes = 32 * 1024;
  static const _requestLimit = 16 * 1024;
  final String operation;
  final Map<String, Object?> _request;
  final bool _sensitive;

  factory SqliteQueryDetails.capture(
    String operation,
    String statement,
    List<Object?> arguments,
  ) {
    final sql = _sql(statement);
    return SqliteQueryDetails._(
      operation,
      Map.unmodifiable({
        'policy': 'full_debug',
        'database': 'chat_app_db',
        'operation': operation,
        'statement': _value(sql.statement, 8192),
        ..._parameters(arguments, sql.sensitive, 7000),
        if (sql.sensitive) 'credentialsOmitted': true,
      }),
      sql.sensitive,
    );
  }

  factory SqliteQueryDetails.batch(
    List<String> statements,
    List<({int statementIndex, List<Object?> arguments})> executions,
  ) {
    final parsed = statements.map(_sql).toList();
    final templates = <Object?>[];
    var used = 0;
    for (var index = 0; index < parsed.length; index++) {
      final template = {
        'statementIndex': index,
        'statement': _value(parsed[index].statement, 4096),
      };
      final bytes = _bytes(template);
      if (used + bytes > _requestLimit ~/ 2) break;
      templates.add(Map.unmodifiable(template));
      used += bytes;
    }
    final runs = <Object?>[];
    for (final execution in executions) {
      final index = execution.statementIndex;
      final sensitive =
          index < 0 || index >= parsed.length || parsed[index].sensitive;
      final item = {
        'statementIndex': index,
        ..._parameters(execution.arguments, sensitive, 4096),
      };
      final bytes = _bytes(item);
      if (used + bytes > _requestLimit) break;
      runs.add(Map.unmodifiable(item));
      used += bytes;
    }
    return SqliteQueryDetails._(
      'batch',
      Map.unmodifiable({
        'policy': 'full_debug',
        'database': 'chat_app_db',
        'operation': 'batch',
        'statements': List.unmodifiable(templates),
        'statementsOmitted': statements.length - templates.length,
        'executions': List.unmodifiable(runs),
        'executionsOmitted': executions.length - runs.length,
      }),
      parsed.any((item) => item.sensitive),
    );
  }

  Map<String, Object?> snapshot({
    Object? result,
    bool completed = false,
    bool failed = false,
    bool cancelled = false,
  }) {
    if (!completed) return _request;
    final response = <String, Object?>{};
    if (failed || cancelled) {
      response['outcome'] = cancelled ? 'cancelled' : 'failed';
    } else if (operation == 'select' && result is List) {
      response['rowCount'] = result.length;
      final rows = <Object?>[];
      var used = _bytes(_request) + 512;
      if (!_sensitive) {
        for (final row in result) {
          final safe = _value(row, 8192);
          final bytes = _bytes(safe) + 1;
          if (used + bytes > maxBytes) break;
          rows.add(safe);
          used += bytes;
        }
      }
      response.addAll({
        'rows': List.unmodifiable(rows),
        'rowsCaptured': rows.length,
        'rowsOmitted': result.length - rows.length,
      });
      if (_sensitive) response['credentialsOmitted'] = true;
    } else if (operation == 'insert' && result is int) {
      response['lastInsertRowId'] = result;
      response['observation'] =
          'SQLite insert return value; not an affected-row count or a reread.';
    } else if ((operation == 'update' || operation == 'delete') &&
        result is int) {
      response['affectedRows'] = result;
    } else {
      response['outcome'] = 'completed';
      response['observation'] = 'Executor returned no rows or per-statement counts; transaction commit/rollback is recorded separately.';
    }
    return Map.unmodifiable({
      ..._request,
      'result': Map.unmodifiable(response),
    });
  }

  static Map<String, Object?> _parameters(
    List<Object?> values,
    bool sensitive,
    int budget,
  ) {
    final parameters = <Object?>[];
    var used = 0;
    for (var index = 0; index < values.length; index++) {
      final value = values[index];
      final item = {
        'position': index + 1,
        'storageType': _type(value),
        'value': sensitive ? '[REDACTED]' : _value(value, 4096),
      };
      final bytes = _bytes(item) + 1;
      if (used + bytes > budget) break;
      parameters.add(Map.unmodifiable(item));
      used += bytes;
    }
    return {
      'parameters': List.unmodifiable(parameters),
      'parametersOmitted': values.length - parameters.length,
    };
  }

  static String _type(Object? value) => switch (value) {
    null => 'null',
    int() => 'integer',
    double() => 'real',
    bool() => 'boolean',
    String() => 'text',
    TypedData() || ByteBuffer() => 'blob',
    _ => 'other',
  };

  static int _bytes(Object? value) => utf8.encode(jsonEncode(value)).length;

  static Object? _value(Object? value, int limit) {
    try {
      final safe = DebugTrafficLogger.snapshotValue(value);
      final bytes = _bytes(safe);
      return bytes <= limit
          ? safe
          : Map<String, Object?>.unmodifiable({
              'payloadOmitted': true,
              'omissionReason': 'detail_byte_limit',
              'omittedBytes': bytes,
              'limitBytes': limit,
            });
    } catch (_) {
      return const {'payloadOmitted': true, 'omissionReason': 'unserializable'};
    }
  }

  static final _tokens = RegExp(
    r'''--[^\r\n]*|/\*[\s\S]*?\*/|'(?:''|[^'])*'|"(?:""|[^"])*"|`(?:``|[^`])*`|\[[^\]]*\]|\?[0-9]*|[:@$][a-zA-Z_][a-zA-Z_0-9]*|[a-zA-Z_][a-zA-Z_0-9]*|[0-9]+(?:\.[0-9]+)?|[\s\S]''',
  );

  static ({String statement, bool sensitive}) _sql(String statement) {
    // Do not retain a large SQL string or guess whether a truncated prefix
    // references credentials later in the statement.
    if (statement.length > 8192) {
      return (
        statement: '[SQL omitted: statement_byte_limit]',
        sensitive: true,
      );
    }
    final tokens = _tokens
        .allMatches(statement)
        .map((match) => match[0]!)
        .toList();
    bool literal(String token) => token.startsWith("'");
    bool comment(String token) =>
        token.startsWith('--') || token.startsWith('/*');
    final sensitive = tokens.any(
      (token) =>
          !literal(token) &&
          !comment(token) &&
          DebugTrafficLogger.credentialField(token),
    );
    final output = StringBuffer();
    String? previous;
    for (final token in tokens) {
      if (comment(token)) {
        output.write('/* comment omitted */');
      } else if (literal(token)) {
        if (token.length < 2) {
          return (statement: '[SQL omitted: invalid literal]', sensitive: true);
        }
        final decoded = token
            .substring(1, token.length - 1)
            .replaceAll("''", "'");
        final safe = sensitive
            ? '[REDACTED]'
            : previous?.toUpperCase() == 'X'
            ? '[BINARY]'
            : DebugTrafficLogger.snapshotValue(decoded);
        output.write("'${safe.toString().replaceAll("'", "''")}'");
      } else if (sensitive && RegExp(r'^[0-9]').hasMatch(token)) {
        output.write('[REDACTED]');
      } else {
        output.write(token);
      }
      if (token.trim().isNotEmpty && !comment(token)) previous = token;
    }
    return (statement: output.toString(), sensitive: sensitive);
  }
}
