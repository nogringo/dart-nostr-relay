import 'event.dart';
import 'utils.dart';

class NostrFilter {
  NostrFilter({
    this.ids,
    this.authors,
    this.kinds,
    this.since,
    this.until,
    this.limit,
    Map<String, List<String>>? tagFilters,
  }) : tagFilters = tagFilters ?? const {};

  final List<String>? ids;
  final List<String>? authors;
  final List<int>? kinds;
  final int? since;
  final int? until;
  final int? limit;
  final Map<String, List<String>> tagFilters;

  factory NostrFilter.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('filter must be an object');
    }
    List<String>? stringList(String key) {
      final value = json[key];
      if (value == null) {
        return null;
      }
      if (value is! List || value.any((item) => item is! String)) {
        throw FormatException('$key must be a list of strings');
      }
      return value.cast<String>();
    }

    List<int>? intList(String key) {
      final value = json[key];
      if (value == null) {
        return null;
      }
      if (value is! List || value.any((item) => item is! int)) {
        throw FormatException('$key must be a list of integers');
      }
      return value.cast<int>();
    }

    int? scalarInt(String key) {
      final value = json[key];
      if (value == null) {
        return null;
      }
      if (value is! int) {
        throw FormatException('$key must be an integer');
      }
      return value;
    }

    final tagFilters = <String, List<String>>{};
    for (final entry in json.entries) {
      final key = entry.key;
      if (key is String && RegExp(r'^#[A-Za-z]$').hasMatch(key)) {
        final value = entry.value;
        if (value is! List || value.any((item) => item is! String)) {
          throw FormatException('$key must be a list of strings');
        }
        tagFilters[key.substring(1)] = value.cast<String>();
      }
    }

    return NostrFilter(
      ids: stringList('ids'),
      authors: stringList('authors'),
      kinds: intList('kinds'),
      since: scalarInt('since'),
      until: scalarInt('until'),
      limit: scalarInt('limit'),
      tagFilters: tagFilters,
    );
  }

  bool get explicitlyAsksForGiftWrap =>
      kinds != null && (kinds!.contains(1059) || kinds!.contains(21059));

  bool get mayIncludeGiftWrap =>
      kinds == null || kinds!.contains(1059) || kinds!.contains(21059);

  bool matches(NostrEvent event) {
    if (ids != null && !ids!.any((id) => event.id.startsWith(id))) {
      return false;
    }
    if (authors != null && !authors!.contains(event.pubkey)) {
      return false;
    }
    if (kinds != null && !kinds!.contains(event.kind)) {
      return false;
    }
    if (since != null && event.createdAt < since!) {
      return false;
    }
    if (until != null && event.createdAt > until!) {
      return false;
    }
    for (final entry in tagFilters.entries) {
      final eventValues = event.tagValues(entry.key);
      if (!eventValues.any(entry.value.contains)) {
        return false;
      }
    }
    return true;
  }

  String? validate() {
    if (ids != null &&
        ids!.any(
          (id) =>
              id.isEmpty ||
              id.length > 64 ||
              !RegExp(r'^[0-9a-f]+$').hasMatch(id),
        )) {
      return 'invalid: ids must be lowercase hex prefixes';
    }
    if (authors != null && authors!.any((author) => !isLowerHex64(author))) {
      return 'invalid: authors must be 32-byte lowercase hex';
    }
    return null;
  }
}
