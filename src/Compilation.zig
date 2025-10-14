const std = @import("std");

const Lexer = @import("Assembler.zig").Lexer;

pub const Error = struct {
    data: Data,
    source_range: Lexer.SourceRange,

    pub const Data = union(enum) {
        expected_token: struct {
            expected: Lexer.Token.Tag,
            got: Lexer.Token,
        },
        unknown_mneumonic,
        shift_amount_overflow,
        immediate_overflow,
        mov_immediate_overflow,
        mov_shift_overflow,
        mov_no_lsl,
        load_store_offset_overflow,
        unimplemented_far_jump,
        dot_label,
        unexpected: Lexer.Token,
        duplicate_label_name: []const u8,
        undefined_label: []const u8,
        empty_label,

        pub fn format(self: Data, writer: *std.io.Writer) !void {
            switch (self) {
                .expected_token => |data| {
                    try writer.writeAll("expected ");
                    try Lexer.Token.formatTag(data.expected, writer);
                    try writer.print(", got {f}", .{data.got});
                },
                .unexpected => |data| {
                    try writer.print("unexpected {f}", .{data});
                },
                .unknown_mneumonic => {
                    try writer.writeAll("unknown instruction mneumonic");
                },
                .shift_amount_overflow => {
                    try writer.writeAll("shift amount is out of the range for a 6-bit unsigned integer");
                },
                .immediate_overflow => {
                    try writer.writeAll("immediate is out of the range for a 12-bit signed integer");
                },
                .load_store_offset_overflow => {
                    try writer.writeAll("load/store offset is out of the range for a 9-bit unsigned integer");
                },
                .unimplemented_far_jump => {
                    try writer.writeAll("TODO branch target is further than allowed immediate size");
                },
                .dot_label => {
                    try writer.writeAll("label cannot contain '.'");
                },
                .mov_immediate_overflow => {
                    try writer.writeAll("move immediate is out of the range for a 16-bit unsigned integer");
                },
                .mov_shift_overflow => {
                    try writer.writeAll("move shift amount is not 0, 16, 32, or 48");
                },
                .mov_no_lsl => {
                    try writer.writeAll("expected 'LSL' for move shift amount");
                },
                .duplicate_label_name => |label| {
                    try writer.print("duplicate label name '{s}'", .{label});
                },
                .undefined_label => |label| {
                    try writer.print("use of undeclared label '{s}'", .{label});
                },
                .empty_label => {
                    try writer.writeAll("label must have at least one instruction");
                },
            }
        }
    };

    pub const Fmt = struct {
        tty_config: std.io.tty.Config,
        @"error": Error,
        source_label: ?[]const u8,
        source: []const u8,

        pub fn format(fmt: *const Fmt, writer: *std.io.Writer) std.io.Writer.Error!void {
            fmt.formatInner(writer) catch return error.WriteFailed;
        }

        fn formatInner(fmt: *const Fmt, writer: *std.io.Writer) !void {
            try fmt.tty_config.setColor(writer, .reset);
            try fmt.tty_config.setColor(writer, .bold);
            const line = std.mem.count(u8, fmt.source[0..fmt.@"error".source_range.start], &.{'\n'}) + 1;
            const line_start = if (std.mem.lastIndexOfScalar(u8, fmt.source[0..fmt.@"error".source_range.start], '\n')) |nl_index| nl_index + 1 else 0;
            if (fmt.source_label) |label| {
                try writer.print("{s}:", .{label});
            }
            try writer.print("{}:{}: ", .{ line, 1 + fmt.@"error".source_range.start - line_start });
            try fmt.tty_config.setColor(writer, .reset);
            try fmt.tty_config.setColor(writer, .bold);
            try fmt.tty_config.setColor(writer, .red);
            try writer.writeAll("error: ");
            try fmt.tty_config.setColor(writer, .reset);
            try fmt.tty_config.setColor(writer, .bold);
            try writer.print("{f}", .{fmt.@"error".data});
            try fmt.tty_config.setColor(writer, .reset);
            const line_end = if (std.mem.indexOfScalarPos(u8, fmt.source, fmt.@"error".source_range.end -| 1, '\n')) |nl_index| nl_index else fmt.source.len;
            try writer.print("\n{s}\n", .{fmt.source[line_start..line_end]});
            try writer.splatByteAll(' ', fmt.@"error".source_range.start - line_start);
            try fmt.tty_config.setColor(writer, .bold);
            try fmt.tty_config.setColor(writer, .green);
            try writer.writeByte('^');
            try writer.splatByteAll('~', fmt.@"error".source_range.end - fmt.@"error".source_range.start -| 1);
            try fmt.tty_config.setColor(writer, .reset);
        }
    };
};
