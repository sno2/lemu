//! Not really fuzzing: just random program generation.

const std = @import("std");

const lemu = @import("lemu");

pub fn main() !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const lemu_exe = args[1];
    const legv8emul_exe = args[2];
    const file_path = args[3];
    const maybe_seed = args[4];

    var seed: u64 = undefined;
    if (!std.mem.eql(u8, maybe_seed, "none")) {
        seed = try std.fmt.parseInt(u64, maybe_seed, 0);
    } else {
        var buf: [8]u8 = undefined;
        try std.posix.getrandom(&buf);
        seed = @as(*align(1) u64, @ptrCast(buf[0..8])).*;
    }

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();

    std.log.info("fuzz seed = 0x{x}", .{seed});
    std.log.info("{s}", .{file_path});

    var file_buf: [200]u8 = undefined;
    while (true) {
        var file_writer = file.writer(&file_buf);

        var used_registers: std.bit_set.IntegerBitSet(32) = .initEmpty();

        const len = rand.int(u8) % 20 + 1;
        var label_i: usize = 0;
        var i: usize = 0;
        while (i < len) {
            const tag = rand.enumValue(lemu.Instruction.Codec.Tag);
            switch (tag) {
                // These are not implemented in legv8emul.
                .faddd,
                .smulh,
                .umulh,
                .stxr,
                .ldxr,
                .sturw,
                // These are not implemented correctly in legv8emul.
                .udiv,
                .lsr,
                .ldursw,
                .ldurb,
                // These are too hard to fuzz.
                .time,
                .br,
                => continue,
                else => {},
            }

            const codec = tag.get();

            switch (codec.format) {
                .r => |r| {
                    switch (r.style) {
                        .@"Xn, Xn, Xn" => {
                            const r1 = rand.int(u8) % 28;
                            const r2 = rand.int(u8) % 28;
                            const r3 = rand.int(u8) % 28;
                            used_registers.set(r1);
                            used_registers.set(r2);
                            used_registers.set(r3);

                            switch (tag) {
                                .sdiv, .udiv => {
                                    try file_writer.interface.print(
                                        \\CBNZ X{0d}, L{1d} // ensure divisor non-zero
                                        \\ADDI X{0d}, X{0d}, #{2d}
                                        \\L{1d}:
                                        \\
                                    , .{ r3, label_i, @max(rand.int(i12), 1) });
                                    label_i += 1;
                                },
                                else => {},
                            }

                            try file_writer.interface.print("{s} X{d}, X{d}, X{d}", .{ codec.mneumonics[0], r1, r2, r3 });
                        },
                        .@"Xn, Xn, Shamt" => {
                            const r1 = rand.int(u8) % 28;
                            const r2 = rand.int(u8) % 28;
                            const shift = rand.int(u6);
                            used_registers.set(r1);
                            used_registers.set(r2);

                            try file_writer.interface.print("{s} X{d}, X{d}, #{d}", .{ codec.mneumonics[0], r1, r2, shift });
                        },
                        .Xn => {
                            const r1 = rand.int(u8) % 28;
                            used_registers.set(r1);

                            try file_writer.interface.print("{s} X{d}", .{ codec.mneumonics[0], r1 });
                        },
                        else => continue,
                    }
                },
                .i => {
                    const r1 = rand.int(u8) % 28;
                    const r2 = rand.int(u8) % 28;
                    used_registers.set(r1);
                    used_registers.set(r2);
                    const immediate = rand.int(i12);

                    try file_writer.interface.print("{s} X{d}, X{d}, #{d}", .{ codec.mneumonics[0], r1, r2, immediate });
                },
                .d => |d| switch (d.style) {
                    .@"Xn, [Xn, #]" => {
                        const r1 = rand.int(u8) % 28;
                        const offset = rand.int(u4);
                        used_registers.set(r1);
                        try file_writer.interface.print("{s} X{d}, [XZR, #{d}]", .{ codec.mneumonics[0], r1, offset });
                    },
                    .@"Xn, Xn, [Xn]" => { // stxr
                        const r1 = rand.int(u8) % 28;
                        const r2 = rand.int(u8) % 28;
                        const r3 = rand.int(u8) % 28;
                        const offset = rand.int(u4);
                        used_registers.set(r1);
                        used_registers.set(r2);
                        used_registers.set(r3);
                        try file_writer.interface.print("ADDI X{d}, XZR, #{d}\n", .{ r3, offset });
                        try file_writer.interface.print("{s} X{d}, X{d}, [X{d}]", .{ codec.mneumonics[0], r1, r2, r3 });
                    },
                    else => continue,
                },
                else => continue,
            }

            try file_writer.interface.writeByte('\n');
            i += 1;
        }

        try file_writer.interface.writeAll(
            \\// Print registers.
            \\
        );
        for (0..32) |x| {
            if (used_registers.isSet(x)) {
                try file_writer.interface.print("PRNT X{}\n", .{x});
            }
        }

        // legv8emul does not do flags well
        // if (false) {
        //     const min = @intFromEnum(lemu.Instruction.Codec.Tag.beq);
        //     const max = @intFromEnum(lemu.Instruction.Codec.Tag.bvc);
        //     const bcond: lemu.Instruction.Codec.Tag = @enumFromInt(rand.int(u8) % (max - min) + min);
        //     try file_writer.interface.print(
        //         \\// Print flag
        //         \\{s} F1
        //         \\PRNT XZR
        //         \\B F2
        //         \\F1:
        //         \\ADDI X0, XZR, #1
        //         \\PRNT X0
        //         \\F2:
        //         \\
        //     , .{bcond.get().mneumonics[0]});
        // }

        try file_writer.interface.flush();

        var env_map: std.process.EnvMap = .init(gpa);
        defer env_map.deinit();

        try env_map.put("NO_COLOR", "1");

        const result = try std.process.Child.run(.{
            .allocator = gpa,
            .argv = &.{ lemu_exe, "-z", file_path },
            .env_map = &env_map,
        });
        defer {
            gpa.free(result.stderr);
            gpa.free(result.stdout);
        }

        const other_result = try std.process.Child.run(.{
            .allocator = gpa,
            .argv = &.{ legv8emul_exe, file_path },
        });
        defer {
            gpa.free(other_result.stderr);
            gpa.free(other_result.stdout);
        }

        const prefix =
            \\
            \\    This is LEGv8ASM
            \\    Build time: Wed Oct 16 08:23:15 CDT 2024
            \\
            \\
        ;

        if ((result.term != .Exited and result.term.Exited != 0) or (other_result.term != .Exited and result.term.Exited != 0)) {
            std.testing.expectEqualStrings(result.stderr, other_result.stdout) catch |e| {
                std.log.info("for {s}", .{file_path});
                return e;
            };
        }

        std.testing.expectEqualStrings(result.stdout, other_result.stdout[prefix.len..]) catch |e| {
            std.log.info("for {s}", .{file_path});
            return e;
        };

        try file.setEndPos(0);
    }

    unreachable;
}
