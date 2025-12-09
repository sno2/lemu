import { createStdioOptions, startServer } from "@vscode/wasm-wasi-lsp";
import { Wasm } from "@vscode/wasm-wasi/v1";
import {
  ExtensionContext,
  Uri,
  window,
  workspace,
  env,
  UIKind,
  OutputChannel,
  ProgressLocation,
} from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
} from "vscode-languageclient/node";
import { chmod } from "fs/promises";
import path from "path";

const name = "lemu";
const displayName = "Lemu Language Server";
const args = ["--stdio"];
const checkMs = 3 * 24 * 60 * 1000; // 3 days
const remote = "https://codeberg.org/sno2/lemu/releases/download/latest/";

const CHECK_INSTALL_TIME_KEY = `lemu.checkInstallTime`;
const INSTALL_LAST_MODIFIED_KEY = `lemu.installLastModified`;
const INSTALL_ALWAYS_KEY = `lemu.installAlways`;

async function fetchBinary(
  context: ExtensionContext,
  channel: OutputChannel,
  binaryUri: Uri,
  binaryName: string
) {
  const checkInstallTime = context.globalState.get(CHECK_INSTALL_TIME_KEY, 0);
  const shouldCheckInstall = Date.now() - checkInstallTime >= checkMs;
  let installLastModified = new Date(
    context.globalState.get(INSTALL_LAST_MODIFIED_KEY, 0)
  );

  let binary: Uint8Array | undefined;
  try {
    binary = await workspace.fs.readFile(binaryUri);
    if (!shouldCheckInstall) {
      channel.appendLine("(JS) Using existing binary");
      return binary;
    }
  } catch (err) {
    channel.appendLine(`(JS) Failed to access binary: ${err}`);
    installLastModified = new Date(0);
  }

  try {
    const url = `${remote}${binaryName}`;
    const response = await fetch(url);

    const lastModified = new Date(response.headers.get("Last-Modified") ?? 1);
    if (installLastModified.getTime() === lastModified.getTime()) {
      channel.appendLine(
        '(JS) Using existing binary that matches "Last-Modified" of latest'
      );
      return binary;
    }

    if (!context.globalState.get(INSTALL_ALWAYS_KEY, false)) {
      const result = await window.showInformationMessage(
        binary
          ? "Lemu executable is out of date. Would you like to update it?"
          : "Lemu executable not found. Would you like to download it?",
        "Yes (Always)",
        "Yes",
        "Cancel"
      );

      if (result === "Yes (Always)") {
        await context.globalState.update(INSTALL_ALWAYS_KEY, true);
      } else if (result === "Cancel") {
        throw new Error("user cancellation");
      }
    }

    return await window.withProgress(
      {
        location: ProgressLocation.Notification,
        title: `Downloading ${binaryName}`,
      },
      async () => {
        channel.appendLine(`(JS) Fetching binary: ${url}`);
        const bytes = await response.bytes();
        channel.appendLine(`(JS) Writing binary: "${binaryUri.toString()}"`);
        await workspace.fs.writeFile(binaryUri, bytes as any);
        if (!binaryName.endsWith(".wasm") || !binaryName.endsWith(".exe")) {
          channel.appendLine("(JS) Making binary executable.");
          await chmod(binaryUri.fsPath, 0o755);
        }
        await Promise.all([
          context.globalState.update(CHECK_INSTALL_TIME_KEY, Date.now()),
          context.globalState.update(INSTALL_LAST_MODIFIED_KEY, lastModified),
        ]);
        return bytes;
      }
    );
  } catch (err) {
    channel.appendLine(`(JS) Failed to fetch binary: ${err}`);
    if (binary) {
      return binary;
    }
    throw err;
  }
}

async function getLanguageClient(
  channel: OutputChannel,
  binaryPath: Uri,
  maybeBinary?: Uint8Array
) {
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "LEGv8" }],
    outputChannel: channel,
  };

  if (binaryPath.toString().endsWith(".wasm")) {
    const [wasm, module] = await Promise.all([
      Wasm.load(),
      (async () => {
        const bytes = maybeBinary || (await workspace.fs.readFile(binaryPath));
        return WebAssembly.compile(bytes as any);
      })(),
    ]);
    channel.appendLine("(JS) Compiled WebAssembly module.");

    const process = await wasm.createProcess(
      name,
      module,
      { initial: 160, maximum: 160, shared: false },
      { stdio: createStdioOptions(), args }
    );
    channel.appendLine("(JS) Create WebAssembly process.");

    const decoder = new TextDecoder("utf-8");
    process.stderr!.onData((data) => {
      channel.append(decoder.decode(data));
    });

    return new LanguageClient(
      name,
      displayName,
      () => startServer(process),
      clientOptions
    );
  } else {
    return new LanguageClient(
      name,
      displayName,
      {
        run: { command: binaryPath.fsPath, args },
        debug: { command: binaryPath.fsPath, args },
      },
      clientOptions
    );
  }
}

function getBinaryName() {
  const arch = (
    {
      arm: "arm",
      arm64: "aarch64",
      ia32: "x86",
      x64: "x86_64",
      loong64: "loongarch64",
      ppc64: "powerpc64",
      riscv64: "riscv64",
      s390x: "s390x",
    } as Record<typeof process.arch, string>
  )[process.arch];

  const suffix: string = (
    {
      linux: "linux-musl",
      win32: "windows-gnu.exe",
      darwin: "macos",
    } as Record<typeof process.platform, string>
  )[process.platform];

  return `lemu-${arch}-${suffix}`;
}

let client: LanguageClient;
export async function activate(context: ExtensionContext) {
  const config = workspace.getConfiguration("lemu");
  const exePath = config.get<string>("exePath");
  const isBrowser = env.uiKind == UIKind.Web;

  const channel = window.createOutputChannel("Lemu Language Server");

  try {
    if (exePath) {
      channel.appendLine(`(JS) Using existing executable path: "${exePath}"`);
      client = await getLanguageClient(channel, Uri.file(exePath), undefined);
    } else {
      const binaryName = isBrowser ? "lemu-wasm32-wasi.wasm" : getBinaryName();
      const ext =
        binaryName.indexOf(".") !== -1
          ? binaryName.slice(binaryName.indexOf("."))
          : "";

      const binaryUri = Uri.joinPath(context.globalStorageUri, `lemu${ext}`);
      const binary = await fetchBinary(context, channel, binaryUri, binaryName);

      if (!isBrowser) {
        context.environmentVariableCollection.prepend(
          "PATH",
          `${context.globalStorageUri.fsPath}${path.delimiter}`
        );
      }

      client = await getLanguageClient(channel, binaryUri, binary);
    }
  } catch (e) {
    window.showErrorMessage(`Failed to get Lemu executable: ${e}`);
    return;
  }

  await client.start();
  channel.appendLine("(JS) Language client has started.");
}

export function deactivate(): Thenable<void> | undefined {
  if (!client) {
    return undefined;
  }
  return client.stop();
}
