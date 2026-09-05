/// Pure-Dart MD5 (RFC 1321).
///
/// Exists for exactly one caller: Subsonic/Navidrome/Airsonic token
/// authentication (`t = md5(password + salt)`), which the Subsonic API
/// requires in addition to the plain username. As with the core's own
/// SHA-256, implementing the ~120-line digest avoids adding a `crypto`
/// dependency to a verified build. RFC 1321 test vectors cover it in
/// `test/md5_test.dart`; it is never used for security decisions.
library;

import 'dart:math' as math;

const int _mask32 = 0xFFFFFFFF;

int _rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & _mask32;

/// K[i] = floor(abs(sin(i+1)) * 2^32), precomputed at first use.
final List<int> _k = List<int>.generate(64, (i) {
  final value = (math.sin(i + 1).abs() * 4294967296.0).floor();
  return value & _mask32;
});

/// MD5 digest of [input] as 16 bytes.
List<int> md5Bytes(List<int> input) {
  // Per-round shift amounts (RFC 1321 §3.4).
  const shifts = <int>[
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];

  var a0 = 0x67452301;
  var b0 = 0xefcdab89;
  var c0 = 0x98badcfe;
  var d0 = 0x10325476;

  // Message padded to 56 bytes mod 64, then 8-byte little-endian bit length.
  final padded = <int>[...input, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  final bitLength = input.length * 8;
  for (var i = 0; i < 8; i++) {
    padded.add((bitLength >> (8 * i)) & 0xFF);
  }

  for (var chunkStart = 0; chunkStart < padded.length; chunkStart += 64) {
    final m = <int>[
      for (var j = 0; j < 16; j++)
        padded[chunkStart + j * 4] |
            (padded[chunkStart + j * 4 + 1] << 8) |
            (padded[chunkStart + j * 4 + 2] << 16) |
            (padded[chunkStart + j * 4 + 3] << 24),
    ];

    var a = a0;
    var b = b0;
    var c = c0;
    var d = d0;

    for (var i = 0; i < 64; i++) {
      int f;
      int g;
      if (i < 16) {
        f = (b & c) | ((~b & _mask32) & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | ((~d & _mask32) & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | (~d & _mask32));
        g = (7 * i) % 16;
      }
      f = (f + a + _k[i] + m[g]) & _mask32;
      a = d;
      d = c;
      c = b;
      b = (b + _rotl(f, shifts[i])) & _mask32;
    }

    a0 = (a0 + a) & _mask32;
    b0 = (b0 + b) & _mask32;
    c0 = (c0 + c) & _mask32;
    d0 = (d0 + d) & _mask32;
  }

  // Little-endian output words.
  final out = <int>[];
  for (final word in <int>[a0, b0, c0, d0]) {
    out.add(word & 0xFF);
    out.add((word >> 8) & 0xFF);
    out.add((word >> 16) & 0xFF);
    out.add((word >> 24) & 0xFF);
  }
  return out;
}

/// MD5 digest of the UTF-8 bytes of [input] as lowercase hex.
String md5Hex(String input) => _hexOf(md5Bytes(utf8BytesOf(input)));

/// MD5 over raw code units — the Subsonic salt path feeds ASCII/UTF-8
/// passwords and hex salts; UTF-8 encoding matches every client library.
List<int> utf8BytesOf(String input) {
  // Avoid importing dart:convert for one call: encode manually for the
  // code points Subsonic credentials can contain (ASCII + BMP).
  final out = <int>[];
  for (final codeUnit in input.codeUnits) {
    if (codeUnit < 0x80) {
      out.add(codeUnit);
    } else if (codeUnit < 0x800) {
      out.add(0xC0 | (codeUnit >> 6));
      out.add(0x80 | (codeUnit & 0x3F));
    } else {
      out.add(0xE0 | (codeUnit >> 12));
      out.add(0x80 | ((codeUnit >> 6) & 0x3F));
      out.add(0x80 | (codeUnit & 0x3F));
    }
  }
  return out;
}

String _hexOf(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Builds a Subsonic auth pair: the random salt `s` (hex string) and the
/// token `t = md5(password + salt)` per the Subsonic API 1.13.0+ spec.
(String salt, String token) subsonicAuthToken(String password) {
  final random = math.Random.secure();
  final saltBytes = List<int>.generate(6, (_) => random.nextInt(256));
  final salt = _hexOf(saltBytes);
  final token = _hexOf(
    md5Bytes(<int>[...utf8BytesOf(password), ...utf8BytesOf(salt)]),
  );
  return (salt, token);
}
