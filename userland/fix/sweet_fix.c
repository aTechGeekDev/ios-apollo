/*
 * libsweet-fix.dylib: small run-time fixes for iOS 16 programs on apollo, inserted by the
 * kernel (xnu 0162: sweet_exec_inject's built-in group, boot-arg sweetfix=0 turns it off).
 *
 * There is no Metal device here (the GPU is driven through Mesa/OpenGL ES, not Apple's AGX
 * driver), so MTLCreateSystemDefaultDevice() is nil, and so is every library, function and
 * pipeline made from it. Most code copes; PencilKit (the markup in the screenshot preview,
 * ScreenshotServicesService) builds an MTLComputePipelineDescriptor and gives it the nil
 * function, and Metal's own check of that argument (MTLReportFailure -> __assert_rtn) aborts
 * the process (boot 93: sig 6, -[PKMetalResourceHandler newPaintShaderKernelPipelineState]
 * <- -[MTLComputePipelineDescriptorInternal setComputeFunction:]); no screenshot is saved.
 * Here the descriptor setters that take a function ignore nil (which is what they hold
 * already): the pipeline is then asked of the nil device, which answers nil, as for every
 * other Metal object here.
 */
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef void (*setter_fn)(id, SEL, id);

#define FIXES 4
static const struct {
	const char *cls, *sel;
} fix_list[FIXES] = {
	{ "MTLComputePipelineDescriptorInternal", "setComputeFunction:" },
	{ "MTLRenderPipelineDescriptorInternal", "setVertexFunction:" },
	{ "MTLRenderPipelineDescriptorInternal", "setFragmentFunction:" },
	{ "MTLTileRenderPipelineDescriptorInternal", "setTileFunction:" },
};
static setter_fn fix_orig[FIXES];
static unsigned fix_skipped;

static void
fix_note(unsigned i)
{
	if (fix_skipped++ < 4) {
		fprintf(stderr, "sweet-fix: [%s %s] nil (no Metal device): skipped\n", fix_list[i].cls, fix_list[i].sel);
	}
}

#define FIX_SETTER(n) \
	static void fix_setter_##n(id self, SEL sel, id fn) \
	{ \
		if (fn == nil) { \
			fix_note(n); \
			return; \
		} \
		fix_orig[n](self, sel, fn); \
	}
FIX_SETTER(0)
FIX_SETTER(1)
FIX_SETTER(2)
FIX_SETTER(3)
static const IMP fix_new[FIXES] = { (IMP)fix_setter_0, (IMP)fix_setter_1, (IMP)fix_setter_2, (IMP)fix_setter_3 };

__attribute__((constructor))
static void
sweet_fix_init(void)
{
	unsigned done = 0;

	/* Metal.framework is in the shared cache; make sure its classes are loaded */
	objc_getClass("MTLComputePipelineDescriptor");
	for (unsigned i = 0; i < FIXES; i++) {
		Class c = objc_getClass(fix_list[i].cls);
		Method m = c != Nil ? class_getInstanceMethod(c, sel_registerName(fix_list[i].sel)) : NULL;

		if (m == NULL) {
			continue;
		}
		fix_orig[i] = (setter_fn)method_setImplementation(m, fix_new[i]);
		done++;
	}
	fprintf(stderr, "sweet-fix: pid %d: %u of %u Metal setters accept a nil function\n", getpid(), done, FIXES);
}
