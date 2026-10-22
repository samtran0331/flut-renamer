import 'package:path/path.dart' as p;

import 'ex_file.dart';

enum FileSortField { name, size, date, type }

/// Compares names in the order people normally expect: `file`, `file(2)`,
/// `file(10)` instead of lexicographic order, which puts `file` last.
int compareNaturally(String left, String right) =>
    _compareNaturalKeys(_NaturalKey.of(left), _NaturalKey.of(right));

/// A file name pre-split into digit and non-digit runs.
///
/// Splitting is done once per string with a single linear scan, so sorting
/// does not repeat regular-expression work on every comparison.
class _NaturalKey {
  _NaturalKey._(this.parts, this.isNumber);

  factory _NaturalKey.of(String value) {
    final lower = value.toLowerCase();
    final parts = <String>[];
    final isNumber = <bool>[];
    var start = 0;
    while (start < lower.length) {
      final digit = _isDigit(lower.codeUnitAt(start));
      var end = start + 1;
      while (end < lower.length && _isDigit(lower.codeUnitAt(end)) == digit) {
        end++;
      }
      final part = lower.substring(start, end);
      parts.add(digit ? _stripLeadingZeroes(part) : part);
      isNumber.add(digit);
      start = end;
    }
    return _NaturalKey._(parts, isNumber);
  }

  final List<String> parts;
  final List<bool> isNumber;
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

String _stripLeadingZeroes(String digits) {
  var index = 0;
  while (index < digits.length - 1 && digits.codeUnitAt(index) == 0x30) {
    index++;
  }
  return index == 0 ? digits : digits.substring(index);
}

int _compareNaturalKeys(_NaturalKey left, _NaturalKey right) {
  final length = left.parts.length < right.parts.length
      ? left.parts.length
      : right.parts.length;

  for (var index = 0; index < length; index++) {
    final leftPart = left.parts[index];
    final rightPart = right.parts[index];
    final comparison = left.isNumber[index] && right.isNumber[index]
        ? _compareNumericRuns(leftPart, rightPart)
        : leftPart.compareTo(rightPart);
    if (comparison != 0) return comparison;
  }

  return left.parts.length.compareTo(right.parts.length);
}

/// Compares decimal strings without converting them to a native integer.
///
/// File names may contain numeric runs that exceed Dart's integer range.
/// Leading zeroes are removed when the key is built, which makes length a
/// reliable magnitude comparison; equal-length runs can then be compared
/// lexicographically.
int _compareNumericRuns(String left, String right) {
  final lengthComparison = left.length.compareTo(right.length);
  if (lengthComparison != 0) return lengthComparison;

  return left.compareTo(right);
}

/// Loads size and modification-time values before a size/date sort.
///
/// A small worker pool keeps a very large selection from opening an
/// unbounded number of file-system requests at once. [compareFiles] only
/// reads the values cached by this function; it never performs I/O.
Future<void> preloadFileSortMetadata(Iterable<FileEntity> files) async {
  final pending = files.toList(growable: false);
  const maxConcurrentLoads = 8;
  final workerCount =
      pending.length < maxConcurrentLoads ? pending.length : maxConcurrentLoads;
  var nextIndex = 0;

  Future<void> loadNext() async {
    while (nextIndex < pending.length) {
      final file = pending[nextIndex++];
      await file.preloadSortMetadata();
    }
  }

  await Future.wait(
    List<Future<void>>.generate(workerCount, (_) => loadNext()),
  );
}

int compareFiles(FileEntity left, FileEntity right, FileSortField field) =>
    _compareFileKeys(_FileSortKey(left), _FileSortKey(right), field);

/// Sorts [files] in place by [field].
///
/// Natural-sort keys are computed once per file rather than once per
/// comparison, keeping large selections responsive on the UI isolate.
void sortFiles(
  List<FileEntity> files,
  FileSortField field, {
  bool ascending = true,
}) {
  final keys = files.map(_FileSortKey.new).toList(growable: false);
  keys.sort((left, right) {
    final comparison = _compareFileKeys(left, right, field);
    return ascending ? comparison : -comparison;
  });
  for (var index = 0; index < keys.length; index++) {
    files[index] = keys[index].file;
  }
}

class _FileSortKey {
  _FileSortKey(this.file);

  final FileEntity file;
  late final _NaturalKey baseName =
      _NaturalKey.of(p.basenameWithoutExtension(file.name));
  late final _NaturalKey extension = _NaturalKey.of(p.extension(file.name));
  late final _NaturalKey fullName = _NaturalKey.of(file.name);
}

int _compareFileKeys(
  _FileSortKey left,
  _FileSortKey right,
  FileSortField field,
) {
  final comparison = switch (field) {
    FileSortField.name => _compareNaturalKeys(left.baseName, right.baseName),
    FileSortField.type => _compareNaturalKeys(left.extension, right.extension),
    FileSortField.size =>
      _metadataValue(left.file, right.file, (metadata) => metadata.size),
    FileSortField.date => _metadataValue(
        left.file,
        right.file,
        (metadata) => metadata.modified?.millisecondsSinceEpoch,
      ),
  };

  if (comparison != 0) {
    return comparison;
  }

  return _compareNaturalKeys(left.fullName, right.fullName);
}

int _metadataValue(
  FileEntity left,
  FileEntity right,
  int? Function(FileSortMetadata metadata) value,
) {
  final leftMetadata = left.sortMetadata;
  final rightMetadata = right.sortMetadata;
  if (leftMetadata == null || rightMetadata == null) return 0;

  final leftValue = value(leftMetadata);
  final rightValue = value(rightMetadata);
  if (leftValue == null || rightValue == null) return 0;
  return leftValue.compareTo(rightValue);
}
