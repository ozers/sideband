// Bridge to Apple's private IOAVService API (IOKit).
//
// These symbols are not in any public SDK header and are not listed in the
// IOKit.tbd stub the linker sees, so they cannot be linked against directly.
// They are resolved at runtime with dlsym instead, which also means a future
// macOS that drops them degrades into "DDC unavailable" rather than a crash
// on launch.
//
// Consequence: an app using these cannot ship on the Mac App Store.

#ifndef CIOAVSERVICE_H
#define CIOAVSERVICE_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

/// Opaque handle to an IOAVService.
///
/// Deliberately not `CFTypeRef`: that maps into Swift as `Unmanaged<AnyObject>`,
/// which cannot cross an actor boundary and drags ownership questions into
/// every call site. A void pointer plus an explicit release keeps the lifetime
/// obvious on the Swift side.
typedef void *KDNAVServiceRef;

/// Resolves the private symbols. Returns true once they are all available.
/// Safe to call repeatedly; the lookup happens only on the first call.
bool kdn_avservice_available(void);

/// Wraps IOAVServiceCreateWithService. Returns NULL if unavailable.
/// Caller owns the result and must pass it to kdn_avservice_release.
KDNAVServiceRef kdn_avservice_create(io_service_t service);

/// Releases a handle returned by kdn_avservice_create. NULL is ignored.
void kdn_avservice_release(KDNAVServiceRef service);

/// Wraps IOAVServiceWriteI2C. Returns kIOReturnUnsupported if unavailable.
IOReturn kdn_avservice_write_i2c(KDNAVServiceRef service,
                                 uint32_t chipAddress,
                                 uint32_t offset,
                                 void *inputBuffer,
                                 uint32_t inputBufferSize);

/// Wraps IOAVServiceReadI2C. Returns kIOReturnUnsupported if unavailable.
/// Kept even though this display never answers reads: other displays do, and
/// the capability probe needs to be able to try.
IOReturn kdn_avservice_read_i2c(KDNAVServiceRef service,
                                uint32_t chipAddress,
                                uint32_t offset,
                                void *outputBuffer,
                                uint32_t outputBufferSize);

#endif /* CIOAVSERVICE_H */
