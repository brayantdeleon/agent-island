// Copyright 2026 Brayant De Leon
// SPDX-License-Identifier: MIT

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDManager.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    K0_VENDOR_ID       = 0x3434,
    K0_PRODUCT_ID      = 0x0A06,
    K0_USAGE_PAGE      = 0xFF60,
    K0_USAGE           = 0x61,
    AI_COMMAND_FAMILY  = 0xAC,
    AI_MAGIC_0         = 0x41,
    AI_MAGIC_1         = 0x49,
    AI_PROTOCOL_MAJOR  = 0x01,
    AI_RESPONSE_FLAG   = 0x01,
    AI_REPORT_SIZE     = 32,
    AI_PAYLOAD_MAX     = 22,
    AI_WATCHDOG_SECONDS = 6,
};

enum {
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

typedef struct {
    IOHIDManagerRef manager;
    IOHIDDeviceRef  device;
    uint8_t         input_report[AI_REPORT_SIZE];
    uint8_t         nonce[8];
    uint16_t        sequence;
    bool            stock_response_seen;
    bool            capabilities_seen;
    bool            layer_enabled_seen;
    bool            selection_seen;
    bool            action_seen;
    bool            watchdog_seen;
} probe_context_t;

static uint8_t crc8_atm(const uint8_t *data, size_t length) {
    uint8_t crc = 0;
    for (size_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (uint8_t bit = 0; bit < 8; ++bit) {
            crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07) : (uint8_t)(crc << 1);
        }
    }
    return crc;
}

static uint16_t read_u16(const uint8_t *data) {
    return (uint16_t)data[0] | ((uint16_t)data[1] << 8);
}

static uint32_t read_u32(const uint8_t *data) {
    return (uint32_t)data[0] |
           ((uint32_t)data[1] << 8) |
           ((uint32_t)data[2] << 16) |
           ((uint32_t)data[3] << 24);
}

static void write_u16(uint8_t *data, uint16_t value) {
    data[0] = value & 0xFF;
    data[1] = value >> 8;
}

static void print_packet(const char *direction, const uint8_t *packet) {
    printf("%s", direction);
    for (size_t i = 0; i < AI_REPORT_SIZE; ++i) {
        printf("%s%02x", i == 0 ? " " : "", packet[i]);
    }
    printf("\n");
}

static bool packet_is_valid(const uint8_t *packet, CFIndex length) {
    return length == AI_REPORT_SIZE &&
           packet[0] == AI_COMMAND_FAMILY &&
           packet[1] == AI_MAGIC_0 &&
           packet[2] == AI_MAGIC_1 &&
           packet[3] == AI_PROTOCOL_MAJOR &&
           packet[8] <= AI_PAYLOAD_MAX &&
           crc8_atm(packet, AI_REPORT_SIZE - 1) == packet[AI_REPORT_SIZE - 1];
}

static bool send_raw_report(probe_context_t *context, const uint8_t *report) {
    IOReturn result = IOHIDDeviceSetReport(
        context->device,
        kIOHIDReportTypeOutput,
        0,
        report,
        AI_REPORT_SIZE
    );
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDDeviceSetReport failed: 0x%08x\n", result);
        return false;
    }
    print_packet("host -> keyboard", report);
    return true;
}

static bool send_packet(
    probe_context_t *context,
    uint8_t type,
    uint8_t flags,
    uint16_t sequence,
    const uint8_t *payload,
    uint8_t payload_length
) {
    uint8_t packet[AI_REPORT_SIZE] = {0};
    packet[0] = AI_COMMAND_FAMILY;
    packet[1] = AI_MAGIC_0;
    packet[2] = AI_MAGIC_1;
    packet[3] = AI_PROTOCOL_MAJOR;
    packet[4] = type;
    packet[5] = flags;
    write_u16(&packet[6], sequence);
    packet[8] = payload_length;
    if (payload_length > 0) {
        memcpy(&packet[9], payload, payload_length);
    }
    packet[AI_REPORT_SIZE - 1] = crc8_atm(packet, AI_REPORT_SIZE - 1);
    return send_raw_report(context, packet);
}

static void send_selection_ack(probe_context_t *context, const uint8_t *request) {
    uint8_t payload[22] = {0};
    memcpy(payload, context->nonce, sizeof(context->nonce));
    payload[8]  = request[17];
    payload[9]  = 0;
    payload[10] = 1;
    payload[11] = 0;
    for (uint8_t i = 0; i < 8; ++i) {
        payload[12 + i] = (uint8_t)(0xA1 + i);
    }
    payload[20] = 0x07;
    payload[21] = 30;
    send_packet(context, AI_MSG_SELECTION_ACK, AI_RESPONSE_FLAG, read_u16(&request[6]), payload, sizeof(payload));
}

static void send_action_result(probe_context_t *context, const uint8_t *request) {
    uint8_t payload[11] = {0};
    memcpy(payload, context->nonce, sizeof(context->nonce));
    payload[8]  = request[17];
    payload[9]  = request[18];
    payload[10] = 0;
    send_packet(context, AI_MSG_ACTION_RESULT, AI_RESPONSE_FLAG, read_u16(&request[6]), payload, sizeof(payload));
}

static void input_report_callback(
    void *context_pointer,
    IOReturn result,
    void *sender,
    IOHIDReportType report_type,
    uint32_t report_id,
    uint8_t *report,
    CFIndex report_length
) {
    (void)sender;
    (void)report_type;
    (void)report_id;
    probe_context_t *context = context_pointer;

    if (result != kIOReturnSuccess) {
        fprintf(stderr, "Input report callback failed: 0x%08x\n", result);
        return;
    }

    if (report_length == AI_REPORT_SIZE && report[0] == 0xA0) {
        context->stock_response_seen = true;
        printf("Stock Keychron protocol response: version=%u command-set=%u\n", report[1], report[3]);
        print_packet("keyboard -> host", report);
        return;
    }

    if (!packet_is_valid(report, report_length)) {
        return;
    }

    print_packet("keyboard -> host", report);
    const uint8_t *payload = &report[9];
    switch (report[4]) {
        case AI_MSG_CAPABILITIES:
            if (report[8] >= 18 && memcmp(payload, context->nonce, sizeof(context->nonce)) == 0) {
                context->capabilities_seen = true;
                printf(
                    "Handshake: protocol=1.%u slots=%u transport=%u watchdog=%us build=0x%08x\n",
                    payload[8],
                    payload[9],
                    payload[12],
                    payload[13],
                    read_u32(&payload[14])
                );
            }
            break;
        case AI_MSG_SLOT_SELECTED:
            if (report[8] >= 11 && memcmp(payload, context->nonce, sizeof(context->nonce)) == 0) {
                context->selection_seen = true;
                printf("Selection intent: slot=%u generation=%u (diagnostic ACK only)\n", payload[8] + 1, read_u16(&payload[9]));
                send_selection_ack(context, report);
            }
            break;
        case AI_MSG_ACTION_INVOKED:
            if (report[8] >= 18 && memcmp(payload, context->nonce, sizeof(context->nonce)) == 0) {
                context->action_seen = true;
                printf("Action intent: slot=%u action=%u (logged; no agent action dispatched)\n", payload[8] + 1, payload[9]);
                send_action_result(context, report);
            }
            break;
        case AI_MSG_LAYER_CHANGED:
            if (report[8] >= 10 && memcmp(payload, context->nonce, sizeof(context->nonce)) == 0) {
                printf("Agent Control layer: enabled=%u reason=%u\n", payload[8], payload[9]);
                if (payload[8] == 1) {
                    context->layer_enabled_seen = true;
                }
                if (payload[8] == 0 && payload[9] == 1) {
                    context->watchdog_seen = true;
                }
            }
            break;
    }
}

static void dictionary_set_number(CFMutableDictionaryRef dictionary, CFStringRef key, int value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    CFDictionarySetValue(dictionary, key, number);
    CFRelease(number);
}

static bool open_device(probe_context_t *context) {
    context->manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!context->manager) {
        fprintf(stderr, "Unable to create IOHIDManager.\n");
        return false;
    }

    CFMutableDictionaryRef matching = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    dictionary_set_number(matching, CFSTR(kIOHIDVendorIDKey), K0_VENDOR_ID);
    dictionary_set_number(matching, CFSTR(kIOHIDProductIDKey), K0_PRODUCT_ID);
    dictionary_set_number(matching, CFSTR(kIOHIDPrimaryUsagePageKey), K0_USAGE_PAGE);
    dictionary_set_number(matching, CFSTR(kIOHIDPrimaryUsageKey), K0_USAGE);
    IOHIDManagerSetDeviceMatching(context->manager, matching);
    CFRelease(matching);

    IOReturn result = IOHIDManagerOpen(context->manager, kIOHIDOptionsTypeNone);
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDManagerOpen failed: 0x%08x\n", result);
        return false;
    }

    CFSetRef devices = IOHIDManagerCopyDevices(context->manager);
    if (!devices || CFSetGetCount(devices) != 1) {
        CFIndex count = devices ? CFSetGetCount(devices) : 0;
        fprintf(stderr, "Expected exactly one K0 Max Raw HID interface; found %ld.\n", (long)count);
        if (devices) {
            CFRelease(devices);
        }
        return false;
    }

    const void *device_value = NULL;
    CFSetGetValues(devices, &device_value);
    context->device = (IOHIDDeviceRef)device_value;
    CFRetain(context->device);
    CFRelease(devices);

    result = IOHIDDeviceOpen(context->device, kIOHIDOptionsTypeNone);
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDDeviceOpen failed: 0x%08x\n", result);
        return false;
    }

    IOHIDDeviceRegisterInputReportCallback(
        context->device,
        context->input_report,
        sizeof(context->input_report),
        input_report_callback,
        context
    );
    IOHIDDeviceScheduleWithRunLoop(context->device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    return true;
}

static void close_device(probe_context_t *context) {
    if (context->device) {
        IOHIDDeviceUnscheduleFromRunLoop(context->device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOHIDDeviceClose(context->device, kIOHIDOptionsTypeNone);
        CFRelease(context->device);
    }
    if (context->manager) {
        IOHIDManagerClose(context->manager, kIOHIDOptionsTypeNone);
        CFRelease(context->manager);
    }
}

static void run_loop_for(CFTimeInterval seconds) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + seconds;
    while (CFAbsoluteTimeGetCurrent() < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
}

static int run_self_test(void) {
    uint8_t hello[AI_REPORT_SIZE] = {
        0xAC, 0x41, 0x49, 0x01, 0x01, 0x00, 0x01, 0x00,
        0x0C, 0x00, 0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45,
        0x23, 0x01, 0x06, 0x1F, 0x00,
    };
    hello[AI_REPORT_SIZE - 1] = crc8_atm(hello, AI_REPORT_SIZE - 1);

    if (hello[AI_REPORT_SIZE - 1] != 0x97 || !packet_is_valid(hello, sizeof(hello))) {
        fprintf(stderr, "CRC/golden HELLO self-test failed (got 0x%02x, expected 0x97).\n", hello[AI_REPORT_SIZE - 1]);
        return 1;
    }

    hello[10] ^= 0x01;
    if (packet_is_valid(hello, sizeof(hello))) {
        fprintf(stderr, "Malformed-packet self-test failed.\n");
        return 1;
    }

    printf("Protocol self-test passed.\n");
    printf("Golden HELLO CRC-8/ATM: 0x97\n");
    return 0;
}

static int identify_stock_firmware(probe_context_t *context) {
    uint8_t report[AI_REPORT_SIZE] = {0};
    report[0] = 0xA0;
    if (!send_raw_report(context, report)) {
        return 1;
    }
    run_loop_for(2.0);
    if (!context->stock_response_seen) {
        fprintf(stderr, "No stock Keychron protocol response received.\n");
        return 1;
    }
    return 0;
}

static bool send_hello(probe_context_t *context) {
    uint8_t payload[12] = {0};
    payload[0] = 0;
    memcpy(&payload[1], context->nonce, sizeof(context->nonce));
    payload[9]  = AI_WATCHDOG_SECONDS;
    payload[10] = 0x1F;
    payload[11] = 0;
    return send_packet(context, AI_MSG_HELLO, 0, context->sequence++, payload, sizeof(payload));
}

static bool send_snapshot(probe_context_t *context) {
    uint8_t payload[21] = {0};
    memcpy(payload, context->nonce, sizeof(context->nonce));
    payload[8]  = 1;
    payload[9]  = 0;
    payload[10] = 0;
    payload[11] = 2;
    return send_packet(context, AI_MSG_STATE_SNAPSHOT, 0, context->sequence++, payload, sizeof(payload));
}

static bool send_heartbeat(probe_context_t *context) {
    return send_packet(context, AI_MSG_HEARTBEAT, 0, context->sequence++, context->nonce, sizeof(context->nonce));
}

static int exercise_diagnostic_firmware(probe_context_t *context, int active_seconds) {
    static const uint8_t diagnostic_nonce[8] = {0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01};
    memcpy(context->nonce, diagnostic_nonce, sizeof(context->nonce));
    context->sequence = 1;

    if (!send_hello(context)) {
        return 1;
    }
    run_loop_for(1.0);
    if (!context->capabilities_seen) {
        fprintf(stderr, "No compatible Agent Island capabilities response received.\n");
        return 1;
    }
    if (!send_snapshot(context)) {
        return 1;
    }

    printf("\nManual input window (%d seconds):\n", active_seconds);
    printf("  1. Tap M5. M5 should turn cyan and key 1 should turn blue.\n");
    printf("  2. Press 1, then press Enter. The probe only logs and acknowledges them.\n");
    printf("  3. Do not use + or - with a real agent; this probe never dispatches approvals.\n\n");

    CFAbsoluteTime deadline       = CFAbsoluteTimeGetCurrent() + active_seconds;
    CFAbsoluteTime next_heartbeat = CFAbsoluteTimeGetCurrent() + 1.5;
    while (CFAbsoluteTimeGetCurrent() < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        if (CFAbsoluteTimeGetCurrent() >= next_heartbeat) {
            if (!send_heartbeat(context)) {
                return 1;
            }
            next_heartbeat += 2.0;
        }
    }

    printf("Heartbeat stopped. Waiting 8 seconds for the firmware watchdog...\n");
    run_loop_for(8.0);

    bool complete = context->capabilities_seen &&
                    context->layer_enabled_seen &&
                    context->selection_seen &&
                    context->action_seen &&
                    context->watchdog_seen;
    printf(
        "Evidence: handshake=%s layer=%s selection=%s action=%s watchdog=%s\n",
        context->capabilities_seen ? "yes" : "no",
        context->layer_enabled_seen ? "yes" : "no",
        context->selection_seen ? "yes" : "no",
        context->action_seen ? "yes" : "no",
        context->watchdog_seen ? "yes" : "no"
    );
    if (!complete) {
        fprintf(stderr, "Diagnostic exercise incomplete.\n");
        return 2;
    }
    return 0;
}

static void print_usage(const char *program) {
    fprintf(
        stderr,
        "Usage:\n"
        "  %s --self-test\n"
        "  %s --identify-stock\n"
        "  %s --exercise [active-seconds]\n",
        program,
        program,
        program
    );
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
        return run_self_test();
    }

    bool identify = argc == 2 && strcmp(argv[1], "--identify-stock") == 0;
    bool exercise = (argc == 2 || argc == 3) && strcmp(argv[1], "--exercise") == 0;
    if (!identify && !exercise) {
        print_usage(argv[0]);
        return 64;
    }

    int active_seconds = 30;
    if (exercise && argc == 3) {
        active_seconds = atoi(argv[2]);
        if (active_seconds < 5 || active_seconds > 300) {
            fprintf(stderr, "active-seconds must be between 5 and 300.\n");
            return 64;
        }
    }

    probe_context_t context = {0};
    if (!open_device(&context)) {
        close_device(&context);
        return 1;
    }

    int result = identify ? identify_stock_firmware(&context) : exercise_diagnostic_firmware(&context, active_seconds);
    close_device(&context);
    return result;
}
