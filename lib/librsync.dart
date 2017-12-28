import "dart:async";
import "dart:io";
import "dart:typed_data";
import "dart:math" as math;

import 'package:pointycastle/digests/blake2b.dart';
import "package:typed_data/typed_buffers.dart";

import "rolling_checksum.dart";
import "src/delta_generator.dart";
import "src/signature_lookup.dart";

// librsync's default block size is 2048.

const sigMagicMD4 = 0x72730136;
const sigMagicBlake2 = 0x72730137;
const deltaMagic = 0x72730236;

const md4SumSize = 16;
const blake2SumSize = 32;

// I probably should truncate the strong hash to 128 bits. Even 128 bits is overkill. I don't know
// why they used 256. If you had a 2 GB file (using 2KB blocks) containing 1,000,000 blocks and you
// synced 1 billion such files, there is a 99.999999999999999+% chance that there would never be a
// collision.
// 1 - e^(-1000000^2/(2*2^128)) = 1.47 * 10^-27
// (1.47 * 10^-27) ^ 1000000000 = 99.999999+%


// By default, the strong sum is not truncated. `strongSumSize` can be set to truncate the strong
// sum.
Stream<List<int>> calculateSignature(Stream<List<int>> oldFile,
    {int blockSize = 2048, int strongSumSize = null}) async* {
  strongSumSize ??= blake2SumSize;

  if(blockSize < 1)
    throw new ArgumentError.value("blockSize");
  if(strongSumSize < 1 || strongSumSize > blake2SumSize)
    throw new ArgumentError.value("strongSumSize");

  final headerList = new Uint8List(4 * 3);
  final headerData = headerList.buffer.asByteData();
  headerData.setUint32(0, sigMagicBlake2);
  headerData.setUint32(4, blockSize);
  headerData.setUint32(8, strongSumSize);
  yield headerList;

  final signatureList = new Uint8List(4 + strongSumSize);
  final signatureData = signatureList.buffer.asByteData();
  final rollingChecksum = new RollingChecksum();
  // Setting the Blake2b digest size changes the hash, so it has to be 32 for compatibility with
  // librsync.
  final hasher = new Blake2bDigest(digestSize: 32);
  final hash = new Uint8List(hasher.digestSize);
  await for(var bytes in oldFile) {
    for(int i = 0; i < bytes.length; ) {
      final toAdd = math.min(blockSize - rollingChecksum.count, bytes.length - i);
      rollingChecksum.addAll(bytes, i, i + toAdd);
      hasher.update(bytes, i, toAdd);
      if(rollingChecksum.count == blockSize) {
        signatureData.setUint32(0, rollingChecksum.get());
        hasher.doFinal(hash, 0);
        signatureList.setRange(4, 4 + strongSumSize, hash);
        yield new Uint8List.fromList(signatureList);
        rollingChecksum.reset();
        //hasher.reset(); // doFinal does this
      }
      i += toAdd;
    }
  }
  if(rollingChecksum.count != 0) {
      signatureData.setUint32(0, rollingChecksum.get());
      hasher.doFinal(hash, 0);
      signatureList.setRange(4, 4 + strongSumSize, hash);
      yield signatureList;
  }
}

// `bufferBlockCount` is the size of the buffer that is processed at once, in multiples of the
// block size. It usually does not need changed.
Stream<List<int>> calculateDelta(Stream<List<int>> newFile, Stream<List<int>> sigFile,
    [int bufferBlockCount = 10]) async* {
  if(bufferBlockCount < 2)
    throw new ArgumentError.value(bufferBlockCount, "bufferBlockCount"); // TODO: try
  final sig = await SignatureLookup.load(sigFile);
  final maxBufferSize = sig.blockSize * bufferBlockCount;
  final gen = new DeltaGenerator(sig, sig.blockSize);
  await for(var chunk in newFile) {
      for(var chunkIndex = 0; chunkIndex < chunk.length; ) {
        final toCopy = math.min(maxBufferSize - gen.buffer.length, chunk.length - chunkIndex);
        gen.buffer.addAll(chunk, chunkIndex, chunkIndex + toCopy);
        chunkIndex += toCopy;
        if(gen.buffer.length == maxBufferSize)
          yield gen.processBuffer(false);
      }
  }
  yield gen.processBuffer(true);
}

//_calculateDelta() that doesn't add header or EOF.
//calculateDelta() calls _calculateDelta() and adds header and EOF.
//calculateDeltaInIsolates() calls _calculateDelta() in isolates.
//Maybe calculate 500 block sizes of the file on each isolate. (Take like 2000 block size bytes and split among 4 isolates. When those are done, take 2000 more and split among the isolates.)

typedef Stream<List<int>> SeekStreamFunction(int start, int end);

abstract class SeekStreamFactory {
  Stream<List<int>> create(int start, int end);
}

class FunctionSeekStreamFactory implements SeekStreamFactory {
  SeekStreamFunction _fn;
  FunctionSeekStreamFactory(SeekStreamFunction this._fn);
  Stream<List<int>> create(int start, int end) {
    return _fn(start, end);
  }
}

class FileSeekStreamFactory implements SeekStreamFactory {
  File _file;
  FileSeekStreamFactory(String path) {
    _file = new File(path);
  }
  Stream<List<int>> create(int start, int end) {
    return _file.openRead(start, end);
  }
}

class ListSeekStreamFactory implements SeekStreamFactory {
  List<int> _list;
  ListSeekStreamFactory(List<int> this._list);
  Stream<List<int>> create(int start, int end) async* {
    yield _list.sublist(start, end);
  }
}

const _sizes = const [1, 2, 4, 8];

const _headerSize = 4;

enum _ParseState {
  Header,
  Commands,
}

/// Will throw `FormatException` if the header is not recognized (indicating the format is
/// different), if file contains an unsupported command, or if the file is truncated (either due to
/// an EOF marker or the actual end of file)
Stream<List<int>> applyDelta(SeekStreamFactory oldFile, Stream<List<int>> deltaFile) async* {
  final fileBuffer = new Uint8List(256);
  var fileBufferStart = 0;
  var fileBufferEnd = 0;
  final fileData = fileBuffer.buffer.asByteData();
  var state = _ParseState.Header;
  var literalCount = 0;
  var eofFound = false;

  final readUint = (int size) {
    assert(fileBufferEnd - fileBufferStart >= size);
    var n;
    if(size == 1) {
      n = fileData.getUint8(fileBufferStart);
    } else if(size == 2) {
      n = fileData.getUint16(fileBufferStart);
    } else if(size == 4) {
      n = fileData.getUint32(fileBufferStart);
    } else if(size == 8) {
      n = fileData.getUint64(fileBufferStart);
    } else {
      assert(false, "invalid size");
    }
    fileBufferStart += size;
    return n;
  };

  readLoop:
  await for(var chunk in deltaFile) {
    for(var chunkIndex = 0; chunkIndex < chunk.length; ) {
      final toAdd = math.min(chunk.length - chunkIndex, fileBuffer.length - fileBufferEnd);
      fileBuffer.setRange(fileBufferEnd, fileBufferEnd + toAdd, chunk, chunkIndex);
      fileBufferEnd += toAdd;
      chunkIndex += toAdd;

      while(true) {
        var madeProgress = false;
        if(state == _ParseState.Header) {
          if(fileBufferEnd - fileBufferStart >= _headerSize) {
            final magic = fileData.getUint32(0);
            if(magic != deltaMagic) {
              throw new FormatException(
                  "unsupported delta format: 0x${magic.toRadixString(16)}");
            }
            fileBufferStart += _headerSize;
            state = _ParseState.Commands;
            madeProgress = true;
          }
        } else if(state == _ParseState.Commands) {
          if(literalCount > 0) {
            final toYield = math.min(literalCount, fileBufferEnd - fileBufferStart);
            yield fileBuffer.sublist(fileBufferStart, fileBufferStart + toYield);
            fileBufferStart += toYield;
            literalCount -= toYield;
            madeProgress = true;
          } else if(fileBufferEnd - fileBufferStart >= 1) {
            final cmd = fileBuffer[fileBufferStart];
            final eatCmd = () {
              ++fileBufferStart;
              madeProgress = true;
            };
            if(cmd == 0) { // end of file
              eatCmd();
              eofFound = true;
              break readLoop;
            } else if(cmd >= 1 && cmd <= 64) { // literal
              eatCmd();
              literalCount = cmd;
            } else if(cmd >= 65 && cmd <= 68) { // literal
              final lenSize = _sizes[cmd - 65];
              if(fileBufferEnd - fileBufferStart >= lenSize) {
                eatCmd();
                literalCount = readUint(lenSize);
              }
            } else if(cmd >= 69 && cmd <= 84) { // copy
              final cmdOffset = cmd - 69;
              final startSize = _sizes[cmdOffset ~/ 4];
              final lenSize = _sizes[cmdOffset % 4];
              if(fileBufferEnd - fileBufferStart >= startSize + lenSize) {
                eatCmd();
                final copyStart = readUint(_sizes[cmdOffset ~/ 4]);
                final copyLen = readUint(_sizes[cmdOffset % 4]);
                yield await oldFile.create(copyStart, copyStart + copyLen)
                    .fold(new Uint8Buffer(), (acc, chunk) => acc..addAll(chunk));
              }
            } else {
              throw new FormatException("unsupported command");
            }
          }
        }
        if(!madeProgress)
          break;
      }
    }
  }
  if(!eofFound)
    throw new FormatException("truncated file (no EOF found)");
  if(literalCount > 0)
    throw new FormatException("truncated file inside literal");
  if(fileBufferEnd - fileBufferStart > 0)
    throw new FormatException("truncated file inside command");
}
