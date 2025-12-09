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
const expireMs = 30 * 24 * 60 * 1000; // 30 days
const remote = "https://codeberg.org/sno2/lemu/releases/download/latest/";

async function fetchBinary(
  channel: OutputChannel,
  binaryUri: Uri,
  binaryName: string,
  wantBytes: boolean
) {
  try {
    const stat = await workspace.fs.stat(binaryUri);
    if (new Date().getTime() - stat.ctime < expireMs) {
      channel.appendLine("(JS) Cache hit for binary.");
      return wantBytes ? workspace.fs.readFile(binaryUri) : undefined;
    }
    throw "too old"; // yeet
  } catch (err) {
    channel.appendLine(`(JS) Cache miss for binary: ${err}`);
  }

  return window.withProgress(
    {
      location: ProgressLocation.Notification,
      title: `Downloading ${binaryName}`,
    },
    async () => {
      const input = `${remote}${binaryName}`;
      channel.appendLine(`(JS) Fetching binary: ${input}`);
      const response = await fetch(input);
      const bytes = await response.bytes();
      channel.appendLine(`(JS) Writing binary: "${binaryUri.toString()}"`);
      await workspace.fs.writeFile(binaryUri, bytes as any);
      return bytes;
    }
  );
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
    const binary = await fetchBinary(channel, binaryUri, binaryName, isBrowser);
    if (!isBrowser && !binaryName.endsWith(".exe")) {
      channel.appendLine("(JS) Adding executable flags to binary");
      await chmod(binaryUri.fsPath, 0o755);
    }
    if (!isBrowser) {
      context.environmentVariableCollection.prepend(
        "PATH",
        `${context.globalStorageUri.fsPath}${path.delimiter}`
      );
    }

    client = await getLanguageClient(channel, binaryUri, binary);
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
