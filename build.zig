const std = @import("std");

const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lsp: bool,
    debugger: bool,
    strip: ?bool,
    fuzz_seed: ?u64,
    name: []const u8 = "lemu",
};

const release_target_queries: []const std.Target.Query = &.{
    .{ .os_tag = .linux, .cpu_arch = .aarch64, .abi = .musl },
    .{ .os_tag = .linux, .cpu_arch = .arm, .abi = .musl },
    .{ .os_tag = .linux, .cpu_arch = .loongarch64, .abi = .musl },
    .{ .os_tag = .linux, .cpu_arch = .powerpc64le, .abi = .musl },
    .{ .os_tag = .linux, .cpu_arch = .riscv64, .abi = .musl },
    .{ .os_tag = .linux, .cpu_arch = .s390x, .abi = .musl },
    .{ .os_tag = .linux, .cpu_arch = .x86_64, .abi = .musl },
    .{ .os_tag = .linux, .cpu_arch = .x86, .abi = .musl },
    .{ .os_tag = .macos, .cpu_arch = .aarch64 },
    .{ .os_tag = .macos, .cpu_arch = .x86_64 },
    .{ .os_tag = .wasi, .cpu_arch = .wasm32 },
    .{ .os_tag = .wasi, .cpu_arch = .wasm64 },
    .{ .os_tag = .windows, .cpu_arch = .aarch64, .abi = .gnu },
    .{ .os_tag = .windows, .cpu_arch = .x86_64, .abi = .gnu },
    .{ .os_tag = .windows, .cpu_arch = .x86, .abi = .gnu },
};

pub fn build(b: *std.Build) !void {
    const config: Config = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .lsp = b.option(bool, "lsp", "Include LSP support (defaults to true)") orelse true,
        .debugger = b.option(bool, "debugger", "Include debugger support (defaults to true)") orelse true,
        .strip = b.option(bool, "strip", "Strip debug information"),
        .fuzz_seed = b.option(u64, "fuzz-seed", "Fuzz seed"),
    };
    const maybe_release = b.option(enum { build, publish }, "release", "Release mode (publish requires 'git' and an authenticated 'tea' CLI)") orelse null;

    const config_exe = buildInner(b, config, true);
    if (maybe_release == null) {
        b.installArtifact(config_exe);
    }

    if (maybe_release) |release| {
        var files: std.ArrayList(*std.Build.Step.Compile) = .empty;

        for (release_target_queries) |release_target_query| {
            const release_target = b.resolveTargetQuery(release_target_query);

            const release_exe_name = b.fmt("lemu-{s}", .{try release_target.query.zigTriple(b.graph.arena)});

            const release_exe = buildInner(b, .{
                .target = release_target,
                .optimize = .ReleaseSafe,
                .lsp = true,
                .debugger = true,
                .strip = true,
                .fuzz_seed = null,
                .name = release_exe_name,
            }, false);
            try files.append(b.graph.arena, release_exe);

            const install_release_exe = b.addInstallArtifact(release_exe, .{});
            if (release == .build) {
                b.getInstallStep().dependOn(&install_release_exe.step);
            }
        }

        if (release == .publish) {
            const delete_release = b.addSystemCommand(&.{ "tea", "release", "delete", "latest", "-y" });

            const delete_tag = b.addSystemCommand(&.{ "git", "push", "--delete", "origin", "latest" });
            delete_tag.step.dependOn(&delete_release.step);

            const sleep = b.addSystemCommand(&.{ "sleep", "3" }); // necessary because there seems to be a race condition
            sleep.step.dependOn(&delete_tag.step);

            const create_release = b.addSystemCommand(&.{ "tea", "release", "create", "--prerelease", "--tag", "latest", "--title", "latest", "--note", "Latest manual release.", "--repo", "sno2/lemu" });
            create_release.step.dependOn(&sleep.step);

            for (files.items) |file| {
                create_release.addArg("--asset");
                create_release.addArtifactArg(file);
            }

            b.getInstallStep().dependOn(&create_release.step);
        }
    }
}

fn buildInner(b: *std.Build, config: Config, include_steps: bool) *std.Build.Step.Compile {
    const build_options = b.addOptions();
    build_options.addOption(bool, "lsp", config.lsp);
    build_options.addOption(bool, "debugger", config.debugger);
    const build_options_mod = build_options.createModule();

    const mod = b.addModule("lemu", .{
        .target = config.target,
        .optimize = config.optimize,
        .root_source_file = b.path("src/lemu.zig"),
        .strip = config.strip,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    const exe_mod = b.createModule(.{
        .target = config.target,
        .optimize = config.optimize,
        .root_source_file = b.path("src/cli.zig"),
        .imports = &.{
            .{ .name = "lemu", .module = mod },
            .{ .name = "options", .module = build_options_mod },
        },
        .strip = config.strip,
        .link_libc = if (config.target.result.os.tag == .windows) true else null,
    });

    const exe = b.addExecutable(.{
        .name = config.name,
        .root_module = exe_mod,
    });

    if (config.lsp) blk: {
        const lsp_kit = b.lazyDependency("lsp_kit", .{}) orelse break :blk;
        const lsp_mod = lsp_kit.module("lsp");
        mod.addImport("lsp", lsp_mod);
        exe.root_module.addImport("lsp", lsp_mod);
    }

    if (config.debugger) blk: {
        const zigline_dep = b.lazyDependency("zigline", .{}) orelse break :blk;
        const zigline_mod = zigline_dep.module("zigline");
        exe.root_module.addImport("zigline", zigline_mod);
    }

    if (include_steps) {
        const mod_tests = b.addTest(.{ .root_module = mod });
        b.installArtifact(mod_tests);

        const run_mod_tests = b.addRunArtifact(mod_tests);
        const exe_tests = b.addTest(.{ .root_module = exe.root_module });

        const run_exe_tests = b.addRunArtifact(exe_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
        test_step.dependOn(&run_exe_tests.step);

        const test_runner = b.addExecutable(.{
            .name = "test_runner",
            .root_module = b.createModule(.{
                .target = config.target,
                .optimize = config.optimize,
                .root_source_file = b.path("src/test_runner.zig"),
                .link_libc = if (config.target.result.os.tag == .wasi) true else null,
            }),
        });

        for (syntax_tests) |test_path| {
            const run_syntax_test = b.addRunArtifact(test_runner);
            run_syntax_test.setName(test_path);
            run_syntax_test.addArtifactArg(exe);
            run_syntax_test.addArg("syntax");
            run_syntax_test.addArg(test_path);
            test_step.dependOn(&run_syntax_test.step);
        }

        for (behavior_tests) |test_path| {
            const run_behavior_test = b.addRunArtifact(test_runner);
            run_behavior_test.setName(test_path);
            run_behavior_test.addArtifactArg(exe);
            run_behavior_test.addArg("behavior");
            run_behavior_test.addArg(test_path);
            test_step.dependOn(&run_behavior_test.step);
        }

        const fuzz_step = b.step("fuzz", "Run fuzz tests against legv8emul");

        const fuzz_runner_exe = b.addExecutable(.{
            .name = "fuzz_runner",
            .root_module = b.createModule(.{
                .target = config.target,
                .optimize = config.optimize,
                .root_source_file = b.path("src/fuzz_runner.zig"),
                .imports = &.{
                    .{ .name = "lemu", .module = mod },
                },
            }),
        });

        const run_fuzz_runner_exe = b.addRunArtifact(fuzz_runner_exe);
        run_fuzz_runner_exe.stdio = .inherit;
        run_fuzz_runner_exe.addArtifactArg(exe);
        run_fuzz_runner_exe.addFileArg(b.path("legv8emul"));
        _ = run_fuzz_runner_exe.addOutputFileArg("fuzz.lv8");
        run_fuzz_runner_exe.addArg(if (config.fuzz_seed) |seed| b.fmt("{}", .{seed}) else "none");

        fuzz_step.dependOn(&run_fuzz_runner_exe.step);

        const tmlanguage_step = b.step("tmLanguage", "Generate textmate grammar");

        const tmlanguage = b.addExecutable(.{
            .name = "tmLanguage",
            .root_module = b.createModule(.{
                .target = b.graph.host,
                .root_source_file = b.path("src/grammars/tmLanguage.zig"),
                .imports = &.{
                    .{ .name = "lemu", .module = mod },
                },
            }),
        });

        const run_tmlanguage = b.addRunArtifact(tmlanguage);
        const tmlanguage_json = run_tmlanguage.captureStdOut();
        const update_src = b.addUpdateSourceFiles();
        update_src.addCopyFileToSource(tmlanguage_json, "editors/vscode/syntaxes/legv8.tmLanguage.json");
        tmlanguage_step.dependOn(&update_src.step);

        const code_snippets_step = b.step("codeSnippets", "Generate code snippets");

        const code_snippets = b.addExecutable(.{
            .name = "code_snippets",
            .root_module = b.createModule(.{
                .target = b.graph.host,
                .root_source_file = b.path("src/code_snippets.zig"),
                .imports = &.{
                    .{ .name = "lemu", .module = mod },
                },
            }),
        });

        const run_code_snippets = b.addRunArtifact(code_snippets);
        const code_snippets_json = run_code_snippets.captureStdOut();
        const update_snippet_src = b.addUpdateSourceFiles();
        update_snippet_src.addCopyFileToSource(code_snippets_json, "editors/vscode/legv8.code-snippets");
        code_snippets_step.dependOn(&update_snippet_src.step);

        const package_step = b.step("package", "Package extensions; requires 'vsce'");

        const base_content_url = "https://codeberg.org/sno2/lemu/raw/branch/main/editors/vscode";

        const run_vsce_package = b.addSystemCommand(&.{ "vsce", "package", "--baseContentUrl", base_content_url });
        run_vsce_package.setCwd(b.path("editors/vscode"));
        package_step.dependOn(&run_vsce_package.step);

        const publish_step = b.step("publish", "Publish extensions; requires 'vsce' and 'ovsx'");

        const run_vsce_publish = b.addSystemCommand(&.{ "vsce", "publish", "--baseContentUrl", base_content_url });
        run_vsce_publish.setCwd(b.path("editors/vscode"));
        publish_step.dependOn(&run_vsce_publish.step);

        const run_ovsx_publish = b.addSystemCommand(&(.{ "ovsx", "publish", "--baseContentUrl", base_content_url }));
        run_ovsx_publish.setCwd(b.path("editors/vscode"));
        publish_step.dependOn(&run_ovsx_publish.step);
    }

    return exe;
}

const syntax_tests: []const []const u8 = &.{
    "test/syntax/arith_immediate_overflow.lv8",
    "test/syntax/error_after_undefined_label.lv8",
    "test/syntax/error_on_duplicate_label.lv8",
    "test/syntax/error_on_lsl_overflow.lv8",
    "test/syntax/error_on_lsr_overflow.lv8",
    "test/syntax/error_on_unknown_mneumonic.lv8",
    "test/syntax/label_with_dot.lv8",
    "test/syntax/memory_offset_overflow.lv8",
    "test/syntax/mov_immediate_overflow.lv8",
    "test/syntax/mov_invalid.lv8",
    "test/syntax/mov_shift_overflow.lv8",
    "test/syntax/multiline_instruction.lv8",
    "test/syntax/multiple_instructions_on_line.lv8",
    "test/syntax/stxr_invalid_operands.lv8",
    "test/syntax/unexpected_registers.lv8",
};

const behavior_tests: []const []const u8 = &.{
    "test/behavior/add.lv8",
    "test/behavior/brlr.lv8",
    "test/behavior/bytes.lv8",
    "test/behavior/cmp.lv8",
    "test/behavior/cmpi.lv8",
    "test/behavior/empty.lv8",
    "test/behavior/fib.lv8",
    "test/behavior/halt.lv8",
    "test/behavior/halves.lv8",
    "test/behavior/isprime.lv8",
    "test/behavior/lda.lv8",
    "test/behavior/max_index.lv8",
    "test/behavior/mov.lv8",
    "test/behavior/parity.lv8",
    "test/behavior/popcnt.lv8",
    "test/behavior/prnl.lv8",
    "test/behavior/prnt.lv8",
    "test/behavior/rand.lv8",
    "test/behavior/shift.lv8",
    "test/behavior/swap.lv8",
    "test/behavior/zpg_bounds.lv8",
    "test/behavior/zpg_fail.lv8",
    "test/behavior/zpg.lv8",
};
