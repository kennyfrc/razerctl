# razerctl

Small macOS CLI for Razer mice. It talks to the mouse over USB HID feature reports, so it
works without Razer Synapse and without a kernel extension.

Tested on a Razer Viper V3 Pro (1532:00C0, wired).

## The Bluetooth question

The Viper V3 Pro has no Bluetooth. Razer ships it with two links only:

- the 2.4 GHz HyperPolling dongle (product id 0x00C1 when the mouse talks through it), and
- USB-C cable (product id 0x00C0).

There is no pairing switch and no BLE service on this model. Razer's own product page lists
only HyperSpeed Wireless and the HyperPolling dongle under connectivity, and OpenRazer's
device table has exactly two ids for it: `0x00C0` wired and `0x00C1` wireless. No
Bluetooth id exists for it.

If you want Bluetooth on a Razer mouse, the Cobra Pro or the DeathAdder V2 Pro have a
three-way switch (2.4 GHz / Bluetooth / off). Those show up as a Bluetooth HID device
instead of a USB one.

## Install

```sh
make install          # builds release and copies to ~/.local/bin/razerctl
razerctl list
```

## Usage

```
razerctl list                    show Razer HID interfaces on the bus
razerctl info                    name, firmware, serial, battery, DPI, polling
razerctl battery                 battery percentage and charging state
razerctl dpi                     read DPI
razerctl dpi 1600                set DPI
razerctl polling                 read polling rate
razerctl polling 4000            set polling rate
razerctl raw 0x07 0x80 0x02      send a raw report (class, id, data size, args)
razerctl doctor                  permissions, detection, live probe
razerctl bluetooth               what this model can and cannot do over Bluetooth
```

Every read command accepts `--json` for scripting. `--pid 0xC1` picks one device when two
are attached, and `--txid` overrides the transaction id byte.

## Permission

macOS gates opening a mouse interface behind Input Monitoring. The first run fails with
`Input Monitoring permission is missing` until the app that launches the command has it:

1. `razerctl doctor` prints the state and the settings command.
2. System Settings > Privacy & Security > Input Monitoring: enable your terminal app.
3. Quit and reopen that app.

This is the same permission a screen recorder asks for. There is no way around it from
userspace: the 90-byte control interface belongs to the mouse HID collection.

## How it works

Razer's protocol is a 90-byte request/response message:

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

The CLI writes it as a HID feature report, waits 31 ms, then reads the reply feature report.
If the reply is BUSY or belongs to an older command, it reads again.

Commands used here, all from OpenRazer's driver:

| What | Class | Id | Reply |
|---|---|---|---|
| Firmware | 0x00 | 0x81 | major, minor |
| Serial | 0x00 | 0x82 | ASCII |
| Battery level | 0x07 | 0x80 | arguments[1], 0-255 |
| Charging | 0x07 | 0x84 | arguments[0] != 0 |
| Get DPI | 0x04 | 0x85 | x, y big endian |
| Set DPI | 0x04 | 0x05 | varstore, x, y |
| Get polling (ext) | 0x00 | 0xC0 | bitmask in arguments[1] |
| Set polling (ext) | 0x00 | 0x40 | 0x01=8k, 0x02=4k, 0x04=2k, 0x08=1k, 0x10=500, 0x40=125 |
| Get polling (std) | 0x00 | 0x85 | bitmask in arguments[0] |
| Set polling (std) | 0x00 | 0x05 | 0x01=1k, 0x02=500, 0x08=125 |

Wired models answer the standard polling commands, which cap at 1000 Hz. The 2.4 GHz dongle
answers the extended ones, which reach 8000 Hz. The CLI tries both.

## Credits

Protocol constants and command ids come from [OpenRazer](https://github.com/openrazer/openrazer)
(driver/razercommon.h, razerchromacommon.c, razermouse_driver.c). The HID transport pattern
(busy retry, stale-reply rejection) follows what
[MacRazer](https://github.com/SorcRR/MacRazer) found working on macOS.

MIT licensed.
