const builtin = @import("builtin");
const std = @import("std");

const build_options = @import("options");
const lemu = @import("lemu");
const lsp = @import("lsp");
const zigline = @import("zigline");

var outbuf: [256]u8 = undefined;
var inbuf: [256]u8 = undefined;

const Args = struct {
    help: bool = false,
    @"zero-page": bool = false,
    debug: bool = false,
    stdio: bool = false,
    @"limit-errors": bool = false,
    file: ?[]const u8 = null,

    pub const descriptions: []const struct { []const u8, []const u8 } = &.{
        .{ "-h, --help", "Display this help and exit." },
        .{ "-z, --zero-page", "Provide a non-standard memory space of 4096 bytes starting from 0x0." },
        .{ "-l, --limit-errors", "Limit to the first 3 compile errors." },
        .{ "-d, --debug", "Enable debugging." },
        .{ "<file>", "Assemble and run the file." },
        .{ "--stdio", "Start the LSP (used by editors)." },
    };

    pub fn printHelp(writer: *std.Io.Writer) !void {
        try writer.writeAll(
            \\Lemu: A LEGv8 toolkit.
            \\
            \\Usage:
            \\
        );

        for (descriptions) |description| {
            try writer.print("    {s:<21}{s}\n", .{ description.@"0", description.@"1" });
        }
    }

    pub fn parse(list: [][:0]u8) !?Args {
        var result: Args = .{};
        outer: for (list[1..]) |arg| {
            if (std.mem.startsWith(u8, arg, "--")) {
                inline for (@typeInfo(Args).@"struct".fields) |field| {
                    if (field.type != ?[]const u8 and (std.mem.eql(u8, arg[1..], "-" ++ field.name) or std.mem.eql(u8, arg[1..], field.name[0..1]))) {
                        @field(result, field.name) = true;
                        continue :outer;
                    }
                }

                std.log.err("unknown flag \"{s}\"", .{arg});
                return null;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                inner: for (arg[1..]) |b| {
                    inline for (@typeInfo(Args).@"struct".fields) |field| {
                        if (field.type != ?[]const u8 and b == field.name[0]) {
                            @field(result, field.name) = true;
                            continue :inner;
                        }
                    }
                    std.log.err("unknown switch '{c}'", .{b});
                    return null;
                }
                continue :outer;
            }

            if (result.file == null) {
                result.file = arg;
            } else {
                std.log.err("expected 1 file argument", .{});
                return null;
            }
        }

        if (result.help) {
            return null;
        }

        if (!result.stdio and result.file == null) {
            std.log.err("expected a file argument", .{});
            return null;
        }

        return result;
    }
};

pub fn main() !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 20 }) = .init;
    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ if (builtin.target.os.tag == .wasi) std.heap.wasm_allocator else std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const args_list = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args_list);

    const args = try Args.parse(args_list) orelse {
        const stderr_file: std.fs.File = .stderr();
        var stderr_writer = stderr_file.writer(&outbuf);
        try Args.printHelp(&stderr_writer.interface);
        try stderr_writer.interface.flush();
        return 1;
    };

    if (args.stdio) {
        if (!build_options.lsp) {
            std.log.err("Lemu was compiled without LSP support.", .{});
            return 1;
        }

        var stdio_transport: lsp.Transport.Stdio = .init(&outbuf, .stdin(), .stdout());

        var ls: lemu.LanguageServer = .init(gpa, &stdio_transport.transport);
        defer ls.deinit();

        try ls.run();
        return 0;
    }

    const file = std.fs.cwd().openFile(args.file.?, .{}) catch |e| {
        std.log.err("failed to open file: {t}", .{e});
        return 1;
    };
    defer file.close();
    var file_reader = file.reader(&.{});

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);

    try file_reader.interface.appendRemainingUnlimited(gpa, &source);
    try source.append(gpa, 0);

    if (args.debug) {
        if (!build_options.debugger) {
            std.log.err("Lemu was compiled without debugger support.", .{});
            return 1;
        }

        var editor: zigline.Editor = .init(gpa, .{});
        defer editor.deinit();

        var stdout_file: std.fs.File = .stdout();
        var stdout_writer = stdout_file.writer(&outbuf);
        const tty_config: std.io.tty.Config = .detect(stdout_file);
        const writer = &stdout_writer.interface;

        var debugger: lemu.Debugger = .init(gpa, writer, tty_config, args.@"limit-errors");
        defer debugger.deinit(gpa);

        try debugger.execute(.{
            .@"set-file" = .{
                .label = args.file.?,
                .source = source.items[0 .. source.items.len - 1 :0],
            },
        });

        while (true) {
            const line = editor.getLine("(lemudb) ") catch |err| switch (err) {
                error.Eof => break,
                else => return err,
            };
            defer gpa.free(line);

            var lex: lemu.Assembler.Lexer = .{ .source = try gpa.dupeZ(u8, line) };
            defer gpa.free(lex.source);
            lex.next();

            try editor.addToHistory(line);

            if (lex.token != .identifier) {
                std.log.info("command must be an identifier", .{});
                continue;
            }

            const command = lex.sourceRange().slice(line);
            lex.next();

            const cmd: lemu.Debugger.Command = cmd: {
                if (std.mem.eql(u8, command, "exit")) {
                    break;
                } else if (std.mem.eql(u8, command, "run")) {
                    break :cmd .run;
                } else if (std.mem.eql(u8, command, "stepi")) {
                    if (lex.token != .eof) {
                        if (lex.token != .integer) {
                            std.log.err("stepi count must be an integer", .{});
                            continue;
                        }

                        const value = std.fmt.parseInt(usize, lex.sourceRange().slice(line), 0) catch {
                            std.log.err("stepi count overflow", .{});
                            continue;
                        };
                        lex.next();
                        break :cmd .{ .stepi = value };
                    } else {
                        break :cmd .{ .stepi = 1 };
                    }
                } else if (std.mem.eql(u8, command, "break")) {
                    switch (lex.token) {
                        .identifier, .dot_identifier => {
                            const label = lex.sourceRange().slice(line);
                            lex.next();
                            break :cmd .{ .@"break" = .{ .label = label } };
                        },
                        .integer => {
                            const linenum = std.fmt.parseInt(usize, lex.sourceRange().slice(line), 0) catch {
                                std.log.err("breakpoint line number overflow", .{});
                                continue;
                            };
                            lex.next();
                            break :cmd .{ .@"break" = .{ .line = linenum } };
                        },
                        else => {
                            std.log.err("expected line number or label name for breakpoint", .{});
                            continue;
                        },
                    }
                } else if (std.mem.eql(u8, command, "continue")) {
                    break :cmd .@"continue";
                } else {
                    std.log.err("unknown command \"{s}\"", .{command});
                    continue;
                }
            };

            if (lex.token != .eof and lex.token != .newline) {
                std.log.err("unexpected text after command", .{});
                continue;
            }

            try debugger.execute(cmd);
        }
        return 0;
    }

    var assembler: lemu.Assembler = .init(gpa, source.items[0 .. source.items.len - 1 :0]);
    defer assembler.deinit(gpa);

    assembler.assemble() catch |e| switch (e) {
        error.InvalidSyntax => {
            var stderr: std.fs.File = .stderr();
            var stderr_writer = stderr.writer(&outbuf);
            const tty_config = std.io.tty.Config.detect(stderr);
            const len = if (args.@"limit-errors") @min(assembler.errors.items.len, 3) else assembler.errors.items.len;
            for (assembler.errors.items[0..len]) |@"error"| {
                const fmt: lemu.Compilation.Error.Fmt = .{
                    .tty_config = tty_config,
                    .@"error" = @"error",
                    .source_label = args.file,
                    .source = assembler.lex.source,
                };
                try stderr_writer.interface.print("{f}\n", .{fmt});
            }
            if (assembler.errors.items.len -| len > 0) {
                try tty_config.setColor(&stderr_writer.interface, .dim);
                try stderr_writer.interface.print("({} errors omitted)\n", .{assembler.errors.items.len - len});
                try tty_config.setColor(&stderr_writer.interface, .reset);
            }
            try stderr_writer.interface.flush();
            return 1;
        },
        else => return e,
    };

    const stdout: std.fs.File = .stdout();
    var stdout_writer = stdout.writer(&.{});

    var vm: lemu.Vm = .{
        .memory = .init(gpa),
        .output = &stdout_writer.interface,
    };
    defer vm.memory.deinit(gpa);
    try vm.memory.readonly.appendSlice(gpa, @ptrCast(assembler.instructions.items(.instruction)));
    if (args.@"zero-page") {
        try vm.memory.zero_page.appendNTimes(gpa, 0, 4096);
    }
    vm.execute() catch |e| switch (e) {
        error.ExceptionThrown => {
            var stderr: std.fs.File = .stderr();
            var stderr_writer = stderr.writer(&outbuf);

            const fmt: lemu.Vm.Exception.Fmt = .{
                .tty_config = std.io.tty.Config.detect(stderr),
                .assembler = &assembler,
                .vm = &vm,
                .source_label = args.file,
                .exception = vm.exception.?,
            };
            try stderr_writer.interface.print("{f}\n", .{fmt});
            try stderr_writer.interface.flush();
            return 1;
        },
        else => return e,
    };
    return 0;
}
