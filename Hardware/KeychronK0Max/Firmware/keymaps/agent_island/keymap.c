// Copyright 2026 Brayant De Leon
// SPDX-License-Identifier: GPL-2.0-or-later

#include QMK_KEYBOARD_H
#include "agent_island_build_id.h"
#include "keychron_common.h"
#include "keychron_raw_hid.h"
#include "keymap_introspection.h"
#include "raw_hid.h"

enum layers {
    BASE,
    FN,
    AGENT,
};

enum custom_keycodes {
    AI_TOGGLE = SAFE_RANGE,
    AI_FN,
    AI_SLOT_1,
    AI_SLOT_2,
    AI_SLOT_3,
    AI_SLOT_4,
    AI_SLOT_5,
    AI_SLOT_6,
    AI_SLOT_7,
    AI_SLOT_8,
    AI_SLOT_9,
    AI_SLOT_10,
    AI_JUMP,
    AI_ALLOW,
    AI_DENY,
};

enum agent_island_message {
    AI_MSG_HELLO          = 0x01,
    AI_MSG_STATE_SNAPSHOT = 0x02,
    AI_MSG_HEARTBEAT      = 0x03,
    AI_MSG_SELECTION_ACK  = 0x04,
    AI_MSG_ACTION_RESULT  = 0x05,
    AI_MSG_CAPABILITIES   = 0x81,
    AI_MSG_SLOT_SELECTED  = 0x82,
    AI_MSG_ACTION_INVOKED = 0x83,
    AI_MSG_LAYER_CHANGED  = 0x84,
};

enum agent_island_action {
    AI_ACTION_JUMP       = 1,
    AI_ACTION_ALLOW_ONCE = 2,
    AI_ACTION_DENY       = 3,
};

enum agent_island_layer_reason {
    AI_LAYER_CONTROL_TAP      = 0,
    AI_LAYER_WATCHDOG_EXPIRED = 1,
    AI_LAYER_HOST_DISCONNECT  = 2,
    AI_LAYER_FIRMWARE_RESET   = 3,
    AI_LAYER_INCOMPATIBLE_HOST = 4,
};

enum agent_island_constants {
    AI_COMMAND_FAMILY          = 0xAC,
    AI_MAGIC_0                 = 0x41,
    AI_MAGIC_1                 = 0x49,
    AI_PROTOCOL_MAJOR          = 0x01,
    AI_PROTOCOL_MINOR          = 0x00,
    AI_RESPONSE_FLAG           = 0x01,
    AI_ERROR_FLAG              = 0x02,
    AI_KNOWN_FLAGS             = AI_RESPONSE_FLAG | AI_ERROR_FLAG,
    AI_REPORT_SIZE             = 32,
    AI_PAYLOAD_MAX             = 22,
    AI_SLOT_COUNT              = 10,
    AI_DEFAULT_WATCHDOG_SEC    = 6,
    AI_CAP_STATE_SNAPSHOTS     = 1U << 0,
    AI_CAP_SELECTION           = 1U << 1,
    AI_CAP_JUMP                = 1U << 2,
    AI_CAP_ALLOW_ONCE          = 1U << 3,
    AI_CAP_DENY                = 1U << 4,
    AI_ALL_CAPABILITIES        = 0x1F,
    AI_ALLOWED_ACTIONS         = 0x07,
    AI_MAX_SLOT_STATE          = 6,
    AI_RESPONSE_TIMEOUT_MS     = 2000,
    AI_SELECTION_FEEDBACK_MS   = 350,
    AI_ACTION_FEEDBACK_MS      = 500,
    AI_REJECTED_FEEDBACK_MS    = 650,
    AI_UNAVAILABLE_FEEDBACK_MS = 500,
    AI_LED_CONTROL             = 18,
};

static const uint8_t ai_slot_leds[AI_SLOT_COUNT] = {19, 20, 21, 15, 16, 17, 10, 11, 12, 23};
static const uint8_t ai_action_leds[3]            = {25, 13, 8};

static bool     ai_handshake_active;
static bool     ai_agent_control_active;
static bool     ai_fn_active;
static bool     ai_fn_restore_agent;
static bool     ai_rgb_was_enabled;
static bool     ai_feedback_active;
static bool     ai_feedback_restore_rgb_off;
static bool     ai_snapshot_seen;
static bool     ai_pending_selection;
static bool     ai_pending_action;
static uint8_t  ai_last_transport;
static uint8_t  ai_watchdog_seconds = AI_DEFAULT_WATCHDOG_SEC;
static uint8_t  ai_slot_states[AI_SLOT_COUNT];
static uint8_t  ai_overflow_count;
static uint8_t  ai_selected_slot = 0xFF;
static uint8_t  ai_allowed_actions;
static uint8_t  ai_selection_lifetime_seconds;
static uint8_t  ai_pending_selection_slot;
static uint8_t  ai_pending_action_slot;
static uint8_t  ai_pending_action_kind;
static uint8_t  ai_feedback_led;
static uint8_t  ai_feedback_red;
static uint8_t  ai_feedback_green;
static uint8_t  ai_feedback_blue;
static uint8_t  ai_selection_token[8];
static uint8_t  ai_connection_nonce[8];
static uint16_t ai_host_capabilities;
static uint16_t ai_snapshot_generation;
static uint16_t ai_device_sequence = 1;
static uint16_t ai_last_host_sequence;
static uint16_t ai_pending_selection_sequence;
static uint16_t ai_pending_action_sequence;
static uint32_t ai_watchdog_timer;
static uint32_t ai_selection_timer;
static uint32_t ai_pending_selection_timer;
static uint32_t ai_pending_action_timer;
static uint32_t ai_feedback_timer;
static uint16_t ai_feedback_duration_ms;

static uint8_t ai_crc8(const uint8_t *data, uint8_t length) {
    uint8_t crc = 0;
    for (uint8_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (uint8_t bit = 0; bit < 8; ++bit) {
            crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07) : (uint8_t)(crc << 1);
        }
    }
    return crc;
}

static uint16_t ai_read_u16(const uint8_t *data) {
    return (uint16_t)data[0] | ((uint16_t)data[1] << 8);
}

static void ai_write_u16(uint8_t *data, uint16_t value) {
    data[0] = value & 0xFF;
    data[1] = value >> 8;
}

static void ai_write_u32(uint8_t *data, uint32_t value) {
    data[0] = value & 0xFF;
    data[1] = (value >> 8) & 0xFF;
    data[2] = (value >> 16) & 0xFF;
    data[3] = (value >> 24) & 0xFF;
}

static bool ai_nonce_is_nonzero(const uint8_t *nonce) {
    uint8_t combined = 0;
    for (uint8_t i = 0; i < 8; ++i) {
        combined |= nonce[i];
    }
    return combined != 0;
}

static bool ai_nonce_matches(const uint8_t *nonce) {
    return ai_handshake_active && memcmp(nonce, ai_connection_nonce, sizeof(ai_connection_nonce)) == 0;
}

static bool ai_bytes_are_nonzero(const uint8_t *bytes, uint8_t length) {
    uint8_t combined = 0;
    for (uint8_t i = 0; i < length; ++i) {
        combined |= bytes[i];
    }
    return combined != 0;
}

static bool ai_sequence_is_newer(uint16_t candidate, uint16_t previous) {
    uint16_t distance = candidate - previous;
    return distance != 0 && distance < 0x8000;
}

static bool ai_packet_is_valid(const uint8_t *data, uint8_t length) {
    if (length != AI_REPORT_SIZE ||
        data[0] != AI_COMMAND_FAMILY ||
        data[1] != AI_MAGIC_0 ||
        data[2] != AI_MAGIC_1 ||
        data[3] != AI_PROTOCOL_MAJOR ||
        (data[5] & ~AI_KNOWN_FLAGS) != 0 ||
        data[8] > AI_PAYLOAD_MAX ||
        ai_crc8(data, AI_REPORT_SIZE - 1) != data[AI_REPORT_SIZE - 1]) {
        return false;
    }

    for (uint8_t index = 9 + data[8]; index < AI_REPORT_SIZE - 1; ++index) {
        if (data[index] != 0) {
            return false;
        }
    }
    return true;
}

static void ai_send_packet(uint8_t type, uint8_t flags, uint16_t sequence, const uint8_t *payload, uint8_t payload_length) {
    uint8_t packet[AI_REPORT_SIZE] = {0};
    packet[0]                      = AI_COMMAND_FAMILY;
    packet[1]                      = AI_MAGIC_0;
    packet[2]                      = AI_MAGIC_1;
    packet[3]                      = AI_PROTOCOL_MAJOR;
    packet[4]                      = type;
    packet[5]                      = flags;
    ai_write_u16(&packet[6], sequence);
    packet[8] = payload_length;
    if (payload_length > 0) {
        memcpy(&packet[9], payload, payload_length);
    }
    packet[AI_REPORT_SIZE - 1] = ai_crc8(packet, AI_REPORT_SIZE - 1);
    kc_raw_hid_send(ai_last_transport, packet, sizeof(packet));
}

static void ai_clear_pending_intents(void) {
    ai_pending_selection          = false;
    ai_pending_action             = false;
    ai_pending_selection_slot     = 0xFF;
    ai_pending_action_slot        = 0xFF;
    ai_pending_action_kind        = 0;
    ai_pending_selection_sequence = 0;
    ai_pending_action_sequence    = 0;
}

static void ai_clear_selection(void) {
    ai_selected_slot              = 0xFF;
    ai_allowed_actions            = 0;
    ai_selection_lifetime_seconds = 0;
    memset(ai_selection_token, 0, sizeof(ai_selection_token));
    ai_clear_pending_intents();
}

static void ai_end_feedback(void) {
    if (!ai_feedback_active) {
        return;
    }

    ai_feedback_active = false;
    if (ai_feedback_restore_rgb_off) {
        rgb_matrix_disable_noeeprom();
    }
    ai_feedback_restore_rgb_off = false;
}

static void ai_start_feedback(
    uint8_t led,
    uint8_t red,
    uint8_t green,
    uint8_t blue,
    uint16_t duration_ms
) {
    ai_end_feedback();
    if (!ai_agent_control_active && !rgb_matrix_is_enabled()) {
        rgb_matrix_enable_noeeprom();
        ai_feedback_restore_rgb_off = true;
    }

    ai_feedback_led         = led;
    ai_feedback_red         = red;
    ai_feedback_green       = green;
    ai_feedback_blue        = blue;
    ai_feedback_duration_ms = duration_ms;
    ai_feedback_timer       = timer_read32();
    ai_feedback_active      = true;
}

static void ai_restore_base_rgb(void) {
    if (!ai_rgb_was_enabled && rgb_matrix_is_enabled()) {
        rgb_matrix_disable_noeeprom();
    }
}

static void ai_prepare_agent_rgb(void) {
    ai_rgb_was_enabled = rgb_matrix_is_enabled();
    if (!ai_rgb_was_enabled) {
        rgb_matrix_enable_noeeprom();
    }
}

static void ai_send_layer_changed(bool enabled, uint8_t reason) {
    uint8_t payload[10] = {0};
    memcpy(payload, ai_connection_nonce, sizeof(ai_connection_nonce));
    payload[8] = enabled ? 1 : 0;
    payload[9] = reason;
    ai_send_packet(AI_MSG_LAYER_CHANGED, 0, ai_device_sequence++, payload, sizeof(payload));
}

static void ai_set_agent_control(bool enabled, uint8_t reason) {
    if (enabled == ai_agent_control_active) {
        return;
    }

    ai_end_feedback();
    ai_clear_selection();
    if (enabled) {
        ai_prepare_agent_rgb();
        ai_agent_control_active = true;
        layer_on(AGENT);
    } else {
        layer_off(AGENT);
        ai_agent_control_active = false;
        ai_restore_base_rgb();
    }
    if (ai_handshake_active) {
        ai_send_layer_changed(enabled, reason);
    }
}

static void ai_expire_connection(void) {
    if (ai_handshake_active) {
        ai_set_agent_control(false, AI_LAYER_WATCHDOG_EXPIRED);
    } else {
        layer_off(AGENT);
        ai_agent_control_active = false;
    }
    ai_handshake_active = false;
    ai_clear_selection();
    memset(ai_connection_nonce, 0, sizeof(ai_connection_nonce));
    memset(ai_slot_states, 0, sizeof(ai_slot_states));
    ai_host_capabilities   = 0;
    ai_overflow_count      = 0;
    ai_snapshot_seen       = false;
    ai_snapshot_generation = 0;
    ai_last_host_sequence   = 0;
}

static void ai_refresh_watchdog(void) {
    ai_watchdog_timer = timer_read32();
}

static void ai_send_capabilities(uint16_t response_sequence) {
    uint8_t response[18] = {0};
    memcpy(response, ai_connection_nonce, sizeof(ai_connection_nonce));
    response[8]  = AI_PROTOCOL_MINOR;
    response[9]  = AI_SLOT_COUNT;
    response[10] = AI_ALL_CAPABILITIES;
    response[11] = 0;
    response[12] = ai_last_transport == RAW_HID_SRC_USB ? 1 : 2;
    response[13] = ai_watchdog_seconds;
    ai_write_u32(&response[14], AGENT_ISLAND_BUILD_ID);
    ai_send_packet(
        AI_MSG_CAPABILITIES,
        AI_RESPONSE_FLAG,
        response_sequence,
        response,
        sizeof(response)
    );
}

static void ai_handle_hello(uint8_t src, const uint8_t *packet) {
    const uint8_t *payload = &packet[9];
    uint16_t host_capabilities;
    if (packet[5] != 0 ||
        packet[8] != 12 ||
        payload[0] != AI_PROTOCOL_MINOR ||
        !ai_nonce_is_nonzero(&payload[1])) {
        return;
    }

    host_capabilities = ai_read_u16(&payload[10]);
    if (!(host_capabilities & AI_CAP_STATE_SNAPSHOTS) ||
        (host_capabilities & ~AI_ALL_CAPABILITIES) != 0) {
        return;
    }

    if (ai_handshake_active &&
        src == ai_last_transport &&
        memcmp(&payload[1], ai_connection_nonce, sizeof(ai_connection_nonce)) == 0 &&
        ai_read_u16(&packet[6]) == ai_last_host_sequence) {
        ai_refresh_watchdog();
        ai_send_capabilities(ai_last_host_sequence);
        return;
    }

    if (ai_agent_control_active) {
        ai_set_agent_control(false, AI_LAYER_HOST_DISCONNECT);
    }
    ai_end_feedback();
    ai_clear_selection();
    memset(ai_slot_states, 0, sizeof(ai_slot_states));
    memcpy(ai_connection_nonce, &payload[1], sizeof(ai_connection_nonce));
    ai_last_transport      = src;
    ai_handshake_active    = true;
    ai_watchdog_seconds    = AI_DEFAULT_WATCHDOG_SEC;
    ai_host_capabilities   = host_capabilities;
    ai_device_sequence     = 1;
    ai_last_host_sequence  = ai_read_u16(&packet[6]);
    ai_snapshot_seen       = false;
    ai_overflow_count      = 0;
    ai_snapshot_generation = 0;
    ai_refresh_watchdog();

    ai_send_capabilities(ai_last_host_sequence);
}

static void ai_handle_snapshot(const uint8_t *packet) {
    const uint8_t *payload = &packet[9];
    uint16_t       sequence;
    uint16_t       generation;
    const uint8_t *states;

    if (packet[5] != 0 || packet[8] != 21 || !ai_nonce_matches(payload)) {
        return;
    }

    sequence = ai_read_u16(&packet[6]);
    if (!ai_sequence_is_newer(sequence, ai_last_host_sequence)) {
        return;
    }

    states = &payload[11];
    for (uint8_t slot = 0; slot < AI_SLOT_COUNT; ++slot) {
        if (states[slot] > AI_MAX_SLOT_STATE) {
            return;
        }
    }

    generation = ai_read_u16(&payload[8]);
    if (ai_snapshot_seen && generation == ai_snapshot_generation) {
        if (payload[10] != ai_overflow_count ||
            memcmp(states, ai_slot_states, sizeof(ai_slot_states)) != 0) {
            return;
        }
    } else {
        if (ai_selected_slot < AI_SLOT_COUNT &&
            ai_slot_states[ai_selected_slot] != states[ai_selected_slot]) {
            ai_clear_selection();
        }
        ai_snapshot_generation = generation;
        ai_overflow_count      = payload[10];
        memcpy(ai_slot_states, states, sizeof(ai_slot_states));
        ai_snapshot_seen = true;
    }

    ai_last_host_sequence = sequence;
    ai_refresh_watchdog();
}

static void ai_handle_heartbeat(const uint8_t *packet) {
    uint16_t sequence;
    if (packet[5] != 0 || packet[8] != 8 || !ai_nonce_matches(&packet[9])) {
        return;
    }

    sequence = ai_read_u16(&packet[6]);
    if (!ai_sequence_is_newer(sequence, ai_last_host_sequence)) {
        return;
    }
    ai_last_host_sequence = sequence;
    ai_refresh_watchdog();
}

static void ai_handle_selection_ack(const uint8_t *packet) {
    const uint8_t *payload = &packet[9];
    uint8_t        slot;
    uint8_t        result;
    uint8_t        allowed_actions;
    const uint8_t *token;

    if ((packet[5] & AI_RESPONSE_FLAG) == 0 ||
        packet[8] != 22 ||
        !ai_nonce_matches(payload) ||
        !ai_pending_selection ||
        ai_read_u16(&packet[6]) != ai_pending_selection_sequence) {
        return;
    }

    slot    = payload[8];
    result  = payload[9];
    token   = &payload[12];
    ai_pending_selection = false;

    if ((packet[5] & AI_ERROR_FLAG) != 0 ||
        result != 0 ||
        slot >= AI_SLOT_COUNT ||
        slot != ai_pending_selection_slot ||
        payload[21] == 0 ||
        !ai_bytes_are_nonzero(token, sizeof(ai_selection_token))) {
        ai_clear_selection();
        if (slot < AI_SLOT_COUNT) {
            ai_start_feedback(
                ai_slot_leds[slot],
                255,
                96,
                0,
                AI_REJECTED_FEEDBACK_MS
            );
        }
        return;
    }

    allowed_actions = payload[20] & AI_ALLOWED_ACTIONS;
    if (!(ai_host_capabilities & AI_CAP_JUMP)) {
        allowed_actions &= ~(1U << (AI_ACTION_JUMP - 1));
    }
    if (!(ai_host_capabilities & AI_CAP_ALLOW_ONCE)) {
        allowed_actions &= ~(1U << (AI_ACTION_ALLOW_ONCE - 1));
    }
    if (!(ai_host_capabilities & AI_CAP_DENY)) {
        allowed_actions &= ~(1U << (AI_ACTION_DENY - 1));
    }

    ai_selected_slot              = slot;
    ai_allowed_actions            = allowed_actions;
    ai_selection_lifetime_seconds = payload[21];
    ai_selection_timer             = timer_read32();
    memcpy(ai_selection_token, token, sizeof(ai_selection_token));
    ai_start_feedback(
        ai_slot_leds[slot],
        255,
        255,
        255,
        AI_SELECTION_FEEDBACK_MS
    );
}

static void ai_handle_action_result(const uint8_t *packet) {
    const uint8_t *payload = &packet[9];
    uint8_t result;

    if ((packet[5] & AI_RESPONSE_FLAG) == 0 ||
        packet[8] != 11 ||
        !ai_nonce_matches(payload) ||
        !ai_pending_action ||
        ai_read_u16(&packet[6]) != ai_pending_action_sequence ||
        payload[8] != ai_pending_action_slot ||
        payload[9] != ai_pending_action_kind) {
        return;
    }

    result            = payload[10];
    ai_pending_action = false;
    if ((packet[5] & AI_ERROR_FLAG) != 0 || result != 0) {
        ai_start_feedback(
            ai_action_leds[ai_pending_action_kind - 1],
            255,
            96,
            0,
            AI_REJECTED_FEEDBACK_MS
        );
        ai_clear_selection();
        return;
    }

    ai_start_feedback(
        ai_action_leds[ai_pending_action_kind - 1],
        0,
        255,
        0,
        AI_ACTION_FEEDBACK_MS
    );
    if (ai_pending_action_kind != AI_ACTION_JUMP) {
        ai_clear_selection();
    }
}

bool keychron_raw_hid_receive_user(uint8_t src, uint8_t *data, uint8_t length) {
    if (length == 0 || data[0] != AI_COMMAND_FAMILY) {
        return false;
    }
    if (!ai_packet_is_valid(data, length)) {
        return true;
    }

    switch (data[4]) {
        case AI_MSG_HELLO:
            ai_handle_hello(src, data);
            break;
        case AI_MSG_STATE_SNAPSHOT:
            ai_handle_snapshot(data);
            break;
        case AI_MSG_HEARTBEAT:
            ai_handle_heartbeat(data);
            break;
        case AI_MSG_SELECTION_ACK:
            ai_handle_selection_ack(data);
            break;
        case AI_MSG_ACTION_RESULT:
            ai_handle_action_result(data);
            break;
    }
    return true;
}

static void ai_send_slot_selected(uint8_t slot) {
    uint16_t sequence;

    ai_clear_selection();
    sequence                      = ai_device_sequence++;
    ai_pending_selection          = true;
    ai_pending_selection_slot     = slot;
    ai_pending_selection_sequence = sequence;
    ai_pending_selection_timer    = timer_read32();

    uint8_t payload[11] = {0};
    memcpy(payload, ai_connection_nonce, sizeof(ai_connection_nonce));
    payload[8] = slot;
    ai_write_u16(&payload[9], ai_snapshot_generation);
    ai_send_packet(AI_MSG_SLOT_SELECTED, 0, sequence, payload, sizeof(payload));
}

static void ai_send_action(uint8_t action) {
    uint8_t  required_bit;
    uint16_t sequence;

    if (action < AI_ACTION_JUMP || action > AI_ACTION_DENY) {
        return;
    }
    required_bit = 1U << (action - 1);
    if (ai_pending_action ||
        ai_selected_slot >= AI_SLOT_COUNT ||
        !(ai_allowed_actions & required_bit) ||
        !ai_bytes_are_nonzero(ai_selection_token, sizeof(ai_selection_token))) {
        ai_start_feedback(
            ai_action_leds[action - 1],
            255,
            96,
            0,
            AI_REJECTED_FEEDBACK_MS
        );
        return;
    }

    sequence                   = ai_device_sequence++;
    ai_pending_action          = true;
    ai_pending_action_slot     = ai_selected_slot;
    ai_pending_action_kind     = action;
    ai_pending_action_sequence = sequence;
    ai_pending_action_timer    = timer_read32();

    uint8_t payload[18] = {0};
    memcpy(payload, ai_connection_nonce, sizeof(ai_connection_nonce));
    payload[8] = ai_selected_slot;
    payload[9] = action;
    memcpy(&payload[10], ai_selection_token, sizeof(ai_selection_token));
    ai_send_packet(AI_MSG_ACTION_INVOKED, 0, sequence, payload, sizeof(payload));
}

bool process_record_user(uint16_t keycode, keyrecord_t *record) {
    if (keycode == AI_TOGGLE) {
        if (record->event.pressed && !ai_fn_active) {
            if (ai_handshake_active && timer_elapsed32(ai_watchdog_timer) <= (uint32_t)ai_watchdog_seconds * 1000U) {
                ai_set_agent_control(!ai_agent_control_active, AI_LAYER_CONTROL_TAP);
            } else {
                ai_start_feedback(
                    AI_LED_CONTROL,
                    255,
                    96,
                    0,
                    AI_UNAVAILABLE_FEEDBACK_MS
                );
            }
        }
        return false;
    }

    if (keycode == AI_FN) {
        if (record->event.pressed && !ai_fn_active) {
            ai_fn_restore_agent = ai_agent_control_active;
            if (ai_fn_restore_agent) {
                layer_off(AGENT);
                ai_restore_base_rgb();
            }
            layer_on(FN);
            ai_fn_active = true;
        } else if (!record->event.pressed && ai_fn_active) {
            layer_off(FN);
            if (ai_fn_restore_agent && ai_agent_control_active && ai_handshake_active) {
                ai_prepare_agent_rgb();
                layer_on(AGENT);
            }
            ai_fn_active         = false;
            ai_fn_restore_agent  = false;
        }
        return false;
    }

    if (keycode >= AI_SLOT_1 && keycode <= AI_SLOT_10) {
        if (record->event.pressed && ai_agent_control_active && ai_handshake_active) {
            uint8_t slot = (uint8_t)(keycode - AI_SLOT_1);
            if (ai_host_capabilities & AI_CAP_SELECTION) {
                ai_send_slot_selected(slot);
            } else {
                ai_start_feedback(
                    ai_slot_leds[slot],
                    255,
                    96,
                    0,
                    AI_REJECTED_FEEDBACK_MS
                );
            }
        }
        return false;
    }

    if (keycode >= AI_JUMP && keycode <= AI_DENY) {
        if (record->event.pressed && ai_agent_control_active && ai_handshake_active) {
            ai_send_action((uint8_t)(keycode - AI_JUMP + AI_ACTION_JUMP));
        }
        return false;
    }

    return true;
}

static uint16_t ai_agent_keycode_for_position(keypos_t key) {
    if (key.row == 2 && key.col >= 1 && key.col <= 3) {
        return AI_SLOT_7 + (key.col - 1);
    }
    if (key.row == 3 && key.col >= 1 && key.col <= 3) {
        return AI_SLOT_4 + (key.col - 1);
    }
    if (key.row == 4 && key.col >= 1 && key.col <= 3) {
        return AI_SLOT_1 + (key.col - 1);
    }
    if (key.row == 5 && key.col == 1) {
        return AI_SLOT_10;
    }
    if (key.row == 5 && key.col == 4) {
        return AI_JUMP;
    }
    if (key.row == 2 && key.col == 4) {
        return AI_ALLOW;
    }
    if (key.row == 1 && key.col == 4) {
        return AI_DENY;
    }
    return KC_NO;
}

uint16_t keymap_key_to_keycode(uint8_t layer, keypos_t key) {
    if (key.row < MATRIX_ROWS && key.col < MATRIX_COLS) {
        if (key.row == 4 && key.col == 0) {
            return AI_TOGGLE;
        }
        if (key.row == 5 && key.col == 0) {
            return AI_FN;
        }
        if (layer == AGENT) {
            return ai_agent_keycode_for_position(key);
        }
        return keycode_at_keymap_location(layer, key.row, key.col);
    }
#ifdef ENCODER_MAP_ENABLE
    if (key.row == KEYLOC_ENCODER_CW && key.col < NUM_ENCODERS) {
        return keycode_at_encodermap_location(layer, key.col, true);
    }
    if (key.row == KEYLOC_ENCODER_CCW && key.col < NUM_ENCODERS) {
        return keycode_at_encodermap_location(layer, key.col, false);
    }
#endif
    return KC_NO;
}

void matrix_scan_user(void) {
    if (ai_handshake_active && timer_elapsed32(ai_watchdog_timer) > (uint32_t)ai_watchdog_seconds * 1000U) {
        ai_expire_connection();
    }
    if (ai_feedback_active && timer_elapsed32(ai_feedback_timer) > ai_feedback_duration_ms) {
        ai_end_feedback();
    }
    if (ai_pending_selection &&
        timer_elapsed32(ai_pending_selection_timer) > AI_RESPONSE_TIMEOUT_MS) {
        uint8_t slot       = ai_pending_selection_slot;
        ai_pending_selection = false;
        ai_clear_selection();
        if (slot < AI_SLOT_COUNT) {
            ai_start_feedback(
                ai_slot_leds[slot],
                255,
                96,
                0,
                AI_REJECTED_FEEDBACK_MS
            );
        }
    }
    if (ai_pending_action &&
        timer_elapsed32(ai_pending_action_timer) > AI_RESPONSE_TIMEOUT_MS) {
        uint8_t action = ai_pending_action_kind;
        ai_pending_action = false;
        ai_clear_selection();
        if (action >= AI_ACTION_JUMP && action <= AI_ACTION_DENY) {
            ai_start_feedback(
                ai_action_leds[action - 1],
                255,
                96,
                0,
                AI_REJECTED_FEEDBACK_MS
            );
        }
    }
    if (ai_selected_slot < AI_SLOT_COUNT &&
        ai_selection_lifetime_seconds > 0 &&
        timer_elapsed32(ai_selection_timer) >
            (uint32_t)ai_selection_lifetime_seconds * 1000U) {
        ai_clear_selection();
    }
}

static uint8_t ai_scale8(uint8_t value, uint8_t scale) {
    return ((uint16_t)value * scale) / 255U;
}

static uint8_t ai_pulse_value(void) {
    uint8_t phase    = (uint8_t)(timer_read() >> 3);
    uint8_t triangle = phase < 128 ? phase * 2 : (255 - phase) * 2;
    return 24 + ai_scale8(triangle, 231);
}

static void ai_set_slot_color(uint8_t led, uint8_t state) {
    uint8_t pulse = ai_pulse_value();
    switch (state) {
        case 2:
            rgb_matrix_set_color(led, 0, 0, pulse);
            break;
        case 3:
        case 4: {
            uint8_t flash = timer_read() & 0x80 ? 255 : 0;
            rgb_matrix_set_color(led, flash, 0, 0);
            break;
        }
        case 5:
            rgb_matrix_set_color(led, pulse, ai_scale8(pulse, 96), 0);
            break;
        case 6:
            rgb_matrix_set_color(led, 0, 255, 0);
            break;
        default:
            rgb_matrix_set_color(led, 0, 0, 0);
            break;
    }
}

bool rgb_matrix_indicators_advanced_user(uint8_t led_min, uint8_t led_max) {
    if (ai_agent_control_active && !ai_fn_active) {
        if (AI_LED_CONTROL >= led_min && AI_LED_CONTROL < led_max) {
            if (ai_overflow_count > 0) {
                rgb_matrix_set_color(AI_LED_CONTROL, 180, 0, 255);
            } else {
                rgb_matrix_set_color(AI_LED_CONTROL, 0, 180, 255);
            }
        }

        for (uint8_t slot = 0; slot < AI_SLOT_COUNT; ++slot) {
            uint8_t led = ai_slot_leds[slot];
            if (led >= led_min && led < led_max) {
                ai_set_slot_color(led, ai_slot_states[slot]);
            }
        }
        for (uint8_t action = 0; action < 3; ++action) {
            uint8_t led = ai_action_leds[action];
            if (led >= led_min && led < led_max) {
                rgb_matrix_set_color(led, 0, 0, 0);
            }
        }
    }

    if (ai_feedback_active &&
        ai_feedback_led >= led_min &&
        ai_feedback_led < led_max &&
        !ai_fn_active) {
        rgb_matrix_set_color(
            ai_feedback_led,
            ai_feedback_red,
            ai_feedback_green,
            ai_feedback_blue
        );
    }
    return true;
}

// clang-format off
const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {
    [BASE] = LAYOUT_tenkey_27(
        KC_MUTE, KC_ESC,  KC_DEL,  KC_TAB,  KC_BSPC,
        MC_1,    KC_NUM,  KC_PSLS, KC_PAST, KC_PMNS,
        MC_2,    KC_P7,   KC_P8,   KC_P9,   KC_PPLS,
        MC_3,    KC_P4,   KC_P5,   KC_P6,
        AI_TOGGLE, KC_P1, KC_P2,   KC_P3,
        AI_FN,   KC_P0,            KC_PDOT, KC_PENT),

    [FN] = LAYOUT_tenkey_27(
        UG_TOGG, BT_HST1, BT_HST2, BT_HST3, P2P4G,
        _______, UG_NEXT, UG_VALU, UG_HUEU, _______,
        _______, UG_PREV, UG_VALD, UG_HUED, _______,
        _______, UG_SATU, UG_SPDU, KC_MPRV,
        _______, UG_SATD, UG_SPDD, KC_MPLY,
        _______, UG_TOGG,          KC_MNXT, _______),

    [AGENT] = LAYOUT_tenkey_27(
        KC_NO,   KC_NO,   KC_NO,      KC_NO,     KC_NO,
        KC_NO,   KC_NO,   KC_NO,      KC_NO,     AI_DENY,
        KC_NO,   AI_SLOT_7, AI_SLOT_8, AI_SLOT_9, AI_ALLOW,
        KC_NO,   AI_SLOT_4, AI_SLOT_5, AI_SLOT_6,
        AI_TOGGLE, AI_SLOT_1, AI_SLOT_2, AI_SLOT_3,
        AI_FN,     AI_SLOT_10,          KC_NO,     AI_JUMP),
};

#if defined(ENCODER_MAP_ENABLE)
const uint16_t PROGMEM encoder_map[][NUM_ENCODERS][2] = {
    [BASE]  = {ENCODER_CCW_CW(KC_VOLD, KC_VOLU)},
    [FN]    = {ENCODER_CCW_CW(UG_VALD, UG_VALU)},
    [AGENT] = {ENCODER_CCW_CW(KC_NO, KC_NO)},
};
#endif
// clang-format on
