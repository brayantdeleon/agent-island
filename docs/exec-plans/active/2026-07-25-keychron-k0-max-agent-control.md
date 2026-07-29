# Keychron K0 Max Agent Control Implementation Plan

- **Status:** Active
- **Created:** 2026-07-25
- **Protocol contract:** [Keychron K0 Max Agent Control Protocol](../../references/keychron-k0-max-agent-control-protocol.md)

## Goal

Add an optional Keychron K0 Max control surface to Agent Island. A dedicated
keyboard layer will show ten stable agent slots on the number keys, let the
user select an agent, jump to it, and resolve a current permission request
without sending ordinary keystrokes to the frontmost application.

The integration must remain local-first, preserve the K0 Max's normal and Fn
behavior, fail back to an ordinary numpad when Agent Island is unavailable,
and never let a stale keyboard action resolve a newer permission request.

## Problem

Agent Island already has the state needed for a hardware dashboard:

- `SessionPhase` distinguishes running, waiting for approval, waiting for an
  answer, and completed sessions.
- `AppModel` owns the user-visible session set and terminal jump routing.
- `PermissionRequest` and `PermissionResolution` represent actionable
  requests and allow-once or deny decisions.
- The closed-island agents grid already establishes stable
  first-observation ordering, but it is a nine-cell presentation with
  overflow rather than a reusable ten-slot identity model.

The K0 Max exposes per-key RGB and bidirectional Raw HID, but stock firmware
does not know Agent Island's session state. Agent Island also has no device
transport or request-identity guard suitable for authorizing from external
hardware.

## Intended End State

When the optional integration is enabled and compatible firmware is present:

1. Tapping M4 enters or exits Agent Control. M5 retains the stock momentary
   Fn behavior.
2. Digits `1` through `9` address slots 1 through 9; `0` addresses slot 10.
3. Pressing a populated digit selects that agent and reveals its card in
   Agent Island. It does not jump or authorize by itself.
4. Enter jumps to the selected agent using Agent Island's existing
   session-scoped jump path.
5. `+` submits allow-once only when the selected agent has the exact live
   permission request represented by the selection token.
6. `-` denies under the same identity and freshness checks.
7. Firmware animates the number LEDs locally. Agent Island sends compact
   snapshots only on changes, plus a heartbeat.
8. If the heartbeat expires, firmware clears all Agent Island state, exits
   Agent Control, and restores ordinary keyboard behavior.
9. Base and Fn layers remain usable and Keychron Launcher/VIA compatibility
   is regression-tested.

## Locked Interaction Contract

| Input | Agent Control behavior |
|---|---|
| M4 tap | Enter or exit Agent Control |
| M5 hold | Momentary stock Fn layer |
| `1`-`9` | Select slots 1-9 and reveal the corresponding Agent Island card |
| `0` | Select slot 10 |
| Enter | Jump to the selected agent |
| `+` | Allow the selected request once |
| `-` | Deny the selected request |
| All other keys and knob actions | Reserved in v1; emit no Agent Control action |

While Agent Control is active, the digit, Enter, `+`, and `-` positions emit
Raw HID intents only. They must not also type their ordinary keycodes into the
frontmost application.

M4 may enter Agent Control only after a fresh, compatible handshake. If Agent
Island is unavailable, an M4 tap gives brief amber feedback and leaves the
base layer active.

## Lighting Contract

| Projected slot state | Number-key lighting |
|---|---|
| Unassigned | Off |
| Assigned but idle | Off |
| Running | Blue pulse |
| Waiting for actionable approval | Fast red flash |
| Waiting for observed/non-actionable approval | Fast red flash; `+` and `-` disabled |
| Waiting for an answer | Amber pulse |
| Recently completed | Solid green |

Selection gives a brief white acknowledgement and then returns to the phase
color. Accepted device actions give brief green feedback; rejected or stale
actions give brief amber feedback.

The M4 LED indicates the control layer. Cyan means Agent Control is active.
Purple means more eligible sessions exist than the ten hardware slots.

Project state in this priority order:

1. `waitingForApproval` is actionable only when a `PermissionRequest` exists,
   it does not require terminal-only approval, and the identity-bound bridge
   reports that exact request as resolvable. Otherwise it is observer-only.
2. `waitingForAnswer` is amber and never enables `+` or `-`.
3. `running` is blue; v1 does not infer a different hardware state from
   process liveness alone.
4. `completed` is green until the configured completion threshold expires.
5. Any retained assignment that matches none of the above is idle and off.

`idle` is a hardware projection fallback, not a new `SessionPhase`.

## Session And Slot Rules

The keyboard projection is not the closed-island grid itself. Introduce a
shared, device-independent slot allocator and let the island grid and keyboard
derive their own presentations from the same stable ordering data.

- Capacity is ten.
- Candidates are top-level, surfaced sessions. Individual subagents and
  realtime voice sessions are excluded from v1.
- Hidden sessions with an approval request remain eligible, matching Agent
  Island's existing surfacing rule.
- At bulk startup, order newcomers by `firstSeenAt` and then session ID.
- After startup, assign a newly observed session to the first free slot.
- Do not renumber eligible live or recently completed sessions.
- Persist assignments by stable session ID so app restart does not scramble
  the physical mapping.
- Keep completed sessions green until the configured completed-stale
  threshold. Once stale, release the hardware slot and turn it off.
- When a known session becomes eligible again, reclaim its previous slot if
  that slot is free; otherwise use the first free slot.
- Do not page or rotate slots automatically in v1. Sessions beyond capacity
  remain controllable in the app and set the overflow indication.
- Show the assigned keyboard label (`1`-`9`, `0`) on the corresponding Agent
  Island card so the physical mapping is discoverable.

## Architecture

Keep three concerns separate:

1. **Projection and authorization model (`AgentIslandCore`)**
   - stable ten-slot allocation
   - session-to-light-state projection
   - packet value types and codec
   - opaque selection/action tokens
   - request-identity validation

2. **macOS device coordination (`AgentIslandApp`)**
   - opt-in preference and device status
   - IOHID discovery, handshake, heartbeat, reconnect, and sleep/wake
   - snapshot deduplication
   - selection, card reveal, jump, and permission intent routing
   - a fake transport for deterministic tests

3. **K0 Max firmware**
   - dedicated M4 control behavior and stock momentary M5 Fn behavior
   - Raw HID protocol endpoint
   - in-RAM slot and selection state
   - local RGB animation and feedback
   - heartbeat watchdog and fail-safe layer exit

No session title, prompt, command, file path, or workspace name crosses the
HID boundary. The keyboard receives only slot states, opaque tokens, counts,
and result codes.

## Authorization Invariants

These are release blockers, not optional hardening:

- Firmware emits intent; it never decides whether an agent action is allowed.
- A selection token is bound to the connection nonce, slot epoch, session ID,
  action type, and—when applicable—the exact `PermissionRequest.id`.
- Tokens expire and are invalidated on reconnect, layer exit, slot reuse,
  selection change, request change, or session phase change.
- `+` means `.allowOnce`; persistent approval is not exposed on the keyboard.
- `+` and `-` are disabled for questions and observer-only approval states.
- App-side validation must re-read the current session immediately before
  dispatch.
- Permission resolution must carry the expected request identity through the
  bridge. The bridge must reject a mismatch rather than resolve whichever
  request happens to be current for that session ID.
- A rejected action must not optimistically change the session phase.
- Replayed, duplicate, malformed, or out-of-order action packets are rejected.

The existing `BridgeCommand.resolvePermission(sessionID:resolution:)` does not
carry request identity. Hardware approval must not ship until that path can
perform identity-bound resolution.

## Source And Distribution Strategy

Use Keychron's `2025q3` QMK branch, pinned for the first spike to commit
`07bfc38a4b11b8dac7ab758dfc5868b4229499ca`. That commit contains a K0 Max
matrix fix and is the reviewed baseline for this plan.

Keep Agent Island's firmware work reproducible without vendoring the entire
QMK repository:

- store the small K0 Max keymap/keyboard overlay and any common-source patch
  under a dedicated hardware directory in this repository;
- provide a script that checks out the pinned Keychron commit into a temporary
  build directory, applies the overlay, and builds the firmware;
- record the source commit in the generated artifact metadata;
- do not auto-flash from Agent Island;
- distribute corresponding modified firmware source and license notices with
  any firmware binary, in accordance with QMK/Keychron's GPL terms.

Any later Keychron rebase must re-audit the locally reserved Raw HID command
family before the pinned commit changes.

## Implementation Rounds

Every round uses its own feature branch and worktree, runs targeted
verification, updates this plan, and ends in a focused commit.

### Round 1 — Design and protocol contract

- [x] Confirm the physical K0 Max layout and LED indices.
- [x] Lock M4, M5, digit, Enter, `+`, and `-` behavior.
- [x] Define slot stability, overflow, and completion expiry.
- [x] Define the versioned Raw HID packet contract.
- [x] Record authorization and fail-safe invariants.
- [x] Record the pinned Keychron firmware baseline and recovery gates.

Exit criterion: the product behavior and byte-level contract are reviewable
without implementing app or firmware behavior.

### Round 2 — Bidirectional hardware spike

- [x] Record and test the stock-firmware recovery/DFU path before flashing.
- [x] Build a minimal custom firmware image from the pinned source.
- [x] Build a diagnostic macOS host probe outside the production coordinator.
- [x] Set the `1` LED to a local blue pulse from host-projected state.
- [x] Receive one digit selection and one action-key intent from firmware.
- [x] Verify heartbeat expiry clears state and exits Agent Control.
- [x] Test USB first; explicitly defer 2.4 GHz because the available receiver
  is USB-A and the test Mac has no USB-A port or adapter.
- [x] Reopen Keychron Launcher and confirm ordinary VIA operations still work.

Exit criterion: one LED and one key work bidirectionally on USB, factory
recovery is proven, and 2.4 GHz support is either proven or explicitly
deferred with evidence. Do not integrate Agent Island before this gate passes.

#### Round 2 software evidence

On 2026-07-25, refreshed on 2026-07-28:

- The connected stock K0 Max enumerated as VID/PID `3434:0A06` with Raw HID
  usage page `0xFF60`, usage `0x61`, and 32-byte reports.
- A read-only host probe received Keychron protocol version 2 and command set
  2 from the stock firmware.
- Stock and diagnostic firmware compiled from pinned Keychron commit
  `07bfc38a4b11b8dac7ab758dfc5868b4229499ca` with QMK CLI 1.2.0 and
  `arm-none-eabi-gcc` 15.2.0.
- The current diagnostic source digest/build ID is
  `4103537d7ed1e99951264b39259cf7ad109a6c623dc1c674b5ff0d3bffc11368`
  / `0x4103537d`. The built image is 73,188 bytes; stock is 71,104 bytes.
- The probe's CRC-8/ATM golden `HELLO` vector passed with CRC `0x97`.
- After rebasing the spike onto `origin/main` at `26b13d4`, both firmware
  images and the macOS probe rebuilt successfully and the temporary Keychron
  source checkout remained clean.
- A fresh read-only stock probe again received Keychron protocol version 2
  and command set 2. Physical Esc-at-plug-in recovery then enumerated the
  STM32 bootloader as `0483:DF11`; a normal reconnect returned to stock
  firmware before the first custom image was written.
- The diagnostic image flashed successfully over DFU. Its USB exercise
  advertised build `0x4103537d` and reported `yes` for handshake, layer,
  selection, action, and watchdog evidence. Hardware observation confirmed
  that M4 entered Agent Control, `1` pulsed blue, digit LEDs `2` through `0`
  were off, and the ordinary RGB effect returned after watchdog expiry.
- The diagnostic selection and Enter action were logged and acknowledged
  only; no Agent Island session action or approval was dispatched. After
  watchdog exit, a physical `1` press again produced an ordinary numpad
  keystroke.
- The 2.4 GHz receiver test is deferred because the receiver is USB-A and the
  test Mac has no compatible port or adapter. Wireless support remains
  unclaimed.
- Keychron Launcher 1.4.2 connected as `Keychron K0 Max RGB`, read all four
  VIA layers, and preserved the dedicated M4/M5 custom keycodes. A reversible
  brightness write changed `10` to `9` and restored `10`.
- With Launcher still connected, a second diagnostic exercise again reported
  `yes` for handshake, layer, selection, action, and watchdog evidence. The
  reserved `0xAC` family therefore coexisted with ordinary VIA traffic in the
  tested USB configuration.

Build, recovery, flash, probe, and restore instructions live in
[`Hardware/KeychronK0Max/README.md`](../../../Hardware/KeychronK0Max/README.md).

### Round 3 — Stable slot and projection model

- [x] Add a pure ten-slot allocator and persisted assignment store.
- [x] Add phase-to-device-state projection.
- [x] Add overflow and completion-expiry behavior.
- [x] Expose matching slot labels to Agent Island presentation state.
- [x] Cover startup ordering, new arrivals, temporary disappearance, restart,
  completion expiry, slot reuse, hidden approvals, subagent exclusion, and
  overflow with unit tests.

Exit criterion: deterministic tests prove that a live agent does not change
numbers unexpectedly.

#### Round 3 evidence

On 2026-07-28:

- `AgentControlSlotAllocator` deterministically assigns ten device-independent
  slots, preserves active assignments, restores persisted preferences, and
  lets overflow candidates claim released capacity without rotating live
  sessions.
- `AgentControlLightState` projects running, actionable and observed approval,
  question, recent-completion, and idle states using the protocol's v1 raw
  values.
- `AgentControlSlotCoordinator` filters stale completions, subagents, and
  realtime voice sessions, then persists preferred assignments through a
  versioned `UserDefaults` store.
- `AppModel` exposes the shared projection and `1`-`9`/`0` labels. The
  closed-island agent grid now consumes the same stable ordering instead of a
  separate process-lifetime ticket map.
- Focused allocator/store, presentation, and existing grid test suites passed
  19 tests. The full `swift test` run passed 434 Swift Testing tests plus 24
  XCTest tests; the live Ghostty integration test remained intentionally
  skipped behind its existing environment gate.

### Round 4 — macOS HID transport

- [x] Add a transport protocol and fake implementation.
- [x] Discover the K0 Max by VID/PID and Raw HID usage.
- [x] Implement handshake, capability checks, heartbeat, reconnect, and
  sleep/wake recovery.
- [x] Add packet validation, sequence handling, snapshot deduplication, and
  structured diagnostics.
- [x] Handle multiple matching devices deterministically or present a device
  choice before enabling.

Exit criterion: transport tests pass without hardware, and the real transport
survives unplug/replug and app restart without stale lights.

#### Round 4 evidence

On 2026-07-28:

- The Core codec matches the Round 2 golden `HELLO` vector byte for byte,
  including CRC `0x97`, and rejects invalid length, magic, major version,
  flags, payload length, CRC, and nonzero padding.
- The production IOHID transport matches VID/PID `3434:0A06`, primary usage
  page `0xFF60`, and primary usage `0x61`. It selects multiple interfaces
  deterministically by location ID and then registry-entry ID.
- The coordinator uses a fresh nonzero nonce per connection, advertises only
  read-only snapshot support in this round, validates capabilities, sends
  monotonic sequences and two-second heartbeats, deduplicates snapshots by
  slot identity and light state, retries failures/timeouts, and resets across
  disconnect, sleep, and wake.
- Eighteen deterministic codec/coordinator tests pass using the fake
  transport. They cover capability incompatibility, heartbeat, snapshot
  deduplication, stale handshake containment, sequence replay/out-of-order
  rejection, send failure, timeout, disconnect/replug, sleep/wake, and
  multi-device selection.
- The complete suite passed 452 Swift Testing tests and 26 XCTest tests.
  Three opt-in live tests were skipped in the ordinary run: the two K0 Max
  gates and the existing Ghostty jump gate.
- The opt-in live USB test passed against diagnostic firmware build
  `0x4103537d`: real IOHID discovery, handshake, snapshot, coordinator stop,
  a new host connection, and an empty clearing snapshot all completed.
- The opt-in manual USB unplug/replug test passed. The real removal callback
  returned the coordinator to searching, reconnect rediscovered the keyboard,
  and a fresh handshake returned the coordinator to ready without restarting
  the host process.

The production coordinator is not started by `AppModel` in this round.
Opt-in preference, visible device status, and real session snapshot wiring
remain Round 6 work.

### Round 5 — Complete firmware behavior

- [ ] Implement the dedicated M4 control behavior and momentary M5 Fn
  behavior.
- [ ] Implement all ten LED states and local animations.
- [ ] Implement selection, jump, allow-once, and deny intents.
- [ ] Implement action acknowledgements and local feedback.
- [ ] Keep all live Agent Island state in RAM.
- [ ] Implement watchdog-driven clearing and base-layer recovery.

Exit criterion: firmware behavior matches the protocol using the diagnostic
host, with no Agent Island application dependency.

### Round 6 — Read-only Agent Island integration

- [ ] Add an opt-in K0 Max setting and visible connection/protocol status.
- [ ] Connect the slot projection to snapshots and heartbeat.
- [ ] Show hardware slot labels in Agent Island.
- [ ] Ship no navigation or approval action in this round.

Exit criterion: real sessions drive correct lighting, while all keyboard
actions remain disabled.

### Round 7 — Selection and navigation

- [ ] Route digit selection to the exact current slot/session mapping.
- [ ] Reveal the selected card without jumping.
- [ ] Route Enter through the existing session-scoped jump behavior.
- [ ] Reject stale selections and acknowledge accepted/rejected intents.

Exit criterion: selection and jump pass unit, harness, and manual
multi-session tests.

### Round 8 — Guarded approval and denial

- [ ] Extend permission resolution with expected request identity.
- [ ] Add selection tokens and end-to-end request matching.
- [ ] Enable `+` allow-once and `-` deny behind a separate opt-in.
- [ ] Test request replacement, slot reuse, duplicate packets, expired tokens,
  observer-only waits, questions, and bridge disconnects.

Exit criterion: a stale action cannot resolve a newer request, and every
negative test produces no agent-side authorization.

### Round 9 — Packaging and support

- [ ] Provide pinned build, flash, restore, upgrade, and uninstall
  documentation.
- [ ] Publish firmware source and required license notices with binaries.
- [ ] Record USB and 2.4 GHz support status accurately.
- [ ] Measure RGB battery impact and document expected tradeoffs.
- [ ] Run the complete regression matrix and move this plan to `completed/`.

## Verification Matrix

### Automated

- Slot allocator and persistence unit tests
- Phase projection and completion-expiry tests
- Packet golden vectors, CRC, length, enum, and malformed-input tests
- Sequence, nonce, replay, token-expiry, and request-identity tests
- Fake-transport reconnect and heartbeat tests
- Existing Agent Island `swift test` suite
- QMK compile for the pinned K0 Max target

### Hardware

| Scenario | USB | 2.4 GHz |
|---|---:|---:|
| Handshake and capabilities | Required | Required before claiming support |
| State snapshot and all ten LEDs | Required | Required before claiming support |
| Digit selection | Required | Required before claiming support |
| Enter jump intent | Required | Required before claiming support |
| `+` and `-` intent | Required | Required before claiming support |
| App crash/watchdog recovery | Required | Required before claiming support |
| Unplug/replug and keyboard reboot | Required | Required before claiming support |
| macOS sleep/wake | Required | Required before claiming support |
| Launcher/VIA coexistence | Required | Configure over USB; retest wireless afterward |
| Restore stock firmware | Required | Not applicable |

Approval tests begin with a fake resolver. Hardware is allowed to resolve only
disposable, non-destructive test requests until stale-request cases pass.

## Non-goals For V1

- Bluetooth transport
- More than ten hardware slots or automatic paging
- Individual subagent slots
- Persistent or "always allow" authorization
- Answering structured questions from the keyboard
- Automatic firmware flashing from Agent Island
- General support for other QMK keyboards
- Full VIA remapping of Agent Control actions

## Risks And Decision Gates

| Risk | Gate or mitigation |
|---|---|
| 2.4 GHz may not support unsolicited device-to-host Raw HID consistently | Round 2 must prove it; otherwise ship USB first and evaluate polling separately |
| Launcher may contend for the same Raw HID interface | Filter the reserved family and test simultaneous access before claiming coexistence |
| Reserving M4 removes one stock macro position | Keep M5 as immediate momentary Fn and make the reserved M4 behavior explicit in the integration UI and firmware notes |
| Firmware update can temporarily brick normal use | Prove and document stock recovery before the first custom flash |
| External hardware could approve the wrong request after a race | Bind action through the bridge to the exact permission request identity |
| Animated RGB reduces wireless battery life | Animate locally, avoid host-rate flashing, measure and document battery impact |
| Keychron can allocate command `0xAC` later | Pin source and re-audit on every upstream rebase |
| Multiple K0 Max devices can share VID/PID | Add deterministic device identity or require explicit selection |
| macOS HID behavior may differ across OS releases | Keep a fake transport and manually verify the oldest supported macOS version |

## Round 1 Verification

- Confirm all referenced Agent Island source paths and symbols exist.
- Confirm the pinned Keychron commit, K0 Max build target, VID/PID, matrix, Raw
  HID support, and LED map from official source.
- Check relative Markdown links.
- Run `git diff --check`.
- Review scope against `docs/product.md` and the repository's fail-open
  principle.
