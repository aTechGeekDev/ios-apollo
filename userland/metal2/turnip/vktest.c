/*
 * vktest: Turnip (libvulkan_freedreno.dylib, darwin backend) on the A640 through SweetAccelerator v2.
 *   vktest [LIB]      (default /var/local/lib/libvulkan_freedreno.dylib)
 * Steps, each checked: device info, a buffer fill + copy, a compute shader compiled on the phone,
 * a triangle rendered into a 256x256 RGBA8 image and read back. Prints PASS/FAIL per step.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include "shaders.h"	/* fill_comp, tri_vert, tri_frag: SPIR-V words (build.sh) */

static PFN_vkGetInstanceProcAddr gipa;
static PFN_vkGetDeviceProcAddr gdpa;
static VkInstance inst;
static VkDevice dev;
#define IFN(n) PFN_##n n = (PFN_##n)gipa(inst, #n)
#define DFN(n) PFN_##n n = (PFN_##n)gdpa(dev, #n)

static double now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("FAIL %s -> %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static VkPhysicalDeviceMemoryProperties memprops;

static uint32_t memtype(uint32_t bits, VkMemoryPropertyFlags want)
{
	for (uint32_t i = 0; i < memprops.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (memprops.memoryTypes[i].propertyFlags & want) == want)
			return i;
	printf("FAIL no memory type for %x/%x\n", bits, want);
	exit(1);
}

struct buf { VkBuffer b; VkDeviceMemory m; void *p; };

static struct buf mkbuf(VkDeviceSize size, VkBufferUsageFlags usage)
{
	DFN(vkCreateBuffer); DFN(vkGetBufferMemoryRequirements); DFN(vkAllocateMemory); DFN(vkBindBufferMemory);
	DFN(vkMapMemory);
	struct buf r;
	VkBufferCreateInfo bi = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage };
	CHECK(vkCreateBuffer(dev, &bi, NULL, &r.b));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, r.b, &mr);
	VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = memtype(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
	CHECK(vkAllocateMemory(dev, &ai, NULL, &r.m));
	CHECK(vkBindBufferMemory(dev, r.b, r.m, 0));
	CHECK(vkMapMemory(dev, r.m, 0, VK_WHOLE_SIZE, 0, &r.p));
	return r;
}

static VkQueue queue;
static VkCommandPool pool;

static VkCommandBuffer begin(void)
{
	DFN(vkAllocateCommandBuffers); DFN(vkBeginCommandBuffer);
	VkCommandBuffer cb;
	VkCommandBufferAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
	CHECK(vkAllocateCommandBuffers(dev, &ai, &cb));
	VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	CHECK(vkBeginCommandBuffer(cb, &bi));
	return cb;
}

static double submit_wait(VkCommandBuffer cb)
{
	DFN(vkEndCommandBuffer); DFN(vkCreateFence); DFN(vkQueueSubmit); DFN(vkWaitForFences); DFN(vkDestroyFence);
	DFN(vkFreeCommandBuffers);
	CHECK(vkEndCommandBuffer(cb));
	VkFence f;
	VkFenceCreateInfo fi = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
	CHECK(vkCreateFence(dev, &fi, NULL, &f));
	VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
	double t0 = now_ms();
	CHECK(vkQueueSubmit(queue, 1, &si, f));
	CHECK(vkWaitForFences(dev, 1, &f, VK_TRUE, 3000000000ull));
	double t = now_ms() - t0;
	vkDestroyFence(dev, f, NULL);
	vkFreeCommandBuffers(dev, pool, 1, &cb);
	return t;
}

/* round trip of an empty command buffer: what one submit costs (kernel wrapper, fence, wake-up) */
static int test_empty(void)
{
	double best = 1e9, sum = 0;
	const int n = 40;
	for (int i = 0; i < n; i++) {
		double t = submit_wait(begin());
		sum += t;
		if (t < best)
			best = t;
	}
	printf("PASS empty submit round trip: mean %.3f ms, best %.3f ms (%d)\n", sum / n, best, n);
	return 0;
}

static VkShaderModule module(const uint32_t *code, size_t bytes)
{
	DFN(vkCreateShaderModule);
	VkShaderModule m;
	VkShaderModuleCreateInfo ci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = bytes, .pCode = code };
	CHECK(vkCreateShaderModule(dev, &ci, NULL, &m));
	return m;
}

static int test_fill(void)
{
	DFN(vkCmdFillBuffer); DFN(vkCmdCopyBuffer); DFN(vkCmdPipelineBarrier);
	const uint32_t n = 1 << 18;	/* 1 MB */
	struct buf a = mkbuf(4 * n, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT);
	struct buf b = mkbuf(4 * n, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
	memset(b.p, 0, 4 * n);
	VkCommandBuffer cb = begin();
	vkCmdFillBuffer(cb, a.b, 0, 4 * n, 0x5eed1234);
	VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT };
	vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
	VkBufferCopy c = { 0, 0, 4 * n };
	vkCmdCopyBuffer(cb, a.b, b.b, 1, &c);
	double t = submit_wait(cb);
	uint32_t bad = 0;
	for (uint32_t i = 0; i < n; i++)
		bad += ((uint32_t *)b.p)[i] != 0x5eed1234;
	printf("%s fill+copy 1 MB: %u wrong words, %.2f ms\n", bad ? "FAIL" : "PASS", bad, t);
	return bad != 0;
}

static int test_compute(void)
{
	DFN(vkCreateDescriptorSetLayout); DFN(vkCreatePipelineLayout); DFN(vkCreateComputePipelines);
	DFN(vkCreateDescriptorPool); DFN(vkAllocateDescriptorSets); DFN(vkUpdateDescriptorSets);
	DFN(vkCmdBindPipeline); DFN(vkCmdBindDescriptorSets); DFN(vkCmdDispatch);
	const uint32_t n = 65536;
	struct buf o = mkbuf(4 * n, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
	memset(o.p, 0, 4 * n);
	VkDescriptorSetLayoutBinding lb = { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL };
	VkDescriptorSetLayoutCreateInfo lci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1,
		.pBindings = &lb };
	VkDescriptorSetLayout dsl;
	CHECK(vkCreateDescriptorSetLayout(dev, &lci, NULL, &dsl));
	VkPipelineLayoutCreateInfo pli = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl };
	VkPipelineLayout pl;
	CHECK(vkCreatePipelineLayout(dev, &pli, NULL, &pl));
	VkComputePipelineCreateInfo cpi = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
			   .module = module(fill_comp, sizeof(fill_comp)), .pName = "main" },
		.layout = pl };
	VkPipeline p;
	double t0 = now_ms();
	CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpi, NULL, &p));
	double tc = now_ms() - t0;
	VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
	VkDescriptorPoolCreateInfo dpi = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1,
		.pPoolSizes = &ps };
	VkDescriptorPool dp;
	CHECK(vkCreateDescriptorPool(dev, &dpi, NULL, &dp));
	VkDescriptorSetAllocateInfo dai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp,
		.descriptorSetCount = 1, .pSetLayouts = &dsl };
	VkDescriptorSet ds;
	CHECK(vkAllocateDescriptorSets(dev, &dai, &ds));
	VkDescriptorBufferInfo dbi = { o.b, 0, VK_WHOLE_SIZE };
	VkWriteDescriptorSet w = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .descriptorCount = 1,
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi };
	vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
	VkCommandBuffer cb = begin();
	vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, p);
	vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &ds, 0, NULL);
	vkCmdDispatch(cb, n / 64, 1, 1);
	double t = submit_wait(cb);
	uint32_t bad = 0;
	for (uint32_t i = 0; i < n; i++)
		bad += ((uint32_t *)o.p)[i] != i * 3 + 1;
	printf("%s compute (shader compiled on the phone in %.1f ms): %u wrong of %u, %.2f ms\n", bad ? "FAIL" : "PASS", tc,
	       bad, n, t);
	return bad != 0;
}

static int test_draw(void)
{
	DFN(vkCreateImage); DFN(vkGetImageMemoryRequirements); DFN(vkAllocateMemory); DFN(vkBindImageMemory);
	DFN(vkCreateImageView); DFN(vkCreatePipelineLayout); DFN(vkCreateGraphicsPipelines);
	DFN(vkCmdPipelineBarrier); DFN(vkCmdBeginRendering); DFN(vkCmdEndRendering); DFN(vkCmdBindPipeline);
	DFN(vkCmdDraw); DFN(vkCmdCopyImageToBuffer); DFN(vkCmdSetViewport); DFN(vkCmdSetScissor);
	const uint32_t W = 256, H = 256;
	VkImageCreateInfo ii = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT };
	VkImage img;
	CHECK(vkCreateImage(dev, &ii, NULL, &img));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, img, &mr);
	VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = memtype(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
	VkDeviceMemory im;
	CHECK(vkAllocateMemory(dev, &ai, NULL, &im));
	CHECK(vkBindImageMemory(dev, img, im, 0));
	VkImageViewCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img, .viewType = VK_IMAGE_VIEW_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CHECK(vkCreateImageView(dev, &vi, NULL, &view));
	struct buf out = mkbuf(4 * W * H, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
	memset(out.p, 0xcd, 4 * W * H);

	VkPipelineLayoutCreateInfo pli = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
	VkPipelineLayout pl;
	CHECK(vkCreatePipelineLayout(dev, &pli, NULL, &pl));
	VkPipelineShaderStageCreateInfo st[2] = {
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
		  .module = module(tri_vert, sizeof(tri_vert)), .pName = "main" },
		{ .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
		  .module = module(tri_frag, sizeof(tri_frag)), .pName = "main" },
	};
	VkPipelineVertexInputStateCreateInfo vin = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
	VkPipelineViewportStateCreateInfo vp = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1,
		.scissorCount = 1 };
	VkPipelineRasterizationStateCreateInfo rs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
	VkPipelineMultisampleStateCreateInfo ms = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cb = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &cba };
	VkDynamicState dyn[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
	VkPipelineDynamicStateCreateInfo ds = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2,
		.pDynamicStates = dyn };
	VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
	VkPipelineRenderingCreateInfo ri = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .colorAttachmentCount = 1,
		.pColorAttachmentFormats = &fmt };
	VkGraphicsPipelineCreateInfo gpi = { .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &ri,
		.stageCount = 2, .pStages = st, .pVertexInputState = &vin, .pInputAssemblyState = &ia, .pViewportState = &vp,
		.pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cb, .pDynamicState = &ds, .layout = pl };
	VkPipeline p;
	double t0 = now_ms();
	CHECK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpi, NULL, &p));
	double tc = now_ms() - t0;

	VkCommandBuffer c = begin();
	VkImageMemoryBarrier b0 = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
		.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .image = img,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL, 0, NULL, 1, &b0);
	VkRenderingAttachmentInfo att = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
		.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
		.storeOp = VK_ATTACHMENT_STORE_OP_STORE, .clearValue.color.float32 = { 0, 0, 1, 1 } };
	VkRenderingInfo rinfo = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { W, H } }, .layerCount = 1,
		.colorAttachmentCount = 1, .pColorAttachments = &att };
	vkCmdBeginRendering(c, &rinfo);
	vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, p);
	VkViewport v = { 0, 0, W, H, 0, 1 };
	VkRect2D sc = { { 0, 0 }, { W, H } };
	vkCmdSetViewport(c, 0, 1, &v);
	vkCmdSetScissor(c, 0, 1, &sc);
	vkCmdDraw(c, 3, 1, 0, 0);
	vkCmdEndRendering(c);
	VkImageMemoryBarrier b1 = b0;
	b1.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
	b1.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
	b1.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
	b1.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
	vkCmdPipelineBarrier(c, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b1);
	VkBufferImageCopy bic = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { W, H, 1 } };
	vkCmdCopyImageToBuffer(c, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, out.b, 1, &bic);
	double t = submit_wait(c);

	/* the triangle (tri.vert: (-0.8,-0.8) (0.8,-0.8) (0,0.8)) is red, the rest the blue clear */
	const uint32_t *px = out.p;
	uint32_t red = 0, blue = 0, other = 0;
	for (uint32_t i = 0; i < W * H; i++) {
		if (px[i] == 0xff0000ff)
			red++;
		else if (px[i] == 0xffff0000)
			blue++;
		else
			other++;
	}
	int ok = px[(H / 2) * W + W / 2] == 0xff0000ff && px[2 * W + 2] == 0xffff0000 && other == 0 && red > W * H / 4;
	printf("%s draw 256x256 (pipeline compiled on the phone in %.1f ms): %u red, %u blue, %u other; centre %08x corner %08x, %.2f ms\n",
	       ok ? "PASS" : "FAIL", tc, red, blue, other, px[(H / 2) * W + W / 2], px[2 * W + 2], t);
	FILE *f = fopen("/var/local/vktest.raw", "wb");
	if (f) {
		fwrite(out.p, 4, W * H, f);
		fclose(f);
	}
	return !ok;
}

int main(int argc, char **argv)
{
	const char *lib = argc > 1 ? argv[1] : "/var/local/lib/libvulkan_freedreno.dylib";
	double t0 = now_ms();
	void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
	if (!h) {
		printf("FAIL dlopen: %s\n", dlerror());
		return 1;
	}
	gipa = (PFN_vkGetInstanceProcAddr)dlsym(h, "vkGetInstanceProcAddr");
	if (!gipa) {
		printf("FAIL no vkGetInstanceProcAddr\n");
		return 1;
	}
	printf("loaded %s in %.0f ms\n", lib, now_ms() - t0);
	PFN_vkCreateInstance vkCreateInstance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
	VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vktest", .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	CHECK(vkCreateInstance(&ici, NULL, &inst));
	IFN(vkEnumeratePhysicalDevices); IFN(vkGetPhysicalDeviceProperties); IFN(vkGetPhysicalDeviceMemoryProperties);
	IFN(vkCreateDevice); IFN(vkGetDeviceProcAddr) ;
	gdpa = vkGetDeviceProcAddr;
	uint32_t n = 1;
	VkPhysicalDevice pd;
	VkResult er = vkEnumeratePhysicalDevices(inst, &n, &pd);
	if (er != VK_SUCCESS && er != VK_INCOMPLETE) {
		printf("FAIL vkEnumeratePhysicalDevices -> %d\n", er);
		return 1;
	}
	if (n == 0) {
		printf("FAIL no physical device (is SweetAccelerator v2 there?)\n");
		return 1;
	}
	VkPhysicalDeviceProperties pp;
	vkGetPhysicalDeviceProperties(pd, &pp);
	vkGetPhysicalDeviceMemoryProperties(pd, &memprops);
	printf("PASS device: %s, Vulkan %u.%u.%u, driver %x, %u memory types\n", pp.deviceName, VK_API_VERSION_MAJOR(pp.apiVersion),
	       VK_API_VERSION_MINOR(pp.apiVersion), VK_API_VERSION_PATCH(pp.apiVersion), pp.driverVersion, memprops.memoryTypeCount);
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1,
		.pQueuePriorities = &prio };
	VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .dynamicRendering = VK_TRUE };
	VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f13, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci };
	t0 = now_ms();
	CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
	printf("PASS device created in %.0f ms\n", now_ms() - t0);
	DFN(vkGetDeviceQueue); DFN(vkCreateCommandPool);
	vkGetDeviceQueue(dev, 0, 0, &queue);
	VkCommandPoolCreateInfo cpi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0 };
	CHECK(vkCreateCommandPool(dev, &cpi, NULL, &pool));
	int fails = test_empty();
	fails += test_fill();
	fails += test_compute();
	fails += test_draw();
	printf("%s: %d failed\n", fails ? "FAIL" : "ALL PASS", fails);
	return fails != 0;
}
