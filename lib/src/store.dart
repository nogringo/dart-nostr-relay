import 'event.dart';
import 'filter.dart';

class RelayRecord implements Comparable<RelayRecord> {
  RelayRecord(this.createdAt, this.id);

  final int createdAt;
  final String id;

  @override
  int compareTo(RelayRecord other) {
    final timeDiff = createdAt.compareTo(other.createdAt);
    if (timeDiff != 0) {
      return timeDiff;
    }
    return id.compareTo(other.id);
  }
}

class StoreSaveResult {
  const StoreSaveResult(this.accepted, this.message);

  final bool accepted;
  final String message;

  static const stored = StoreSaveResult(true, '');
  static const duplicate = StoreSaveResult(
    true,
    'duplicate: already have this event',
  );
  static const ignoredOlder = StoreSaveResult(
    true,
    'duplicate: newer replaceable event already exists',
  );
}

abstract class RelayStore {
  Future<void> open();

  Future<void> close();

  Future<StoreSaveResult> saveEvent(NostrEvent event);

  Future<List<NostrEvent>> query(
    List<NostrFilter> filters, {
    Set<String> allowedGiftWrapRecipients = const {},
    int? maxResults,
  });

  Future<List<RelayRecord>> records(
    List<NostrFilter> filters, {
    required int limit,
    Set<String> allowedGiftWrapRecipients = const {},
  });

  Future<int> count(
    List<NostrFilter> filters, {
    Set<String> allowedGiftWrapRecipients = const {},
    int? maxResults,
  });

  Future<void> deleteEventsByIds(Iterable<String> ids);

  Future<void> deleteGiftWrapsByRecipientAndIds(
    String recipientPubkey,
    Iterable<String> ids,
  );

  Future<void> deleteGiftWrapsByRecipient(String recipientPubkey);

  Future<void> vanishPubkey(String pubkey);
}
