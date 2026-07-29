# Keychron K0 Max Agent Control Protocol

- **Protocol:** Agent Island K0 Max Raw HID
- **Major version:** 1
- **Minor version:** 0
- **Status:** Protocol v1; packet mechanics validated in Round 2 and complete
  keyboard-side behavior implemented in Round 5

## Purpose

This document is the byte-level contract between Agent Island on macOS and
custom Keychron K0 Max firmware. It deliberately carries only anonymous slot
state and user intent. Agent Island remains the authority for mapping a slot
to a session and for deciding whether a jump, approval, or denial is valid.

## Reviewed Firmware Baseline

- Repository: [Keychron/qmk_firmware](https://github.com/Keychron/qmk_firmware)
- Branch: `2025q3`
- Pinned commit: [`07bfc38a4b11b8dac7ab758dfc5868b4229499ca`](https://github.com/Keychron/qmk_firmware/commit/07bfc38a4b11b8dac7ab758dfc5868b4229499ca)
- QMK target: `keychron/k0_max:keychron`
- USB vendor ID: `0x3434`
- USB product ID: `0x0A06`
- Device version: `1.1.1`
- Raw HID usage page: `0xFF60`
- Raw HID usage: `0x61`
- Report size: 32 bytes

Reviewed source anchors:

- [K0 Max metadata and USB identifiers](https://github.com/Keychron/qmk_firmware/blob/07bfc38a4b11b8dac7ab758dfc5868b4229499ca/keyboards/keychron/k0_max/keyboard.json)
- [Stock K0 Max keymap](https://github.com/Keychron/qmk_firmware/blob/07bfc38a4b11b8dac7ab758dfc5868b4229499ca/keyboards/keychron/k0_max/keymaps/keychron/keymap.c)
- [K0 Max matrix-to-LED map](https://github.com/Keychron/qmk_firmware/blob/07bfc38a4b11b8dac7ab758dfc5868b4229499ca/keyboards/keychron/k0_max/led_config.c)
- [Keychron Raw HID routing](https://github.com/Keychron/qmk_firmware/blob/07bfc38a4b11b8dac7ab758dfc5868b4229499ca/keyboards/keychron/common/keychron_raw_hid.c)
- [QMK Raw HID API](https://docs.qmk.fm/features/rawhid)

At the pinned commit, Keychron reserves top-level Raw HID commands `0xA0`
through `0xAB`. This custom firmware locally reserves `0xAC` for Agent Island.
That value is not an upstream allocation and must be re-audited before moving
the firmware baseline.

The stock keymap implements physical M4 as macro position `MC_4` and M5 as
`MO(FN)`. Custom firmware reserves M4 as the Agent Control toggle and retains
M5 as an immediate momentary Fn key.

## Physical Slot And LED Map

Protocol slot indices are zero-based; user-facing labels are not.

| Protocol slot | Key label | Matrix | RGB LED index |
|---:|---:|---|---:|
| 0 | 1 | `[4,1]` | 19 |
| 1 | 2 | `[4,2]` | 20 |
| 2 | 3 | `[4,3]` | 21 |
| 3 | 4 | `[3,1]` | 15 |
| 4 | 5 | `[3,2]` | 16 |
| 5 | 6 | `[3,3]` | 17 |
| 6 | 7 | `[2,1]` | 10 |
| 7 | 8 | `[2,2]` | 11 |
| 8 | 9 | `[2,3]` | 12 |
| 9 | 0 | `[5,1]` | 23 |

Control and feedback LEDs:

| Key | Matrix | RGB LED index |
|---|---|---:|
| M4 / Agent Control | `[4,0]` | 18 |
| M5 / Fn | `[5,0]` | 22 |
| `-` | `[1,4]` | 8 |
| `+` | `[2,4]` | 13 |
| Enter | `[5,4]` | 25 |

## Transport Rules

- Reports are always exactly 32 bytes.
- Multi-byte integers are little-endian.
- Unused payload bytes are zero.
- Host and firmware ignore packets with invalid magic, length, major version,
  or CRC.
- A valid `HELLO`, `STATE_SNAPSHOT`, or `HEARTBEAT` refreshes the firmware
  watchdog.
- The host sends a heartbeat every 2 seconds.
- The firmware watchdog expires after 6 seconds unless a negotiated
  compatible timeout replaces it.
- On watchdog expiry, firmware clears slots and selection, invalidates tokens,
  exits Agent Control, restores the base layer, and emits no synthetic
  keystroke.
- Bluetooth is outside protocol v1 support. USB is the required baseline;
  2.4 GHz support is claimed only after the same contract passes hardware
  verification.

## Common Packet Header

| Byte | Size | Field | Value or meaning |
|---:|---:|---|---|
| 0 | 1 | Command family | `0xAC` |
| 1 | 1 | Magic 0 | `0x41` (`A`) |
| 2 | 1 | Magic 1 | `0x49` (`I`) |
| 3 | 1 | Protocol major | `0x01` |
| 4 | 1 | Message type | See message table |
| 5 | 1 | Flags | Bit 0 response, bit 1 error, bits 2-7 zero |
| 6 | 2 | Sequence | Origin-local sequence, or copied request sequence for a response |
| 8 | 1 | Payload length | `0...22` |
| 9 | 22 | Payload | Message-specific; zero-filled after payload length |
| 31 | 1 | CRC | CRC-8/ATM over bytes 0-30 |

CRC-8/ATM parameters:

- Polynomial: `0x07`
- Initial value: `0x00`
- Input reflected: no
- Output reflected: no
- Final XOR: `0x00`

Round 2 golden `HELLO` report for sequence `1`, minor `0`, nonce
`0x0123456789ABCDEF`, watchdog `6`, and host capabilities `0x001F`:

```text
ac414901010001000c00efcdab8967452301061f000000000000000000000097
```

The final byte is CRC `0x97`.

The sender increments its sequence for each new non-response packet. A
response copies the sequence from the request and sets the response flag.
Duplicate action sequences within the active connection nonce must return the
previous result and must not dispatch twice.

## Connection Nonce

The host creates a random, nonzero 64-bit connection nonce for every
successful transport open. `HELLO` establishes it and `CAPABILITIES` echoes
it. Every later message includes it as the first eight payload bytes.

Firmware rejects messages for an old nonce. Agent Island rejects device
events for an old nonce. A reconnect invalidates every selection and action
token from the prior connection.

## Message Types

| Type | Name | Direction | Response behavior |
|---:|---|---|---|
| `0x01` | `HELLO` | Host → firmware | `CAPABILITIES` |
| `0x02` | `STATE_SNAPSHOT` | Host → firmware | No response |
| `0x03` | `HEARTBEAT` | Host → firmware | No response |
| `0x04` | `SELECTION_ACK` | Host → firmware | Response to `SLOT_SELECTED` |
| `0x05` | `ACTION_RESULT` | Host → firmware | Response to `ACTION_INVOKED` |
| `0x81` | `CAPABILITIES` | Firmware → host | Response to `HELLO` |
| `0x82` | `SLOT_SELECTED` | Firmware → host | `SELECTION_ACK` |
| `0x83` | `ACTION_INVOKED` | Firmware → host | `ACTION_RESULT` |
| `0x84` | `LAYER_CHANGED` | Firmware → host | No response |

Unknown message types are ignored. A response with the error flag set uses
the same payload shape where possible and supplies a nonzero result code.

## `HELLO` (`0x01`)

Payload:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 1 | Host protocol minor (`0`) |
| 1 | 8 | Connection nonce |
| 9 | 1 | Requested watchdog seconds (`6`) |
| 10 | 2 | Host capability bits |

Host capability bits:

- Bit 0: state snapshots
- Bit 1: selection
- Bit 2: jump
- Bit 3: allow once
- Bit 4: deny
- Bits 5-15: reserved

## `CAPABILITIES` (`0x81`)

Payload:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | Echoed connection nonce |
| 8 | 1 | Firmware protocol minor |
| 9 | 1 | Slot count (`10`) |
| 10 | 2 | Firmware capability bits |
| 12 | 1 | Active transport |
| 13 | 1 | Effective watchdog seconds |
| 14 | 4 | Firmware build identifier |

Active transport:

- `0`: unknown
- `1`: USB
- `2`: 2.4 GHz
- `3`: Bluetooth, reported for diagnostics but unsupported in v1

Firmware capability bits use the same low five meanings as the host. The host
must keep action handling disabled if a required capability is absent or the
major version is incompatible.

The build identifier is the first 32 bits of a SHA-256 digest over the pinned
Keychron commit plus the ordered paths and SHA-256 values of the local
firmware overlay and patch files. The build manifest records the complete
digest. The identifier excludes QMK's generated build timestamp.

## `STATE_SNAPSHOT` (`0x02`)

Payload:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | Connection nonce |
| 8 | 2 | Snapshot generation |
| 10 | 1 | Overflow count, capped at 255 |
| 11 | 10 | Slot states for protocol slots 0-9 |

Slot state:

| Value | Name | Lighting | Actions |
|---:|---|---|---|
| `0` | `unassigned` | Off | None |
| `1` | `idle` | Off | Select and jump if available |
| `2` | `running` | Blue pulse | Select and jump |
| `3` | `waitingApprovalActionable` | Fast red flash | Select, jump, allow once, deny |
| `4` | `waitingApprovalObserved` | Fast red flash | Select and jump only |
| `5` | `waitingAnswer` | Amber pulse | Select and jump only |
| `6` | `completedRecent` | Green pulse with full-off trough | Select and jump if available |

Snapshot generation increments whenever assignment identity or a projected
slot state changes. It wraps naturally at `UInt16.max`. A generation change
invalidates any token whose slot epoch no longer matches.

Firmware performs animation locally. Repeated identical snapshots must not
restart an animation cycle.

## `HEARTBEAT` (`0x03`)

Payload:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | Connection nonce |

Heartbeat carries no state and must not write EEPROM.

## `SLOT_SELECTED` (`0x82`)

Sent when the user presses a digit while Agent Control is active.

Payload:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | Connection nonce |
| 8 | 1 | Protocol slot index |
| 9 | 2 | Firmware's current snapshot generation |

Firmware does not change its authoritative selection until it receives a
successful `SELECTION_ACK`. An unassigned slot may still be reported so the
host can return explicit rejected feedback.

## `SELECTION_ACK` (`0x04`)

Response payload:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | Connection nonce |
| 8 | 1 | Protocol slot index |
| 9 | 1 | Selection result |
| 10 | 2 | Slot epoch |
| 12 | 8 | Opaque selection token |
| 20 | 1 | Allowed action bits |
| 21 | 1 | Token lifetime seconds |

Selection result:

- `0`: accepted
- `1`: unassigned
- `2`: stale snapshot
- `3`: session unavailable
- `4`: app unavailable
- `5`: unsupported

Allowed action bits:

- Bit 0: jump
- Bit 1: allow once
- Bit 2: deny

The token is random and nonzero. It is meaningful only to Agent Island and is
bound internally to connection nonce, slot epoch, session ID, allowed action,
expiration, and current permission request ID when approval actions are
available.

## `ACTION_INVOKED` (`0x83`)

Sent for Enter, `+`, or `-` after a successful selection.

Payload:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | Connection nonce |
| 8 | 1 | Protocol slot index |
| 9 | 1 | Action |
| 10 | 8 | Opaque selection token |

Action:

- `1`: jump
- `2`: allow once
- `3`: deny

Firmware should suppress locally impossible actions using the allowed-action
bits, but Agent Island must still perform complete validation for every
received intent.

## `ACTION_RESULT` (`0x05`)

Response payload:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | Connection nonce |
| 8 | 1 | Protocol slot index |
| 9 | 1 | Action |
| 10 | 1 | Result |

Result:

- `0`: accepted for dispatch
- `1`: no valid selection
- `2`: stale or unknown token
- `3`: slot unassigned or reused
- `4`: action not available for the current state
- `5`: permission request changed or expired
- `6`: bridge or jump transport unavailable
- `7`: unsupported
- `8`: app busy; user may retry
- `9`: malformed or duplicate conflict

`accepted for dispatch` does not mean the underlying agent completed the
operation. Firmware gives brief accepted feedback, then follows the next
authoritative state snapshot.

For allow-once and deny, Agent Island may return accepted only after the
identity-bound bridge has accepted the exact expected permission request.

## `LAYER_CHANGED` (`0x84`)

Payload:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 8 | Connection nonce |
| 8 | 1 | Agent Control enabled (`0` or `1`) |
| 9 | 1 | Reason |

Reason:

- `0`: M4 tap
- `1`: watchdog expiry
- `2`: host disconnect
- `3`: firmware reset
- `4`: incompatible host

This message is diagnostic. Agent Island does not treat it as authority over
session state.

## Token And Approval Safety

Agent Island must validate, in order:

1. packet CRC, magic, major version, nonce, and sequence;
2. selected slot and slot epoch;
3. opaque token existence, action permission, and expiry;
4. current slot-to-session mapping;
5. current session phase;
6. current `PermissionRequest.id` for allow-once or deny;
7. bridge availability;
8. the same expected request identity inside the bridge immediately before
   resolution.

Failure at any step returns a nonzero action result and performs no jump or
permission resolution.

Layer exit, reconnect, slot release/reuse, session replacement, request
replacement, phase transition, and token timeout all invalidate affected
tokens.

## RGB And Persistence Rules

- Agent slot state, selection, tokens, watchdog timestamps, and animation
  phase live only in RAM.
- Status snapshots and heartbeats never update EEPROM.
- Firmware restores the user's existing base RGB configuration after leaving
  Agent Control.
- Agent Control colors override only the number keys and control-feedback keys
  required by this contract.
- M1-M3 and the encoder remain reserved for future versions; M4 is the
  dedicated Agent Control toggle.

## Compatibility And Coexistence

The `0xAC` family is handled before ordinary VIA commands and all other Raw HID
families continue through Keychron's existing handler. Agent Island filters
incoming reports by command family, magic, version, and nonce and ignores
Launcher traffic.

This namespace separation does not prove that two host processes can open and
read the same HID interface reliably on every macOS version. Concurrent
Keychron Launcher use is a required hardware test.

## Protocol Change Policy

- Backward-compatible additions increment the minor version.
- Incompatible header, field, enum, or safety changes increment the major
  version.
- Reserved fields must be sent as zero and ignored when received.
- The app must disable action handling on a major-version mismatch.
- The app may continue read-only status support across a minor-version
  mismatch only when the negotiated capability set is understood.
- Golden packet vectors produced in Round 2 become normative fixtures for
  both the Swift codec and firmware tests.
