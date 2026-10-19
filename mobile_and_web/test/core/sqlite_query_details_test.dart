import 'dart:convert';

import 'package:chat_workspace/core/app_database.dart';
import 'package:chat_workspace/core/debug_inspector.dart';
import 'package:chat_workspace/core/sqlite_query_details.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, Object?>> events(DebugInspector inspector) =>
    (inspector.snapshot()['events'] as List).cast<Map<String, Object?>>();
Map<String, Object?> details(Map<String, Object?> event) =>
    (event['data'] as Map)['sqlite'] as Map<String, Object?>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'SQL values detach while JSON credentials and binary bytes stay private',
    () {
      final bytes = Uint8List.fromList([11, 22, 33]);
      final args = <Object?>[
        'hello',
        '{"text":"business","password":"private-json"}',
        bytes,
      ];
      final query = SqliteQueryDetails.capture(
        'select',
        'SELECT ? AS text, ? AS json, ? AS bytes',
        args,
      );
      args[0] = 'changed-later';
      bytes[0] = 99;
      final value = query.snapshot(
        result: [
          {
            'text': 'result text',
            'token': 'private-result',
            'bytes': Uint8List.fromList([1, 2, 3]),
          },
        ],
        completed: true,
      );
      expect(value['statement'], 'SELECT ? AS text, ? AS json, ? AS bytes');
      final parameters = value['parameters'] as List;
      expect((parameters[0] as Map)['value'], 'hello');
      expect((parameters[2] as Map)['value'], {'type': 'binary', 'length': 3});
      expect(jsonEncode(value), contains('result text'));
      expect(jsonEncode(value), contains('[REDACTED]'));
      expect(jsonEncode(value), isNot(contains('private-')));
      expect(jsonEncode(value), isNot(contains('changed-later')));
      expect(
        () => (parameters[0] as Map)['value'] = 'changed',
        throwsUnsupportedError,
      );
    },
  );
  test('credential columns redact operands, aliased results, literals and comments', () {
    for (final sql in [
      "SELECT password_hash AS value FROM users WHERE id = ? AND pin = 123 -- private-comment",
      "UPDATE users SET token = 'private-literal' WHERE id = ?",
      'SELECT ? AS "sessionId"',
    ]) {
      final value =
          SqliteQueryDetails.capture('select', sql, [
            'private-argument',
          ]).snapshot(
            result: [
              {'value': 'private-alias'},
            ],
            completed: true,
          );
      expect(jsonEncode(value), isNot(contains('private-')));
      expect(jsonEncode(value), isNot(contains('123')));
      expect((value['result'] as Map)['rowsOmitted'], 1);
    }
    final inline = SqliteQueryDetails.capture(
      'select',
      "SELECT '{\"password\":\"private-json\"}' AS body, X'414243' AS bytes",
      [],
    ).snapshot();
    expect(jsonEncode(inline), isNot(contains('private-json')));
    expect(jsonEncode(inline), isNot(contains('414243')));
  });
  test('size bounds preserve honest counts and explicit row, value and batch omissions', () {
    final rows = List.generate(500, (i) => {'id': i, 'text': 'x' * 1000});
    final value = SqliteQueryDetails.capture(
      'select',
      'SELECT * FROM local_messages',
      [],
    ).snapshot(result: rows, completed: true);
    final result = value['result'] as Map;
    expect(result['rowCount'], 500);
    expect(result['rowsCaptured'], lessThan(500));
    expect(
      (result['rowsCaptured'] as int) + (result['rowsOmitted'] as int),
      500,
    );
    expect(
      utf8.encode(jsonEncode(value)).length,
      lessThanOrEqualTo(SqliteQueryDetails.maxBytes),
    );
    final batch = SqliteQueryDetails.batch(
      ['INSERT INTO local_messages (text) VALUES (?)'],
      [
        for (var i = 0; i < 100; i++)
          (statementIndex: 0, arguments: <Object?>['x' * 1000]),
      ],
    ).snapshot(completed: true);
    expect(batch['executionsOmitted'], greaterThan(0));
    expect(
      utf8.encode(jsonEncode(batch)).length,
      lessThanOrEqualTo(SqliteQueryDetails.maxBytes),
    );
    expect(
      jsonEncode(
        SqliteQueryDetails.capture('select', 'SELECT ?', [
          'x' * 10000,
        ]).snapshot(),
      ),
      contains('detail_byte_limit'),
    );
  });
  test(
    'toggle fences in-flight data and clears details while metadata continues',
    () {
      final inspector = DebugInspector(enabled: true);
      addTearDown(inspector.dispose);
      var captured = 0;
      SqliteQueryDetails capture() {
        captured++;
        return SqliteQueryDetails.capture('select', 'SELECT ?', [
          'private-row',
        ]);
      }

      inspector
          .begin('drift', 'query.select', sqlite: capture)!
          .finish(
            sqliteResult: [
              {'value': 'private-result'},
            ],
          );
      expect(captured, 0);
      inspector.setSqliteDetailsEnabled(true);
      final query = inspector.begin('drift', 'query.select', sqlite: capture)!;
      expect(captured, 1);
      expect(jsonEncode(events(inspector)), contains('private-row'));
      inspector.setSqliteDetailsEnabled(false);
      inspector.setSqliteDetailsEnabled(true);
      query.finish(
        sqliteResult: [
          {'value': 'private-result'},
        ],
      );
      expect(jsonEncode(events(inspector)), isNot(contains('private-')));
      final active = [
        for (var i = 0; i < DebugInspector.activeSpanLimit + 1; i++)
          inspector.begin('drift', 'query.select', sqlite: capture)!,
      ];
      expect(captured, DebugInspector.activeSpanLimit + 1);
      active.last.finish(
        sqliteResult: [
          {'value': 'overflow-secret'},
        ],
      );
      expect(
        jsonEncode(events(inspector)),
        contains('span_capacity_or_inspection_failure'),
      );
      expect(jsonEncode(events(inspector)), isNot(contains('overflow-secret')));
      for (final span in active) {
        span.finish();
      }
    },
  );
  test('real SQLite reads, inserts, updates, batches and failures retain actual behavior', () async {
    final inspector = DebugInspector(enabled: true)
      ..setSqliteDetailsEnabled(true);
    final db = AppDatabase(NativeDatabase.memory(), inspector);
    addTearDown(() async {
      await db.close();
      inspector.dispose();
    });
    await db.initializeSession('synthetic-user');
    await db.customStatement(
      'CREATE TABLE log_fixture (id INTEGER PRIMARY KEY, body TEXT, bytes BLOB)',
    );
    final id = await db.customInsert(
      'INSERT INTO log_fixture (body, bytes) VALUES (?, ?)',
      variables: [
        Variable('{"text":"row body","token":"private-token"}'),
        Variable.withBlob(Uint8List.fromList([41, 42, 43])),
      ],
    );
    final result = await db
        .customSelect(
          'SELECT * FROM log_fixture WHERE id = ?',
          variables: [Variable(id)],
        )
        .get();
    expect(result.single.read<String>('body'), contains('private-token'));
    final selected = events(inspector).lastWhere(
      (event) => event['name'] == 'query.select' && event['phase'] == 'end',
    );
    expect((details(selected)['result'] as Map)['rowCount'], 1);
    expect(jsonEncode(details(selected)), contains('row body'));
    expect(jsonEncode(details(selected)), isNot(contains('private-token')));
    final inserted = events(inspector).lastWhere(
      (event) => event['name'] == 'query.insert' && event['phase'] == 'end',
    );
    expect((details(inserted)['result'] as Map)['lastInsertRowId'], id);
    expect(
      await db.customUpdate(
        'UPDATE log_fixture SET body = ? WHERE id = ?',
        variables: [Variable('updated'), Variable(id)],
      ),
      1,
    );
    final updated = events(inspector).lastWhere(
      (event) => event['name'] == 'query.update' && event['phase'] == 'end',
    );
    expect((details(updated)['result'] as Map)['affectedRows'], 1);
    expect(
      await (db.delete(db.syncMetadata)..where((row) => row.id.equals(1))).go(),
      1,
    );
    final deleted = events(inspector).lastWhere(
      (event) => event['name'] == 'query.delete' && event['phase'] == 'end',
    );
    expect((details(deleted)['result'] as Map)['affectedRows'], 1);
    await db.batch((batch) {
      batch.customStatement('INSERT INTO log_fixture (body) VALUES (?)', [
        'batch-one',
      ]);
      batch.customStatement('INSERT INTO log_fixture (body) VALUES (?)', [
        'batch-two',
      ]);
    });
    final batched = events(inspector).lastWhere(
      (event) => event['name'] == 'query.batch' && event['phase'] == 'end',
    );
    expect(jsonEncode(details(batched)), contains('batch-one'));
    expect(jsonEncode(details(batched)), contains('statementIndex'));
    await expectLater(
      db.customSelect('SELECT * FROM missing_sql_fixture').get(),
      throwsA(isA<Object>()),
    );
    final failed = events(inspector).lastWhere(
      (event) => event['name'] == 'query.select' && event['phase'] == 'end',
    );
    expect((details(failed)['result'] as Map)['outcome'], 'failed');
    expect((failed['data'] as Map)['errorType'], isA<String>());
  });
}
