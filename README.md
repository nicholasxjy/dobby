# Dobby

Dobby is a free macOS menu bar process monitor — a lighter, clearer take on Activity Monitor.

## Demo

![Dobby CPU tab showing usage history and system processes](docs/images/demo.png)

## Features

- **CPU, Memory and Ports tabs.** Each tab shows its system-wide total, with iStat Menus–style history graphs (CPU split into user/system, memory colored by pressure) above a dense list.
- **Stable lists.** CPU and memory lists sort by usage, highest first. Rows stop reordering while the pointer is over the list, so you never click the wrong process.
- **Port exposure at a glance.** The Ports tab lists listening TCP and bound UDP ports, sorted by port number, and marks each one as **Local** (local-only) or **LAN** (reachable from the network).
- **Quit or force quit.** Select a row, then choose **Quit** — apps get a normal Quit, other processes get SIGTERM — or **Force Quit** — SIGKILL, press twice to confirm. Closing a port means ending the process that holds it.
- **Keyboard first.** Type to search, `↑` / `↓` to select, `⌘⌫` to quit, `⌥⌘⌫` to force quit, `⌘1` / `⌘2` / `⌘3` to switch tabs, `Esc` to clear, `⌘Q` to quit Dobby.
- **Light on resources.** Processes are sampled every 2 seconds, and only while the panel is open. System totals for the graphs are sampled in the background with two cheap host calls.
- **Settings menu** (gear icon in the footer):
  - **Appearance**: System, Light or Dark, remembered across launches.
  - **Show Stats in Menu Bar**: adds an iStat Menus–style readout next to the menu bar icon — CPU %, memory used % and the number of open ports, each as an icon plus a number. Hover it for the full values. While it is on, Dobby also counts ports in the background (a few milliseconds every 2 seconds).
  - **Launch at Login**: starts Dobby automatically when you log in. macOS may ask you to allow it under *System Settings › General › Login Items*; Dobby opens that page for you. You can also turn it off there.
- **System processes**: shows processes and ports owned by root and other users, and lets you end them. See below.

### System processes

Turning on **System processes** asks for an administrator password, then starts `DobbyHelper` as root. The helper:

- only reads process and port data and relays SIGTERM / SIGKILL;
- accepts requests only from the Dobby process that launched it;
- exits when Dobby quits or the option is turned off, so nothing stays installed.

`launchd`, `kernel_task`, `WindowServer` and `loginwindow` can never be ended from Dobby.

## Requirements

- macOS 14 or later
- Swift 6 (the Command Line Tools are enough; Xcode is not required)

## Build and run

```sh
./scripts/test.sh        # unit tests plus live process, socket and helper tests
./scripts/build-app.sh   # builds build/Dobby.app (ad-hoc signed)
open build/Dobby.app
```

The app icon is drawn in code: edit `scripts/make-icon.swift`, then run `swift scripts/make-icon.swift` to regenerate `Resources/AppIcon.icns`.

`scripts/test.sh` works around a Command Line Tools bug where SwiftPM sometimes fails to find the swift-testing macro plugin.

Launch at login and System processes need the bundled app: run Dobby from `build/Dobby.app` (ideally moved to `/Applications`), not via `swift run`.

## Snapshots

To render the panel to a PNG without opening it:

```sh
DOBBY_SNAPSHOT=out.png .build/debug/Dobby
```

Optional variables:

| Variable | Values |
| --- | --- |
| `DOBBY_SNAPSHOT_TAB` | `memory`, `ports`, `menubar` (the menu bar readout; default: CPU) |
| `DOBBY_SNAPSHOT_THEME` | `system`, `light`, `dark` |
| `DOBBY_SNAPSHOT_SELECT` | row index to select |
| `DOBBY_SNAPSHOT_WAIT` | seconds to wait before capturing (default `2.6`) |

## License

MIT — see [LICENSE](LICENSE).
