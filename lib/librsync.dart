import "dart:async";
import "dart:typed_data";
import "dart:math" as math;

import 'package:pointycastle/digests/blake2b.dart';

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

Stream<List<int>> applyDelta(Stream<List<int>> oldFile, Stream<List<int>> deltaFile) async* {
//
}
