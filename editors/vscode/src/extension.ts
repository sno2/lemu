import { ExtensionContext, workspace } from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(_: ExtensionContext) {
  const config = workspace.getConfiguration("lemu");
  const exePath = config.get<string>("exePath", "lemu");

  const serverOptions: ServerOptions = {
    run: {
      command: exePath,
      transport: TransportKind.stdio,
    },
    debug: {
      command: exePath,
      transport: TransportKind.stdio,
    },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "LEGv8" }],
  };

  client = new LanguageClient("lemu", "lemu", serverOptions, clientOptions);
  client.start();
}

export function deactivate(): Thenable<void> | undefined {
  if (!client) {
    return undefined;
  }
  return client.stop();
}
