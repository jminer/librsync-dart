import "dart:async";
import "dart:io";

import "package:args/args.dart";

import "package:librsync/librsync.dart" as librsync;

main(List<String> args) async {
  var parser = new ArgParser(allowTrailingOptions: true);

  var sigCommand = new ArgParser(allowTrailingOptions: true);
  parser.addCommand("signature", sigCommand);
  sigCommand.addOption("block-size", abbr: "b", valueHelp: "BLOCK_SIZE", help: "The bytes per block");
  sigCommand.addOption("sum-size", abbr: "S", valueHelp: "SUM_SIZE", help: "Set to smaller than the strong sum size (32 for Blake2) to truncate it");

  var deltaCommand = new ArgParser(allowTrailingOptions: true);
  deltaCommand = parser.addCommand("delta");
  var patchCommand = new ArgParser(allowTrailingOptions: true);
  patchCommand = parser.addCommand("patch");

  if(args.isEmpty) {
    print("");
    print("rdiff.dart signature [options] <OLD_FILE> <SIGNATURE_FILE>");
    print("");
    print(sigCommand.usage);
    print("");
    print("rdiff.dart delta <SIGNATURE_FILE> <NEW_FILE> <DELTA_FILE>");
    print("");
    //print(deltaCommand.usage);
    //print("");
    print("rdiff.dart patch <OLD_FILE> <DELTA_FILE> <NEW_FILE>");
    print("");
    //print(patchCommand.usage);
    //print("");
    exit(0);
  }

  var results = parser.parse(args);
  if(results.command == null) {
    print("No command given");
    exit(1);
  }
  if(results.command.name == "signature") {
    var rest = results.command.rest;
    if(rest.length < 2 || rest.length > 2) { // TODO: allow only 1 arg and gen name of sigFile
      print("Wrong number of arguments");
      exit(1);
    }
    var oldFile = rest[0];
    var sigFile = rest[1];
    await librsync.calculateSignature(new File(oldFile).openRead()).pipe(new File(sigFile).openWrite());
  } else if(results.command.name == "delta") {
    var rest = results.command.rest;

  } else if(results.command.name == "patch") {
    var rest = results.command.rest;

  }
}
