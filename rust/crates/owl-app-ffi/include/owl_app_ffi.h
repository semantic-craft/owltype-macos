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
void owl_app_string_free(char *response); // NULL is allowed; other pointers must be ours.
#ifdef __cplusplus
}
#endif
#endif
