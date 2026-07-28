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

enum tap_dances {
    TD_AGENT_M5,
};

enum custom_keycodes {
    AI_SLOT_1 = SAFE_RANGE,
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
    AI_LAYER_M5_TAP          = 0,
    AI_LAYER_WATCHDOG_EXPIRED = 1,
};

enum agent_island_constants {
    AI_COMMAND_FAMILY       = 0xAC,
    AI_MAGIC_0              = 0x41,
    AI_MAGIC_1              = 0x49,
    AI_PROTOCOL_MAJOR       = 0x01,
    AI_PROTOCOL_MINOR       = 0x00,
    AI_RESPONSE_FLAG        = 0x01,
    AI_REPORT_SIZE          = 32,
    AI_PAYLOAD_MAX          = 22,
    AI_SLOT_COUNT           = 10,
    AI_DEFAULT_WATCHDOG_SEC = 6,
    AI_ALL_CAPABILITIES     = 0x1F,
    AI_LED_M5               = 22,
    AI_LED_SLOT_1           = 19,
};

static bool     ai_handshake_active;
static bool     ai_agent_control_active;
static bool     ai_m5_fn_active;
static bool     ai_m5_restore_agent;
static bool     ai_unavailable_feedback_active;
static uint8_t  ai_last_transport;
static uint8_t  ai_watchdog_seconds = AI_DEFAULT_WATCHDOG_SEC;
static uint8_t  ai_slot_states[AI_SLOT_COUNT];
static uint8_t  ai_selected_slot = 0xFF;
static uint8_t  ai_allowed_actions;
static uint8_t  ai_selection_token[8];
static uint8_t  ai_connection_nonce[8];
static uint16_t ai_snapshot_generation;
static uint16_t ai_device_sequence = 1;
static uint32_t ai_watchdog_timer;
static uint32_t ai_unavailable_feedback_timer;

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

static bool ai_packet_is_valid(const uint8_t *data, uint8_t length) {
    return length == AI_REPORT_SIZE &&
           data[0] == AI_COMMAND_FAMILY &&
           data[1] == AI_MAGIC_0 &&
           data[2] == AI_MAGIC_1 &&
           data[3] == AI_PROTOCOL_MAJOR &&
           data[8] <= AI_PAYLOAD_MAX &&
           ai_crc8(data, AI_REPORT_SIZE - 1) == data[AI_REPORT_SIZE - 1];
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

static void ai_clear_selection(void) {
    ai_selected_slot   = 0xFF;
    ai_allowed_actions = 0;
    memset(ai_selection_token, 0, sizeof(ai_selection_token));
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

    ai_agent_control_active = enabled;
    ai_clear_selection();
    if (enabled) {
        layer_on(AGENT);
    } else {
        layer_off(AGENT);
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
    ai_snapshot_generation = 0;
}

static void ai_refresh_watchdog(void) {
    ai_watchdog_timer = timer_read32();
}

static void ai_handle_hello(uint8_t src, const uint8_t *packet) {
    const uint8_t *payload = &packet[9];
    if (packet[8] < 12 || !ai_nonce_is_nonzero(&payload[1])) {
        return;
    }

    if (ai_agent_control_active) {
        layer_off(AGENT);
        ai_agent_control_active = false;
    }
    ai_clear_selection();
    memset(ai_slot_states, 0, sizeof(ai_slot_states));
    memcpy(ai_connection_nonce, &payload[1], sizeof(ai_connection_nonce));
    ai_last_transport    = src;
    ai_handshake_active  = true;
    ai_watchdog_seconds  = AI_DEFAULT_WATCHDOG_SEC;
    ai_device_sequence   = 1;
    ai_snapshot_generation = 0;
    ai_refresh_watchdog();

    uint8_t response[18] = {0};
    memcpy(response, ai_connection_nonce, sizeof(ai_connection_nonce));
    response[8]  = AI_PROTOCOL_MINOR;
    response[9]  = AI_SLOT_COUNT;
    response[10] = AI_ALL_CAPABILITIES;
    response[11] = 0;
    response[12] = src == RAW_HID_SRC_USB ? 1 : 2;
    response[13] = ai_watchdog_seconds;
    ai_write_u32(&response[14], AGENT_ISLAND_BUILD_ID);
    ai_send_packet(AI_MSG_CAPABILITIES, AI_RESPONSE_FLAG, ai_read_u16(&packet[6]), response, sizeof(response));
}

static void ai_handle_snapshot(const uint8_t *packet) {
    const uint8_t *payload = &packet[9];
    if (packet[8] < 21 || !ai_nonce_matches(payload)) {
        return;
    }

    ai_snapshot_generation = ai_read_u16(&payload[8]);
    memcpy(ai_slot_states, &payload[11], sizeof(ai_slot_states));
    ai_refresh_watchdog();
}

static void ai_handle_heartbeat(const uint8_t *packet) {
    if (packet[8] >= 8 && ai_nonce_matches(&packet[9])) {
        ai_refresh_watchdog();
    }
}

static void ai_handle_selection_ack(const uint8_t *packet) {
    const uint8_t *payload = &packet[9];
    if (packet[8] < 22 || !ai_nonce_matches(payload)) {
        return;
    }

    uint8_t slot   = payload[8];
    uint8_t result = payload[9];
    if (result != 0 || slot >= AI_SLOT_COUNT) {
        ai_clear_selection();
        return;
    }

    ai_selected_slot   = slot;
    ai_allowed_actions = payload[20];
    memcpy(ai_selection_token, &payload[12], sizeof(ai_selection_token));
}

static void ai_handle_action_result(const uint8_t *packet) {
    const uint8_t *payload = &packet[9];
    if (packet[8] < 11 || !ai_nonce_matches(payload)) {
        return;
    }

    if (payload[10] != 0) {
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
    uint8_t payload[11] = {0};
    memcpy(payload, ai_connection_nonce, sizeof(ai_connection_nonce));
    payload[8] = slot;
    ai_write_u16(&payload[9], ai_snapshot_generation);
    ai_send_packet(AI_MSG_SLOT_SELECTED, 0, ai_device_sequence++, payload, sizeof(payload));
}

static void ai_send_action(uint8_t action) {
    uint8_t required_bit = 1U << (action - 1);
    if (ai_selected_slot >= AI_SLOT_COUNT || !(ai_allowed_actions & required_bit)) {
        return;
    }

    uint8_t payload[18] = {0};
    memcpy(payload, ai_connection_nonce, sizeof(ai_connection_nonce));
    payload[8] = ai_selected_slot;
    payload[9] = action;
    memcpy(&payload[10], ai_selection_token, sizeof(ai_selection_token));
    ai_send_packet(AI_MSG_ACTION_INVOKED, 0, ai_device_sequence++, payload, sizeof(payload));
}

bool process_record_user(uint16_t keycode, keyrecord_t *record) {
    if (keycode >= AI_SLOT_1 && keycode <= AI_SLOT_10) {
        if (record->event.pressed && ai_agent_control_active && ai_handshake_active) {
            ai_send_slot_selected((uint8_t)(keycode - AI_SLOT_1));
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
        if (key.row == 5 && key.col == 0) {
            return TD(TD_AGENT_M5);
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

static void ai_m5_finished(tap_dance_state_t *state, void *user_data) {
    if (state->count != 1) {
        return;
    }

    if (state->pressed || state->interrupted) {
        ai_m5_restore_agent = ai_agent_control_active;
        if (ai_m5_restore_agent) {
            layer_off(AGENT);
        }
        layer_on(FN);
        ai_m5_fn_active = true;
        return;
    }

    if (ai_handshake_active && timer_elapsed32(ai_watchdog_timer) <= (uint32_t)ai_watchdog_seconds * 1000U) {
        ai_set_agent_control(!ai_agent_control_active, AI_LAYER_M5_TAP);
    } else {
        ai_unavailable_feedback_active = true;
        ai_unavailable_feedback_timer  = timer_read32();
    }
}

static void ai_m5_reset(tap_dance_state_t *state, void *user_data) {
    if (!ai_m5_fn_active) {
        return;
    }

    layer_off(FN);
    if (ai_m5_restore_agent && ai_agent_control_active && ai_handshake_active) {
        layer_on(AGENT);
    }
    ai_m5_fn_active     = false;
    ai_m5_restore_agent = false;
}

tap_dance_action_t tap_dance_actions[] = {
    [TD_AGENT_M5] = ACTION_TAP_DANCE_FN_ADVANCED(NULL, ai_m5_finished, ai_m5_reset),
};

void matrix_scan_user(void) {
    if (ai_handshake_active && timer_elapsed32(ai_watchdog_timer) > (uint32_t)ai_watchdog_seconds * 1000U) {
        ai_expire_connection();
    }
    if (ai_unavailable_feedback_active && timer_elapsed32(ai_unavailable_feedback_timer) > 500) {
        ai_unavailable_feedback_active = false;
    }
}

bool rgb_matrix_indicators_advanced_user(uint8_t led_min, uint8_t led_max) {
    if (AI_LED_M5 >= led_min && AI_LED_M5 < led_max) {
        if (ai_agent_control_active) {
            rgb_matrix_set_color(AI_LED_M5, 0, 180, 255);
        } else if (ai_unavailable_feedback_active) {
            rgb_matrix_set_color(AI_LED_M5, 255, 96, 0);
        }
    }

    if (ai_agent_control_active && AI_LED_SLOT_1 >= led_min && AI_LED_SLOT_1 < led_max) {
        switch (ai_slot_states[0]) {
            case 2:
                rgb_matrix_set_color(AI_LED_SLOT_1, 0, 0, 255);
                break;
            case 3:
            case 4:
                rgb_matrix_set_color(AI_LED_SLOT_1, 255, 0, 0);
                break;
            case 5:
                rgb_matrix_set_color(AI_LED_SLOT_1, 255, 96, 0);
                break;
            case 6:
                rgb_matrix_set_color(AI_LED_SLOT_1, 0, 255, 0);
                break;
            default:
                rgb_matrix_set_color(AI_LED_SLOT_1, 0, 0, 0);
                break;
        }
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
        MC_4,    KC_P1,   KC_P2,   KC_P3,
        TD(TD_AGENT_M5), KC_P0,    KC_PDOT, KC_PENT),

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
        KC_NO,   AI_SLOT_1, AI_SLOT_2, AI_SLOT_3,
        TD(TD_AGENT_M5), AI_SLOT_10,   KC_NO,     AI_JUMP),
};

#if defined(ENCODER_MAP_ENABLE)
const uint16_t PROGMEM encoder_map[][NUM_ENCODERS][2] = {
    [BASE]  = {ENCODER_CCW_CW(KC_VOLD, KC_VOLU)},
    [FN]    = {ENCODER_CCW_CW(UG_VALD, UG_VALU)},
    [AGENT] = {ENCODER_CCW_CW(KC_NO, KC_NO)},
};
#endif
// clang-format on
