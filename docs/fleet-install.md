# fleet-install — fleet tool release installer

`bin/fleet-install` replaces the desk's ad-hoc install script for the tagged
fleet tools (runtug, pacelever, mergewake, …). One command downloads a GitHub
release, verifies `SHA256SUMS`, installs the right `<tool>-<os>-<arch>` binary
on the operator host and each named remote, then runs the restart hooks from a
local-only config file.

```sh
fleet-install mergewake v1.2.3 --hosts build-a,build-b
fleet-install mergewake v1.2.3 --hosts build-a --dry-run
```

What it does, in order:

1. Polls `gh run list -R mgh3326/<tool> --branch <tag>` until the release
   workflow run for headBranch `<tag>` completes (`--wait-timeout`, default
   1800s; a fresh tag may not have a run row yet, so an empty list keeps
   polling). A non-success conclusion is an error.
2. `gh release download <tag> -R mgh3326/<tool> --clobber` into a temp dir.
3. `shasum -a 256 -c SHA256SUMS` (or `sha256sum -c`). Required, never skipped.
4. Detects this host's `<os>-<arch>` (`uname`, x86_64→amd64, aarch64→arm64) and
   `install -m 755 <tool>-<os>-<arch> ~/.local/bin/<tool>`, then prints
   `<tool> --version`.
5. Per `--hosts` entry: probes `<os>-<arch>` over ssh, `scp` the matching
   binary to `.local/bin/<tool>.new`, then `chmod 755` + `mv -f` into place
   (atomic replace) and prints `<tool> --version`.
6. Runs the configured restart hooks for every target that installed.

Exit codes: `0` all targets ok · `1` at least one target (host or local)
failed — other hosts still install · `2` usage · `3` release wait timed
out/failed or download/checksum error.

## Restart hook config

Host names and which daemon runs where are **local config only** — this repo
is public and must never name real hosts. Default path:

```
~/.config/wrk/fleet-install.toml      # override: FLEET_INSTALL_CONFIG
```

Format (TOML subset — bracket sections, `restart = [ "... strings ..." ]`):

```toml
# Example only — no real hosts.
# [tool.<tool>.local]        hooks run on the operator host via `sh -c`
# [tool.<tool>.host.<name>]  hooks run on the --hosts entry <name> over ssh

[tool.mergewake.local]
restart = ["launchctl kickstart -k gui/$(id -u)/com.example.mergewake"]

[tool.mergewake.host.build-b]
restart = ["systemctl --user restart mergewake.service"]
```

Tools or targets without a section get no restart step. A restart failure
marks that target failed (exit 1).

## Environment overrides

`FLEET_INSTALL_GH` / `FLEET_INSTALL_SSH` / `FLEET_INSTALL_SCP` replace the
`gh`/`ssh`/`scp` binaries, `FLEET_INSTALL_BIN_DIR` the install dir,
`FLEET_INSTALL_CONFIG` the config path, `FLEET_INSTALL_WAIT_TIMEOUT` and
`FLEET_INSTALL_POLL_INTERVAL` the release-wait pacing. Used by
`tests/test-fleet-install.sh`.
