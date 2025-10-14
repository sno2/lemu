//! Lexer for the LEGv8 Assembly syntax. See pages 64 & 65 of the book.

const std = @import("std");

const Compilation = @import("../Compilation.zig");

pub const Lexer = @This();

pub const SourceRange = struct {
    start: usize,
    end: usize,

    pub fn slice(source_range: SourceRange, s: []const u8) []const u8 {
        return s[source_range.start..source_range.end];
    }
};

source: [:0]const u8,
start: usize = 0,
index: usize = 0,
token: Token = .invalid,

pub const Token = union(enum) {
    eof,
    identifier,
    dot_identifier,
    integer,
    newline,
    x: u5,
    s: u5,
    d: u5,
    @":",
    @",",
    @"[",
    @"]",
    invalid,

    pub fn format(token: Token, writer: *std.io.Writer) !void {
        try formatTag(token, writer);
    }

    pub fn formatTag(tag: @typeInfo(Token).@"union".tag_type.?, writer: *std.io.Writer) !void {
        switch (tag) {
            .eof => try writer.writeAll("the end of the file"),
            .identifier => try writer.writeAll("an identifier"),
            .dot_identifier => try writer.writeAll("an invalid identifier"),
            .integer => try writer.writeAll("an integer"),
            .newline => try writer.writeAll("a newline"),
            .x => try writer.writeAll("an X register"),
            .s => try writer.writeAll("an S register"),
            .d => try writer.writeAll("a D register"),
            .@":" => try writer.writeAll("a colon"),
            .@"," => try writer.writeAll("a comma"),
            .@"[" => try writer.writeAll("a left-bracket"),
            .@"]" => try writer.writeAll("a right-bracket"),
            .invalid => try writer.writeAll("invalid bytes"),
        }
    }

    pub const Tag = @typeInfo(Token).@"union".tag_type.?;
};

const State = enum {
    init,
    @"0",
    @"0b",
    @"0x",
    identifier,
    dot_identifier0,
    dot_identifier,
    integer,
    @"/",
    @"-",
    @"#",
    comment,
    X,
    XN,
    S,
    SN,
    D,
    DN,
};

const keyword_map = std.StaticStringMap(Token).initComptime(.{
    .{ "IP0", Token{ .x = 16 } },
    .{ "IP1", Token{ .x = 17 } },
    .{ "SP", Token{ .x = 28 } },
    .{ "FP", Token{ .x = 29 } },
    .{ "LR", Token{ .x = 30 } },
    .{ "XZR", Token{ .x = 31 } },
});

pub fn sourceRange(lex: *Lexer) Lexer.SourceRange {
    return .{
        .start = lex.start,
        .end = lex.index,
    };
}

fn nextInner(lex: *Lexer) Token {
    state: switch (@as(State, .init)) {
        .init => {
            lex.start = lex.index;
            switch (lex.source[lex.index]) {
                0 => return .eof,
                ' ', '\t' => {
                    lex.index += 1;
                    continue :state .init;
                },
                '\r', '\n' => {
                    lex.index += 1;
                    return .newline;
                },
                '0' => {
                    lex.index += 1;
                    continue :state .@"0";
                },
                '-' => {
                    lex.index += 1;
                    continue :state .integer;
                },
                '1'...'9' => {
                    lex.index += 1;
                    continue :state .integer;
                },
                'a'...'z', 'A'...'D' - 1, 'D' + 1...'S' - 1, 'S' + 1...'X' - 1, 'X' + 1...'Z', '_' => {
                    lex.index += 1;
                    continue :state .identifier;
                },
                '/' => {
                    lex.index += 1;
                    continue :state .@"/";
                },
                'X' => {
                    lex.index += 1;
                    continue :state .X;
                },
                'S' => {
                    lex.index += 1;
                    continue :state .S;
                },
                'D' => {
                    lex.index += 1;
                    continue :state .D;
                },
                ':' => {
                    lex.index += 1;
                    return .@":";
                },
                ',' => {
                    lex.index += 1;
                    return .@",";
                },
                '[' => {
                    lex.index += 1;
                    return .@"[";
                },
                ']' => {
                    lex.index += 1;
                    return .@"]";
                },
                '#' => {
                    lex.index += 1;
                    continue :state .@"#";
                },
                else => {
                    lex.index += 1;
                    return .invalid;
                },
            }
        },
        .@"#" => switch (lex.source[lex.index]) {
            '0' => {
                lex.start += 1;
                lex.index += 1;
                continue :state .@"0";
            },
            '1'...'9' => {
                lex.start += 1;
                lex.index += 1;
                continue :state .integer;
            },
            '-' => {
                lex.start += 1;
                lex.index += 1;
                continue :state .@"-";
            },
            else => return .invalid,
        },
        .@"0" => switch (lex.source[lex.index]) {
            'b', 'B' => {
                lex.index += 1;
                continue :state .@"0b";
            },
            'x', 'X' => {
                lex.index += 1;
                continue :state .@"0x";
            },
            '1'...'9' => return .invalid,
            else => return .integer,
        },
        .@"0b" => switch (lex.source[lex.index]) {
            '0', '1' => {
                lex.index += 1;
                continue :state .@"0b";
            },
            else => return .integer,
        },
        .@"0x" => switch (lex.source[lex.index]) {
            '0'...'9', 'a'...'f', 'A'...'F' => {
                lex.index += 1;
                continue :state .@"0x";
            },
            else => return .integer,
        },
        .identifier => switch (lex.source[lex.index]) {
            'a'...'z', 'A'...'Z', '_', '0'...'9' => {
                lex.index += 1;
                continue :state .identifier;
            },
            '.' => {
                lex.index += 1;
                continue :state .dot_identifier0;
            },
            else => return keyword_map.get(lex.source[lex.start..lex.index]) orelse .identifier,
        },
        .dot_identifier0 => switch (lex.source[lex.index]) {
            'a'...'z', 'A'...'Z' => {
                lex.index += 1;
                continue :state .dot_identifier;
            },
            else => {
                lex.index -= 1;
                return keyword_map.get(lex.source[lex.start..lex.index]) orelse .identifier;
            },
        },
        .dot_identifier => switch (lex.source[lex.index]) {
            'a'...'z', 'A'...'Z', '_', '0'...'9' => {
                lex.index += 1;
                continue :state .dot_identifier;
            },
            '.' => {
                lex.index += 1;
                continue :state .dot_identifier0;
            },
            else => return .dot_identifier,
        },
        .@"/" => switch (lex.source[lex.index]) {
            '/' => {
                lex.index += 1;
                continue :state .comment;
            },
            else => return .invalid,
        },
        .comment => switch (lex.source[lex.index]) {
            0, '\r', '\n' => continue :state .init,
            else => {
                lex.index += 1;
                continue :state .comment;
            },
        },
        .X => switch (lex.source[lex.index]) {
            '0'...'9' => {
                lex.index += 1;
                continue :state .XN;
            },
            else => continue :state .identifier,
        },
        .XN => switch (lex.source[lex.index]) {
            '0'...'9' => {
                lex.index += 1;
                continue :state .XN;
            },
            else => {
                if (std.fmt.parseInt(u5, lex.source[lex.start + 1 .. lex.index], 0) catch null) |x| {
                    return .{ .x = x };
                }
                continue :state .identifier;
            },
        },
        .S => switch (lex.source[lex.index]) {
            '0'...'9' => {
                lex.index += 1;
                continue :state .SN;
            },
            else => continue :state .identifier,
        },
        .SN => switch (lex.source[lex.index]) {
            '0'...'9' => {
                lex.index += 1;
                continue :state .SN;
            },
            else => {
                if (std.fmt.parseInt(u5, lex.source[lex.start + 1 .. lex.index], 0) catch null) |s| {
                    return .{ .s = s };
                }
                continue :state .identifier;
            },
        },
        .D => switch (lex.source[lex.index]) {
            '0'...'9' => {
                lex.index += 1;
                continue :state .DN;
            },
            else => continue :state .identifier,
        },
        .DN => switch (lex.source[lex.index]) {
            '0'...'9' => {
                lex.index += 1;
                continue :state .DN;
            },
            else => {
                if (std.fmt.parseInt(u5, lex.source[lex.start + 1 .. lex.index], 0) catch null) |d| {
                    return .{ .d = d };
                }
                continue :state .identifier;
            },
        },
        .@"-" => switch (lex.source[lex.index]) {
            '0' => {
                lex.index += 1;
                continue :state .@"0";
            },
            '1'...'9' => {
                lex.index += 1;
                continue :state .integer;
            },
            else => return .invalid,
        },
        .integer => switch (lex.source[lex.index]) {
            '0'...'9' => {
                lex.index += 1;
                continue :state .integer;
            },
            else => return .integer,
        },
    }
}

pub fn next(lex: *Lexer) void {
    lex.token = lex.nextInner();
}
