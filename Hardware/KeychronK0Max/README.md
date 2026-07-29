# Keychron K0 Max Agent Control firmware

This directory contains the pinned Agent Control firmware overlay and macOS
Raw HID diagnostic host for the Agent Island K0 Max integration. The firmware
implements the keyboard-side protocol. The standalone diagnostic host does
not connect to Agent Island sessions or dispatch real approvals; the Round 6
app integration projects session state only and does not enable keyboard
selection, navigation, or approval actions.

The original Round 2 spike proved five things before application integration:

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

Round 5 adds the complete keyboard-side behavior: all slot-state animations,
overflow indication, selection and action feedback, response matching and
timeouts, token lifetime enforcement, negotiated action gating, and
watchdog-driven cleanup.

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

## Round 5 complete-firmware verification

Build and flash the Agent Island image named by `manifest.txt`, then run the
complete diagnostic exercise:

```sh
/private/tmp/agent-island-k0-max-artifacts/k0max-probe \
  --round5-exercise 90
```

The diagnostic host sends a ten-slot gallery:

- `1` and `8`: running, blue pulse
- `2` and `9`: actionable approval, fast red flash
- `3`: observed approval, fast red flash with approval actions disabled
- `4`: waiting for an answer, amber pulse
- `5` and `0`: recently completed, green pulse with a full-off trough
- `6`: assigned idle, off
- `7`: unassigned, off

Follow the printed key sequence to verify white selection feedback, accepted
green action feedback, rejected amber feedback, all ten digit positions,
M4 cyan/purple status, and momentary M5 Fn behavior. The probe only
acknowledges anonymous intents; it cannot jump to or resolve a real agent.
Leave Agent Control active at the end so watchdog recovery can be verified.
While Agent Control is active, every LED outside M4, the assigned number
states, and temporary action feedback remains off. Blue, amber, and green
pulses now reach fully off at their trough, which increases contrast while
reducing average RGB power.

The final evidence line must report `yes` for handshake, layer, all slots,
jump/allow/deny, both rejection paths, the observer guard, and watchdog.

Verified on USB on 2026-07-28 with build `0xa41cfb54`. The complete evidence
line passed, the visual gallery and M5 behavior matched the contract, and
post-watchdog M4 unavailable feedback left ordinary number entry active.
The 2.4 GHz transport remains deferred and unclaimed.

The follow-up presentation build `0x19fb67fd` was flashed and verified on USB
the same day. Its source digest is
`19fb67fd954709bd27cd179b18fa652d8c7a2b2f1d787f65aa8ceabef7e8bcd7`
and its firmware SHA-256 is
`5ba6d275ffdafbb0f45d6da247e83797589daf14a129566f0a4700565602a4af`.
The production app handshake reported that exact build. Manual verification
confirmed that non-agent LEDs remain black, completed slots pulse green to
fully off, blue and amber share the deeper trough, and M5 still restores the
ordinary RGB effect while held.

## Round 6 read-only app integration

With firmware build `0x19fb67fd` connected in Cable mode:

1. Open Agent Island Settings → General.
2. Enable **Keychron K0 Max** under **Agent Control Keyboard**.
3. Confirm the status shows **Connected**, **USB**, protocol **v1.0**, and
   firmware **0x19FB67FD**.
4. Open the island and confirm assigned sessions show `K0 · 1` through
   `K0 · 0` badges.
5. Tap M4 and compare the digit lighting with current session phases.

Round 6 deliberately negotiates state snapshots only. Number-key selection,
Enter jump, `+` allow-once, and `-` deny remain disabled in both the firmware
capability gate and AppModel. Disabling the setting sends an empty snapshot
before closing the transport; the firmware watchdog remains the fallback.

The opt-in production-USB gate exercises AppModel session projection through
the real IOHID transport:

```sh
AGENT_ISLAND_RUN_K0_MAX_HID_INTEGRATION=1 \
swift test \
  --filter K0MaxHIDTransportIntegrationTests/testLiveAppModelProjectsSessionStateReadOnly
```

This test is skipped during ordinary `swift test` runs.

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
