/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef _UAPI_LINUX_HTMM_IOCTL_H
#define _UAPI_LINUX_HTMM_IOCTL_H

#include <linux/types.h>
#include <linux/ioctl.h>

/*
 * Userspace (Soar's malloc interceptor) -> MEMTIS handoff.
 *
 * On each tracked allocation the interceptor registers the returned
 * [start, start+len) virtual range together with the object's Soar weight
 * (frequency- and footprint-stripped per-access criticality), expressed in
 * AOL_SCALE fixed point (AOL_SCALE == neutral == "no reweighting").
 * On free it unregisters by start address. The kernel maps every PEBS
 * sample's address back to its range -> weight and uses it as aol_weight.
 */
struct htmm_weight_range {
	__u64 start;
	__u64 len;
	__u64 weight;
};

#define HTMM_IOCTL_MAGIC	'H'
#define HTMM_IOC_REGISTER	_IOW(HTMM_IOCTL_MAGIC, 1, struct htmm_weight_range)
#define HTMM_IOC_UNREGISTER	_IOW(HTMM_IOCTL_MAGIC, 2, struct htmm_weight_range)
#define HTMM_IOC_CLEAR		_IO(HTMM_IOCTL_MAGIC, 3)

#endif /* _UAPI_LINUX_HTMM_IOCTL_H */
