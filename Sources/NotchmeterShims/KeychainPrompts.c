#include "NotchmeterShims.h"

#include <Security/Security.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
void notchmeter_keychain_set_prompts_allowed(bool allowed) {
    SecKeychainSetUserInteractionAllowed(allowed);
}

OSStatus notchmeter_keychain_copy_matching_suppressed(CFDictionaryRef query, CFTypeRef *result) {
    CFMutableDictionaryRef mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    if (!mutable) {
        return SecItemCopyMatching(query, result);
    }
    CFDictionarySetValue(mutable, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
    OSStatus status = SecItemCopyMatching(mutable, result);
    CFRelease(mutable);
    return status;
}
#pragma clang diagnostic pop
