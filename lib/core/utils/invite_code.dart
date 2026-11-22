/// Client-side helpers for invitation codes. The server
/// (`private.normalize_invite_code`) applies the same normalisation and is
/// the only authority on validity.
abstract final class InviteCode {
  static const length = 16;
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// Uppercases, strips separators and maps look-alike characters
  /// (O→0, I/L→1) exactly like the database does.
  static String normalize(String input) {
    final stripped = input.toUpperCase().replaceAll(RegExp('[^0-9A-Z]'), '');
    return stripped.replaceAll('O', '0').replaceAll('I', '1').replaceAll('L', '1');
  }

  static bool isWellFormed(String input) {
    final n = normalize(input);
    return n.length == length && n.split('').every(_alphabet.contains);
  }

  /// Groups a code for display: ABCD-EFGH-JKMN-PQRS.
  static String format(String input) {
    final n = normalize(input);
    final groups = <String>[];
    for (var i = 0; i < n.length; i += 4) {
      groups.add(n.substring(i, i + 4 > n.length ? n.length : i + 4));
    }
    return groups.join('-');
  }

  /// Extracts a code from pasted text: a full invite link or a bare code.
  static String? extract(String input) {
    final trimmed = input.trim();
    final uri = Uri.tryParse(trimmed);
    final fromLink = uri?.queryParameters['code'];
    if (fromLink != null && isWellFormed(fromLink)) return normalize(fromLink);
    if (isWellFormed(trimmed)) return normalize(trimmed);
    return null;
  }
}
