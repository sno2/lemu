# lemu

A LEGv8 developer toolkit with the following features:

- LEGv8 Emulator
- Command-Line Debugger
- Language Server (LSP)
- VS Code Extension (snippets, syntax highlighting)

## Usage

```
Lemu: A LEGv8 toolkit.

Usage:
    -h, --help           Display this help and exit.
    -z, --zero-page      Provide a non-standard memory space of 4096 bytes starting from 0x0.
    -l, --limit-errors   Limit to the first 3 compile errors.
    -d, --debug          Enable debugging.
    <file>               Assemble and run the file.
    --stdio              Start the LSP (used by editors).
```

## Building

Run `zig build` to build the binary. If you do not need LSP support, then pass
in `-Dlsp=false` which will decrease your binary size by ~90%.

## Testing

Run `zig build test` to run all of the behavior and syntax tests (located in
the `test` folder).

Run `zig build fuzz` to run random programs against a `legv8emul` executable.
This is available to students at Iowa State University taking COM S 3210 and has
been used to find multiple bugs in the provided emulator.

## License

[MIT](./LICENSE)
