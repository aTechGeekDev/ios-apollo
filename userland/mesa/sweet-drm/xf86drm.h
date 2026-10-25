/*
 * What Mesa's freedreno takes from libdrm's xf86drm.h, on a system without Linux's DRM: the
 * declarations here, the functions in sweet_drm.c, which carry the requests to the kernel's GPU
 * service (SweetGPU, iokit/Kernel/arm/SweetGPU.cpp in xnu/patches/0112) as calls of its user
 * client. userland/mesa/build.sh puts both into Mesa's tree as src/sweet-drm, where they are the
 * "libdrm" freedreno is built against. Request numbers and structures are Linux's (Mesa's
 * include/drm-uapi).
 *
 * Adapted from HackiOS's tools/mesa/redwood-drm (Copyright (c) 2026 OOSEX GANG, MIT License).
 */
#ifndef SWEET_XF86DRM_H
#define SWEET_XF86DRM_H

#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include "drm-uapi/drm.h"

#define DRM_NODE_PRIMARY        0
#define DRM_NODE_RENDER         2
#define DRM_CLOEXEC             O_CLOEXEC
#define DRM_RDWR                O_RDWR

typedef struct _drmVersion {
	int version_major, version_minor, version_patchlevel;
	int name_len;
	char *name;
	int date_len;
	char *date;
	int desc_len;
	char *desc;
} drmVersion, *drmVersionPtr;

int drmOpenWithType(const char *name, const char *busid, int type);
int drmIoctl(int fd, unsigned long request, void *arg);
int drmCommandWrite(int fd, unsigned long index, const void *data, unsigned long size);
int drmCommandWriteRead(int fd, unsigned long index, void *data, unsigned long size);
drmVersionPtr drmGetVersion(int fd);
void drmFreeVersion(drmVersionPtr version);
int drmGetCap(int fd, uint64_t capability, uint64_t *value);

/*
 * Buffers and fences as file descriptors: there are none here. Memory somebody else has made
 * (an IOSurface, by its ID where freedreno expects a descriptor) is what drmPrimeFDToHandle()
 * is for; SweetGPU does not offer that yet, so it fails (see sweet_drm_surface()).
 */
int drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime_fd);
int drmPrimeFDToHandle(int fd, int surface, uint32_t *handle);
int drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle);
int drmSyncobjDestroy(int fd, uint32_t handle);
int drmSyncobjReset(int fd, const uint32_t *handles, uint32_t count);
int drmSyncobjFDToHandle(int fd, int obj_fd, uint32_t *handle);
int drmSyncobjHandleToFD(int fd, uint32_t handle, int *obj_fd);
int drmSyncobjImportSyncFile(int fd, uint32_t handle, int sync_file_fd);
int drmSyncobjExportSyncFile(int fd, uint32_t handle, int *sync_file_fd);

/* Not libdrm's: a buffer's memory in this process, in place of mmap() on the device (freedreno_bo.c is patched to call these). */
void *sweet_drm_map(int fd, uint32_t handle, uint64_t size);
void sweet_drm_unmap(int fd, uint32_t handle, void *address);

/*
 * Not libdrm's either: what the memory of an IOSurface would be like as a buffer; 0, or -1 with
 * errno. The request (0x7e, HackiOS's) is not in SweetGPU yet, so this fails with ENOSYS and
 * OSMesa's EGL-image path finds no surface; drawing into OSMesa's own buffers is unaffected.
 */
struct sweet_drm_surface {
	uint32_t surface;                       /* the IOSurface's ID */
	uint32_t handle;                        /* (the kernel's: which of the two is asked) */
	uint64_t size;                          /* back: how big the buffer is, */
	uint32_t offset, row_bytes;             /* where the pixels start in it and how long a row of them is, */
	uint32_t width, height, pixel_format, planes;   /* and what they are */
};
int sweet_drm_surface(int fd, struct sweet_drm_surface *surface);

#endif
