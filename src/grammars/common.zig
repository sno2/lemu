const std = @import("std");

const lemu = @import("lemu");

pub const regex = struct {
    pub const register =
        "\\b([XSD][0-9]|[XSD][1-2][0-9]|[XSD]3[01]|IP0|IP1|SP|FP|LR|XZR)\\b";
    pub const label = "[a-zA-Z_][a-zA-Z0-9_]*";
    pub const bin = "#0[bB][01]+|0[bB][01]+";
    pub const hex = "#0[xX][0-9a-fA-F]+|0[xX][0-9a-fA-F]+";
    pub const dec = "#[0-9]+|[0-9]+";

    pub fn writeInstruction(writer: *std.io.Writer, double_escape: bool) !void {
        const start = "\\b(";
        const end = "|B|MOV|LDA|CMPI|CMP)\\b";

        if (double_escape) {
            try EscapeFmt.init(start).format(writer);
        } else {
            try writer.writeAll(start);
        }

        var first: bool = true;
        for (lemu.Instruction.Codec.list) |codec| {
            if (codec.tag == .b) {
                continue;
            }

            for (codec.mneumonics) |mneumonic| {
                if (!first) {
                    try writer.writeByte('|');
                }

                if (std.mem.indexOfScalar(u8, mneumonic, '.')) |dot_index| {
                    var buf: [16]u8 = undefined;
                    var cpy: std.ArrayList(u8) = .initBuffer(&buf);
                    try cpy.appendSliceBounded(mneumonic);
                    try cpy.insertBounded(dot_index, '\\');
                    if (double_escape) {
                        try cpy.insertBounded(dot_index, '\\');
                    }
                    try writer.writeAll(cpy.items);
                } else {
                    try writer.writeAll(mneumonic);
                }
            }
            first = false;
        }

        if (double_escape) {
            try EscapeFmt.init(end).format(writer);
        } else {
            try writer.writeAll(end);
        }
    }
};

pub const EscapeFmt = struct {
    regex: []const u8,

    pub fn init(re: []const u8) EscapeFmt {
        return .{ .regex = re };
    }

    pub fn format(fmt: EscapeFmt, writer: *std.io.Writer) !void {
        for (fmt.regex) |x| {
            if (x == '\\') {
                try writer.writeByte('\\');
            }
            try writer.writeByte(x);
        }
    }
};
