/*
 * vbltest - measure the real refresh rate of a DRM CRTC by waiting for vblank
 * events, without libdrm (the two structs are defined here exactly as the
 * kernel's drm.h defines them).
 *
 * Build:
 *   aarch64-linux-gnu-gcc -static -O2 -s -o vbltest vbltest.c
 *
 *   vbltest [/dev/dri/card0] [seconds]
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define DRM_IOCTL_BASE 'd'

struct drm_wait_vblank_request {
	unsigned int type;
	unsigned int sequence;
	unsigned long signal;
};

struct drm_wait_vblank_reply {
	unsigned int type;
	unsigned int sequence;
	long tval_sec;
	long tval_usec;
};

union drm_wait_vblank {
	struct drm_wait_vblank_request request;
	struct drm_wait_vblank_reply reply;
};

#define DRM_IOWR(nr, type) _IOWR(DRM_IOCTL_BASE, nr, type)
#define DRM_IOCTL_WAIT_VBLANK DRM_IOWR(0x3a, union drm_wait_vblank)

#define _DRM_VBLANK_RELATIVE 0x1

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/dri/card0";
	double seconds = argc > 2 ? atof(argv[2]) : 3.0;
	union drm_wait_vblank vbl;
	double t0, t;
	int fd, n = 0;

	fd = open(dev, O_RDWR);
	if (fd < 0) {
		perror(dev);
		return 1;
	}

	t0 = now();
	for (;;) {
		memset(&vbl, 0, sizeof(vbl));
		vbl.request.type = _DRM_VBLANK_RELATIVE;
		vbl.request.sequence = 1;
		if (ioctl(fd, DRM_IOCTL_WAIT_VBLANK, &vbl) < 0) {
			perror("WAIT_VBLANK");
			return 1;
		}
		n++;
		t = now();
		if (t - t0 >= seconds)
			break;
	}

	printf("%d vblanks in %.3f s = %.2f Hz\n", n, t - t0, n / (t - t0));
	return 0;
}
