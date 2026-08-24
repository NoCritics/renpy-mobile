// THROWAWAY SPIKE CODE — not the eventual design.

#include "VNBridge.h"

#include <string.h>

// __attribute__((used)) and default visibility are both load-bearing, and this is one of
// the specific failure modes the consultation flagged: with -dead_strip, a C symbol that
// no native code references can be removed by the linker entirely. Every one of these is
// called only from Python via ctypes, so as far as the linker can see they are dead.
// If they are stripped, ctypes finds nothing and the failure looks like "the bridge
// doesn't work" rather than "the symbol was removed".
#define VNBRIDGE_EXPORT __attribute__((used, visibility("default")))

typedef struct {
    int32_t command;
    char payload[VNBRIDGE_PAYLOAD_LEN];
} VNBridgeSlot;

// Deliberately static storage: this is the state that must outlive a Python interpreter
// reset. Zero-initialized in BSS.
static VNBridgeSlot g_queue[VNBRIDGE_QUEUE_LEN];
static int32_t g_head = 0;
static int32_t g_tail = 0;
static int32_t g_post_count = 0;

VNBRIDGE_EXPORT int vnbridge_ping(void) {
    return 0x5643;  // "VC" — an arbitrary constant Python checks for.
}

VNBRIDGE_EXPORT int vnbridge_post(int32_t command, const char *payload) {
    int32_t next = (g_tail + 1) % VNBRIDGE_QUEUE_LEN;
    if (next == g_head) {
        return 0;  // Full. Dropping is correct here: a stale command is worse than none.
    }

    g_queue[g_tail].command = command;
    if (payload != 0) {
        strncpy(g_queue[g_tail].payload, payload, VNBRIDGE_PAYLOAD_LEN - 1);
        g_queue[g_tail].payload[VNBRIDGE_PAYLOAD_LEN - 1] = '\0';
    } else {
        g_queue[g_tail].payload[0] = '\0';
    }

    g_tail = next;
    g_post_count++;
    return 1;
}

VNBRIDGE_EXPORT int vnbridge_poll(int32_t *out_command, char *out_payload, int32_t out_size) {
    if (g_head == g_tail) {
        return 0;
    }

    if (out_command != 0) {
        *out_command = g_queue[g_head].command;
    }
    if (out_payload != 0 && out_size > 0) {
        strncpy(out_payload, g_queue[g_head].payload, (size_t)out_size - 1);
        out_payload[out_size - 1] = '\0';
    }

    g_head = (g_head + 1) % VNBRIDGE_QUEUE_LEN;
    return 1;
}

VNBRIDGE_EXPORT void vnbridge_reset(void) {
    g_head = 0;
    g_tail = 0;
    memset(g_queue, 0, sizeof(g_queue));
}

VNBRIDGE_EXPORT int32_t vnbridge_post_count(void) {
    return g_post_count;
}
