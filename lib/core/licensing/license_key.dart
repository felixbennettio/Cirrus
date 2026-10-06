/// Licence keys: `CIRRUS-XXXXX-XXXXX-XXXXX-XXXXX`, 20 characters from the
/// Crockford base32 alphabet (`docs/licensing.md`).
library;

const licenseKeyPrefix = 'CIRRUS';
const crockfordAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// The canonical form of a typed or pasted key, or null when it cannot be
/// a licence key. Normalises like the server: whitespace anywhere removed,
/// upper-case, `O`→`0` and `I`/`L`→`1`, with the dashes and the `CIRRUS`
/// prefix optional.
String? normalizeLicenseKey(String input) {
  var s = input.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  // Before the mapping below, which would turn the prefix into "C1RRUS".
  if (s.startsWith(licenseKeyPrefix)) s = s.substring(licenseKeyPrefix.length);
  s = s.replaceAll('O', '0').replaceAll(RegExp('[IL]'), '1');
  if (s.length != 20 || !s.split('').every(crockfordAlphabet.contains)) return null;
  return [licenseKeyPrefix, for (var i = 0; i < 20; i += 5) s.substring(i, i + 5)].join('-');
}

/// A canonical key with all but its last group hidden, for display:
/// `CIRRUS-XXXXX-…-ABCDE`.
String maskLicenseKey(String key) {
  final last = key.length >= 5 ? key.substring(key.length - 5) : key;
  return '$licenseKeyPrefix-XXXXX-…-$last';
}
