/*
 * Userspace harness for the kernel module's tob_parse().
 *
 * The parser under test is NOT copied here. test_tob_parse.py slices the
 * struct, the status-token table and tob_parse() verbatim out of
 * guest/native-module/try-omarchy-battery/try-omarchy-battery.c into
 * tob_parse_extract.c, which this file compiles against the handful of kernel
 * helpers the parser uses. A drift between the shipped module and the tested
 * parser is therefore impossible.
 *
 * Reads one state line on stdin. Prints the parsed fields, or "ERR <errno>".
 */

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))
#define GFP_KERNEL 0

/* power_supply.h status values; only their distinctness matters here. */
enum {
	POWER_SUPPLY_STATUS_UNKNOWN = 0,
	POWER_SUPPLY_STATUS_CHARGING,
	POWER_SUPPLY_STATUS_DISCHARGING,
	POWER_SUPPLY_STATUS_NOT_CHARGING,
	POWER_SUPPLY_STATUS_FULL,
};

static char *kstrndup(const char *source, size_t max, int flags)
{
	(void)flags;
	return strndup(source, max);
}

static void kfree(void *pointer)
{
	free(pointer);
}

/* lib/kstrtox.c: accepts y/Y/1, n/N/0, on/off; one trailing newline is fine. */
static int kstrtobool(const char *text, bool *result)
{
	if (!text)
		return -EINVAL;
	switch (text[0]) {
	case 'y':
	case 'Y':
	case '1':
		*result = true;
		break;
	case 'n':
	case 'N':
	case '0':
		*result = false;
		break;
	case 'o':
	case 'O':
		switch (text[1]) {
		case 'n':
		case 'N':
			*result = true;
			return 0;
		case 'f':
		case 'F':
			*result = false;
			return 0;
		default:
			return -EINVAL;
		}
	default:
		return -EINVAL;
	}
	if (text[1] == '\0' || text[1] == '\n')
		return 0;
	return -EINVAL;
}

/* lib/kstrtox.c: no leading space, digits only, one trailing newline. */
static int kstrtoint(const char *text, unsigned int base, int *result)
{
	const char *cursor = text;
	long long value = 0;
	bool negative = false;
	bool digits = false;

	if (base != 10 || !text)
		return -EINVAL;
	if (*cursor == '-') {
		negative = true;
		cursor++;
	} else if (*cursor == '+') {
		cursor++;
	}
	for (; *cursor >= '0' && *cursor <= '9'; cursor++) {
		digits = true;
		value = value * 10 + (*cursor - '0');
		if (value > 4294967296LL)
			return -ERANGE;
	}
	if (!digits)
		return -EINVAL;
	if (*cursor == '\n')
		cursor++;
	if (*cursor != '\0')
		return -EINVAL;
	if (negative)
		value = -value;
	if (value < -2147483648LL || value > 2147483647LL)
		return -ERANGE;
	*result = (int)value;
	return 0;
}

#include "tob_parse_extract.c"

int main(void)
{
	static char buffer[8192];
	struct tob_state parsed;
	size_t count = fread(buffer, 1, sizeof(buffer) - 1, stdin);
	int error;

	buffer[count] = '\0';
	error = tob_parse(buffer, count, &parsed);
	if (error) {
		printf("ERR %d\n", -error);
		return 0;
	}
	printf("OK present=%d status=%d capacity=%d ac=%d time_to_empty=%d time_to_full=%d\n",
	       parsed.present ? 1 : 0, parsed.status, parsed.capacity,
	       parsed.ac_online ? 1 : 0, parsed.time_to_empty,
	       parsed.time_to_full);
	return 0;
}
