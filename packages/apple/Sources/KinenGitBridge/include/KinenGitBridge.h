#ifndef KINEN_GIT_BRIDGE_H
#define KINEN_GIT_BRIDGE_H

/* Each operation owns its libgit2 handles and reports a copy of the error. */
#define KG_BUFFER_LENGTH 256

enum {
    KG_OK = 0, KG_MISSING = 1, KG_NOT_ANCESTOR = 2,
    KG_ERROR = -1, KG_HOST_UNTRUSTED = -2, KG_HOST_CHANGED = -3,
    KG_REMOTE_CHANGED = -4, KG_AUTH = -5
};

typedef struct {
    const char *url;
    const char *branch;
    const char *public_key;
    const char *private_key;
    const char *passphrase;
    const unsigned char *host_hash;
} kg_remote;

typedef struct {
    char oid[65];
    char detail[KG_BUFFER_LENGTH];
    unsigned char host_hash[32];
    int has_host_hash;
} kg_result;

int kg_fetch(const char *repository, const kg_remote *connection, kg_result *result);
int kg_is_ancestor(const char *repository, const char *ancestor, const char *revision, kg_result *result);
int kg_checkout(const char *repository, const char *revision, const char *folder, kg_result *result);
typedef int (*kg_before_push)(const char *oid, void *payload);
int kg_publish(const char *repository, const kg_remote *connection, const char *folder,
               const char *expected, kg_before_push before_push, void *payload, kg_result *result);

#endif
