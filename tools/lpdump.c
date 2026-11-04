/*
 * lpdump - print the Android dynamic-partition (super) layout.
 *
 *   lpdump /dev/sda15
 *
 * Only reads the LP metadata at the start of the partition; the payload is not
 * touched.  One line per extent, so a logical partition split into several
 * extents can be loop-mounted with the right offset.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define LP_PARTITION_RESERVED_BYTES 4096
#define LP_METADATA_GEOMETRY_SIZE 4096

struct geometry {
	uint32_t magic;
	uint32_t struct_size;
	uint8_t checksum[32];
	uint32_t metadata_max_size;
	uint32_t metadata_slot_count;
	uint32_t logical_block_size;
};

struct table_desc {
	uint32_t offset;
	uint32_t num_entries;
	uint32_t entry_size;
};

struct header {
	uint32_t magic;
	uint16_t major_version;
	uint16_t minor_version;
	uint32_t header_size;
	uint8_t header_checksum[32];
	uint32_t tables_size;
	uint8_t tables_checksum[32];
	struct table_desc partitions;
	struct table_desc extents;
	struct table_desc groups;
	struct table_desc block_devices;
};

static int rd(int fd, void *buf, size_t len, off_t off)
{
	ssize_t n = pread(fd, buf, len, off);

	if (n != (ssize_t)len) {
		fprintf(stderr, "short read at %lld: %zd\n", (long long)off, n);
		return -1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/sda15";
	unsigned char meta[65536];
	unsigned char *tables;
	struct geometry geo;
	struct header hdr;
	int fd, i, e;

	setvbuf(stdout, NULL, _IONBF, 0);

	fd = open(dev, O_RDONLY);
	if (fd < 0) {
		perror(dev);
		return 1;
	}

	if (rd(fd, &geo, sizeof(geo), LP_PARTITION_RESERVED_BYTES))
		return 1;
	if (geo.magic != 0x616c4467) {
		fprintf(stderr, "bad geometry magic %08x\n", geo.magic);
		return 1;
	}
	printf("geometry: max_size=%u slots=%u block_size=%u\n",
	       geo.metadata_max_size, geo.metadata_slot_count,
	       geo.logical_block_size);

	if (geo.metadata_max_size > sizeof(meta))
		return 1;
	/* geometry, its backup, then the primary metadata slot */
	if (rd(fd, meta, geo.metadata_max_size,
	       LP_PARTITION_RESERVED_BYTES + 2 * LP_METADATA_GEOMETRY_SIZE))
		return 1;

	memcpy(&hdr, meta, sizeof(hdr));
	if (hdr.magic != 0x414C5030) {
		fprintf(stderr, "bad header magic %08x\n", hdr.magic);
		return 1;
	}
	printf("header: v%u.%u header_size=%u tables=%u\n", hdr.major_version,
	       hdr.minor_version, hdr.header_size, hdr.tables_size);

	/* The table offsets are relative to the end of the header. */
	tables = meta + hdr.header_size;
	if (hdr.partitions.entry_size < 52 || hdr.extents.entry_size < 24 ||
	    hdr.block_devices.entry_size < 24) {
		fprintf(stderr, "unsupported entry sizes\n");
		return 1;
	}

	for (i = 0; i < (int)hdr.partitions.num_entries; i++) {
		unsigned char *pent = tables + hdr.partitions.offset +
				      i * hdr.partitions.entry_size;
		char name[37];
		uint32_t first, num;

		memcpy(name, pent, 36);
		name[36] = 0;
		memcpy(&first, pent + 40, 4);
		memcpy(&num, pent + 44, 4);
		if (!name[0])
			continue;

		for (e = 0; e < (int)num; e++) {
			unsigned char *xent = tables + hdr.extents.offset +
					      (first + e) * hdr.extents.entry_size;
			uint64_t sectors;
			uint32_t type, data;

			memcpy(&sectors, xent, 8);
			memcpy(&type, xent + 8, 4);
			memcpy(&data, xent + 12, 4);
			printf("%-20s extent %d/%u type=%u off=%" PRIu64
			       " size=%" PRIu64 "\n",
			       name, e, num, type, (uint64_t)data * 512,
			       sectors * 512);
		}
	}

	for (i = 0; i < (int)hdr.block_devices.num_entries; i++) {
		unsigned char *bent = tables + hdr.block_devices.offset +
				      i * hdr.block_devices.entry_size;
		uint64_t first_logical, size;

		memcpy(&first_logical, bent, 8);
		memcpy(&size, bent + 16, 8);
		printf("blockdev %d: first_logical=%" PRIu64 " size=%" PRIu64 "\n",
		       i, first_logical, size);
	}

	return 0;
}
