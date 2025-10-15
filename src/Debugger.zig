//! An executor for LEGv8 assembly.
//!
//! Mostly used for the CLI, but can probably be abstracted to more use-cases.

const std = @import("std");

const Assembler = @import("Assembler.zig");
const Vm = @import("Vm.zig");
const Compilation = @import("Compilation.zig");

const Debugger = @This();

pub const Command = union(enum) {
    @"set-file": struct {
        label: []const u8,
        source: [:0]const u8,
    },
    run,
    stepi: usize,
    @"continue",
    @"break": union(enum) {
        label: []const u8,
        line: usize,
    },

    pub const descriptions = std.enums.directEnumArray(std.meta.Tag(Command), []const u8, 0, .{
        .@"set-file" = "Set the current file path.",
        .run = "Run the current file.",
        .stepi = "Step 1 instruction (pseudo-instructions can be multiple instructions)",
    });
};

gpa: std.mem.Allocator,
/// A source label, possibly a file path.
source_label: ?[]const u8 = null,
limit_errors: bool,
assembler: Assembler,
vm: Vm,
breakpoints: std.AutoArrayHashMapUnmanaged(usize, void),
tty_config: std.io.tty.Config,

pub fn init(
    gpa: std.mem.Allocator,
    stdout: *std.io.Writer,
    tty_config: std.io.tty.Config,
    limit_errors: bool,
) Debugger {
    return .{
        .gpa = gpa,
        .source_label = null,
        .limit_errors = limit_errors,
        .assembler = .init(gpa, ""),
        .breakpoints = .empty,
        .vm = .{
            .memory = .init(gpa),
            .output = stdout,
        },
        .tty_config = tty_config,
    };
}

pub fn deinit(debugger: *Debugger, gpa: std.mem.Allocator) void {
    debugger.assembler.deinit(gpa);
    debugger.breakpoints.deinit(gpa);
    debugger.vm.memory.deinit(gpa);
}

pub const Error = std.mem.Allocator.Error || Assembler.Error || Vm.Error || std.io.Writer.Error || std.io.tty.Config.SetColorError || error{NoProgram};

pub fn execute(debugger: *Debugger, command: Command) Error!void {
    switch (command) {
        .@"set-file" => |info| {
            debugger.source_label = null;
            debugger.assembler.reset(info.source);
            debugger.breakpoints.clearRetainingCapacity();
            debugger.assembler.assemble() catch |e| switch (e) {
                error.InvalidSyntax => {
                    const len = if (debugger.limit_errors) @min(debugger.assembler.errors.items.len, 3) else debugger.assembler.errors.items.len;

                    for (debugger.assembler.errors.items[0..len]) |@"error"| {
                        const fmt: Compilation.Error.Fmt = .{
                            .tty_config = debugger.tty_config,
                            .@"error" = @"error",
                            .source_label = info.label,
                            .source = info.source,
                        };
                        try debugger.vm.output.print("{f}\n", .{fmt});
                    }
                    if (debugger.assembler.errors.items.len -| len > 0) {
                        try debugger.tty_config.setColor(debugger.vm.output, .dim);
                        try debugger.vm.output.print("({} errors omitted)\n", .{debugger.assembler.errors.items.len - len});
                        try debugger.tty_config.setColor(debugger.vm.output, .reset);
                    }
                    try debugger.vm.output.flush();
                    return error.InvalidSyntax;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            debugger.source_label = info.label;

            debugger.vm.memory.reset();
            try debugger.vm.memory.readonly.appendSlice(
                debugger.gpa,
                @ptrCast(debugger.assembler.instructions.items(.instruction)),
            );
        },
        .run => try debugger.executeProgram(null, false),
        .stepi => |cnt| try debugger.executeProgram(cnt, false),
        .@"continue" => try debugger.executeProgram(null, true),
        .@"break" => |brk| {
            switch (brk) {
                .label => |label| {
                    const info = debugger.assembler.labels.get(label) orelse {
                        try debugger.vm.output.print("error: no label found for '{s}'\n", .{label});
                        try debugger.vm.output.flush();
                        return;
                    };
                    const source_starts = debugger.assembler.instructions.items(.source_start);
                    for (source_starts[0..], info.instruction_index..) |start, idx| {
                        if (start == source_starts[info.instruction_index]) {
                            try debugger.breakpoints.put(debugger.gpa, idx, {});
                        } else {
                            break;
                        }
                    }
                },
                .line => @panic("TODO"),
            }
        },
    }
}

fn executeProgram(debugger: *Debugger, cnt: ?usize, skip_first_breakpoint: bool) Error!void {
    std.debug.assert(debugger.source_label != null);

    var i: usize = 0;
    while (cnt == null or i < cnt.?) : (i += 1) {
        if (debugger.breakpoints.contains(debugger.vm.pc) and !(i == 0 and skip_first_breakpoint)) {
            try debugger.printVmException(.{ .bkpt = .debugger });
            return;
        }

        if (!try debugger.executeInstruction()) {
            break;
        }
    }
}

fn executeInstruction(debugger: *Debugger) Error!bool {
    return debugger.vm.executeOne() catch |e| {
        if (e == error.ExceptionThrown) {
            try debugger.printVmException(debugger.vm.exception.?);
        }
        return e;
    };
}

fn printVmException(debugger: *Debugger, exception: Vm.Exception) Error!void {
    const fmt: Vm.Exception.Fmt = .{
        .tty_config = debugger.tty_config,
        .assembler = &debugger.assembler,
        .vm = &debugger.vm,
        .source_label = debugger.source_label.?,
        .exception = exception,
    };
    try debugger.vm.output.print("{f}\n", .{fmt});
    try debugger.vm.output.flush();
}
