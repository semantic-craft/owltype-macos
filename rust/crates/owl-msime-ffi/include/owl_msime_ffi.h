#ifndef OWL_MSIME_FFI_H
#define OWL_MSIME_FFI_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OwlMsimeSession OwlMsimeSession;

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

char *owl_msime_session_handle_action_json(
    OwlMsimeSession *session,
    const char *action_json
);

char *owl_msime_session_snapshot_json(
    const OwlMsimeSession *session
);

void owl_msime_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* OWL_MSIME_FFI_H */
