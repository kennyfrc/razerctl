# razerctl

Small macOS CLI for Razer mice. It reads the battery, sets DPI and polling rate, and runs a
background agent that reapplies your settings when the mouse reconnects.

It talks to the mouse over USB HID feature reports, so it needs no Razer Synapse and no
kernel extension. Verified on a Razer Viper V3 Pro over both links: USB-C cable
(`1532:00C0`) and the 2.4 GHz dongle (`1532:00C1`).

## Quick start

```sh
make install                  # build, sign, install to ~/.local/bin/razerctl
razerctl install              # background agent, so settings survive a reconnect
razerctl setup                # check the install in order, prints the next step
razerctl dpi 1000             # set and save sensitivity
razerctl polling 125          # set and save report rate
```

Settings live in `~/.config/razerctl/mouse.yaml` and the agent reapplies them. The defaults
below (1000 DPI, 125 Hz) are what felt right on a 120 Hz MacBook screen; 1000 Hz is the better
default for desktop work.

## The Bluetooth question

The Viper V3 Pro has no Bluetooth. Razer ships it with two links only:

- the 2.4 GHz HyperPolling dongle (the mouse then reports product id 0x00C1), and
- a USB-C cable (product id 0x00C0).

There is no pairing switch and no BLE service on this model. Razer's product page lists only
HyperSpeed Wireless and the HyperPolling dongle under connectivity, and OpenRazer's device
table has exactly two ids for it, 0x00C0 and 0x00C1. No Bluetooth id exists.

Razer mice that do support Bluetooth, such as the Cobra Pro or the DeathAdder V2 Pro, have a
three-way switch underneath (2.4 GHz / Bluetooth / off). Those show up as a Bluetooth HID
device instead of a USB one.

`razerctl bluetooth` prints this for the attached model.

## Install

```sh
make install          # build, sign, copy to ~/.local/bin/razerctl
razerctl install      # install and start the agent (LaunchAgent local.razerctl)
razerctl setup        # check the install in order, print the next step
```

`make install` signs the binary with a fixed identifier and designated requirement
(`local.razerctl`), so the Input Monitoring grant stays with `razerctl` across rebuilds.

Full install order for a fresh machine, including the permission dance and what to run when a
step does not stick: [SETUP.md](SETUP.md).

## Permission

macOS blocks opening a mouse interface until the process has Input Monitoring. There are two
ways to satisfy it, and either one is enough:

1. Give the agent its own grant. The system may deny the first request without a prompt.
   Open System Settings > Privacy & Security > Input Monitoring, turn on `razerctl`, and
   restart the agent: `launchctl kickstart -k gui/$(id -u)/local.razerctl`.
2. Give the app that runs your shell the grant (Terminal, iTerm, and so on).

When the CLI has no grant, it reads what the agent last saw (up to five minutes old) and
sends writes through the agent by saving them to the config file. `razerctl status` shows
which source answered.

## Usage

```
razerctl                         summary: device, battery, DPI, polling, agent
razerctl list                    Razer HID interfaces on the bus
razerctl info                    name, firmware, serial, battery, DPI, polling
razerctl battery                 battery percentage and charging state
razerctl dpi                     read DPI
razerctl dpi 1600                set DPI and save it
razerctl polling                 read polling rate
razerctl polling 8000            set polling rate and save it
razerctl stages                  show the DPI stage list and the active one
razerctl stages 400 800 1600 3200 6400 --active 3
                                 write the stage list back
razerctl match                   copy the Logitech DPI, read from mxctl
razerctl raw 0x07 0x80 0x02      raw report (class, id, data size, args)
razerctl doctor                  permissions, detection, live probe
razerctl bluetooth               Bluetooth capability of this model
razerctl pair                    put the dongle in pairing mode
razerctl install / uninstall     manage the agent
razerctl watch                   run the agent in the foreground
razerctl status                  agent state and saved settings
razerctl setup                   check the install in order, name the next step
razerctl ask "connect this mouse"  plain language, mapped to the right command
razerctl intents                 list the phrases it understands, with examples
```

Read commands accept `--json`. `--pid 0xC1` picks one device when two are attached, and
`--txid` overrides the transaction id byte.

## Plain language

`razerctl ask` takes a sentence instead of a command. It matches keywords, extracts the
number, then calls the command you would have typed. No model, no network.

```
$ razerctl ask "hey i want to connect this mouse to my macbook how do i do that"
intent: connect
Linked: Razer Viper V3 Pro (2.4 GHz dongle) (1532:00C1)
  battery 95%, dpi 1600, polling 8000 Hz

$ razerctl ask "set dpi to 1600"
intent: set_dpi
Saved DPI 1600. The agent applies it within a few seconds.

$ razerctl ask "max out the polling rate"
intent: set_polling
Saved polling 8000 Hz. The agent applies it within a few seconds.
```

Recognised intents: `connect`, `status`, `battery`, `set_dpi`, `set_polling`,
`bluetooth`, `pair`, `diagnose`. `razerctl intents` prints the examples, and
`razerctl intents --json` prints them as a schema for a script or an agent. A sentence with
no keywords falls to `diagnose`, which runs the checks and names the next step.

Piping works too: `echo "how much battery is left" | razerctl ask`.

## DPI is a stage list

The mouse keeps five DPI stages and runs whichever stage is active. The single-value
register (command 0x04/0x85) can report a number that the active stage does not match, so
the CLI could say 1600 while the mouse was moving at the 400 DPI of stage 1.

`razerctl dpi` now reads the active stage, and `razerctl dpi <value>` activates the stage that
already holds the value, or overwrites the active stage and keeps it active. `razerctl stages`
prints the list, and `razerctl stages 400 800 1600 3200 6400 --active 3` writes it back.

Stage writes go to the mouse's storage, so the device answers BUSY for a few seconds
afterwards. Reads during that window come back empty; wait a moment and retry.

## Recommended settings

```sh
razerctl dpi 1000
razerctl polling 125      # a 60-120 Hz game; 1000 for desktop work
```

On macOS the polling rate changes more than latency. Pointer lock in a browser exposes the
system's acceleration curve, which is evaluated per report, so a mouse at 1000 Hz can turn
less than the same mouse at 125 Hz for the same physical stroke. Chromium 41352922 records
that: pointer-lock movementX is wrong at 1000 Hz and correct at 125. A game that reads raw
counts (pointer lock with `unadjustedMovement`) is immune, and then 1000 Hz is fine.

1000 Hz is 1 ms per report and the right default for the desktop. Above 1000 Hz the gain is
small and the cost is real: more USB traffic, more CPU, and faster battery drain. Apple
Silicon Macs cap some devices at 500 Hz anyway.

DPI is a personal value. Desktop work usually lands between 1200 and 1600; games often use
800 to 1600 and scale the rest with in-game sensitivity, since eDPI = DPI x sensitivity.

## Matching another mouse

Same DPI means the same physical sensitivity at the same macOS pointer speed. To match a
Logitech MX Master 3S:

```sh
razerctl match          # reads "mxctl dpi" and applies the same number
razerctl match 800      # or state the number yourself
```

`mxctl` is the companion CLI for the MX Master 3S. Games multiply this by their own
sensitivity, so matching DPI only aligns the base: eDPI = DPI x in-game sensitivity.

## Going wireless

There is no Bluetooth step. The mouse links to the HyperPolling dongle:

1. Plug the dongle into a USB port on the Mac, directly rather than through a hub.
2. Turn the mouse on: press and hold the button underneath for two seconds.
3. Unplug the USB-C cable. The mouse switches to the 2.4 GHz link.
4. Run `razerctl list`. The product id changes from 0x00C0 (wired) to 0x00C1 (dongle).
5. `razerctl polling 8000` reaches 8000 Hz on this link. Wired tops out at 1000 Hz.

A new mouse and dongle are paired at the factory, so steps 1 to 3 are all it takes. If the
dongle was paired to another mouse, plug it in with no cable attached and run
`razerctl pair`, then repeat step 2.

The dongle is USB-A, so a USB-C-only Mac needs something in between: the included cable, or a
passive USB-C to USB-A adapter. Any chain that makes `1532:00C1` appear is fine, because the link runs at USB
full speed. A hub or dock may not carry 8000 reports per second, which shows up as polling
falling back to 1000 Hz.

## The agent

`razerctl install` writes `~/Library/LaunchAgents/local.razerctl.plist` and starts it. The
agent:

- reapplies saved DPI and polling when the mouse connects, for example after you switch it
  off and on;
- applies a change within five seconds after `razerctl dpi` or `razerctl polling` saves it;
- records battery, DPI and polling in a state file for the CLI to read.

| Path | Contents |
|---|---|
| `~/.config/razerctl/config.json` | saved DPI and polling rate |
| `~/.config/razerctl/state.json` | last readings from the agent |
| `~/Library/LaunchAgents/local.razerctl.plist` | the LaunchAgent |
| `~/Library/Logs/razerctl.log` | one line per event, with a timestamp |

## How it works

Razer's protocol is a 90-byte request and response message:

```
[0]      status
[1]      transaction id (0x1F on current mice)
[2..3]   remaining packets
[4]      protocol type
[5]      data size
[6]      command class
[7]      command id
[8..87]  arguments
[88]     checksum (xor of bytes 2..87)
[89]     reserved
```

The CLI writes it as a HID feature report, waits for the reply, then reads it back. The wait
is 31 ms on a cable and 60 ms over the dongle; a shorter wait returns an empty reply. If the
reply is BUSY or belongs to an older command, it reads again.

Commands, all from OpenRazer's driver:

| What | Class | Id | Reply |
|---|---|---|---|
| Firmware | 0x00 | 0x81 | major, minor |
| Serial | 0x00 | 0x82 | ASCII |
| Battery level | 0x07 | 0x80 | arguments[1], 0-255 |
| Charging | 0x07 | 0x84 | arguments[0] != 0 |
| Get DPI | 0x04 | 0x85 | x, y big endian |
| Set DPI | 0x04 | 0x05 | varstore, x, y |
| Get polling (extended) | 0x00 | 0xC0 | bitmask in arguments[1] |
| Set polling (extended) | 0x00 | 0x40 | 0x01=8k, 0x02=4k, 0x04=2k, 0x08=1k, 0x10=500 |
| Get polling (standard) | 0x00 | 0x85 | bitmask in arguments[0] |
| Set polling (standard) | 0x00 | 0x05 | 0x01=1k, 0x02=500, 0x08=125 |

Wired models answer the standard polling commands, which stop at 1000 Hz. The 2.4 GHz dongle
answers the extended ones, which reach 8000 Hz. The CLI tries extended first, then standard.

## Verified

On 2026-10-19, against the attached Viper V3 Pro:

- cable link `0x00C0`: battery 91%, DPI set and read back, polling 1000 Hz;
- dongle link `0x00C1`: battery 95%, DPI 1600, polling 8000 Hz;
- firmware and serial read over the same channel;
- writes survive a reconnect, because the agent reapplies the saved config;
- DPI stage list read as 400 / 800 / 1600 / 3200 / 6400 with stage 3 active, and the
  active stage is what the DPI reading now reports;
- matched a Logitech at 1000 DPI with `razerctl match`;
- at 1000 DPI and 1000 Hz the Viper feels the same as an MX Master 3S at 1000 DPI, which was
  not true while the wrong DPI stage was active.

## Credits

Protocol constants and command ids come from [OpenRazer](https://github.com/openrazer/openrazer)
(driver/razercommon.h, razerchromacommon.c, razermouse_driver.c). The HID transport rules
(busy retry, stale-reply rejection) follow what
[MacRazer](https://github.com/SorcRR/MacRazer) found working on macOS. The agent and signing
model follow [mxctl](https://github.com/kennyfrc/mxctl).

MIT licensed.
