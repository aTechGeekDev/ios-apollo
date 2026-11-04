/*
 * libsweet-ui.dylib: UI changes for SpringBoard and the apps, inserted by the kernel (xnu 0175, option apollo_ui=1).
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
 * that 375 points is under). A value set in the defaults themselves still wins. Nothing else is changed.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

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

__attribute__((constructor))
static void
sweet_ui_start(void)
{
	@autoreleasepool {
		const char *env = getenv("SWEET_UI_STATUS_BAR");
		NSString *name = env != NULL && *env != '\0' ? @(env) : @"_UIStatusBarVisualProvider_DynamicSplitMedium";

		/* only a class this UIKit has (UIKitCore is loaded before inserted libraries' initializers run in an app) */
		if (NSClassFromString(name) == Nil) {
			NSLog(@"sweet-ui: no class %@ here: the status bar is left as it is", name);
			return;
		}
		sweet_provider = [name copy];
		Method m = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
		if (m == NULL) {
			return;
		}
		orig_objectForKey = (id (*)(id, SEL, NSString *))method_setImplementation(m, (IMP)sweet_objectForKey);
	}
}
