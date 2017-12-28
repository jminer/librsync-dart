
librsync is a Dart library to calculate differences between two files without having access to both files at the same time. Although it is a rewrite, it should be compatible with the C library of the same name.

It is feature complete and has tests. I have not tested performance, but even if performance is lacking, I'm not sure it can be improved much in Dart.

See the tests or rdiff for example usage.

The C librsync library has [documentation on the signature file format](https://github.com/librsync/librsync/blob/131447aa4b8636c8de576e27bc0736f6a5be9bc2/doc/format.md), and the .NET librsync library has [documentation on the delta file format](https://github.com/braddodson/librsync.net/blob/abcda421a74d769b2be986c0b92a41c12a4f96ce/deltaformat.md).
