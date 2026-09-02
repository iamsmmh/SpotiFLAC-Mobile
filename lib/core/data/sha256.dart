/// Pure-Dart streaming SHA-256 (FIPS 180-4).
///
/// The core deliberately avoids adding the `crypto` package to pubspec:
/// this implementation is small, strictly-typed, and covered by the standard
/// NIST test vectors plus chunked-streaming equivalence checks. It exists to
/// serve the transactional finalize gate (content integrity verification)
/// without new third-party dependencies.
library;

const int _mask32 = 0xFFFFFFFF;

/// First 32 bits of the fractional parts of the square roots of the first 8
/// primes — the SHA-256 initial hash value.
const List<int> _initialState = <int>[
  0x6a09e667,
  0xbb67ae85,
  0x3c6ef372,
  0xa54ff53a,
  0x510e527f,
  0x9b05688c,
  0x1f83d9ab,
  0x5be0cd19,
];

/// Round constants: first 32 bits of the fractional parts of the cube roots
/// of the first 64 primes.
const List<int> _roundConstants = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotR(int value, int shift) {
  final v = value & _mask32;
  return ((v >> shift) | (v << (32 - shift))) & _mask32;
}

/// Incremental SHA-256 hasher. Feed bytes with [add], finish with [digestHex]
/// or [digestBytes]. An accumulator is single-shot: [digestBytes] seals it.
class Sha256Accumulator {
  final List<int> _state = List<int>.of(_initialState);
  final List<int> _buffer = <int>[];
  int _totalLength = 0; // Byte length overall.
  bool _sealed = false;

  final List<int> _w = List<int>.filled(64, 0);

  bool get isSealed => _sealed;

  /// Number of bytes fed so far.
  int get length => _totalLength;

  void add(List<int> bytes) {
    if (_sealed) {
      throw StateError('SHA-256 accumulator already sealed');
    }
    _totalLength += bytes.length;
    for (final byte in bytes) {
      _buffer.add(byte & 0xFF);
      if (_buffer.length == 64) {
        _compress(_buffer);
        _buffer.clear();
      }
    }
  }

  /// Final digest as 32 bytes; seals the accumulator.
  List<int> digestBytes() {
    if (_sealed) {
      throw StateError('SHA-256 accumulator already sealed');
    }
    _sealed = true;

    final bitLength = _totalLength * 8;
    _buffer.add(0x80);
    if (_buffer.length == 64) {
      _compress(_buffer);
      _buffer.clear();
    }
    while (_buffer.length != 56) {
      _buffer.add(0);
      if (_buffer.length == 64) {
        _compress(_buffer);
        _buffer.clear();
      }
    }
    // 64-bit big-endian byte length (high 32 bits are zero for any artifact
    // this pipeline will ever see; still emitted for spec compliance).
    for (var shift = 56; shift >= 0; shift -= 8) {
      final byte = (bitLength ~/ (1 << shift)) & 0xFF;
      _buffer.add(byte);
    }
    _compress(_buffer);

    final digest = <int>[];
    for (final word in _state) {
      digest.add((word >> 24) & 0xFF);
      digest.add((word >> 16) & 0xFF);
      digest.add((word >> 8) & 0xFF);
      digest.add(word & 0xFF);
    }
    return digest;
  }

  /// Final digest as lowercase hex; seals the accumulator.
  String digestHex() {
    final bytes = digestBytes();
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  void _compress(List<int> block) {
    final w = _w;
    for (var i = 0; i < 16; i++) {
      w[i] =
          ((block[i * 4] << 24) |
              (block[i * 4 + 1] << 16) |
              (block[i * 4 + 2] << 8) |
              block[i * 4 + 3]) &
          _mask32;
    }
    for (var i = 16; i < 64; i++) {
      final w15 = w[i - 15];
      final w2 = w[i - 2];
      final s0 = _rotR(w15, 7) ^ _rotR(w15, 18) ^ (w15 >> 3);
      final s1 = _rotR(w2, 17) ^ _rotR(w2, 19) ^ (w2 >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask32;
    }

    var a = _state[0];
    var b = _state[1];
    var c = _state[2];
    var d = _state[3];
    var e = _state[4];
    var f = _state[5];
    var g = _state[6];
    var h = _state[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotR(e, 6) ^ _rotR(e, 11) ^ _rotR(e, 25);
      final ch = (e & f) ^ ((~e & _mask32) & g);
      final temp1 =
          (h + s1 + ch + _roundConstants[i] + w[i]) & _mask32;
      final s0 = _rotR(a, 2) ^ _rotR(a, 13) ^ _rotR(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & _mask32;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & _mask32;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & _mask32;
    }

    _state[0] = (_state[0] + a) & _mask32;
    _state[1] = (_state[1] + b) & _mask32;
    _state[2] = (_state[2] + c) & _mask32;
    _state[3] = (_state[3] + d) & _mask32;
    _state[4] = (_state[4] + e) & _mask32;
    _state[5] = (_state[5] + f) & _mask32;
    _state[6] = (_state[6] + g) & _mask32;
    _state[7] = (_state[7] + h) & _mask32;
  }
}

/// One-shot convenience: lowercase SHA-256 hex of [bytes].
String sha256Hex(List<int> bytes) {
  final accumulator = Sha256Accumulator()..add(bytes);
  return accumulator.digestHex();
}
