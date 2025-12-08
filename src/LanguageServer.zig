//! LSP for LEGv8.

const builtin = @import("builtin");
const std = @import("std");

const lsp = @import("lsp");

const Assembler = @import("Assembler.zig");
const Instruction = @import("instruction.zig").Instruction;

const LanguageServer = @This();

gpa: std.mem.Allocator,
transport: *lsp.Transport,
files: std.StringArrayHashMapUnmanaged(File),
offset_encoding: lsp.offsets.Encoding,
scratch: std.io.Writer.Allocating,

const File = struct {
    source: std.ArrayList(u8),
    assembler: Assembler,

    pub fn init(gpa: std.mem.Allocator) File {
        return .{
            .source = .empty,
            .assembler = .init(gpa, ""),
        };
    }

    pub fn reset(file: *File, source: []const u8) !void {
        file.source.clearRetainingCapacity();
        try file.source.appendSlice(file.assembler.gpa, source);
        file.assembler.reset("");
    }

    pub fn deinit(file: *File) void {
        file.source.deinit(file.assembler.gpa);
        file.assembler.deinit(file.assembler.gpa);
    }

    /// `file.source` cannot be changed while this pointer is active.
    pub fn assemblerPtr(file: *File) !*Assembler {
        try file.source.append(file.assembler.gpa, 0);
        defer file.source.items.len -= 1;
        file.assembler.lex = .{
            .source = file.source.items[0 .. file.source.items.len - 1 :0],
        };
        return &file.assembler;
    }
};

pub fn init(gpa: std.mem.Allocator, transport: *lsp.Transport) LanguageServer {
    return .{
        .gpa = gpa,
        .transport = transport,
        .files = .empty,
        .offset_encoding = .@"utf-16",
        .scratch = .init(gpa),
    };
}

pub fn deinit(ls: *LanguageServer) void {
    for (ls.files.keys()) |key| {
        ls.gpa.free(key);
    }
    for (ls.files.values()) |*file| {
        file.deinit();
    }
    ls.files.deinit(ls.gpa);
    ls.scratch.deinit();
}

pub fn run(ls: *LanguageServer) !void {
    try lsp.basic_server.run(
        ls.gpa,
        ls.transport,
        ls,
        std.log.err,
    );
}

fn analyzeFile(
    ls: *LanguageServer,
    document_uri: lsp.types.URI,
    file: *File,
) !void {
    const assembler = try file.assemblerPtr();
    assembler.reset(assembler.lex.source);
    assembler.assemble() catch |e| switch (e) {
        error.InvalidSyntax => {
            var diagnostics: std.ArrayList(lsp.types.Diagnostic) = .empty;
            defer {
                for (diagnostics.items) |diagnostic| {
                    ls.gpa.free(diagnostic.message);
                }
                diagnostics.deinit(ls.gpa);
            }

            for (file.assembler.errors.items) |err| {
                try diagnostics.append(ls.gpa, .{
                    .range = .{
                        .start = lsp.offsets.indexToPosition(assembler.lex.source, err.source_range.start, ls.offset_encoding),
                        .end = lsp.offsets.indexToPosition(assembler.lex.source, err.source_range.end, ls.offset_encoding),
                    },
                    .message = try std.fmt.allocPrint(ls.gpa, "{f}", .{err.data}),
                });
            }

            const notif: lsp.TypedJsonRPCNotification(lsp.types.PublishDiagnosticsParams) = .{
                .method = "textDocument/publishDiagnostics",
                .params = .{
                    .uri = document_uri,
                    .diagnostics = diagnostics.items,
                },
            };

            const message = try std.json.Stringify.valueAlloc(ls.gpa, notif, .{ .emit_null_optional_fields = false });
            defer ls.gpa.free(message);

            try ls.transport.writeJsonMessage(message);
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    const notif: lsp.TypedJsonRPCNotification(lsp.types.PublishDiagnosticsParams) = .{
        .method = "textDocument/publishDiagnostics",
        .params = .{
            .uri = document_uri,
            .diagnostics = &.{},
        },
    };
    const message = try std.json.Stringify.valueAlloc(ls.gpa, notif, .{ .emit_null_optional_fields = false });
    defer ls.gpa.free(message);

    try ls.transport.writeJsonMessage(message);
}

pub fn initialize(
    ls: *LanguageServer,
    _: std.mem.Allocator,
    request: lsp.types.InitializeParams,
) lsp.types.InitializeResult {
    std.log.debug("Received 'initialize' message", .{});

    if (request.clientInfo) |client_info| {
        std.log.info("The client is '{s}' ({s})", .{ client_info.name, client_info.version orelse "unknown version" });
    }

    const client_capabilities: lsp.types.ClientCapabilities = request.capabilities;

    if (client_capabilities.general) |general| {
        for (general.positionEncodings orelse &.{}) |encoding| {
            ls.offset_encoding = switch (encoding) {
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-32" => .@"utf-32",
                .custom_value => continue,
            };
            break;
        }
    }

    const server_capabilities: lsp.types.ServerCapabilities = .{
        .positionEncoding = switch (ls.offset_encoding) {
            .@"utf-8" => .@"utf-8",
            .@"utf-16" => .@"utf-16",
            .@"utf-32" => .@"utf-32",
        },
        .textDocumentSync = .{
            .TextDocumentSyncOptions = .{
                .openClose = true,
                .change = .Full,
            },
        },
        .hoverProvider = .{ .bool = true },
        .definitionProvider = .{ .bool = true },
    };

    if (@import("builtin").mode == .Debug) {
        lsp.basic_server.validateServerCapabilities(LanguageServer, server_capabilities);
    }

    return .{
        .serverInfo = .{
            .name = "lemu",
            .version = "0.1.0",
        },
        .capabilities = server_capabilities,
    };
}

pub fn initialized(
    _: *LanguageServer,
    _: std.mem.Allocator,
    _: lsp.types.InitializedParams,
) void {
    std.log.debug("Received 'initialized' notification", .{});
}

pub fn shutdown(
    _: *LanguageServer,
    _: std.mem.Allocator,
    _: void,
) ?void {
    std.log.debug("Received 'shutdown' request", .{});
    return null;
}

pub fn exit(
    _: *LanguageServer,
    _: std.mem.Allocator,
    _: void,
) void {
    std.log.debug("Received 'exit' notification", .{});
}

pub fn @"textDocument/hover"(
    ls: *LanguageServer,
    _: std.mem.Allocator,
    params: lsp.types.HoverParams,
) !?lsp.types.Hover {
    const file = ls.files.getPtr(params.textDocument.uri) orelse return null;
    const assembler = try file.assemblerPtr();

    if (file.source.items.len == 0) return null;

    const source_index = lsp.offsets.positionToIndex(file.source.items, params.position, ls.offset_encoding);
    std.log.debug("Hover position: line={d}, character={d}, index={d}", .{ params.position.line, params.position.character, source_index });

    const line_start = std.mem.lastIndexOfScalar(u8, file.source.items[0..source_index], '\n') orelse 0;
    assembler.lex.index = line_start;
    while (assembler.lex.index <= source_index) {
        assembler.lex.next();
    }

    if (source_index < assembler.lex.start) {
        return null;
    }

    const range: lsp.offsets.Range = .{
        .start = lsp.offsets.indexToPosition(file.source.items, assembler.lex.start, ls.offset_encoding),
        .end = lsp.offsets.indexToPosition(file.source.items, assembler.lex.index, ls.offset_encoding),
    };

    switch (assembler.lex.token) {
        .dot_identifier, .identifier => {
            // binary search for instruction in assembly
            const insns_slice = file.assembler.instructions.slice();
            var result: ?usize = null;
            var low: usize = 0;
            var high: usize = insns_slice.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (insns_slice.items(.source_start)[mid] <= assembler.lex.start) {
                    if (insns_slice.items(.source_start)[mid] == assembler.lex.start) {
                        result = mid;
                    }
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }

            if (result) |index| {
                defer ls.scratch.clearRetainingCapacity();
                const codec = insns_slice.items(.instruction_codec_tag)[index].get();

                try ls.scratch.writer.print(
                    \\{s}: {f}
                    \\
                , .{
                    codec.description,
                    codec.format,
                });

                switch (codec.format) {
                    inline else => |_, tag| {
                        const value = @field(insns_slice.items(.instruction)[index], @tagName(tag));
                        const fields = @typeInfo(@TypeOf(value)).@"struct".fields;
                        comptime var i = fields.len;

                        inline while (i > 0) {
                            i -= 1;
                            try ls.scratch.writer.print("| {s} ", .{fields[i].name});
                        }

                        try ls.scratch.writer.writeAll("|\n");
                        try ls.scratch.writer.splatBytesAll("|---", fields.len);
                        try ls.scratch.writer.writeAll("|\n");
                        i = fields.len;
                        inline while (i > 0) {
                            i -= 1;
                            const field = fields[i];
                            try ls.scratch.writer.writeAll("| ");
                            const field_value = @field(value, field.name);
                            var buf: [32]u8 = undefined;
                            const binary = try std.fmt.bufPrint(&buf, "{b}", .{@as(std.meta.Int(.unsigned, @bitSizeOf(field.type)), @bitCast(field_value))});
                            try ls.scratch.writer.splatByteAll('0', @bitSizeOf(field.type) - binary.len);
                            try ls.scratch.writer.print("{s} ", .{binary});
                        }
                        try ls.scratch.writer.writeAll("|\n");
                    },
                }

                return .{
                    .contents = .{
                        .MarkupContent = .{
                            .kind = .markdown,
                            .value = ls.scratch.written(),
                        },
                    },
                    .range = range,
                };
            }

            if (assembler.labels.contains(assembler.lex.source[assembler.lex.start..assembler.lex.index])) {
                defer ls.scratch.clearRetainingCapacity();
                try ls.scratch.writer.print(
                    \\```
                    \\{0s}: // label
                    \\```
                    \\
                , .{assembler.lex.source[assembler.lex.start..assembler.lex.index]});
                return .{
                    .contents = .{
                        .MarkupContent = .{
                            .kind = .markdown,
                            .value = ls.scratch.written(),
                        },
                    },
                };
            }
        },
        .integer => blk: {
            defer ls.scratch.clearRetainingCapacity();
            const value = std.fmt.parseInt(i64, assembler.lex.source[assembler.lex.start..assembler.lex.index], 0) catch break :blk;
            try ls.scratch.writer.print(
                \\| Base | Value |
                \\|------|-------|
                \\| BIN  | 0b{[abs]b} |
                \\| HEX  | 0x{[abs]X} |
                \\| DEC  | {[dec]d} |
                \\
            , .{
                .abs = @as(u64, @bitCast(value)),
                .dec = value,
            });
            return .{
                .contents = .{
                    .MarkupContent = .{
                        .kind = .markdown,
                        .value = ls.scratch.written(),
                    },
                },
                .range = range,
            };
        },
        .x => return .{
            .contents = .{
                .MarkupContent = .{
                    .kind = .markdown,
                    .value = "A 64-bit integral register.\n\nFast locations for data. `X0`-`X30`. `XZR` is always `0`.",
                },
            },
            .range = range,
        },
        .s => return .{
            .contents = .{
                .MarkupContent = .{
                    .kind = .markdown,
                    .value = "A 32-bit floating-point register. S0-S31.",
                },
            },
            .range = range,
        },
        .d => return .{
            .contents = .{
                .MarkupContent = .{
                    .kind = .markdown,
                    .value = "A 64-bit floating-point register. D0-D31.",
                },
            },
            .range = range,
        },
        else => {},
    }

    return null;
}

pub fn @"textDocument/definition"(
    ls: *LanguageServer,
    _: std.mem.Allocator,
    params: lsp.types.DefinitionParams,
) !lsp.types.getRequestMetadata("textDocument/definition").?.Result {
    const file = ls.files.getPtr(params.textDocument.uri) orelse return null;
    const assembler = try file.assemblerPtr();

    if (file.source.items.len == 0) return null;

    const source_index = lsp.offsets.positionToIndex(file.source.items, params.position, ls.offset_encoding);
    std.log.debug("Hover position: line={d}, character={d}, index={d}", .{ params.position.line, params.position.character, source_index });
    if (file.source.items.len == 0) return null;

    const line_start = std.mem.lastIndexOfScalar(u8, file.source.items[0..source_index], '\n') orelse 0;
    assembler.lex.index = line_start;
    while (assembler.lex.index <= source_index) {
        assembler.lex.next();
    }

    if (source_index < assembler.lex.start or assembler.lex.token != .identifier) {
        return null;
    }

    if (assembler.labels.getKey(assembler.lex.source[assembler.lex.start..assembler.lex.index])) |label| {
        return .{
            .Definition = .{
                .Location = .{
                    .uri = params.textDocument.uri,
                    .range = .{
                        .start = lsp.offsets.indexToPosition(assembler.lex.source, label.ptr - assembler.lex.source.ptr, ls.offset_encoding),
                        .end = lsp.offsets.indexToPosition(assembler.lex.source, label[label.len..].ptr - assembler.lex.source.ptr, ls.offset_encoding),
                    },
                },
            },
        };
    }

    return null;
}

pub fn @"textDocument/didOpen"(
    self: *LanguageServer,
    _: std.mem.Allocator,
    notification: lsp.types.DidOpenTextDocumentParams,
) !void {
    std.log.debug("Received 'textDocument/didOpen' notification", .{});

    const gop = try self.files.getOrPut(self.gpa, notification.textDocument.uri);
    if (gop.found_existing) {
        std.log.warn("Document opened twice: '{s}'", .{notification.textDocument.uri});
    } else {
        errdefer std.debug.assert(self.files.swapRemove(notification.textDocument.uri));
        gop.key_ptr.* = try self.gpa.dupe(u8, notification.textDocument.uri);
        gop.value_ptr.* = .init(self.gpa);
    }

    try gop.value_ptr.reset(notification.textDocument.text);
    try self.analyzeFile(notification.textDocument.uri, gop.value_ptr);
}

pub fn @"textDocument/didChange"(
    self: *LanguageServer,
    _: std.mem.Allocator,
    notification: lsp.types.DidChangeTextDocumentParams,
) !void {
    std.log.debug("Received 'textDocument/didChange' notification", .{});

    const cur_file = self.files.getPtr(notification.textDocument.uri) orelse {
        std.log.warn("Modifying non existent Document: '{s}'", .{notification.textDocument.uri});
        return;
    };

    for (notification.contentChanges) |content_change| {
        switch (content_change) {
            .literal_1 => |change| {
                cur_file.source.clearRetainingCapacity();
                try cur_file.source.appendSlice(self.gpa, change.text);
            },
            .literal_0 => |change| {
                const loc = lsp.offsets.rangeToLoc(cur_file.source.items, change.range, self.offset_encoding);
                try cur_file.source.replaceRange(self.gpa, loc.start, loc.end - loc.start, change.text);
            },
        }
    }

    try self.analyzeFile(notification.textDocument.uri, cur_file);
}

pub fn @"textDocument/didClose"(
    self: *LanguageServer,
    _: std.mem.Allocator,
    notification: lsp.types.DidCloseTextDocumentParams,
) !void {
    std.log.debug("Received 'textDocument/didClose' notification", .{});

    var entry = self.files.fetchSwapRemove(notification.textDocument.uri) orelse {
        std.log.warn("Closing non existent Document: '{s}'", .{notification.textDocument.uri});
        return;
    };
    self.gpa.free(entry.key);
    entry.value.deinit();
}

pub fn onResponse(
    _: *LanguageServer,
    _: std.mem.Allocator,
    response: lsp.JsonRPCMessage.Response,
) void {
    std.log.warn("received unexpected response from client with id '{?}'!", .{response.id});
}
