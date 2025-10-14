//! Virtual memory for LEGv8.

const std = @import("std");

const Memory = @This();

pub const text_start = 0x40_0000;
pub const text_end = 0x1000_0000;
pub const dynamic_end = 0x7f_ffff_fffc;

pub const Mapped = union(enum) {
    reserved,
    /// Non-standard. Provided to make loads and stores to dynamic memory
    /// simpler. You should just use the stack, though.
    zero_page: u32,
    text: u32,
    dynamic: u64,

    pub fn init(memory: *const Memory, addr: u64) Mapped {
        if (addr < memory.zero_page.items.len) {
            std.debug.assert(memory.zero_page.items.len < text_start);
            return .{ .zero_page = @intCast(addr) };
        } else if (addr < text_start) {
            return .reserved;
        } else if (addr < text_end) {
            return .{ .text = @intCast(addr - text_start) };
        } else if (addr < dynamic_end) {
            return .{ .dynamic = addr - (text_start + text_end) };
        } else {
            return .reserved;
        }
    }
};

page_len: usize,
gpa: std.mem.Allocator,
dynamic: std.AutoArrayHashMapUnmanaged(u64, []u8),
zero_page: std.ArrayList(u8),
readonly: std.ArrayList(u32),

pub const Error = error{InvalidAddress} || std.mem.Allocator.Error;

pub fn init(gpa: std.mem.Allocator) Memory {
    return .{
        .page_len = std.heap.pageSize(),
        .gpa = gpa,
        .dynamic = .empty,
        .zero_page = .empty,
        .readonly = .empty,
    };
}

pub fn deinit(memory: *Memory, gpa: std.mem.Allocator) void {
    for (memory.dynamic.values()) |page| {
        memory.gpa.free(page);
    }
    memory.dynamic.deinit(gpa);
    memory.zero_page.deinit(gpa);
    memory.readonly.deinit(gpa);
}

fn accessZeroPageMemory(mem: *Memory, comptime T: type, index: u32) Error!*align(1) T {
    if (index >= mem.zero_page.items.len or mem.zero_page.items[index..].len < @sizeOf(T)) {
        return error.InvalidAddress;
    }
    return @ptrCast(mem.zero_page.items[index..][0..@sizeOf(T)]);
}

fn accessReadonlyMemory(mem: *Memory, comptime T: type, index: u32) Error!*align(1) T {
    const byte_slice: []u8 = @ptrCast(mem.readonly.items);
    if (index >= byte_slice.len or byte_slice[index..].len < @sizeOf(T)) {
        return error.InvalidAddress;
    }
    return @ptrCast(byte_slice[index..][0..@sizeOf(T)]);
}

/// Access a page's slice from the index's offset in the page. Creates a new
/// page if there is not already one present.
fn accessDynamicMemory(mem: *Memory, index: u64) Error![]u8 {
    const gop = try mem.dynamic.getOrPut(mem.gpa, index / mem.page_len);
    if (!gop.found_existing) {
        gop.value_ptr.* = try mem.gpa.alloc(u8, mem.page_len);
    }
    return gop.value_ptr.*[@intCast(index % mem.page_len)..]; // @intCast required for wasi
}

pub fn loadAlignedReadonlyMemory(mem: *Memory, index: usize) Error!u32 {
    if (index >= mem.readonly.items.len) {
        return error.InvalidAddress;
    }
    return mem.readonly.items[index];
}

fn BackingInt(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int => T,
        .float => std.meta.Int(.unsigned, @bitSizeOf(T)),
        else => @compileError(std.fmt.comptimePrint("{}", .{T})),
    };
}

pub fn load(mem: *Memory, comptime T: type, addr: u64) Error!T {
    const result = try mem.loadBig(T, addr);
    return @bitCast(std.mem.bigToNative(BackingInt(T), @bitCast(result)));
}

fn loadBig(mem: *Memory, comptime T: type, addr: u64) Error!T {
    std.debug.assert(@sizeOf(T) <= std.heap.page_size_min);
    switch (Mapped.init(mem, addr)) {
        .reserved => return error.InvalidAddress,
        .zero_page => |zpg| {
            const ptr = try mem.accessZeroPageMemory(T, zpg);
            return ptr.*;
        },
        .text => |text| {
            const ptr = try mem.accessReadonlyMemory(T, text);
            return ptr.*;
        },
        .dynamic => |dynamic| {
            const page1_slice = try mem.accessDynamicMemory(dynamic);

            if (page1_slice.len >= @sizeOf(T)) {
                const ptr: *align(1) T = @ptrCast(page1_slice[0..@sizeOf(T)]);
                return ptr.*;
            }

            const page2_slice = try mem.accessDynamicMemory(dynamic + page1_slice.len);
            var result: [@sizeOf(T)]u8 = undefined;
            @memcpy(result[0..page1_slice.len], page1_slice[0..]);
            @memcpy(result[0..page2_slice.len], page2_slice[0 .. @sizeOf(T) - page1_slice.len]);
            const ptr: *align(1) T = @ptrCast(result[0..]);
            return ptr.*;
        },
    }
}

pub fn store(mem: *Memory, comptime T: type, addr: u64, value: T) Error!void {
    const big_value = std.mem.nativeToBig(BackingInt(T), @bitCast(value));
    try mem.storeBig(T, addr, @bitCast(big_value));
}

fn storeBig(mem: *Memory, comptime T: type, addr: u64, value: T) Error!void {
    switch (Mapped.init(mem, addr)) {
        .reserved => return error.InvalidAddress,
        .zero_page => |zpg| {
            const ptr = try mem.accessZeroPageMemory(T, zpg);
            ptr.* = value;
        },
        .text => |text| {
            const ptr = try mem.accessReadonlyMemory(T, text);
            ptr.* = value;
        },
        .dynamic => |dynamic| {
            const page1_slice = try mem.accessDynamicMemory(dynamic);

            if (page1_slice.len >= @sizeOf(T)) {
                @branchHint(.likely);
                const ptr: *align(1) T = @ptrCast(page1_slice[0..@sizeOf(T)]);
                ptr.* = value;
                return;
            }

            const page2_slice = try mem.accessDynamicMemory(dynamic + page1_slice.len);
            const value_slice = std.mem.toBytes(value);
            @memcpy(page1_slice, value_slice[0..page1_slice.len]);
            @memcpy(page2_slice[0 .. @sizeOf(T) - page1_slice.len], value_slice[page1_slice.len..]);
        },
    }
}
