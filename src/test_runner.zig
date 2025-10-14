const builtin = @import("builtin");
const std = @import("std");

pub fn main() !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const lemu_exe = args[1];
    const mode = args[2];

    var env_map: std.process.EnvMap = .init(gpa);
    defer env_map.deinit();

    try env_map.put("NO_COLOR", "1");

    if (std.mem.eql(u8, mode, "syntax")) {
        const path = args[3];

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var file_reader = file.reader(&.{});

        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(gpa);

        try file_reader.interface.appendRemainingUnlimited(gpa, &source);
        try source.append(gpa, 0);

        var expected_stderr: std.ArrayList(u8) = .empty;
        defer expected_stderr.deinit(gpa);

        const prefix = "/// ";

        var i: usize = 0;
        while (std.mem.indexOfPos(u8, source.items, i, prefix)) |stderr_index| {
            const line_end = std.mem.indexOfScalarPos(u8, source.items, stderr_index, '\n') orelse source.items.len;
            try expected_stderr.appendSlice(gpa, source.items[stderr_index + prefix.len .. line_end]);
            try expected_stderr.append(gpa, '\n');
            i = line_end;
        }

        const result = try std.process.Child.run(.{
            .allocator = gpa,
            .argv = &.{ lemu_exe, path },
            .env_map = &env_map,
        });
        defer {
            gpa.free(result.stderr);
            gpa.free(result.stdout);
        }

        if (!std.mem.eql(u8, result.stderr, expected_stderr.items)) {
            std.log.err(
                \\test case {s} failed
                \\======= EXPECTED =======
                \\{s}
                \\=======  FOUND   =======
                \\{s}
            , .{ path, expected_stderr.items, result.stderr });
            return 1;
        }
    } else if (std.mem.eql(u8, mode, "behavior")) {
        const path = args[3];

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var file_reader = file.reader(&.{});

        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(gpa);

        try file_reader.interface.appendRemainingUnlimited(gpa, &source);
        try source.append(gpa, 0);

        var cmdargs: std.ArrayList([]const u8) = .empty;
        defer cmdargs.deinit(gpa);
        try cmdargs.append(gpa, lemu_exe);

        const arg_prefix = "///#";
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, source.items, i, arg_prefix)) |arg_index| {
            const line_end = std.mem.indexOfScalarPos(u8, source.items, arg_index, '\n') orelse source.items.len;
            try cmdargs.append(gpa, std.mem.trim(u8, source.items[arg_index + arg_prefix.len .. line_end], &std.ascii.whitespace));
            i = line_end;
        }
        try cmdargs.append(gpa, path);

        var expected_output: std.ArrayList(u8) = .empty;
        defer expected_output.deinit(gpa);

        const prefix = "/// ";

        i = 0;
        while (std.mem.indexOfPos(u8, source.items, i, prefix)) |stderr_index| {
            const line_end = std.mem.indexOfScalarPos(u8, source.items, stderr_index, '\n') orelse source.items.len;
            try expected_output.appendSlice(gpa, source.items[stderr_index + prefix.len .. line_end]);
            try expected_output.append(gpa, '\n');
            i = line_end;
        }

        const result = try std.process.Child.run(.{
            .allocator = gpa,
            .argv = cmdargs.items,
            .env_map = &env_map,
        });
        defer {
            gpa.free(result.stderr);
            gpa.free(result.stdout);
        }

        if (result.stdout.len + result.stderr.len != expected_output.items.len or
            !std.mem.eql(u8, result.stdout, expected_output.items[0..result.stdout.len]) or
            !std.mem.eql(u8, result.stderr, expected_output.items[result.stdout.len..]))
        {
            std.log.err(
                \\test case {s} failed
                \\======= EXPECTED =======
                \\{s}
                \\=======  FOUND   =======
                \\{s}{s}
            , .{ path, expected_output.items, result.stdout, result.stderr });
            return 1;
        }
    } else {
        std.log.err("invalid mode {s}", .{mode});
        return 1;
    }

    return 0;
}
