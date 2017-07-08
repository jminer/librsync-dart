const charOffset = 31;

class RollingChecksum {
  int a;
  int b;
  int _count;

  RollingChecksum()
      : a = 0,
        b = 0,
        _count = 0 {}

  int get count => _count;

  reset() {
    a = 0;
    b = 0;
    _count = 0;
  }

  add(int inByte) {
    a += inByte + charOffset;
    a &= 0xFFFF;
    b += a;
    b &= 0xFFFF;
    ++_count;
  }

  addAll(List<int> bytes, int start, int end) {
    // slower implementation
    //bytes.forEach((inByte) { add(inByte); });

    for(var i = start; i < end; ++i) {
      a += bytes[i];
      a &= 0xFFFF;
      b += a;
      b &= 0xFFFF;
    }
    int inCount = end - start;
    a += charOffset * inCount;
    a &= 0xFFFF;
    b += charOffset * (inCount * (inCount + 1) ~/ 2);
    b &= 0xFFFF;
    _count += inCount;
  }

  remove(int outByte) {
    a -= outByte + charOffset;
    a &= 0xFFFF;
    b -= _count * (outByte + charOffset);
    b &= 0xFFFF;
    --_count;
  }

  rotate(int inByte, int outByte) {
    a += inByte - outByte;
    a &= 0xFFFF;
    b += a - _count * (outByte + charOffset);
    b &= 0xFFFF;
  }

  get() {
    return (b << 16) | a;
  }
}
