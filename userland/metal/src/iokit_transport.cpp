// The kernel's GPU driver through its IOKit user client: the requests as struct-method calls whose selector is the
// request's number, and a buffer's memory as the client memory of the type that is its handle. The same as hakios's
// tools/mesa/hakios-drm/hakios.drm.c does for freedreno.
//
// sweet (ios-apollo): on the Mi 10T the driver is SweetGPU (iokit/Kernel/arm/SweetGPU.cpp, xnu 0112/0114/0163), the same
// ABI as hakios's HakiosGPU (both are HackiOS's RedwoodGPU underneath; userland/mesa/sweet-drm talks to it the same
// way). SweetGPU is asked for first, HakiosGPU after it. Xcode's iPhoneOS SDK has no IOKit headers, so the few IOKitLib
// calls are declared here, as userland/gpu-test and sweet-drm do (IOKit.framework is linked as usual).
#include <mach/mach.h>
#include <mach/mach_time.h>

#include <cerrno>
#include <cstdio>

#include "hakios-metal/gpu.hpp"

extern "C" {
typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_connect_t;
typedef struct __CFDictionary* CFMutableDictionaryRef;
typedef const struct __CFDictionary* CFDictionaryRef;
CFMutableDictionaryRef IOServiceMatching(const char* name);
io_service_t IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching);
kern_return_t IOServiceOpen(io_service_t service, task_port_t owningTask, uint32_t type, io_connect_t* connect);
kern_return_t IOServiceClose(io_connect_t connect);
kern_return_t IOObjectRelease(io_object_t object);
kern_return_t IOConnectCallStructMethod(io_connect_t connection, uint32_t selector, const void* inputStruct,
                                        size_t inputStructCnt, void* outputStruct, size_t* outputStructCnt);
kern_return_t IOConnectMapMemory64(io_connect_t connect, uint32_t memoryType, task_port_t intoTask,
                                   mach_vm_address_t* atAddress, mach_vm_size_t* ofSize, uint32_t options);
kern_return_t IOConnectUnmapMemory64(io_connect_t connect, uint32_t memoryType, task_port_t fromTask,
                                     mach_vm_address_t atAddress);
}

namespace hakios::metal {

namespace {

// IOKit/IOReturn.h and IOKit/IOTypes.h, which the SDK does not ship
constexpr uint32_t kMapAnywhere = 0x00000001;
constexpr kern_return_t kNoMemory = kern_return_t(0xe00002bd);
constexpr kern_return_t kBadArgument = kern_return_t(0xe00002c2);
constexpr kern_return_t kUnsupported = kern_return_t(0xe00002c7);
constexpr kern_return_t kNotReady = kern_return_t(0xe00002d8);
constexpr kern_return_t kBusy = kern_return_t(0xe00002d5);
constexpr kern_return_t kTimeout = kern_return_t(0xe00002d6);
constexpr kern_return_t kNotFound = kern_return_t(0xe00002f0);

class KernelGpu : public Transport {
public:
    explicit KernelGpu(io_connect_t c) : c_(c) { mach_timebase_info(&timebase_); }
    ~KernelGpu() override { IOServiceClose(c_); }

    int call(uint32_t request, void* data, size_t size) override {
        size_t returned = size;
        kern_return_t r = IOConnectCallStructMethod(c_, request, data, size, data, &returned);
        switch (r) {
        case KERN_SUCCESS: return 0;
        case kNoMemory: return ENOMEM;
        case kBadArgument: return EINVAL;
        case kTimeout: return ETIMEDOUT;
        case kBusy: return EBUSY;
        case kNotFound: return ENOENT;
        case kUnsupported: return ENOSYS;
        case kNotReady: return EAGAIN;   // sweet: SweetGPU before sweet_gpu.c has the GPU kept on
        default:
            // the kernel's own answer would be lost in a plain EIO: a code no case names is a failure nobody has
            // looked at yet, so it is printed where it happens
            fprintf(stderr, "hakios-metal: the driver's request %u answered %#x\n", request, unsigned(r));
            return EIO;
        }
    }

    void* map(uint32_t handle, uint64_t) override {
        mach_vm_address_t address = 0;
        mach_vm_size_t size = 0;
        // as the driver made the memory: write-combined, the way Linux hands it to freedreno
        if (IOConnectMapMemory64(c_, handle, mach_task_self(), &address, &size, kMapAnywhere) != KERN_SUCCESS) {
            return nullptr;
        }
        return reinterpret_cast<void*>(uintptr_t(address));
    }

    void unmap(uint32_t handle, void* address) override {
        IOConnectUnmapMemory64(c_, handle, mach_task_self(), mach_vm_address_t(uintptr_t(address)));
    }

    int64_t nowNs() override {
        // the driver's deadlines are of mach_continuous_time (hakios.gpu.cpp and SweetGPU.cpp, millisecondsUntil)
        return int64_t(mach_continuous_time() * timebase_.numer / timebase_.denom);
    }

private:
    io_connect_t c_;
    mach_timebase_info_data_t timebase_{};
};

}  // namespace

std::unique_ptr<Transport> openKernelGpu(std::string* why) {
    // (MACH_PORT_NULL: the default main port, kIOMainPortDefault's value)
    const char* name = "SweetGPU";
    io_service_t s = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching(name));
    if (s == 0) {
        name = "HakiosGPU";
        s = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching(name));
    }
    if (s == 0) {
        *why = "no SweetGPU service: the kernel has not kept the GPU on (boot-args sweetgpu=22 sweetgpukeep=1, the "
               "firmware in the ADT: mkadt.py --gmu-fw/--sqe-fw/--zap-mdt)";
        return nullptr;
    }
    io_connect_t c = 0;
    kern_return_t r = IOServiceOpen(s, mach_task_self(), 0, &c);
    IOObjectRelease(s);
    if (r != KERN_SUCCESS) {
        *why = std::string(name) + " would not open: error " + std::to_string(r);
        return nullptr;
    }
    return std::unique_ptr<Transport>(new KernelGpu(c));
}

}  // namespace hakios::metal
