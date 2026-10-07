# dobby

Dobby is free — a macOS menu bar process monitor: a lighter, clearer take on Activity Monitor.

- **CPU / 内存 / 端口** tabs, each showing its system-wide total, with iStat Menus–style history graphs (CPU user/system, memory by pressure) above a dense list.
- CPU and memory lists sort by usage, high to low. Rows stop reordering while the pointer is over the list, so you don't click the wrong process.
- The ports tab lists listening TCP and bound UDP ports, sorted by port number, and marks whether each port is local-only (仅本机) or reachable from the network (局域网可访问).
- Select a row to **退出** (graceful: apps get a normal Quit, other processes SIGTERM) or **强制退出** (SIGKILL, press twice to confirm). Closing a port means ending the process that holds it.
- Keyboard: type to search, `↑↓` select, `⌘⌫` quit, `⌥⌘⌫` force quit, `⌘1/2/3` switch tabs, `Esc` clear.
- Processes are sampled every 2 s only while the panel is open; system totals for the graphs are sampled in the background (two cheap host calls).
- Appearance menu in the footer: 跟随系统 / 浅色 / 深色, remembered across launches.
- **含系统进程**: lists root and other users' processes and ports, and lets you end them. Clicking it asks for an admin password, then starts `DobbyHelper` as root. The helper only reads process/port data and relays SIGTERM/SIGKILL, accepts requests only from the Dobby process that launched it, and exits when Dobby quits or the button is turned off, so nothing stays installed. `launchd`, `kernel_task`, `WindowServer` and `loginwindow` can never be ended from Dobby.

## Build

Requires macOS 14+ and Swift 6 (Command Line Tools are enough).

```sh
./scripts/test.sh        # unit + live process/socket/helper tests (works around a CLT macro-plugin bug)
./scripts/build-app.sh   # -> build/Dobby.app
open build/Dobby.app
```

`DOBBY_SNAPSHOT=out.png [DOBBY_SNAPSHOT_TAB=memory|ports] [DOBBY_SNAPSHOT_THEME=light|dark] .build/debug/Dobby` renders the panel to a PNG without opening it.
