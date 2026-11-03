#ifndef NOTCHMETER_SHIMS_H
#define NOTCHMETER_SHIMS_H

#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

/// Allows or suppresses the Keychain's access dialogs for this process. Wraps SecKeychainSetUserInteractionAllowed,
/// which is deprecated with no replacement for the file-based keychain's per-item access prompt.
void notchmeter_keychain_set_prompts_allowed(bool allowed);

/// Copies matching keychain item while ensuring authentication UI is suppressed (kSecUseAuthenticationUIFail).
OSStatus notchmeter_keychain_copy_matching_suppressed(CFDictionaryRef query, CFTypeRef *result);

#endif
