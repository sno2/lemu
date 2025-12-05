const build_options = @import("build_options");

pub const Assembler = @import("Assembler.zig");
pub const Compilation = @import("Compilation.zig");
pub const Debugger = @import("Debugger.zig");
pub const Instruction = @import("instruction.zig").Instruction;
pub const LanguageServer = @import("LanguageServer.zig");
pub const Memory = @import("Vm/Memory.zig");
pub const Vm = @import("Vm.zig");

test {
    _ = Assembler;
    _ = Vm;
    _ = Memory;
    _ = Instruction;
    _ = Compilation;
    if (build_options.lsp) {
        _ = LanguageServer;
    }
    if (build_options.debugger) {
        _ = Debugger;
    }
}
