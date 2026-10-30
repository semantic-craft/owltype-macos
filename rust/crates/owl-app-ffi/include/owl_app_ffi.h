#ifndef OWL_APP_FFI_H
#define OWL_APP_FFI_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// ABI 1: borrowed input bytes live for the synchronous call only; never retained.
// Returned UTF-8 JSON is Rust-owned, NUL-terminated, and must be freed exactly once.
// NULL input is rejected, even with length 0. Non-NULL input must point to length
// readable bytes. Payloads are limited to 4 MiB. Errors contain no request text.
// owl_app_call has no callbacks, I/O or global mutable state. Calls may run concurrently.
uint32_t owl_app_abi_version(void);
char *owl_app_call(uint32_t abi_version, const uint8_t *request, size_t length);
// Allocation-free keyboard hot-path decision: 0 none, 1 defer, 2 apply. Inputs are 0/1.
uint8_t owl_app_keyboard_can_apply(uint8_t requires_idle, uint8_t composing);
// Schema action: 0 already active, 1 attempt, 2 skip known failure. Inputs are identity facts.
uint32_t owl_app_keyboard_schema_idle_action(uint8_t current_matches, uint8_t failed_matches);
uint32_t owl_app_keyboard_refresh(uint8_t pending, uint8_t composing);
// Storage requests synchronously call raw native services on the calling thread. The
// callback response is borrowed until its next invocation or the end of this call.
typedef const char *(*owl_app_host_callback)(void *context, const char *request);
char *owl_app_storage_call(uint32_t abi_version, const uint8_t *request, size_t length,
                           void *context, owl_app_host_callback callback);
// Owned ephemeral sessions: creator thread serializes all calls and destruction. No callbacks.
// Creation validates ABI 1 and returns an owned status buffer through response (free it too).
// Creation/runtime publication accept storage-sized snapshots; other events are <= 4 MiB.
// The optional index is borrowed for one event and must be a distinct live session.
// Keep the same index while recognizing; native publication drains pending recognition first.
// Free NULL is permitted. No handle or response may be freed twice or used after free.
typedef struct OwlAppSession OwlAppSession;
OwlAppSession *owl_app_session_new(uint32_t version, const uint8_t *request, size_t length, char **response);
char *owl_app_session_call(OwlAppSession *session, const uint8_t *request, size_t length, const OwlAppSession *index);
void owl_app_session_free(OwlAppSession *session);
void owl_app_string_free(char *response); // NULL is allowed; other pointers must be ours.
#ifdef __cplusplus
}
#endif
#endif
