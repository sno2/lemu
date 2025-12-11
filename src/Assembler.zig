//! Assembler and linker for LEGv8 assembly.

const std = @import("std");

pub const Lexer = @import("Assembler/Lexer.zig");

const Compilation = @import("Compilation.zig");
const Instruction = @import("instruction.zig").Instruction;
const Memory = @import("Vm/Memory.zig");

const Assembler = @This();

gpa: std.mem.Allocator,
lex: Lexer,
instructions: std.MultiArrayList(AnnotatedInstruction),
symbols: std.StringArrayHashMapUnmanaged(Symbol),
relocations: std.ArrayList(Relocation),
errors: std.ArrayList(Compilation.Error),

pub const AnnotatedInstruction = struct {
    source_start: u32,
    instruction: Instruction,
};

pub const Error = error{InvalidSyntax} || std.mem.Allocator.Error;

pub fn addError(assembler: *Assembler, err: Compilation.Error) !void {
    try assembler.errors.append(assembler.gpa, err);
}

pub fn fail(assembler: *Assembler, err: Compilation.Error) Error!noreturn {
    try assembler.addError(err);
    return error.InvalidSyntax;
}

const Symbol = struct {
    instruction_index: u32,
};

pub const Relocation = struct {
    instruction_index: u32,
    format: Format,
    symbol: Lexer.SourceRange,
    resolved: bool = false,

    pub const Format = enum {
        b,
        cb,
        /// 2 instructions are reserved
        lda,
    };
};

pub fn init(gpa: std.mem.Allocator, source: [:0]const u8) Assembler {
    var assembler: Assembler = .{
        .gpa = gpa,
        .lex = .{ .source = source },
        .instructions = .empty,
        .symbols = .empty,
        .relocations = .empty,
        .errors = .empty,
    };
    assembler.lex.next();
    return assembler;
}

pub fn reset(assembler: *Assembler, source: [:0]const u8) void {
    assembler.lex = .{ .source = source };
    assembler.instructions.clearRetainingCapacity();
    assembler.symbols.clearRetainingCapacity();
    assembler.relocations.clearRetainingCapacity();
    assembler.errors.clearRetainingCapacity();
    assembler.lex.next();
}

pub fn deinit(assembler: *Assembler, gpa: std.mem.Allocator) void {
    assembler.instructions.deinit(gpa);
    assembler.symbols.deinit(gpa);
    assembler.relocations.deinit(gpa);
    assembler.errors.deinit(gpa);
}

const TokenResult = struct {
    token: Lexer.Token,
    source_range: Lexer.SourceRange,
};

fn curToken(assembler: *Assembler) TokenResult {
    return .{
        .token = assembler.lex.token,
        .source_range = assembler.lex.sourceRange(),
    };
}

fn expectToken(
    assembler: *Assembler,
    tag: Lexer.Token.Tag,
) Error!TokenResult {
    if (assembler.lex.token != tag) {
        try assembler.fail(.{
            .data = .{
                .expected_token = .{
                    .expected = tag,
                    .got = assembler.lex.token,
                },
            },
            .source_range = assembler.lex.sourceRange(),
        });
    }
    const result = assembler.curToken();
    assembler.lex.next();
    return result;
}

pub fn assemble(assembler: *Assembler) Error!void {
    while (true) {
        switch (assembler.lex.token) {
            .eof => break,
            .newline => assembler.lex.next(),
            .dot_identifier, .identifier => {
                assembler.assembleLineAtIdentifier() catch |e| switch (e) {
                    error.InvalidSyntax => {
                        while (assembler.lex.token != .newline and assembler.lex.token != .eof) {
                            assembler.lex.next();
                        }
                    },
                    else => return e,
                };
            },
            else => {
                try assembler.addError(.{
                    .data = .{ .unexpected = assembler.lex.token },
                    .source_range = assembler.lex.sourceRange(),
                });
                while (assembler.lex.token != .newline and assembler.lex.token != .eof) {
                    assembler.lex.next();
                }
            },
        }
    }

    for (assembler.relocations.items) |*relocation| {
        if (relocation.resolved) continue;
        const instructions = assembler.instructions.items(.instruction)[relocation.instruction_index..];
        relocation.resolved = try assembler.resolveRelocation(relocation.*, instructions);
        if (!relocation.resolved) {
            try assembler.addError(.{
                .data = .{ .undefined_label = relocation.symbol.slice(assembler.lex.source) },
                .source_range = relocation.symbol,
            });
        }
    }

    if (assembler.errors.items.len != 0) {
        return error.InvalidSyntax;
    }
}

fn assembleLineAtIdentifier(assembler: *Assembler) Error!void {
    const identifier_tok = assembler.curToken();
    assembler.lex.next();
    const identifier = identifier_tok.source_range.slice(assembler.lex.source);

    if (assembler.lex.token == .@":") {
        try assembler.assembleLabel(identifier_tok);
        return;
    }

    try assembler.instructions.ensureUnusedCapacity(assembler.gpa, 3);

    const codec_tag = Instruction.Codec.Tag.map.get(identifier) orelse {
        if (std.mem.eql(u8, identifier, "MOV")) {
            var instruction: AnnotatedInstruction = .{
                .source_start = @intCast(identifier_tok.source_range.start),
                .instruction = @bitCast(@as(u32, 0)),
            };
            instruction.instruction.setTag(.add);
            defer assembler.instructions.appendAssumeCapacity(instruction);

            instruction.instruction.r.rd = (try assembler.expectToken(.x)).token.x;
            _ = try assembler.expectToken(.@",");
            instruction.instruction.r.rn = (try assembler.expectToken(.x)).token.x;
            instruction.instruction.r.rm = 31;
            return;
        } else if (std.mem.eql(u8, identifier, "LDA")) {
            const source_start: u32 = @intCast(identifier_tok.source_range.start);
            var instructions: [2]Instruction = @splat(@bitCast(@as(u32, 0)));
            defer for (&instructions, 0..) |*i, j| {
                i.setTag(if (j == 0) .movz else .movk);
                assembler.instructions.appendAssumeCapacity(.{
                    .source_start = source_start,
                    .instruction = i.*,
                });
            };

            const rd = (try assembler.expectToken(.x)).token.x;
            _ = try assembler.expectToken(.@",");
            const label_tok = try assembler.expectToken(.identifier);

            for (&instructions) |*i| {
                i.iw.rd = rd;
            }

            try assembler.addRelocation(.{
                .instruction_index = @intCast(assembler.instructions.len),
                .format = .lda,
                .symbol = label_tok.source_range,
            }, &instructions);
            return;
        } else if (std.mem.eql(u8, identifier, "CMP")) {
            var instruction: AnnotatedInstruction = .{
                .source_start = @intCast(identifier_tok.source_range.start),
                .instruction = @bitCast(@as(u32, 0)),
            };
            instruction.instruction.setTag(.subs);
            defer assembler.instructions.appendAssumeCapacity(instruction);

            instruction.instruction.r.rd = 31;
            instruction.instruction.r.rn = (try assembler.expectToken(.x)).token.x;
            _ = try assembler.expectToken(.@",");
            instruction.instruction.r.rm = (try assembler.expectToken(.x)).token.x;
            return;
        } else if (std.mem.eql(u8, identifier, "CMPI")) {
            var instruction: AnnotatedInstruction = .{
                .source_start = @intCast(identifier_tok.source_range.start),
                .instruction = @bitCast(@as(u32, 0)),
            };
            instruction.instruction.setTag(.subis);
            defer assembler.instructions.appendAssumeCapacity(instruction);

            instruction.instruction.i.rd = 31;
            instruction.instruction.i.rn = (try assembler.expectToken(.x)).token.x;
            _ = try assembler.expectToken(.@",");
            const immediate_tok = try assembler.expectToken(.integer);
            instruction.instruction.i.alu_immediate = std.fmt.parseInt(i12, immediate_tok.source_range.slice(assembler.lex.source), 0) catch {
                try assembler.fail(.{
                    .data = .immediate_overflow,
                    .source_range = immediate_tok.source_range,
                });
            };
            return;
        } else {
            try assembler.fail(.{
                .data = .unknown_mneumonic,
                .source_range = identifier_tok.source_range,
            });
        }
    };
    const codec = codec_tag.get();

    var instruction: AnnotatedInstruction = .{
        .source_start = @intCast(identifier_tok.source_range.start),
        .instruction = @bitCast(@as(u32, 0)),
    };
    var insn: *Instruction = &instruction.instruction;
    insn.setTag(codec.tag);
    defer assembler.instructions.appendAssumeCapacity(instruction);

    switch (codec.format) {
        .r => |r| {
            switch (r.style) {
                .@"Xn, Xn, Xn" => {
                    insn.r.rd = (try assembler.expectToken(.x)).token.x;
                    _ = try assembler.expectToken(.@",");
                    insn.r.rn = (try assembler.expectToken(.x)).token.x;
                    _ = try assembler.expectToken(.@",");
                    insn.r.rm = (try assembler.expectToken(.x)).token.x;
                },
                .@"Xn, Xn, Shamt" => {
                    insn.r.rd = (try assembler.expectToken(.x)).token.x;
                    _ = try assembler.expectToken(.@",");
                    insn.r.rn = (try assembler.expectToken(.x)).token.x;
                    _ = try assembler.expectToken(.@",");
                    const shamt_tok = try assembler.expectToken(.integer);
                    insn.r.shamt = std.fmt.parseInt(u6, shamt_tok.source_range.slice(assembler.lex.source), 0) catch {
                        try assembler.fail(.{
                            .data = .shift_amount_overflow,
                            .source_range = shamt_tok.source_range,
                        });
                    };
                },
                .Xn => {
                    insn.r.rn = (try assembler.expectToken(.x)).token.x;
                },
                .prnt => {
                    insn.r.rd, insn.r.rn = switch (assembler.lex.token) {
                        .x => .{ (try assembler.expectToken(.x)).token.x, 0 },
                        .s => .{ (try assembler.expectToken(.s)).token.s, 1 },
                        .d => .{ (try assembler.expectToken(.d)).token.d, 2 },
                        else => try assembler.fail(.{
                            .data = .expected_x_s_d,
                            .source_range = assembler.lex.sourceRange(),
                        }),
                    };
                },
                .@"Sn, Sn, Sn" => {
                    insn.r.rd = (try assembler.expectToken(.s)).token.s;
                    _ = try assembler.expectToken(.@",");
                    insn.r.rn = (try assembler.expectToken(.s)).token.s;
                    _ = try assembler.expectToken(.@",");
                    insn.r.rm = (try assembler.expectToken(.s)).token.s;
                },
                .@"Dn, Dn, Dn" => {
                    insn.r.rd = (try assembler.expectToken(.d)).token.d;
                    _ = try assembler.expectToken(.@",");
                    insn.r.rn = (try assembler.expectToken(.d)).token.d;
                    _ = try assembler.expectToken(.@",");
                    insn.r.rm = (try assembler.expectToken(.d)).token.d;
                },
                .@"Sn, Sn" => {
                    insn.r.rn = (try assembler.expectToken(.s)).token.s;
                    _ = try assembler.expectToken(.@",");
                    insn.r.rm = (try assembler.expectToken(.s)).token.s;
                },
                .@"Dn, Dn" => {
                    insn.r.rn = (try assembler.expectToken(.d)).token.d;
                    _ = try assembler.expectToken(.@",");
                    insn.r.rm = (try assembler.expectToken(.d)).token.d;
                },
                .empty => {},
                .time => {
                    if (assembler.lex.token == .newline) {
                        insn.r.rd = 0;
                    } else {
                        insn.r.rd = (try assembler.expectToken(.x)).token.x;
                    }
                },
            }
        },
        .i => {
            insn.i.rd = (try assembler.expectToken(.x)).token.x;
            _ = try assembler.expectToken(.@",");
            insn.i.rn = (try assembler.expectToken(.x)).token.x;
            _ = try assembler.expectToken(.@",");
            const immediate_tok = try assembler.expectToken(.integer);
            insn.i.alu_immediate = std.fmt.parseInt(i12, immediate_tok.source_range.slice(assembler.lex.source), 0) catch {
                try assembler.fail(.{
                    .data = .immediate_overflow,
                    .source_range = immediate_tok.source_range,
                });
            };
        },
        .d => |d| {
            switch (d.style) {
                .@"Xn, [Xn, #]" => {
                    insn.d.rt = (try assembler.expectToken(.x)).token.x;
                    _ = try assembler.expectToken(.@",");
                    _ = try assembler.expectToken(.@"[");
                    insn.d.rn = (try assembler.expectToken(.x)).token.x;
                    _ = try assembler.expectToken(.@",");
                    const offset_tok = try assembler.expectToken(.integer);
                    const offset = std.fmt.parseInt(u9, offset_tok.source_range.slice(assembler.lex.source), 0) catch {
                        try assembler.fail(.{
                            .data = .load_store_offset_overflow,
                            .source_range = offset_tok.source_range,
                        });
                    };
                    insn.d.dt_address = offset;
                    _ = try assembler.expectToken(.@"]");
                },
                .@"Xn, Xn, [Xn]" => {
                    insn.d.rt = (try assembler.expectToken(.x)).token.x;
                    _ = try assembler.expectToken(.@",");
                    insn.d.rn = (try assembler.expectToken(.x)).token.x;
                    _ = try assembler.expectToken(.@",");
                    _ = try assembler.expectToken(.@"[");
                    insn.d.dt_address = (try assembler.expectToken(.x)).token.x;
                    _ = try assembler.expectToken(.@"]");
                },
                .@"Sn, [Xn, #]" => {
                    insn.d.rt = (try assembler.expectToken(.s)).token.s;
                    _ = try assembler.expectToken(.@",");
                    _ = try assembler.expectToken(.@"[");
                    insn.d.rn = (try assembler.expectToken(.x)).token.x;
                    _ = try assembler.expectToken(.@",");
                    const offset_tok = try assembler.expectToken(.integer);
                    const offset = std.fmt.parseInt(u9, offset_tok.source_range.slice(assembler.lex.source), 0) catch {
                        try assembler.fail(.{
                            .data = .load_store_offset_overflow,
                            .source_range = offset_tok.source_range,
                        });
                    };
                    insn.d.dt_address = offset;
                    _ = try assembler.expectToken(.@"]");
                },
                .@"Dn, [Xn, #]" => {
                    insn.d.rt = (try assembler.expectToken(.d)).token.d;
                    _ = try assembler.expectToken(.@",");
                    _ = try assembler.expectToken(.@"[");
                    insn.d.rn = (try assembler.expectToken(.x)).token.x;
                    _ = try assembler.expectToken(.@",");
                    const offset_tok = try assembler.expectToken(.integer);
                    const offset = std.fmt.parseInt(u9, offset_tok.source_range.slice(assembler.lex.source), 0) catch {
                        try assembler.fail(.{
                            .data = .load_store_offset_overflow,
                            .source_range = offset_tok.source_range,
                        });
                    };
                    insn.d.dt_address = offset;
                    _ = try assembler.expectToken(.@"]");
                },
            }
        },
        .b => {
            const name_tok = try assembler.expectToken(.identifier);
            try assembler.addRelocation(.{
                .format = .b,
                .instruction_index = @intCast(assembler.instructions.len),
                .symbol = name_tok.source_range,
            }, insn[0..1]);
        },
        .cb => {
            if (codec.format.cb.op) |op| {
                insn.cb.rt = op;
            } else {
                insn.cb.rt = (try assembler.expectToken(.x)).token.x;
                _ = try assembler.expectToken(.@",");
            }

            const name_tok = try assembler.expectToken(.identifier);
            try assembler.addRelocation(.{
                .format = .cb,
                .instruction_index = @intCast(assembler.instructions.len),
                .symbol = name_tok.source_range,
            }, insn[0..1]);
        },
        .iw => inner2: {
            insn.iw.rd = (try assembler.expectToken(.x)).token.x;
            _ = try assembler.expectToken(.@",");
            const immediate_tok = try assembler.expectToken(.integer);
            insn.iw.mov_immediate = std.fmt.parseInt(u16, immediate_tok.source_range.slice(assembler.lex.source), 0) catch {
                try assembler.fail(.{
                    .data = .mov_immediate_overflow,
                    .source_range = immediate_tok.source_range,
                });
            };

            if (assembler.lex.token == .newline) {
                insn.iw.shamtx16 = 0;
                break :inner2;
            }

            _ = try assembler.expectToken(.@",");
            const lsl_tok = assembler.curToken();
            if (!std.mem.eql(u8, lsl_tok.source_range.slice(assembler.lex.source), "LSL")) {
                try assembler.fail(.{
                    .data = .mov_no_lsl,
                    .source_range = lsl_tok.source_range,
                });
            }
            assembler.lex.next();
            const shift_tok = try assembler.expectToken(.integer);
            insn.iw.shamtx16 = switch (std.fmt.parseInt(u8, shift_tok.source_range.slice(assembler.lex.source), 0) catch 1) {
                inline 0, 16, 32, 48 => |x| x / 16,
                else => try assembler.fail(.{
                    .data = .mov_shift_overflow,
                    .source_range = shift_tok.source_range,
                }),
            };
        },
    }

    if (assembler.lex.token != .eof and assembler.lex.token != .newline) {
        _ = try assembler.expectToken(.newline);
        unreachable;
    }
}

fn assembleLabel(assembler: *Assembler, identifier_tok: TokenResult) Error!void {
    const identifier = identifier_tok.source_range.slice(assembler.lex.source);

    if (identifier_tok.token == .dot_identifier) {
        try assembler.fail(.{
            .data = .dot_label,
            .source_range = identifier_tok.source_range,
        });
    }
    assembler.lex.next();

    const gop = try assembler.symbols.getOrPut(assembler.gpa, identifier);
    if (gop.found_existing) {
        try assembler.addError(.{
            .data = .{ .duplicate_label_name = identifier },
            .source_range = identifier_tok.source_range,
        });
    } else {
        gop.value_ptr.* = .{ .instruction_index = @intCast(assembler.instructions.len) };
    }
}

fn resolveRelocation(assembler: *Assembler, relocation: Relocation, instructions: []Instruction) Error!bool {
    const symbol = assembler.symbols.get(relocation.symbol.slice(assembler.lex.source)) orelse return false;
    switch (relocation.format) {
        inline .b, .cb => |format| {
            const instruction = &instructions[0];
            const full_offset = std.math.sub(isize, @intCast(symbol.instruction_index), @intCast(relocation.instruction_index)) catch return false;
            switch (format) {
                .b => instruction.b.br_address = std.math.cast(@TypeOf(instruction.b.br_address), full_offset) orelse return false,
                .cb => instruction.cb.cond_br_address = std.math.cast(@TypeOf(instruction.cb.cond_br_address), full_offset) orelse return false,
                else => comptime unreachable,
            }
            return true;
        },
        .lda => {
            const absolute_address = Memory.text_start + @sizeOf(Instruction) * symbol.instruction_index;
            for (instructions[0..2], 0..) |*instruction, i| {
                instruction.iw.mov_immediate = @truncate(absolute_address >> @intCast(16 * i));
                instruction.iw.shamtx16 = @intCast(i);
            }
            return true;
        },
    }
}

fn addRelocation(assembler: *Assembler, relocation: Relocation, instructions: []Instruction) Error!void {
    var reloc = relocation;
    reloc.resolved = try assembler.resolveRelocation(relocation, instructions);
    try assembler.relocations.append(assembler.gpa, reloc);
}

pub const WriteProgramOptions = struct {
    writer: *std.io.Writer,
    format: Format,

    pub const Format = union(enum) {
        human: std.io.tty.Config,
        binary,
    };
};

pub fn writeProgram(assembler: *Assembler, options: WriteProgramOptions) !void {
    switch (options.format) {
        .human => |tty| {
            for (assembler.instructions.items(.instruction)) |insn| {
                const bits_be: u32 = @bitCast(insn);
                try tty.setColor(options.writer, .green);
                try options.writer.print("{X} ", .{bits_be});
                try tty.setColor(options.writer, .reset);
                try tty.setColor(options.writer, .blue);
                try tty.setColor(options.writer, .bold);
                try options.writer.print("{b} ", .{bits_be});
                try tty.setColor(options.writer, .reset);
                try tty.setColor(options.writer, .dim);
                try options.writer.print("{b}\n", .{@byteSwap(bits_be)});
                try tty.setColor(options.writer, .reset);
            }
        },
        .binary => {
            for (assembler.instructions.items(.instruction)) |insn| {
                try options.writer.writeInt(u32, @bitCast(insn), .big);
            }
        },
    }
}

fn bruteForceTest(gpa: std.mem.Allocator, seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);

    const source_len: usize = @intCast(prng.next() % 200);

    const source = try gpa.allocSentinel(u8, source_len, 0);
    defer gpa.free(source);

    if (source_len != 0) {
        prng.fill(source);
    }

    var assembler: Assembler = .init(gpa, source);
    defer assembler.deinit(gpa);

    assembler.assemble() catch |e| switch (e) {
        error.InvalidSyntax => {},
        else => return e,
    };
}

// test "label" {
//     try bruteForceTest(std.testing.allocator, 385254);
// }

// test "brute force assembler" {
//     for (385_000..390_000) |seed| {
//         std.log.err("{}", .{seed});
//         try bruteForceTest(std.testing.allocator, 385254);
//     }
// }
