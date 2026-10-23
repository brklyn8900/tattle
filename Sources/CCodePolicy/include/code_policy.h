// Who may hold a capture descriptor beyond "its code satisfies the requirement" (ADR-0003):
// code that no other process of the same user can steer. Shared by the broker, which applies
// it to each caller, and the app, which applies it to itself before installing the broker,
// so the two cannot disagree about what counts.

#ifndef TATTLE_CODE_POLICY_H
#define TATTLE_CODE_POLICY_H

#include <Security/Security.h>

typedef enum {
    TATTLE_HARDENING_OK = 0,
    TATTLE_HARDENING_UNREADABLE,
    TATTLE_HARDENING_NOT_VALID,
    TATTLE_HARDENING_NO_RUNTIME,
    TATTLE_HARDENING_DEBUGGED,
    TATTLE_HARDENING_DEBUGGABLE,
    TATTLE_HARDENING_INJECTABLE,
} tattle_hardening;

// Judges running code from the kernel's view of it and its entitlements: valid, under the
// hardened runtime, not debugged, and without get-task-allow or an entitlement that lets
// DYLD_* variables or unsigned libraries in.
tattle_hardening tattle_code_hardening(SecCodeRef code);

// A few words for a log line.
const char *tattle_hardening_text(tattle_hardening verdict);

#endif
