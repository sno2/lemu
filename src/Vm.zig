const std = @import("std");

const Assembler = @import("Assembler.zig");
const Instruction = @import("instruction.zig").Instruction;
const Memory = @import("Vm/Memory.zig");

const Vm = @This();

const reserved_terminating_pc_address: i64 = Memory.text_end - 4;

/// M
memory: Memory,
/// PC - this is a u32 index into the readonly segment (makes alignment checks and accesses simpler)
pc: usize = 0,
/// N
negative: bool = false,
/// Z
zero: bool = false,
/// O
overflow: bool = false,
/// C
carry: bool = false,
/// R
registers: [32]i64 = blk: {
    var registers: [32]i64 = @splat(0);
    registers[28] = Memory.dynamic_end - 8; // SP
    registers[30] = reserved_terminating_pc_address; // BL
    break :blk registers;
},
/// S
single_registers: [32]f32 = @splat(0.0),
/// D
double_registers: [32]f64 = @splat(0.0),
exception: ?Exception = null,
output: *std.io.Writer,
tty_config: std.io.tty.Config,

pub const Options = struct {
    gpa: std.mem.Allocator,
    /// Copied using gpa.
    readonly_memory: []const u32,
    zero_page: bool,
    output: *std.io.Writer,
    tty_config: std.io.tty.Config,
};

pub fn init(options: Options) std.mem.Allocator.Error!Vm {
    var vm: Vm = .{
        .memory = .init(options.gpa),
        .output = options.output,
        .tty_config = options.tty_config,
    };
    errdefer vm.memory.deinit(options.gpa);
    try vm.memory.readonly.appendSlice(options.gpa, options.readonly_memory);
    if (options.zero_page) {
        try vm.memory.zero_page.appendNTimes(options.gpa, 0, 4096);
    }
    return vm;
}

/// Takes the role of the Exception Syndrome Register.
pub const Exception = union(enum(u6)) {
    /// Unknown
    unknown = 0,
    /// SIMD/FP registers disabled
    simd = 7,
    /// Illegal Execution State
    ies = 14,
    /// Supervisor Call Exception
    sys = 17,
    /// Instruction Abort
    instr = 32,
    /// Misaligned PC Exception
    pc = 34,
    /// Data Abort
    data: struct {
        kind: enum { load, store },
        addr: i64,
    } = 36,
    /// Floating-point exception
    fpe: enum {
        division_by_zero,
    } = 40,
    /// Data Breakpoint exception
    wpt = 52,
    /// SW Breakpoint Exception
    bkpt: enum {
        halt,
        dump,
        debugger,
    } = 56,

    pub const Fmt = struct {
        tty_config: std.io.tty.Config,
        assembler: *const Assembler,
        source_label: ?[]const u8,
        vm: *const Vm,
        exception: Exception,

        pub fn format(fmt: Fmt, writer: *std.io.Writer) std.io.Writer.Error!void {
            fmt.formatInner(writer) catch return error.WriteFailed;
        }

        fn formatInner(fmt: Fmt, writer: *std.io.Writer) !void {
            const insn_index = fmt.vm.pc;
            const insn_start = fmt.assembler.instructions.items(.source_start)[insn_index];
            var lex: Assembler.Lexer = .{ .source = fmt.assembler.lex.source };
            lex.index = insn_start;
            lex.next();

            const line = std.mem.count(u8, fmt.assembler.lex.source[0..insn_start], &.{'\n'}) + 1;
            const line_start = if (std.mem.lastIndexOfScalar(u8, fmt.assembler.lex.source[0..insn_start], '\n')) |nl_index| nl_index + 1 else 0;

            try fmt.tty_config.setColor(writer, .bold);
            try fmt.tty_config.setColor(writer, .red);
            try writer.print("{s} exception: ", .{switch (fmt.exception) {
                .data => "data",
                .fpe => "floating-point",
                .bkpt => "breakpoint",
                .pc => "program counter",
                .simd => "simd",
                .sys => "system",
                .wpt => "wpt",
                .ies => "ies",
                .instr => "instruction",
                .unknown => "unknown",
            }});

            try fmt.tty_config.setColor(writer, .reset);
            try fmt.tty_config.setColor(writer, .bold);
            switch (fmt.exception) {
                .data => |data| {
                    try writer.print("invalid {t} to {s}address at 0x{x}\n", .{
                        data.kind,
                        switch (Memory.Mapped.init(&fmt.vm.memory, @bitCast(data.addr))) {
                            .zero_page => "zero page ",
                            .reserved => "reserved ",
                            .text => "readonly ",
                            .dynamic => "",
                        },
                        data.addr,
                    });
                },
                .fpe => |fpe| try writer.print("{s}\n", .{switch (fpe) {
                    .division_by_zero => "division by zero",
                }}),
                .bkpt => |bkpt| try writer.print("{s}\n", .{switch (bkpt) {
                    .halt => "reached halt",
                    .dump => "reached dump",
                    .debugger => "debugger",
                }}),
                .pc => try writer.writeAll("invalid address\n"),
                else => try writer.writeAll("\n"),
            }

            var result: ?usize = null;
            var low: usize = 0;
            var high: usize = fmt.assembler.labels.count();
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (fmt.assembler.labels.values()[mid].instruction_index <= insn_index) {
                    result = mid;
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }

            if (fmt.source_label) |source_label| {
                try writer.print("{s}:", .{source_label});
            }

            try writer.print("{}:{}{s}{s} at 0x{x}:\n", .{
                line,
                1 + insn_start - line_start,
                if (result != null) " in " else "",
                if (result) |i| fmt.assembler.labels.keys()[i] else "",
                (Memory.text_start + fmt.vm.pc * 4),
            });
            try fmt.tty_config.setColor(writer, .reset);

            const line_end = if (std.mem.indexOfScalarPos(u8, fmt.assembler.lex.source, lex.index, '\n')) |nl_index| nl_index else fmt.assembler.lex.source.len;

            try writer.print("{s}\n", .{lex.source[line_start..line_end]});

            try writer.splatByteAll(' ', insn_start - line_start);
            try fmt.tty_config.setColor(writer, .bold);
            try fmt.tty_config.setColor(writer, .green);
            try writer.writeByte('^');
            try writer.splatByteAll('~', lex.index - insn_start -| 1);
            try fmt.tty_config.setColor(writer, .reset);
        }
    };
};

pub const Error = error{ExceptionThrown} || std.mem.Allocator.Error;

pub fn throwException(vm: *Vm, exception: Exception) Error!noreturn {
    vm.exception = exception;
    return error.ExceptionThrown;
}

fn fetchInstruction(vm: *Vm) ?Instruction {
    const bits = vm.memory.loadAlignedReadonlyMemory(vm.pc) catch return null;
    const insn: Instruction = @bitCast(bits);
    return insn;
}

pub fn execute(vm: *Vm) !void {
    var insn: Instruction = vm.fetchInstruction() orelse return;
    loop: switch (insn.getTag() orelse try vm.throwException(.instr)) {
        _ => unreachable,
        inline else => |tag| {
            try vm.executeOneInner(tag.get(), insn);
            insn = vm.fetchInstruction() orelse return;
            continue :loop insn.getTag() orelse try vm.throwException(.instr);
        },
    }
}

pub fn executeOne(vm: *Vm) !bool {
    const insn = vm.fetchInstruction() orelse return false;
    switch (insn.getTag() orelse try vm.throwException(.instr)) {
        _ => unreachable,
        inline else => |tag| try vm.executeOneInner(tag.get(), insn),
    }
    return true;
}

fn executeOneInner(vm: *Vm, comptime meta: Instruction.Codec, insn: Instruction) !void {
    switch (meta.tag) {
        _ => comptime unreachable,
        .add, .adds => {
            vm.registers[insn.r.rd] = vm.executeAdd(meta, vm.registers[insn.r.rn], vm.registers[insn.r.rm]);
        },
        .addi, .addis => {
            vm.registers[insn.i.rd] = vm.executeAdd(meta, vm.registers[insn.i.rn], insn.i.alu_immediate);
        },
        .@"and", .ands => {
            vm.registers[insn.r.rd] = vm.registers[insn.r.rn] & vm.registers[insn.r.rm];
        },
        .andi, .andis => {
            vm.registers[insn.i.rd] = vm.registers[insn.i.rn] & insn.i.alu_immediate;
        },
        .b => {
            vm.pc = signedIndexOffset(vm.pc, insn.b.br_address) orelse {
                try vm.throwException(.instr);
            };
            return;
        },
        .beq,
        .bne,
        .blt,
        .ble,
        .bgt,
        .bge,
        .blo,
        .bls,
        .bhi,
        .bhs,
        .bmi,
        .bpl,
        .bvs,
        .bvc,
        .cbnz,
        .cbz,
        => {
            const should_jump = switch (meta.tag) {
                .beq => vm.zero,
                .bne => !vm.zero,
                .blt => vm.negative != vm.overflow,
                .ble => !(!vm.zero and vm.negative == vm.overflow),
                .bgt => !vm.zero and vm.negative == vm.overflow,
                .bge => vm.negative == vm.overflow,
                .blo => !vm.carry,
                .bls => !(!vm.zero and vm.carry),
                .bhi => !vm.zero and vm.carry,
                .bhs => vm.carry,
                .bmi => vm.negative,
                .bpl => !vm.negative,
                .bvs => vm.overflow,
                .bvc => !vm.overflow,
                .cbnz => vm.registers[insn.cb.rt] != 0,
                .cbz => vm.registers[insn.cb.rt] == 0,
                else => comptime unreachable,
            };
            if (should_jump) {
                vm.pc = signedIndexOffset(vm.pc, @as(i64, insn.cb.cond_br_address)) orelse try vm.throwException(.pc);
                return;
            }
        },
        .bl => {
            vm.registers[30] = std.math.cast(i64, Memory.text_start + (vm.pc +| 1) * 4) orelse try vm.throwException(.pc);
            vm.pc = signedIndexOffset(vm.pc, @as(i64, insn.b.br_address)) orelse try vm.throwException(.pc);
            return;
        },
        .br => {
            vm.pc = std.math.cast(usize, std.math.divExact(i64, vm.registers[insn.r.rd] - Memory.text_start, 4) catch {
                try vm.throwException(.pc);
            }) orelse try vm.throwException(.pc);
            return;
        },
        .eor => {
            vm.registers[insn.r.rd] = vm.registers[insn.r.rn] ^ vm.registers[insn.r.rm];
        },
        .eori => {
            vm.registers[insn.i.rd] = vm.registers[insn.i.rn] ^ insn.i.alu_immediate;
        },
        .ldur, .ldxr => { // ldxr is supposed to be atomic, but you can't do unaligned atomic reads
            vm.registers[insn.d.rt] = try vm.loadMemory(i64, @bitCast(vm.registers[insn.d.rn] +| insn.d.dt_address));
        },
        .ldurb => {
            vm.registers[insn.d.rt] = try vm.loadMemory(u8, @bitCast(vm.registers[insn.d.rn] +| insn.d.dt_address));
        },
        .ldurh => {
            vm.registers[insn.d.rt] = try vm.loadMemory(u16, @bitCast(vm.registers[insn.d.rn] +| insn.d.dt_address));
        },
        .ldursw => {
            vm.registers[insn.d.rt] = try vm.loadMemory(i32, @bitCast(vm.registers[insn.d.rn] +| insn.d.dt_address));
        },
        .lsl => {
            vm.registers[insn.r.rd] = vm.registers[insn.r.rn] << insn.r.shamt;
        },
        .lsr => {
            vm.registers[insn.r.rd] = @bitCast(@as(u64, @bitCast(vm.registers[insn.r.rn])) >> insn.r.shamt);
        },
        .movz => {
            vm.registers[insn.iw.rd] = @bitCast(@as(u64, insn.iw.mov_immediate) << (@as(u6, insn.iw.shamtx16) * 16));
        },
        .movk => {
            const shift = @as(u6, insn.iw.shamtx16) * 16;
            const masked = @as(u64, @bitCast(vm.registers[insn.iw.rd])) & ~((@as(u64, ~@as(u16, 0))) << shift);
            const new_mask = (@as(u64, insn.iw.mov_immediate) << shift);
            vm.registers[insn.iw.rd] = @bitCast(masked | new_mask);
        },
        .orr => {
            vm.registers[insn.r.rd] = vm.registers[insn.r.rn] | vm.registers[insn.r.rm];
        },
        .orri => {
            vm.registers[insn.i.rd] = vm.registers[insn.i.rn] | insn.i.alu_immediate;
        },
        .stur => {
            try vm.storeMemory(
                i64,
                @bitCast(vm.registers[insn.d.rn] +| insn.d.dt_address),
                vm.registers[insn.d.rt],
            );
        },
        .sturb => {
            try vm.storeMemory(
                i8,
                @bitCast(vm.registers[insn.d.rn] +| insn.d.dt_address),
                @truncate(vm.registers[insn.d.rt]),
            );
        },
        .sturh => {
            try vm.storeMemory(
                i16,
                @bitCast(vm.registers[insn.d.rn] +| insn.d.dt_address),
                @truncate(vm.registers[insn.d.rt]),
            );
        },
        .sturw => {
            try vm.storeMemory(
                i32,
                @bitCast(vm.registers[insn.d.rn] +| insn.d.dt_address),
                @truncate(vm.registers[insn.d.rt]),
            );
        },
        .stxr => {
            // stxr is supposed to be atomic, but you can't do unaligned atomic writes
            try vm.storeMemory(
                i64,
                @bitCast(vm.registers[insn.d.rn]),
                vm.registers[insn.d.rt],
            );
            if (insn.d.dt_address >= vm.registers.len) {
                try vm.throwException(.instr);
            }
            vm.registers[insn.d.dt_address] = 0;
        },
        .sub, .subs => {
            vm.registers[insn.r.rd] = vm.executeSub(meta, vm.registers[insn.r.rn], vm.registers[insn.r.rm]);
        },
        .subi, .subis => {
            vm.registers[insn.i.rd] = vm.executeSub(meta, vm.registers[insn.i.rn], insn.i.alu_immediate);
        },
        .fadds => {
            vm.single_registers[insn.r.rd] = vm.single_registers[insn.r.rn] + vm.single_registers[insn.r.rm];
        },
        .faddd => {
            vm.double_registers[insn.r.rd] = vm.double_registers[insn.r.rn] + vm.double_registers[insn.r.rm];
        },
        .fcmps, .fcmpd => {
            const left, const right = switch (meta.tag) {
                .fcmps => .{ vm.single_registers[insn.r.rn], vm.single_registers[insn.r.rm] },
                .fcmpd => .{ vm.double_registers[insn.r.rn], vm.double_registers[insn.r.rm] },
                else => comptime unreachable,
            };

            // negative zero overflow carry
            // If neither is operand a NaN and Value1==Value2, FLAGS = 4'b0110;
            // If neither is operand a NaN and Valuel < Value2, FLAGS = 4'b1000;
            // If neither is operand a NaN and Value1 > Value2, FLAGS = 4'b0010;
            // If an operand is a Nan, operands are unordered
            if (left == right) {
                vm.negative = false;
                vm.zero = true;
                vm.overflow = true;
                vm.carry = false;
            } else if (left < right) {
                vm.negative = true;
                vm.zero = false;
                vm.overflow = false;
                vm.carry = false;
            } else if (left > right) {
                vm.negative = false;
                vm.zero = false;
                vm.overflow = true;
                vm.carry = false;
            } else {
                vm.negative = false;
                vm.zero = false;
                vm.carry = true;
                vm.overflow = true;
            }
        },
        .fdivs => {
            vm.single_registers[insn.r.rd] = try vm.executeDivFloat(f32, vm.single_registers[insn.r.rn], vm.single_registers[insn.r.rm]);
        },
        .fdivd => {
            vm.double_registers[insn.r.rd] = try vm.executeDivFloat(f64, vm.double_registers[insn.r.rn], vm.double_registers[insn.r.rm]);
        },
        .fmuls => {
            vm.single_registers[insn.r.rd] = vm.single_registers[insn.r.rn] * vm.single_registers[insn.r.rm];
        },
        .fmuld => {
            vm.double_registers[insn.r.rd] = vm.double_registers[insn.r.rn] * vm.double_registers[insn.r.rm];
        },
        .fsubs => {
            vm.single_registers[insn.r.rd] = vm.single_registers[insn.r.rn] - vm.single_registers[insn.r.rm];
        },
        .fsubd => {
            vm.double_registers[insn.r.rd] = vm.double_registers[insn.r.rn] - vm.double_registers[insn.r.rm];
        },
        .ldurs => {
            vm.single_registers[insn.d.rt] = try vm.loadMemory(f32, @bitCast(vm.registers[insn.d.rn] + insn.d.dt_address));
        },
        .ldurd => {
            vm.double_registers[insn.d.rt] = try vm.loadMemory(f64, @bitCast(vm.registers[insn.d.rn] + insn.d.dt_address));
        },
        .mul => {
            vm.registers[insn.r.rd] = vm.registers[insn.r.rn] *% vm.registers[insn.r.rm];
        },
        .sdiv => {
            vm.registers[insn.r.rd] = std.math.divTrunc(i64, vm.registers[insn.r.rn], vm.registers[insn.r.rm]) catch {
                try vm.throwException(.{ .fpe = .division_by_zero });
            };
        },
        .smulh => {
            const full = @as(i128, vm.registers[insn.r.rn]) * @as(i128, vm.registers[insn.r.rm]);
            vm.registers[insn.r.rd] = @intCast(full >> 64);
        },
        .sturs => {
            try vm.storeMemory(
                f32,
                @bitCast(vm.registers[insn.d.rn] +% insn.d.dt_address),
                vm.single_registers[insn.d.rt],
            );
        },
        .sturd => {
            try vm.storeMemory(
                f64,
                @bitCast(vm.registers[insn.d.rn] +% insn.d.dt_address),
                vm.double_registers[insn.d.rt],
            );
        },
        .udiv => {
            const result = std.math.divTrunc(u64, @bitCast(vm.registers[insn.r.rn]), @bitCast(vm.registers[insn.r.rm])) catch {
                try vm.throwException(.{ .fpe = .division_by_zero });
            };
            vm.registers[insn.r.rd] = @bitCast(result);
        },
        .umulh => {
            const full = @as(u128, @as(u64, @bitCast(vm.registers[insn.r.rn]))) * @as(u128, @as(u64, @bitCast(vm.registers[insn.r.rm])));
            vm.registers[insn.r.rd] = @bitCast(@as(u64, @intCast(full >> 64)));
        },
        // Non-standard instructions
        .halt => {
            try vm.throwException(.{ .bkpt = .halt });
        },
        .dump => {
            std.log.info("dump!", .{});
        },
        .prnt => {
            try vm.printRegister(switch (insn.r.rn) {
                0 => .{ .x = insn.r.rd },
                1 => .{ .s = insn.r.rd },
                2 => .{ .d = insn.r.rd },
                else => try vm.throwException(.instr),
            });
            try vm.output.writeByte('\n');
            try vm.output.flush();
        },
        .prnl => {
            try vm.output.writeByte('\n');
            try vm.output.flush();
        },
        .time => vm.registers[insn.r.rd] = std.time.milliTimestamp(),
    }

    if (meta.flags) {
        switch (meta.format) {
            .r => |r| {
                if (r.shamt == null) {
                    vm.negative = vm.registers[insn.r.rd] < 0;
                    vm.zero = vm.registers[insn.r.rd] == 0;
                }
            },
            .i => {
                vm.negative = vm.registers[insn.r.rd] < 0;
                vm.zero = vm.registers[insn.r.rd] == 0;
            },
            else => comptime unreachable,
        }
    }
    if (meta.format != .b and meta.format != .cb) {
        vm.registers[31] = 0;
    }
    vm.pc += 1;
}

pub const Register = union(enum(u8)) {
    x: u5,
    s: u5,
    d: u5,
};

pub fn printRegister(vm: *Vm, register: Register) (std.Io.Writer.Error || std.Io.tty.Config.SetColorError)!void {
    try vm.tty_config.setColor(vm.output, .green);
    switch (register) {
        inline else => |payload, tag| try vm.output.print([_]u8{std.ascii.toUpper(@tagName(tag)[0])} ++ "{d}: ", .{payload}),
    }
    try vm.tty_config.setColor(vm.output, .reset);

    switch (register) {
        .x => |x| {
            try vm.tty_config.setColor(vm.output, .blue);
            try vm.output.print("{1s}{0x:0>16}", .{
                @as(u64, @bitCast(vm.registers[x])),
                if (vm.registers[x] != 0) "0x" else "00",
            });
            try vm.tty_config.setColor(vm.output, .reset);
            try vm.output.writeAll(" (");
            try vm.tty_config.setColor(vm.output, .blue);
            try vm.output.print("{d}", .{@as(u64, @bitCast(vm.registers[x]))});
            try vm.tty_config.setColor(vm.output, .reset);
            try vm.output.writeAll(")");
        },
        .s => |s| {
            try vm.tty_config.setColor(vm.output, .blue);
            try vm.output.print("{e}", .{vm.single_registers[s]});
            try vm.tty_config.setColor(vm.output, .reset);
            try vm.output.writeAll(" (");
            try vm.tty_config.setColor(vm.output, .blue);
            try vm.output.print("{}", .{vm.single_registers[s]});
            try vm.tty_config.setColor(vm.output, .reset);
            try vm.output.writeAll(")");
        },
        .d => |d| {
            try vm.tty_config.setColor(vm.output, .blue);
            try vm.output.print("{e}", .{vm.double_registers[d]});
            try vm.tty_config.setColor(vm.output, .reset);
            try vm.output.writeAll(" (");
            try vm.tty_config.setColor(vm.output, .blue);
            try vm.output.print("{}", .{vm.double_registers[d]});
            try vm.tty_config.setColor(vm.output, .reset);
            try vm.output.writeAll(")");
        },
    }
}

fn loadMemory(vm: *Vm, comptime T: type, addr: u64) Error!T {
    return vm.memory.load(T, addr) catch |e| switch (e) {
        error.InvalidAddress => try vm.throwException(.{ .data = .{
            .kind = .load,
            .addr = @bitCast(addr),
        } }),
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn storeMemory(vm: *Vm, comptime T: type, addr: u64, value: T) Error!void {
    vm.memory.store(T, addr, value) catch |e| switch (e) {
        error.InvalidAddress => try vm.throwException(.{ .data = .{
            .kind = .store,
            .addr = @bitCast(addr),
        } }),
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn signedIndexOffset(index: usize, offset: i64) ?usize {
    if (offset < 0) {
        return std.math.sub(
            usize,
            index,
            std.math.cast(usize, std.math.negate(offset) catch return null) orelse return null,
        ) catch null;
    } else {
        return std.math.add(
            usize,
            index,
            std.math.cast(usize, offset) orelse return null,
        ) catch null;
    }
}

fn executeAdd(vm: *Vm, comptime meta: Instruction.Codec, a: i64, b: i64) i64 {
    const result, const overflow = @addWithOverflow(a, b);
    const result2, const carry = @addWithOverflow(@as(u64, @bitCast(a)), @as(u64, @bitCast(b)));
    std.debug.assert(result == @as(i64, @bitCast(result2)));
    if (meta.flags) {
        vm.overflow = overflow == 1;
        vm.carry = carry == 1;
    }
    return result;
}

fn executeSub(vm: *Vm, comptime meta: Instruction.Codec, a: i64, b: i64) i64 {
    const result, const overflow = @subWithOverflow(a, b);
    const result2, const carry = @subWithOverflow(@as(u64, @bitCast(a)), @as(u64, @bitCast(b)));
    std.debug.assert(result == @as(i64, @bitCast(result2)));
    if (meta.flags) {
        vm.overflow = overflow == 1;
        vm.carry = carry == 1;
    }
    return result;
}

fn executeDivFloat(vm: *Vm, comptime T: type, a: T, b: T) Error!T {
    if (b == 0) {
        try vm.throwException(.{ .fpe = .division_by_zero });
    }
    return a / b;
}
