const std = @import("std");

pub const Instruction = packed union {
    r: R,
    i: I,
    d: D,
    b: B,
    cb: Cb,
    iw: Iw,

    comptime {
        std.debug.assert(@sizeOf(Instruction) == @sizeOf(u32));
        std.debug.assert(@alignOf(Instruction) == @alignOf(u32));
        std.debug.assert(@bitSizeOf(Instruction) == @bitSizeOf(u32));
    }

    pub fn getOpcode(insn: Instruction) u11 {
        const bits: *const u32 = @ptrCast(&insn);
        return @intCast(bits.* >> 21);
    }

    // Improves instruction decoding for most programs by ~40%.
    const null_tag: Codec.Tag = @enumFromInt(std.math.maxInt(u8));
    const fast_lookup = blk: {
        var buf: [std.math.maxInt(u11) + 1]Codec.Tag = @splat(null_tag);
        for (Instruction.Codec.list) |codec| {
            if ((codec.format != .r or codec.format.r.shamt == null) and
                (codec.format != .cb or codec.format.cb.op == null))
            {
                for (buf[codec.opcode_range.start .. @as(usize, codec.opcode_range.end) + 1]) |*tag| {
                    std.debug.assert(tag.* == null_tag);
                    tag.* = codec.tag;
                }
            }
        }
        break :blk buf;
    };

    pub fn getTag(instruction: Instruction) ?Instruction.Codec.Tag {
        const opcode = instruction.getOpcode();

        const maybe_tag = fast_lookup[opcode];
        if (maybe_tag != null_tag) {
            return maybe_tag;
        }

        inline for (Instruction.Codec.list) |codec| {
            if ((comptime (fast_lookup[codec.opcode_range.start] == null_tag)) and
                opcode >= codec.opcode_range.start and opcode <= codec.opcode_range.end and
                (codec.format != .r or codec.format.r.shamt == null or instruction.r.shamt == codec.format.r.shamt.?) and
                (codec.format != .cb or codec.format.cb.op == null or instruction.cb.rt == codec.format.cb.op.?))
            {
                return codec.tag;
            }
        }

        return null;
    }

    pub fn setTag(instruction: *Instruction, tag: Instruction.Codec.Tag) void {
        const codec = tag.get();
        switch (codec.format) {
            .r => |r| if (r.shamt) |shamt| {
                instruction.r.shamt = shamt;
            },
            .cb => |cb| if (cb.op) |op| {
                instruction.cb.rt = op;
            },
            else => {},
        }
        switch (codec.format) {
            inline else => |_, format| {
                const format_name = @tagName(format);
                @field(instruction, format_name).opcode = @intCast(codec.opcode_range.start >>
                    (@bitSizeOf(@TypeOf(codec.opcode_range.start)) -
                        @bitSizeOf(@TypeOf(@field(instruction, format_name).opcode))));
            },
        }
    }

    pub const R = packed struct(u32) {
        rd: u5,
        rn: u5,
        shamt: u6,
        rm: u5,
        opcode: u11,
    };

    pub const I = packed struct(u32) {
        rd: u5,
        rn: u5,
        alu_immediate: i12,
        opcode: u10,
    };

    pub const D = packed struct(u32) {
        rt: u5,
        rn: u5,
        op: u2,
        dt_address: u9,
        opcode: u11,
    };

    pub const B = packed struct(u32) {
        br_address: i26,
        opcode: u6,
    };

    pub const Cb = packed struct(u32) {
        rt: u5,
        cond_br_address: i19,
        opcode: u8,
    };

    pub const Iw = packed struct(u32) {
        rd: u5,
        mov_immediate: u16,
        shamtx16: u2,
        opcode: u9,
    };

    pub const Codec = struct {
        tag: Tag,
        format: Format,
        opcode_range: OpcodeRange,
        flags: bool,
        mneumonics: []const []const u8,
        description: []const u8,

        pub const Tag = enum(u8) {
            add,
            addi,
            addis,
            adds,
            @"and",
            andi,
            andis,
            ands,
            b,
            beq,
            bne,
            blt,
            ble,
            bgt,
            bge,
            blo,
            bls,
            bhi,
            bhs,
            bmi,
            bpl,
            bvs,
            bvc,
            bl,
            br,
            cbnz,
            cbz,
            eor,
            eori,
            ldur,
            ldurb,
            ldurh,
            ldursw,
            ldxr,
            lsl,
            lsr,
            movk,
            movz,
            orr,
            orri,
            stur,
            sturb,
            sturh,
            sturw,
            stxr,
            sub,
            subi,
            subis,
            subs,
            fadds,
            faddd,
            fcmps,
            fcmpd,
            fdivs,
            fdivd,
            fmuls,
            fmuld,
            fsubs,
            fsubd,
            ldurs,
            ldurd,
            mul,
            sdiv,
            smulh,
            sturs,
            sturd,
            udiv,
            umulh,
            // Non-standard instructions
            halt,
            dump,
            prnt,
            prnl,
            time,
            _,

            pub fn get(tag: Tag) Codec {
                return list[@intFromEnum(tag)];
            }

            pub const map = blk: {
                var len: usize = 0;
                for (list) |codec| {
                    len += codec.mneumonics.len;
                }

                var entries: [len]struct { []const u8, Tag } = undefined;
                for (list) |codec| {
                    for (codec.mneumonics) |mneumonic| {
                        len -= 1;
                        entries[len] = .{ mneumonic, codec.tag };
                    }
                }

                break :blk std.StaticStringMap(Tag).initComptime(entries);
            };
        };

        /// An inclusive range of the 11 most-significant bits of the instruction.
        pub const OpcodeRange = struct {
            start: u11,
            end: u11,

            pub fn init(start: u11, end: u11) OpcodeRange {
                return .{ .start = start, .end = end };
            }

            pub fn initSingle(val: u11) OpcodeRange {
                return .{ .start = val, .end = val };
            }

            pub fn contains(range: OpcodeRange, value: u11) bool {
                return value >= range.start and value <= range.end;
            }
        };

        pub fn init(
            tag: Tag,
            format: Format,
            opcode_range: OpcodeRange,
            flags: bool,
            mneumonics: []const []const u8,
            description: []const u8,
        ) Codec {
            return .{
                .tag = tag,
                .format = format,
                .opcode_range = opcode_range,
                .flags = flags,
                .mneumonics = mneumonics,
                .description = description,
            };
        }

        pub const Format = union(enum) {
            r: struct {
                shamt: ?u6 = null,
                style: enum {
                    @"Xn, Xn, Xn",
                    @"Sn, Sn, Sn",
                    @"Dn, Dn, Dn",
                    @"Xn, Xn, Shamt",
                    Xn,
                    @"Sn, Sn",
                    @"Dn, Dn",
                    empty,
                    time,
                    prnt,
                } = .@"Xn, Xn, Xn",
            },
            i,
            d: struct {
                style: enum {
                    @"Xn, [Xn, #]",
                    @"Xn, Xn, [Xn]",
                    @"Sn, [Xn, #]",
                    @"Dn, [Xn, #]",
                } = .@"Xn, [Xn, #]",
            },
            b,
            cb: struct { op: ?u4 },
            iw,

            pub const non_alu_r: Format = .{ .r = .{} };

            pub fn format(fmt: Format, writer: *std.io.Writer) !void {
                switch (fmt) {
                    .r => |r| {
                        try writer.writeAll("R-type instruction");
                        if (r.shamt) |shamt| {
                            try writer.print(" (shamt=0x{x})", .{shamt});
                        }
                    },
                    .i => try writer.writeAll("I-type instruction"),
                    .d => try writer.writeAll("D-type instruction"),
                    .b => try writer.writeAll("B-type instruction"),
                    .cb => |cb| {
                        try writer.writeAll("CB-type instruction");
                        if (cb.op) |op| {
                            try writer.print(" (op=0b{d})", .{op});
                        }
                    },
                    .iw => try writer.writeAll("IW-type instruction"),
                }
            }
        };

        pub const list = std.enums.directEnumArray(Tag, Codec, 0, .{
            .add = .init(.add, .non_alu_r, .initSingle(0x458), false, &.{"ADD"}, "ADD"),
            .addi = .init(.addi, .i, .init(0x488, 0x489), false, &.{"ADDI"}, "ADD Immediate"),
            .addis = .init(.addis, .i, .init(0x588, 0x589), true, &.{"ADDIS"}, "ADD Immediate & Set flags"),
            .adds = .init(.adds, .non_alu_r, .initSingle(0x558), true, &.{"ADDS"}, "ADD & Set flags"),
            .@"and" = .init(.@"and", .non_alu_r, .initSingle(0x450), false, &.{"AND"}, "AND"),
            .andi = .init(.andi, .i, .init(0x490, 0x491), false, &.{"ANDI"}, "AND Immediate"),
            .andis = .init(.andis, .i, .init(0x790, 0x791), true, &.{"ANDIS"}, "AND Immediate & Set flags"),
            .ands = .init(.ands, .non_alu_r, .initSingle(0x750), true, &.{"ANDS"}, "AND & Set flags"),
            .b = .init(.b, .b, .init(0x0A0, 0x0BF), false, &.{"B"}, "Branch"),
            .beq = .init(.beq, .{ .cb = .{ .op = 0 } }, .init(0x2A0, 0x2A7), false, &.{ "B.EQ", "BEQ" }, "Branch if Equal"),
            .bne = .init(.bne, .{ .cb = .{ .op = 1 } }, .init(0x2A0, 0x2A7), false, &.{ "B.NE", "BNE" }, "Branch if Not Equal"),
            .bhs = .init(.bhs, .{ .cb = .{ .op = 2 } }, .init(0x2A0, 0x2A7), false, &.{ "B.HS", "BHS" }, "Branch if Greater Than or Equal (Unsigned)"),
            .blo = .init(.blo, .{ .cb = .{ .op = 3 } }, .init(0x2A0, 0x2A7), false, &.{ "B.LO", "BLO" }, "Branch if Less Than (Unsigned)"),
            .bmi = .init(.bmi, .{ .cb = .{ .op = 4 } }, .init(0x2A0, 0x2A7), false, &.{ "B.MI", "BMI" }, "Branch if Minus"),
            .bpl = .init(.bpl, .{ .cb = .{ .op = 5 } }, .init(0x2A0, 0x2A7), false, &.{ "B.PL", "BPL" }, "Branch if Plus"),
            .bvs = .init(.bvs, .{ .cb = .{ .op = 6 } }, .init(0x2A0, 0x2A7), false, &.{ "B.VS", "BVS" }, "Branch if Overflow Set"),
            .bvc = .init(.bvc, .{ .cb = .{ .op = 7 } }, .init(0x2A0, 0x2A7), false, &.{ "B.VC", "BVC" }, "Branch if Overflow Clear"),
            .bhi = .init(.bhi, .{ .cb = .{ .op = 8 } }, .init(0x2A0, 0x2A7), false, &.{ "B.HI", "BHI" }, "Branch if Greater Than (Unsigned)"),
            .bls = .init(.bls, .{ .cb = .{ .op = 9 } }, .init(0x2A0, 0x2A7), false, &.{ "B.LS", "BLS" }, "Branch if Less Than or Equal (Unsigned)"),
            .bge = .init(.bge, .{ .cb = .{ .op = 10 } }, .init(0x2A0, 0x2A7), false, &.{ "B.GE", "BGE" }, "Branch if Greater Than or Equal"),
            .blt = .init(.blt, .{ .cb = .{ .op = 11 } }, .init(0x2A0, 0x2A7), false, &.{ "B.LT", "BLT" }, "Branch if Less Than"),
            .bgt = .init(.bgt, .{ .cb = .{ .op = 12 } }, .init(0x2A0, 0x2A7), false, &.{ "B.GT", "BGT" }, "Branch if Greater Than"),
            .ble = .init(.ble, .{ .cb = .{ .op = 13 } }, .init(0x2A0, 0x2A7), false, &.{ "B.LE", "BLE" }, "Branch if Less Than or Equal"),
            .bl = .init(.bl, .b, .init(0x4A0, 0x4BF), false, &.{"BL"}, "Branch with Link"),
            .br = .init(.br, .{ .r = .{ .style = .Xn } }, .initSingle(0x6B0), false, &.{"BR"}, "Branch to Register"),
            .cbnz = .init(.cbnz, .{ .cb = .{ .op = null } }, .init(0x5A8, 0x5AF), false, &.{"CBNZ"}, "Compare & Branch if Not Zero"),
            .cbz = .init(.cbz, .{ .cb = .{ .op = null } }, .init(0x5A0, 0x5A7), false, &.{"CBZ"}, "Compare & Branch if Zero"),
            .eor = .init(.eor, .non_alu_r, .initSingle(0x650), false, &.{"EOR"}, "Exclusive OR"),
            .eori = .init(.eori, .i, .init(0x690, 0x691), false, &.{"EORI"}, "Exclusive OR Immediate"),
            .ldur = .init(.ldur, .{ .d = .{} }, .initSingle(0x7C2), false, &.{"LDUR"}, "LoaD Register Unscaled offset"),
            .ldurb = .init(.ldurb, .{ .d = .{} }, .initSingle(0x1C2), false, &.{"LDURB"}, "LoaD Byte Unscaled offset"),
            .ldurh = .init(.ldurh, .{ .d = .{} }, .initSingle(0x3C2), false, &.{"LDURH"}, "LoaD Half Unscaled offset"),
            .ldursw = .init(.ldursw, .{ .d = .{} }, .initSingle(0x5C4), false, &.{"LDURSW"}, "LoaD Signed Word Unscaled offset"),
            .ldxr = .init(.ldxr, .{ .d = .{} }, .initSingle(0x642), false, &.{"LDXR"}, "LoaD eXclusive Register"),
            .lsl = .init(.lsl, .{ .r = .{ .style = .@"Xn, Xn, Shamt" } }, .initSingle(0x69B), false, &.{"LSL"}, "Logical Shift Left"),
            .lsr = .init(.lsr, .{ .r = .{ .style = .@"Xn, Xn, Shamt" } }, .initSingle(0x69A), false, &.{"LSR"}, "Logical Shift Right"),
            .movk = .init(.movk, .iw, .init(0x794, 0x797), false, &.{"MOVK"}, "MOVe wide with Keep"),
            .movz = .init(.movz, .iw, .init(0x694, 0x697), false, &.{"MOVZ"}, "MOVe wide with Zero"),
            .orr = .init(.orr, .non_alu_r, .initSingle(0x550), false, &.{"ORR"}, "Inclusive OR"),
            .orri = .init(.orri, .i, .init(0x590, 0x591), false, &.{"ORRI"}, "Inclusive OR Immediate"),
            .stur = .init(.stur, .{ .d = .{} }, .initSingle(0x7C0), false, &.{"STUR"}, "STore Register Unscaled offset"),
            .sturb = .init(.sturb, .{ .d = .{} }, .initSingle(0x1C0), false, &.{"STURB"}, "STore Byte Unscaled offset"),
            .sturh = .init(.sturh, .{ .d = .{} }, .initSingle(0x3C0), false, &.{"STURH"}, "STore Half Unscaled offset"),
            .sturw = .init(.sturw, .{ .d = .{} }, .initSingle(0x5C0), false, &.{"STURW"}, "STore Word Unscaled offset"),
            .stxr = .init(.stxr, .{ .d = .{ .style = .@"Xn, Xn, [Xn]" } }, .initSingle(0x640), false, &.{"STXR"}, "STore eXclusive Register"),
            .sub = .init(.sub, .non_alu_r, .initSingle(0x658), false, &.{"SUB"}, "SUBtract"),
            .subi = .init(.subi, .i, .init(0x688, 0x689), false, &.{"SUBI"}, "SUBtract Immediate"),
            .subis = .init(.subis, .i, .init(0x788, 0x789), true, &.{"SUBIS"}, "SUBtract Immediate & Set flags"),
            .subs = .init(.subs, .non_alu_r, .initSingle(0x758), true, &.{"SUBS"}, "SUBtract & Set flags"),
            .fadds = .init(.fadds, .{ .r = .{ .shamt = 0x0A, .style = .@"Sn, Sn, Sn" } }, .initSingle(0x0F1), false, &.{"FADDS"}, "Floating-point ADD Single"),
            .faddd = .init(.faddd, .{ .r = .{ .shamt = 0x0A, .style = .@"Dn, Dn, Dn" } }, .initSingle(0x0F3), false, &.{"FADDD"}, "Floating-point ADD Double"),
            .fcmps = .init(.fcmps, .{ .r = .{ .shamt = 0x08, .style = .@"Sn, Sn" } }, .initSingle(0x0F1), true, &.{"FCMPS"}, "Floating-point CoMPare Single"),
            .fcmpd = .init(.fcmpd, .{ .r = .{ .shamt = 0x08, .style = .@"Dn, Dn" } }, .initSingle(0x0F3), true, &.{"FCMPD"}, "Floating-point CoMPare Double"),
            .fdivs = .init(.fdivs, .{ .r = .{ .shamt = 0x06, .style = .@"Sn, Sn, Sn" } }, .initSingle(0x0F1), false, &.{"FDIVS"}, "Floating-point DIVide Single"),
            .fdivd = .init(.fdivd, .{ .r = .{ .shamt = 0x06, .style = .@"Dn, Dn, Dn" } }, .initSingle(0x0F3), false, &.{"FDIVD"}, "Floating-point DIVide Double"),
            .fmuls = .init(.fmuls, .{ .r = .{ .shamt = 0x02, .style = .@"Sn, Sn, Sn" } }, .initSingle(0x0F1), false, &.{"FMULS"}, "Floating-point MULtiply Single"),
            .fmuld = .init(.fmuld, .{ .r = .{ .shamt = 0x02, .style = .@"Dn, Dn, Dn" } }, .initSingle(0x0F3), false, &.{"FMULD"}, "Floating-point MULtiply Double"),
            .fsubs = .init(.fsubs, .{ .r = .{ .shamt = 0x0E, .style = .@"Sn, Sn, Sn" } }, .initSingle(0x0F1), false, &.{"FSUBS"}, "Floating-point SUBtract Single"),
            .fsubd = .init(.fsubd, .{ .r = .{ .shamt = 0x0E, .style = .@"Dn, Dn, Dn" } }, .initSingle(0x0F3), false, &.{"FSUBD"}, "Floating-point SUBtract Double"),
            .ldurs = .init(.ldurs, .{ .d = .{ .style = .@"Sn, [Xn, #]" } }, .initSingle(0x5E2), false, &.{"LDURS"}, "LoaD Single floating-point"),
            .ldurd = .init(.ldurd, .{ .d = .{ .style = .@"Dn, [Xn, #]" } }, .initSingle(0x7E2), false, &.{"LDURD"}, "LoaD Double floating-point"),
            .mul = .init(.mul, .{ .r = .{ .shamt = 0x1F } }, .initSingle(0x4D8), false, &.{"MUL"}, "MULtiply"),
            .sdiv = .init(.sdiv, .{ .r = .{ .shamt = 0x02 } }, .initSingle(0x4D6), false, &.{"SDIV"}, "Signed DIVide"),
            .smulh = .init(.smulh, .non_alu_r, .initSingle(0x4DA), false, &.{"SMULH"}, "Signed MULtiply High"),
            .sturs = .init(.sturs, .{ .d = .{ .style = .@"Sn, [Xn, #]" } }, .initSingle(0x5E0), false, &.{"STURS"}, "STore Single floating-point"),
            .sturd = .init(.sturd, .{ .d = .{ .style = .@"Dn, [Xn, #]" } }, .initSingle(0x7E0), false, &.{"STURD"}, "STore Double floating-point"),
            .udiv = .init(.udiv, .{ .r = .{ .shamt = 0x03 } }, .initSingle(0x4D6), false, &.{"UDIV"}, "Unsigned DIVide"),
            .umulh = .init(.umulh, .non_alu_r, .initSingle(0x4DE), false, &.{"UMULH"}, "Unsigned MULtiply High"),
            // Non-standard instructions
            .halt = .init(.halt, .{ .r = .{ .shamt = null, .style = .empty } }, .initSingle(0x7FF), false, &.{"HALT"}, "HALT execution (non-standard)"),
            .dump = .init(.dump, .{ .r = .{ .shamt = null, .style = .empty } }, .initSingle(0x7FE), false, &.{"DUMP"}, "DUMP state (non-standard)"),
            .prnt = .init(.prnt, .{ .r = .{ .shamt = null, .style = .prnt } }, .initSingle(0x7FD), false, &.{"PRNT"}, "PRiNT register (non-standard)"),
            .prnl = .init(.prnl, .{ .r = .{ .shamt = null, .style = .empty } }, .initSingle(0x7FC), false, &.{"PRNL"}, "PRint NewLine (non-standard)"),
            .time = .init(.time, .{ .r = .{ .shamt = null, .style = .time } }, .initSingle(0x7FB), false, &.{"TIME"}, "TIME now (non-standard)"),
        });
    };
};

test "overlapping codecs" {
    for (Instruction.Codec.list[0 .. Instruction.Codec.list.len - 1], 0..) |first, i| {
        for (Instruction.Codec.list[i + 1 ..]) |second| {
            const overlapping =
                first.opcode_range.contains(second.opcode_range.start) and
                first.opcode_range.contains(second.opcode_range.end);
            const different_r = first.format == .r and first.format.r.shamt != null and
                second.format == .r and first.format.r.shamt != second.format.r.shamt;
            const different_cb = first.format == .cb and first.format.cb.op != null and
                second.format == .cb and first.format.cb.op != second.format.cb.op;

            if (overlapping and different_r and different_cb) {
                std.log.err("{}", .{(first.format == .cb and first.format.cb.op != null and
                    second.format == .cb and first.format.cb.op == second.format.cb.op)});
                std.log.err("overlapping {} and {}", .{ first, second });
                try std.testing.expect(false);
            }
        }
    }
}

test "codec tags match" {
    for (Instruction.Codec.list, 0..) |codec, index| {
        try std.testing.expectEqual(@as(Instruction.Codec.Tag, @enumFromInt(index)), codec.tag);
    }
}

test "oracle encoding" {
    const oracle: []const struct { Instruction.Codec.Tag, u11 } = &.{
        .{ .add, 0b10001011000 },
        .{ .addi, 0b1001000100 },
        .{ .addis, 0b1011000100 },
        .{ .adds, 0b10101011000 },
        .{ .@"and", 0b10001010000 },
        .{ .andi, 0b1001001000 },
        .{ .andis, 0b1111001000 },
        // .{ .ands, 0b1110101000 }, // Incorrect!
        .{ .ands, 0b11101010000 },
        .{ .b, 0b000101 },
        .{ .bl, 0b100101 },
        .{ .br, 0b11010110000 },
        .{ .cbnz, 0b10110101 },
        .{ .cbz, 0b10110100 },
        .{ .dump, 0b11111111110 },
        .{ .eor, 0b11001010000 },
        .{ .eori, 0b1101001000 },
        .{ .faddd, 0b00011110011 },
        .{ .fadds, 0b00011110001 },
        .{ .fcmpd, 0b00011110011 },
        .{ .fcmps, 0b00011110001 },
        .{ .fdivd, 0b00011110011 },
        .{ .fdivs, 0b00011110001 },
        .{ .fmuld, 0b00011110011 },
        .{ .fmuls, 0b00011110001 },
        .{ .fsubd, 0b00011110011 },
        .{ .fsubs, 0b00011110001 },
        .{ .halt, 0b11111111111 },
        .{ .ldur, 0b11111000010 },
        .{ .ldurb, 0b00111000010 },
        .{ .ldurd, 0b11111100010 },
        .{ .ldurh, 0b01111000010 },
        .{ .ldurs, 0b10111100010 },
        .{ .ldursw, 0b10111000100 },
        .{ .lsl, 0b11010011011 },
        .{ .lsr, 0b11010011010 },
        .{ .mul, 0b10011011000 },
        .{ .orr, 0b10101010000 },
        .{ .orri, 0b1011001000 },
        .{ .prnl, 0b11111111100 },
        .{ .prnt, 0b11111111101 },
        .{ .sdiv, 0b10011010110 },
        .{ .smulh, 0b10011011010 },
        .{ .stur, 0b11111000000 },
        .{ .sturb, 0b00111000000 },
        .{ .sturd, 0b11111100000 },
        .{ .sturh, 0b01111000000 },
        .{ .sturs, 0b10111100000 },
        // .{ .stursw, 0b10111000000 },
        .{ .sub, 0b11001011000 },
        .{ .subi, 0b1101000100 },
        .{ .subis, 0b1111000100 },
        .{ .subs, 0b11101011000 },
        .{ .udiv, 0b10011010110 },
        .{ .umulh, 0b10011011110 },
    };

    for (oracle) |val| {
        var insn: Instruction = @bitCast(@as(u32, 0));
        insn.setTag(val.@"0");
        switch (val.@"0".get().format) {
            inline else => |_, f| {
                const opcode = @field(insn, @tagName(f)).opcode;
                const equal = val.@"1" == opcode;
                if (!equal) {
                    std.log.err("{}", .{val});
                }
                try std.testing.expectEqual(opcode, val.@"1");
            },
        }
    }
}
