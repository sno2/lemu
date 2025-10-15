const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lsp = b.option(bool, "lsp", "Include LSP support (defaults to true)") orelse true;
    const debugger = b.option(bool, "debugger", "Include debugger support (defaults to true)") orelse true;
    const strip = b.option(bool, "strip", "Strip debug information") orelse false;
    const fuzz_seed = b.option(u64, "fuzz-seed", "Fuzz seed");

    const build_options = b.addOptions();
    build_options.addOption(bool, "lsp", lsp);
    build_options.addOption(bool, "debugger", debugger);
    const build_options_mod = build_options.createModule();

    const mod = b.addModule("lemu", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/lemu.zig"),
        .strip = strip,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/cli.zig"),
        .imports = &.{
            .{ .name = "lemu", .module = mod },
            .{ .name = "options", .module = build_options_mod },
        },
        .strip = strip,
        .link_libc = if (target.result.os.tag == .windows) true else null,
    });

    const exe = b.addExecutable(.{
        .name = "lemu",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    if (lsp) blk: {
        const lsp_kit = b.lazyDependency("lsp_kit", .{}) orelse break :blk;
        const lsp_mod = lsp_kit.module("lsp");
        mod.addImport("lsp", lsp_mod);
        exe.root_module.addImport("lsp", lsp_mod);
    }

    if (debugger) blk: {
        const zigline_dep = b.lazyDependency("zigline", .{}) orelse break :blk;
        const zigline_mod = zigline_dep.module("zigline");
        exe.root_module.addImport("zigline", zigline_mod);
    }

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
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/test_runner.zig"),
            .link_libc = if (target.result.os.tag == .wasi) true else null,
        }),
    });

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

    for (syntax_tests) |test_path| {
        const run_syntax_test = b.addRunArtifact(test_runner);
        run_syntax_test.setName(test_path);
        run_syntax_test.addArtifactArg(exe);
        run_syntax_test.addArg("syntax");
        run_syntax_test.addArg(test_path);
        test_step.dependOn(&run_syntax_test.step);
    }

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
        "test/behavior/mov.lv8",
        "test/behavior/parity.lv8",
        "test/behavior/popcnt.lv8",
        "test/behavior/prnl.lv8",
        "test/behavior/prnt.lv8",
        "test/behavior/rand.lv8",
        "test/behavior/shift.lv8",
        "test/behavior/zpg_bounds.lv8",
        "test/behavior/zpg_fail.lv8",
        "test/behavior/zpg.lv8",
    };

    for (behavior_tests) |test_path| {
        const run_behavior_test = b.addRunArtifact(test_runner);
        run_behavior_test.setName(test_path);
        run_behavior_test.addArtifactArg(exe);
        run_behavior_test.addArg("behavior");
        run_behavior_test.addArg(test_path);
        test_step.dependOn(&run_behavior_test.step);
    }

    {
        const fuzz_step = b.step("fuzz", "Run fuzz tests against legv8emul");

        const fuzz_runner_exe = b.addExecutable(.{
            .name = "fuzz_runner",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
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
        run_fuzz_runner_exe.addArg(if (fuzz_seed) |seed| b.fmt("{}", .{seed}) else "none");

        fuzz_step.dependOn(&run_fuzz_runner_exe.step);
    }

    {
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
    }

    {
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
        const update_src = b.addUpdateSourceFiles();
        update_src.addCopyFileToSource(code_snippets_json, "editors/vscode/legv8.code-snippets");
        code_snippets_step.dependOn(&update_src.step);
    }
}
