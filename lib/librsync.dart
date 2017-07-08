import "dart:async";
import "dart:typed_data";
import "dart:math" as math;

import 'rolling_checksum.dart';

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


// By default, the strong sum is not truncated. `strongSumLength` can be set to truncate the strong
// sum.
Stream<List<int>> calculateSignature(Stream<List<int>> oldFile,
    {int blockSize = 2048, int strongSumSize = null}) async* {
  strongSumSize ??= blake2SumSize;

  if(blockSize < 1)
    throw new ArgumentError.value("blockSize");
  if(strongSumSize < 1 || strongSumSize > blake2SumSize)
    throw new ArgumentError.value("strongSumSize");

  var headerList = new Uint8List(4 * 3);
  var headerData = headerList.buffer.asByteData();
  headerData.setUint32(0, sigMagicBlake2);
  headerData.setUint32(4, blockSize);
  headerData.setUint32(8, strongSumSize);
  yield headerList;

  var signatureList = new Uint8List(4 + strongSumSize);
  var signatureData = signatureList.buffer.asByteData();
  var rollingChecksum = new RollingChecksum();
  await for(var bytes in oldFile) {
    for(int i = 0; i < bytes.length; ) {
      var toAdd = math.min(blockSize - rollingChecksum.count, bytes.length - i);
      rollingChecksum.addAll(bytes, i, i + toAdd);
      if(rollingChecksum.count == blockSize) {
        signatureData.setUint32(0, rollingChecksum.get());
        // Blake2Digest.doFinal(signatureList, 4);
        yield signatureList;
        rollingChecksum.reset();
      }
      i += toAdd;
    }
  }
  if(rollingChecksum.count != 0) {
      signatureData.setUint32(0, rollingChecksum.get());
      // Blake2Digest.doFinal(signatureList, 4);
      yield signatureList;
  }
}

Stream<List<int>> calculateDelta(Stream<List<int>> newFile, Stream<List<int>> sigFile) {
//
}

Stream<List<int>> applyDelta(Stream<List<int>> oldFile, Stream<List<int>> deltaFile) {
//
}
