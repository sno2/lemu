const std = @import("std");

const release_target_queries: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .x86, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
    .{ .cpu_arch = .wasm64, .os_tag = .wasi },
};

pub fn build(b: *std.Build) !void {
    for (release_target_queries) |release_target_query| {
        const release_target = b.resolveTargetQuery(release_target_query);

        const lemu = b.dependency("lemu", .{
            .target = release_target,
            .optimize = .ReleaseSafe,
            .strip = true,
        });

        const lemu_exe = lemu.artifact("lemu");
        const lemu_exe_name = b.fmt("lemu-{s}{s}", .{ try release_target.query.zigTriple(b.graph.arena), release_target.result.exeFileExt() });
        const install_lemu_exe = b.addInstallArtifact(lemu_exe, .{ .dest_sub_path = lemu_exe_name });
        b.getInstallStep().dependOn(&install_lemu_exe.step);
    }
}
