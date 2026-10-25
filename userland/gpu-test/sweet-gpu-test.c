/*
 * sweet-gpu-test: a program's first use of the GPU through SweetGPU
 * (iokit/Kernel/arm/SweetGPU.cpp, the msm DRM interface of Mesa's freedreno).
 *
 *   sweet-gpu-test [submissions]
 *
 * Waits up to 3 minutes for the service (launchd starts this at boot, before
 * sweet_gpu.c has brought the GPU up and offered it), opens it, asks the parameters freedreno asks first, makes a
 * command buffer and a target buffer, maps both, writes CP_MEM_WRITE packets
 * (one per submission) into the command buffer, submits, waits for each fence,
 * and checks every word the GPU wrote. Prints to stdout: launchd points it at
 * /dev/null, which the kernel copies into its console log (read by
 * tools/sweet-log-pull.sh) for the programs named in boot-arg sweetnull, e.g.
 * sweetnull=backboardd,SpringBoard,sweet-gpu-test (patch 0048). Exit 0 when
 * every check passes.
 *
 * The iOS SDK has no IOKit headers, so the few IOKitLib calls used are
 * declared here (IOKit.framework is linked as usual).
 */
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_connect_t;
typedef struct __CFDictionary *CFMutableDictionaryRef;
typedef const struct __CFDictionary *CFDictionaryRef;
extern CFMutableDictionaryRef IOServiceMatching(const char *name);
extern io_service_t IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching);
extern kern_return_t IOServiceOpen(io_service_t service, task_port_t owningTask, uint32_t type, io_connect_t *connect);
extern kern_return_t IOServiceClose(io_connect_t connect);
extern kern_return_t IOObjectRelease(io_object_t object);
extern kern_return_t IOConnectCallStructMethod(io_connect_t connection, uint32_t selector, const void *inputStruct,
    size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt);
extern kern_return_t IOConnectMapMemory64(io_connect_t connect, uint32_t memoryType, task_port_t intoTask,
    mach_vm_address_t *atAddress, mach_vm_size_t *ofSize, uint32_t options);
#define kIOMapAnywhere 0x00000001

/* msm_drm.h (Linux), as SweetGPU.cpp has them */
#define MSM_GET_PARAM           0x40
#define MSM_GEM_NEW             0x42
#define MSM_GEM_INFO            0x43
#define MSM_GEM_SUBMIT          0x46
#define MSM_WAIT_FENCE          0x47
#define DRM_GEM_CLOSE           0x09
#define MSM_PIPE_3D0            0x01
#define MSM_PARAM_GPU_ID        0x01
#define MSM_PARAM_GMEM_SIZE     0x02
#define MSM_PARAM_CHIP_ID       0x03
#define MSM_PARAM_MAX_FREQ      0x04
#define MSM_INFO_GET_IOVA       1
#define MSM_BO_WC               0x00020000
#define MSM_SUBMIT_CMD_BUF      1
#define MSM_SUBMIT_BO_READ      0x0001
#define MSM_SUBMIT_BO_WRITE     0x0002

struct msm_timespec { int64_t seconds, nanoseconds; };
struct msm_param { uint32_t pipe, param; uint64_t value; uint32_t len, pad; };
struct msm_gem_new { uint64_t size; uint32_t flags, handle; };
struct msm_gem_info { uint32_t handle, info; uint64_t value; uint32_t len, pad; };
struct msm_gem_submit_cmd { uint32_t type, submit_idx, submit_offset, size, pad, nr_relocs; uint64_t relocs; };
struct msm_gem_submit_bo { uint32_t flags, handle; uint64_t presumed; };
struct msm_gem_submit {
	uint32_t flags, fence, nr_bos, nr_cmds;
	uint64_t bos, cmds;
	int32_t fence_fd;
	uint32_t queueid;
	uint64_t in_syncobjs, out_syncobjs;
	uint32_t nr_in_syncobjs, nr_out_syncobjs, syncobj_stride, pad;
};
struct msm_wait_fence { uint32_t fence, flags; struct msm_timespec timeout; uint32_t queueid; };
struct drm_gem_close { uint32_t handle, pad; };

#define CP_MEM_WRITE            0x3d

static io_connect_t gpu;

static kern_return_t
call(uint32_t selector, void *data, size_t size)
{
	size_t back = size;
	return IOConnectCallStructMethod(gpu, selector, data, size, data, &back);
}

static uint32_t
parity(uint32_t v)
{
	return (0x9669u >> (0xfu & (v ^ (v >> 4) ^ (v >> 8) ^ (v >> 12) ^ (v >> 16) ^ (v >> 20) ^ (v >> 24) ^ (v >> 28)))) & 1u;
}

static uint32_t
pkt7(uint32_t op, uint32_t words)
{
	return (7u << 28) | words | (parity(words) << 15) | (op << 16) | (parity(op) << 23);
}

/* nanoseconds of the clock msm's timeouts are on (the kernel's mach_continuous_time) */
static uint64_t
now_ns(void)
{
	static mach_timebase_info_data_t tb;
	if (tb.denom == 0)
		mach_timebase_info(&tb);
	return mach_continuous_time() * tb.numer / tb.denom;
}

struct buffer {
	uint32_t handle;
	uint64_t iova;
	volatile uint32_t *cpu;
	mach_vm_size_t size;
};

static int
buffer_new(struct buffer *b, uint64_t size, const char *what)
{
	struct msm_gem_new n = { .size = size, .flags = MSM_BO_WC };
	struct msm_gem_info info = { .info = MSM_INFO_GET_IOVA };
	mach_vm_address_t at = 0;
	kern_return_t kr;

	if ((kr = call(MSM_GEM_NEW, &n, sizeof(n))) != KERN_SUCCESS) {
		printf("sweet-gpu-test: GEM_NEW %s (%llu bytes) failed: %#x\n", what, (unsigned long long)size, kr);
		return -1;
	}
	b->handle = n.handle;
	info.handle = n.handle;
	if ((kr = call(MSM_GEM_INFO, &info, sizeof(info))) != KERN_SUCCESS) {
		printf("sweet-gpu-test: GEM_INFO %s failed: %#x\n", what, kr);
		return -1;
	}
	b->iova = info.value;
	if ((kr = IOConnectMapMemory64(gpu, n.handle, mach_task_self(), &at, &b->size, kIOMapAnywhere)) != KERN_SUCCESS) {
		printf("sweet-gpu-test: mapping %s failed: %#x\n", what, kr);
		return -1;
	}
	b->cpu = (volatile uint32_t *)(uintptr_t)at;
	printf("sweet-gpu-test: %s: handle %u, GPU %#llx, mapped at %p (%llu bytes)\n", what, b->handle,
	    (unsigned long long)b->iova, (void *)(uintptr_t)at, (unsigned long long)b->size);
	return 0;
}

int
main(int argc, char **argv)
{
	unsigned submissions = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 0) : 64;
	struct msm_param p = { .pipe = MSM_PIPE_3D0 };
	struct buffer cmd, target;
	uint64_t chip = 0, gpu_id = 0, gmem = 0, freq = 0, began, took_ns = 0;
	unsigned wrong = 0;
	io_service_t service;
	kern_return_t kr;

	if (submissions == 0 || submissions > 1000)
		submissions = 64;
	setvbuf(stdout, NULL, _IOLBF, 0);
	printf("sweet-gpu-test: waiting for the SweetGPU service\n");
	for (unsigned waited = 0; (service = IOServiceGetMatchingService(0, IOServiceMatching("SweetGPU"))) == 0; waited += 2) {
		if (waited >= 180) {
			printf("sweet-gpu-test: no SweetGPU service after 3 minutes (boot with sweetgpu=22 sweetgpukeep=1)\n");
			return 1;
		}
		sleep(2);
	}
	kr = IOServiceOpen(service, mach_task_self(), 0, &gpu);
	IOObjectRelease(service);
	if (kr != KERN_SUCCESS) {
		printf("sweet-gpu-test: IOServiceOpen failed: %#x\n", kr);
		return 1;
	}

	p.param = MSM_PARAM_GPU_ID;
	if (call(MSM_GET_PARAM, &p, sizeof(p)) == KERN_SUCCESS)
		gpu_id = p.value;
	p.param = MSM_PARAM_CHIP_ID;
	if (call(MSM_GET_PARAM, &p, sizeof(p)) == KERN_SUCCESS)
		chip = p.value;
	p.param = MSM_PARAM_GMEM_SIZE;
	if (call(MSM_GET_PARAM, &p, sizeof(p)) == KERN_SUCCESS)
		gmem = p.value;
	p.param = MSM_PARAM_MAX_FREQ;
	if (call(MSM_GET_PARAM, &p, sizeof(p)) == KERN_SUCCESS)
		freq = p.value;
	printf("sweet-gpu-test: Adreno %llu, chip id %#llx, GMEM %llu KiB, %llu MHz\n", (unsigned long long)gpu_id,
	    (unsigned long long)chip, (unsigned long long)(gmem >> 10), (unsigned long long)(freq / 1000000));

	if (buffer_new(&cmd, 16384, "command buffer") || buffer_new(&target, 16384, "target"))
		return 1;
	for (unsigned i = 0; i < submissions; i++)
		target.cpu[i] = 0;

	for (unsigned i = 0; i < submissions; i++) {
		struct msm_gem_submit_bo bos[2] = {
			{ .flags = MSM_SUBMIT_BO_READ, .handle = cmd.handle },
			{ .flags = MSM_SUBMIT_BO_WRITE, .handle = target.handle },
		};
		struct msm_gem_submit_cmd cmds[1] = {
			{ .type = MSM_SUBMIT_CMD_BUF, .submit_idx = 0, .submit_offset = 16u * i, .size = 16 },
		};
		struct msm_gem_submit s = {
			.flags = MSM_PIPE_3D0, .nr_bos = 2, .nr_cmds = 1,
			.bos = (uint64_t)(uintptr_t)bos, .cmds = (uint64_t)(uintptr_t)cmds,
		};
		uint64_t to = target.iova + 4u * i, deadline;
		struct msm_wait_fence w = { 0 };

		cmd.cpu[4 * i + 0] = pkt7(CP_MEM_WRITE, 3);
		cmd.cpu[4 * i + 1] = (uint32_t)to;
		cmd.cpu[4 * i + 2] = (uint32_t)(to >> 32);
		cmd.cpu[4 * i + 3] = 0xc0de0000u | i;
		began = now_ns();
		if ((kr = call(MSM_GEM_SUBMIT, &s, sizeof(s))) != KERN_SUCCESS) {
			printf("sweet-gpu-test: submission %u failed: %#x\n", i, kr);
			return 1;
		}
		/* 2 s: SweetGPU reports the core's state only for waits of a second or more */
		deadline = now_ns() + 2000000000ull;
		w.fence = s.fence;
		w.timeout.seconds = (int64_t)(deadline / 1000000000ull);
		w.timeout.nanoseconds = (int64_t)(deadline % 1000000000ull);
		if ((kr = call(MSM_WAIT_FENCE, &w, sizeof(w))) != KERN_SUCCESS) {
			printf("sweet-gpu-test: fence %u of submission %u not done within 2 s: %#x\n", s.fence, i, kr);
			return 1;
		}
		took_ns += now_ns() - began;
		if (i < 2 || (i + 1) % 16 == 0)
			printf("sweet-gpu-test: submission %u: fence %u done, word %#x\n", i, s.fence, target.cpu[i]);
	}
	for (unsigned i = 0; i < submissions; i++)
		if (target.cpu[i] != (0xc0de0000u | i))
			wrong++;
	printf("sweet-gpu-test: %u submissions, %llu us each (submit + wait), %u words wrong: %s\n", submissions,
	    (unsigned long long)(took_ns / submissions / 1000), wrong,
	    wrong == 0 ? "A PROGRAM DRIVES THE GPU" : "FAILED");

	struct drm_gem_close c1 = { .handle = cmd.handle }, c2 = { .handle = target.handle };
	(void)call(DRM_GEM_CLOSE, &c1, sizeof(c1));
	(void)call(DRM_GEM_CLOSE, &c2, sizeof(c2));
	IOServiceClose(gpu);
	return wrong == 0 ? 0 : 1;
}
