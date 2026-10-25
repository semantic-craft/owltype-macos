#ifndef OWL_MSIME_FFI_H
#define OWL_MSIME_FFI_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OwlMsimeSession OwlMsimeSession;
typedef struct OwlMsimeConfig OwlMsimeConfig;

/*
 * Loads a base YAML document and an optional Rime-style custom document whose
 * root `patch:` map is overlaid on it. Both nested maps and flat slash paths
 * (for example `style/inline_preedit` or
 * `"app_options/com.example.App/ascii_mode"`) are supported. A missing patch
 * file is accepted; a missing or malformed base file is an error.
 *
 * On failure this returns NULL and, when error_out is non-NULL, stores a newly
 * allocated UTF-8 message released by owl_msime_string_free.
 */
OwlMsimeConfig *owl_msime_config_open(
    const char *base_path,
    const char *patch_path,
    char **error_out
);

void owl_msime_config_destroy(OwlMsimeConfig *config);

bool owl_msime_config_get_bool(
    const OwlMsimeConfig *config,
    const char *path,
    bool *value_out
);

bool owl_msime_config_get_double(
    const OwlMsimeConfig *config,
    const char *path,
    double *value_out
);

/* Returns NULL for a missing or non-scalar value. Free with owl_msime_string_free. */
char *owl_msime_config_get_string(
    const OwlMsimeConfig *config,
    const char *path
);

bool owl_msime_config_has_map(
    const OwlMsimeConfig *config,
    const char *path
);

/*
 * Returns a deterministic JSON object containing the boolean direct children
 * of app_options/<bundle_id>. An absent section is `{}`. Free the result with
 * owl_msime_string_free.
 */
char *owl_msime_config_app_options_json(
    const OwlMsimeConfig *config,
    const char *bundle_id
);

OwlMsimeSession *owl_msime_session_create(
    const char *pinyin_db_path,
    const char *english_db_path,
    const char *user_data_dir,
    uint32_t page_size
);

/*
 * Creates a session over four exact, non-overlapping EngineOptions roots.
 * Every root is created if absent and used as given: no msime-* child is
 * appended. Their existing ancestors are resolved before any directory is
 * created, so the supplied strings need not already be canonical. Paths
 * containing ".." are rejected before writes.
 *
 * On success, returns an opaque session and leaves *error_out NULL when
 * error_out is non-NULL. On failure, returns NULL; when error_out is
 * non-NULL it receives a newly allocated UTF-8 message that the caller frees
 * with owl_msime_string_free. Pass NULL for error_out when no message is
 * needed.
 *
 * The returned session does not own or delete any of these roots. A caller
 * may remove a disposable runtime root only after owl_msime_session_destroy;
 * the persistent user_data_dir must outlive runtime updates and lease
 * releases. page_size 0 means 5 and other values clamp to 1...10.
 */
OwlMsimeSession *owl_msime_session_create_with_roots(
    const char *pinyin_db_path,
    const char *english_db_path,
    const char *resources_dir,
    const char *user_data_dir,
    const char *cache_dir,
    const char *dictionaries_dir,
    uint32_t page_size,
    char **error_out
);

/*
 * Prepares an upstream dictionary generation and creates one session over it.
 * resources_dir must contain msime-pinyin.db and msime-english.db directly.
 * The generation is created at
 * <user_data_dir>/dictionaries/<content_id>, while the persistent journal is
 * <user_data_dir>/msime_user.db. content_id is 1...128 bytes of
 * [0-9A-Za-z_-]. user_data_dir and cache_dir must be exact, non-overlapping
 * absolute roots.
 *
 * The legacy and explicit-roots constructors above are unchanged. On failure,
 * this entry returns NULL and, when error_out is non-NULL, stores a newly
 * allocated UTF-8 message released by owl_msime_string_free.
 */
OwlMsimeSession *owl_msime_session_create_with_generation(
    const char *resources_dir,
    const char *user_data_dir,
    const char *cache_dir,
    const char *content_id,
    uint32_t page_size,
    char **error_out
);

void owl_msime_session_destroy(OwlMsimeSession *session);

/*
 * Imports one fully prepared Owltype Rime migration into four exact runtime
 * roots. request_id must name an existing
 * <user_data_dir>/.owl-user-migration/<request_id> directory containing the
 * manifest, record stream and prepared marker written by the Swift stager.
 *
 * The caller must stop sessions that use these roots before this call. The
 * four roots and the staged directory are never deleted or rewritten by a
 * failed import. Dictionary and learning-habit changes are rolled back from a
 * database snapshot if either merge fails.
 *
 * Returns a newly allocated UTF-8 JSON report. Success is
 * {"ok":true,...}; failure is {"ok":false,"error":"..."}. Release the result
 * with owl_msime_string_free. A malformed argument or caller invariant returns
 * a failure report rather than NULL whenever the report can be serialized.
 */
char *owl_msime_user_migration_import(
    const char *resources_dir,
    const char *user_data_dir,
    const char *cache_dir,
    const char *dictionaries_dir,
    const char *request_id
);

char *owl_msime_session_handle_action_json(
    OwlMsimeSession *session,
    const char *action_json
);

char *owl_msime_session_snapshot_json(
    const OwlMsimeSession *session
);

/*
 * Optional local candidate reranking. Models load on worker threads; configuration
 * and keystrokes never read the model synchronously. All functions return a newly
 * allocated UTF-8 JSON string released with owl_msime_string_free.
 *
 * configure_rerank_json accepts:
 * {
 *   "keyboard": {"enabled": bool, "path": "/absolute/file",
 *                "source": "...", "version": "...", "expected_sha256": "..."},
 *   "settled":  {...}
 * }
 * Both models default to disabled. The path must be absolute, a regular
 * non-symlink file, and at most 64 MiB.
 *
 * start_settled_rerank_json may return {"status":"pending","token":N}.
 * poll_settled_rerank_json must run on the session thread. Pass accept=false
 * when the composition that started the job is no longer current.
 */
char *owl_msime_session_configure_rerank_json(
    OwlMsimeSession *session,
    const char *config_json
);

char *owl_msime_session_rerank_status_json(
    OwlMsimeSession *session
);

char *owl_msime_session_start_settled_rerank_json(
    OwlMsimeSession *session
);

char *owl_msime_session_poll_settled_rerank_json(
    OwlMsimeSession *session,
    uint64_t token,
    bool accept
);

void owl_msime_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* OWL_MSIME_FFI_H */
