![./lemu.svg](lemu.svg)

A toolkit for LEGv8, an academic ISA inspired by ARMv8 described in
_Computer Organization And Design Arm Edition_.

## Features

- **LEGv8 Emulator**: Assemble and execute LEGv8 code (`lemu <file>`).
- **Command-Line Debugger**: Set breakpoints, step through instructions, and inspect registers (`lemu -d <file>`).
- **Language Server (LSP)**: Syntax and assembler errors, goto definition, and hover information in your editor
- **VS Code Extension**: Instruction snippets and syntax highlighting. Requires a `lemu` executable.

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

Use `zig build`. Relevant project-specific options from `zig build -h`:

```
  -Dtarget=[string]            The CPU architecture, OS, and ABI to build for
  -Dcpu=[string]               Target CPU features to add or subtract
  -Doptimize=[enum]            Prioritize performance, safety, or binary size
                                 Supported Values:
                                   Debug
                                   ReleaseSafe
                                   ReleaseFast
                                   ReleaseSmall
  -Dlsp=[bool]                 Include LSP support (defaults to true)
  -Ddebugger=[bool]            Include debugger support (defaults to true)
  -Dstrip=[bool]               Strip debug information
```

## Compliance

The goal is to maintain instruction encoding and emulation compliance. However,
there are still non-standard instructions such as `PRNT`, to enable
printf-debugging.

Please open issues for correctness problems.

## Performance

The emulator is optimized enough to compete with `legv8emul` for most programs.
However, lemu has a slower startup time and usually consumes about 10% more
memory compared to `legv8emul`.

```
$ uname -a
Linux archlinux 6.17.2-arch1-1 #1 SMP PREEMPT_DYNAMIC Sun, 12 Oct 2025 12:45:18 +0000 x86_64 GNU/Linux
```

<details>
<summary>67% faster recursive fibonacci sequence from 1 to 30</summary>
<pre><code>$ zig build -Doptimize=ReleaseFast -Dstrip
$ poop "lemu test/behavior/fib.lv8" "./legv8emul test/behavior/fib.lv8 -s 2000"
Benchmark 1 (32 runs): lemu test/behavior/fib.lv8
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           157ms ± 9.50ms     148ms …  192ms          2 ( 6%)        0%
  peak_rss           1.73MB ± 39.3KB    1.55MB … 1.74MB          3 ( 9%)        0%
  cpu_cycles          654M  ± 28.3M      552M  …  680M           2 ( 6%)        0%
  instructions       3.27G  ±  152M     2.67G  … 3.39G           2 ( 6%)        0%
  cache_references   2.00K  ± 1.10K     1.00K  … 5.92K           2 ( 6%)        0%
  cache_misses       1.40K  ±  821       709   … 4.50K           2 ( 6%)        0%
  branch_misses      1.02M  ± 47.2K      832K  … 1.07M           2 ( 6%)        0%
Benchmark 2 (20 runs): ./legv8emul test/behavior/fib.lv8 -s 2000
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           262ms ± 6.99ms     253ms …  279ms          1 ( 5%)        💩+ 67.3% ±  3.2%
  peak_rss           1.55MB ±    0      1.55MB … 1.55MB          0 ( 0%)        ⚡- 10.3% ±  1.0%
  cpu_cycles         1.17G  ± 31.2M     1.08G  … 1.19G           3 (15%)        💩+ 78.3% ±  2.6%
  instructions       4.50G  ±  113M     4.17G  … 4.55G           4 (20%)        💩+ 37.7% ±  2.4%
  cache_references   2.95K  ±  896      1.71K  … 4.63K           0 ( 0%)        💩+ 47.7% ± 29.5%
  cache_misses       2.14K  ±  748      1.33K  … 3.80K           0 ( 0%)        💩+ 52.7% ± 32.5%
  branch_misses      1.35M  ± 34.2K     1.25M  … 1.37M           4 (20%)        💩+ 33.0% ±  2.4%
</code></pre></details>

Feel free to open issues for performance problems.

## Testing

Run `zig build test` to run all of the behavior and syntax tests (located in
the `test` folder).

Run `zig build fuzz` to run random programs against a `legv8emul` executable.
This is available to students at Iowa State University taking COM S 3210 and has
been used to find multiple bugs in the provided emulator.

## License

[MIT](./LICENSE)
