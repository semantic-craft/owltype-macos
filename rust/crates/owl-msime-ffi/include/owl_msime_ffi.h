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
