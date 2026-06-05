# Deno Public API Coverage

This plugin is a native SA replacement surface for Deno-compatible APIs. It does not call the `deno` executable or embed the Deno runtime.

## Source Of Truth

- Stable Deno namespace: `/home/vscode/projects/deno/cli/tsc/dts/lib.deno.ns.d.ts`
- Deno networking declarations: `/home/vscode/projects/deno/cli/tsc/dts/lib.deno_net.d.ts`
- Deno web/global declarations: `/home/vscode/projects/deno/cli/tsc/dts/lib.deno_web*.d.ts`
- Unstable declarations: `/home/vscode/projects/deno/cli/tsc/dts/lib.deno.unstable.d.ts`

## Current Native Surface

Published SA files:

- `deno.sai`: C-ABI `@extern` declarations.
- `deno.sal`: SA macro facade over slot allocation and output loading.

Current status:

- `implemented`: host/sys info, pid/ppid/uid/gid, memory usage, env get/set/delete, text file read/write, random UUID, args JSON, base64 helpers, text encode/decode byte helpers, version/build JSON, wall-clock time, mkdir/remove/copy/readDir/lstat, command output.
- `planned_native`: the remaining stable Deno namespace APIs from the source declarations, especially cwd/chdir, chmod/chown, rename, binary read/write, stat/realPath/readLink/symlink/truncate, temp files/dirs, umask/kill, DNS, permissions, file handles, and network handles.
- `stub_unsupported`: runtime-heavy APIs that need a larger native subsystem before behavior can be compatible, including test/bench registration, full Web APIs, WebGPU, KV, lint, Jupyter, and browser-style event objects.
- `type_only`: TypeScript-only helper types that do not map directly to an SA runtime symbol.

Before adding a new `@extern`, update `deno.sai`, add a matching `pub export fn sa_deno_plugin_*` symbol, and run `tests/deno-symbol-interface-smoke.sh`.
