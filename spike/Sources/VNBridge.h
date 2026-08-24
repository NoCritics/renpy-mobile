// THROWAWAY SPIKE CODE — not the eventual design.
//
// A mailbox between Swift and Python, deliberately owned by C rather than by either
// side. The point being tested: this lives in the process BSS, so it survives a Python
// interpreter reset. Our game-switching mechanism raises UtterRestartException, which
// unwinds and re-enters the engine and would destroy any Python-side state.
//
// Python reaches these symbols with ctypes.CDLL(None) — no extension module, no pyobjus.
// Whether that actually works on iOS with static linking is one of the things this
// spike exists to find out.

#ifndef VNBRIDGE_H
#define VNBRIDGE_H

#include <stdint.h>

#define VNBRIDGE_QUEUE_LEN 16
#define VNBRIDGE_PAYLOAD_LEN 512

// Returns a known constant. The cheapest possible answer to "can Python see C symbols
// linked into the main executable at all?"
int vnbridge_ping(void);

// Swift -> Python. Returns 1 on success, 0 if the queue is full.
int vnbridge_post(int32_t command, const char *payload);

// Python -> drains one command. Returns 1 if one was dequeued, 0 if empty.
int vnbridge_poll(int32_t *out_command, char *out_payload, int32_t out_size);

// Clears the queue. Must be called when the engine restarts into a different game, or
// commands aimed at the previous game leak into the next one.
void vnbridge_reset(void);

// How many commands have ever been posted. Lets the on-device screen show that the
// counter survived a restart, which is the property that matters.
int32_t vnbridge_post_count(void);

#endif
