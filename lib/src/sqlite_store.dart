import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'event.dart';
import 'filter.dart';
import 'store.dart';

class SqliteRelayStore implements RelayStore {
  SqliteRelayStore(this.path);

  final String path;
  late final Database _db;
  bool _open = false;

  @override
  Future<void> open() async {
    if (_open) {
      return;
    }
    _db = sqlite3.open(path);
    _db.execute('''
CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  pubkey TEXT NOT NULL,
  kind INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  content TEXT NOT NULL,
  sig TEXT NOT NULL,
  raw TEXT NOT NULL,
  d_tag TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_pubkey ON events(pubkey);
CREATE INDEX IF NOT EXISTS idx_events_kind ON events(kind);
CREATE INDEX IF NOT EXISTS idx_events_created_at ON events(created_at);
CREATE INDEX IF NOT EXISTS idx_events_replaceable ON events(pubkey, kind);
CREATE INDEX IF NOT EXISTS idx_events_addressable ON events(kind, pubkey, d_tag);

CREATE TABLE IF NOT EXISTS event_tags (
  event_id TEXT NOT NULL,
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  FOREIGN KEY(event_id) REFERENCES events(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_event_tags_name_value ON event_tags(name, value);
CREATE INDEX IF NOT EXISTS idx_event_tags_event_id ON event_tags(event_id);

CREATE TABLE IF NOT EXISTS deleted_events (
  id TEXT PRIMARY KEY,
  deleted_at INTEGER NOT NULL
);
''');
    _open = true;
  }

  @override
  Future<void> close() async {
    if (!_open) {
      return;
    }
    _db.close();
    _open = false;
  }

  @override
  Future<StoreSaveResult> saveEvent(NostrEvent event) async {
    final deleted = _db.select('SELECT id FROM deleted_events WHERE id = ?', [
      event.id,
    ]);
    if (deleted.isNotEmpty) {
      return const StoreSaveResult(false, 'blocked: event was deleted');
    }
    final existing = _db.select('SELECT id FROM events WHERE id = ?', [
      event.id,
    ]);
    if (existing.isNotEmpty) {
      return StoreSaveResult.duplicate;
    }

    if (event.isReplaceable || event.isAddressable) {
      final dTag = event.isAddressable ? event.firstTagValue('d') ?? '' : null;
      final rows = event.isAddressable
          ? _db.select(
              'SELECT id, created_at FROM events WHERE kind = ? AND pubkey = ? AND d_tag = ?',
              [event.kind, event.pubkey, dTag],
            )
          : _db.select(
              'SELECT id, created_at FROM events WHERE kind = ? AND pubkey = ?',
              [event.kind, event.pubkey],
            );
      for (final row in rows) {
        final oldId = row['id'] as String;
        final oldCreatedAt = row['created_at'] as int;
        final newer =
            event.createdAt > oldCreatedAt ||
            (event.createdAt == oldCreatedAt && event.id.compareTo(oldId) < 0);
        if (!newer) {
          return StoreSaveResult.ignoredOlder;
        }
      }
      await deleteEventsByIds(rows.map((row) => row['id'] as String));
    }

    _insertEvent(event);
    return StoreSaveResult.stored;
  }

  @override
  Future<List<NostrEvent>> query(
    List<NostrFilter> filters, {
    Set<String> allowedGiftWrapRecipients = const {},
    int? maxResults,
  }) async {
    if (filters.isEmpty) {
      return const [];
    }
    final all = <String, NostrEvent>{};
    for (final filter in filters) {
      final events = _queryOne(
        filter,
        allowedGiftWrapRecipients: allowedGiftWrapRecipients,
        maxResults: maxResults,
      );
      for (final event in events) {
        all[event.id] = event;
      }
    }
    final result = all.values.toList()
      ..sort((a, b) {
        final timeDiff = b.createdAt.compareTo(a.createdAt);
        if (timeDiff != 0) {
          return timeDiff;
        }
        return a.id.compareTo(b.id);
      });
    if (maxResults != null && result.length > maxResults) {
      return result.take(maxResults).toList();
    }
    return result;
  }

  @override
  Future<List<RelayRecord>> records(
    List<NostrFilter> filters, {
    required int limit,
    Set<String> allowedGiftWrapRecipients = const {},
  }) async {
    final events = await query(
      [
        for (final filter in filters)
          NostrFilter(
            ids: filter.ids,
            authors: filter.authors,
            kinds: filter.kinds,
            since: filter.since,
            until: filter.until,
            limit: limit,
            tagFilters: filter.tagFilters,
          ),
      ],
      allowedGiftWrapRecipients: allowedGiftWrapRecipients,
      maxResults: limit,
    );
    final records =
        events.map((event) => RelayRecord(event.createdAt, event.id)).toList()
          ..sort();
    if (records.length > limit) {
      return records.take(limit).toList();
    }
    return records;
  }

  @override
  Future<int> count(
    List<NostrFilter> filters, {
    Set<String> allowedGiftWrapRecipients = const {},
    int? maxResults,
  }) async => (await query(
    filters,
    allowedGiftWrapRecipients: allowedGiftWrapRecipients,
    maxResults: maxResults,
  )).length;

  @override
  Future<void> deleteEventsByIds(Iterable<String> ids) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final deleteEvent = _db.prepare('DELETE FROM events WHERE id = ?');
    final deleteTags = _db.prepare('DELETE FROM event_tags WHERE event_id = ?');
    final tombstone = _db.prepare(
      'INSERT OR IGNORE INTO deleted_events(id, deleted_at) VALUES (?, ?)',
    );
    try {
      _db.execute('BEGIN');
      for (final id in ids.toSet()) {
        tombstone.execute([id, now]);
        deleteTags.execute([id]);
        deleteEvent.execute([id]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      deleteEvent.close();
      deleteTags.close();
      tombstone.close();
    }
  }

  @override
  Future<void> deleteGiftWrapsByRecipientAndIds(
    String recipientPubkey,
    Iterable<String> ids,
  ) async {
    final idSet = ids.toSet();
    if (idSet.isEmpty) {
      return;
    }
    final rows = _db.select(
      '''
SELECT e.id FROM events e
JOIN event_tags t ON t.event_id = e.id
WHERE e.kind = 1059 AND t.name = 'p' AND t.value = ?
''',
      [recipientPubkey],
    );
    final allowedIds = rows
        .map((row) => row['id'] as String)
        .where(idSet.contains);
    await deleteEventsByIds(allowedIds);
  }

  @override
  Future<void> deleteGiftWrapsByRecipient(String recipientPubkey) async {
    final rows = _db.select(
      '''
SELECT e.id FROM events e
JOIN event_tags t ON t.event_id = e.id
WHERE e.kind = 1059 AND t.name = 'p' AND t.value = ?
''',
      [recipientPubkey],
    );
    await deleteEventsByIds(rows.map((row) => row['id'] as String));
  }

  @override
  Future<void> vanishPubkey(String pubkey) async {
    final rows = _db.select('SELECT id FROM events WHERE pubkey = ?', [pubkey]);
    await deleteEventsByIds(rows.map((row) => row['id'] as String));
    await deleteGiftWrapsByRecipient(pubkey);
  }

  void _insertEvent(NostrEvent event) {
    final dTag = event.isAddressable ? event.firstTagValue('d') ?? '' : null;
    final insertEvent = _db.prepare('''
INSERT INTO events(id, pubkey, kind, created_at, content, sig, raw, d_tag)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
''');
    final insertTag = _db.prepare(
      'INSERT INTO event_tags(event_id, name, value) VALUES (?, ?, ?)',
    );
    try {
      _db.execute('BEGIN');
      insertEvent.execute([
        event.id,
        event.pubkey,
        event.kind,
        event.createdAt,
        event.content,
        event.sig,
        jsonEncode(event.toJson()),
        dTag,
      ]);
      for (final tag in event.tags) {
        if (tag.length > 1 && RegExp(r'^[A-Za-z]$').hasMatch(tag.first)) {
          insertTag.execute([event.id, tag.first, tag[1]]);
        }
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      insertEvent.close();
      insertTag.close();
    }
  }

  List<NostrEvent> _queryOne(
    NostrFilter filter, {
    required Set<String> allowedGiftWrapRecipients,
    int? maxResults,
  }) {
    final clauses = <String>[];
    final args = <Object?>[];

    if (filter.ids != null && filter.ids!.isNotEmpty) {
      clauses.add(
        '(${List.filled(filter.ids!.length, 'id LIKE ?').join(' OR ')})',
      );
      args.addAll(filter.ids!.map((id) => '$id%'));
    }
    if (filter.authors != null && filter.authors!.isNotEmpty) {
      clauses.add(
        'pubkey IN (${List.filled(filter.authors!.length, '?').join(', ')})',
      );
      args.addAll(filter.authors!);
    }
    if (filter.kinds != null && filter.kinds!.isNotEmpty) {
      clauses.add(
        'kind IN (${List.filled(filter.kinds!.length, '?').join(', ')})',
      );
      args.addAll(filter.kinds!);
    }
    if (filter.since != null) {
      clauses.add('created_at >= ?');
      args.add(filter.since);
    }
    if (filter.until != null) {
      clauses.add('created_at <= ?');
      args.add(filter.until);
    }
    for (final entry in filter.tagFilters.entries) {
      if (entry.value.isEmpty) {
        return const [];
      }
      clauses.add(
        'id IN (SELECT event_id FROM event_tags WHERE name = ? AND value IN (${List.filled(entry.value.length, '?').join(', ')}))',
      );
      args.add(entry.key);
      args.addAll(entry.value);
    }
    if (allowedGiftWrapRecipients.isEmpty) {
      clauses.add('kind NOT IN (1059, 21059)');
    } else {
      clauses.add(
        '(kind NOT IN (1059, 21059) OR id IN (SELECT event_id FROM event_tags WHERE name = ? AND value IN (${List.filled(allowedGiftWrapRecipients.length, '?').join(', ')})))',
      );
      args.add('p');
      args.addAll(allowedGiftWrapRecipients);
    }

    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final limitValue = _minPositive(filter.limit, maxResults);
    final limit = limitValue == null ? '' : 'LIMIT ?';
    if (limitValue != null) {
      args.add(limitValue);
    }
    final rows = _db.select(
      'SELECT raw FROM events $where ORDER BY created_at DESC, id ASC $limit',
      args,
    );
    return [
      for (final row in rows)
        NostrEvent.fromJson(jsonDecode(row['raw'] as String)),
    ];
  }

  int? _minPositive(int? left, int? right) {
    final values = [
      if (left != null && left > 0) left,
      if (right != null && right > 0) right,
    ];
    if (values.isEmpty) {
      return null;
    }
    values.sort();
    return values.first;
  }
}
