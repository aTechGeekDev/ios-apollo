// SPDX-License-Identifier: MIT
// Native Metal API frontend over the bridge (bridge/NativeMetalObjects.h): the metal2vulkan runtime on Turnip, on the Adreno 740 through
// NativeAdreno. Same shape as the offline frontend: the device is a dynamically allocated subclass of the target's own _MTLDevice that
// only adds this file's implementations; every other object is an own class answering the Metal protocol methods it implements.
// Every result comes from the runtime and the GPU: a refused call returns nil/NO with the runtime's reason, an encoder call the runtime
// refuses fails its command buffer (status Error, handlers run) instead of being dropped. A selector this frontend does not implement is
// reported through the missing-selector hook before the usual exception, so a hardware run names the gap.
// Shared events work within this process (no cross-process handle yet). Not yet implemented here: heaps, argument buffers, indirect commands, drawables/presentation.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#include <algorithm>
#include <atomic>
#include <initializer_list>
#include <mutex>
#include <pthread.h>
#include <string>
#include <unordered_map>
#include <vector>
#include <sys/mman.h>
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <mach/mach.h>
#include "bridge/NativeMetalObjects.h"
#include "NativeBridgeMetalFrontend.h"

extern "C" void sys_dcache_flush(void *start, size_t length);

static NmbDevice *gDevice;
static id gDeviceObject;
static uint64_t gRegistryID;
static NSString *gName;
static void (*gMissing)(const char *, const char *);

// What this device has been asked and refused, for the plugin's status line (native_bridge_metal_status): commits, render/compute pipelines made,
// refusals, and the last two refusals' texts. Counters only; nothing here changes a result.
static std::atomic<uint64_t> gCommits,gCommitFailures,gPipelines,gProblems,gCompleted;
// What the render server actually asks of the GPU (int-141: 59 commits in 200 s, and a desktop that behaves like CPU compositing): render passes,
// draws, the pixels of their first colour attachment, compute dispatches, blits and the largest pass (pixels).
static std::atomic<uint64_t> gPasses,gDraws,gPassPixels,gDispatches,gBlits,gBiggestPass,gFullScreenPasses;
// Where the time goes on the CPU side of the bridge: pipeline, library and function creation (count, total and slowest, in microseconds), and the
// last commits with what each held and how long the GPU took (commit to completion).
static uint64_t nowUs() {return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1000;}
struct Timed {std::atomic<uint64_t> count{0},total{0},slowest{0};
 void add(uint64_t began){const uint64_t took=nowUs()-began;count++;total+=took;uint64_t seen=slowest.load();while(took>seen && !slowest.compare_exchange_weak(seen,took)){}}};
static Timed gTimePipeline,gTimeLibrary,gTimeFunction,gTimeEncodeToCommit;
static Timed gTimeWaitScheduled,gTimeWaitCompleted;
static Timed gTimeResourceWait;
static std::atomic<uint64_t> gResourceChecks,gResourceSkipped;
static Timed gTimeSurfaceFlush;
static std::atomic<uint64_t> gSurfaceFlushBytes,gSurfaceFlushDuplicates;
struct EncodedWork {uint32_t passes,draws,dispatches,blits;uint64_t pixels;};
struct CommitRecord {uint64_t committedUs=0,callbackUs=0,ageUs=0;int64_t scheduledUs=-1;uint32_t index=0;EncodedWork work={};};
static CommitRecord gCommitRing[32];
static std::mutex gCommitLock;
static std::mutex gProblemLock;
static char gLastProblems[2][200];
static void noteProblem(NSString *what) {
 gProblems++;
 std::lock_guard<std::mutex> lock(gProblemLock);
 memcpy(gLastProblems[1],gLastProblems[0],sizeof gLastProblems[0]);
 strlcpy(gLastProblems[0],what.UTF8String?:"?",sizeof gLastProblems[0]);
}
extern "C" void sm2_logs(const char *);
static std::atomic<uint64_t> gLoggedCount;
#define NBLOG(...) do{NSString *nbText=[NSString stringWithFormat:__VA_ARGS__];if(gLoggedCount.fetch_add(1,std::memory_order_relaxed)<64)sm2_logs(nbText.UTF8String);noteProblem(nbText);}while(0)
// The pixel formats textures were asked for (first eight distinct), with how many were refused: native_bridge_metal_formats.
static uint32_t gFormats[8];static unsigned gFormatCount;static std::atomic<uint64_t> gTextureRefusals;
static void noteFormat(uint32_t format,bool made) {
 std::lock_guard<std::mutex> lock(gProblemLock);
 if(!made)gTextureRefusals++;
 for(unsigned i=0;i<gFormatCount;i++)if(gFormats[i]==format)return;
 if(gFormatCount<8)gFormats[gFormatCount++]=format;
}
static NSError *nbError(NSString *why) {
 return [NSError errorWithDomain:@"org.blu-sharky.native-metal" code:-1 userInfo:@{NSLocalizedDescriptionKey:why?:@"refused"}];
}
static NSString *lastError() {return [NSString stringWithUTF8String:nmb_last_error()];}
// The render pipeline journal: one line per render pipeline creation (when, on which thread, how long, the outcome, both functions with
// every constant value, the attachments, blending and vertex descriptor) appended to pipelines.log in the runtime's cache directory, which
// the board log exports with the caches (CacheExport.h): every pipeline a boot made, or was refused, can be made again on the host.
static std::mutex gJournalLock;
static std::string gJournalPath;
static uint64_t gJournalBegan;
static void journal(const std::string &line) {
 if(gJournalPath.empty())return;
 std::lock_guard<std::mutex> lock(gJournalLock);
 if(FILE *f=fopen(gJournalPath.c_str(),"a")){fwrite(line.data(),1,line.size(),f);fputc('\n',f);fclose(f);}
}

static std::atomic<uint64_t> gTraceObjectIDs{0};
@interface NBObject : NSObject {uint64_t _traceObjectID;}
@property(atomic,copy) NSString *label;
@end
@implementation NBObject
- (id<MTLDevice>)device {return gDeviceObject;}
// Metal's trace identity: queues, command buffers, encoders and heaps answer globalTraceObjectID for signposts (unique, never reused).
- (uint64_t)globalTraceObjectID {
 uint64_t id=__atomic_load_n(&_traceObjectID,__ATOMIC_RELAXED);
 if(!id) {
  const uint64_t next=gTraceObjectIDs.fetch_add(1,std::memory_order_relaxed)+1;
  if(__atomic_compare_exchange_n(&_traceObjectID,&id,next,false,__ATOMIC_RELAXED,__ATOMIC_RELAXED))id=next;
 }
 return id;
}
- (void)doesNotRecognizeSelector:(SEL)selector {
 if(gMissing)gMissing(class_getName(object_getClass(self)),sel_getName(selector));
 noteProblem([NSString stringWithFormat:@"missing %s %s",class_getName(object_getClass(self)),sel_getName(selector)]);
 [super doesNotRecognizeSelector:selector];
}
@end

// ---- resources ----
// The wait takes a strong snapshot of already-committed buffers; new commits require the
// caller's usual resource synchronization. Storage dependency checks are in the runtime.
static NSMutableSet *gInFlight;
static void waitForResource(id resource);
// Resource SPI the runtime has no state for: no protected content (Metal's default options), and no owner transfer
// (memory attribution is the kernel driver's, by the importing task), refused as not supported.
#define NB_RESOURCE_SPI \
- (uint64_t)protectionOptions {return 0;} \
- (id<MTLHeap>)heap {return _parentHeap;} \
- (BOOL)doesAliasResource:(id<MTLResource>)r {(void)r;return NO;} \
- (BOOL)doesAliasAllResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)c {(void)r;(void)c;return NO;} \
- (BOOL)doesAliasAnyResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)c {(void)r;(void)c;return NO;} \
- (BOOL)isPurgeable {return NO;} \
- (BOOL)isComplete {return YES;} \
- (MTLResourceOptions)unfilteredResourceOptions {return [self resourceOptions];} \
- (NSUInteger)allocationID {return (NSUInteger)(uintptr_t)self;} \
- (NSUInteger)resourceID {return (NSUInteger)(uintptr_t)self;} \
- (NSUInteger)resourceSize {return [self allocatedSize];} \
- (int)setOwnerWithIdentity:(unsigned)identity {(void)identity;return 46; /* KERN_NOT_SUPPORTED */} \
- (void)waitUntilComplete {waitForResource(self);}
@interface NBBuffer : NBObject
@property(nonatomic) NmbBuffer *handle;
@property(nonatomic) MTLResourceOptions options;
@property(nonatomic,copy) void (^deallocator)(void *,NSUInteger);
@property(nonatomic) void *wrapped;
@property(nonatomic) IOSurfaceRef surfaceOwner; // keeps a shared import's CPU mapping alive
@property(nonatomic,strong) id<MTLHeap> parentHeap;   // the heap that made the buffer, nil otherwise
@property(nonatomic) int responsibleProcess;
@end
@interface NBTexture : NBObject
@property(nonatomic) NmbTexture *handle;
@property(nonatomic) NmbTextureDescriptor descriptor;
@property(nonatomic) NmbTextureDescriptor requestDescriptor;
@property(nonatomic) BOOL hasRequestDescriptor,noRecycle;
@property(nonatomic,strong) NBBuffer *buffer;
@property(nonatomic) IOSurfaceRef surface;
@property(nonatomic) NSUInteger surfacePlane;
@property(nonatomic) NSUInteger offset,rowBytes;
@property(nonatomic,strong) id<MTLTexture> parent;
@property(nonatomic) NSUInteger parentRelativeLevel,parentRelativeSlice;
@property(nonatomic,strong) id<MTLHeap> parentHeap;
@property(nonatomic) int responsibleProcess;
@end
@implementation NBBuffer
- (void)dealloc {
 const NSUInteger length=nmb_buffer_length(_handle);nmb_buffer_release(_handle);
 if(_deallocator)_deallocator(_wrapped,length);
 if(_surfaceOwner)CFRelease(_surfaceOwner);
}
- (NSUInteger)length {return nmb_buffer_length(_handle);}
- (void *)contents {return nmb_buffer_contents(_handle);}
- (uint64_t)gpuAddress {return nmb_buffer_gpu_address(_handle);}
- (uint64_t)gpuHandle {return [self gpuAddress];}
- (MTLResourceOptions)resourceOptions {return _options;}
- (MTLStorageMode)storageMode {return (MTLStorageMode)((_options&MTLResourceStorageModeMask)>>MTLResourceStorageModeShift);}
- (MTLCPUCacheMode)cpuCacheMode {return (MTLCPUCacheMode)((_options&MTLResourceCPUCacheModeMask)>>MTLResourceCPUCacheModeShift);}
- (MTLHazardTrackingMode)hazardTrackingMode {return (MTLHazardTrackingMode)((_options&MTLResourceHazardTrackingModeMask)>>MTLResourceHazardTrackingModeShift);}
- (void)didModifyRange:(NSRange)range {(void)range;}
- (void)addDebugMarker:(NSString *)marker range:(NSRange)range {(void)marker;(void)range;}
- (void)removeAllDebugMarkers {}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state {
 const uint64_t answer=nmb_buffer_set_purgeable_state(_handle,state);
 if(!answer)NBLOG(@"native-metal: buffer setPurgeableState refused: %@",lastError());
 return (MTLPurgeableState)answer;
}
- (NSUInteger)heapOffset {return nmb_buffer_heap_offset(_handle);}
- (BOOL)isAliasable {return nmb_buffer_is_aliasable(_handle);}
- (void)makeAliasable {if(!nmb_buffer_make_aliasable(_handle))NBLOG(@"native-metal: buffer makeAliasable refused: %@",lastError());}
- (NSUInteger)allocatedSize {return nmb_buffer_length(_handle);}
- (IOSurfaceRef)iosurface {return _surfaceOwner;}
NB_RESOURCE_SPI
@end
// Reuse only an import still held by a texture/view or pending command. Weak
// values never extend a GPU allocation's lifetime. The strong buffer snapshot
// and its retained surface prevent object/address reuse during a hit. A new
// mapping, allocation identity or size needs a separate import; ordinary
// caller-owned no-copy buffers do not enter this cache.
static NSMapTable<NSValue *,NBBuffer *> *gSurfaceImports;
static std::mutex gSurfaceImportLock;
static NBBuffer *surfaceBuffer(IOSurfaceRef surface,void *base,size_t bytes) {
 struct Key {uint64_t identity,address,bytes;};
 const Key value={IOSurfaceGetID(surface),(uintptr_t)base,bytes};
 NSValue *key=value.identity?[NSValue valueWithBytes:&value objCType:@encode(Key)]:nil;
 std::lock_guard<std::mutex> lock(gSurfaceImportLock);
 if(!gSurfaceImports)gSurfaceImports=[NSMapTable strongToWeakObjectsMapTable];
 NBBuffer *buffer=key?[gSurfaceImports objectForKey:key]:nil;
 if(buffer)return buffer;
 NmbBuffer *handle=nmb_buffer_new_no_copy(gDevice,base,bytes,MTLResourceStorageModeShared);
 if(!handle){NBLOG(@"native-metal: surface import refused: %@",lastError());return nil;}
 buffer=[NBBuffer new];buffer.handle=handle;buffer.options=MTLResourceStorageModeShared;
 buffer.surfaceOwner=(IOSurfaceRef)CFRetain(surface);
 if(key) {
  // Bound metadata without retaining old frames. Evicting an association is
  // harmless: its owners still retain the actual import until their own end.
  if(gSurfaceImports.count>=256) {
   for(NSValue *old in gSurfaceImports.keyEnumerator.allObjects)
    if(![gSurfaceImports objectForKey:old])[gSurfaceImports removeObjectForKey:old];
   if(gSurfaceImports.count>=256)[gSurfaceImports removeObjectForKey:gSurfaceImports.keyEnumerator.nextObject];
  }
  [gSurfaceImports setObject:buffer forKey:key];
 }
 return buffer;
}
static bool textureDescriptor(MTLTextureDescriptor *d,NmbTextureDescriptor *out) {
 if(!d)return false;
 *out={(uint64_t)d.textureType,(uint64_t)d.pixelFormat,d.width,d.height,d.depth,d.mipmapLevelCount,d.sampleCount,d.arrayLength,(uint64_t)d.usage,(uint64_t)d.resourceOptions};
 return true;
}
static uint64_t sweetTexelBytes(MTLPixelFormat f);
static bool sweetBlock(MTLPixelFormat f, uint32_t *bw, uint32_t *bh, uint32_t *bytes);
static MTLResourceID sweetResourceID(const void *p) {
 MTLResourceID r{};const uint64_t v=(uint64_t)(uintptr_t)p;
 static_assert(sizeof(r)==sizeof(v),"MTLResourceID size");
 memcpy(&r,&v,sizeof(r));return r;
}
@protocol NBTextureViewDesc <NSObject>
- (MTLPixelFormat)pixelFormat;
- (MTLTextureType)textureType;
- (NSRange)levelRange;
- (NSRange)sliceRange;
@end
struct PooledTexture {
 NmbTexture *handle;
 NmbTextureDescriptor req;
 uint64_t bytes;
};
static std::mutex gTexturePoolLock;
static std::vector<PooledTexture> gTexturePool;
static uint64_t gTexturePoolBytes;
static std::atomic<uint64_t> gTexturePoolHits,gTexturePoolMisses;
static void texturePoolLimits(uint64_t *capBytes,size_t *capCount) {
 const char *prog=getprogname();
 if(prog && !strcmp(prog,"backboardd")){*capBytes=192ull<<20;*capCount=32;}
 else if(prog && !strcmp(prog,"SpringBoard")){*capBytes=64ull<<20;*capCount=24;}
 else{*capBytes=0;*capCount=0;}
}
static bool canPoolTextureDesc(const NmbTextureDescriptor &req) {
 const char *prog=getprogname();
 if(!prog || (strcmp(prog,"backboardd")!=0 && strcmp(prog,"SpringBoard")!=0))return false;
 if(req.type!=MTLTextureType2D || req.depth!=1 || req.levels!=1 || req.samples!=1 || req.array_length!=1)return false;
 if(req.width<64 || req.height<64)return false;
 return (req.usage&MTLTextureUsageRenderTarget)!=0 && (req.usage&MTLTextureUsageShaderWrite)==0;
}
static NmbTexture *takePooledTexture(const NmbTextureDescriptor &req) {
 if(!canPoolTextureDesc(req))return nullptr;
 std::lock_guard<std::mutex> lock(gTexturePoolLock);
 for(size_t i=gTexturePool.size();i>0;i--) {
  if(memcmp(&gTexturePool[i-1].req,&req,sizeof(req))==0) {
   NmbTexture *h=gTexturePool[i-1].handle;
   gTexturePoolBytes-=gTexturePool[i-1].bytes;
   gTexturePool.erase(gTexturePool.begin()+(ptrdiff_t)(i-1));
   gTexturePoolHits.fetch_add(1,std::memory_order_relaxed);
   return h;
  }
 }
 gTexturePoolMisses.fetch_add(1,std::memory_order_relaxed);
 return nullptr;
}
static void drainTexturePool() {
 std::vector<PooledTexture> doomed;
 {
  std::lock_guard<std::mutex> lock(gTexturePoolLock);
  doomed.swap(gTexturePool);
  gTexturePoolBytes=0;
 }
 for(const PooledTexture &e:doomed)nmb_texture_release(e.handle);
}
static void recycleStandaloneTexture(NmbTexture *handle,const NmbTextureDescriptor &req,uint64_t bytes) {
 if(!handle)return;
 uint64_t capBytes=0;size_t capCount=0;
 texturePoolLimits(&capBytes,&capCount);
 if(!canPoolTextureDesc(req) || !bytes || bytes>capBytes){nmb_texture_release(handle);return;}
 std::vector<NmbTexture *> evicted;
 {
  std::lock_guard<std::mutex> lock(gTexturePoolLock);
  while(!gTexturePool.empty() && (gTexturePoolBytes+bytes>capBytes || gTexturePool.size()>=capCount)) {
   evicted.push_back(gTexturePool.front().handle);
   gTexturePoolBytes-=gTexturePool.front().bytes;
   gTexturePool.erase(gTexturePool.begin());
  }
  gTexturePool.push_back({handle,req,bytes});
  gTexturePoolBytes+=bytes;
 }
 for(NmbTexture *old:evicted)nmb_texture_release(old);
}
@implementation NBTexture
- (void)dealloc {
 if(_handle) {
  if(_hasRequestDescriptor && !_surface && !_buffer && !_parent && !_parentHeap && !_noRecycle)
   recycleStandaloneTexture(_handle,_requestDescriptor,[self allocatedSize]);
  else
   nmb_texture_release(_handle);
 }
 if(_surface)CFRelease(_surface);
}
- (MTLTextureType)textureType {return (MTLTextureType)_descriptor.type;}
- (MTLPixelFormat)pixelFormat {return (MTLPixelFormat)_descriptor.format;}
- (NSUInteger)width {return _descriptor.width;}
- (NSUInteger)height {return _descriptor.height;}
- (NSUInteger)depth {return _descriptor.depth;}
- (NSUInteger)mipmapLevelCount {return _descriptor.levels;}
- (NSUInteger)sampleCount {return _descriptor.samples;}
- (NSUInteger)arrayLength {return _descriptor.array_length;}
- (MTLTextureUsage)usage {return (MTLTextureUsage)_descriptor.usage;}
- (MTLResourceOptions)resourceOptions {return (MTLResourceOptions)_descriptor.options;}
- (MTLStorageMode)storageMode {return (MTLStorageMode)((_descriptor.options&MTLResourceStorageModeMask)>>MTLResourceStorageModeShift);}
- (MTLCPUCacheMode)cpuCacheMode {return (MTLCPUCacheMode)((_descriptor.options&MTLResourceCPUCacheModeMask)>>MTLResourceCPUCacheModeShift);}
- (MTLHazardTrackingMode)hazardTrackingMode {return (MTLHazardTrackingMode)((_descriptor.options&MTLResourceHazardTrackingModeMask)>>MTLResourceHazardTrackingModeShift);}
- (BOOL)isFramebufferOnly {return NO;}
- (BOOL)allowGPUOptimizedContents {return YES;}
- (BOOL)isShareable {return _surface!=nullptr;}
- (BOOL)isSparse {return NO;}
- (BOOL)isDrawable {return NO;}
- (BOOL)isCompressed {uint32_t bw=0,bh=0,bb=0;return sweetBlock((MTLPixelFormat)_descriptor.format,&bw,&bh,&bb);}
- (BOOL)isMemoryless {return self.storageMode==MTLStorageModeMemoryless;}
- (MTLTextureCompressionType)compressionType {return MTLTextureCompressionTypeLossless;}
- (NSUInteger)compressionFootprint {return 0;}
- (MTLTextureSwizzleChannels)swizzle {return MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed,MTLTextureSwizzleGreen,MTLTextureSwizzleBlue,MTLTextureSwizzleAlpha);}
- (uint32_t)swizzleKey {return 0;}
- (IOSurfaceRef)iosurface {return _surface;}
- (NSUInteger)iosurfacePlane {return _surfacePlane;}
- (id<MTLBuffer>)buffer {return _surface?nil:(id<MTLBuffer>)_buffer;}
- (NSUInteger)bufferOffset {return _offset;}
- (NSUInteger)bufferBytesPerRow {return _rowBytes;}
- (id<MTLTexture>)parentTexture {return _parent;}
- (id<MTLResource>)rootResource {return _parent?(id<MTLResource>)_parent:(_buffer?(id<MTLResource>)_buffer:nil);}
- (uint64_t)gpuAddress {return _buffer?[_buffer gpuAddress]+_offset:0;}
- (uint64_t)gpuHandle {return (uint64_t)(uintptr_t)_handle;}
- (MTLResourceID)gpuResourceID {return sweetResourceID(_handle);}
- (NSUInteger)resourceIndex {return 0;}
- (NSUInteger)uniqueIdentifier {return (NSUInteger)(uintptr_t)_handle;}
- (NSUInteger)rotation {return 0;}
- (NSUInteger)allocatedSize {
 if(_surface)return IOSurfaceGetAllocSize(_surface);
 if(_buffer && !_rowBytes)return [_buffer allocatedSize];
 const uint64_t w=MAX((uint64_t)1,_descriptor.width),h=MAX((uint64_t)1,_descriptor.height),
                d=MAX((uint64_t)1,_descriptor.depth),a=MAX((uint64_t)1,_descriptor.array_length),
                s=MAX((uint64_t)1,_descriptor.samples);
 if(_rowBytes)return (NSUInteger)(_rowBytes*h*d*a);
 uint32_t bw=0,bh=0,bb=0;
 const uint64_t base=sweetBlock((MTLPixelFormat)_descriptor.format,&bw,&bh,&bb)
     ? ((w+bw-1)/bw)*((h+bh-1)/bh)*bb
     : w*h*sweetTexelBytes((MTLPixelFormat)_descriptor.format);
 const uint64_t page=(uint64_t)getpagesize();
 return (NSUInteger)((base*d*a*s+page-1)&~(page-1));
}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state {
 if(state==MTLPurgeableStateEmpty)_noRecycle=YES;
 const uint64_t answer=nmb_texture_set_purgeable_state(_handle,state);
 if(!answer)NBLOG(@"native-metal: texture setPurgeableState refused: %@",lastError());
 return (MTLPurgeableState)answer;
}
- (NSUInteger)heapOffset {return nmb_texture_heap_offset(_handle);}
- (BOOL)isAliasable {return nmb_texture_is_aliasable(_handle);}
- (void)makeAliasable {_noRecycle=YES;if(!nmb_texture_make_aliasable(_handle))NBLOG(@"native-metal: texture makeAliasable refused: %@",lastError());}
NB_RESOURCE_SPI
- (id<MTLTexture>)view:(NmbTexture *)handle {
 if(!handle){NBLOG(@"native-metal: texture view refused: %@",lastError());return nil;}
 NBTexture *view=[NBTexture new];view.handle=handle;NmbTextureDescriptor descriptor;nmb_texture_describe(handle,&descriptor);view.descriptor=descriptor;
 view.parent=(id<MTLTexture>)self;view.buffer=_buffer;view.offset=_offset;view.rowBytes=_rowBytes;view.parentHeap=_parentHeap;
 if(_surface){view.surface=(IOSurfaceRef)CFRetain(_surface);view.surfacePlane=_surfacePlane;}
 return (id<MTLTexture>)view;
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format {
 return [self view:nmb_texture_new_view(_handle,format,0,nullptr,nullptr,true)];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type levels:(NSRange)levels slices:(NSRange)slices {
 const uint64_t l[2]={levels.location,levels.length},s[2]={slices.location,slices.length};
 id<MTLTexture> v=[self view:nmb_texture_new_view(_handle,format,type,l,s,false)];
 if(v){((NBTexture *)v).parentRelativeLevel=levels.location;((NBTexture *)v).parentRelativeSlice=slices.location;}
 return v;
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type levels:(NSRange)levels slices:(NSRange)slices swizzle:(MTLTextureSwizzleChannels)swizzle {
 (void)swizzle;
 return [self newTextureViewWithPixelFormat:format textureType:type levels:levels slices:slices];
}
- (id<MTLTexture>)newTextureViewWithDescriptor:(id)d {
 if(!d)return nil;
 id<NBTextureViewDesc> desc=(id<NBTextureViewDesc>)d;
 const MTLPixelFormat df=[desc pixelFormat];
 const MTLPixelFormat format=(df!=MTLPixelFormatInvalid)?df:self.pixelFormat;
 const MTLTextureType type=[desc textureType];
 NSRange levels=[desc levelRange],slices=[desc sliceRange];
 if(!levels.length)levels=NSMakeRange(0,MAX((NSUInteger)1,self.mipmapLevelCount));
 if(!slices.length) {
  const NSUInteger mult=([self textureType]==MTLTextureTypeCube || [self textureType]==MTLTextureTypeCubeArray)?6:1;
  slices=NSMakeRange(0,MAX((NSUInteger)1,self.arrayLength*mult));
 }
 return [self newTextureViewWithPixelFormat:format textureType:type levels:levels slices:slices];
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void *)bytes bytesPerRow:(NSUInteger)row bytesPerImage:(NSUInteger)image {
 const uint64_t region[6]={r.origin.x,r.origin.y,r.origin.z,r.size.width,r.size.height,r.size.depth};
 const uint64_t length=(r.size.depth>1?image*(r.size.depth-1):0)+row*r.size.height;
 if(!nmb_texture_replace(_handle,region,level,slice,bytes,row,image,length))NBLOG(@"native-metal: replaceRegion refused: %@",lastError());
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level withBytes:(const void *)bytes bytesPerRow:(NSUInteger)row {
 [self replaceRegion:r mipmapLevel:level slice:0 withBytes:bytes bytesPerRow:row bytesPerImage:row*r.size.height];
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)row bytesPerImage:(NSUInteger)image fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice {
 const uint64_t region[6]={r.origin.x,r.origin.y,r.origin.z,r.size.width,r.size.height,r.size.depth};
 const uint64_t length=(r.size.depth>1?image*(r.size.depth-1):0)+row*r.size.height;
 if(!nmb_texture_get_bytes(_handle,bytes,row,image,length,region,level,slice))NBLOG(@"native-metal: getBytes refused: %@",lastError());
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)row fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level {
 [self getBytes:bytes bytesPerRow:row bytesPerImage:row*r.size.height fromRegion:r mipmapLevel:level slice:0];
}
@end
// A command can use many independent imports/views of one IOSurface. Their
// owners keep the mapping live through this phase. Maintain each exact CPU
// range once; no address identity or decision is carried into another phase
// or command, and distinct/partially overlapping ranges retain their calls.
static void flushSurfaces(NSMutableSet *surfaces) {
 if(!surfaces.count)return;
 std::vector<std::pair<uintptr_t,size_t>> ranges;
 ranges.reserve(surfaces.count);
 const size_t page=(size_t)getpagesize();
 for(id item in surfaces) {
  IOSurfaceRef surface=[item isKindOfClass:[NBTexture class]]?[(NBTexture *)item surface]:
                       ([item isKindOfClass:[NBBuffer class]]?[(NBBuffer *)item surfaceOwner]:nullptr);
  if(!surface)continue;
  void *rawBase=IOSurfaceGetBaseAddress(surface);
  const size_t allocation=IOSurfaceGetAllocSize(surface);
  if(!rawBase || !allocation)continue;
  const uintptr_t base=reinterpret_cast<uintptr_t>(rawBase)&~(page-1);
  const size_t span=((reinterpret_cast<uintptr_t>(rawBase)-base)+allocation+page-1)&~(page-1);
  ranges.emplace_back(base,span);
 }
 std::sort(ranges.begin(),ranges.end());
 const auto last=std::unique(ranges.begin(),ranges.end());
 gSurfaceFlushDuplicates+=(uint64_t)(ranges.end()-last);
 for(auto it=ranges.begin();it!=last;++it) {
  const uint64_t began=nowUs();
  sys_dcache_flush(reinterpret_cast<void *>(it->first),it->second);
  gSurfaceFlushBytes+=it->second;gTimeSurfaceFlush.add(began);
 }
}
static NBTexture *textureOnBuffer(NBBuffer *buffer,MTLTextureDescriptor *d,NSUInteger offset,NSUInteger row,bool surface) {
 NmbTextureDescriptor descriptor;if(!buffer || !textureDescriptor(d,&descriptor))return nil;
 NmbTexture *handle=nmb_texture_new_on_buffer(buffer.handle,&descriptor,offset,row,surface);
 if(!handle){NBLOG(@"native-metal: texture over buffer refused: %@",lastError());return nil;}
 NBTexture *texture=[NBTexture new];texture.handle=handle;nmb_texture_describe(handle,&descriptor);texture.descriptor=descriptor;
 texture.buffer=buffer;texture.offset=offset;texture.rowBytes=row;
 if(buffer.surfaceOwner)texture.surface=(IOSurfaceRef)CFRetain(buffer.surfaceOwner);
 return texture;
}
@implementation NBBuffer (Textures)
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset bytesPerRow:(NSUInteger)row {
 return (id<MTLTexture>)textureOnBuffer(self,d,offset,row,false);
}
- (id<MTLTexture>)newLinearTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset bytesPerRow:(NSUInteger)row bytesPerImage:(NSUInteger)image {
 NmbTextureDescriptor descriptor;if(!textureDescriptor(d,&descriptor))return nil;
 NmbTexture *handle=nmb_texture_new_linear(self.handle,&descriptor,offset,row,image);
 if(!handle){NBLOG(@"native-metal: linear texture refused: %@",lastError());return nil;}
 NBTexture *texture=[NBTexture new];texture.handle=handle;nmb_texture_describe(handle,&descriptor);texture.descriptor=descriptor;
 texture.buffer=self;texture.offset=offset;texture.rowBytes=row;
 if(self.surfaceOwner)texture.surface=(IOSurfaceRef)CFRetain(self.surfaceOwner);
 return (id<MTLTexture>)texture;
}
@end

// ---- libraries, functions, states ----
@interface NBLibrary : NBObject {
 @public
 uint8_t _libraryHash[CC_SHA256_DIGEST_LENGTH];
}
@property(nonatomic) NmbLibrary *handle;
- (void)computeLibraryHash:(const void *)bytes length:(size_t)length;
@end
@interface NBFunction : NBObject {
 @public
 uint8_t _bitCodeHash[CC_SHA256_DIGEST_LENGTH];
}
@property(nonatomic) NmbFunction *handle;
@property(nonatomic,copy) NSString *name;
@property(nonatomic) MTLFunctionOptions options;
@property(nonatomic) MTLFunctionType functionType;
@property(nonatomic) std::string constantsText;   // name:type:hex of each constant value it was specialized with (the journal's)
- (void)computeBitCodeHashWithLibrary:(const uint8_t *)libHash
                         originalName:(const char *)origName
                      specializedName:(const char *)specName
                            constants:(const NmbConstant *)constants
                                count:(size_t)count;
@end
@implementation NBFunction
- (void)dealloc {nmb_function_release(_handle);}
- (void)computeBitCodeHashWithLibrary:(const uint8_t *)libHash
                         originalName:(const char *)origName
                      specializedName:(const char *)specName
                            constants:(const NmbConstant *)constants
                                count:(size_t)count {
 std::vector<uint8_t> buf;
 buf.reserve(128+count*24);
 auto append=[&](const void *p,size_t n){if(p && n){const uint8_t *b=(const uint8_t *)p;buf.insert(buf.end(),b,b+n);}};
 append(libHash,CC_SHA256_DIGEST_LENGTH);
 if(origName)append(origName,strlen(origName)+1);
 if(specName)append(specName,strlen(specName)+1);
 const uint64_t meta[2]={(uint64_t)_functionType,(uint64_t)_options};
 append(meta,sizeof meta);
 for(size_t i=0;i<count;i++) {
  const uint64_t cmeta[3]={constants[i].type,constants[i].index,constants[i].length};
  append(cmeta,sizeof cmeta);
  if(constants[i].name)append(constants[i].name,strlen(constants[i].name)+1);
  append(constants[i].bytes,(size_t)constants[i].length);
 }
 CC_SHA256(buf.data(),(CC_LONG)buf.size(),_bitCodeHash);
}
- (const void *)bitCodeHash {return _bitCodeHash;}
- (const void *)baseFunctionHash {return _bitCodeHash;}
- (const void *)functionConstantSpecializationHash {return _bitCodeHash;}
- (NSUInteger)bitCodeFileSize {return 0;}
- (NSData *)bitcodeData {return nil;}
- (NSDictionary *)functionConstantsDictionary {return @{};}
- (NSArray *)vertexAttributes {return @[];}
- (NSArray *)stageInputAttributes {return @[];}
- (NSInteger)patchControlPointCount {return 0;}
- (MTLPatchType)patchType {return MTLPatchTypeNone;}
@end
// The target's own accessors of MTLFunctionConstantValues (as the offline frontend reads them); their ABI is checked before any call.
@interface MTLFunctionConstantValues (NBOriginalConstantAccess)
- (NSArray *)newIndexedConstantArray;
- (NSArray *)newNamedConstantArray;
@end
@protocol NBOriginalConstantValue
- (NSUInteger)dataType;
- (void *)data;
- (NSUInteger)index;
- (NSString *)name;
@end
static bool methodABI(id object,SEL selector,const char *encoding) {
 Method method=class_getInstanceMethod(object_getClass(object),selector);
 return method && !strcmp(method_getTypeEncoding(method),encoding);
}
// Bytes of a function constant of MTLDataType `type`: lanes packed tightly, as metal2vulkan takes them (its CLI: bool3 = 3 bytes).
// 3-wide vectors added for iOS 16, whose QuartzCore specialises fixed_frag with uchar3 fc_color_opcodes0/1 (MTLDataTypeUChar3).
static uint64_t constantBytes(uint64_t type) {
 switch(type) {
  case 5:case 31:case 35:return 12;	/* float3, int3, uint3 */
  case 18:case 39:case 43:return 6;	/* half3, short3, ushort3 */
  case 47:case 51:case 55:return 3;	/* char3, uchar3, bool3 */
  case 83:case 87:return 24;		/* long3, ulong3 */
  case 3:case 29:case 33:return 4;
  case 4:case 30:case 34:return 8;
  case 6:case 32:case 36:return 16;
  case 16:case 37:case 41:return 2;
  case 17:case 38:case 42:return 4;
  case 19:case 40:case 44:return 8;
  case 45:case 49:case 53:return 1;
  case 46:case 50:case 54:return 2;
  case 48:case 52:case 56:return 4;
  case 81:case 85:return 8;
  case 82:case 86:return 16;
  case 84:case 88:return 32;
  default:return 0;
 }
}
static std::string quartzCoreCallers();
@implementation NBLibrary
- (void)dealloc {nmb_library_release(_handle);}
- (void)computeLibraryHash:(const void *)bytes length:(size_t)length {
 if(bytes && length) {
  CC_SHA256(bytes,(CC_LONG)(length>0x40000000u?0x40000000u:length),_libraryHash);
 } else {
  const uintptr_t tag=(uintptr_t)self;
  CC_SHA256(&tag,(CC_LONG)sizeof tag,_libraryHash);
 }
}
- (const void *)libraryId {return _libraryHash;}
- (NSData *)bitCodeWithHash:(const void *)hash {(void)hash;return nil;}
- (id<MTLFunction>)makeFunctionWithName:(NSString *)name specializedName:(NSString *)specializedName options:(MTLFunctionOptions)options
                         constantValues:(MTLFunctionConstantValues *)values error:(NSError **)error {
 if(!name){if(error)*error=nbError(@"a function name is required");return nil;}
 MTLFunctionConstantValues *snapshot=nil;
 NSArray *indexed=nil,*named=nil;
 std::vector<NmbConstant> constants;
 if(values) {
  if(!methodABI(values,@selector(newIndexedConstantArray),"@16@0:8") || !methodABI(values,@selector(newNamedConstantArray),"@16@0:8")) {
   NBLOG(@"native-metal: %@: unqualified function constant values (%s)",name,object_getClassName(values));
   if(error)*error=nbError(@"unqualified function constant values");return nil;
  }
  snapshot=[values copy];
  indexed=[snapshot newIndexedConstantArray];named=[snapshot newNamedConstantArray];
  for(unsigned group=0;group<2;group++)for(id value in (group?named:indexed)) {
   if(!methodABI(value,@selector(dataType),"Q16@0:8") || !methodABI(value,@selector(data),"^v16@0:8") ||
      !methodABI(value,group?@selector(name):@selector(index),group?"@16@0:8":"Q16@0:8")) {
    NBLOG(@"native-metal: %@: unqualified constant value ABI (%s)",name,object_getClassName(value));
    if(error)*error=nbError(@"unqualified constant value ABI");return nil;
   }
   id<NBOriginalConstantValue> v=value;
   const uint64_t bytes=constantBytes(v.dataType);
   if(!bytes || !v.data){NBLOG(@"native-metal: %@: constant type %lu is not qualified",name,(unsigned long)v.dataType);
    if(error)*error=nbError([NSString stringWithFormat:@"constant type %lu is not qualified",(unsigned long)v.dataType]);return nil;}
   constants.push_back({v.dataType,group?0:v.index,group?v.name.UTF8String:nullptr,v.data,bytes});
  }
 }
 std::string text;
 if(!gJournalPath.empty()) {
  for(const NmbConstant &c:constants) {
   char head[32];if(!c.name)snprintf(head,sizeof head,"#%llu",(unsigned long long)c.index);
   text+=text.empty()?"":" ";text+=c.name?c.name:head;snprintf(head,sizeof head,":%llu:",(unsigned long long)c.type);text+=head;
   for(uint64_t i=0;i<c.length;i++){snprintf(head,sizeof head,"%02x",((const uint8_t *)c.bytes)[i]);text+=head;}
  }
 }
 const char *sname=specializedName.length?specializedName.UTF8String:nullptr;
 const uint64_t functionBegan=nowUs();
 NmbFunction *handle=nmb_function_new_with_descriptor(_handle,name.UTF8String,sname,(uint64_t)options,constants.data(),(uint32_t)constants.size(),values!=nil);
 gTimeFunction.add(functionBegan);
 (void)indexed;(void)named;(void)snapshot;
 // One S line per specialization (int-155: every QuartzCore pipeline was made on its draw, and a refused generic function would leave its
 // generic pipeline unmade without a word): the function, its constants, the time, the refusal and QuartzCore's callers.
 if((values || sname || options) && !gJournalPath.empty()) {
  char head[96];snprintf(head,sizeof head,"S t=%llu us=%llu ok=%d name=",(unsigned long long)((functionBegan-gJournalBegan)/1000),
      (unsigned long long)(nowUs()-functionBegan),handle?1:0);
  std::string desc=std::string(name.UTF8String?:"?");
  if(sname){desc+="->";desc+=sname;}
  journal(head+desc+" k="+text+(handle?std::string():" err="+std::string(lastError().UTF8String?:"?"))+" | "+quartzCoreCallers());
 }
 if(!handle){
  if(values || sname || options)noteProblem([NSString stringWithFormat:@"specialized function %@: %@",name,lastError()]);
  if(error)*error=nbError([NSString stringWithFormat:@"function %@: %@",name,lastError()]);return nil;
 }
 NBFunction *function=[NBFunction new];function.handle=handle;function.name=specializedName.length?specializedName:name;function.options=options;
 function.functionType=(MTLFunctionType)nmb_function_type(handle);function.constantsText=text;
 [function computeBitCodeHashWithLibrary:_libraryHash originalName:name.UTF8String specializedName:sname constants:constants.data() count:constants.size()];
 if(error)*error=nil;return (id<MTLFunction>)function;
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values error:(NSError **)error {
 if(!name || !values) {
  NBLOG(@"native-metal: %@: unqualified function constant values (%s)",name,values?object_getClassName(values):"nil");
  if(error)*error=nbError(@"unqualified function constant values");return nil;
 }
 return [self makeFunctionWithName:name specializedName:nil options:MTLFunctionOptionNone constantValues:values error:error];
}
- (void)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values completionHandler:(void (^)(id<MTLFunction>,NSError *))handler {
 NSError *error=nil;id<MTLFunction> function=[self newFunctionWithName:name constantValues:values error:&error];
 if(handler)handler(function,error);
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values pipelineLibrary:(id)pipelineLibrary error:(NSError **)error {
 (void)pipelineLibrary;
 return [self makeFunctionWithName:name specializedName:nil options:MTLFunctionOptionNone constantValues:values error:error];
}
- (void)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values pipelineLibrary:(id)pipelineLibrary completionHandler:(void (^)(id<MTLFunction>,NSError *))handler {
 NSError *error=nil;id<MTLFunction> function=[self newFunctionWithName:name constantValues:values pipelineLibrary:pipelineLibrary error:&error];
 if(handler)handler(function,error);
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values functionCache:(id)cache error:(NSError **)error {
 (void)cache;
 return [self makeFunctionWithName:name specializedName:nil options:MTLFunctionOptionNone constantValues:values error:error];
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values functionCache:(id)cache specializedName:(NSString *)specializedName error:(NSError **)error {
 (void)cache;
 return [self makeFunctionWithName:name specializedName:specializedName options:MTLFunctionOptionNone constantValues:values error:error];
}
- (void)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)values functionCache:(id)cache specializedName:(NSString *)specializedName completionHandler:(void (^)(id<MTLFunction>,NSError *))handler {
 NSError *error=nil;id<MTLFunction> function=[self newFunctionWithName:name constantValues:values functionCache:cache specializedName:specializedName error:&error];
 if(handler)handler(function,error);
}
- (MTLLibraryType)type {return MTLLibraryTypeExecutable;}
- (id<MTLFunction>)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d error:(NSError **)error {
 if(!d){if(error)*error=nbError(@"a function descriptor is required");return nil;}
 return [self makeFunctionWithName:d.name specializedName:d.specializedName options:d.options constantValues:d.constantValues error:error];
}
- (void)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d completionHandler:(void (^)(id<MTLFunction>,NSError *))handler {
 NSError *error=nil;id<MTLFunction> function=[self newFunctionWithDescriptor:d error:&error];
 if(handler)handler(function,error);
}
- (id<MTLFunction>)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d destinationArchive:(id<MTLBinaryArchive>)archive error:(NSError **)error {
 (void)archive;
 return [self newFunctionWithDescriptor:d error:error];
}
- (void)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d destinationArchive:(id<MTLBinaryArchive>)archive completionHandler:(void (^)(id<MTLFunction>,NSError *))handler {
 (void)archive;
 [self newFunctionWithDescriptor:d completionHandler:handler];
}
- (NSArray<NSString *> *)functionNames {
 NSMutableArray *names=[NSMutableArray array];
 for(uint32_t i=0,n=nmb_library_function_count(_handle);i<n;i++) {
  char name[256];nmb_library_function_name(_handle,i,name,sizeof name);[names addObject:[NSString stringWithUTF8String:name]];
 }
 return names;
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name {
 const uint64_t functionBegan=nowUs();
 NmbFunction *handle=name?nmb_function_new(_handle,name.UTF8String):nullptr;gTimeFunction.add(functionBegan);
 if(!handle)return nil;
 NBFunction *function=[NBFunction new];function.handle=handle;function.name=name;function.functionType=(MTLFunctionType)nmb_function_type(handle);
 [function computeBitCodeHashWithLibrary:_libraryHash originalName:name.UTF8String specializedName:nullptr constants:nullptr count:0];
 return (id<MTLFunction>)function;
}
- (id<MTLFunction>)nb_newFunctionWithZeroConstants:(NSString *)name {
 id<MTLFunction> fn=[self newFunctionWithName:name];
 if(fn || !name)return fn;
 const uint64_t functionBegan=nowUs();
 NmbFunction *handle=nmb_function_new_with_descriptor(_handle,name.UTF8String,nullptr,0,nullptr,0,true);
 gTimeFunction.add(functionBegan);
 if(!handle)return nil;
 NBFunction *function=[NBFunction new];function.handle=handle;function.name=name;function.functionType=(MTLFunctionType)nmb_function_type(handle);
 [function computeBitCodeHashWithLibrary:_libraryHash originalName:name.UTF8String specializedName:nullptr constants:nullptr count:0];
 return (id<MTLFunction>)function;
}
@end
@interface NBComputePipeline : NBObject
@property(nonatomic) NmbComputePipeline *handle;
@end
@implementation NBComputePipeline
- (void)dealloc {nmb_compute_pipeline_release(_handle);}
- (NSUInteger)maxTotalThreadsPerThreadgroup {return nmb_compute_pipeline_max_threads(_handle);}
- (NSUInteger)threadExecutionWidth {return nmb_compute_pipeline_execution_width(_handle);}
- (NSUInteger)staticThreadgroupMemoryLength {return nmb_compute_pipeline_static_threadgroup_memory(_handle);}
- (MTLSize)requiredThreadsPerThreadgroup {
 uint64_t s[3]={};nmb_compute_pipeline_required_threads(_handle,s);
 return MTLSizeMake(s[0],s[1],s[2]);
}
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)d {(void)d;return 0;}
- (BOOL)supportIndirectCommandBuffers {return NO;}
- (NSUInteger)allocatedSize {return 0;}
- (NSInteger)shaderValidation {return 0;}
- (MTLResourceID)gpuResourceID {return sweetResourceID(_handle);}
- (uint64_t)gpuHandle {return (uint64_t)(uintptr_t)_handle;}
- (NSUInteger)resourceIndex {return 0;}
- (NSUInteger)uniqueIdentifier {return (NSUInteger)(uintptr_t)_handle;}
@end
@interface NBRenderPipeline : NBObject
@property(nonatomic) NmbRenderPipeline *handle;
@end
@implementation NBRenderPipeline
- (void)dealloc {nmb_render_pipeline_release(_handle);}
// The threadgroup size a tile dispatch of this pipeline could use: the device's limit (no tile shaders are offered).
- (NSUInteger)maxTotalThreadsPerThreadgroup {
 uint64_t s[3]={};if(!nmb_device_max_threads_per_threadgroup(gDevice,s))return 0;
 return s[0];
}
- (BOOL)threadgroupSizeMatchesTileSize {return NO;}
- (NSUInteger)imageblockSampleLength {return 0;}
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)d {(void)d;return 0;}
- (BOOL)supportIndirectCommandBuffers {return NO;}
- (NSUInteger)allocatedSize {return 0;}
- (NSInteger)shaderValidation {return 0;}
- (MTLResourceID)gpuResourceID {return sweetResourceID(_handle);}
- (uint64_t)gpuHandle {return (uint64_t)(uintptr_t)_handle;}
- (NSUInteger)resourceIndex {return 0;}
- (NSUInteger)uniqueIdentifier {return (NSUInteger)(uintptr_t)_handle;}
@end
@interface NBSampler : NBObject
@property(nonatomic) NmbSampler *handle;
@end
@implementation NBSampler
- (void)dealloc {nmb_sampler_release(_handle);}
- (NSUInteger)pixelFormat {return MTLPixelFormatInvalid;}   // SPI: a sampler built from a plain descriptor names no format
- (MTLResourceID)gpuResourceID {return sweetResourceID(_handle);}
- (uint64_t)gpuAddress {return 0;}
- (uint64_t)gpuHandle {return (uint64_t)(uintptr_t)_handle;}
- (NSUInteger)resourceIndex {return 0;}
- (NSUInteger)uniqueIdentifier {return (NSUInteger)(uintptr_t)_handle;}
@end
@interface NBDepthStencil : NBObject
@property(nonatomic) NmbDepthStencil *handle;
@property(nonatomic) BOOL readsDepth,writesDepth,readsStencil,writesStencil;
@end
@implementation NBDepthStencil
- (void)dealloc {nmb_depth_stencil_release(_handle);}
- (MTLResourceID)gpuResourceID {return sweetResourceID(_handle);}
- (NSUInteger)resourceIndex {return 0;}
- (NSUInteger)uniqueIdentifier {return (NSUInteger)(uintptr_t)_handle;}
@end

// ---- events and fences ----
@interface NBEvent : NBObject
@property(nonatomic) NmbEvent *handle;
@end
@implementation NBEvent
- (void)dealloc {nmb_event_release(_handle);}
@end
@interface NBSharedEvent : NBEvent
@end
static void notified(void *context,uint64_t value);
@implementation NBSharedEvent
- (uint64_t)signaledValue {return nmb_shared_event_value(self.handle);}
- (void)setSignaledValue:(uint64_t)value {nmb_shared_event_set_value(self.handle,value);}
- (BOOL)waitUntilSignaledValue:(uint64_t)value timeoutMS:(uint64_t)milliseconds {return nmb_shared_event_wait(self.handle,value,milliseconds);}
// The block runs on the listener's dispatch queue (Metal's contract); the bridge's listener thread only forwards it there.
- (void)notifyListener:(MTLSharedEventListener *)listener atValue:(uint64_t)value block:(MTLSharedEventNotificationBlock)block {
 if(!block)return;
 dispatch_queue_t queue=listener.dispatchQueue?:dispatch_get_global_queue(QOS_CLASS_DEFAULT,0);
 NSArray *job=@[self,queue,[block copy]];
 if(!nmb_shared_event_notify(self.handle,value,notified,(__bridge_retained void *)job)) {
  (void)(__bridge_transfer NSArray *)(__bridge void *)job;
  NBLOG(@"native-metal: notifyListener refused: %@",lastError());
 }
}
// A handle for another process needs a kernel-backed event this bridge does not have yet: refused, never a handle that could not work.
- (MTLSharedEventHandle *)newSharedEventHandle {
 if(gMissing)gMissing("NBSharedEvent","newSharedEventHandle (cross-process)");
 return nil;
}
@end
static void notified(void *context,uint64_t value) {
 NSArray *job=(__bridge_transfer NSArray *)context;
 id<MTLSharedEvent> event=job[0];MTLSharedEventNotificationBlock block=job[2];
 dispatch_async(job[1],^{block(event,value);});
}
@interface NBFence : NBObject
@property(nonatomic) NmbFence *handle;
@end
@implementation NBFence
- (void)dealloc {nmb_fence_release(_handle);}
@end

// ---- command buffers and encoders ----
@interface NBQueue : NBObject
@property(nonatomic) NmbQueue *handle;
@property(atomic,strong) dispatch_queue_t completionQueue;   // SPI: where command buffers' handlers run (nil: the runtime's thread)
@property(atomic) int backgroundTrackingPID;
@property(atomic) BOOL skipRender;
@property(atomic) BOOL executionEnabled;
@property(atomic,getter=isProfilingEnabled) BOOL profilingEnabled;
@property(atomic,getter=isStatEnabled) BOOL statEnabled;
@property(atomic) uint64_t statOptions;
@property(atomic) uint64_t statLocations;
@end
@interface NBCommandBuffer : NBObject {
@public
 EncodedWork encodedWork;   // the command buffer's single encoder thread, not global counter deltas
 uint64_t createdUs;
}
@property(nonatomic) NmbCommandBuffer *handle;
@property(nonatomic,strong) NBQueue *queue;
@property(atomic,copy) NSString *encodeFailure;
@property(atomic) BOOL committed,failedLocally;
@property(nonatomic) uint64_t committedUs;
@property(nonatomic) uint32_t commitIndex;
@property(nonatomic,strong) NSMutableArray *scheduledHandlers,*completedHandlers;
@property(nonatomic,strong) NSMutableSet *surfaces,*writtenSurfaces;
// Runtime handles retain GPU storage, but only the Objective-C owner retains
// a no-copy deallocator, its memory owner and texture/heap ancestry.
@property(nonatomic,strong) NSMutableSet *resourceOwners;
@property(nonatomic,strong) dispatch_group_t handlers;
@property(nonatomic,strong) dispatch_group_t schedulingHandlers;
@property(nonatomic) BOOL schedulingDelivered;
@property(nonatomic,strong) NSMutableDictionary *userDict;
- (void)refuse:(NSString *)what;
@end
@interface NBEncoder : NBObject
@property(nonatomic) NmbEncoder *handle;
@property(nonatomic,strong) NBCommandBuffer *commandBuffer;
@property(nonatomic) BOOL refused;
@end
static void waitForResource(id resource) {
 const uint64_t began=nowUs();
 NSArray *pending;@synchronized(gInFlight){pending=gInFlight.allObjects;}
 for(NBCommandBuffer *commandBuffer in pending) {
  int dependency=-1;
  if([resource isKindOfClass:[NBBuffer class]])dependency=nmb_command_buffer_uses_buffer(commandBuffer.handle,[(NBBuffer *)resource handle]);
  else if([resource isKindOfClass:[NBTexture class]])dependency=nmb_command_buffer_uses_texture(commandBuffer.handle,[(NBTexture *)resource handle]);
  gResourceChecks++;
  // An unknown result retains the old conservative wait. False means no matching storage
  // (or GPU work already completed), not a fabricated completion for a pending dependency.
  if(dependency!=0)[(id<MTLCommandBuffer>)commandBuffer waitUntilCompleted];else gResourceSkipped++;
 }
 gTimeResourceWait.add(began);
}
@implementation NBEncoder
- (void)dealloc {if(_handle)nmb_encoder_discard(_handle);}
- (bool)check:(bool)ok what:(const char *)what {
 if(_refused)return false;
 if(!ok)[_commandBuffer refuse:[NSString stringWithFormat:@"%s: %@",what,lastError()]];
 return ok;
}
- (void)endEncoding {
 if(_refused){_refused=NO;return;}
 NmbEncoder *handle=_handle;_handle=nullptr;
 if(!handle){[_commandBuffer refuse:@"endEncoding twice"];return;}
 [self check:nmb_encoder_end(handle) what:"endEncoding"];
}
- (void)insertDebugSignpost:(NSString *)s {(void)s;}
- (void)pushDebugGroup:(NSString *)s {(void)s;}
- (void)popDebugGroup {}
- (void)useResidencySet:(id)residencySet {(void)residencySet;}
- (void)useResidencySets:(const id __unsafe_unretained [])residencySets count:(NSUInteger)count {(void)residencySets;(void)count;}
- (void)barrierAfterQueueStages:(NSUInteger)after beforeStages:(NSUInteger)before {(void)after;(void)before;}
// Stage 0 compute, 1 vertex, 2 fragment (the bridge's numbering).
- (void)buffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset index:(NSUInteger)index stage:(uint32_t)stage {
 if(_refused)return;
 if(buffer && ![(id)buffer isKindOfClass:[NBBuffer class]]){[_commandBuffer refuse:@"foreign buffer"];return;}
 if(buffer) {
  [_commandBuffer.resourceOwners addObject:buffer];
  if([(NBBuffer *)buffer surfaceOwner]){[_commandBuffer.surfaces addObject:buffer];[_commandBuffer.writtenSurfaces addObject:buffer];}
 }
 [self check:nmb_encoder_set_buffer(_handle,stage,buffer?[(NBBuffer *)buffer handle]:nullptr,offset,(uint32_t)index) what:"setBuffer"];
}
- (void)texture:(id<MTLTexture>)texture index:(NSUInteger)index stage:(uint32_t)stage {
 if(_refused)return;
 if(texture && ![(id)texture isKindOfClass:[NBTexture class]]){[_commandBuffer refuse:@"foreign texture"];return;}
 if(texture)[_commandBuffer.resourceOwners addObject:texture];
 if(texture && [(NBTexture *)texture surface]) {
  NBTexture *t=(NBTexture *)texture;
  [_commandBuffer.surfaces addObject:t];
  const MTLTextureUsage u=t.usage;
  if(!u || (u&MTLTextureUsageShaderWrite))[_commandBuffer.writtenSurfaces addObject:t];
 }
 [self check:nmb_encoder_set_texture(_handle,stage,texture?[(NBTexture *)texture handle]:nullptr,(uint32_t)index) what:"setTexture"];
}
- (void)sampler:(id<MTLSamplerState>)sampler index:(NSUInteger)index stage:(uint32_t)stage {
 if(_refused)return;
 if(sampler && ![(id)sampler isKindOfClass:[NBSampler class]]){[_commandBuffer refuse:@"foreign sampler"];return;}
 if(sampler)[_commandBuffer.resourceOwners addObject:sampler];
 [self check:nmb_encoder_set_sampler(_handle,stage,sampler?[(NBSampler *)sampler handle]:nullptr,(uint32_t)index) what:"setSamplerState"];
}
- (void)bytes:(const void *)bytes length:(NSUInteger)length index:(NSUInteger)index stage:(uint32_t)stage {
 if(_refused)return;
 [self check:nmb_encoder_set_bytes(_handle,stage,bytes,length,(uint32_t)index) what:"setBytes"];
}
- (void)fence:(id<MTLFence>)fence stages:(uint64_t)stages update:(bool)update {
 if(_refused)return;
 if(![(id)fence isKindOfClass:[NBFence class]]){[_commandBuffer refuse:@"foreign fence"];return;}
 [_commandBuffer.resourceOwners addObject:fence];
 NmbFence *handle=[(NBFence *)fence handle];
 [self check:update?nmb_encoder_update_fence(_handle,handle,stages):nmb_encoder_wait_fence(_handle,handle,stages) what:update?"updateFence":"waitForFence"];
}
- (void)retainUsedResource:(id)r usage:(MTLResourceUsage)u {
 if(!r)return;
 [_commandBuffer.resourceOwners addObject:r];
 if(([r isKindOfClass:[NBTexture class]] && [(NBTexture *)r surface]) ||
    ([r isKindOfClass:[NBBuffer class]] && [(NBBuffer *)r surfaceOwner])) {
  [_commandBuffer.surfaces addObject:r];
  if(u&MTLResourceUsageWrite)[_commandBuffer.writtenSurfaces addObject:r];
 }
}
- (void)updateFence:(id<MTLFence>)fence {[self fence:fence stages:0 update:true];}
- (void)waitForFence:(id<MTLFence>)fence {[self fence:fence stages:0 update:false];}
- (void)offset:(NSUInteger)offset index:(NSUInteger)index stage:(uint32_t)stage {
 if(_refused)return;
 [self check:nmb_encoder_set_buffer_offset(_handle,stage,offset,(uint32_t)index) what:"setBufferOffset"];
}
@end

@interface NBComputeEncoder : NBEncoder
@end
@implementation NBComputeEncoder
- (MTLDispatchType)dispatchType {return MTLDispatchTypeSerial;}
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state {
 if(self.refused)return;
 if(![(id)state isKindOfClass:[NBComputePipeline class]]){[self.commandBuffer refuse:@"foreign compute pipeline"];return;}
 [self.commandBuffer.resourceOwners addObject:state];
 [self check:nmb_compute_set_pipeline(self.handle,[(NBComputePipeline *)state handle]) what:"setComputePipelineState"];
}
- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {[self buffer:b offset:o index:i stage:0];}
- (void)setBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {[self offset:o index:i stage:0];}
- (void)setBuffers:(const id<MTLBuffer> __unsafe_unretained [])b offsets:(const NSUInteger [])o withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self buffer:b[k] offset:o[k] index:r.location+k stage:0];
}
- (void)setBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i {[self bytes:p length:n index:i stage:0];}
- (void)setTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {[self texture:t index:i stage:0];}
- (void)setTextures:(const id<MTLTexture> __unsafe_unretained [])t withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self texture:t[k] index:r.location+k stage:0];
}
- (void)setSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i {[self sampler:s index:i stage:0];}
- (void)setSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])s withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self sampler:s[k] index:r.location+k stage:0];
}
- (void)setSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)lo lodMaxClamp:(float)hi atIndex:(NSUInteger)i {
 (void)lo;(void)hi;[self sampler:s index:i stage:0];
}
- (void)setSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])s lodMinClamps:(const float [])lo lodMaxClamps:(const float [])hi withRange:(NSRange)r {
 (void)lo;(void)hi;[self setSamplerStates:s withRange:r];
}
- (void)setThreadgroupMemoryLength:(NSUInteger)n atIndex:(NSUInteger)i {
 if(self.refused)return;
 [self check:nmb_compute_set_threadgroup_memory(self.handle,(uint32_t)n,(uint32_t)i) what:"setThreadgroupMemoryLength"];
}
- (void)dispatch:(MTLSize)size group:(MTLSize)group threads:(bool)threads {
 if(self.refused)return;
 gDispatches++;self.commandBuffer->encodedWork.dispatches++;
 const uint64_t s[3]={size.width,size.height,size.depth},g[3]={group.width,group.height,group.depth};
 [self check:nmb_compute_dispatch(self.handle,s,g,threads) what:"dispatch"];
}
- (void)dispatchThreads:(MTLSize)t threadsPerThreadgroup:(MTLSize)g {[self dispatch:t group:g threads:true];}
- (void)dispatchThreadgroups:(MTLSize)t threadsPerThreadgroup:(MTLSize)g {[self dispatch:t group:g threads:false];}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u {[self retainUsedResource:r usage:u];}
- (void)useResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)c usage:(MTLResourceUsage)u {
 for(NSUInteger i=0;i<c && r;i++)[self retainUsedResource:r[i] usage:u];
}
- (void)useHeap:(id<MTLHeap>)h {if(h)[self.commandBuffer.resourceOwners addObject:h];}
- (void)useHeaps:(const id<MTLHeap> __unsafe_unretained [])h count:(NSUInteger)c {
 for(NSUInteger i=0;i<c && h;i++)if(h[i])[self.commandBuffer.resourceOwners addObject:h[i]];
}
- (void)memoryBarrierWithScope:(MTLBarrierScope)s {(void)s;}
- (void)memoryBarrierWithResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)c {(void)r;(void)c;}
- (void)setStageInRegion:(MTLRegion)r {(void)r;}
- (void)setImageblockWidth:(NSUInteger)w height:(NSUInteger)h {(void)w;(void)h;}
@end

@interface NBRenderEncoder : NBEncoder
@end
@implementation NBRenderEncoder
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)state {
 if(self.refused)return;
 if(![(id)state isKindOfClass:[NBRenderPipeline class]]){[self.commandBuffer refuse:@"foreign render pipeline"];return;}
 [self.commandBuffer.resourceOwners addObject:state];
 [self check:nmb_render_set_pipeline(self.handle,[(NBRenderPipeline *)state handle]) what:"setRenderPipelineState"];
}
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {[self buffer:b offset:o index:i stage:1];}
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i {[self buffer:b offset:o index:i stage:2];}
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {[self offset:o index:i stage:1];}
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {[self offset:o index:i stage:2];}
- (void)setVertexBuffers:(const id<MTLBuffer> __unsafe_unretained [])b offsets:(const NSUInteger [])o withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self buffer:b[k] offset:o[k] index:r.location+k stage:1];
}
- (void)setFragmentBuffers:(const id<MTLBuffer> __unsafe_unretained [])b offsets:(const NSUInteger [])o withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self buffer:b[k] offset:o[k] index:r.location+k stage:2];
}
- (void)setVertexBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i {[self bytes:p length:n index:i stage:1];}
- (void)setFragmentBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i {[self bytes:p length:n index:i stage:2];}
- (void)setVertexTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {[self texture:t index:i stage:1];}
- (void)setVertexTextures:(const id<MTLTexture> __unsafe_unretained [])t withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self texture:t[k] index:r.location+k stage:1];
}
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {[self texture:t index:i stage:2];}
- (void)setFragmentTextures:(const id<MTLTexture> __unsafe_unretained [])t withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self texture:t[k] index:r.location+k stage:2];
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i {[self sampler:s index:i stage:1];}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i {[self sampler:s index:i stage:2];}
- (void)setVertexSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])s withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self sampler:s[k] index:r.location+k stage:1];
}
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])s withRange:(NSRange)r {
 for(NSUInteger k=0;k<r.length;k++)[self sampler:s[k] index:r.location+k stage:2];
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)lo lodMaxClamp:(float)hi atIndex:(NSUInteger)i {
 (void)lo;(void)hi;[self sampler:s index:i stage:1];
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)lo lodMaxClamp:(float)hi atIndex:(NSUInteger)i {
 (void)lo;(void)hi;[self sampler:s index:i stage:2];
}
- (void)setVertexSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])s lodMinClamps:(const float [])lo lodMaxClamps:(const float [])hi withRange:(NSRange)r {
 (void)lo;(void)hi;[self setVertexSamplerStates:s withRange:r];
}
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> __unsafe_unretained [])s lodMinClamps:(const float [])lo lodMaxClamps:(const float [])hi withRange:(NSRange)r {
 (void)lo;(void)hi;[self setFragmentSamplerStates:s withRange:r];
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)state {
 if(self.refused)return;
 if(state && ![(id)state isKindOfClass:[NBDepthStencil class]]){[self.commandBuffer refuse:@"foreign depth/stencil state"];return;}
 if(state)[self.commandBuffer.resourceOwners addObject:state];
 [self check:nmb_render_set_depth_stencil(self.handle,state?[(NBDepthStencil *)state handle]:nullptr) what:"setDepthStencilState"];
}
- (void)setViewport:(MTLViewport)v {
 if(self.refused)return;
 const double values[6]={v.originX,v.originY,v.width,v.height,v.znear,v.zfar};
 [self check:nmb_render_set_viewport(self.handle,values) what:"setViewport"];
}
- (void)setViewports:(const MTLViewport *)v count:(NSUInteger)c {if(v && c)[self setViewport:v[0]];}
- (void)setScissorRect:(MTLScissorRect)r {
 if(self.refused)return;
 const uint64_t values[4]={r.x,r.y,r.width,r.height};
 [self check:nmb_render_set_scissor(self.handle,values) what:"setScissorRect"];
}
- (void)setScissorRects:(const MTLScissorRect *)r count:(NSUInteger)c {if(r && c)[self setScissorRect:r[0]];}
- (void)setDepthClipMode:(MTLDepthClipMode)mode {(void)mode;}
- (void)setColorStoreAction:(MTLStoreAction)sa atIndex:(NSUInteger)i {(void)sa;(void)i;}
- (void)setDepthStoreAction:(MTLStoreAction)sa {(void)sa;}
- (void)setStencilStoreAction:(MTLStoreAction)sa {(void)sa;}
// The runtime takes cull mode, winding and fill mode together; this encoder keeps Metal's defaults until each is set.
- (void)raster {
 if(self.refused)return;
 NSNumber *cull=objc_getAssociatedObject(self,"cull"),*winding=objc_getAssociatedObject(self,"winding"),*fill=objc_getAssociatedObject(self,"fill");
 [self check:nmb_render_set_raster(self.handle,cull.unsignedLongLongValue,winding.unsignedLongLongValue,fill.unsignedLongLongValue) what:"raster state"];
}
- (void)setCullMode:(MTLCullMode)m {objc_setAssociatedObject(self,"cull",@(m),OBJC_ASSOCIATION_RETAIN);[self raster];}
- (void)setFrontFacingWinding:(MTLWinding)w {objc_setAssociatedObject(self,"winding",@(w),OBJC_ASSOCIATION_RETAIN);[self raster];}
- (void)setTriangleFillMode:(MTLTriangleFillMode)f {objc_setAssociatedObject(self,"fill",@(f),OBJC_ASSOCIATION_RETAIN);[self raster];}
- (void)setDepthBias:(float)bias slopeScale:(float)slope clamp:(float)clamp {
 if(self.refused)return;
 [self check:nmb_render_set_depth_bias(self.handle,bias,slope,clamp) what:"setDepthBias"];
}
- (void)setLineWidth:(float)width {if(self.refused)return;[self check:nmb_render_set_line_width(self.handle,width) what:"setLineWidth"];}
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode offset:(NSUInteger)offset {
 if(self.refused)return;
 [self check:nmb_render_set_visibility_mode(self.handle,mode,offset) what:"setVisibilityResultMode"];
}
- (void)setFragmentTexture:(id<MTLTexture>)t atTextureIndex:(NSUInteger)ti samplerState:(id<MTLSamplerState>)s atSamplerIndex:(NSUInteger)si {
 [self texture:t index:ti stage:2];[self sampler:s index:si stage:2];
}
// Tile shaders and imageblock tile memory (Apple GPU families 4 and up) are not offered: supportsTileShaders answers no, and a call that
// reaches one anyway fails its command buffer.
- (NSUInteger)tileWidth {return 0;}
- (NSUInteger)tileHeight {return 0;}
- (void)setTileTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i {(void)t;(void)i;if(self.refused)return;[self.commandBuffer refuse:@"tile shaders are not supported"];}
- (void)setTileBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i {(void)p;(void)n;(void)i;if(self.refused)return;[self.commandBuffer refuse:@"tile shaders are not supported"];}
- (void)dispatchThreadsPerTile:(MTLSize)size {(void)size;if(self.refused)return;[self.commandBuffer refuse:@"tile shaders are not supported"];}
- (void)dispatchThreadsPerTile:(MTLSize)size inRegion:(MTLRegion)region {(void)size;(void)region;if(self.refused)return;[self.commandBuffer refuse:@"tile shaders are not supported"];}
- (void)setStencilReferenceValue:(uint32_t)v {if(self.refused)return;[self check:nmb_render_set_stencil_reference(self.handle,v,v) what:"setStencilReferenceValue"];}
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b {
 if(self.refused)return;
 [self check:nmb_render_set_stencil_reference(self.handle,f,b) what:"setStencilReferenceValues"];
}
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a {
 if(self.refused)return;
 const float c[4]={r,g,b,a};[self check:nmb_render_set_blend_color(self.handle,c) what:"setBlendColor"];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n instanceCount:(NSUInteger)i baseInstance:(NSUInteger)b {
 if(self.refused)return;
 gDraws++;self.commandBuffer->encodedWork.draws++;
 [self check:nmb_render_draw(self.handle,t,(uint32_t)s,(uint32_t)n,(uint32_t)i,(uint32_t)b) what:"drawPrimitives"];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n instanceCount:(NSUInteger)i {
 [self drawPrimitives:t vertexStart:s vertexCount:n instanceCount:i baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n {
 [self drawPrimitives:t vertexStart:s vertexCount:n instanceCount:1 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)k indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o
                instanceCount:(NSUInteger)i baseVertex:(NSInteger)v baseInstance:(NSUInteger)bi {
 if(self.refused)return;
 if(![(id)b isKindOfClass:[NBBuffer class]]){[self.commandBuffer refuse:@"foreign index buffer"];return;}
 [self.commandBuffer.resourceOwners addObject:b];
 gDraws++;self.commandBuffer->encodedWork.draws++;
 [self check:nmb_render_draw_indexed(self.handle,t,(uint32_t)n,k,[(NBBuffer *)b handle],o,(uint32_t)i,(int32_t)v,(uint32_t)bi) what:"drawIndexedPrimitives"];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)k indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o
                instanceCount:(NSUInteger)i {
 [self drawIndexedPrimitives:t indexCount:n indexType:k indexBuffer:b indexBufferOffset:o instanceCount:i baseVertex:0 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexCount:(NSUInteger)n indexType:(MTLIndexType)k indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o {
 [self drawIndexedPrimitives:t indexCount:n indexType:k indexBuffer:b indexBufferOffset:o instanceCount:1 baseVertex:0 baseInstance:0];
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u {[self retainUsedResource:r usage:u];}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u stages:(MTLRenderStages)s {(void)s;[self retainUsedResource:r usage:u];}
- (void)useResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)c usage:(MTLResourceUsage)u {
 for(NSUInteger i=0;i<c && r;i++)[self retainUsedResource:r[i] usage:u];
}
- (void)useResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)c usage:(MTLResourceUsage)u stages:(MTLRenderStages)s {
 (void)s;for(NSUInteger i=0;i<c && r;i++)[self retainUsedResource:r[i] usage:u];
}
- (void)useHeap:(id<MTLHeap>)h {if(h)[self.commandBuffer.resourceOwners addObject:h];}
- (void)useHeap:(id<MTLHeap>)h stages:(MTLRenderStages)s {(void)s;if(h)[self.commandBuffer.resourceOwners addObject:h];}
- (void)useHeaps:(const id<MTLHeap> __unsafe_unretained [])h count:(NSUInteger)c {
 for(NSUInteger i=0;i<c && h;i++)if(h[i])[self.commandBuffer.resourceOwners addObject:h[i]];
}
- (void)useHeaps:(const id<MTLHeap> __unsafe_unretained [])h count:(NSUInteger)c stages:(MTLRenderStages)s {
 (void)s;for(NSUInteger i=0;i<c && h;i++)if(h[i])[self.commandBuffer.resourceOwners addObject:h[i]];
}
- (void)memoryBarrierWithScope:(MTLBarrierScope)s afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before {(void)s;(void)after;(void)before;}
- (void)memoryBarrierWithResources:(const id<MTLResource> __unsafe_unretained [])r count:(NSUInteger)c afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before {(void)r;(void)c;(void)after;(void)before;}
- (void)updateFence:(id<MTLFence>)fence afterStages:(MTLRenderStages)stages {[self fence:fence stages:stages update:true];}
- (void)waitForFence:(id<MTLFence>)fence beforeStages:(MTLRenderStages)stages {[self fence:fence stages:stages update:false];}
@end

@interface NBBlitEncoder : NBEncoder
@end
@implementation NBBlitEncoder
// The arguments are passed as a plain array: an NSArray literal raises on a nil element, and a nil resource (a refused allocation) must fail the
// command buffer like any invalid argument, not abort the host process.
#define NB_OBJECTS(...) ((__unsafe_unretained id[]){__VA_ARGS__})
- (bool)buffers:(__unsafe_unretained id *)objects count:(size_t)count {
 if(self.refused)return false;
 for(size_t i=0;i<count;i++)if(![objects[i] isKindOfClass:[NBBuffer class]]){[self.commandBuffer refuse:@"missing or foreign blit buffer"];return false;}
 for(size_t i=0;i<count;i++) {
  id o=objects[i];
  [self.commandBuffer.resourceOwners addObject:o];
  if([(NBBuffer *)o surfaceOwner])[self.commandBuffer.surfaces addObject:o];
 }
 return true;
}
- (bool)textures:(__unsafe_unretained id *)objects count:(size_t)count {
 if(self.refused)return false;
 for(size_t i=0;i<count;i++) {
  id o=objects[i];
  if(![o isKindOfClass:[NBTexture class]]){[self.commandBuffer refuse:@"missing or foreign blit texture"];return false;}
  [self.commandBuffer.resourceOwners addObject:o];
  if([(NBTexture *)o surface])[self.commandBuffer.surfaces addObject:o];
 }
 return true;
}
- (void)copyFromBuffer:(id<MTLBuffer>)s sourceOffset:(NSUInteger)so toBuffer:(id<MTLBuffer>)d destinationOffset:(NSUInteger)dO size:(NSUInteger)n {
 if(![self buffers:NB_OBJECTS(s,d) count:2])return;
 if([(NBBuffer *)d surfaceOwner])[self.commandBuffer.writtenSurfaces addObject:d];
 [self check:nmb_blit_copy_buffer(self.handle,[(NBBuffer *)s handle],so,[(NBBuffer *)d handle],dO,n) what:"copyFromBuffer:toBuffer:"];
}
- (void)fillBuffer:(id<MTLBuffer>)b range:(NSRange)r value:(uint8_t)v {
 if(![self buffers:NB_OBJECTS(b) count:1])return;
 if([(NBBuffer *)b surfaceOwner])[self.commandBuffer.writtenSurfaces addObject:b];
 [self check:nmb_blit_fill_buffer(self.handle,[(NBBuffer *)b handle],r.location,r.location+r.length,v) what:"fillBuffer"];
}
- (void)copyFromTexture:(id<MTLTexture>)s sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)z
              toTexture:(id<MTLTexture>)d destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dO {
 if(![self textures:NB_OBJECTS(s,d) count:2])return;
 if([(NBTexture *)d surface])[self.commandBuffer.writtenSurfaces addObject:d];
 const uint64_t a[3]={so.x,so.y,so.z},size[3]={z.width,z.height,z.depth},b[3]={dO.x,dO.y,dO.z};
 [self check:nmb_blit_copy_texture(self.handle,[(NBTexture *)s handle],ss,sl,a,size,[(NBTexture *)d handle],ds,dl,b) what:"copyFromTexture:toTexture:"];
}
- (void)copyFromTexture:(id<MTLTexture>)s toTexture:(id<MTLTexture>)d {
 if(![self textures:NB_OBJECTS(s,d) count:2])return;
 const NSUInteger sMult=(s.textureType==MTLTextureTypeCube || s.textureType==MTLTextureTypeCubeArray)?6:1;
 const NSUInteger dMult=(d.textureType==MTLTextureTypeCube || d.textureType==MTLTextureTypeCubeArray)?6:1;
 const NSUInteger levels=MIN(s.mipmapLevelCount,d.mipmapLevelCount),slices=MIN(s.arrayLength*sMult,d.arrayLength*dMult);
 for(NSUInteger slice=0;slice<slices;slice++)for(NSUInteger level=0;level<levels;level++) {
  MTLSize size=MTLSizeMake(MAX(s.width>>level,(NSUInteger)1),MAX(s.height>>level,(NSUInteger)1),MAX(s.depth>>level,(NSUInteger)1));
  [self copyFromTexture:s sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0) sourceSize:size toTexture:d destinationSlice:slice
       destinationLevel:level destinationOrigin:MTLOriginMake(0,0,0)];
 }
}
- (void)copyFromBuffer:(id<MTLBuffer>)s sourceOffset:(NSUInteger)o sourceBytesPerRow:(NSUInteger)row sourceBytesPerImage:(NSUInteger)image
            sourceSize:(MTLSize)z toTexture:(id<MTLTexture>)d destinationSlice:(NSUInteger)slice destinationLevel:(NSUInteger)level
     destinationOrigin:(MTLOrigin)dO {
 if(![self buffers:NB_OBJECTS(s) count:1] || ![self textures:NB_OBJECTS(d) count:1])return;
 if([(NBTexture *)d surface])[self.commandBuffer.writtenSurfaces addObject:d];
 const uint64_t size[3]={z.width,z.height,z.depth},b[3]={dO.x,dO.y,dO.z};
 [self check:nmb_blit_buffer_to_texture(self.handle,[(NBBuffer *)s handle],o,row,image,size,[(NBTexture *)d handle],slice,level,b) what:"copyFromBuffer:toTexture:"];
}
- (void)copyFromTexture:(id<MTLTexture>)s sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)z
               toBuffer:(id<MTLBuffer>)d destinationOffset:(NSUInteger)o destinationBytesPerRow:(NSUInteger)row destinationBytesPerImage:(NSUInteger)image {
 if(![self textures:NB_OBJECTS(s) count:1] || ![self buffers:NB_OBJECTS(d) count:1])return;
 if([(NBBuffer *)d surfaceOwner])[self.commandBuffer.writtenSurfaces addObject:d];
 const uint64_t a[3]={so.x,so.y,so.z},size[3]={z.width,z.height,z.depth};
 [self check:nmb_blit_texture_to_buffer(self.handle,[(NBTexture *)s handle],slice,level,a,size,[(NBBuffer *)d handle],o,row,image) what:"copyFromTexture:toBuffer:"];
}
- (void)copyFromTexture:(id<MTLTexture>)s sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)z
              toTexture:(id<MTLTexture>)d destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dO
                options:(MTLBlitOption)options {
 (void)options;
 [self copyFromTexture:s sourceSlice:ss sourceLevel:sl sourceOrigin:so sourceSize:z toTexture:d destinationSlice:ds destinationLevel:dl destinationOrigin:dO];
}
// Public whole-subresource range copy, used by the wallpaper renderer. Validate the entire range before encoding
// so an invalid later mip cannot leave a partial copy.
- (void)copyFromTexture:(id<MTLTexture>)s sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
              toTexture:(id<MTLTexture>)d destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl
             sliceCount:(NSUInteger)slices levelCount:(NSUInteger)levels {
 if(![self textures:NB_OBJECTS(s,d) count:2])return;
 NSUInteger sourceSlices=s.arrayLength,destinationSlices=d.arrayLength;
 const bool sourceCube=s.textureType==MTLTextureTypeCube || s.textureType==MTLTextureTypeCubeArray;
 const bool destinationCube=d.textureType==MTLTextureTypeCube || d.textureType==MTLTextureTypeCubeArray;
 if((sourceCube && sourceSlices>NSUIntegerMax/6) || (destinationCube && destinationSlices>NSUIntegerMax/6)) {
  [self.commandBuffer refuse:@"texture copy slice-count overflow"];return;
 }
 if(sourceCube)sourceSlices*=6;
 if(destinationCube)destinationSlices*=6;
 uint32_t sbw=1,sbh=1,sbb=(uint32_t)sweetTexelBytes(s.pixelFormat),dbw=1,dbh=1,dbb=(uint32_t)sweetTexelBytes(d.pixelFormat);
 const bool scmp=sweetBlock(s.pixelFormat,&sbw,&sbh,&sbb),dcmp=sweetBlock(d.pixelFormat,&dbw,&dbh,&dbb);
 const bool sameFootprint=s.pixelFormat==d.pixelFormat || (scmp==dcmp && sbw==dbw && sbh==dbh && sbb==dbb);
 if(ss>sourceSlices || slices>sourceSlices-ss || ds>destinationSlices || slices>destinationSlices-ds ||
    sl>s.mipmapLevelCount || levels>s.mipmapLevelCount-sl || dl>d.mipmapLevelCount || levels>d.mipmapLevelCount-dl ||
    !sameFootprint || s.sampleCount!=d.sampleCount) {
  [self.commandBuffer refuse:@"invalid texture copy subresource range"];return;
 }
 for(NSUInteger level=0;level<levels;level++) {
  const NSUInteger a=sl+level,b=dl+level;
  if(a>=sizeof(NSUInteger)*8 || b>=sizeof(NSUInteger)*8 ||
     MAX(s.width>>a,(NSUInteger)1)!=MAX(d.width>>b,(NSUInteger)1) ||
     MAX(s.height>>a,(NSUInteger)1)!=MAX(d.height>>b,(NSUInteger)1) ||
     MAX(s.depth>>a,(NSUInteger)1)!=MAX(d.depth>>b,(NSUInteger)1)) {
   [self.commandBuffer refuse:@"texture copy mip dimensions differ"];return;
  }
 }
 for(NSUInteger slice=0;slice<slices;slice++)for(NSUInteger level=0;level<levels;level++) {
  const NSUInteger a=sl+level;
  MTLSize size=MTLSizeMake(MAX(s.width>>a,(NSUInteger)1),MAX(s.height>>a,(NSUInteger)1),MAX(s.depth>>a,(NSUInteger)1));
  [self copyFromTexture:s sourceSlice:ss+slice sourceLevel:a sourceOrigin:MTLOriginMake(0,0,0) sourceSize:size
              toTexture:d destinationSlice:ds+slice destinationLevel:dl+level destinationOrigin:MTLOriginMake(0,0,0)];
 }
}
- (void)copyFromBuffer:(id<MTLBuffer>)s sourceOffset:(NSUInteger)o sourceBytesPerRow:(NSUInteger)row sourceBytesPerImage:(NSUInteger)image
            sourceSize:(MTLSize)z toTexture:(id<MTLTexture>)d destinationSlice:(NSUInteger)slice destinationLevel:(NSUInteger)level
     destinationOrigin:(MTLOrigin)dO options:(MTLBlitOption)options {
 (void)options;
 [self copyFromBuffer:s sourceOffset:o sourceBytesPerRow:row sourceBytesPerImage:image sourceSize:z toTexture:d destinationSlice:slice destinationLevel:level destinationOrigin:dO];
}
- (void)copyFromTexture:(id<MTLTexture>)s sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)z
               toBuffer:(id<MTLBuffer>)d destinationOffset:(NSUInteger)o destinationBytesPerRow:(NSUInteger)row destinationBytesPerImage:(NSUInteger)image
                options:(MTLBlitOption)options {
 (void)options;
 [self copyFromTexture:s sourceSlice:slice sourceLevel:level sourceOrigin:so sourceSize:z toBuffer:d destinationOffset:o destinationBytesPerRow:row destinationBytesPerImage:image];
}
- (void)generateMipmapsForTexture:(id<MTLTexture>)t {
 if(![self textures:NB_OBJECTS(t) count:1])return;
 if([(NBTexture *)t surface])[self.commandBuffer.writtenSurfaces addObject:t];
 [self check:nmb_blit_generate_mipmaps(self.handle,[(NBTexture *)t handle]) what:"generateMipmapsForTexture"];
}
- (void)synchronizeResource:(id<MTLResource>)r {(void)r;}
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)t {(void)t;}
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)t slice:(NSUInteger)s level:(NSUInteger)l {(void)t;(void)s;(void)l;}
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)t {(void)t;}
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)t slice:(NSUInteger)s level:(NSUInteger)l {(void)t;(void)s;(void)l;}
@end

static void completed(void *context);
static void scheduled(void *context);
@implementation NBCommandBuffer
- (instancetype)init {
 if((self=[super init])){_scheduledHandlers=[NSMutableArray array];_completedHandlers=[NSMutableArray array];_surfaces=[NSMutableSet set];_writtenSurfaces=[NSMutableSet set];_resourceOwners=[NSMutableSet set];_handlers=dispatch_group_create();_schedulingHandlers=dispatch_group_create();}
 if(self)createdUs=nowUs();
 return self;
}
- (void)dealloc {nmb_command_buffer_release(_handle);}
- (id<MTLCommandQueue>)commandQueue {return (id<MTLCommandQueue>)_queue;}
- (BOOL)retainedReferences {return YES;}
// Protected content is not supported (the runtime's AppleOnlyCall::SetProtectionOptions takes Metal's default only): any other option fails
// the command buffer.
- (uint64_t)protectionOptions {return 0;}
- (void)setProtectionOptions:(uint64_t)options {if(options)[self refuse:[NSString stringWithFormat:@"protection options 0x%llx",options]];}
- (void)refuse:(NSString *)what {
 if(!self.encodeFailure){self.encodeFailure=what;NBLOG(@"native-metal: command buffer refused: %@",what);}
}
- (MTLCommandBufferStatus)status {
 if(self.failedLocally)return MTLCommandBufferStatusError;
 return (MTLCommandBufferStatus)nmb_command_buffer_status(_handle);
}
- (NSError *)error {
 if(self.failedLocally)return nbError(self.encodeFailure);
 if(self.status!=MTLCommandBufferStatusError)return nil;
 char text[512]={};nmb_command_buffer_error(_handle,text,sizeof text);
 return nbError([NSString stringWithUTF8String:text]);
}
// Debug groups and cache hints name work for tools and the driver's caches; they change nothing the GPU computes here.
- (void)pushDebugGroup:(NSString *)name {(void)name;}
- (void)popDebugGroup {}
- (void)useResidencySet:(id)residencySet {(void)residencySet;}
- (void)useResidencySets:(const id __unsafe_unretained [])residencySets count:(NSUInteger)count {(void)residencySets;(void)count;}
- (void)useInternalResidencySet:(id)residencySet {(void)residencySet;}
- (void)useInternalResidencySets:(const id __unsafe_unretained [])residencySets count:(NSUInteger)count {(void)residencySets;(void)count;}
- (void)barrierAfterQueueStages:(NSUInteger)after beforeStages:(NSUInteger)before {(void)after;(void)before;}
- (void)encodeCacheHintTag:(uint64_t)tag resourceGroups:(const id __unsafe_unretained [])groups count:(NSUInteger)count {(void)tag;(void)groups;(void)count;}
- (void)encodeCacheHintFinalize:(uint64_t)tag resourceGroups:(const id __unsafe_unretained [])groups count:(NSUInteger)count {(void)tag;(void)groups;(void)count;}
- (void)dropResourceGroups:(const id __unsafe_unretained [])groups count:(NSUInteger)count {(void)groups;(void)count;}
- (void)setResourceGroups:(const id __unsafe_unretained [])groups count:(NSUInteger)count {(void)groups;(void)count;}
- (void)setResponsibleTaskIDs:(const uint32_t *)ids count:(uint32_t)count {(void)ids;(void)count;}
- (BOOL)isCommitted {return self.committed;}
- (MTLCommandBufferErrorOption)errorOptions {return MTLCommandBufferErrorOptionNone;}
- (id<MTLLogContainer>)logs {return nil;}
- (NSMutableDictionary *)userDictionary {@synchronized(self){if(!_userDict)_userDict=[NSMutableDictionary new];return _userDict;}}
// The kernel driver's own submission times are not recorded: 0 is Metal's answer where they are unavailable.
- (CFTimeInterval)kernelStartTime {return 0;}
- (CFTimeInterval)kernelEndTime {return 0;}
- (BOOL)commitAndWaitUntilSubmitted {[(id<MTLCommandBuffer>)self commit];[self waitUntilScheduled];return !self.failedLocally;}
- (CFTimeInterval)GPUStartTime {return nmb_command_buffer_gpu_time(_handle,false);}
- (CFTimeInterval)GPUEndTime {return nmb_command_buffer_gpu_time(_handle,true);}
- (id)refuseEncoder:(NBEncoder *)encoder why:(NSString *)why {
 [self refuse:why];encoder.refused=YES;encoder.commandBuffer=self;return encoder;
}
- (id)encoder:(NBEncoder *)encoder handle:(NmbEncoder *)handle what:(NSString *)what {
 if(self.committed)return [self refuseEncoder:encoder why:[what stringByAppendingString:@" after commit"]];
 if(!handle)return [self refuseEncoder:encoder why:[NSString stringWithFormat:@"%@: %@",what,lastError()]];
 encoder.handle=handle;encoder.commandBuffer=self;return encoder;
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoder {
 return [self encoder:[NBComputeEncoder new] handle:self.committed?nullptr:nmb_compute_encoder_new(_handle) what:@"computeCommandEncoder"];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)type {
 if(type!=MTLDispatchTypeSerial)return [self refuseEncoder:[NBComputeEncoder new] why:@"concurrent compute dispatch"];
 return [self computeCommandEncoder];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor *)d {
 if(d && d.dispatchType!=MTLDispatchTypeSerial)return [self refuseEncoder:[NBComputeEncoder new] why:@"concurrent compute dispatch"];
 return [self computeCommandEncoder];
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoder {
 gBlits++;encodedWork.blits++;
 return [self encoder:[NBBlitEncoder new] handle:self.committed?nullptr:nmb_blit_encoder_new(_handle) what:@"blitCommandEncoder"];
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor *)d {
 (void)d;
 return [self blitCommandEncoder];
}
// Present after the GPU work completes (no cross-process fence wait between an app's CAMetalLayer draw and backboardd's import).
- (void)presentDrawable:(id<MTLDrawable>)drawable {if(drawable)[self addCompletedHandler:^(id<MTLCommandBuffer>){[drawable present];}];}
- (void)presentDrawable:(id<MTLDrawable>)drawable atTime:(CFTimeInterval)t {if(drawable)[self addCompletedHandler:^(id<MTLCommandBuffer>){[drawable presentAtTime:t];}];}
- (void)presentDrawable:(id<MTLDrawable>)drawable afterMinimumDuration:(CFTimeInterval)d {if(drawable)[self addCompletedHandler:^(id<MTLCommandBuffer>){[drawable presentAfterMinimumDuration:d];}];}
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d {
 NmbRenderPassDescriptor pass={};
 {
  id<MTLTexture> first=d.colorAttachments[0].texture;
  if(first) {
   const uint64_t pixels=(uint64_t)first.width*first.height;
   gPasses++;gPassPixels+=pixels;encodedWork.passes++;encodedWork.pixels+=pixels;
   uint64_t seen=gBiggestPass.load();while(pixels>seen && !gBiggestPass.compare_exchange_weak(seen,pixels)){}
   if(pixels>=2000000)gFullScreenPasses++;
  }
 }
 auto attachment=[&](MTLRenderPassAttachmentDescriptor *a,NmbPassAttachment &out)->bool {
  if(!a.texture)return true;
  if(![(id)a.texture isKindOfClass:[NBTexture class]])return false;
  NBTexture *texture=(NBTexture *)a.texture;if(texture.surface){[_surfaces addObject:texture];[_writtenSurfaces addObject:texture];}
  [_resourceOwners addObject:texture];
  out.texture=texture.handle;out.level=a.level;out.slice=a.slice;out.depth_plane=a.depthPlane;out.load=a.loadAction;out.store=a.storeAction;
  return true;
 };
 for(unsigned i=0;i<8;i++) {
  MTLRenderPassColorAttachmentDescriptor *c=d.colorAttachments[i];
  if(!attachment(c,pass.colors[i]))return [self refuseEncoder:[NBRenderEncoder new] why:@"foreign color attachment"];
  pass.colors[i].clear[0]=c.clearColor.red;pass.colors[i].clear[1]=c.clearColor.green;pass.colors[i].clear[2]=c.clearColor.blue;pass.colors[i].clear[3]=c.clearColor.alpha;
 }
 if(!attachment(d.depthAttachment,pass.depth) || !attachment(d.stencilAttachment,pass.stencil))return [self refuseEncoder:[NBRenderEncoder new] why:@"foreign depth/stencil attachment"];
 pass.depth.clear[0]=d.depthAttachment.clearDepth;pass.stencil.clear[0]=d.stencilAttachment.clearStencil;
 pass.width=d.renderTargetWidth;pass.height=d.renderTargetHeight;pass.array_length=d.renderTargetArrayLength;pass.samples=d.defaultRasterSampleCount;
 if(d.visibilityResultBuffer) {
  if(![(id)d.visibilityResultBuffer isKindOfClass:[NBBuffer class]])return [self refuseEncoder:[NBRenderEncoder new] why:@"foreign visibility result buffer"];
  [_resourceOwners addObject:d.visibilityResultBuffer];
  pass.visibility=[(NBBuffer *)d.visibilityResultBuffer handle];
 }
 return [self encoder:[NBRenderEncoder new] handle:self.committed?nullptr:nmb_render_encoder_new(_handle,&pass) what:@"renderCommandEncoder"];
}
- (void)addScheduledHandler:(MTLCommandBufferHandler)block {if(block)@synchronized(self){[_scheduledHandlers addObject:[block copy]];}}
- (void)addCompletedHandler:(MTLCommandBufferHandler)block {if(block)@synchronized(self){[_completedHandlers addObject:[block copy]];}}
- (void)enqueue {}
- (void)event:(id<MTLEvent>)event value:(uint64_t)value signal:(bool)signal {
 if(![(id)event isKindOfClass:[NBEvent class]]){[self refuse:@"foreign event"];return;}
 if(self.committed){[self refuse:@"event encoded after commit"];return;}
 [_resourceOwners addObject:event];
 NmbEvent *handle=[(NBEvent *)event handle];
 if(!(signal?nmb_command_buffer_signal_event(_handle,handle,value):nmb_command_buffer_wait_event(_handle,handle,value)))
  [self refuse:[NSString stringWithFormat:@"%s: %@",signal?"encodeSignalEvent":"encodeWaitForEvent",lastError()]];
}
- (void)encodeSignalEvent:(id<MTLEvent>)event value:(uint64_t)value {[self event:event value:value signal:true];}
- (void)encodeSignalEvent:(id<MTLEvent>)event value:(uint64_t)value agentMask:(uint64_t)mask {(void)mask;[self event:event value:value signal:true];}
- (void)encodeSignalEventScheduled:(id<MTLEvent>)event value:(uint64_t)value {[self event:event value:value signal:true];}
- (void)encodeWaitForEvent:(id<MTLEvent>)event value:(uint64_t)value {[self event:event value:value signal:false];}
- (void)encodeWaitForEvent:(id<MTLEvent>)event value:(uint64_t)value timeout:(uint32_t)timeout {(void)timeout;[self event:event value:value signal:false];}
// The runtime has submitted the work. Deliver scheduling without waiting for GPU completion.
- (void)didSchedule {
 {
  const uint64_t took=nowUs()-self.committedUs;
  std::lock_guard<std::mutex> lock(gCommitLock);
  CommitRecord &r=gCommitRing[self.commitIndex%32];
  if(r.index==self.commitIndex)r.scheduledUs=took;
 }
 NSArray *handlers;
 @synchronized(self){
  _schedulingDelivered=YES;handlers=[_scheduledHandlers copy];[_scheduledHandlers removeAllObjects];
 }
 void (^run)(void)=^{
  for(MTLCommandBufferHandler block in handlers)block((id<MTLCommandBuffer>)self);
  dispatch_group_leave(self->_schedulingHandlers);
 };
 // Run on the runtime's scheduled-handler thread, preserving its ordering and own-wait
 // deadlock checks. The queue's completionQueue routes completed handlers only.
 run();
}
// After completion (or a refusal): invalidate the CPU's view of GPU-written imported surfaces, then completed handlers, once.
- (void)finish {
 if(!self.failedLocally)flushSurfaces(_writtenSurfaces);
 // Actual GPU completion (or a local refusal that never submitted) is the
 // release point. A retained completed command must not pin every old frame.
 [_surfaces removeAllObjects];[_writtenSurfaces removeAllObjects];[_resourceOwners removeAllObjects];
 @synchronized(gInFlight){[gInFlight removeObject:self];}
 NSArray *completedHandlers;
 @synchronized(self){
  // A frontend refusal or a failed submission never scheduled. Unblock its waiter without inventing a scheduled event.
  if(!_schedulingDelivered){_schedulingDelivered=YES;[_scheduledHandlers removeAllObjects];dispatch_group_leave(_schedulingHandlers);}
  completedHandlers=[_completedHandlers copy];[_completedHandlers removeAllObjects];
 }
 void (^run)(void)=^{
  for(MTLCommandBufferHandler block in completedHandlers)block((id<MTLCommandBuffer>)self);
  dispatch_group_leave(self->_handlers);
 };
 dispatch_queue_t queue=_queue.completionQueue;
 if(queue)dispatch_async(queue,run);else run();
}
- (void)commit {
 if(self.committed){NBLOG(@"native-metal: commit twice");return;}
 self.committed=YES;
 self.committedUs=nowUs();
 {
  std::lock_guard<std::mutex> lock(gCommitLock);
  // Assign once under the same lock as publication. A concurrent commit cannot reuse this index.
  const uint32_t index=(uint32_t)(gCommits.fetch_add(1)+1);self.commitIndex=index;
  CommitRecord &r=gCommitRing[index%32];
  r={};r.index=index;r.committedUs=self.committedUs;r.ageUs=self.committedUs-createdUs;r.work=encodedWork;
 }
 dispatch_group_enter(_handlers);
 dispatch_group_enter(_schedulingHandlers);
 @synchronized(gInFlight){[gInFlight addObject:self];}
 if(!self.encodeFailure) {
  flushSurfaces(_surfaces);
  // Completion owns this reference; the runtime orders the non-owning scheduled callback before it.
  void *context=(__bridge_retained void *)self;
  if(nmb_command_buffer_on_completed(_handle,completed,context) &&
     nmb_command_buffer_on_scheduled(_handle,scheduled,context) && nmb_command_buffer_commit(_handle))return;
  (void)CFBridgingRelease(context);   // refused registration/commit cannot call the registered handlers
  [self refuse:[@"commit: " stringByAppendingString:lastError()]];
 }
 self.failedLocally=YES;gCommitFailures++;
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{[self finish];});
}
- (void)waitUntilCompleted {
 if(!self.committed)return;
 const uint64_t began=nowUs();
 if(!self.failedLocally)nmb_command_buffer_wait(_handle,0);
 dispatch_group_wait(_handlers,DISPATCH_TIME_FOREVER);
 gTimeWaitCompleted.add(began);
}
- (void)waitUntilScheduled {
 if(!self.committed)return;
 const uint64_t began=nowUs();
 if(!self.failedLocally && !nmb_command_buffer_wait_scheduled(_handle)){
  NBLOG(@"native-metal: waitUntilScheduled refused: %@",lastError());return;
 }
 dispatch_group_wait(_schedulingHandlers,DISPATCH_TIME_FOREVER);
 gTimeWaitScheduled.add(began);
}
@end
static void scheduled(void *context) {[(__bridge NBCommandBuffer *)context didSchedule];}
// The runtime's completion: the command buffer's own reference, taken at commit, is given back here.
static void completed(void *context) {
 gCompleted++;
 NBCommandBuffer *commandBuffer=(__bridge_transfer NBCommandBuffer *)context;
 {
  const uint64_t took=nowUs()-commandBuffer.committedUs;
  gTimeEncodeToCommit.count++;gTimeEncodeToCommit.total+=took;
  uint64_t seen=gTimeEncodeToCommit.slowest.load();while(took>seen && !gTimeEncodeToCommit.slowest.compare_exchange_weak(seen,took)){}
  std::lock_guard<std::mutex> lock(gCommitLock);
  CommitRecord &r=gCommitRing[commandBuffer.commitIndex%32];
  if(r.index==commandBuffer.commitIndex)r.callbackUs=took;
 }
 [commandBuffer finish];
}

@implementation NBQueue
- (instancetype)init {if((self=[super init]))_executionEnabled=YES;return self;}
- (void)dealloc {nmb_queue_release(_handle);}
- (id<MTLCommandBuffer>)commandBuffer {
 NmbCommandBuffer *handle=nmb_command_buffer_new(_handle);
 if(!handle){NBLOG(@"native-metal: commandBuffer refused: %@",lastError());return nil;}
 NBCommandBuffer *commandBuffer=[NBCommandBuffer new];commandBuffer.handle=handle;commandBuffer.queue=self;return (id<MTLCommandBuffer>)commandBuffer;
}
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences {return [self commandBuffer];}
- (void)setSubmissionQueue:(dispatch_queue_t)queue {(void)queue;}   // submission happens on the caller's thread here
// setCompletionQueue: is the property's setter.
// GPU priorities are not applied (one hardware queue): getters return Metal defaults; setters report not applied.
- (NSUInteger)getGPUPriority {return 1; /* MTLGPUPriorityDefault */}
- (NSUInteger)getBackgroundGPUPriority {return 2; /* MTLGPUPriorityLow */}
- (BOOL)setGPUPriority:(NSUInteger)priority {(void)priority;return NO;}
- (BOOL)setGPUPriority:(NSUInteger)priority offset:(uint16_t)offset {(void)priority;(void)offset;return NO;}
- (BOOL)setBackgroundGPUPriority:(NSUInteger)priority {(void)priority;return NO;}
- (BOOL)setBackgroundGPUPriority:(NSUInteger)priority offset:(uint16_t)offset {(void)priority;(void)offset;return NO;}
- (BOOL)_setGPUPriority:(NSUInteger)priority backgroundPriority:(NSUInteger)bg {(void)priority;(void)bg;return NO;}
- (BOOL)supportsBackgroundAppRole {return YES;}
- (NSUInteger)qosLevel {return 0;}
- (dispatch_queue_t)commitQueue {return nil;}
- (BOOL)commitSynchronously {return NO;}
- (BOOL)commitsWithQoS {return NO;}
- (BOOL)disableCrossQueueHazardTracking {return NO;}
- (NSUInteger)maxCommandBufferCount {return 64;}
- (BOOL)isOpenGLQueue {return NO;}
- (void)insertDebugCaptureBoundary {}
- (void)finish {
 NSArray *pending;@synchronized(gInFlight){pending=gInFlight.allObjects;}
 for(NBCommandBuffer *cb in pending)if(cb.queue==self)[(id<MTLCommandBuffer>)cb waitUntilCompleted];
}
- (void)dispatchAvailableCompletionNotifications {}
- (uint64_t)getStatOptions {return self.statOptions;}
- (uint64_t)getStatLocations {return self.statLocations;}
- (NSArray *)availableCounters {return @[];}
- (int)requestCounters:(id)counters {(void)counters;return -1;}
- (int)requestCounters:(id)counters withIndex:(unsigned)index {(void)counters;(void)index;return -1;}
- (void)addPerfSampleHandler:(id)block {(void)block;}
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)d {(void)d;return [self commandBuffer];}
- (void)addResidencySet:(id)residencySet {(void)residencySet;}
- (void)addResidencySets:(const id __unsafe_unretained [])residencySets count:(NSUInteger)count {(void)residencySets;(void)count;}
- (void)removeResidencySet:(id)residencySet {(void)residencySet;}
- (void)removeResidencySets:(const id __unsafe_unretained [])residencySets count:(NSUInteger)count {(void)residencySets;(void)count;}
- (void)addInternalResidencySet:(id)residencySet {(void)residencySet;}
- (void)addInternalResidencySets:(const id __unsafe_unretained [])residencySets count:(NSUInteger)count {(void)residencySets;(void)count;}
- (void)removeInternalResidencySet:(id)residencySet {(void)residencySet;}
- (void)removeInternalResidencySets:(const id __unsafe_unretained [])residencySets count:(NSUInteger)count {(void)residencySets;(void)count;}
@end

// ---- the device ----
template <typename T> static T failWith(NSError **error,NSString *what,T value) {
 noteProblem([NSString stringWithFormat:@"%@: %@",what,lastError()]);
 if(error)*error=nbError([NSString stringWithFormat:@"%@: %@",what,lastError()]);
 return value;
}
// Which of QuartzCore's paths asked for a pipeline (int-153: every one was made synchronously on its render thread and no generic pipeline
// was ever asked for): its return addresses as offsets from its image header (header 0x189429000 in the 21H461 cache, so offset +
// 0x189429000 is the address in that image's disassembly), the global feature flags it ORs into every context's flags, and its
// CA_DISABLE_GENERIC_SHADERS, CA_FORCE_GENERIC_SHADERS and CA_DISABLE_PRECOMPILED_PIPELINES debug options (ca_debug_options +0x55..0x57,
// read only where dladdr places that address in QuartzCore).
static std::string quartzCoreCallers() {
 /* SweetMetal2 (iOS 16.7): only the return addresses into QuartzCore, as offsets from its header. UniXNU's version also read
  * MetalContext fields and debug bytes at iPadOS 17.7.11 (21H461) offsets, which mean nothing here. */
 void *frames[24];const int n=backtrace(frames,24);
 std::string out="qc";char item[32];unsigned kept=0;
 for(int i=0;i<n && kept<8;i++) {
  Dl_info info{};
  if(!dladdr(frames[i],&info) || !info.dli_fname || !strstr(info.dli_fname,"/QuartzCore"))continue;
  snprintf(item,sizeof item," %lx",(unsigned long)((uintptr_t)frames[i]-(uintptr_t)info.dli_fbase));out+=item;++kept;
 }
 return out;
}
// What a creation cost beyond its wall time (int-156: a translation the host does in 6 ms took 665 ms on the tablet, whose single core is
// as fast): this thread's CPU time (user and system, microseconds) and the task's page faults, page-ins and context switches. A creation
// whose CPU time is near its wall time computed; one whose faults are many paid the 4 KiB fault path; one far below it waited.
struct NBCost {
 uint64_t user=0,system=0;int64_t faults=0,pageins=0,switches=0;
 static NBCost now() {
  NBCost c;thread_basic_info_data_t t{};mach_msg_type_number_t n=THREAD_BASIC_INFO_COUNT;mach_port_t self=mach_thread_self();
  if(thread_info(self,THREAD_BASIC_INFO,(thread_info_t)&t,&n)==KERN_SUCCESS) {
   c.user=(uint64_t)t.user_time.seconds*1000000+t.user_time.microseconds;c.system=(uint64_t)t.system_time.seconds*1000000+t.system_time.microseconds;
  }
  mach_port_deallocate(mach_task_self(),self);
  task_events_info_data_t e{};n=TASK_EVENTS_INFO_COUNT;
  if(task_info(mach_task_self(),TASK_EVENTS_INFO,(task_info_t)&e,&n)==KERN_SUCCESS){c.faults=e.faults;c.pageins=e.pageins;c.switches=e.csw;}
  return c;
 }
 std::string since(const NBCost &b) const {
  char text[128];snprintf(text,sizeof text," cpu=%llu sys=%llu flt=%lld pin=%lld csw=%lld",(unsigned long long)(user+system-b.user-b.system),
      (unsigned long long)(system-b.system),(long long)(faults-b.faults),(long long)(pageins-b.pageins),(long long)(switches-b.switches));
  return text;
 }
};
// One journal line of a render pipeline creation begun at `began` (microseconds), `refused` its refusal or null. The label is the
// caller's name for the pipeline (QuartzCore's: its spec's encoded name).
static void journalRenderPipeline(MTLRenderPipelineDescriptor *d,uint64_t began,const char *refused,const std::string &cost) {
 if(gJournalPath.empty())return;
 const uint64_t ended=nowUs();uint64_t tid=0;pthread_threadid_np(nullptr,&tid);
 char head[256];
 snprintf(head,sizeof head,"R t=%llu tid=%llu main=%d us=%llu ok=%d samples=%lu topo=%lu ds=%lu/%lu",(unsigned long long)((began-gJournalBegan)/1000),
     (unsigned long long)tid,pthread_main_np(),(unsigned long long)(ended-began),refused?0:1,(unsigned long)d.rasterSampleCount,
     (unsigned long)d.inputPrimitiveTopology,(unsigned long)d.depthAttachmentPixelFormat,(unsigned long)d.stencilAttachmentPixelFormat);
 std::string line=head;
 line+=cost;
 line+=" label=";line+=d.label.length?d.label.UTF8String:"-";
 for(unsigned i=0;i<8;i++) {
  MTLRenderPipelineColorAttachmentDescriptor *a=d.colorAttachments[i];if(a.pixelFormat==MTLPixelFormatInvalid)continue;
  snprintf(head,sizeof head," c%u=%lu:%lu:%d:%lu:%lu:%lu:%lu:%lu:%lu",i,(unsigned long)a.pixelFormat,(unsigned long)a.writeMask,(int)a.blendingEnabled,
      (unsigned long)a.sourceRGBBlendFactor,(unsigned long)a.destinationRGBBlendFactor,(unsigned long)a.rgbBlendOperation,(unsigned long)a.sourceAlphaBlendFactor,
      (unsigned long)a.destinationAlphaBlendFactor,(unsigned long)a.alphaBlendOperation);
  line+=head;
 }
 if(MTLVertexDescriptor *v=d.vertexDescriptor)for(unsigned i=0;i<31;i++) {
  MTLVertexAttributeDescriptor *a=v.attributes[i];if(a.format==MTLVertexFormatInvalid)continue;
  MTLVertexBufferLayoutDescriptor *l=v.layouts[a.bufferIndex<31?a.bufferIndex:0];
  snprintf(head,sizeof head," a%u=%lu:%lu:%lu:%lu:%lu:%lu",i,(unsigned long)a.format,(unsigned long)a.offset,(unsigned long)a.bufferIndex,(unsigned long)l.stride,
      (unsigned long)l.stepFunction,(unsigned long)l.stepRate);
  line+=head;
 }
 NBFunction *vf=[(id)d.vertexFunction isKindOfClass:[NBFunction class]]?(NBFunction *)d.vertexFunction:nil;
 NBFunction *ff=[(id)d.fragmentFunction isKindOfClass:[NBFunction class]]?(NBFunction *)d.fragmentFunction:nil;
 line+=" | v ";line+=vf?vf.name.UTF8String:"-";line+=" ";line+=vf?vf.constantsText:"";
 line+=" | f ";line+=ff?ff.name.UTF8String:"-";line+=" ";line+=ff?ff.constantsText:"";
 if(refused){line+=" | refused ";line+=refused;}
 line+=" | ";line+=quartzCoreCallers();
 for(char &c:line)if(c=='\n')c=' ';
 journal(line);
}
struct BuiltLinkedFunctions {
 std::vector<NmbFunction *> functions,privateFunctions,binaryFunctions;
 std::vector<std::string> groupNames;
 std::vector<std::vector<NmbFunction *>> groupLists;
 std::vector<NmbLinkedGroup> groups;
 bool populate(MTLLinkedFunctions *src,NmbLinkedFunctions &out,NSError **error) {
  out={};
  if(!src)return true;
  auto convert=[&](NSArray<id<MTLFunction>> *in,std::vector<NmbFunction *> &dst)->bool {
   if(!in.count)return true;
   dst.reserve(in.count);
   for(id f in in) {
    if(![f isKindOfClass:[NBFunction class]]){if(error)*error=nbError(@"foreign linked function");return false;}
    dst.push_back([(NBFunction *)f handle]);
   }
   return true;
  };
  if(!convert(src.functions,functions) || !convert(src.privateFunctions,privateFunctions) || !convert(src.binaryFunctions,binaryFunctions))
   return false;
  out.functions=functions.empty()?nullptr:functions.data();out.function_count=(uint32_t)functions.size();
  out.private_functions=privateFunctions.empty()?nullptr:privateFunctions.data();out.private_function_count=(uint32_t)privateFunctions.size();
  out.binary_functions=binaryFunctions.empty()?nullptr:binaryFunctions.data();out.binary_function_count=(uint32_t)binaryFunctions.size();
  NSDictionary<NSString *,NSArray<id<MTLFunction>> *> *g=src.groups;
  if(g.count) {
   groupNames.reserve(g.count);groupLists.reserve(g.count);groups.reserve(g.count);
   for(NSString *name in g) {
    if(!name){if(error)*error=nbError(@"null linked group name");return false;}
    groupNames.emplace_back(name.UTF8String?:"");
    groupLists.emplace_back();
    if(!convert(g[name],groupLists.back()))return false;
   }
   for(size_t i=0;i<groupNames.size();++i)
    groups.push_back({groupNames[i].c_str(),groupLists[i].empty()?nullptr:groupLists[i].data(),(uint32_t)groupLists[i].size()});
   out.groups=groups.data();out.group_count=(uint32_t)groups.size();
  }
  return true;
 }
};
struct BuiltRenderDescriptor {
 NmbRenderPipelineDescriptor raw={};
 BuiltLinkedFunctions vertexLinked,fragmentLinked;
};
// A render pipeline descriptor in the bridge's form; false, with the error, for a function of another device.
static bool renderDescriptor(MTLRenderPipelineDescriptor *d,BuiltRenderDescriptor *b,NSError **error) {
 if(!d || ![(id)d.vertexFunction isKindOfClass:[NBFunction class]] || (d.fragmentFunction && ![(id)d.fragmentFunction isKindOfClass:[NBFunction class]])) {
  if(error)*error=nbError(@"foreign function");return false;
 }
 if(d.vertexPreloadedLibraries.count || d.fragmentPreloadedLibraries.count) {
  if(error)*error=nbError(@"render dynamic libraries are not implemented");return false;
 }
 NmbRenderPipelineDescriptor *p=&b->raw;
 if(!b->vertexLinked.populate(d.vertexLinkedFunctions,p->vertex_linked,error) ||
    !b->fragmentLinked.populate(d.fragmentLinkedFunctions,p->fragment_linked,error))return false;
 p->vertex=[(NBFunction *)d.vertexFunction handle];p->fragment=d.fragmentFunction?[(NBFunction *)d.fragmentFunction handle]:nullptr;
 for(unsigned i=0;i<8;i++) {
  MTLRenderPipelineColorAttachmentDescriptor *a=d.colorAttachments[i];
  p->colors[i]={(uint64_t)a.pixelFormat,(uint64_t)a.writeMask,(uint64_t)a.blendingEnabled,(uint64_t)a.sourceRGBBlendFactor,(uint64_t)a.destinationRGBBlendFactor,
      (uint64_t)a.rgbBlendOperation,(uint64_t)a.sourceAlphaBlendFactor,(uint64_t)a.destinationAlphaBlendFactor,(uint64_t)a.alphaBlendOperation};
 }
 p->depth_format=d.depthAttachmentPixelFormat;p->stencil_format=d.stencilAttachmentPixelFormat;p->samples=d.rasterSampleCount;
 p->topology=d.inputPrimitiveTopology;p->rasterization=d.rasterizationEnabled;
 p->max_vertex_call_stack_depth=d.maxVertexCallStackDepth;p->max_fragment_call_stack_depth=d.maxFragmentCallStackDepth;
 p->adding_vertex_binary_functions=d.supportAddingVertexBinaryFunctions;p->adding_fragment_binary_functions=d.supportAddingFragmentBinaryFunctions;
 if(MTLVertexDescriptor *v=d.vertexDescriptor) {
  for(unsigned i=0;i<31;i++) {
   MTLVertexAttributeDescriptor *a=v.attributes[i];if(a.format==MTLVertexFormatInvalid)continue;
   p->vertex_inputs=1;p->attributes[i]={(uint64_t)a.format,a.offset,a.bufferIndex};
   if(a.bufferIndex<31){MTLVertexBufferLayoutDescriptor *l=v.layouts[a.bufferIndex];p->layouts[a.bufferIndex]={l.stride,(uint64_t)l.stepFunction,l.stepRate};}
  }
 }
 return true;
}

// ---- heaps ----
// Metal heaps over the runtime's: an automatic heap places each resource, a placement heap takes an offset. Resources made from one keep it
// alive (their `heap`); a heap's resources share its storage mode, CPU cache mode and (here) hazard tracking mode.
@interface NBHeap : NBObject
@property(nonatomic) NmbHeap *handle;
@property(nonatomic) MTLResourceOptions options;
@property(nonatomic) MTLHeapType heapType;
@end
@implementation NBHeap
- (void)dealloc {nmb_heap_release(_handle);}
- (NSUInteger)size {return nmb_heap_size(_handle);}
- (NSUInteger)usedSize {return nmb_heap_used_size(_handle);}
- (NSUInteger)currentAllocatedSize {return nmb_heap_allocated_size(_handle);}
- (NSUInteger)allocatedSize {return nmb_heap_allocated_size(_handle);}
- (NSUInteger)maxAvailableSizeWithAlignment:(NSUInteger)alignment {return nmb_heap_max_available_size(_handle,alignment);}
- (MTLResourceOptions)resourceOptions {return _options;}
- (MTLStorageMode)storageMode {return (MTLStorageMode)((_options&MTLResourceStorageModeMask)>>MTLResourceStorageModeShift);}
- (MTLCPUCacheMode)cpuCacheMode {return (MTLCPUCacheMode)((_options&MTLResourceCPUCacheModeMask)>>MTLResourceCPUCacheModeShift);}
- (MTLHazardTrackingMode)hazardTrackingMode {return (MTLHazardTrackingMode)((_options&MTLResourceHazardTrackingModeMask)>>MTLResourceHazardTrackingModeShift);}
- (MTLResourceOptions)unfilteredResourceOptions {return _options;}
- (MTLHeapType)type {return _heapType;}
- (uint64_t)protectionOptions {return 0;}
- (uint64_t)gpuAddress {return 0;}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state {
 const uint64_t answer=nmb_heap_set_purgeable_state(_handle,state);
 if(!answer)NBLOG(@"native-metal: heap setPurgeableState refused: %@",lastError());
 return (MTLPurgeableState)answer;
}
- (id<MTLBuffer>)bufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options offset:(uint64_t)offset {
 NmbBuffer *handle=nmb_heap_new_buffer(_handle,length,options,offset);
 if(!handle){if(!strstr(nmb_last_error(),"OutOfMemory(Heap)"))NBLOG(@"native-metal: heap buffer refused: %@",lastError());return nil;}
 NBBuffer *buffer=[NBBuffer new];buffer.handle=handle;buffer.options=options;buffer.parentHeap=(id<MTLHeap>)self;
 return (id<MTLBuffer>)buffer;
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {return [self bufferWithLength:length options:options offset:UINT64_MAX];}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options offset:(NSUInteger)offset {
 return [self bufferWithLength:length options:options offset:offset];
}
- (id<MTLBuffer>)newBufferWithDescriptor:(id)d {
 if(!d)return nil;
 NSUInteger len=[d respondsToSelector:@selector(length)]?[(NBBuffer *)d length]:0;
 MTLResourceOptions opts=[d respondsToSelector:@selector(resourceOptions)]?[(NBBuffer *)d resourceOptions]:_options;
 return [self bufferWithLength:len options:opts offset:UINT64_MAX];
}
- (id<MTLBuffer>)newBufferWithDescriptor:(id)d offset:(NSUInteger)offset {
 if(!d)return nil;
 NSUInteger len=[d respondsToSelector:@selector(length)]?[(NBBuffer *)d length]:0;
 MTLResourceOptions opts=[d respondsToSelector:@selector(resourceOptions)]?[(NBBuffer *)d resourceOptions]:_options;
 return [self bufferWithLength:len options:opts offset:offset];
}
- (id<MTLTexture>)textureWithDescriptor:(MTLTextureDescriptor *)d offset:(uint64_t)offset {
 NmbTextureDescriptor descriptor;if(!textureDescriptor(d,&descriptor))return nil;
 NmbTexture *handle=nmb_heap_new_texture(_handle,&descriptor,offset);
 if(!handle){if(!strstr(nmb_last_error(),"OutOfMemory(Heap)"))NBLOG(@"native-metal: heap texture refused: %@",lastError());return nil;}
 NBTexture *texture=[NBTexture new];texture.handle=handle;nmb_texture_describe(handle,&descriptor);texture.descriptor=descriptor;
 texture.parentHeap=(id<MTLHeap>)self;return (id<MTLTexture>)texture;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d {return [self textureWithDescriptor:d offset:UINT64_MAX];}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset {return [self textureWithDescriptor:d offset:offset];}
@end
// Apple's SPI resource groups name resources for cache hints (encodeCacheHintTag:/Finalize:); a group only keeps its resources alive.
@interface NBResourceGroup : NBObject
@property(nonatomic,strong) NSArray *resources;
@end
@implementation NBResourceGroup
@end
@interface NBResidencySet : NBObject {
 NSMutableSet *_allocations;
}
@end
@implementation NBResidencySet
- (instancetype)init {
 if((self=[super init]))_allocations=[NSMutableSet new];
 return self;
}
- (uint64_t)allocatedSize {
 uint64_t total=0;
 @synchronized(self){
  for(id a in _allocations)
   if([a respondsToSelector:@selector(allocatedSize)])total+=[(NBBuffer *)a allocatedSize];
 }
 return total;
}
- (NSUInteger)allocationCount {@synchronized(self){return _allocations.count;}}
- (NSArray *)allAllocations {@synchronized(self){return _allocations.allObjects;}}
- (BOOL)containsAllocation:(id)allocation {
 if(!allocation)return NO;
 @synchronized(self){return [_allocations containsObject:allocation];}
}
- (void)addAllocation:(id)allocation {
 if(allocation)@synchronized(self){[_allocations addObject:allocation];}
}
- (void)addAllocations:(const id __unsafe_unretained [])allocations count:(NSUInteger)count {
 if(!allocations)return;
 @synchronized(self){for(NSUInteger i=0;i<count;i++)if(allocations[i])[_allocations addObject:allocations[i]];}
}
- (void)removeAllocation:(id)allocation {
 if(allocation)@synchronized(self){[_allocations removeObject:allocation];}
}
- (void)removeAllocations:(const id __unsafe_unretained [])allocations count:(NSUInteger)count {
 if(!allocations)return;
 @synchronized(self){for(NSUInteger i=0;i<count;i++)if(allocations[i])[_allocations removeObject:allocations[i]];}
}
- (void)removeAllAllocations {@synchronized(self){[_allocations removeAllObjects];}}
- (NSArray *)allCommittedAllocations {return [self allAllocations];}
- (NSUInteger)countForAllocation:(id)a {return [self containsAllocation:a]?1:0;}
- (uint64_t)currentGeneration {return 1;}
- (void)setCurrentGeneration:(uint64_t)g {(void)g;}
- (uint64_t)expiredGeneration {return 0;}
- (void)setExpiredGeneration:(uint64_t)g {(void)g;}
- (uint64_t)generationForAllocation:(id)a {return [self containsAllocation:a]?1:0;}
- (void)commit {}
- (void)requestResidency {}
- (void)endResidency {}
@end

struct BuiltComputeDescriptor {
 NmbComputePipelineDescriptor raw={};
 BuiltLinkedFunctions linked;
};
// Creation and archive population must use the same complete supported descriptor.
static bool computeDescriptor(MTLComputePipelineDescriptor *d,BuiltComputeDescriptor *b,NSError **error) {
 if(!d || ![(id)d.computeFunction isKindOfClass:[NBFunction class]]){
  NBLOG(@"native-metal: compute descriptor refused: foreign compute function (%s)",d && d.computeFunction?object_getClassName(d.computeFunction):"nil");
  if(error)*error=nbError(@"foreign compute function");
  return false;
 }
 // Metal may materialize empty stage/linked descriptors on access. Preserve the
 // default meaning while refusing state this frontend cannot yet represent.
 MTLStageInputOutputDescriptor *stage=d.stageInputDescriptor;
 bool empty=true;
 for(NSUInteger index=0;stage && index<31;++index) {
  MTLAttributeDescriptor *a=stage.attributes[index];
  if(a && a.format!=MTLAttributeFormatInvalid){empty=false;break;}
 }
 if(!empty){
  NBLOG(@"native-metal: compute descriptor refused: stage inputs not implemented (%@)",[(NBFunction *)d.computeFunction name]);
  if(error)*error=nbError(@"compute stage inputs are not implemented");
  return false;
 }
 if(d.preloadedLibraries.count || d.insertLibraries.count) {
  NBLOG(@"native-metal: compute descriptor refused: dynamic libraries (%@)",[(NBFunction *)d.computeFunction name]);
  if(error)*error=nbError(@"compute dynamic libraries are not implemented");return false;
 }
 NmbComputePipelineDescriptor *p=&b->raw;
 if(!b->linked.populate(d.linkedFunctions,p->linked,error))return false;
 p->function=[(NBFunction *)d.computeFunction handle];p->max_threads=d.maxTotalThreadsPerThreadgroup;
 p->multiple_of_execution_width=d.threadGroupSizeIsMultipleOfThreadExecutionWidth;p->indirect=d.supportIndirectCommandBuffers;
 p->max_call_stack_depth=d.maxCallStackDepth;p->adding_binary_functions=d.supportAddingBinaryFunctions;
 for(NSUInteger index=0;index<31;++index)p->mutability[index]=d.buffers[index].mutability;
 return true;
}

// ---- binary archives ----
@interface NBBinaryArchive : NBObject
@property(nonatomic) NmbBinaryArchive *handle;
@end
@implementation NBBinaryArchive
- (void)dealloc {nmb_binary_archive_release(_handle);}
- (NSUInteger)options {return 0;}
- (BOOL)addRenderPipelineFunctionsWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)error {
 auto *b=new BuiltRenderDescriptor();
 const bool ok=renderDescriptor(d,b,error) && nmb_binary_archive_add_render(_handle,&b->raw);delete b;
 if(!ok)return failWith<BOOL>(error,@"archive render pipeline",NO);
 if(error)*error=nil;return YES;
}
- (BOOL)addComputePipelineFunctionsWithDescriptor:(MTLComputePipelineDescriptor *)d error:(NSError **)error {
 BuiltComputeDescriptor b;if(!computeDescriptor(d,&b,error))return NO;
 if(!nmb_binary_archive_add_compute_descriptor(_handle,&b.raw))return failWith<BOOL>(error,@"archive compute pipeline",NO);
 if(error)*error=nil;return YES;
}
- (BOOL)serializeToURL:(NSURL *)url error:(NSError **)error {
 if(!url.isFileURL){if(error)*error=nbError(@"a file URL is required");return NO;}
 if(!nmb_binary_archive_serialize(_handle,url.fileSystemRepresentation))return failWith<BOOL>(error,@"archive serialize",NO);
 if(error)*error=nil;return YES;
}
@end

static bool pipelineArchives(NSArray *list,std::vector<NmbBinaryArchive *> &archives,NSError **error) {
 for(id archive in list) {
  if(![archive isKindOfClass:[NBBinaryArchive class]]){if(error)*error=nbError(@"foreign binary archive");return false;}
  archives.push_back([(NBBinaryArchive *)archive handle]);
 }
 return true;
}

@interface NBDeviceMethods : NSObject
@end
// Bytes of one texel of the uncompressed formats Core Animation and RenderBox use (4 for the rest).
static uint64_t sweetTexelBytes(MTLPixelFormat f) {
 switch((NSUInteger)f) {
 case 1: case 10: case 11: case 12: case 13: case 14: return 1;
 case 20: case 22: case 23: case 24: case 25: case 30: case 32: case 33: case 34: case 40: case 41: case 42: case 43: return 2;
 case 103: case 104: case 105: case 110: case 111: case 112: case 113: case 114: case 115: case 552: case 553: return 8;
 case 123: case 124: case 125: return 16;
 default: return 4;
 }
}
typedef struct {uint64_t w[2];} SweetWatermark;   /* AGXTextureLayout's {?=[2Q]} watermark */
// Block footprint and bytes of the compressed formats the A640 samples (ASTC LDR/sRGB, ETC2/EAC); false for the rest.
static bool sweetBlock(MTLPixelFormat f, uint32_t *bw, uint32_t *bh, uint32_t *bytes) {
 static const uint8_t astc[][2] = {{4,4},{5,4},{5,5},{6,5},{6,6},{0,0},{8,5},{8,6},{8,8},{10,5},{10,6},{10,8},{10,10},{12,10},{12,12}};
 const NSUInteger n = (NSUInteger)f;
 if((n >= 186 && n <= 200) || (n >= 204 && n <= 218)) {
  const NSUInteger i = n >= 204 ? n - 204 : n - 186;
  if(!astc[i][0]) return false;
  *bw = astc[i][0]; *bh = astc[i][1]; *bytes = 16; return true;
 }
 switch(n) {
 case 170: case 172: case 180: case 181: case 182: case 183: *bw = 4; *bh = 4; *bytes = 8; return true;   /* EAC R11, ETC2 RGB8(A1) */
 case 174: case 176: case 178: case 179: *bw = 4; *bh = 4; *bytes = 16; return true;                          /* EAC RG11, RGBA8 */
 default: return false;
 }
}
// Keeps a no-copy texture's memory owner until the texture goes (its deallocator runs then).
@interface SweetMemoryOwner : NSObject
@property(nonatomic,copy) void (^deallocator)(void *,NSUInteger);
@property(nonatomic) void *bytes;
@property(nonatomic) NSUInteger length;
@end
@implementation SweetMemoryOwner
- (void)dealloc {if(_deallocator)_deallocator(_bytes,_length);}
@end
static char sweetMemoryOwnerKey;
// SweetMetal2's MTLTextureLayout (Metal SPI: AGXTextureLayout's protocol on Apple's GPUs): a linear layout of `row`-byte rows.
@interface SweetTextureLayout : NSObject
- (instancetype)initWithRow:(uint64_t)row height:(uint64_t)height texel:(uint64_t)texel;
- (instancetype)initWithBlocks:(uint32_t)bw by:(uint32_t)bh bytes:(uint32_t)bytes width:(uint64_t)width height:(uint64_t)height;
@end
@implementation SweetTextureLayout {
 uint64_t _row,_height,_texel;
 uint32_t _bw,_bh;     /* block footprint (1x1 uncompressed); _height and _texel count block rows and block bytes */
}
- (instancetype)initWithRow:(uint64_t)row height:(uint64_t)height texel:(uint64_t)texel {
 if((self=[super init])){_row=row;_height=height;_texel=texel?texel:4;_bw=_bh=1;}
 return self;
}
- (instancetype)initWithBlocks:(uint32_t)bw by:(uint32_t)bh bytes:(uint32_t)bytes width:(uint64_t)width height:(uint64_t)height {
 if((self=[super init])){_bw=bw;_bh=bh;_texel=bytes;_row=(width+bw-1)/bw*bytes;_height=(height+bh-1)/bh;}
 return self;
}
- (NSUInteger)size {const uint64_t page=(uint64_t)getpagesize();return (NSUInteger)((_row*_height+page-1)&~(page-1));}
- (NSUInteger)alignment {return (NSUInteger)getpagesize();}
- (MTLSize)copyGranularity {return MTLSizeMake(_bw,_bh,1);}
- (SweetWatermark)watermark {SweetWatermark none={{0,0}};return none;}
- (void)initializeTextureMemory:(void *)memory {(void)memory;}
- (void)finalizeTextureMemory:(void *)memory {(void)memory;}
- (void)copyFromLinearBytes:(const void *)src linearOffset:(NSUInteger)offset linearBytesPerRow:(NSUInteger)srcRow linearBytesPerImage:(NSUInteger)image
            toTextureMemory:(void *)dst textureSlice:(NSUInteger)slice textureLevel:(NSUInteger)level textureRegion:(MTLRegion)r {
 (void)image;if(slice || level)return;
 const NSUInteger x0=r.origin.x/_bw,y0=r.origin.y/_bh,w=(r.size.width+_bw-1)/_bw,h=(r.size.height+_bh-1)/_bh;
 for(NSUInteger y=0;y<h && y0+y<_height;y++)
  memcpy((uint8_t *)dst+(y0+y)*_row+x0*_texel,(const uint8_t *)src+offset+y*srcRow,w*_texel);
}
- (void)copyFromTextureMemory:(const void *)src textureSlice:(NSUInteger)slice textureLevel:(NSUInteger)level textureRegion:(MTLRegion)r
              toLinearBytes:(void *)dst linearOffset:(NSUInteger)offset linearBytesPerRow:(NSUInteger)dstRow linearBytesPerImage:(NSUInteger)image {
 (void)image;if(slice || level)return;
 const NSUInteger x0=r.origin.x/_bw,y0=r.origin.y/_bh,w=(r.size.width+_bw-1)/_bw,h=(r.size.height+_bh-1)/_bh;
 for(NSUInteger y=0;y<h && y0+y<_height;y++)
  memcpy((uint8_t *)dst+offset+y*dstRow,(const uint8_t *)src+(y0+y)*_row+x0*_texel,w*_texel);
}
@end
@interface NBArchitecture : NSObject <NSCopying>
@end
@implementation NBArchitecture
- (NSString *)name {return @"applegpu_g9p";}
- (NSString *)revision {return @"A1";}
- (int)cpuType {return 0x100000c;}
- (int)cpuSubtype {return 0;}
- (id)copyWithZone:(NSZone *)zone {
 (void)zone;
#if __has_feature(objc_arc)
 return self;
#else
 return [self retain];
#endif
}
@end
static uint64_t askAnswer(SEL cmd,NSUInteger arg);
@implementation NBDeviceMethods
- (NSString *)name {return gName;}
- (id)architecture {
 static NBArchitecture *arch;
 static dispatch_once_t once;
 dispatch_once(&once,^{arch=[NBArchitecture new];});
 return arch;
}
- (uint64_t)registryID {return gRegistryID;}
- (NSUInteger)maxBufferLength {return nmb_device_max_buffer_length(gDevice);}
- (BOOL)hasUnifiedMemory {return YES;}
- (BOOL)isLowPower {return NO;}
- (BOOL)isRemovable {return NO;}
- (BOOL)isHeadless {return NO;}
- (NSUInteger)gpuCoreCount {return 2;}
- (NSUInteger)maxVertexAmplificationCount {return 1;}
- (BOOL)supportsVertexAmplificationCount:(NSUInteger)count {return count==1;}
- (NSUInteger)maxComputeThreadgroupMemory {return 32768;}
- (BOOL)isLargeMRTSupported {return NO;}
- (BOOL)supportsComputeCompressedTextureWrite {return NO;}
- (BOOL)supportsConditionalLoadStore {return NO;}
// supportsFamily: and the other queries the runtime answers are installed from it (installAnswers); supportsFamily: also answers the target
// hardware's families (the bridge's TARGET_FAMILIES, journaled with their waived rows as F lines). No legacy feature set is claimed: the
// base implementation reads Apple tables this device does not have.
- (BOOL)supportsFeatureSet:(MTLFeatureSet)set {(void)set;return NO;}
// The original discovery (_MTLAddDevice) runs these four on every device it registers. The target's own versions fill the base class's limits
// and feature tables from a hardware profile (`featureProfile`, `indirectArgumentBufferCapabilities`, a table of Apple GPUs) that this device
// has not got: running them would claim an Apple GPU's capabilities. They are empty here, so a limit or feature the runtime measured is answered
// by this file's own answers (installAnswers) and any other stays the base class's neutral 0/NO. Nothing is claimed that nothing measured.
- (NSUInteger)featureProfile {return 0;}
- (void)initLimits {}
- (void)initFeatureQueries {}
- (void)initGPUFamilySupport {}
- (void)initWorkarounds {}
- (NSString *)productName {return gName;}
- (NSString *)vendorName {char name[64]={};nmb_device_vendor_name(gDevice,name,sizeof name);return [NSString stringWithUTF8String:name];}
- (MTLSize)maxThreadsPerThreadgroup {
 uint64_t s[3]={};if(!nmb_device_max_threads_per_threadgroup(gDevice,s))NBLOG(@"native-metal: maxThreadsPerThreadgroup: %@",lastError());
 return MTLSizeMake(s[0],s[1],s[2]);
}
- (void)doesNotRecognizeSelector:(SEL)selector {
 if(gMissing)gMissing("NativeBridgeMetalDevice",sel_getName(selector));
 noteProblem([NSString stringWithFormat:@"missing device %s",sel_getName(selector)]);
 [super doesNotRecognizeSelector:selector];
}
- (id<MTLEvent>)newEvent {
 NmbEvent *handle=nmb_event_new(gDevice,false);if(!handle)return nil;
 NBEvent *event=[NBEvent new];event.handle=handle;return (id<MTLEvent>)event;
}
- (id<MTLSharedEvent>)newSharedEvent {
 NmbEvent *handle=nmb_event_new(gDevice,true);if(!handle)return nil;
 NBSharedEvent *event=[NBSharedEvent new];event.handle=handle;return (id<MTLSharedEvent>)event;
}
- (id<MTLFence>)newFence {
 NmbFence *handle=nmb_fence_new(gDevice);if(!handle)return nil;
 NBFence *fence=[NBFence new];fence.handle=handle;return (id<MTLFence>)fence;
}
- (id<MTLCommandQueue>)newCommandQueue {
 NmbQueue *handle=nmb_queue_new(gDevice);if(!handle)return nil;
 NBQueue *queue=[NBQueue new];queue.handle=handle;return (id<MTLCommandQueue>)queue;
}
- (id<MTLCommandQueue>)newCommandQueueWithDescriptor:(id)d {(void)d;return [(id<MTLDevice>)self newCommandQueue];}
- (id)newResidencySetWithDescriptor:(id)d error:(NSError **)error {
 NBResidencySet *set=[NBResidencySet new];
 if([d respondsToSelector:@selector(label)])set.label=[(NBObject *)d label];
 if(error)*error=nil;
 return set;
}
- (id<MTLHeap>)newHeapWithDescriptor:(MTLHeapDescriptor *)d {
 if(!d)return nil;
 NmbHeap *handle=nmb_heap_new(gDevice,d.type,d.size,(uint64_t)d.resourceOptions);
 if(!handle){NBLOG(@"native-metal: heap refused: %@",lastError());return nil;}
 NBHeap *heap=[NBHeap new];heap.handle=handle;heap.options=d.resourceOptions;heap.heapType=d.type;return (id<MTLHeap>)heap;
}
- (id)newResourceGroupFromResources:(const id __unsafe_unretained [])resources count:(NSUInteger)count {
 NBResourceGroup *group=[NBResourceGroup new];
 NSMutableArray *held=[NSMutableArray arrayWithCapacity:count];
 for(NSUInteger i=0;i<count;i++)if(resources[i])[held addObject:resources[i]];
 group.resources=held;return group;
}
// SweetMetal2: a texture over raw memory, and the layout object for such memory (MTLTextureLayout SPI), in one linear layout of
// our choosing that both answer alike: rows of the runtime's required linear pitch, level 0 of a 2D texture, page-aligned
// memory (it is imported, not copied). Clients ask the layout for size and alignment, allocate, then wrap the memory
// (RenderBox's drawables; without these: "RBDisplayList: no drawable" and blank widgets). A caller that never asked
// gets the pitch its length implies where the required one does not fit.
- (id<MTLTexture>)newTextureWithBytesNoCopy:(void *)bytes length:(NSUInteger)length descriptor:(MTLTextureDescriptor *)d deallocator:(void (^)(void *,NSUInteger))deallocator {
 const size_t page=(size_t)getpagesize();
 if(!d || !d.width || !d.height)return nil;
 if(bytes && !length && !((uintptr_t)bytes&(page-1)) && !deallocator && d.textureType==MTLTextureType2D && d.mipmapLevelCount<=1 && d.arrayLength<=1 && d.sampleCount<=1) {
  uint32_t bw=0,bh=0,bb=0;
  const uint64_t rowNeed=sweetBlock(d.pixelFormat,&bw,&bh,&bb)?((d.width+bw-1)/bw*bb):nmb_device_linear_bytes_per_row(gDevice,d.pixelFormat,d.width);
  const uint64_t rowsNeed=bw?((d.height+bh-1)/bh):d.height;
  const uint64_t want=rowNeed*rowsNeed?((rowNeed*rowsNeed+page-1)&~(page-1)):0;
  vm_address_t raddr=(vm_address_t)(uintptr_t)bytes;vm_size_t rsize=0;
  vm_region_basic_info_data_64_t rinfo={};mach_msg_type_number_t rcnt=VM_REGION_BASIC_INFO_COUNT_64;mach_port_t robj=MACH_PORT_NULL;
  if(want && vm_region_64(mach_task_self(),&raddr,&rsize,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&rinfo,&rcnt,&robj)==KERN_SUCCESS) {
   if(robj!=MACH_PORT_NULL)mach_port_deallocate(mach_task_self(),robj);
   if(raddr<=(uintptr_t)bytes && (rinfo.protection&VM_PROT_READ) && ((uintptr_t)raddr+rsize)>=(uintptr_t)bytes+want)
    length=(NSUInteger)want;
  }
 }
 if(!bytes || !length || ((uintptr_t)bytes&(page-1)) || d.textureType!=MTLTextureType2D || d.mipmapLevelCount>1 || d.arrayLength>1 || d.sampleCount>1){
  NBLOG(@"native-metal: newTextureWithBytesNoCopy refused (%p %lu %lux%lu type %lu levels %lu)",bytes,(unsigned long)length,(unsigned long)d.width,(unsigned long)d.height,(unsigned long)d.textureType,(unsigned long)d.mipmapLevelCount);
  return nil;
 }
 uint32_t bw=0,bh=0,bb=0;
 if(sweetBlock(d.pixelFormat,&bw,&bh,&bb)) {
  /* compressed: no linear texture of it exists, so a texture of its own, filled from the caller's blocks (packed rows) */
  const NSUInteger row=(d.width+bw-1)/bw*bb,rows=(d.height+bh-1)/bh;
  if(row*rows>length){NBLOG(@"native-metal: newTextureWithBytesNoCopy: %lux%lu fmt %lu needs %lu bytes, has %lu",(unsigned long)d.width,(unsigned long)d.height,(unsigned long)d.pixelFormat,(unsigned long)(row*rows),(unsigned long)length);return nil;}
  MTLTextureDescriptor *own=[d copy];
  own.storageMode=MTLStorageModeShared;
  id<MTLTexture> texture=[(id<MTLDevice>)self newTextureWithDescriptor:own];
  if(!texture)return nil;
  [texture replaceRegion:MTLRegionMake2D(0,0,d.width,d.height) mipmapLevel:0 withBytes:bytes bytesPerRow:row];
  SweetMemoryOwner *owner=[SweetMemoryOwner new];owner.deallocator=deallocator;owner.bytes=bytes;owner.length=length;
  objc_setAssociatedObject(texture,&sweetMemoryOwnerKey,owner,OBJC_ASSOCIATION_RETAIN);
  return texture;
 }
 uint64_t row=nmb_device_linear_bytes_per_row(gDevice,d.pixelFormat,d.width);
 if(row && row*d.height>length && length%d.height==0)row=length/d.height;
 if(!row || row*d.height>length){NBLOG(@"native-metal: newTextureWithBytesNoCopy: %lux%lu fmt %lu does not fit %lu bytes",(unsigned long)d.width,(unsigned long)d.height,(unsigned long)d.pixelFormat,(unsigned long)length);return nil;}
 id<MTLBuffer> buffer=[(id<MTLDevice>)self newBufferWithBytesNoCopy:bytes length:(length+page-1)&~(page-1) options:MTLResourceStorageModeShared deallocator:deallocator];
 if(!buffer)return nil;
 return (id<MTLTexture>)textureOnBuffer((NBBuffer *)buffer,d,0,row,false);
}
- (id)newTextureLayoutWithDescriptor:(MTLTextureDescriptor *)d isHeapOrBufferBacked:(BOOL)backed {
 (void)backed;
 if(!d || !d.width || !d.height)return nil;
 if(d.textureType!=MTLTextureType2D || d.mipmapLevelCount>1 || d.arrayLength>1 || d.sampleCount>1){
  NBLOG(@"native-metal: newTextureLayoutWithDescriptor refused (type %lu levels %lu)",(unsigned long)d.textureType,(unsigned long)d.mipmapLevelCount);
  return nil;
 }
 uint32_t bw=0,bh=0,bb=0;
 if(sweetBlock(d.pixelFormat,&bw,&bh,&bb))
  return [[SweetTextureLayout alloc] initWithBlocks:bw by:bh bytes:bb width:d.width height:d.height];
 const uint64_t row=nmb_device_linear_bytes_per_row(gDevice,d.pixelFormat,d.width);
 if(!row){NBLOG(@"native-metal: newTextureLayoutWithDescriptor: no linear pitch for fmt %lu: %@",(unsigned long)d.pixelFormat,lastError());return nil;}
 return [[SweetTextureLayout alloc] initWithRow:row height:d.height texel:sweetTexelBytes(d.pixelFormat)];
}
- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)count {(void)count;return [(id<MTLDevice>)self newCommandQueue];}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
 NmbBuffer *handle=nmb_buffer_new(gDevice,length,options,nullptr);
 if(!handle){NBLOG(@"native-metal: buffer refused: %@",lastError());return nil;}
 NBBuffer *buffer=[NBBuffer new];buffer.handle=handle;buffer.options=options;return (id<MTLBuffer>)buffer;
}
- (id<MTLBuffer>)newBufferWithBytes:(const void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options {
 if(!bytes)return nil;
 NmbBuffer *handle=nmb_buffer_new(gDevice,length,options,bytes);
 if(!handle){NBLOG(@"native-metal: buffer refused: %@",lastError());return nil;}
 NBBuffer *buffer=[NBBuffer new];buffer.handle=handle;buffer.options=options;return (id<MTLBuffer>)buffer;
}
- (id<MTLBuffer>)newBufferWithBytesNoCopy:(void *)pointer length:(NSUInteger)length options:(MTLResourceOptions)options deallocator:(void (^)(void *,NSUInteger))deallocator {
 NmbBuffer *handle=nmb_buffer_new_no_copy(gDevice,pointer,length,options);
 if(!handle){NBLOG(@"native-metal: no-copy buffer refused: %@",lastError());return nil;}
 NBBuffer *buffer=[NBBuffer new];buffer.handle=handle;buffer.options=options;
 buffer.wrapped=pointer;buffer.deallocator=deallocator;
 return (id<MTLBuffer>)buffer;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d {
 NmbTextureDescriptor req;if(!textureDescriptor(d,&req))return nil;
 NmbTexture *handle=takePooledTexture(req);
 if(!handle) {
  handle=nmb_texture_new(gDevice,&req);
  if(!handle){drainTexturePool();handle=nmb_texture_new(gDevice,&req);}
  noteFormat((uint32_t)req.format,handle!=nullptr);
 }
 if(!handle){NBLOG(@"native-metal: texture refused: %@",lastError());return nil;}
 NBTexture *texture=[NBTexture new];texture.handle=handle;
 texture.requestDescriptor=req;texture.hasRequestDescriptor=YES;
 NmbTextureDescriptor actual=req;nmb_texture_describe(handle,&actual);texture.descriptor=actual;
 return (id<MTLTexture>)texture;
}
// The surface's pages are the texels: its mapping in this process is imported without a copy (pinned by the kernel, mapped into the GPU's
// 4 KiB context by Turnip), so every process that imports the surface renders and samples the same memory.
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane {
 if(!surface || !d)return nil;
 const size_t planeCount=IOSurfaceGetPlaneCount(surface);
 if(planeCount>2 || (planeCount?plane>=planeCount:plane!=0))return nil;
 void *rawBase=IOSurfaceGetBaseAddress(surface);const size_t page=(size_t)getpagesize(),allocation=IOSurfaceGetAllocSize(surface);
 if(!page || (page&(page-1)) || !rawBase || !allocation)return nil;
 void *base=(void *)((uintptr_t)rawBase&~(page-1));
 const size_t lead=(uintptr_t)rawBase-(uintptr_t)base;
 if(allocation>SIZE_MAX-lead-(page-1))return nil;
 const size_t bytes=(lead+allocation+page-1)&~(page-1);
 uint64_t offset=0,rowBytes=0;
 if(planeCount) {
  void *planeBase=IOSurfaceGetBaseAddressOfPlane(surface,plane);
  if(!planeBase || (uintptr_t)planeBase<(uintptr_t)rawBase)return nil;
  const size_t rawOffset=(uintptr_t)planeBase-(uintptr_t)rawBase;
  if(rawOffset>=allocation)return nil;
  offset=(uint64_t)((uintptr_t)planeBase-(uintptr_t)base);
  rowBytes=(uint64_t)IOSurfaceGetBytesPerRowOfPlane(surface,plane);
 } else {
  offset=(uint64_t)lead;
  rowBytes=(uint64_t)IOSurfaceGetBytesPerRow(surface);
 }
 if(!rowBytes)return nil;
 NmbSurfacePlane sp={};
 sp.offset=offset;sp.bytes_per_row=rowBytes;sp.planar=planeCount>0;
 char matrixBuf[64]={};
 if(planeCount==2) {
  void *chromaBase=IOSurfaceGetBaseAddressOfPlane(surface,1);
  if(!chromaBase || (uintptr_t)chromaBase<(uintptr_t)rawBase)return nil;
  const size_t rawChroma=(uintptr_t)chromaBase-(uintptr_t)rawBase;
  const uint64_t chromaRow=(uint64_t)IOSurfaceGetBytesPerRowOfPlane(surface,1);
  if(rawChroma>=allocation || !chromaRow)return nil;
  sp.has_ycbcr=true;
  sp.pixel_format=(uint32_t)IOSurfaceGetPixelFormat(surface);
  sp.plane=(uint64_t)plane;
  sp.width=(uint64_t)IOSurfaceGetWidth(surface);
  sp.height=(uint64_t)IOSurfaceGetHeight(surface);
  sp.chroma_offset=(uint64_t)((uintptr_t)chromaBase-(uintptr_t)base);
  sp.chroma_bytes_per_row=chromaRow;
  CFTypeRef mv=IOSurfaceCopyValue(surface,CFSTR("IOSurfaceYCbCrMatrix"));
  if(mv) {
   if(CFGetTypeID(mv)==CFStringGetTypeID() && CFStringGetCString((CFStringRef)mv,matrixBuf,sizeof matrixBuf,kCFStringEncodingUTF8))
    sp.matrix=matrixBuf;
   CFRelease(mv);
  }
 }
 NBBuffer *buffer=surfaceBuffer(surface,base,bytes);if(!buffer)return nil;
 NmbTextureDescriptor descriptor;if(!textureDescriptor(d,&descriptor))return nil;
 NmbTexture *handle=nmb_texture_new_iosurface(buffer.handle,&descriptor,&sp);
 noteFormat((uint32_t)descriptor.format,handle!=nullptr);
 if(!handle){NBLOG(@"native-metal: texture over iosurface (plane %lu/%lu fmt %u ostype 0x%x) refused: %@",(unsigned long)plane,(unsigned long)planeCount,(unsigned)descriptor.format,(unsigned)IOSurfaceGetPixelFormat(surface),lastError());return nil;}
 NBTexture *texture=[NBTexture new];texture.handle=handle;nmb_texture_describe(handle,&descriptor);texture.descriptor=descriptor;
 texture.buffer=buffer;texture.offset=(NSUInteger)offset;texture.rowBytes=(NSUInteger)rowBytes;
 texture.surface=(IOSurfaceRef)CFRetain(surface);texture.surfacePlane=plane;
 return (id<MTLTexture>)texture;
}
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
 const void *bytes=nullptr;size_t size=0;dispatch_data_t mapped=dispatch_data_create_map(data,&bytes,&size);
 const uint64_t libraryBegan=nowUs();
 NmbLibrary *handle=nmb_library_new(gDevice,bytes,size,false);(void)mapped;gTimeLibrary.add(libraryBegan);
 if(!handle)return failWith<id<MTLLibrary>>(error,@"library",nil);
 NBLibrary *library=[NBLibrary new];library.handle=handle;[library computeLibraryHash:bytes length:size];if(error)*error=nil;return (id<MTLLibrary>)library;
}
- (id<MTLLibrary>)newLibraryWithFile:(NSString *)path error:(NSError **)error {
 NSData *bytes=path?[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error]:nil;if(!bytes)return nil;
 const uint64_t libraryBegan=nowUs();
 NmbLibrary *handle=nmb_library_new(gDevice,bytes.bytes,bytes.length,false);gTimeLibrary.add(libraryBegan);
 if(!handle)return failWith<id<MTLLibrary>>(error,@"library",nil);
 NBLibrary *library=[NBLibrary new];library.handle=handle;[library computeLibraryHash:bytes.bytes length:bytes.length];if(error)*error=nil;return (id<MTLLibrary>)library;
}
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error {
 if(!url.isFileURL){if(error)*error=nbError(@"a file URL is required");return nil;}
 return [(id<MTLDevice>)self newLibraryWithFile:url.path error:error];
}
- (id<MTLLibrary>)newDefaultLibraryWithBundle:(NSBundle *)bundle error:(NSError **)error {
 NSURL *url=[bundle URLForResource:@"default" withExtension:@"metallib"];
 if(!url){if(error)*error=nbError(@"the bundle has no default.metallib");return nil;}
 return [(id<MTLDevice>)self newLibraryWithURL:url error:error];
}
- (id<MTLLibrary>)newDefaultLibrary {return [(id<MTLDevice>)self newDefaultLibraryWithBundle:[NSBundle mainBundle] error:nil];}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function error:(NSError **)error {
 return [(id<MTLDevice>)self newComputePipelineStateWithFunction:function options:MTLPipelineOptionNone reflection:nil error:error];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function options:(MTLPipelineOption)options
                                                         reflection:(MTLAutoreleasedComputePipelineReflection *)reflection error:(NSError **)error {
 if(reflection)*reflection=nil;
 if(![(id)function isKindOfClass:[NBFunction class]]){if(error)*error=nbError(@"foreign function");return nil;}
 const NmbPipelineOptions creation={(uint64_t)options,nullptr,0};
 const uint64_t pipelineBegan=nowUs();
 NmbComputePipeline *handle=nmb_compute_pipeline_new_with_options(gDevice,[(NBFunction *)function handle],&creation);gTimePipeline.add(pipelineBegan);
 if(!handle){NBLOG(@"native-metal: compute pipeline (%@) refused: %@",[(NBFunction *)function name],lastError());return failWith<id<MTLComputePipelineState>>(error,@"compute pipeline",nil);}
 NBComputePipeline *state=[NBComputePipeline new];state.handle=handle;gPipelines++;if(error)*error=nil;return (id<MTLComputePipelineState>)state;
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)d error:(NSError **)error {
 return [(id<MTLDevice>)self newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionNone reflection:nil error:error];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)d options:(MTLPipelineOption)options
                                                       reflection:(MTLAutoreleasedComputePipelineReflection *)reflection error:(NSError **)error {
 if(reflection)*reflection=nil;
 BuiltComputeDescriptor b;if(!computeDescriptor(d,&b,error))return nil;
 std::vector<NmbBinaryArchive *> archives;
 if(!pipelineArchives(d.binaryArchives,archives,error))return nil;
 const NmbPipelineOptions creation={(uint64_t)options,archives.data(),archives.size()};
 const uint64_t pipelineBegan=nowUs();
 NmbComputePipeline *handle=nmb_compute_pipeline_new_with_descriptor(gDevice,&b.raw,&creation);gTimePipeline.add(pipelineBegan);
 if(!handle){NBLOG(@"native-metal: compute pipeline (%@) refused: %@",[(NBFunction *)d.computeFunction name],lastError());return failWith<id<MTLComputePipelineState>>(error,@"compute pipeline",nil);}
 NBComputePipeline *state=[NBComputePipeline new];state.handle=handle;state.label=d.label;gPipelines++;
 if(error)*error=nil;return (id<MTLComputePipelineState>)state;
}
- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)function completionHandler:(void (^)(id<MTLComputePipelineState>,NSError *))completionHandler {
 NSError *error=nil;id<MTLComputePipelineState> state=[(id<MTLDevice>)self newComputePipelineStateWithFunction:function error:&error];
 if(completionHandler)dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{completionHandler(state,error);});
}
- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)function options:(MTLPipelineOption)options completionHandler:(void (^)(id<MTLComputePipelineState>,MTLComputePipelineReflection *,NSError *))completionHandler {
 NSError *error=nil;MTLComputePipelineReflection *reflection=nil;
 id<MTLComputePipelineState> state=[(id<MTLDevice>)self newComputePipelineStateWithFunction:function options:options reflection:&reflection error:&error];
 if(completionHandler)dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{completionHandler(state,reflection,error);});
}
- (void)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)d completionHandler:(void (^)(id<MTLComputePipelineState>,NSError *))completionHandler {
 NSError *error=nil;id<MTLComputePipelineState> state=[self newComputePipelineStateWithDescriptor:d error:&error];
 if(completionHandler)dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{completionHandler(state,error);});
}
- (void)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)d options:(MTLPipelineOption)options completionHandler:(void (^)(id<MTLComputePipelineState>,MTLComputePipelineReflection *,NSError *))completionHandler {
 NSError *error=nil;MTLComputePipelineReflection *reflection=nil;
 id<MTLComputePipelineState> state=[(id<MTLDevice>)self newComputePipelineStateWithDescriptor:d options:options reflection:&reflection error:&error];
 if(completionHandler)dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{completionHandler(state,reflection,error);});
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)error {
 return [(id<MTLDevice>)self newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionNone reflection:nil error:error];
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d completionHandler:(void (^)(id<MTLRenderPipelineState>,NSError *))completionHandler {
 NSError *error=nil;id<MTLRenderPipelineState> state=[(id<MTLDevice>)self newRenderPipelineStateWithDescriptor:d error:&error];
 if(completionHandler)dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{completionHandler(state,error);});
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d options:(MTLPipelineOption)options completionHandler:(void (^)(id<MTLRenderPipelineState>,MTLRenderPipelineReflection *,NSError *))completionHandler {
 NSError *error=nil;MTLRenderPipelineReflection *reflection=nil;
 id<MTLRenderPipelineState> state=[(id<MTLDevice>)self newRenderPipelineStateWithDescriptor:d options:options reflection:&reflection error:&error];
 if(completionHandler)dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{completionHandler(state,reflection,error);});
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d options:(MTLPipelineOption)options
                                                        reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection error:(NSError **)error {
 if(reflection)*reflection=nil;
 auto *b=new BuiltRenderDescriptor();
 if(!renderDescriptor(d,b,error)){delete b;return nil;}
 std::vector<NmbBinaryArchive *> archives;
 if(!pipelineArchives(d.binaryArchives,archives,error)){delete b;return nil;}
 const NmbPipelineOptions creation={(uint64_t)options,archives.data(),archives.size()};
 const uint64_t pipelineBegan=nowUs();
 const bool logJournal=!gJournalPath.empty();
 const NBCost costBegan=logJournal?NBCost::now():NBCost{};
 NmbRenderPipeline *handle=nmb_render_pipeline_new_with_options(gDevice,&b->raw,&creation);delete b;gTimePipeline.add(pipelineBegan);
 if(logJournal)journalRenderPipeline(d,pipelineBegan,handle?nullptr:nmb_last_error(),NBCost::now().since(costBegan));
 if(!handle)return failWith<id<MTLRenderPipelineState>>(error,@"render pipeline",nil);
 NBRenderPipeline *state=[NBRenderPipeline new];state.handle=handle;gPipelines++;if(error)*error=nil;return (id<MTLRenderPipelineState>)state;
}
- (id<MTLBinaryArchive>)newBinaryArchiveWithDescriptor:(MTLBinaryArchiveDescriptor *)d error:(NSError **)error {
 if(d.url && !d.url.isFileURL){if(error)*error=nbError(@"a file URL is required");return nil;}
 NmbBinaryArchive *handle=nmb_binary_archive_new(gDevice,d.url?d.url.fileSystemRepresentation:nullptr);
 if(!handle)return failWith<id<MTLBinaryArchive>>(error,@"binary archive",nil);
 NBBinaryArchive *archive=[NBBinaryArchive new];archive.handle=handle;if(error)*error=nil;return (id<MTLBinaryArchive>)archive;
}
- (NSUInteger)requiredLinearTextureBytesPerRowForDescriptor:(MTLTextureDescriptor *)d {
 const uint64_t row=nmb_device_linear_bytes_per_row(gDevice,d.pixelFormat,d.width);
 if(!row)NBLOG(@"native-metal: requiredLinearTextureBytesPerRow: %@",lastError());
 return row;
}
- (id<MTLSamplerState>)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)d {
 NmbSamplerDescriptor s={(uint64_t)d.minFilter,(uint64_t)d.magFilter,(uint64_t)d.mipFilter,(uint64_t)d.sAddressMode,(uint64_t)d.tAddressMode,(uint64_t)d.rAddressMode,
     (uint64_t)d.borderColor,(uint64_t)d.normalizedCoordinates,d.maxAnisotropy,(uint64_t)d.compareFunction,(uint64_t)d.lodAverage,d.lodMinClamp,d.lodMaxClamp};
 NmbSampler *handle=nmb_sampler_new(gDevice,&s);
 if(!handle){NBLOG(@"native-metal: sampler refused: %@",lastError());return nil;}
 NBSampler *sampler=[NBSampler new];sampler.handle=handle;return (id<MTLSamplerState>)sampler;
}
- (id<MTLDepthStencilState>)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)d {
 auto face=[](MTLStencilDescriptor *s)->NmbStencil {
  return {(uint64_t)s.stencilCompareFunction,(uint64_t)s.stencilFailureOperation,(uint64_t)s.depthFailureOperation,(uint64_t)s.depthStencilPassOperation,s.readMask,s.writeMask};
 };
 NmbDepthStencilDescriptor s={(uint64_t)d.depthCompareFunction,(uint64_t)d.depthWriteEnabled,face(d.frontFaceStencil),face(d.backFaceStencil)};
 NmbDepthStencil *handle=nmb_depth_stencil_new(gDevice,&s);
 if(!handle){NBLOG(@"native-metal: depth/stencil state refused: %@",lastError());return nil;}
 NBDepthStencil *state=[NBDepthStencil new];state.handle=handle;
 state.readsDepth=d.depthCompareFunction!=MTLCompareFunctionAlways || d.depthWriteEnabled;
 state.writesDepth=d.depthWriteEnabled;
 auto stencilActive=[](MTLStencilDescriptor *st)->bool {
  return st && (st.stencilCompareFunction!=MTLCompareFunctionAlways || st.stencilFailureOperation!=MTLStencilOperationKeep ||
                st.depthFailureOperation!=MTLStencilOperationKeep || st.depthStencilPassOperation!=MTLStencilOperationKeep);
 };
 state.readsStencil=stencilActive(d.frontFaceStencil) || stencilActive(d.backFaceStencil);
 state.writesStencil=(d.frontFaceStencil && d.frontFaceStencil.writeMask!=0 && stencilActive(d.frontFaceStencil)) ||
                     (d.backFaceStencil && d.backFaceStencil.writeMask!=0 && stencilActive(d.backFaceStencil));
 return (id<MTLDepthStencilState>)state;
}
- (NSUInteger)minimumTextureBufferAlignmentForPixelFormat:(MTLPixelFormat)format {
 if(format==MTLPixelFormatInvalid)return 0;
 uint32_t bw=0,bh=0,bb=0;
 if(sweetBlock(format,&bw,&bh,&bb))return 0;
 static const SEL sel=sel_registerName("minimumLinearTextureAlignmentForPixelFormat:");
 const uint64_t value=askAnswer(sel,format);
 return (NSUInteger)MAX((uint64_t)64,value);
}
- (MTLSizeAndAlign)heapBufferSizeAndAlignWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
 uint64_t out[2]={0,256};
 if(gDevice && nmb_device_heap_buffer_size_and_align(gDevice,length,options,out))
  return {(NSUInteger)out[0],(NSUInteger)out[1]};
 const NSUInteger align=MAX((NSUInteger)256,(NSUInteger)getpagesize());
 return {(MAX((NSUInteger)1,length)+align-1)&~(align-1),align};
}
- (MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor *)d {
 NmbTextureDescriptor descriptor;uint64_t out[2]={0,4096};
 if(gDevice && textureDescriptor(d,&descriptor) && nmb_device_heap_texture_size_and_align(gDevice,&descriptor,out))
  return {(NSUInteger)out[0],(NSUInteger)out[1]};
 NBLOG(@"native-metal: heapTextureSizeAndAlign refused: %@",lastError());
 return {0,(NSUInteger)MAX((NSUInteger)4096,(NSUInteger)getpagesize())};
}
- (NSUInteger)currentAllocatedSize {return 0;}
- (uint64_t)recommendedMaxWorkingSetSize {return 512ull*1024*1024;}
- (uint64_t)sharedMemorySize {return 512ull*1024*1024;}
- (uint64_t)dedicatedMemorySize {return 0;}
- (BOOL)supportsSampleCount:(NSUInteger)count {return [(id<MTLDevice>)self supportsTextureSampleCount:count];}
- (BOOL)supportsBackgroundAppRole {return YES;}
- (BOOL)supportPriorityBand {return NO;}
- (BOOL)isASTCPixelFormatsSupported {return YES;}
- (BOOL)supportsExplicitVisibilityGroups {return NO;}
- (BOOL)supportsExtendedSamplerLODBiasRange {return NO;}
- (BOOL)supportsMXU {return NO;}
- (BOOL)supportsMeshShaders {return NO;}
- (BOOL)supportsPerPlaneCompression {return NO;}
- (BOOL)supportsPlacementSparse {return NO;}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane slice:(NSUInteger)slice {
 if(slice!=0)return nil;
 return [(id<MTLDevice>)self newTextureWithDescriptor:d iosurface:surface plane:plane];
}
- (id<MTLBuffer>)newBufferWithDescriptor:(id)d {
 if(!d)return nil;
 const NSUInteger len=[d respondsToSelector:@selector(length)]?[(NBBuffer *)d length]:0;
 const MTLResourceOptions opts=[d respondsToSelector:@selector(resourceOptions)]?[(NBBuffer *)d resourceOptions]:MTLResourceStorageModeShared;
 const void *ptr=[d respondsToSelector:@selector(contents)]?[(NBBuffer *)d contents]:nullptr;
 return ptr?[(id<MTLDevice>)self newBufferWithBytes:ptr length:len options:opts]:[(id<MTLDevice>)self newBufferWithLength:len options:opts];
}
- (id<MTLBuffer>)newBufferWithIOSurface:(IOSurfaceRef)surface {
 if(!surface)return nil;
 void *rawBase=IOSurfaceGetBaseAddress(surface);const size_t page=(size_t)getpagesize(),allocation=IOSurfaceGetAllocSize(surface);
 if(!page || (page&(page-1)) || !rawBase || !allocation)return nil;
 void *base=(void *)((uintptr_t)rawBase&~(page-1));
 const size_t lead=(uintptr_t)rawBase-(uintptr_t)base;
 if(allocation>SIZE_MAX-lead-(page-1))return nil;
 const size_t bytes=(lead+allocation+page-1)&~(page-1);
 return (id<MTLBuffer>)surfaceBuffer(surface,base,bytes);
}
- (id)functionHandleWithFunction:(id)f {(void)f;return nil;}
- (id)functionHandleWithFunction:(id)f resourceIndex:(uint64_t)idx {(void)f;(void)idx;return nil;}
- (id)newAccelerationStructureWithSize:(NSUInteger)size {(void)size;return nil;}
- (id)newAccelerationStructureWithSize:(NSUInteger)size resourceIndex:(uint64_t)idx {(void)size;(void)idx;return nil;}
- (id)newAccelerationStructureWithSize:(NSUInteger)size withDescriptor:(id)d {(void)size;(void)d;return nil;}
- (id)newAccelerationStructureWithBuffer:(id)b offset:(NSUInteger)off {(void)b;(void)off;return nil;}
- (id)newAccelerationStructureWithBuffer:(id)b offset:(NSUInteger)off resourceIndex:(uint64_t)idx {(void)b;(void)off;(void)idx;return nil;}
- (MTLSize)sparseTileSizeWithTextureType:(MTLTextureType)t pixelFormat:(MTLPixelFormat)f sampleCount:(NSUInteger)s {(void)t;(void)f;(void)s;return MTLSizeMake(0,0,0);}
- (MTLSize)sparseTileSizeWithTextureType:(MTLTextureType)t pixelFormat:(MTLPixelFormat)f sampleCount:(NSUInteger)s sparsePageSize:(NSInteger)p {(void)t;(void)f;(void)s;(void)p;return MTLSizeMake(0,0,0);}
- (MTLSize)tileSizeWithSparsePageSize:(NSInteger)p textureType:(MTLTextureType)t pixelFormat:(MTLPixelFormat)f sampleCount:(NSUInteger)s {(void)p;(void)t;(void)f;(void)s;return MTLSizeMake(0,0,0);}
@end

// The device queries the runtime answers (nmb_device_answer_selector), as methods of the device class. One without an argument is read once
// and installed only where the device has an answer of its own; one with an argument asks the runtime each call, and a refusal answers 0/NO
// with the reason logged.
static std::unordered_map<SEL,uint64_t> gAnswers;
static NSUInteger countAnswer(id,SEL cmd) {return (NSUInteger)gAnswers.at(cmd);}
static BOOL flagAnswer(id,SEL cmd) {return gAnswers.at(cmd)!=0;}
static uint64_t askAnswer(SEL cmd,NSUInteger arg) {
 static std::mutex lock;
 static std::unordered_map<SEL,std::unordered_map<NSUInteger,uint64_t>> kept;
 {
  std::lock_guard<std::mutex> hold(lock);
  auto answers=kept.find(cmd);
  if(answers!=kept.end()){auto answer=answers->second.find(arg);if(answer!=answers->second.end())return answer->second;}
 }
 uint64_t value=0;
 if(!nmb_device_answer(gDevice,sel_getName(cmd),arg,&value)){NBLOG(@"native-metal: %s(%lu): %@",sel_getName(cmd),(unsigned long)arg,lastError());value=0;}
 std::lock_guard<std::mutex> hold(lock);
 kept[cmd][arg]=value;
 return value;
}
static NSUInteger countArgAnswer(id,SEL cmd,NSUInteger arg) {return (NSUInteger)askAnswer(cmd,arg);}
static BOOL flagArgAnswer(id,SEL cmd,NSUInteger arg) {return askAnswer(cmd,arg)!=0;}
static void installAnswers(Class cls) {
 uint32_t kind=0;
 for(size_t i=0;const char *name=nmb_device_answer_selector(i,&kind);i++) {
  SEL sel=sel_registerName(name);uint64_t value=0;
  if(class_getInstanceMethod([NBDeviceMethods class],sel))continue;
  switch(kind) {
  case NMB_ANSWER_COUNT: case NMB_ANSWER_FLAG:
   if(!nmb_device_answer(gDevice,name,0,&value)){NBLOG(@"native-metal: no device answer: %@",lastError());continue;}
   // Extended-range 10-bit (XR10) framebuffers are withheld: this display chain presents 8-bit BGRX scanout only. The render server picks its
   // wide-gamut 64-bit (and Apple-compressed) framebuffer when a device offers them, and the display driver could not show it (int-089: the
   // swap's surface was '&w4a', 8 bytes per pixel, and every swap was refused).
   if(!strcmp(name,"supportsExtendedXR10Formats"))value=0;
   gAnswers[sel]=value;
   class_addMethod(cls,sel,kind==NMB_ANSWER_COUNT?(IMP)countAnswer:(IMP)flagAnswer,kind==NMB_ANSWER_COUNT?"Q16@0:8":"B16@0:8");
   break;
  case NMB_ANSWER_COUNT_ARG: class_addMethod(cls,sel,(IMP)countArgAnswer,"Q24@0:8Q16");break;
  case NMB_ANSWER_FLAG_ARG: class_addMethod(cls,sel,(IMP)flagArgAnswer,"B24@0:8Q16");break;
  }
 }
}

extern "C" id native_bridge_metal_open(const char *loader,const char *cache,uint64_t registryID,void (*missing)(const char *,const char *)) {
 if(gDeviceObject)return gDeviceObject;
 gMissing=missing;gInFlight=[NSMutableSet set];
 gDevice=nmb_device_open(loader,cache);
 if(!gDevice){NBLOG(@"native-metal: device refused: %s",nmb_last_error());return nil;}
 const char *logPipelines=getenv("HOT_MTL2_LOG_PIPELINES");
 if(!logPipelines)logPipelines=getenv("SWEET_MTL2_LOG_PIPELINES");
 if(cache && logPipelines && !strcmp(logPipelines,"1")){gJournalPath=std::string(cache)+"/pipelines.log";gJournalBegan=nowUs();}
 char name[128]={};nmb_device_name(gDevice,name,sizeof name);gName=[NSString stringWithUTF8String:name];gRegistryID=registryID;
 // The target families supportsFamily: answers true, with the rows of Apple's tables the device does not meet in them (nmb_device_family_waivers).
 if(!gJournalPath.empty()) {
  char waived[4096]={};nmb_device_family_waivers(gDevice,waived,sizeof waived);
  for(char *line=waived,*next;*line;line=next){next=strchr(line,'\n');if(next)*next++=0;else next=line+strlen(line);journal(std::string("F ")+line);}
 }
 Class base=objc_getClass("_MTLDevice");
#if !TARGET_OS_IPHONE
 // Host instrument: on NSObject every selector a client sends that this file lacks reaches the missing hook, instead of the host's
 // own _MTLDevice implementation.
 if(getenv("NMB_DEVICE_BASE_NSOBJECT"))base=[NSObject class];
#endif
#if TARGET_OS_IPHONE
 // The dynamic subclass adds no instance variables, so any base size works (iPadOS 17.7.11: 536 bytes).
 if(!base){NBLOG(@"native-metal: no _MTLDevice");return nil;}
 NBLOG(@"native-metal: _MTLDevice is %zu bytes",class_getInstanceSize(base));
#endif
 if(!base)base=[NSObject class];
 Class cls=objc_allocateClassPair(base,"NativeBridgeMetalDevice",0);if(!cls)return nil;
 unsigned count=0;Method *methods=class_copyMethodList([NBDeviceMethods class],&count);
 for(unsigned i=0;i<count;i++)class_addMethod(cls,method_getName(methods[i]),method_getImplementation(methods[i]),method_getTypeEncoding(methods[i]));
 free(methods);installAnswers(cls);class_addProtocol(cls,@protocol(MTLDevice));
 // The original registration (_MTLAddDevice) asserts that a plugin's device conforms to Metal's private device protocol as well; the target's own
 // drivers get it from their IOGPU base class. Conformance only answers conformsToProtocol:, the methods are still looked up one by one.
 if(Protocol *spi=objc_getProtocol("MTLDeviceSPI"))class_addProtocol(cls,spi);
 // SweetMetal2: Metal checks textures against its private implementation protocol too, and NSLogs "texture is not a
 // MTLTextureImplementation." on every miss (~600 lines/s from backboardd while scrolling). iOS 26 also checks MTLFunction
 // conformance in MTLRenderPipelineDescriptor / MTLComputePipelineDescriptor setters.
 auto adopt=[](Class c,std::initializer_list<const char *> names){
  for(const char *n:names)if(Protocol *p=objc_getProtocol(n))class_addProtocol(c,p);
 };
 adopt([NBFunction class],{"MTLFunction"});
 adopt([NBLibrary class],{"MTLLibrary"});
 adopt([NBBuffer class],{"MTLBuffer","MTLResource","MTLAllocation"});
 adopt([NBTexture class],{"MTLTexture","MTLTextureImplementation","MTLResource","MTLAllocation"});
 adopt([NBHeap class],{"MTLHeap","MTLAllocation"});
 adopt([NBSampler class],{"MTLSamplerState"});
 adopt([NBDepthStencil class],{"MTLDepthStencilState"});
 adopt([NBRenderPipeline class],{"MTLRenderPipelineState"});
 adopt([NBComputePipeline class],{"MTLComputePipelineState"});
 adopt([NBQueue class],{"MTLCommandQueue"});
 adopt([NBCommandBuffer class],{"MTLCommandBuffer"});
 adopt([NBEncoder class],{"MTLCommandEncoder"});
 adopt([NBRenderEncoder class],{"MTLRenderCommandEncoder"});
 adopt([NBComputeEncoder class],{"MTLComputeCommandEncoder"});
 adopt([NBBlitEncoder class],{"MTLBlitCommandEncoder"});
 adopt([NBEvent class],{"MTLEvent"});
 adopt([NBSharedEvent class],{"MTLSharedEvent"});
 adopt([NBFence class],{"MTLFence"});
 adopt([NBBinaryArchive class],{"MTLBinaryArchive"});
 adopt([NBResidencySet class],{"MTLResidencySet","MTLResidencySetSPI"});
 adopt([NBResourceGroup class],{"MTLResourceGroupSPI"});
 adopt([SweetTextureLayout class],{"MTLTextureLayout"});
 {Protocol *tp=objc_getProtocol("MTLTextureImplementation");
  NBLOG(@"native-metal: MTLTextureImplementation %s",tp?([NBTexture conformsToProtocol:tp]?"adopted":"not adopted"):"missing");}
 objc_registerClassPair(cls);
 gDeviceObject=[cls new];
 return gDeviceObject;
}

// Bare AIR bitcode (no metallib wrapper), which Metal itself refuses: for the bridge's own fixtures only.
extern "C" id native_bridge_metal_library_with_air(const void *bytes,size_t length) {
 NmbLibrary *handle=gDevice?nmb_library_new(gDevice,bytes,length,true):nullptr;if(!handle)return nil;
 NBLibrary *library=[NBLibrary new];library.handle=handle;[library computeLibraryHash:bytes length:length];return library;
}
extern "C" bool native_bridge_metal_shader_cache_stats(NmbShaderCacheStats *out) {
 return gDevice && nmb_device_shader_cache_stats(gDevice,out);
}
extern "C" bool native_bridge_metal_work_stats(uint64_t out[10]) {
 return gDevice && nmb_device_work_stats(gDevice,out);
}
extern "C" uint64_t native_bridge_metal_recent_commits(uint64_t windowUs) {
 const uint64_t now=nowUs();
 uint64_t count=0;
 std::lock_guard<std::mutex> lock(gCommitLock);
 for(unsigned i=0;i<32;i++) {
  const CommitRecord &r=gCommitRing[i];
  if(r.index && r.committedUs && now>=r.committedUs && (now-r.committedUs)<=windowUs)count++;
 }
 return count;
}

extern "C" size_t native_bridge_metal_status(char *out,size_t size) {
 std::lock_guard<std::mutex> lock(gProblemLock);
 return (size_t)snprintf(out,size,"c%llu/%llu d%llu p%llu x%llu R%llu D%llu F%llu M%llu C%llu B%llu %s | %s",(unsigned long long)gCommits.load(),(unsigned long long)gCommitFailures.load(),(unsigned long long)gCompleted.load(),
  (unsigned long long)gPipelines.load(),(unsigned long long)gProblems.load(),(unsigned long long)gPasses.load(),(unsigned long long)gDraws.load(),(unsigned long long)gFullScreenPasses.load(),(unsigned long long)(gBiggestPass.load()>>10),(unsigned long long)gDispatches.load(),(unsigned long long)gBlits.load(),gLastProblems[0],gLastProblems[1]);
}

static size_t native_bridge_metal_formats_locked(char *out,size_t size) {
 int n=snprintf(out,size,"tex x%llu f",(unsigned long long)gTextureRefusals.load());
 for(unsigned i=0;i<gFormatCount && n>0 && (size_t)n<size;i++)n+=snprintf(out+n,size-(size_t)n,"%u ",gFormats[i]);
 return n>0?(size_t)n:0;
}
// The benchmark's rows (native_bridge_metal_benchmark), kept for the telemetry table.
static std::mutex gBenchLock;
static char gBench[4][96];
static std::atomic<unsigned> gBenchRuns;
extern "C" size_t native_bridge_metal_benchmark(id device,const char *metallib,unsigned pairs,char *out,size_t size) {
 auto now=[]{return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);};
 // the first run fills rows 0-1 (Y, Y1), a later one rows 2-3 (Z, Z1), so a busy and an idle run are both kept
 const unsigned base=gBenchRuns++?2u:0u;
 auto put=[&](unsigned row,const char *format,auto... args){std::lock_guard<std::mutex> lock(gBenchLock);snprintf(gBench[base+row],sizeof gBench[base+row],format,args...);
  if(base)gBench[base+row][0]='Z';};
 // compute: a dependent integer chain (no memory), 100M steps
 uint64_t t=now(),x=0x9e3779b97f4a7c15ull;
 for(uint32_t i=0;i<100000000u;i++){x^=x<<13;x^=x>>7;x^=x<<17;}
 const uint64_t computeUs=(now()-t)/1000;
 // first touch: 32 MiB of fresh anonymous memory (the tablet's free memory is small), one store per 4 KiB page (the kernel's fault and zero-fill), then four memsets of it
 const size_t bytes=32u<<20;
 uint64_t faultUs=0,fillUs=0,shaUs=0;
 void *m=mmap(nullptr,bytes,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
 if(m!=MAP_FAILED) {
  volatile uint8_t *b=(volatile uint8_t *)m;
  t=now();for(size_t at=0;at<bytes;at+=4096)b[at]=1;faultUs=(now()-t)/1000;
  t=now();for(int k=0;k<4;k++)memset(m,k,bytes);fillUs=(now()-t)/1000;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  t=now();CC_SHA256(m,(CC_LONG)(16u<<20),digest);shaUs=(now()-t)/1000;
  x^=digest[0];
  munmap(m,bytes);
 }
 put(0,"Y cpu=%llums(100M) fault=%lluus/32MiB=%lluns/pg fill=%lluMB/s sha=%lluMB/s %llx",(unsigned long long)(computeUs/1000),
  (unsigned long long)faultUs,(unsigned long long)(faultUs*1000/8192),(unsigned long long)(fillUs?4ull*32*1000000/fillUs:0),
  (unsigned long long)(shaUs?16ull*1000000/shaUs:0),(unsigned long long)(x&0xf));
 // pipelines: the host tool's pairs, in its order
 uint64_t made=0,refused=0,createUs=0,createMax=0,drawUs=0,drawMax=0,libraryUs=0;
 @autoreleasepool {
  id<MTLDevice> dev=(id<MTLDevice>)device;NSError *error=nil;
  t=now();
  id<MTLLibrary> qc=metallib?[dev newLibraryWithURL:[NSURL fileURLWithPath:@(metallib)] error:&error]:nil;
  libraryUs=(now()-t)/1000;
  if(qc) {
   NSArray<NSString *> *names=qc.functionNames;
   id<MTLCommandQueue> queue=[dev newCommandQueue];
   MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
   td.usage=MTLTextureUsageRenderTarget;
   id<MTLTexture> target=[dev newTextureWithDescriptor:td];
   id<MTLBuffer> zeros=[dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
   unsigned n=0;
   for(NSString *name in names) {
    if(n>=pairs)break;
    id<MTLFunction> f=[qc newFunctionWithName:name];
    if(f.functionType!=MTLFunctionTypeVertex)continue;
    NSString *fragmentName=[name stringByReplacingOccurrencesOfString:@"_vert_" withString:@"_frag_"];
    if([fragmentName isEqualToString:name] || ![names containsObject:fragmentName])continue;
    ++n;
    MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
    d.vertexFunction=f;d.fragmentFunction=[qc newFunctionWithName:fragmentName];
    d.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
    t=now();
    id<MTLRenderPipelineState> state=[dev newRenderPipelineStateWithDescriptor:d error:&error];
    const uint64_t took=(now()-t)/1000;
    if(!state){++refused;continue;}
    ++made;createUs+=took;createMax=std::max(createMax,took);
    t=now();
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLCommandBuffer> commands=[queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder=[commands renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:state];
    for(NSUInteger i=0;i<8;++i){[encoder setVertexBuffer:zeros offset:0 atIndex:i];[encoder setFragmentBuffer:zeros offset:0 atIndex:i];}
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];[commands commit];[commands waitUntilCompleted];
    const uint64_t drew=(now()-t)/1000;
    drawUs+=drew;drawMax=std::max(drawMax,drew);
   }
  }
 }
 put(1,"Y1 qc lib=%llums made=%llu refused=%llu create=%llums max=%llums draw=%llums max=%llums",(unsigned long long)(libraryUs/1000),
  (unsigned long long)made,(unsigned long long)refused,(unsigned long long)(createUs/1000),(unsigned long long)(createMax/1000),
  (unsigned long long)(drawUs/1000),(unsigned long long)(drawMax/1000));
 size_t at=0;
 if(out && size) {
  std::lock_guard<std::mutex> lock(gBenchLock);
  out[0]=0;for(unsigned r=base;r<base+2;r++)at+=(size_t)snprintf(out+at,size>at?size-at:0,"%s\n",gBench[r]);
 }
 return at;
}
// The telemetry table the plugin streams to the kernel's log: newline-separated rows of at most 90 characters.
extern "C" size_t native_bridge_metal_telemetry(char *out,size_t size) {
 size_t at=0;out[0]=0;
 auto row=[&](const char *format,auto... args){
  char text[200];int n=snprintf(text,sizeof text,format,args...);if(n<=0)return;if(n>90)n=90;
  if(at+(size_t)n+2>=size)return;memcpy(out+at,text,(size_t)n);at+=(size_t)n;out[at++]='\n';out[at]=0;};
 auto ms=[](uint64_t us){return (unsigned long long)(us/1000);};
 {std::lock_guard<std::mutex> lock(gBenchLock);for(unsigned r=0;r<4;r++)if(gBench[r][0])row("%.90s",gBench[r]);}
 row("S c%llu/%llu d%llu p%llu x%llu R%llu D%llu F%llu M%lluk C%llu B%llu",(unsigned long long)gCommits.load(),(unsigned long long)gCommitFailures.load(),
  (unsigned long long)gCompleted.load(),(unsigned long long)gPipelines.load(),(unsigned long long)gProblems.load(),(unsigned long long)gPasses.load(),
  (unsigned long long)gDraws.load(),(unsigned long long)gFullScreenPasses.load(),(unsigned long long)(gBiggestPass.load()>>10),
  (unsigned long long)gDispatches.load(),(unsigned long long)gBlits.load());
 row("T pipeline n=%llu total=%llums max=%llums",(unsigned long long)gTimePipeline.count.load(),ms(gTimePipeline.total.load()),ms(gTimePipeline.slowest.load()));
 row("T library n=%llu total=%llums max=%llums",(unsigned long long)gTimeLibrary.count.load(),ms(gTimeLibrary.total.load()),ms(gTimeLibrary.slowest.load()));
 row("T function n=%llu total=%llums max=%llums",
  (unsigned long long)gTimeFunction.count.load(),ms(gTimeFunction.total.load()),ms(gTimeFunction.slowest.load()));
 row("G commit-to-complete n=%llu total=%llums max=%llums mean=%lluus",(unsigned long long)gTimeEncodeToCommit.count.load(),ms(gTimeEncodeToCommit.total.load()),
  ms(gTimeEncodeToCommit.slowest.load()),(unsigned long long)(gTimeEncodeToCommit.count.load()?gTimeEncodeToCommit.total.load()/gTimeEncodeToCommit.count.load():0));
 row("J scheduled wait n=%llu total=%llums max=%llums",(unsigned long long)gTimeWaitScheduled.count.load(),ms(gTimeWaitScheduled.total.load()),ms(gTimeWaitScheduled.slowest.load()));
 row("J completed wait n=%llu total=%llums max=%llums",(unsigned long long)gTimeWaitCompleted.count.load(),ms(gTimeWaitCompleted.total.load()),ms(gTimeWaitCompleted.slowest.load()));
 row("J resource wait n=%llu total=%llums max=%llums",(unsigned long long)gTimeResourceWait.count.load(),ms(gTimeResourceWait.total.load()),ms(gTimeResourceWait.slowest.load()));
 row("J resource checks=%llu skipped=%llu",(unsigned long long)gResourceChecks.load(),(unsigned long long)gResourceSkipped.load());
 row("J surface cache n=%llu bytes=%llu dup=%llu us=%llu max=%llu",(unsigned long long)gTimeSurfaceFlush.count.load(),
  (unsigned long long)gSurfaceFlushBytes.load(),(unsigned long long)gSurfaceFlushDuplicates.load(),
  (unsigned long long)gTimeSurfaceFlush.total.load(),(unsigned long long)gTimeSurfaceFlush.slowest.load());
 {
  uint64_t pbytes=0;size_t pcnt=0;
  {std::lock_guard<std::mutex> lock(gTexturePoolLock);pbytes=gTexturePoolBytes;pcnt=gTexturePool.size();}
  row("J texpool hit=%llu miss=%llu live=%zu/%lluMB",(unsigned long long)gTexturePoolHits.load(),
   (unsigned long long)gTexturePoolMisses.load(),pcnt,(unsigned long long)(pbytes>>20));
 }
 // The runtime's VkPipeline makings (the creation log, METAL2VULKAN_LOG_PIPELINES; they happen at draws, not at the state's creation) and
 // its shader cache: where the driver's compile time goes.
 uint64_t work[10]={};
 if(gDevice && nmb_device_work_stats(gDevice,work)) {
  row("V vkpipe n=%llu total=%llums max=%llums waited=%llums failed=%llu",
   (unsigned long long)work[0],ms(work[1]),ms(work[2]),ms(work[3]),(unsigned long long)work[4]);
  row("V cache hit%llu miss%llu wr%llu | msg i%llu w%llu",(unsigned long long)work[7],(unsigned long long)work[8],(unsigned long long)work[9],(unsigned long long)work[5],
   (unsigned long long)work[6]);
  char warning[200];size_t n=nmb_last_warning(warning,sizeof warning);
  if(n){row("W %.86s",warning);if(n>86)row("Wb %.86s",warning+86);}
 }
 {
  std::lock_guard<std::mutex> lock(gProblemLock);
  char formats[160];native_bridge_metal_formats_locked(formats,sizeof formats);row("F %.86s",formats);
  row("P0 %.86s",gLastProblems[0]);row("P0b %.86s",strlen(gLastProblems[0])>86?gLastProblems[0]+86:"");
  row("P1 %.86s",gLastProblems[1]);row("P1b %.86s",strlen(gLastProblems[1])>86?gLastProblems[1]+86:"");
 }
 {
  std::lock_guard<std::mutex> lock(gCommitLock);
  const uint32_t newest=(uint32_t)gCommits.load();
  row("%s","Q timing v2: per-buffer API counts; ctc=commit-to-callback; age includes caller idle");
  for(uint32_t k=0;k<20 && k<newest;k++) {
   const CommitRecord &r=gCommitRing[(newest-k)%32];
   if(r.index!=newest-k)continue;
   row("K%u t=%llu.%03llus rp%u dr%u kpx%llu cs%u bl%u ctc=%lluus",r.index,(unsigned long long)(r.committedUs/1000000),(unsigned long long)((r.committedUs/1000)%1000),
    r.work.passes,r.work.draws,(unsigned long long)(r.work.pixels>>10),r.work.dispatches,r.work.blits,(unsigned long long)r.callbackUs);
   if(k<4)row("E%u age=%lluus scheduled=%lldus",r.index,(unsigned long long)r.ageUs,(long long)r.scheduledUs);
  }
 }
 return at;
}

extern "C" size_t native_bridge_metal_formats(char *out,size_t size) {
 std::lock_guard<std::mutex> lock(gProblemLock);
 return native_bridge_metal_formats_locked(out,size);
}
