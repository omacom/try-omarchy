#include <CommonCrypto/CommonDigest.h>
#include <stdbool.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

static bool matches_payload(const char *resources, const char *name, const char *expected) {
    if (!expected || strlen(expected) != 64) return false;
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/network/%s", resources, name) >= (int)sizeof(path)) return false;
    FILE *file = fopen(path, "rb");
    if (!file) return false;
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    unsigned char buffer[16384], digest[CC_SHA256_DIGEST_LENGTH];
    size_t count;
    while ((count = fread(buffer, 1, sizeof(buffer), file)) > 0) CC_SHA256_Update(&hash, buffer, (CC_LONG)count);
    bool valid = !ferror(file);
    fclose(file);
    CC_SHA256_Final(digest, &hash);
    char hex[65];
    for (size_t i = 0; i < sizeof(digest); ++i) sprintf(hex + 2*i, "%02x", digest[i]);
    return valid && !strcmp(hex, expected);
}
