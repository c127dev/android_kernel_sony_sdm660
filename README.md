# compiler

Build pipeline for the Nitro boot image. Kernel source lives on `nitro-lineage-23.2`.

Run it from the Actions tab with this branch selected, or:

```bash
curl -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/c127dev/android_kernel_sony_sdm660/actions/workflows/build-and-release.yml/dispatches \
    -d '{"ref":"compiler"}'
```

Inputs: `source_ref` is the kernel ref to check out and `source_branch` is the
branch name that ends the release tag, both defaulting to `nitro-lineage-23.2`.
The poller pins `source_ref` to a commit and passes the branch separately.

`build.sh` compiles the kernel, `build_boot.sh` repacks a boot image locally.
Both take the kernel tree from `KERNEL_DIR`, which defaults to the script's own
directory:

```bash
KERNEL_DIR=/path/to/android_kernel_sony_sdm660 ./build.sh
KERNEL_DIR=/path/to/android_kernel_sony_sdm660 ./build_boot.sh --boot stock.img
```

`build.sh` wipes `out/` first. `--incremental` keeps it and rebuilds only what
changed; `build_boot.sh` forwards `--incremental` and `--no-cache`. ccache is on
by default, its cache is `.ccache/` inside the kernel tree.

The workflow downloads the newest official LineageOS `boot.img` for `pioneer`,
compiles the kernel with `build.sh`, repacks it with `magiskboot` and publishes
a release tagged `vYYYY.MM.DD.<run number>.<branch>`. The `LineageOS-Build:` line in the release
body is machine-read by the scheduled check; do not change its format.

Every dispatch builds. Deciding whether a build is due belongs to the poller
that dispatches it - `c127dev/autobuild`, watcher `nitro-kernel`, which fires on
a new `boot.img` sha256 in the LineageOS API.

A push to this branch registers the workflow with the Actions index and stops
before building.
