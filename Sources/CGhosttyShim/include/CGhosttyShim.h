#ifndef CGHOSTTYSHIM_H
#define CGHOSTTYSHIM_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct balagan_ghostty_library balagan_ghostty_library_t;
typedef struct balagan_ghostty_app balagan_ghostty_app_t;
typedef struct balagan_ghostty_surface balagan_ghostty_surface_t;

typedef enum {
    BALAGAN_GHOSTTY_KEY_ENTER,
    BALAGAN_GHOSTTY_KEY_BACKSPACE,
    BALAGAN_GHOSTTY_KEY_TAB,
    BALAGAN_GHOSTTY_KEY_ESCAPE,
    BALAGAN_GHOSTTY_KEY_ARROW_UP,
    BALAGAN_GHOSTTY_KEY_ARROW_DOWN,
    BALAGAN_GHOSTTY_KEY_ARROW_LEFT,
    BALAGAN_GHOSTTY_KEY_ARROW_RIGHT,
    BALAGAN_GHOSTTY_KEY_DELETE,
    BALAGAN_GHOSTTY_KEY_HOME,
    BALAGAN_GHOSTTY_KEY_END,
} balagan_ghostty_key_t;

typedef enum {
    BALAGAN_GHOSTTY_MOUSE_RELEASE,
    BALAGAN_GHOSTTY_MOUSE_PRESS,
} balagan_ghostty_mouse_state_t;

typedef enum {
    BALAGAN_GHOSTTY_MOUSE_BUTTON_UNKNOWN,
    BALAGAN_GHOSTTY_MOUSE_BUTTON_LEFT,
    BALAGAN_GHOSTTY_MOUSE_BUTTON_RIGHT,
    BALAGAN_GHOSTTY_MOUSE_BUTTON_MIDDLE,
} balagan_ghostty_mouse_button_t;

typedef struct {
    const char *key;
    const char *value;
} balagan_ghostty_env_var_t;

typedef enum {
    BALAGAN_GHOSTTY_EVENT_TITLE,
    BALAGAN_GHOSTTY_EVENT_PWD,
    BALAGAN_GHOSTTY_EVENT_NOTIFICATION,
    BALAGAN_GHOSTTY_EVENT_BELL,
} balagan_ghostty_event_kind_t;

typedef void (*balagan_ghostty_event_cb)(
    void *context,
    balagan_ghostty_event_kind_t kind,
    const char *text,
    const char *detail
);

void balagan_ghostty_set_event_callback(balagan_ghostty_event_cb callback);

int balagan_ghostty_library_open(
    const char *path,
    balagan_ghostty_library_t **out_library,
    char *error_buffer,
    size_t error_buffer_len
);

void balagan_ghostty_library_close(balagan_ghostty_library_t *library);

int balagan_ghostty_initialize(
    balagan_ghostty_library_t *library,
    uintptr_t argc,
    char **argv
);

int balagan_ghostty_create_app(
    balagan_ghostty_library_t *library,
    balagan_ghostty_app_t **out_app,
    char *error_buffer,
    size_t error_buffer_len
);

// Reads the resolved `font-size` from the user's Ghostty config (default files), creating a
// throwaway config internally. Returns 0 if unavailable or unset. Used to adopt the user's
// preferred terminal font size as the base size, matching their Ghostty.
double balagan_ghostty_library_config_font_size(balagan_ghostty_library_t *library);

void balagan_ghostty_app_free(balagan_ghostty_app_t *app);
void balagan_ghostty_app_tick(balagan_ghostty_app_t *app);

int balagan_ghostty_app_create_surface(
    balagan_ghostty_app_t *app,
    void *platform_view,
    double scale_factor,
    float font_size,
    const char *working_directory,
    const char *command,
    const balagan_ghostty_env_var_t *env_vars,
    size_t env_var_count,
    void *event_context,
    balagan_ghostty_surface_t **out_surface,
    char *error_buffer,
    size_t error_buffer_len
);

void balagan_ghostty_surface_free(balagan_ghostty_surface_t *surface);
void balagan_ghostty_surface_draw(balagan_ghostty_surface_t *surface);
void balagan_ghostty_surface_refresh(balagan_ghostty_surface_t *surface);
void balagan_ghostty_surface_resize(balagan_ghostty_surface_t *surface, uint32_t width, uint32_t height);
void balagan_ghostty_surface_set_focus(balagan_ghostty_surface_t *surface, bool focused);
void balagan_ghostty_surface_set_occlusion(balagan_ghostty_surface_t *surface, bool occluded);
bool balagan_ghostty_surface_binding_action(balagan_ghostty_surface_t *surface, const char *action, uintptr_t len);
bool balagan_ghostty_surface_size(
    balagan_ghostty_surface_t *surface,
    uint16_t *out_columns,
    uint16_t *out_rows,
    uint32_t *out_width_px,
    uint32_t *out_height_px,
    uint32_t *out_cell_width_px,
    uint32_t *out_cell_height_px
);
bool balagan_ghostty_surface_key(balagan_ghostty_surface_t *surface, balagan_ghostty_key_t key);
// Like balagan_ghostty_surface_key but carries modifier flags (bit0 shift, bit1 control, bit2
// option, bit3 command) so e.g. Shift+Enter is reported distinctly (kitty keyboard protocol).
bool balagan_ghostty_surface_key_with_mods(
    balagan_ghostty_surface_t *surface,
    balagan_ghostty_key_t key,
    uint32_t mods
);
bool balagan_ghostty_surface_key_text(
    balagan_ghostty_surface_t *surface,
    uint32_t keycode,
    const char *text,
    uint32_t unshifted_codepoint
);
// Full key-event entry point (cmux-style pipeline). action: 0=release, 1=press, 2=repeat.
// mods/consumed_mods bits: shift=1, ctrl=2, alt=4, super=8. text may be NULL.
bool balagan_ghostty_surface_send_key(
    balagan_ghostty_surface_t *surface,
    uint32_t keycode,
    uint32_t mods,
    uint32_t consumed_mods,
    int action,
    uint32_t unshifted_codepoint,
    bool composing,
    const char *text
);
uint32_t balagan_ghostty_surface_key_translation_mods(balagan_ghostty_surface_t *surface, uint32_t mods);
void balagan_ghostty_surface_preedit(balagan_ghostty_surface_t *surface, const char *text, uintptr_t len);
bool balagan_ghostty_surface_ime_point(
    balagan_ghostty_surface_t *surface,
    double *x, double *y, double *w, double *h
);
bool balagan_ghostty_surface_control_key_text(
    balagan_ghostty_surface_t *surface,
    uint32_t keycode,
    const char *text,
    uint32_t unshifted_codepoint
);
void balagan_ghostty_surface_text(balagan_ghostty_surface_t *surface, const char *text, uintptr_t len);
void balagan_ghostty_surface_mouse_button(
    balagan_ghostty_surface_t *surface,
    balagan_ghostty_mouse_state_t state,
    balagan_ghostty_mouse_button_t button,
    uint32_t mods
);
void balagan_ghostty_surface_mouse_pos(
    balagan_ghostty_surface_t *surface,
    double x,
    double y,
    uint32_t mods
);
void balagan_ghostty_surface_mouse_scroll(
    balagan_ghostty_surface_t *surface,
    double x,
    double y,
    int scroll_mods
);
bool balagan_ghostty_surface_has_selection(balagan_ghostty_surface_t *surface);
bool balagan_ghostty_surface_process_exited(balagan_ghostty_surface_t *surface);
// True when Ghostty would ask "a process is running, close anyway?" — something other than the shell
// prompt is running (shell integration's prompt marks decide). True when the symbol is unavailable.
bool balagan_ghostty_surface_needs_confirm_quit(balagan_ghostty_surface_t *surface);
int balagan_ghostty_surface_read_selection(
    balagan_ghostty_surface_t *surface,
    char **out_text,
    size_t *out_text_len,
    char *error_buffer,
    size_t error_buffer_len
);
int balagan_ghostty_surface_read_text(
    balagan_ghostty_surface_t *surface,
    char **out_text,
    size_t *out_text_len,
    char *error_buffer,
    size_t error_buffer_len
);
void balagan_ghostty_string_free(char *text);

#ifdef __cplusplus
}
#endif

#endif
