# razerctl

Small macOS CLI for Razer mice. It reads the battery, sets DPI and polling rate, and runs a
small background agent that reapplies your settings when the mouse reconnects.

It talks to the mouse over USB HID feature reports, so it needs no Razer Synapse and no
kernel extension. Verified on a Razer Viper V3 Pro (1532:00C0, wired).

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

\`razerctl bluetooth\` prints this for the attached model.

## Install

\`\`\`sh
make install          # build, sign, copy to ~/.local/bin/razerctl
razerctl install      # install and start the agent (LaunchAgent local.razerctl)
\`\`\`

\`make install\` signs the binary with a fixed identifier and designated requirement
(\`local.razerctl\`), so the Input Monitoring grant stays with \`razerctl\` across rebuilds.

## Permission

macOS blocks opening a mouse interface until the process has Input Monitoring. There are two
ways to satisfy it, and either one is enough:

1. Give the agent its own grant. The system may deny the first request without a prompt.
   Open System Settings > Privacy & Security > Input Monitoring, turn on \`razerctl\`, and
   restart the agent: \`launchctl kickstart -k gui/$(id -u)/local.razerctl\`.
2. Give the app that runs your shell the grant (Terminal, iTerm, and so on).

When the CLI has no grant, it reads what the agent last saw (up to five minutes old) and
sends writes through the agent by saving them to the config file. \`razerctl status\` shows
which source answered.

## Usage

\`\`\`
razerctl                         summary: device, battery, DPI, polling, agent
razerctl list                    Razer HID interfaces on the bus
razerctl info                    name, firmware, serial, battery, DPI, polling
razerctl battery                 battery percentage and charging state
razerctl dpi                     read DPI
razerctl dpi 1600                set DPI and save it
razerctl polling                 read polling rate
razerctl polling 4000            set polling rate and save it
razerctl raw 0x07 0x80 0x02      raw report (class, id, data size, args)
razerctl doctor                  permissions, detection, live probe
razerctl bluetooth               Bluetooth capability of this model
razerctl install / uninstall     manage the agent
razerctl watch                   run the agent in the foreground
razerctl status                  agent state and saved settings
\`\`\`

Read commands accept \`--json\`. \`--pid 0xC1\` picks one device when two are attached, and
\`--txid\` overrides the transaction id byte.

## The agent

\`razerctl install\` writes \`~/Library/LaunchAgents/local.razerctl.plist\` and starts it. The
agent:

- reapplies saved DPI and polling when the mouse connects, for example after you switch it
  off and on;
- applies a change within five seconds after \`razerctl dpi\` or \`razerctl polling\` saves it;
- records battery, DPI and polling in a state file for the CLI to read.

| Path | Contents |
|---|---|
| \`~/.config/razerctl/config.json\` | saved DPI and polling rate |
| \`~/.config/razerctl/state.json\` | last readings from the agent |
| \`~/Library/LaunchAgents/local.razerctl.plist\` | the LaunchAgent |
| \`~/Library/Logs/razerctl.log\` | one line per event, with a timestamp |

## How it works

Razer's protocol is a 90-byte request and response message:

\`\`\`
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
\`\`\`

The CLI writes it as a HID feature report, waits 31 ms, then reads the reply feature report.
If the reply is BUSY or belongs to an older command, it reads again.

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

- battery read 91%, charging false;
- DPI read 3200, set to 1600 and read back 1600, then set back to 3200;
- polling read 1000 Hz, set to 500 and read back 500, then set back to 1000;
- firmware and serial read over the same channel.

## Credits

Protocol constants and command ids come from [OpenRazer](https://github.com/openrazer/openrazer)
(driver/razercommon.h, razerchromacommon.c, razermouse_driver.c). The HID transport rules
(busy retry, stale-reply rejection) follow what
[MacRazer](https://github.com/SorcRR/MacRazer) found working on macOS. The agent and signing
model follow [mxctl](https://github.com/kennyfrc/mxctl).

MIT licensed.
