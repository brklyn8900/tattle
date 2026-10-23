#include "code_policy.h"

// Present and not explicitly false counts as granted.
static bool has_entitlement(CFDictionaryRef entitlements, CFStringRef key) {
    if (entitlements == NULL) return false;
    CFTypeRef value = CFDictionaryGetValue(entitlements, key);
    return value != NULL && !(CFGetTypeID(value) == CFBooleanGetTypeID() && !CFBooleanGetValue(value));
}

tattle_hardening tattle_code_hardening(SecCodeRef code) {
    CFDictionaryRef info = NULL;
    SecCSFlags flags = kSecCSSigningInformation | kSecCSRequirementInformation | kSecCSDynamicInformation;
    if (SecCodeCopySigningInformation((SecStaticCodeRef)code, flags, &info) != errSecSuccess || info == NULL) {
        return TATTLE_HARDENING_UNREADABLE;
    }
    // kSecCodeInfoStatus is the kernel's code-signing state of the running process. Its
    // hardened-runtime bit sits where the signature flag kSecCodeSignatureRuntime does.
    uint32_t status = 0;
    CFNumberRef number = CFDictionaryGetValue(info, kSecCodeInfoStatus);
    CFDictionaryRef entitlements = CFDictionaryGetValue(info, kSecCodeInfoEntitlementsDict);
    tattle_hardening verdict = TATTLE_HARDENING_OK;
    if (number == NULL || !CFNumberGetValue(number, kCFNumberSInt32Type, &status)) {
        verdict = TATTLE_HARDENING_UNREADABLE;
    } else if (!(status & kSecCodeStatusValid)) {
        verdict = TATTLE_HARDENING_NOT_VALID;
    } else if (!(status & kSecCodeSignatureRuntime)) {
        verdict = TATTLE_HARDENING_NO_RUNTIME;
    } else if (status & kSecCodeStatusDebugged) {
        verdict = TATTLE_HARDENING_DEBUGGED;
    } else if (has_entitlement(entitlements, CFSTR("com.apple.security.get-task-allow"))) {
        verdict = TATTLE_HARDENING_DEBUGGABLE;
    } else if (has_entitlement(entitlements, CFSTR("com.apple.security.cs.allow-dyld-environment-variables"))
               || has_entitlement(entitlements, CFSTR("com.apple.security.cs.disable-library-validation"))) {
        // Neither shows in the status word, so the entitlements are read directly.
        verdict = TATTLE_HARDENING_INJECTABLE;
    }
    CFRelease(info);
    return verdict;
}

const char *tattle_hardening_text(tattle_hardening verdict) {
    switch (verdict) {
    case TATTLE_HARDENING_OK: return "hardened";
    case TATTLE_HARDENING_UNREADABLE: return "signing state unreadable";
    case TATTLE_HARDENING_NOT_VALID: return "code signature not valid";
    case TATTLE_HARDENING_NO_RUNTIME: return "no hardened runtime";
    case TATTLE_HARDENING_DEBUGGED: return "debugged";
    case TATTLE_HARDENING_DEBUGGABLE: return "get-task-allow";
    case TATTLE_HARDENING_INJECTABLE: return "an entitlement that allows injection";
    }
    return "unknown";
}
