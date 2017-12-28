
import 'dart:async';
import 'dart:typed_data';

import "package:librsync/librsync.dart";

import 'package:convert/convert.dart' as convert;
import "package:test/test.dart";
import 'package:typed_data/typed_buffers.dart';

final everyTwoRegex = new RegExp(r".{2}");
String hexEncode(List<int> input) {
  return convert.hex.encode(input).replaceAllMapped(everyTwoRegex, (match) => match.group(0) + " ");
}

main() {
  test("Small delta", () async {
    final oldFile = new Uint8List(8);
    oldFile.setAll(0, [
      // "car ice "
      0x63, 0x61, 0x72, 0x20, 0x69, 0x63, 0x65, 0x20
    ]);
    final newFile = new Uint8List(25);
    newFile.setAll(0, [
      // "mug nice jog car try lip "
      0x6D, 0x75, 0x67, 0x20,
      0x6E, 0x69, 0x63, 0x65, 0x20, // "nice "
      0x6A, 0x6F, 0x67, 0x20, // "jog "
      0x63, 0x61, 0x72, 0x20,
      0x74, 0x72, 0x79, 0x20, // "try "
      0x6C, 0x69, 0x70, 0x20
    ]);
    final sig = await calculateSignature((() async* { yield oldFile; })(),
        blockSize: 4, strongSumSize: 8)
        .fold(new Uint8Buffer(), (acc, chunk) => acc..addAll(chunk));
    //print("signature: ${hexEncode(sig)}");
    final delta =
        await calculateDelta((() async* { yield newFile; })(), (() async* { yield sig; })())
            .fold(new Uint8Buffer(), (acc, chunk) => acc..addAll(chunk));
    final deltaStr = hexEncode(delta);
    // This doesn't quite match what the C librsync produces. librsync doesn't use literal commands
    // 1 to 64 for literal data that length. Instead, it uses command 65 (0x41), which contains the
    // length in the next byte. I'm surprised it doesn't do that simple optimization even though it
    // is allowed by the format.
    expect(deltaStr, equals(hexEncode([
      0x72, 0x73, 0x02, 0x36, // header
      0x05, 0x6D, 0x75, 0x67, 0x20, 0x6E, // literal cmd "mug n"
      0x45, 0x04, 0x04, // copy cmd for block 1 "ice "
      0x04, 0x6A, 0x6F, 0x67, 0x20, // literal cmd "jog "
      0x45, 0x00, 0x04, // copy cmd for block 0 "car "
      0x08, 0x74, 0x72, 0x79, 0x20, 0x6C, 0x69, 0x70, 0x20, // literal cmd "try lip "
      0x00, // end of file
    ])));
  });

  test("Applying delta", () async {
    // This is the same data as the above test.
    final oldFile = new Uint8List(8);
    oldFile.setAll(0, [
      // "car ice "
      0x63, 0x61, 0x72, 0x20, 0x69, 0x63, 0x65, 0x20
    ]);
    final deltaFile = new Uint8List(31);
    deltaFile.setAll(0, [
      0x72, 0x73, 0x02, 0x36, // header
      0x05, 0x6D, 0x75, 0x67, 0x20, 0x6E, // literal cmd "mug n"
      0x45, 0x04, 0x04, // copy cmd for block 1 "ice "
      0x04, 0x6A, 0x6F, 0x67, 0x20, // literal cmd "jog "
      0x45, 0x00, 0x04, // copy cmd for block 0 "car "
      0x08, 0x74, 0x72, 0x79, 0x20, 0x6C, 0x69, 0x70, 0x20, // literal cmd "try lip "
      0x00, // end of file
    ]);

    final newFile =
        await applyDelta(new ListSeekStreamFactory(oldFile), (() async* { yield deltaFile; })())
            .fold(new Uint8Buffer(), (acc, chunk) => acc..addAll(chunk));
    final newFileStr = hexEncode(newFile);
    expect(newFileStr, equals(hexEncode([
      // "mug nice jog car try lip "
      0x6D, 0x75, 0x67, 0x20,
      0x6E, 0x69, 0x63, 0x65, 0x20, // "nice "
      0x6A, 0x6F, 0x67, 0x20, // "jog "
      0x63, 0x61, 0x72, 0x20,
      0x74, 0x72, 0x79, 0x20, // "try "
      0x6C, 0x69, 0x70, 0x20
    ])));
  });
}
