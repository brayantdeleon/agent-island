# Keychron K0 Max hardware spike

This directory contains the Round 2 diagnostic firmware overlay and macOS
Raw HID probe for the planned Agent Island K0 Max integration. It is not
production firmware and it does not connect to Agent Island sessions or
dispatch real approvals.

The spike exists to prove five things before application integration begins:

1. a pinned stock recovery image can be built;
2. the keyboard can enter its STM32 DFU bootloader independently of its
   installed application firmware;
3. a host can set the `1` LED to blue;
4. firmware can report a digit and an action-key intent to the host; and
5. loss of host heartbeat clears RAM state and exits Agent Control.

## Safety boundary

- Build and hash the stock image before flashing the diagnostic image.
- Prove the physical Esc-at-plug-in DFU path before the first custom flash.
- Do not use `+` or `-` around a real approval prompt during this spike.
- The diagnostic probe only logs and acknowledges key intents. It never
  contacts Agent Island and cannot authorize or deny an agent request.
- Firmware does not store Agent Island state in EEPROM.
- Keep the K0 Max in Cable mode for the first exercise.

## Pinned source

- Repository: `https://github.com/Keychron/qmk_firmware.git`
- Branch: `2025q3`
- Commit: `07bfc38a4b11b8dac7ab758dfc5868b4229499ca`
- QMK keyboard target: `keychron/k0_max`
- Stock keymap: `keychron`
- Diagnostic keymap: `agent_island`

Keychron's readme at the pinned commit still shows
`keychron/k0_max/encoder:keychron`, but QMK exposes this board as
`keychron/k0_max`. The build script uses the target reported by
`qmk list-keyboards`.

The overlay preserves ordinary VIA-backed Base and Fn mappings except that
the physical M4 position is reserved for Agent Control. Physical Agent
Control positions are resolved independently of VIA EEPROM mappings:

- M4 toggles Agent Control after a fresh handshake.
- M5 retains its stock momentary Fn behavior.
- Digits emit anonymous slot-selection intents.
- Enter emits jump, `+` emits allow-once, and `-` emits deny intents after a
  diagnostic selection acknowledgement.
- Other key and encoder positions emit nothing while Agent Control is active.

Round 2 drives the M4 status LED and all ten digit LEDs. The diagnostic host
sets slot `1` to running, so `1` pulses blue while the other digit LEDs are
forced off. Complete production feedback behavior still belongs to Round 5.

## Build

Install QMK CLI, its ARM toolchain, and `dfu-util`, then obtain the pinned
Keychron checkout with submodules. The paths below match the isolated Round 2
environment; they can be changed with environment variables.

```sh
git clone --branch 2025q3 --recurse-submodules \
  https://github.com/Keychron/qmk_firmware.git \
  /private/tmp/agent-island-keychron-qmk
git -C /private/tmp/agent-island-keychron-qmk checkout \
  07bfc38a4b11b8dac7ab758dfc5868b4229499ca
git -C /private/tmp/agent-island-keychron-qmk submodule update \
  --init --recursive

QMK_SOURCE=/private/tmp/agent-island-keychron-qmk \
QMK_CLI_BIN=/path/to/qmk \
QMK_TOOLCHAIN_BIN=/path/to/qmk-toolchain/bin \
OUTPUT_DIR=/private/tmp/agent-island-k0-max-artifacts \
scripts/build-keychron-k0-max-firmware.sh

OUTPUT_DIR=/private/tmp/agent-island-k0-max-artifacts \
scripts/build-keychron-k0-max-probe.sh
```

The firmware builder rejects the wrong source commit or tracked source
changes. It builds stock first, applies the small Raw HID hook and keymap only
for the custom build, then restores the pinned checkout. It writes binaries
and `manifest.txt` outside the repository.

The deterministic firmware build identifier is the first 32 bits of a
SHA-256 digest. The digest input is, in order:

1. the pinned Keychron commit followed by a newline;
2. each tracked overlay/patch path followed by a newline; and
3. the SHA-256 of that file followed by a newline.

The complete digest is recorded in the manifest. QMK embeds a build timestamp,
so whole-binary SHA-256 values may change across builds even when this source
identifier does not.

## Pre-flash checks

With the stock keyboard connected over USB:

```sh
/private/tmp/agent-island-k0-max-artifacts/k0max-probe --identify-stock
```

The expected response identifies Keychron protocol version 2 and command set
2. This is a read-only command and does not alter the keyboard.

Next, prove hardware recovery without writing anything:

1. Put the K0 Max in Cable mode and unplug it.
2. Hold Esc while reconnecting the cable, then release Esc.
3. Run `/path/to/dfu-util -l`.
4. Confirm an STM32 DFU device with VID/PID `0483:DF11`.
5. Unplug and reconnect normally, then repeat `--identify-stock`.

Do not proceed unless both DFU detection and the normal stock reconnect work.

## Flash and USB exercise

Only after the recovery gate passes, enter DFU again and write the exact
custom binary named by `manifest.txt`:

```sh
/path/to/dfu-util \
  -d 0483:DF11 \
  -a 0 \
  -s 0x08000000:leave \
  -D /private/tmp/agent-island-k0-max-artifacts/keychron_k0_max_agent_island_BUILD_ID.bin
```

Reconnect in Cable mode and run:

```sh
/private/tmp/agent-island-k0-max-artifacts/k0max-probe --exercise 30
```

During the manual input window:

1. Tap M4. M4 should turn cyan, `1` should pulse blue, and the other digit
   LEDs should turn off.
2. Press `1`, then Enter.
3. Wait after the probe announces that heartbeat has stopped.

The final evidence line must report `yes` for handshake, layer, selection,
action, and watchdog. On watchdog expiry the lights must return to the user's
ordinary RGB effect and number keys must type normally.

## Round 4 production-host verification

Round 4 adds the production Swift packet codec, IOHID transport, and
coordinator without starting them from the Agent Island app. The app remains
disconnected by default until the opt-in UI and read-only projection work in
Round 6.

With the diagnostic firmware connected over USB, verify real discovery,
handshake, one snapshot, and a fresh host connection:

```sh
AGENT_ISLAND_RUN_K0_MAX_HID_INTEGRATION=1 \
swift test \
  --filter K0MaxHIDTransportIntegrationTests/testConnectedDiagnosticFirmwareHandshakeAndHostRestart
```

For the manual removal-callback gate, start the following test, unplug the
USB cable when prompted, leave it disconnected for two seconds, and reconnect
it when prompted:

```sh
AGENT_ISLAND_RUN_K0_MAX_HID_REPLUG_INTEGRATION=1 \
swift test \
  --filter K0MaxHIDTransportIntegrationTests/testLiveUnplugAndReplugRecovery
```

Both live tests are skipped during ordinary `swift test` runs.

## Restore stock

Enter DFU with the physical Esc procedure and flash the stock binary recorded
by the same manifest:

```sh
/path/to/dfu-util \
  -d 0483:DF11 \
  -a 0 \
  -s 0x08000000:leave \
  -D /private/tmp/agent-island-k0-max-artifacts/keychron_k0_max_stock_07bfc38a4b11.bin
```

Then reconnect normally and run `--identify-stock`.

## Remaining hardware matrix

After USB passes:

- Repeat the diagnostic exercise through the paired 2.4 GHz receiver. Do not
  claim wireless support if unsolicited device-to-host Raw HID events fail.
- Open Keychron Launcher over USB, read the keyboard, change and restore an
  ordinary Base/Fn mapping or RGB setting, and confirm the diagnostic family
  still works afterward.
- Restore stock once to prove the recovery artifact, then reflash the
  diagnostic image only if more spike testing is required.

Bluetooth is outside protocol v1.
