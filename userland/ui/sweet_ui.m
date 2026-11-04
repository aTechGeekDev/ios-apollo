/*
 * libsweet-ui.dylib: UI changes for SpringBoard and the apps, inserted by the kernel (xnu 0183, option apollo_ui=1).
 *
 * The status bar of the iPhone 14 Pro. UIKit picks a status bar "visual provider" for the phone's own screen in
 * __UIStatusBarGetVisualProviderClassForScreen (UIKitCore 20H392, 0x1891aaa80; ios-re runs 41811694262, 41813238843).
 * Unless a UIKit default names one, it asks the providers by width, scale, idiom and corner radius: this port
 * presents the iPhone X's 375 points (xnu 0152), so it gets _UIStatusBarVisualProvider_Split1125, the X's layout,
 * whose clock sits in the top-left corner -- under the Mi 10T's punch hole. The default it reads first,
 * UIStatusBarVisualProviderClassName, can name any provider class; the 14 Pro's is _UIStatusBarVisualProvider_
 * DynamicSplit(Medium), which lays the items out on both sides of the screen's exclusion area (the Dynamic Island,
 * there since --artwork-subtype 2556), so the clock moves in from the corner, next to the island.
 *
 * Here -[NSUserDefaults objectForKey:] answers that one key when nothing else does: SWEET_UI_STATUS_BAR in the
 * environment, else DynamicSplitMedium (the narrower 14 Pro's variant: DynamicSplit itself picks it below a width
 * that 375 points is under). A value set in the defaults themselves still wins.
 *
 * The island to lay out around (boot 122: the 14 Pro layout came up, but the clock and the icons sat in the top corners,
 * not beside the island's middle). DynamicSplit takes it from -sensorAreaRect = [[screen _displayInfoProvider]
 * exclusionArea].rect (UIKitCore 20H392; ios-re 41835145774): this display has no exclusion area, so the rect is empty
 * and the items fall to the edges. When it is empty, -sensorAreaRect answers the 14 Pro's island, centred on the
 * screen's width (SpringBoard draws the island there). Only the status bar's own question: _exclusionArea itself (which
 * __UIScreenTypeForScreen also reads) is left alone.
 *
 * The flashlight (SpringBoard only: Control Center's button and the lock screen's). AVFlashlight (AVFCapture) asks
 * mediaserverd's camera for a torch, which this port does not have, so iOS's button stays off. Here AVFlashlight says
 * it has one and drives the kernel's: sysctl apollo.torch (xnu 0181, mkadt --option apollo_torch=1; mA per channel),
 * levels 0..1 as 0..150 mA.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>

static NSString *const kProviderKey = @"UIStatusBarVisualProviderClassName";
static NSString *sweet_provider;
static id (*orig_objectForKey)(id, SEL, NSString *);

static id
sweet_objectForKey(id self, SEL _cmd, NSString *key)
{
	id value = orig_objectForKey(self, _cmd, key);

	if (value == nil && sweet_provider != nil && [key isKindOfClass:[NSString class]] && [key isEqualToString:kProviderKey]) {
		return sweet_provider;
	}
	return value;
}

/* ---- the island the status bar lays out around ------------------------------------------------------------------- */

/* the iPhone 14 Pro's island in points (393 wide there): 126 x 37.33, 11.33 from the top, centred */
#define SWEET_ISLAND_WIDTH      126.0
#define SWEET_ISLAND_HEIGHT     37.33
#define SWEET_ISLAND_TOP        11.33

static CGRect (*orig_sensorAreaRect)(id, SEL);

static CGRect
sweet_sensorAreaRect(id self, SEL _cmd)
{
	CGRect r = orig_sensorAreaRect(self, _cmd);

	if (r.size.width >= 1.0 && r.size.height >= 1.0) {
		return r;       /* a real exclusion area: keep it */
	}
	CGSize screen = [UIScreen mainScreen].bounds.size;
	CGFloat width = screen.width < screen.height ? screen.width : screen.height;
	return CGRectMake((width - SWEET_ISLAND_WIDTH) / 2.0, SWEET_ISLAND_TOP, SWEET_ISLAND_WIDTH, SWEET_ISLAND_HEIGHT);
}

/* ---- the flashlight (SpringBoard) ------------------------------------------------------------------------------- */

#define SWEET_TORCH_MAX_MA      150
static float sweet_torch_level;

static BOOL
sweet_torch_set(id flashlight, float level)
{
	int ma = level <= 0.0f ? 0 : (int)(level * SWEET_TORCH_MAX_MA + 0.5f);

	if (ma > SWEET_TORCH_MAX_MA) {
		ma = SWEET_TORCH_MAX_MA;
	}
	if (ma > 0 && ma < 5) {
		ma = 5;
	}
	if (sysctlbyname("apollo.torch", NULL, NULL, &ma, sizeof(ma)) != 0) {
		NSLog(@"sweet-ui: apollo.torch = %d: %s", ma, strerror(errno));
		return NO;
	}
	[flashlight willChangeValueForKey:@"flashlightLevel"];
	sweet_torch_level = ma == 0 ? 0.0f : level;
	[flashlight didChangeValueForKey:@"flashlightLevel"];
	return YES;
}

static BOOL sweet_fl_has(id self, SEL _cmd) { (void)self; (void)_cmd; return YES; }
static BOOL sweet_fl_available(id self, SEL _cmd) { (void)self; (void)_cmd; return YES; }
static BOOL sweet_fl_overheated(id self, SEL _cmd) { (void)self; (void)_cmd; return NO; }
static float sweet_fl_level(id self, SEL _cmd) { (void)self; (void)_cmd; return sweet_torch_level; }

static BOOL
sweet_fl_set_level(id self, SEL _cmd, float level, NSError **error)
{
	(void)_cmd;
	BOOL ok = sweet_torch_set(self, level);
	if (!ok && error != NULL) {
		*error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
	}
	return ok;
}

static BOOL
sweet_fl_on(id self, SEL _cmd, NSError **error)
{
	return sweet_fl_set_level(self, _cmd, 1.0f, error);
}

static void
sweet_fl_off(id self, SEL _cmd)
{
	(void)_cmd;
	(void)sweet_torch_set(self, 0.0f);
}

/*
 * Boots 123/124 stuck at the Apple logo, SpringBoard alive but no frames (124 even without Metal), right after
 * +hasFlashlight began to say YES: SpringBoard then makes an AVFlashlight, whose -init (_setupFlashlight) connects to
 * mediaserverd's FigFlashlight -- there is no camera behind it here, so that wait does not end (guess: the likeliest of
 * this library's changes since boot 122). AVFlashlight never talks to the server now: the torch is ours.
 */
static void
sweet_fl_nothing(id self, SEL _cmd)
{
	(void)self;
	(void)_cmd;
}

static void
sweet_replace(Class cls, SEL sel, IMP imp, BOOL meta)
{
	Class target = meta ? object_getClass(cls) : cls;
	Method m = class_getInstanceMethod(target, sel);

	if (m != NULL) {
		method_setImplementation(m, imp);
	} else {
		NSLog(@"sweet-ui: %@ has no %s%@", cls, meta ? "+" : "-", NSStringFromSelector(sel));
	}
}

static void
sweet_flashlight_start(void)
{
	int ma = 0;
	size_t size = sizeof(ma);

	if (strcmp(getprogname(), "SpringBoard") != 0) {
		return;
	}
	if (sysctlbyname("apollo.torch", &ma, &size, NULL, 0) != 0) {
		NSLog(@"sweet-ui: no apollo.torch in this kernel: iOS's flashlight left as it is");
		return;
	}
	(void)dlopen("/System/Library/PrivateFrameworks/AVFCapture.framework/AVFCapture", RTLD_LAZY);
	Class fl = NSClassFromString(@"AVFlashlight");
	if (fl == Nil) {
		NSLog(@"sweet-ui: no AVFlashlight: iOS's flashlight left as it is");
		return;
	}
	sweet_replace(fl, NSSelectorFromString(@"_setupFlashlight"), (IMP)sweet_fl_nothing, NO);
	sweet_replace(fl, NSSelectorFromString(@"_reconnectToServer"), (IMP)sweet_fl_nothing, NO);
	sweet_replace(fl, NSSelectorFromString(@"_teardownFlashlight"), (IMP)sweet_fl_nothing, NO);
	sweet_replace(fl, @selector(hasFlashlight), (IMP)sweet_fl_has, YES);
	sweet_replace(fl, NSSelectorFromString(@"isAvailable"), (IMP)sweet_fl_available, NO);
	sweet_replace(fl, NSSelectorFromString(@"isOverheated"), (IMP)sweet_fl_overheated, NO);
	sweet_replace(fl, NSSelectorFromString(@"flashlightLevel"), (IMP)sweet_fl_level, NO);
	sweet_replace(fl, NSSelectorFromString(@"setFlashlightLevel:withError:"), (IMP)sweet_fl_set_level, NO);
	sweet_replace(fl, NSSelectorFromString(@"turnPowerOnWithError:"), (IMP)sweet_fl_on, NO);
	sweet_replace(fl, NSSelectorFromString(@"turnPowerOff"), (IMP)sweet_fl_off, NO);
	NSLog(@"sweet-ui: iOS's flashlight drives apollo.torch (now %d mA)", ma);
}

__attribute__((constructor))
static void
sweet_ui_start(void)
{
	@autoreleasepool {
		sweet_flashlight_start();
		const char *env = getenv("SWEET_UI_STATUS_BAR");
		NSString *name = env != NULL && *env != '\0' ? @(env) : @"_UIStatusBarVisualProvider_DynamicSplitMedium";

		/* only a class this UIKit has (UIKitCore is loaded before inserted libraries' initializers run in an app) */
		if (NSClassFromString(name) == Nil) {
			NSLog(@"sweet-ui: no class %@ here: the status bar is left as it is", name);
			return;
		}
		sweet_provider = [name copy];
		Method sensor = class_getInstanceMethod(NSClassFromString(@"_UIStatusBarVisualProvider_DynamicSplit"),
		    NSSelectorFromString(@"sensorAreaRect"));
		if (sensor != NULL) {
			orig_sensorAreaRect = (CGRect (*)(id, SEL))method_setImplementation(sensor, (IMP)sweet_sensorAreaRect);
		}
		Method m = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
		if (m == NULL) {
			return;
		}
		orig_objectForKey = (id (*)(id, SEL, NSString *))method_setImplementation(m, (IMP)sweet_objectForKey);
	}
}
