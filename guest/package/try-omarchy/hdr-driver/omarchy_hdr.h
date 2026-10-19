/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef OMARCHY_VIRTIO_HDR_H
#define OMARCHY_VIRTIO_HDR_H
/* Private, opt-in Try Omarchy ABI v1. Not a standard virtio feature. */
#define VIRTIO_GPU_F_OMARCHY_HDR 6
#define VIRTIO_GPU_CMD_OMARCHY_HDR 0x0400
#define OMARCHY_HDR_MAGIC 0x544f4844
struct virtio_gpu_omarchy_hdr {
 struct virtio_gpu_ctrl_hdr hdr;
 __le32 magic, version, scanout_id, resource_id;
 __le32 colorspace, eotf;
 __le32 primaries[6], whitepoint[2];
 __le32 min_luminance, max_luminance, max_cll, max_fall;
};
#endif
