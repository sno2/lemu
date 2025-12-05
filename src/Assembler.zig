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
labels: std.StringArrayHashMapUnmanaged(Label),
undefined_labels: std.StringArrayHashMapUnmanaged(std.ArrayList(UndefinedLabel)),
errors: std.ArrayListUnmanaged(Compilation.Error),
needs_relocations: bool,

pub const AnnotatedInstruction = struct {
    source_start: u32,
    instruction: Instruction,
    instruction_codec_tag: Instruction.Codec.Tag,
    branch_label_index: ?u32,
};

pub const Error = error{InvalidSyntax} || std.mem.Allocator.Error;

pub fn addError(assembler: *Assembler, err: Compilation.Error) !void {
    try assembler.errors.append(assembler.gpa, err);
}

pub fn fail(assembler: *Assembler, err: Compilation.Error) Error!noreturn {
    try assembler.addError(err);
    return error.InvalidSyntax;
}

const Label = struct {
    instruction_index: u32,
};

const UndefinedLabel = struct {
    instruction_index: u32,
    format: Format,

    pub const Format = enum {
        b,
        cb,
        lda,
    };
};

pub fn init(gpa: std.mem.Allocator, source: [:0]const u8) Assembler {
    var assembler: Assembler = .{
        .gpa = gpa,
        .lex = .{ .source = source },
        .instructions = .empty,
        .labels = .empty,
        .undefined_labels = .empty,
        .errors = .empty,
        .needs_relocations = false,
    };
    assembler.lex.next();
    return assembler;
}

pub fn reset(assembler: *Assembler, source: [:0]const u8) void {
    assembler.lex = .{ .source = source };
    assembler.instructions.clearRetainingCapacity();
    assembler.labels.clearRetainingCapacity();
    for (assembler.undefined_labels.values()) |*undefined_label| {
        undefined_label.deinit(assembler.gpa);
    }
    assembler.undefined_labels.clearRetainingCapacity();
    assembler.errors.clearRetainingCapacity();
    assembler.needs_relocations = false;
    assembler.lex.next();
}

pub fn deinit(assembler: *Assembler, gpa: std.mem.Allocator) void {
    assembler.instructions.deinit(gpa);
    assembler.labels.deinit(gpa);
    for (assembler.undefined_labels.values()) |*undefined_label| {
        undefined_label.deinit(assembler.gpa);
    }
    assembler.undefined_labels.deinit(gpa);
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

    for (assembler.undefined_labels.values()) |undefined_labels| {
        for (undefined_labels.items) |label| {
            const source_start = assembler.instructions.items(.source_start)[label.instruction_index];
            assembler.lex.index = source_start;
            assembler.lex.next();
            assembler.lex.next();
            var source_range: Lexer.SourceRange = assembler.lex.sourceRange();
            while (assembler.lex.token != .newline and assembler.lex.token != .eof) {
                source_range = assembler.lex.sourceRange();
                assembler.lex.next();
            }

            try assembler.addError(.{
                .data = .{ .undefined_label = source_range.slice(assembler.lex.source) },
                .source_range = source_range,
            });
        }
    }

    if (assembler.needs_relocations) {
        @panic("Congratulations! You have enough instructions to require relocations. However, this is not implemented yet...");
    }

    if (assembler.errors.items.len != 0) {
        return error.InvalidSyntax;
    }
}

fn assembleLineAtIdentifier(assembler: *Assembler) Error!void {
    const identifier_tok = assembler.curToken();
    assembler.lex.next();
    const identifier = identifier_tok.source_range.slice(assembler.lex.source);

    const codec_tag = Instruction.Codec.Tag.map.get(identifier) orelse {
        if (assembler.lex.token == .@":") {
            try assembler.assembleLabel(identifier_tok);
            return;
        } else if (std.mem.eql(u8, identifier, "MOV")) {
            var instruction: AnnotatedInstruction = .{
                .source_start = @intCast(identifier_tok.source_range.start),
                .instruction = @bitCast(@as(u32, 0)),
                .instruction_codec_tag = .add,
                .branch_label_index = null,
            };
            instruction.instruction.setTag(.add);
            try assembler.instructions.ensureUnusedCapacity(assembler.gpa, 1);
            defer assembler.instructions.appendAssumeCapacity(instruction);

            instruction.instruction.r.rd = (try assembler.expectToken(.x)).token.x;
            _ = try assembler.expectToken(.@",");
            instruction.instruction.r.rn = (try assembler.expectToken(.x)).token.x;
            instruction.instruction.r.rm = 31;
            return;
        } else if (std.mem.eql(u8, identifier, "LDA")) {
            const result = (try assembler.expectToken(.x)).token.x;
            _ = try assembler.expectToken(.@",");
            const label_tok = try assembler.expectToken(.identifier);
            const label_name = label_tok.source_range.slice(assembler.lex.source);
            const maybe_label = assembler.labels.get(label_name);

            var instruction: AnnotatedInstruction = .{
                .source_start = @intCast(identifier_tok.source_range.start),
                .instruction = @bitCast(@as(u32, 0)),
                .instruction_codec_tag = .movz,
                .branch_label_index = null,
            };
            instruction.instruction.setTag(.movz);
            if (maybe_label == null) {
                const gop = try assembler.undefined_labels.getOrPut(assembler.gpa, label_name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                }
                try gop.value_ptr.append(assembler.gpa, .{
                    .format = .lda,
                    .instruction_index = @intCast(assembler.instructions.len),
                });
            }

            var addr: u64 = if (maybe_label) |label| Memory.text_start + 4 * label.instruction_index else std.math.maxInt(u64);
            for (0..4) |half| {
                instruction.instruction.iw.mov_immediate = @truncate(addr);
                addr >>= 16;
                instruction.instruction.iw.shamtx16 = @intCast(half);
                instruction.instruction.iw.rd = result;
                if (half == 0 or instruction.instruction.iw.mov_immediate != 0) {
                    try assembler.instructions.append(assembler.gpa, instruction);
                }
                instruction.instruction.setTag(.movk);
            }

            return;
        } else if (std.mem.eql(u8, identifier, "CMP")) {
            var instruction: AnnotatedInstruction = .{
                .source_start = @intCast(identifier_tok.source_range.start),
                .instruction = @bitCast(@as(u32, 0)),
                .instruction_codec_tag = .subs,
                .branch_label_index = null,
            };
            instruction.instruction.setTag(.subs);
            try assembler.instructions.ensureUnusedCapacity(assembler.gpa, 1);
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
                .instruction_codec_tag = .subis,
                .branch_label_index = null,
            };
            instruction.instruction.setTag(.subis);
            try assembler.instructions.ensureUnusedCapacity(assembler.gpa, 1);
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
        .instruction_codec_tag = codec_tag,
        .branch_label_index = null,
    };
    var insn: *Instruction = &instruction.instruction;
    insn.setTag(codec.tag);
    try assembler.instructions.ensureUnusedCapacity(assembler.gpa, 1);
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
        inline .b, .cb => {
            const format: UndefinedLabel.Format = switch (codec.format) {
                .b => .b,
                .cb => .cb,
                else => unreachable,
            };

            if (format == .cb) {
                if (codec.format.cb.op) |op| {
                    insn.cb.rt = op;
                } else {
                    insn.cb.rt = (try assembler.expectToken(.x)).token.x;
                    _ = try assembler.expectToken(.@",");
                }
            }

            const name_tok = try assembler.expectToken(.identifier);
            const name = name_tok.source_range.slice(assembler.lex.source);
            if (assembler.labels.getIndex(name)) |label| blk2: {
                instruction.branch_label_index = @intCast(label);
                const offset = @as(isize, @intCast(assembler.labels.values()[label].instruction_index)) - @as(isize, @intCast(assembler.instructions.len));
                switch (format) {
                    .b => insn.b.br_address = std.math.cast(i26, offset) orelse {
                        assembler.needs_relocations = true;
                        break :blk2;
                    },
                    .cb => insn.cb.cond_br_address = std.math.cast(i19, offset) orelse {
                        assembler.needs_relocations = true;
                        break :blk2;
                    },
                    else => unreachable,
                }
            } else {
                const gop = try assembler.undefined_labels.getOrPut(assembler.gpa, name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                }
                try gop.value_ptr.append(assembler.gpa, .{
                    .instruction_index = @intCast(assembler.instructions.len),
                    .format = format,
                });
            }
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

    const gop = try assembler.labels.getOrPut(assembler.gpa, identifier);
    if (gop.found_existing) {
        try assembler.fail(.{
            .data = .{ .duplicate_label_name = identifier },
            .source_range = identifier_tok.source_range,
        });
    }
    gop.value_ptr.* = .{ .instruction_index = @intCast(assembler.instructions.len) };

    if (assembler.undefined_labels.fetchSwapRemove(identifier)) |kv| {
        var list = kv.value;
        defer list.deinit(assembler.gpa);

        for (list.items) |undefined_label| {
            const full_offset = assembler.instructions.len - undefined_label.instruction_index;
            assembler.instructions.items(.branch_label_index)[undefined_label.instruction_index] = @intCast(gop.index);
            switch (undefined_label.format) {
                .b => {
                    const offset = std.math.cast(i26, full_offset) orelse {
                        assembler.needs_relocations = true;
                        continue;
                    };
                    assembler.instructions.items(.instruction)[undefined_label.instruction_index].b.br_address = offset;
                },
                .cb => {
                    const offset = std.math.cast(i19, full_offset) orelse {
                        assembler.needs_relocations = true;
                        continue;
                    };
                    assembler.instructions.items(.instruction)[undefined_label.instruction_index].cb.cond_br_address = offset;
                },
                .lda => {
                    var addr: u64 = Memory.text_start + 4 * assembler.instructions.len;
                    for (assembler.instructions.items(.instruction)[undefined_label.instruction_index..][0..4]) |*instruction| {
                        instruction.iw.mov_immediate = @truncate(addr);
                        addr >>= 16;
                    }
                },
            }
        }
    }
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
