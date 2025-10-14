//! Generate a VS Code code snippets JSON. Ideally, this would be implemented in
//! the LSP but it is hard to do efficiently.

const std = @import("std");

const lemu = @import("lemu");

pub fn main() !void {
    var stdout_file: std.fs.File = .stdout();
    var buf: [128]u8 = undefined;
    var stdout_writer = stdout_file.writer(&buf);
    try run(&stdout_writer.interface);
    try stdout_writer.interface.flush();
}

const x = struct {
    pub fn format(_: @This(), writer: *std.io.Writer) !void {
        for (0..32) |i| {
            try writer.print("X{},", .{i});
        }
        try writer.writeAll("SP,IP0,IP1,XZR");
    }
}{};

const s = struct {
    pub fn format(_: @This(), writer: *std.io.Writer) !void {
        for (0..32) |i| {
            try writer.print("S{}{s}", .{ i, if (i == 31) "" else "," });
        }
    }
}{};

const d = struct {
    pub fn format(_: @This(), writer: *std.io.Writer) !void {
        for (0..32) |i| {
            try writer.print("D{}{s}", .{ i, if (i == 31) "" else "," });
        }
    }
}{};

fn run(writer: *std.io.Writer) !void {
    try writer.writeAll("{\n");
    for (lemu.Instruction.Codec.list, 0..) |codec, i| {
        try writer.print(
            \\  "{0s}": {{
            \\    "prefix": "{0s}",
            \\    "body": "{0s}
        , .{codec.mneumonics[0]});
        switch (codec.format) {
            .r => |r| switch (r.style) {
                .empty => {},
                .Xn => try writer.print(" ${{1|{0f}|}}", .{x}),
                .@"Xn, Xn, Xn" => try writer.print(" ${{1|{0f}|}}, ${{2|{0f}|}}, ${{3|{0f}|}}", .{x}),
                .@"Xn, Xn, Shamt" => try writer.print(" ${{1|{0f}|}}, ${{2|{0f}|}}, ${{3|0|}}", .{x}),
                .@"Sn, Sn" => try writer.print(" ${{1|{0f}|}}, ${{2|{0f}|}}", .{s}),
                .@"Dn, Dn" => try writer.print(" ${{1|{0f}|}}, ${{2|{0f}|}}", .{d}),
                .@"Dn, Dn, Dn" => try writer.print(" ${{1|{0f}|}}, ${{2|{0f}|}}, ${{3|{0f}|}}", .{d}),
                .@"Sn, Sn, Sn" => try writer.print(" ${{1|{0f}|}}, ${{2|{0f}|}}, ${{3|{0f}|}}", .{s}),
                .time => try writer.print(" ${{1|{0f}|}}", .{x}),
            },
            .i => try writer.print(" ${{1|{0f}|}}, ${{2|{0f}|}}, #${{3|0|}}", .{x}),
            .b => try writer.writeAll(" ${1}"),
            .cb => {
                if (codec.tag == .cbnz or codec.tag == .cbz) {
                    try writer.print(" ${{1|{0f}|}}, ${{2}}", .{x});
                } else {
                    try writer.writeAll(" ${1}");
                }
            },
            .d => |dd| switch (dd.style) {
                .@"Xn, [Xn, #]" => try writer.print(" ${{1|{0f}|}}, [${{2|{0f}|}}, #${{3|0|}}]", .{x}),
                .@"Xn, Xn, [Xn]" => try writer.print(" ${{1|{0f}|}}, ${{2|{0f}|}}, [${{3|{0f}|}}]", .{x}),
            },
            .iw => {
                try writer.print(" ${{1|{0f}|}}, #${{2|0|}}${{outer:|${{4}}|}}", .{x});
            },
        }
        try writer.print(
            \\",
            \\    "description": "{s}"
            \\  }}{s}
            \\
        , .{ codec.description, if (i == lemu.Instruction.Codec.list.len - 1) "" else "," });
    }
    try writer.writeAll("}\n");
}
