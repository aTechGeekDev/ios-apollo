/*
 * v2test: SweetAccelerator's v2 user client (NativeAdreno ABI, SweetGPUABI.h) without Turnip.
 *   v2test      buffers: CPU write + read back through the WC mapping (now and 200 ms later), a GPU
 *               CP_MEM_WRITE into a second buffer, then the same with an imported (malloc'd) buffer.
 */
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "NativeAdrenoABI.h"

static io_connect_t conn;

static kern_return_t call(uint32_t method, const void *in, size_t isz, void *out, size_t osz)
{
	uint8_t buf[8 + sizeof(NativeAdrenoAbiSubmit)];
	uint32_t hdr[2] = { 0x4e544e4c, method };
	memcpy(buf, hdr, 8);
	if (isz)
		memcpy(buf + 8, in, isz);
	size_t o = osz;
	return IOConnectCallStructMethod(conn, 0, buf, 8 + isz, osz ? out : NULL, osz ? &o : NULL);
}

static uint32_t pkt7(uint32_t op, uint32_t cnt)
{
	uint32_t p = 0x9669;
	uint32_t pc = (p >> (0xf & (cnt ^ (cnt >> 4) ^ (cnt >> 8) ^ (cnt >> 12) ^ (cnt >> 16) ^ (cnt >> 20) ^ (cnt >> 24) ^ (cnt >> 28)))) & 1;
	uint32_t po = (p >> (0xf & (op ^ (op >> 4) ^ (op >> 8) ^ (op >> 12) ^ (op >> 16) ^ (op >> 20) ^ (op >> 24) ^ (op >> 28)))) & 1;
	return 0x70000000 | cnt | pc << 15 | (op & 0x7f) << 16 | po << 23;
}

struct bo { uint64_t handle, iova; uint32_t *map; };

static int alloc(struct bo *b, uint64_t bytes, uint64_t iova)
{
	NativeAdrenoAbiBoAlloc a = { .bytes = bytes, .align_log2 = 12 };
	NativeAdrenoAbiBoAllocReply ar;
	kern_return_t kr = call(NativeAdrenoMethodBoAlloc, &a, sizeof(a), &ar, sizeof(ar));
	if (kr) { printf("FAIL BoAlloc %x\n", kr); return -1; }
	NativeAdrenoAbiBoMap m = { .handle = ar.handle, .iova = iova, .permissions = 3, .shareability = 2 };
	NativeAdrenoAbiBoMapReply mr;
	kr = call(NativeAdrenoMethodBoMap, &m, sizeof(m), &mr, sizeof(mr));
	if (kr) { printf("FAIL BoMap %x\n", kr); return -1; }
	NativeAdrenoAbiBoCpuMap c = { .handle = ar.handle };
	NativeAdrenoAbiBoCpuMapReply cr;
	kr = call(NativeAdrenoMethodBoCpuMap, &c, sizeof(c), &cr, sizeof(cr));
	if (kr) { printf("FAIL BoCpuMap %x\n", kr); return -1; }
	mach_vm_address_t addr = 0;
	mach_vm_size_t len = 0;
	kr = IOConnectMapMemory64(conn, cr.token, mach_task_self(), &addr, &len, kIOMapAnywhere | kIOMapWriteCombineCache);
	if (kr) { printf("FAIL map %x\n", kr); return -1; }
	b->handle = ar.handle;
	b->iova = iova;
	b->map = (uint32_t *)addr;
	return 0;
}

static int check(const char *what, const uint32_t *p, uint32_t n, uint32_t seed)
{
	uint32_t bad = 0;
	for (uint32_t i = 0; i < n; i++)
		bad += p[i] != seed + i;
	printf("%s %s: %u of %u words wrong (word 0 = %08x)\n", bad ? "FAIL" : "PASS", what, bad, n, p[0]);
	return bad != 0;
}

/* GPU: CP_MEM_WRITE of 4 words to dst, via an IB in ib */
static int gpu_write(struct bo *ib, uint64_t dst, const char *what, volatile uint32_t *dstmap)
{
	uint32_t *w = ib->map;
	w[0] = pkt7(0x3d, 6);
	w[1] = (uint32_t)dst;
	w[2] = (uint32_t)(dst >> 32);
	w[3] = 0xcafe0001; w[4] = 0xcafe0002; w[5] = 0xcafe0003; w[6] = 0xcafe0004;
	__asm__ volatile("dsb sy" ::: "memory");
	NativeAdrenoAbiSubmit s = { .buffer_count = 1 };
	s.buffers[0].handle = ib->handle;
	s.buffers[0].iova = ib->iova;
	s.buffers[0].bytes = 7 * 4;
	NativeAdrenoAbiSubmitReply sr;
	kern_return_t kr = call(NativeAdrenoMethodSubmit, &s, sizeof(s), &sr, sizeof(sr));
	if (kr) { printf("FAIL submit %x\n", kr); return 1; }
	NativeAdrenoAbiWaitFence wf = { .fence = sr.fence, .timeout_ns = 1000000000ull };
	kr = call(NativeAdrenoMethodWaitFence, &wf, sizeof(wf), NULL, 0);
	if (kr) { printf("FAIL wait fence %llu: %x\n", (unsigned long long)sr.fence, kr); return 1; }
	int ok = dstmap[0] == 0xcafe0001 && dstmap[3] == 0xcafe0004;
	printf("%s %s: GPU wrote %08x %08x %08x %08x (fence %llu)\n", ok ? "PASS" : "FAIL", what, dstmap[0], dstmap[1], dstmap[2],
	       dstmap[3], (unsigned long long)sr.fence);
	return !ok;
}

int main(void)
{
	io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAcceleratorES"));
	if (!s || IOServiceOpen(s, mach_task_self(), 0x4147, &conn)) {
		printf("FAIL open\n");
		return 1;
	}
	NativeAdrenoAbiDeviceInfo info;
	if (call(NativeAdrenoMethodGetDeviceInfo, NULL, 0, &info, sizeof(info))) {
		printf("FAIL device info\n");
		return 1;
	}
	printf("window %llx + %llx, chip %x\n", (unsigned long long)info.va_start, (unsigned long long)info.va_size, info.chip_id);
	int fails = 0;
	struct bo a, b;
	if (alloc(&a, 65536, info.va_start) || alloc(&b, 65536, info.va_start + 0x100000))
		return 1;
	const uint32_t n = 16384;
	for (uint32_t i = 0; i < n; i++)
		a.map[i] = 0x10000000 + i;
	fails += check("CPU write, read back at once", a.map, n, 0x10000000);
	usleep(200000);
	fails += check("CPU write, read back 200 ms later", a.map, n, 0x10000000);
	/* a second mapping of the same buffer sees the same memory */
	NativeAdrenoAbiBoCpuMap c = { .handle = a.handle };
	NativeAdrenoAbiBoCpuMapReply cr;
	mach_vm_address_t addr = 0;
	mach_vm_size_t len = 0;
	if (!call(NativeAdrenoMethodBoCpuMap, &c, sizeof(c), &cr, sizeof(cr)) &&
	    !IOConnectMapMemory64(conn, cr.token, mach_task_self(), &addr, &len, kIOMapAnywhere | kIOMapWriteCombineCache))
		fails += check("second mapping", (uint32_t *)addr, n, 0x10000000);
	memset(b.map, 0, 64);
	fails += gpu_write(&a, b.iova, "CP_MEM_WRITE into a WC buffer", b.map);

	/* an import of the caller's own (cacheable) pages: the caller maintains its caches */
	uint32_t *host;
	posix_memalign((void **)&host, 16384, 65536);
	memset(host, 0, 65536);
	for (uint32_t i = 0; i < 65536; i += 64)
		__asm__ volatile("dc civac, %0" :: "r"((char *)host + i) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
	NativeAdrenoAbiBoImport im = { .address = (uint64_t)(uintptr_t)host, .bytes = 65536 };
	NativeAdrenoAbiBoAllocReply ir;
	kern_return_t kr = call(NativeAdrenoMethodBoImport, &im, sizeof(im), &ir, sizeof(ir));
	if (kr) {
		printf("FAIL BoImport %x\n", kr);
		return 1;
	}
	NativeAdrenoAbiBoMap m = { .handle = ir.handle, .iova = info.va_start + 0x200000, .permissions = 3, .shareability = 2 };
	NativeAdrenoAbiBoMapReply mr;
	if ((kr = call(NativeAdrenoMethodBoMap, &m, sizeof(m), &mr, sizeof(mr)))) {
		printf("FAIL import map %x\n", kr);
		return 1;
	}
	int r = gpu_write(&a, m.iova, "CP_MEM_WRITE into imported memory (before invalidate)", host);
	for (uint32_t i = 0; i < 64; i += 64)
		__asm__ volatile("dc civac, %0" :: "r"((char *)host + i) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
	printf("%s imported memory after dc civac: %08x %08x\n", host[0] == 0xcafe0001 ? "PASS" : "FAIL", host[0], host[3]);
	fails += host[0] != 0xcafe0001;
	(void)r;
	NativeAdrenoAbiStatus st;
	call(NativeAdrenoMethodGetStatus, NULL, 0, &st, sizeof(st));
	NativeAdrenoAbiTimestamp ts;
	call(NativeAdrenoMethodGetTimestamp, NULL, 0, &ts, sizeof(ts));
	printf("faults %llu, timestamp %llu\n", (unsigned long long)st.faults, (unsigned long long)ts.ticks);
	printf("%s: %d failed\n", fails ? "FAIL" : "ALL PASS", fails);
	return fails != 0;
}
