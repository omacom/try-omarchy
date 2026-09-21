#include <assert.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include "payload-check.h"

int main(void) {
    char directory[] = "/private/tmp/omarchy-payload-test.XXXXXX";
    assert(mkdtemp(directory));
    char network[PATH_MAX], file[PATH_MAX];
    snprintf(network, sizeof(network), "%s/network", directory);
    assert(mkdir(network, 0700) == 0);
    snprintf(file, sizeof(file), "%s/network/payload", directory);
    FILE *output = fopen(file, "wb");
    assert(output);
    fputs("abc", output);
    fclose(output);
    const char *digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    assert(matches_payload(directory, "payload", digest));
    assert(!matches_payload(directory, "payload", NULL));
    assert(!matches_payload(directory, "payload", "old-protocol"));
    assert(!matches_payload(directory, "missing", digest));
    output = fopen(file, "wb");
    assert(output);
    fputs("updated build", output);
    fclose(output);
    assert(!matches_payload(directory, "payload", digest));
    assert(unlink(file) == 0);
    assert(rmdir(network) == 0);
    assert(rmdir(directory) == 0);
    return 0;
}
