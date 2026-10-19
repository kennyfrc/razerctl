# Setup on a new Mac

This is the order that works, and why each step comes where it does.

## What you need

- A Mac with a USB-C port.
- A Razer Viper V3 Pro and its HyperPolling dongle (USB-A), or the USB-C cable.
- A USB-C to USB-A adapter if the Mac has no USB-A port.
- Xcode Command Line Tools for `swiftc` and `codesign`: `xcode-select --install`.

## Steps

1. **Build and install the binary.**

   ```sh
   git clone <repo> ~/fun/razerctl
   cd ~/fun/razerctl
   make install
   ```

   This builds, signs with the identifier `local.razerctl`, and copies to `~/.local/bin/razerctl`.

2. **Install the agent.**

   ```sh
   razerctl install
   ```

   This is also the first permission request. macOS records `razerctl` in the Input
   Monitoring list at this point, not before. A background process usually gets no prompt,
   so expect a silent denial.

3. **Grant Input Monitoring.**

   System Settings > Privacy & Security > Input Monitoring, turn on `razerctl`.

   If it is not in the list, click `+`, press Cmd+Shift+G, and enter
   `~/.local/bin/razerctl`. Run `razerctl doctor` first if the list still looks empty:
   the entry only appears after something has asked for access once.

4. **Restart the agent.**

   ```sh
   launchctl kickstart -k gui/$(id -u)/local.razerctl
   ```

   A permission change applies to processes started after the change. The agent that is
   already running keeps the old answer, so restart it.

5. **Connect the hardware.**

   Plug the dongle into a port on the Mac, then turn the mouse on: press and hold the
   button underneath for two seconds.

   Steps 1 to 4 and step 5 are independent. The agent retries every five seconds, so it
   picks the mouse up whenever it appears. A cable works the same way and shows up as
   `1532:00C0` instead of `1532:00C1`.

6. **Check.**

   ```sh
   razerctl setup
   razerctl
   ```

   `razerctl setup` prints one line per step above and names the next thing to fix.

7. **Set your values.**

   ```sh
   razerctl dpi 1600
   razerctl polling 8000
   ```

   Both are saved to `~/.config/razerctl/config.json` and reapplied when the mouse
   reconnects.

## Skipping the agent

Steps 2 to 4 exist to give the binary its own permission. If you would rather grant the
app that runs your shell (Terminal, iTerm), you can skip the agent:

- reads go straight to the mouse and are always live;
- writes apply immediately;
- but nothing reapplies your settings when the mouse reconnects, and every command run
  from an app without the grant falls back to the agent, which is then absent.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Keyboard Setup Assistant opens when the dongle goes in | the dongle also exposes a keyboard HID collection | close it, the mouse is unaffected |
| `razerctl` says "not connected" but the mouse works | the agent lost the link, often after a port change | `razerctl setup` |
| Polling falls to 1000 Hz on the dongle | a hub or dock cannot carry 8000 reports per second | plug the dongle into the Mac directly |
| 8000 Hz is rejected on the cable | the wired link stops at 1000 Hz | expected; use the dongle for 8 kHz |
| Input Monitoring list does not show `razerctl` | nothing has requested access yet | `razerctl doctor`, then reopen the pane |
| Grant disappears after a rebuild | binary swapped without the fixed signature | `make install` signs every time; do not copy the build by hand |

## Notes

- The dongle is USB-A. A passive USB-C to USB-A adapter is enough, and the link runs at
  USB full speed, so nothing faster is needed. An 8000 Hz reading proves the adapter is
  not a bottleneck.
- Rebuilds keep the Input Monitoring grant because the signature uses a fixed identifier
  and designated requirement instead of a hash of the build.
