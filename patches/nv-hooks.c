#include <linux/mm.h>
#include <linux/module.h>
#include <linux/preempt.h>
#include "nv-linux.h"

/* Miscellaneous internals */

#ifndef preempt_enable_no_resched
#ifdef CONFIG_PREEMPT_COUNT
#define sched_preempt_enable_no_resched() \
	do { \
		barrier(); \
		preempt_count_dec(); \
	} while (0)
#define preempt_enable_no_resched() sched_preempt_enable_no_resched()
#else
#define preempt_enable_no_resched() barrier()
#endif
#endif

#ifndef X86_CR0_WP_BIT
#define X86_CR0_WP_BIT 16
#endif

#ifndef X86_CR4_CET_BIT
#define X86_CR4_CET_BIT 23
#endif


/* Globals */

#if !defined(NV_VGPU_KVM_BUILD)
#error "Cannot apply patch to non-vGPU drivers!"
#endif

#if !defined(BLOB_TEXT_SIZE)
#error "BLOB_TEXT_SIZE must be defined by Kbuild"
#endif

extern void vup_blob_start(void);
static int vup_cr4_cet_enabled;


/* A primitive `memmem()` implementation customised for finding function signature needles.
   - TODO: Optimising with some kind of jump search would be nice, probably still possible even with -1, but not necessary. */
static uint8_t *find_sigpatch_needle(uint8_t *haystack, size_t haystacklen, int *needle, size_t needlelen)
{
	size_t matched_bytes = 0;
	for (int i = 0; i < haystacklen; i++) {
		if (matched_bytes == needlelen)
			return haystack + i - needlelen;

		if (needle[matched_bytes] == -1 || haystack[i] == needle[matched_bytes])
			matched_bytes++;
		else
			matched_bytes = 0;
	}

	return NULL;
}


/* VUP hooks */

struct vup_hook_item {
	int *sig;
	size_t siglen;
	size_t patched_instrlen;
	void (*func)(void);
};

struct vup_hook_info {
	const struct kernel_param *param;
	struct vup_hook_item *item;
};

#define VUP_HOOK_DEF(name) \
static struct vup_hook_info vup_hook_info_##name = { \
	.param = &__param_##name, \
	.item  = &vup_diff_##name, \
}
#define VUP_HOOK(name) &vup_hook_info_##name

static bool vup_enable_cuda = true;
module_param_named(cuda, vup_enable_cuda, bool, 0400);

__attribute__((naked, no_instrument_function, no_stack_protector, no_split_stack, noclone, function_return("keep")))
static void vup_hook_enable_cuda_naked(void)
{
	asm (
		"endbr64                 \n"
		"movb    $1, 0x42c(%r13) \n"	// sets the target field to 1
		"cmpb    $0, 0x968(%r14) \n"	// copies in the replaced instruction
		ASM_RET
	);
}
STACK_FRAME_NON_STANDARD(vup_hook_enable_cuda_naked);

// There have been significant changes here since R550: now, functions are added to an object that's passed as an argument. The fastest way to find this is to search for the immediate value `0xE7D23F1`, the first argument to the 'debug'/'assert' function (probably mapping to the source file), and look for a function about 512 bytes large with 3-5 instances of it.
static int vup_sighook_enable_cuda[] = { 0x41, 0x80, 0xBE, -1, -1, -1, -1, -1, 0x74, -1, 0x41, 0x80, 0xBD, -1, -1, -1, -1, -1, 0x74, -1, 0x41, 0xC6, 0x85, -1, -1, -1, -1, -1 };
static struct vup_hook_item vup_diff_cuda = {
	vup_sighook_enable_cuda, ARRAY_SIZE(vup_sighook_enable_cuda), 8, vup_hook_enable_cuda_naked
};
VUP_HOOK_DEF(cuda);

static void vup_inject_hooks(uint8_t *blob_base, size_t blob_size)
{
	struct vup_hook_info *hi;
	const char *name;
	bool arg;
	uint8_t *item_start;

	hi = VUP_HOOK(cuda);
	name = hi->param->name;
	arg = *(bool *)hi->param->arg;
	if (!arg)
		return;

	item_start = find_sigpatch_needle(blob_base, blob_size, hi->item->sig, hi->item->siglen);
	if (item_start == NULL) {
		printk(KERN_ERR "nvidia [vup]: %s hook injection failed\n", name);
		return;
	}
	/* CALL vup_hook_enable_##name_naked (and adds NOP to the remaining bytes) */
	*item_start = 0xe8;
	*(uint32_t *)(item_start + 1) = (uint8_t *)hi->item->func - (item_start + 5);
	for (int i = 5; i < hi->item->patched_instrlen; i++)
		*(item_start + i) = 0x90;
	
	printk(KERN_INFO "nvidia [vup]: hooks injection complete\n");
}


/* Entry */

static inline void vup_set_cr0(unsigned long val)
{
	asm volatile("mov %0, %%cr0" : "+r"(val) : : "memory");
}

static inline void vup_set_cr4(unsigned long val)
{
	asm volatile("mov %0, %%cr4" : "+r"(val) : : "memory");
}

static bool vup_patching_start(void)
{
	preempt_disable();
	barrier();
	unsigned long cr4 = __read_cr4();
	vup_cr4_cet_enabled = test_bit(X86_CR4_CET_BIT, &cr4);
	if (vup_cr4_cet_enabled) {
		clear_bit(X86_CR4_CET_BIT, &cr4);
		vup_set_cr4(cr4);
		barrier();
	}
	unsigned long cr0 = read_cr0();
	clear_bit(X86_CR0_WP_BIT, &cr0);
	vup_set_cr0(cr0);
	barrier();
	cr0 = read_cr0();
	if (test_bit(X86_CR0_WP_BIT, &cr0) != 0)
		return false;
	return true;
}

static void vup_patching_done(void)
{
	unsigned long cr0 = read_cr0();
	set_bit(X86_CR0_WP_BIT, &cr0);
	vup_set_cr0(cr0);
	barrier();
	if (vup_cr4_cet_enabled) {
		unsigned long cr4 = __read_cr4();
		set_bit(X86_CR4_CET_BIT, &cr4);
		vup_set_cr4(cr4);
		barrier();
	}
	preempt_enable_no_resched();
}

void vup_hooks_init(void)
{
	uint8_t *blob = (uint8_t *)vup_blob_start;

	if (vup_patching_start())
		vup_inject_hooks(blob, BLOB_TEXT_SIZE);
	vup_patching_done();
}

void vup_hooks_exit(void) { }
