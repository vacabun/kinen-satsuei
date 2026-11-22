#include "KinenGitBridge.h"
#include <git2.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    const kg_remote *connection;
    kg_result *result;
    int status;
    int attempted_credentials;
    const git_oid *expected;
} context;

static int mapped_error(int code, context *ctx) {
    if (ctx && ctx->status) return ctx->status;
    if (code == GIT_ENONFASTFORWARD) return KG_REMOTE_CHANGED;
    if (code == GIT_EAUTH) return KG_AUTH;
    return KG_ERROR;
}

static int finish(int code, context *ctx, kg_result *result) {
    if (code >= 0) return code;
    int mapped = mapped_error(code, ctx);
    /* Omit remote-controlled diagnostic strings from the credential path. */
    if (mapped == KG_ERROR && !result->detail[0]) {
        snprintf(result->detail, sizeof(result->detail), "Git operation failed (%d).", code);
    }
    return mapped;
}

static int certificate(git_cert *cert, int valid, const char *host, void *payload) {
    (void)valid; (void)host;
    context *ctx = payload;
    if (!cert || cert->cert_type != GIT_CERT_HOSTKEY_LIBSSH2) return GIT_ECERTIFICATE;
    git_cert_hostkey *key = (git_cert_hostkey *)cert;
    if (!(key->type & GIT_CERT_SSH_SHA256)) return GIT_ECERTIFICATE;
    memcpy(ctx->result->host_hash, key->hash_sha256, 32);
    ctx->result->has_host_hash = 1;
    if (!ctx->connection->host_hash) {
        ctx->status = KG_HOST_UNTRUSTED;
        return GIT_ECERTIFICATE;
    }
    if (memcmp(ctx->connection->host_hash, key->hash_sha256, 32)) {
        ctx->status = KG_HOST_CHANGED;
        return GIT_ECERTIFICATE;
    }
    return 0;
}

static int credentials(git_credential **out, const char *url, const char *username,
                       unsigned int allowed, void *payload) {
    (void)url;
    context *ctx = payload;
    if (!username) username = "git";
    if (allowed & GIT_CREDENTIAL_USERNAME) return git_credential_username_new(out, username);
    if (ctx->attempted_credentials++ || !(allowed & GIT_CREDENTIAL_SSH_MEMORY) ||
        !ctx->connection->private_key) {
        ctx->status = KG_AUTH;
        return GIT_EAUTH;
    }
    return git_credential_ssh_key_memory_new(out, username, ctx->connection->public_key,
                                             ctx->connection->private_key, ctx->connection->passphrase);
}

static int rejection(const char *ref, const char *status, void *payload) {
    (void)ref;
    context *ctx = payload;
    if (!status) return 0;
    return ctx->status = KG_ERROR;
}

static int check_push(const git_push_update **updates, size_t length, void *payload) {
    context *ctx = payload;
    if (length != 1 || (ctx->expected ? !git_oid_equal(&updates[0]->src, ctx->expected) :
                         !git_oid_is_zero(&updates[0]->src))) {
        ctx->status = KG_REMOTE_CHANGED;
        return GIT_ENONFASTFORWARD;
    }
    return 0;
}

static git_remote_callbacks callbacks(context *ctx) {
    git_remote_callbacks result = GIT_REMOTE_CALLBACKS_INIT;
    result.credentials = credentials;
    result.certificate_check = certificate;
    result.payload = ctx;
    return result;
}

static int open_repository(git_repository **repo, const char *directory) {
    int rc = git_repository_open_ext(repo, directory, GIT_REPOSITORY_OPEN_NO_SEARCH, NULL);
    if (rc == GIT_ENOTFOUND) rc = git_repository_init(repo, directory, 1);
    return rc;
}

static int setup_remote(git_remote **remote, git_repository *repo, const kg_remote *connection,
                        char *ref, size_t capacity) {
    int valid = 0;
    int size = snprintf(ref, capacity, "refs/heads/%s", connection->branch);
    if (size < 0 || (size_t)size >= capacity || git_reference_name_is_valid(&valid, ref) < 0 || !valid) {
        return GIT_EINVALIDSPEC;
    }
    return git_remote_create_anonymous(remote, repo, connection->url);
}

int kg_fetch(const char *repository, const kg_remote *connection, kg_result *result) {
    memset(result, 0, sizeof(*result));
    git_libgit2_init();
    git_repository *repo = NULL;
    git_remote *remote = NULL;
    char ref[1024], spec[1200];
    context ctx = { connection, result, 0, 0, NULL };
    int rc = open_repository(&repo, repository);
    if (rc < 0 || (rc = setup_remote(&remote, repo, connection, ref, sizeof(ref))) < 0) goto done;
    git_remote_callbacks cb = callbacks(&ctx);
    rc = git_remote_connect(remote, GIT_DIRECTION_FETCH, &cb, NULL, NULL);
    if (rc < 0) goto done;
    const git_remote_head **heads = NULL;
    size_t count = 0;
    rc = git_remote_ls(&heads, &count, remote);
    if (rc < 0) goto done;
    size_t n = 0;
    for (; n < count && strcmp(heads[n]->name, ref); n++) {}
    if (n == count) { rc = KG_MISSING; goto done; }

    snprintf(spec, sizeof(spec), "+%s:refs/kinen/fetched", ref);
    char *strings[] = { spec };
    git_strarray array = { strings, 1 };
    git_fetch_options options = GIT_FETCH_OPTIONS_INIT;
    options.callbacks = cb;
    options.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_NONE;
    rc = git_remote_fetch(remote, &array, &options, NULL);
    git_oid oid;
    if (rc == 0) rc = git_reference_name_to_id(&oid, repo, "refs/kinen/fetched");
    if (rc == 0) git_oid_tostr(result->oid, sizeof(result->oid), &oid);
done:
    rc = finish(rc, &ctx, result);
    git_remote_free(remote);
    git_repository_free(repo);
    git_libgit2_shutdown();
    return rc;
}

int kg_is_ancestor(const char *repository, const char *ancestor, const char *revision, kg_result *result) {
    memset(result, 0, sizeof(*result));
    git_libgit2_init();
    git_repository *repo = NULL;
    git_oid a, b;
    int rc = open_repository(&repo, repository);
    if (rc == 0) rc = git_oid_fromstr(&a, ancestor);
    if (rc == 0) rc = git_oid_fromstr(&b, revision);
    if (rc == 0 && git_oid_equal(&a, &b)) {
        rc = KG_OK;
    } else if (rc == 0) {
        int descendant = git_graph_descendant_of(repo, &b, &a);
        rc = descendant < 0 ? descendant : (descendant ? KG_OK : KG_NOT_ANCESTOR);
    }
    rc = finish(rc, NULL, result);
    git_repository_free(repo);
    git_libgit2_shutdown();
    return rc;
}

int kg_checkout(const char *repository, const char *revision, const char *folder, kg_result *result) {
    memset(result, 0, sizeof(*result));
    git_libgit2_init();
    git_repository *repo = NULL;
    git_commit *commit = NULL;
    git_tree *tree = NULL;
    git_oid oid;
    int rc = open_repository(&repo, repository);
    if (rc == 0) rc = git_oid_fromstr(&oid, revision);
    if (rc == 0) rc = git_commit_lookup(&commit, repo, &oid);
    if (rc == 0) rc = git_commit_tree(&tree, commit);
    if (rc == 0) {
        git_checkout_options options = GIT_CHECKOUT_OPTIONS_INIT;
        options.checkout_strategy = GIT_CHECKOUT_FORCE | GIT_CHECKOUT_DONT_UPDATE_INDEX;
        options.target_directory = folder;
        options.disable_filters = 1;
        rc = git_checkout_tree(repo, (git_object *)tree, &options);
    }
    rc = finish(rc, NULL, result);
    git_tree_free(tree);
    git_commit_free(commit);
    git_repository_free(repo);
    git_libgit2_shutdown();
    return rc;
}

int kg_publish(const char *repository, const kg_remote *connection, const char *folder,
               const char *expected, kg_before_push before_push, void *payload, kg_result *result) {
    memset(result, 0, sizeof(*result));
    git_libgit2_init();
    git_repository *repo = NULL;
    git_remote *remote = NULL;
    git_index *index = NULL;
    git_commit *parent = NULL;
    git_tree *tree = NULL;
    git_signature *signature = NULL;
    git_reference *sent = NULL;
    git_oid parent_id, tree_id, commit_id;
    char ref[1024], spec[1100];
    context ctx = { connection, result, 0, 0, NULL };
    int rc = open_repository(&repo, repository);
    if (rc < 0 || (rc = setup_remote(&remote, repo, connection, ref, sizeof(ref))) < 0 ||
        (rc = git_repository_set_workdir(repo, folder, 0)) < 0 ||
        (rc = git_repository_index(&index, repo)) < 0 ||
        (rc = git_index_clear(index)) < 0) goto done;

    char *paths[] = { "library.json", "members", "groups", "entries", "media", "assets" };
    git_strarray allowed = { paths, sizeof(paths) / sizeof(paths[0]) };
    rc = git_index_add_all(index, &allowed, GIT_INDEX_ADD_FORCE, NULL, NULL);
    if (rc < 0 || (rc = git_index_write_tree_to(&tree_id, index, repo)) < 0 ||
        (rc = git_tree_lookup(&tree, repo, &tree_id)) < 0) goto done;
    if (expected) {
        rc = git_oid_fromstr(&parent_id, expected);
        if (rc < 0 || (rc = git_commit_lookup(&parent, repo, &parent_id)) < 0) goto done;
        ctx.expected = &parent_id;
        if (git_oid_equal(&tree_id, git_commit_tree_id(parent))) {
            git_oid_tostr(result->oid, sizeof(result->oid), &parent_id);
            if (before_push) rc = before_push(result->oid, payload);
            goto done;
        }
    }

    rc = git_signature_now(&signature, "Kinen Satsuei", "kinensatsuei@localhost");
    if (rc < 0) goto done;
    const git_commit *parents[] = { parent };
    rc = git_commit_create(&commit_id, repo, NULL, signature, signature, NULL,
                           "Sync Kinen Satsuei library", tree, parent ? 1 : 0, parents);
    if (rc < 0) goto done;
    rc = git_reference_create(&sent, repo, "refs/kinen/outgoing", &commit_id, 1, NULL);
    if (rc < 0) goto done;
    git_oid_tostr(result->oid, sizeof(result->oid), &commit_id);
    if (before_push && (rc = before_push(result->oid, payload)) < 0) goto done;

    snprintf(spec, sizeof(spec), "refs/kinen/outgoing:%s", ref);
    char *strings[] = { spec };
    git_strarray array = { strings, 1 };
    git_push_options options = GIT_PUSH_OPTIONS_INIT;
    options.callbacks = callbacks(&ctx);
    options.callbacks.push_negotiation = check_push;
    options.callbacks.push_update_reference = rejection;
    rc = git_remote_push(remote, &array, &options);
    if (rc == 0) git_oid_tostr(result->oid, sizeof(result->oid), &commit_id);
done:
    rc = finish(rc, &ctx, result);
    git_reference_free(sent);
    git_signature_free(signature);
    git_tree_free(tree);
    git_commit_free(parent);
    git_index_free(index);
    git_remote_free(remote);
    git_repository_free(repo);
    git_libgit2_shutdown();
    return rc;
}
