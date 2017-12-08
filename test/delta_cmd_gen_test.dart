
import "package:convert/convert.dart" as convert;
import "package:test/test.dart";

import "../lib/src/delta_generator.dart";

final everyTwoRegex = new RegExp(r".{2}");
String hexEncode(List<int> input) {
  return convert.hex.encode(input).replaceAllMapped(everyTwoRegex, (match) => match.group(0) + " ");
}

main() {
  test("Delta command generator simple", () async {
    // Has a literal at the beginning and end.
    final cmdGenerator = new DeltaCommandGenerator(30);
    cmdGenerator.addLiteralData([0x3D, 0xF8, 0x23], 1, 2);
    cmdGenerator.recordMatchedBlock(3);
    cmdGenerator.addLiteralData([0x3D, 0xF8, 0x23], 0, 2);
    cmdGenerator.finish();

    final sigStr = hexEncode(cmdGenerator.outputBuffer);
    expect(sigStr, equals(hexEncode([
      0x72, 0x73, 0x02, 0x36, // header
      0x01, 0xF8, // literal cmd
      0x45, 0x5A, 0x1E, // copy cmd for block 3
      0x02, 0x3D, 0xF8, // literal cmd
      0x00, // end of file
    ])));
  });

  test("Delta command generator", () async {
    // Has a record at the beginning and end and tests coalescing matched blocks
    final cmdGenerator = new DeltaCommandGenerator(2000);
    cmdGenerator.recordMatchedBlock(3);
    cmdGenerator.addLiteralData([0x04, 0xF3, 0x83, 0x14], 2, 3);
    cmdGenerator.addLiteralData([0x3D, 0xF8, 0x23], 0, 3);
    cmdGenerator.recordMatchedBlock(4);
    cmdGenerator.recordMatchedBlock(5);
    cmdGenerator.recordMatchedBlock(6);
    cmdGenerator.recordMatchedBlock(42);
    cmdGenerator.recordMatchedBlock(1);
    cmdGenerator.finish();

    final sigStr = hexEncode(cmdGenerator.outputBuffer);
    expect(sigStr, equals(hexEncode([
      0x72, 0x73, 0x02, 0x36, // header
      0x4A, 0x17, 0x70, 0x07, 0xD0, // copy cmd for block 3
      0x04, 0x83, 0x3D, 0xF8, 0x23, // literal cmd
      0x4A, 0x1F, 0x40, 0x17, 0x70, // copy cmd for blocks 4, 5, 6
      0x4E, 0x00, 0x01, 0x48, 0x20, 0x07, 0xD0, // copy cmd for block 42
      0x4A, 0x07, 0xD0, 0x07, 0xD0, // copy cmd for block 1
      0x00, // end of file
    ])));
  });
}
