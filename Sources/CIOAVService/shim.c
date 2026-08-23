#include "include/CIOAVService.h"

#include <dlfcn.h>
#include <stdatomic.h>

typedef CFTypeRef (*create_with_service_fn)(CFAllocatorRef, io_service_t);
typedef IOReturn (*write_i2c_fn)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
typedef IOReturn (*read_i2c_fn)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);

static create_with_service_fn g_create;
static write_i2c_fn g_write;
static read_i2c_fn g_read;
static atomic_bool g_resolved;
static atomic_bool g_ok;

static void resolve(void) {
    if (atomic_load(&g_resolved)) {
        return;
    }

    // RTLD_DEFAULT searches every already-loaded image. IOKit is linked by
    // CoreFoundation's dependents and is always present in a GUI process, so
    // no explicit dlopen of the framework is needed.
    g_create = (create_with_service_fn)dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
    g_write = (write_i2c_fn)dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    g_read = (read_i2c_fn)dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");

    atomic_store(&g_ok, g_create != NULL && g_write != NULL && g_read != NULL);
    atomic_store(&g_resolved, true);
}

bool sb_avservice_available(void) {
    resolve();
    return atomic_load(&g_ok);
}

SBAVServiceRef sb_avservice_create(io_service_t service) {
    resolve();
    if (!atomic_load(&g_ok)) {
        return NULL;
    }
    return (SBAVServiceRef)g_create(kCFAllocatorDefault, service);
}

void sb_avservice_release(SBAVServiceRef service) {
    if (service != NULL) {
        CFRelease((CFTypeRef)service);
    }
}

IOReturn sb_avservice_write_i2c(SBAVServiceRef service,
                                 uint32_t chipAddress,
                                 uint32_t offset,
                                 void *inputBuffer,
                                 uint32_t inputBufferSize) {
    resolve();
    if (!atomic_load(&g_ok)) {
        return kIOReturnUnsupported;
    }
    return g_write((CFTypeRef)service, chipAddress, offset, inputBuffer, inputBufferSize);
}

IOReturn sb_avservice_read_i2c(SBAVServiceRef service,
                                uint32_t chipAddress,
                                uint32_t offset,
                                void *outputBuffer,
                                uint32_t outputBufferSize) {
    resolve();
    if (!atomic_load(&g_ok)) {
        return kIOReturnUnsupported;
    }
    return g_read((CFTypeRef)service, chipAddress, offset, outputBuffer, outputBufferSize);
}
