// SPDX-License-Identifier: GPL-2.0
/*
 * htmm_ioctl.c -- /dev/memtis: receive Soar per-object weights from userspace.
 *
 * Soar profiles a workload offline and derives, per allocation call-site, a
 * frequency- and footprint-stripped per-access criticality ("weight"). At run
 * time its malloc interceptor registers each allocation's virtual range with
 * the object's weight through this device; MEMTIS then maps every PEBS sample
 * address back to its range and uses the weight as aol_weight.
 * Ranges are kept in a per-mm interval tree.
 */
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/slab.h>
#include <linux/mm.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/uaccess.h>
#include <linux/rbtree.h>
#include <linux/interval_tree.h>
#include <linux/htmm.h>
#include <uapi/linux/htmm_ioctl.h>

void htmm_weight_tree_init(struct mm_struct *mm)
{
	mm->htmm_weight_tree = RB_ROOT_CACHED;
	spin_lock_init(&mm->htmm_weight_lock);
}

void htmm_weight_tree_free(struct mm_struct *mm)
{
	struct htmm_weight_node *node, *next;

	spin_lock(&mm->htmm_weight_lock);
	rbtree_postorder_for_each_entry_safe(node, next,
			&mm->htmm_weight_tree.rb_root, it.rb)
		kfree(node);
	mm->htmm_weight_tree = RB_ROOT_CACHED;
	spin_unlock(&mm->htmm_weight_lock);
}

/* 0 == not covered by any registered range (caller keeps its fallback). */
unsigned long htmm_weight_lookup(struct mm_struct *mm, unsigned long addr)
{
	struct interval_tree_node *it;
	unsigned long weight = 0;

	spin_lock(&mm->htmm_weight_lock);
	it = interval_tree_iter_first(&mm->htmm_weight_tree, addr, addr);
	if (it)
		weight = container_of(it, struct htmm_weight_node, it)->weight;
	spin_unlock(&mm->htmm_weight_lock);
	return weight;
}

/* Drop every registered range overlapping [start, last]. Caller holds lock. */
static void htmm_weight_remove_locked(struct mm_struct *mm,
		unsigned long start, unsigned long last)
{
	struct interval_tree_node *it;

	while ((it = interval_tree_iter_first(&mm->htmm_weight_tree,
					      start, last))) {
		struct htmm_weight_node *node =
			container_of(it, struct htmm_weight_node, it);
		interval_tree_remove(it, &mm->htmm_weight_tree);
		kfree(node);
	}
}

static long htmm_weight_register(struct mm_struct *mm,
		struct htmm_weight_range *r)
{
	struct htmm_weight_node *node;
	unsigned long start = r->start;
	unsigned long last;

	if (!r->len || r->start + r->len < r->start)
		return -EINVAL;
	last = r->start + r->len - 1;

	node = kmalloc(sizeof(*node), GFP_KERNEL);
	if (!node)
		return -ENOMEM;
	node->it.start = start;
	node->it.last = last;
	node->weight = r->weight;

	spin_lock(&mm->htmm_weight_lock);
	/* a fresh allocation can reuse a freed range; clear stale overlaps */
	htmm_weight_remove_locked(mm, start, last);
	interval_tree_insert(&node->it, &mm->htmm_weight_tree);
	spin_unlock(&mm->htmm_weight_lock);
	return 0;
}

static long htmm_weight_unregister(struct mm_struct *mm,
		struct htmm_weight_range *r)
{
	struct interval_tree_node *it;

	spin_lock(&mm->htmm_weight_lock);
	/* match by start address; free() only knows the pointer it got back */
	it = interval_tree_iter_first(&mm->htmm_weight_tree,
				      r->start, r->start);
	while (it) {
		struct interval_tree_node *next =
			interval_tree_iter_next(it, r->start, r->start);
		if (it->start == r->start) {
			struct htmm_weight_node *node =
				container_of(it, struct htmm_weight_node, it);
			interval_tree_remove(it, &mm->htmm_weight_tree);
			kfree(node);
		}
		it = next;
	}
	spin_unlock(&mm->htmm_weight_lock);
	return 0;
}

static long htmm_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct mm_struct *mm = current->mm;
	struct htmm_weight_range r;
	long ret;

	if (!mm)
		return -EINVAL;

	switch (cmd) {
	case HTMM_IOC_REGISTER:
		if (copy_from_user(&r, (void __user *)arg, sizeof(r)))
			return -EFAULT;
		ret = htmm_weight_register(mm, &r);
		break;
	case HTMM_IOC_UNREGISTER:
		if (copy_from_user(&r, (void __user *)arg, sizeof(r)))
			return -EFAULT;
		ret = htmm_weight_unregister(mm, &r);
		break;
	case HTMM_IOC_CLEAR:
		htmm_weight_tree_free(mm);
		ret = 0;
		break;
	default:
		ret = -ENOTTY;
	}
	return ret;
}

static const struct file_operations htmm_fops = {
	.owner		= THIS_MODULE,
	.unlocked_ioctl	= htmm_ioctl,
	.compat_ioctl	= htmm_ioctl,
	.llseek		= no_llseek,
};

static struct miscdevice htmm_miscdev = {
	.minor	= MISC_DYNAMIC_MINOR,
	.name	= "memtis",
	.fops	= &htmm_fops,
	.mode	= 0666,
};

static int __init htmm_ioctl_init(void)
{
	return misc_register(&htmm_miscdev);
}
device_initcall(htmm_ioctl_init);
