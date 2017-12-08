import "../librsync.dart";
import "dart:async";
import "dart:collection";
import "dart:typed_data";

import "dart:math" as math;

class BlockInfo {
  Uint8List strongSum;
  int blockIndex;

  BlockInfo(this.strongSum, this.blockIndex);
}

enum ParseState {
  Header,
  Signatures,
}

class SignatureLookup {
  HashMap<int, List<BlockInfo>> _blockInfo;
  int blockSize;
  int strongSumSize;

  static const headerSize = 12;
  // Supporting a maximum of a 512-bit hash
  static const maxEntrySize = 4 + 64;

  SignatureLookup() : _blockInfo = new HashMap() {}

  static Future<SignatureLookup> load(Stream<List<int>> file) async {
    final sig = new SignatureLookup();
    final fileBuffer = new Uint8List(math.max(headerSize, maxEntrySize));
    var fileBufferFilled = 0;
    final fileData = fileBuffer.buffer.asByteData();
    var state = ParseState.Header;
    var entrySize = null;
    var blockIndex = 0;
    await for(var bytes in file) {
      for(var i = 0; i < bytes.length; ) {
        final toAdd = math.min(bytes.length - i, fileBuffer.length - fileBufferFilled);
        fileBuffer.setRange(fileBufferFilled, fileBufferFilled + toAdd, bytes, i);
        fileBufferFilled += toAdd;
        i += toAdd;

        while(true) {
          var madeProgress = false;
          if(state == ParseState.Header) {
            if(fileBufferFilled >= headerSize) {
              final magic = fileData.getUint32(0);
              if(magic != sigMagicBlake2) {
                throw new FormatException(
                    "unsupported signature format: 0x${magic.toRadixString(16)}");
              }
              sig.blockSize = fileData.getUint32(4);
              sig.strongSumSize = fileData.getUint32(8);
              entrySize = 4 + sig.strongSumSize; // 4 for rolling checksum

              fileBuffer.setRange(0, fileBufferFilled - headerSize, fileBuffer, headerSize);
              fileBufferFilled -= headerSize;
              state = ParseState.Signatures;
              madeProgress = true;
            }
          } else if(state == ParseState.Signatures) {
            if(fileBufferFilled >= entrySize) {
              final weakSum = fileData.getUint32(0);
              final strongSum =
                  new Uint8List.fromList(fileBuffer.sublist(4, 4 + sig.strongSumSize));

              final blockInfo = new BlockInfo(strongSum, blockIndex);
              final blocks = sig._blockInfo[weakSum];
              if(blocks == null) {
                sig._blockInfo[weakSum] = [blockInfo];
              } else {
                blocks.add(blockInfo);
              }
              ++blockIndex;

              fileBuffer.setRange(0, fileBufferFilled - entrySize, fileBuffer, entrySize);
              fileBufferFilled -= entrySize;
              madeProgress = true;
            }
          }
          if(!madeProgress)
            break;
        }
      }
    }
    return sig;
  }

  List<BlockInfo> getBlocks(int rollingChecksum) {
    return _blockInfo[rollingChecksum];
  }
}
