// Bundles the extension into dist/extension.js (vscode stays external), and with --tests the
// unit tests into out/test/. No runtime dependencies: everything ships in the one file.
import * as esbuild from "esbuild";
import { readdirSync } from "node:fs";

const args = process.argv.slice(2);
const production = args.includes("--production");

if (args.includes("--tests")) {
  await esbuild.build({
    entryPoints: readdirSync("test").filter((f) => f.endsWith(".test.ts")).map((f) => `test/${f}`),
    outdir: "out/test",
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node18",
    external: ["vscode"],
    logLevel: "warning",
  });
} else {
  const ctx = await esbuild.context({
    entryPoints: ["src/extension.ts"],
    outfile: "dist/extension.js",
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node18",
    external: ["vscode"],
    minify: production,
    sourcemap: !production,
    logLevel: "info",
  });
  if (args.includes("--watch")) await ctx.watch();
  else { await ctx.rebuild(); await ctx.dispose(); }
}
