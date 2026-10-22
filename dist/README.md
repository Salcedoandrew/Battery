`smc` in this folder is a universal (Apple Silicon + Intel) build of the `smc-command` tool from [hholtmann/smcFanControl](https://github.com/hholtmann/smcFanControl) at commit `e1bd672`. It is shipped as a separate, unmodified executable under its own license, GPL-2, included here as `./LICENSE`.

Rebuild it (Xcode Command Line Tools are enough) with:

```shell
./dist/build-smc.sh          # or: ./dist/build-smc.sh <commit>
```

This clones smcFanControl, compiles `smc-command/smc.c` with `-DCMD_TOOL_BUILD` for `arm64` and `x86_64`, and merges both with `lipo` into `dist/smc`.
