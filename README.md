![Lemu](lemu.svg)

A toolkit for LEGv8, an academic ISA and assembly language inspired by ARMv8
described in _Computer Organization And Design Arm Edition_ by Patterson and
Hennessy.

## Features

- **LEGv8 Emulator**: Assemble and execute LEGv8 code (`lemu <file>`).
- **Command-Line Debugger**: Set breakpoints, step through instructions, and
  inspect registers (`lemu -d <file>`).
- **Language Server (LSP)**: View syntax and compiler errors, goto definition,
  and hover information in your editor.
- **VS Code Extension**: Use instruction snippets and access the language server
  features. Requires a `lemu` executable.

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

Lemu has its own test suite and has been fuzz tested against `legv8emul`, an
emulator offered to students taking COM S 3210 at Iowa State University. This
has allowed me to fix multiple bugs in Lemu and file issues for `legv8emul`.

Although the most important metric is compliance, Lemu is not terribly slow
either. For example, it is able to beat `legv8emul` by 67.3% for calculating
the fibonacci sequence of 1 to 30 with recursion. When optimizing the emulator,
the largest points for gains were (1) optimizing opcode decoding to use a lookup
table and (2) using [Zig's labeled switch loop](https://ziglang.org/documentation/0.15.2/#Labeled-switch)
for the instruction loop.

<details>
<summary>Fibonacci benchmark details</summary>
<pre><code>$ uname -a
Linux archlinux 6.17.2-arch1-1 #1 SMP PREEMPT_DYNAMIC Sun, 12 Oct 2025 12:45:18 +0000 x86_64 GNU/Linux
$ zig build -Doptimize=ReleaseFast -Dstrip
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

Here is a list of the standard and non-standard assembly instructions supported
by Lemu:

| Mneumonic | Description                                | Format                          |
| --------- | ------------------------------------------ | ------------------------------- |
| ADD       | ADD                                        | R-type instruction              |
| ADDI      | ADD Immediate                              | I-type instruction              |
| ADDIS     | ADD Immediate & Set flags                  | I-type instruction              |
| ADDS      | ADD & Set flags                            | R-type instruction              |
| AND       | AND                                        | R-type instruction              |
| ANDI      | AND Immediate                              | I-type instruction              |
| ANDIS     | AND Immediate & Set flags                  | I-type instruction              |
| ANDS      | AND & Set flags                            | R-type instruction              |
| B         | Branch                                     | B-type instruction              |
| B.EQ      | Branch if Equal                            | CB-type instruction (op=0b0)    |
| B.NE      | Branch if Not Equal                        | CB-type instruction (op=0b1)    |
| B.LT      | Branch if Less Than                        | CB-type instruction (op=0b2)    |
| B.LE      | Branch if Less Than or Equal               | CB-type instruction (op=0b3)    |
| B.GT      | Branch if Greater Than                     | CB-type instruction (op=0b4)    |
| B.GE      | Branch if Greater Than or Equal            | CB-type instruction (op=0b5)    |
| B.LO      | Branch if Less Than (Unsigned)             | CB-type instruction (op=0b6)    |
| B.LS      | Branch if Less Than or Equal (Unsigned)    | CB-type instruction (op=0b7)    |
| B.HI      | Branch if Greater Than (Unsigned)          | CB-type instruction (op=0b8)    |
| B.HS      | Branch if Greater Than or Equal (Unsigned) | CB-type instruction (op=0b9)    |
| B.MI      | Branch if Minus                            | CB-type instruction (op=0b10)   |
| B.PL      | Branch if Plus                             | CB-type instruction (op=0b11)   |
| B.VS      | Branch if Overflow Set                     | CB-type instruction (op=0b12)   |
| B.VC      | Branch if Overflow Clear                   | CB-type instruction (op=0b13)   |
| BL        | Branch with Link                           | B-type instruction              |
| BR        | Branch to Register                         | R-type instruction              |
| CBNZ      | Compare & Branch if Not Zero               | CB-type instruction             |
| CBZ       | Compare & Branch if Zero                   | CB-type instruction             |
| EOR       | Exclusive OR                               | R-type instruction              |
| EORI      | Exclusive OR Immediate                     | I-type instruction              |
| LDUR      | LoaD Register Unscaled offset              | D-type instruction              |
| LDURB     | LoaD Byte Unscaled offset                  | D-type instruction              |
| LDURH     | LoaD Half Unscaled offset                  | D-type instruction              |
| LDURSW    | LoaD Signed Word Unscaled offset           | D-type instruction              |
| LDXR      | LoaD eXclusive Register                    | D-type instruction              |
| LSL       | Logical Shift Left                         | R-type instruction              |
| LSR       | Logical Shift Right                        | R-type instruction              |
| MOVK      | MOVe wide with Keep                        | IW-type instruction             |
| MOVZ      | MOVe wide with Zero                        | IW-type instruction             |
| ORR       | Inclusive OR                               | R-type instruction              |
| ORRI      | Inclusive OR Immediate                     | I-type instruction              |
| STUR      | STore Register Unscaled offset             | D-type instruction              |
| STURB     | STore Byte Unscaled offset                 | D-type instruction              |
| STURH     | STore Half Unscaled offset                 | D-type instruction              |
| STURW     | STore Word Unscaled offset                 | D-type instruction              |
| STXR      | STore eXclusive Register                   | D-type instruction              |
| SUB       | SUBtract                                   | R-type instruction              |
| SUBI      | SUBtract Immediate                         | I-type instruction              |
| SUBIS     | SUBtract Immediate & Set flags             | I-type instruction              |
| SUBS      | SUBtract & Set flags                       | R-type instruction              |
| FADDS     | Floating-point ADD Single                  | R-type instruction (shamt=0xa)  |
| FADDD     | Floating-point ADD Double                  | R-type instruction (shamt=0xa)  |
| FCMPS     | Floating-point CoMPare Single              | R-type instruction (shamt=0x8)  |
| FCMPD     | Floating-point CoMPare Double              | R-type instruction (shamt=0x8)  |
| FDIVS     | Floating-point DIVide Single               | R-type instruction (shamt=0x6)  |
| FDIVD     | Floating-point DIVide Double               | R-type instruction (shamt=0x6)  |
| FMULS     | Floating-point MULtiply Single             | R-type instruction (shamt=0x2)  |
| FMULD     | Floating-point MULtiply Double             | R-type instruction (shamt=0x2)  |
| FSUBS     | Floating-point SUBtract Single             | R-type instruction (shamt=0xe)  |
| FSUBD     | Floating-point SUBtract Double             | R-type instruction (shamt=0xe)  |
| LDURS     | LoaD Single floating-point                 | D-type instruction              |
| LDURD     | LoaD Double floating-point                 | D-type instruction              |
| MUL       | MULtiply                                   | R-type instruction (shamt=0x1f) |
| SDIV      | Signed DIVide                              | R-type instruction (shamt=0x2)  |
| SMULH     | Signed MULtiply High                       | R-type instruction              |
| STURS     | STore Single floating-point                | D-type instruction              |
| STURD     | STore Double floating-point                | D-type instruction              |
| UDIV      | Unsigned DIVide                            | R-type instruction (shamt=0x3)  |
| UMULH     | Unsigned MULtiply High                     | R-type instruction              |
| HALT      | HALT execution (non-standard)              | R-type instruction              |
| DUMP      | DUMP state (non-standard)                  | R-type instruction              |
| PRNT      | PRiNT register (non-standard)              | R-type instruction              |
| PRNL      | PRint NewLine (non-standard)               | R-type instruction              |
| TIME      | TIME now (non-standard)                    | R-type instruction              |

## Testing

Run `zig build test` to run all of the behavior and syntax tests (located in
the `test` folder).

Run `zig build fuzz` to run random programs against a `legv8emul` executable.
This is available to students at Iowa State University taking COM S 3210 and has
been used to find multiple bugs in the provided emulator.

## License

[MIT](./LICENSE)
