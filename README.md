# owls Companion

`owls Companion` is the native macOS companion for the Open Workloads CLI. It
provides account status, update availability, and local usage across Claude
Code, Codex, and OpenCode. Subscription meters compare current utilization
with elapsed time in each reset window to show whether the quota is on pace,
close to its limit, or projected to run out before reset.

## Install

Install the `owls` CLI first:

```sh
npm install --global --install-links=true github:OpenWorkloads/owls
```

Then ask the CLI to fetch, build, install, and open the companion:

```sh
owls companion install --from-source
```

The source build requires macOS 14 or newer and the Swift toolchain. The
resulting application is ad hoc signed and installed at:

```text
~/Applications/owls Companion.app
```

Signed and notarized releases will replace the source build when Apple
Developer ID distribution is available.

## Development

```sh
swift test
./build-app.sh
```

Usage works without `owls login`. If a session exists, the Account area reads
it in place without displaying the access token or writing another copy. Local
coding-client credentials, prompts, source code, and usage history are not
uploaded to Open Workloads.

## Updates

The companion checks version manifests for both repositories and presents CLI
and app availability separately. Update the CLI first, then rebuild the native
app:

```sh
owls update
owls companion update --from-source
```
