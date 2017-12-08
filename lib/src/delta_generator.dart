
import "dart:math" as math;
import "dart:typed_data";

import "package:pointycastle/digests/blake2b.dart";
import "package:typed_data/typed_buffers.dart";

import "../librsync.dart";
import "../rolling_checksum.dart";
import "signature_lookup.dart";

// Following the format documented at
// https://github.com/braddodson/librsync.net/blob/master/deltaformat.md

class DeltaCommandGenerator {
  int _blockSize;

  int _matchedBlockStart = -1;
  int _matchedBlockCount = 0;
  Uint8Buffer _literalBuffer;

  Uint8Buffer outputBuffer;

  DeltaCommandGenerator(this._blockSize) {
    _literalBuffer = new Uint8Buffer();
    outputBuffer = new Uint8Buffer();
    _addUintBigEndian(deltaMagic, 2, outputBuffer); // header
  }

  Uint8Buffer takeOutputBuffer() {
    final buffer = outputBuffer;
    outputBuffer = new Uint8Buffer();
    return buffer;
  }

  // `blockIndex` is the index of the block in the old file that matched the current location
  // in the new file.
  recordMatchedBlock(int blockIndex) {
    if(_literalBuffer.isNotEmpty) {
      _writeLiteralCommand();
    }
    if(_matchedBlockStart + _matchedBlockCount == blockIndex) {
      ++_matchedBlockCount;
    } else {
      if(_matchedBlockStart != -1) {
        _writeCopyCommand();
      }
      _matchedBlockStart = blockIndex;
      _matchedBlockCount = 1;
    }
  }

  addLiteralData(List<int> literalData, int start, int end) {
    if(_matchedBlockStart != -1) {
      _writeCopyCommand();
    }
    _literalBuffer.addAll(literalData, start, end);
  }

  finish() {
    if(_literalBuffer.isNotEmpty) {
      _writeLiteralCommand();
    } else if(_matchedBlockStart != -1) {
      _writeCopyCommand();
    }
    outputBuffer.add(0);
  }

  _writeLiteralCommand() {
    _addLiteralCommand(_literalBuffer, outputBuffer);
    _literalBuffer.clear();
  }

  _writeCopyCommand() {
    _addCopyCommand(_matchedBlockStart * _blockSize, _matchedBlockCount * _blockSize, outputBuffer);
    _matchedBlockStart = -1;
    _matchedBlockCount = 0;
  }

  static _addLiteralCommand(Uint8Buffer buffer, Uint8Buffer outputBuffer) {
    var lenSizeClass = _getUintSizeClass(buffer.length);
    if(buffer.length <= 64){
      outputBuffer.add(buffer.length);
    } else {
      outputBuffer.add(65 + lenSizeClass);
      _addUintBigEndian(buffer.length, lenSizeClass, outputBuffer);
    }
    outputBuffer.addAll(buffer);
  }

  static _addCopyCommand(int start, int length, Uint8Buffer outputBuffer) {
    var startSizeClass = _getUintSizeClass(start);
    var lenSizeClass = _getUintSizeClass(length);
    outputBuffer.add(69 + startSizeClass * 4 + lenSizeClass);
    _addUintBigEndian(start, startSizeClass, outputBuffer);
    _addUintBigEndian(length, lenSizeClass, outputBuffer);
  }

  // Returns the number of bytes needed to store the specified unsigned integer.
  static int _getUintSizeClass(int n) {
    if(n <= 0xFF) {
      return 0;
    } else if(n <= 0xFFFF) {
      return 1;
    } else if(n <= 0xFFFFFFFF) {
      return 2;
    } else if(n <= 0xFFFFFFFFFFFFFFFF) {
      return 3;
    }
    assert(false);
    return 1;
  }

  static _addUintBigEndian(int n, int sizeClass, Uint8Buffer buffer) {
    if(sizeClass >= 3) {
      buffer.add(n >> 56);
      buffer.add(n >> 48);
      buffer.add(n >> 40);
      buffer.add(n >> 32);
    }
    if(sizeClass >= 2) {
      buffer.add(n >> 24);
      buffer.add(n >> 16);
    }
    if(sizeClass >= 1) {
      buffer.add(n >> 8);
    }
    buffer.add(n);
  }
}

class DeltaGenerator {
  SignatureLookup _sig;
  Uint8Buffer _buffer;
  int _blockSize;
  int _processedCount = 0;
  RollingChecksum _rollingChecksum;
  DeltaCommandGenerator _cmdGenerator;

  Blake2bDigest _hasher;
  Uint8List _hash;

  DeltaGenerator(this._sig, this._blockSize) {
    _buffer = new Uint8Buffer();
    _rollingChecksum = new RollingChecksum();
    _cmdGenerator = new DeltaCommandGenerator(_blockSize);

    // Setting the Blake2b digest size changes the hash, so it has to be 32 for compatibility
    // with librsync.
    _hasher = new Blake2bDigest(digestSize: 32);
    _hash = new Uint8List(_hasher.digestSize);
  }

  Uint8Buffer get buffer => _buffer;

  Uint8Buffer processBuffer(bool finish) {
    assert(finish || _buffer.length > _blockSize);
    if(_buffer.length < _blockSize) {
      // There is no point checking for any matched blocks because the total size is less than
      // the size of one block.
      _cmdGenerator.addLiteralData(_buffer, 0, _buffer.length);
      _cmdGenerator.finish();
      return _cmdGenerator.takeOutputBuffer();
    }

    // There are two cases where processedCount is less than blockSize. One is the first time the
    // buffer is processed and the other is if a match was found within a block size of the end of
    // the buffer.
    _rollingChecksum.addAll(_buffer, _processedCount, _blockSize);
    var i = _blockSize;
    var literalStart = 0;

    final bufferList = _buffer.buffer.asUint8List();
    while(true) {
      final matchingBlocks = _sig.getBlocks(_rollingChecksum.get());
      var matchingBlock = null;
      if(matchingBlocks != null && matchingBlocks.isNotEmpty) {
        _hasher.update(bufferList, i - _blockSize, _blockSize);
        _hasher.doFinal(_hash, 0);
        matchingBlock = matchingBlocks.firstWhere(
            (block) => _hashesEqual(block.strongSum, _hash),
            orElse: () => null);
      }

      if(matchingBlock != null) {
        _cmdGenerator.addLiteralData(_buffer, literalStart, i - _blockSize);
        _cmdGenerator.recordMatchedBlock(matchingBlock.blockIndex);
        literalStart = i;

        _rollingChecksum.reset();
        _rollingChecksum.addAll(_buffer, i, math.min(i + _blockSize, _buffer.length));
        i += _blockSize;
        if(i > _buffer.length)
          break;
      } else {
        if(i >= _buffer.length)
          break;
        _rollingChecksum.rotate(_buffer[i], _buffer[i - _blockSize]);
        ++i;
      }
    }
    _cmdGenerator.addLiteralData(_buffer, literalStart, i - _blockSize);

    // Remove data that has been processed.
    _buffer.removeRange(0, i - _blockSize);
    _processedCount = _buffer.length;

    if(finish) {
      _cmdGenerator.addLiteralData(_buffer, 0, _buffer.length);
      _cmdGenerator.finish();
    }
    return _cmdGenerator.takeOutputBuffer();
  }

  bool _hashesEqual(Uint8List refHash, Uint8List calcHash) {
    for(int i = 0; i < refHash.length; ++i)
      if(refHash[i] != calcHash[i])
        return false;
    return true;
  }

}
