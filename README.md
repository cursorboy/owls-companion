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

## Session schedule

A Claude session window lasts five hours. It opens on the first request sent
after the last window lapsed, so whenever that request happens decides when
every window for the rest of the day starts and ends. Send your first prompt at
10:40 and the window runs to 15:40, which wastes the part of it you spent at
lunch.

The Schedule section fixes the start times instead. Set anchors, and at each one
the companion sends a single small prompt to open a window:

- Anchors carry a time of day and the weekdays they run on.
- The default is 08:00, 13:00, and 18:00 on weekdays, which are exactly one
  window apart and cover fifteen hours end to end.
- The coverage bar shows the parts of today a window holds open, and marks any
  gap between windows.
- An anchor that lands inside a window opened earlier is flagged, because a
  request during an open window joins that window rather than starting a new
  one.
- When a window is already open the anchor is skipped, so quota is not spent on
  a request that would change nothing.
- Whether a window is open is worked out from three sources, because no single
  one is reliable. The usage service reports how much of the window is used but
  often omits the time it lapses. Local Claude Code history carries request
  timestamps, and the window boundaries can be rebuilt from them by anchoring
  on the last request that followed five hours of quiet. A window this app
  opened itself is known exactly.
- A missed anchor still runs for the length of the catch up period, so a Mac
  asleep at 08:00 opens the window when it wakes.

Choose whether each anchor opens the window itself or only sends a reminder.
Opening one costs about a cent, because even a one word prompt loads a system
prompt. Weekly quota is spent whichever way the window opens, so anchor the
hours you actually work.

The prompt runs through the `claude` command already installed on this Mac,
using the login it already holds. It runs in a directory of its own, so it never
reads a `CLAUDE.md` from one of your projects and never writes into one. Set the
path in Settings if `claude` lives somewhere unusual.

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
