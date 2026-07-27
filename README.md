# owls Companion

`owls Companion` is the native macOS companion for the Open Workloads CLI. It
provides account status, update availability, and local usage across Claude
Code, Codex, and OpenCode.

## Install

Install the `owls` CLI first:

```sh
npm install --global github:OpenWorkloads/owls
owls login
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

The companion reads the current `owls login` session in place. It does not
display the access token or write another copy. Local coding-client credentials,
prompts, source code, and usage history are not uploaded to Open Workloads.

## Updates

The companion checks version manifests for both repositories and presents CLI
and app availability separately. Update the CLI first, then rebuild the native
app:

```sh
owls update
owls companion update --from-source
```
