#include "CGhosttyShim.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define GHOSTTY_SUCCESS 0
#define GHOSTTY_PLATFORM_MACOS 1
#define GHOSTTY_SURFACE_CONTEXT_TAB 1

typedef void *ghostty_app_t;
typedef void *ghostty_config_t;
typedef void *ghostty_surface_t;

typedef enum {
    GHOSTTY_MODS_NONE = 0,
    GHOSTTY_MODS_SHIFT = 1 << 0,
    GHOSTTY_MODS_CTRL = 1 << 1,
    GHOSTTY_MODS_ALT = 1 << 2,
    GHOSTTY_MODS_SUPER = 1 << 3,
} ghostty_input_mods_e;

typedef enum {
    GHOSTTY_ACTION_RELEASE,
    GHOSTTY_ACTION_PRESS,
    GHOSTTY_ACTION_REPEAT,
} ghostty_input_action_e;

typedef struct {
    ghostty_input_action_e action;
    ghostty_input_mods_e mods;
    ghostty_input_mods_e consumed_mods;
    uint32_t keycode;
    const char *text;
    uint32_t unshifted_codepoint;
    bool composing;
} ghostty_input_key_s;

typedef enum {
    GHOSTTY_MOUSE_RELEASE,
    GHOSTTY_MOUSE_PRESS,
} ghostty_input_mouse_state_e;

typedef enum {
    GHOSTTY_MOUSE_UNKNOWN,
    GHOSTTY_MOUSE_LEFT,
    GHOSTTY_MOUSE_RIGHT,
    GHOSTTY_MOUSE_MIDDLE,
} ghostty_input_mouse_button_e;

typedef int ghostty_input_scroll_mods_t;

typedef enum {
    GHOSTTY_POINT_ACTIVE,
    GHOSTTY_POINT_VIEWPORT,
    GHOSTTY_POINT_SCREEN,
    GHOSTTY_POINT_SURFACE,
} ghostty_point_tag_e;

typedef enum {
    GHOSTTY_POINT_COORD_EXACT,
    GHOSTTY_POINT_COORD_TOP_LEFT,
    GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
} ghostty_point_coord_e;

typedef struct {
    ghostty_point_tag_e tag;
    ghostty_point_coord_e coord;
    uint32_t x;
    uint32_t y;
} ghostty_point_s;

typedef struct {
    double tl_px_x;
    double tl_px_y;
    uint32_t offset_start;
    uint32_t offset_len;
    const char *text;
    uintptr_t text_len;
} ghostty_text_s;

typedef struct {
    ghostty_point_s top_left;
    ghostty_point_s bottom_right;
    bool rectangle;
} ghostty_selection_s;

typedef enum {
    GHOSTTY_CLIPBOARD_STANDARD,
    GHOSTTY_CLIPBOARD_SELECTION,
} ghostty_clipboard_e;

typedef enum {
    GHOSTTY_CLIPBOARD_REQUEST_PASTE,
    GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
    GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
} ghostty_clipboard_request_e;

typedef struct {
    const char *mime;
    const char *data;
} ghostty_clipboard_content_s;

typedef struct {
    const char *key;
    const char *value;
} ghostty_env_var_s;

typedef struct {
    void *nsview;
} ghostty_platform_macos_s;

typedef struct {
    void *uiview;
} ghostty_platform_ios_s;

typedef union {
    ghostty_platform_macos_s macos;
    ghostty_platform_ios_s ios;
} ghostty_platform_u;

typedef struct {
    int platform_tag;
    ghostty_platform_u platform;
    void *userdata;
    double scale_factor;
    float font_size;
    const char *working_directory;
    const char *command;
    ghostty_env_var_s *env_vars;
    size_t env_var_count;
    const char *initial_input;
    bool wait_after_command;
    int context;
} ghostty_surface_config_s;

typedef struct {
    uint16_t columns;
    uint16_t rows;
    uint32_t width_px;
    uint32_t height_px;
    uint32_t cell_width_px;
    uint32_t cell_height_px;
} ghostty_surface_size_s;

typedef enum {
    GHOSTTY_TARGET_APP,
    GHOSTTY_TARGET_SURFACE,
} ghostty_target_tag_e;

typedef union {
    ghostty_surface_t surface;
} ghostty_target_u;

typedef struct {
    ghostty_target_tag_e tag;
    ghostty_target_u target;
} ghostty_target_s;

typedef struct {
    uint64_t align;
    unsigned char storage[64];
} ghostty_action_storage_s;

typedef struct {
    int tag;
    ghostty_action_storage_s action;
} ghostty_action_s;

typedef struct {
    const char *title;
} ghostty_action_set_title_s;

typedef struct {
    const char *pwd;
} ghostty_action_pwd_s;

typedef struct {
    const char *title;
    const char *body;
} ghostty_action_desktop_notification_s;

// Action tag values from ghostty 1.3.1 include/ghostty.h (ghostty_action_tag_e).
#define GHOSTTY_ACTION_DESKTOP_NOTIFICATION 31
#define GHOSTTY_ACTION_SET_TITLE 32
#define GHOSTTY_ACTION_PWD 35
#define GHOSTTY_ACTION_RING_BELL 50
#define GHOSTTY_ACTION_START_SEARCH 59
#define GHOSTTY_ACTION_END_SEARCH 60
#define GHOSTTY_ACTION_SEARCH_TOTAL 61
#define GHOSTTY_ACTION_SEARCH_SELECTED 62

typedef struct {
    const char *needle;
} ghostty_action_start_search_s;

typedef struct {
    ssize_t value;
} ghostty_action_search_count_s;

typedef void (*ghostty_runtime_wakeup_cb)(void *);
typedef bool (*ghostty_runtime_read_clipboard_cb)(void *, ghostty_clipboard_e, void *);
typedef void (*ghostty_runtime_confirm_read_clipboard_cb)(
    void *,
    const char *,
    void *,
    ghostty_clipboard_request_e
);
typedef void (*ghostty_runtime_write_clipboard_cb)(
    void *,
    ghostty_clipboard_e,
    const ghostty_clipboard_content_s *,
    size_t,
    bool
);
typedef void (*ghostty_runtime_close_surface_cb)(void *, bool);
typedef bool (*ghostty_runtime_action_cb)(ghostty_app_t, ghostty_target_s, ghostty_action_s);

typedef struct {
    void *userdata;
    bool supports_selection_clipboard;
    ghostty_runtime_wakeup_cb wakeup_cb;
    ghostty_runtime_action_cb action_cb;
    ghostty_runtime_read_clipboard_cb read_clipboard_cb;
    ghostty_runtime_confirm_read_clipboard_cb confirm_read_clipboard_cb;
    ghostty_runtime_write_clipboard_cb write_clipboard_cb;
    ghostty_runtime_close_surface_cb close_surface_cb;
} ghostty_runtime_config_s;

typedef int (*ghostty_init_fn)(uintptr_t, char **);
typedef ghostty_config_t (*ghostty_config_new_fn)(void);
typedef void (*ghostty_config_load_default_files_fn)(ghostty_config_t);
typedef void (*ghostty_config_load_file_fn)(ghostty_config_t, const char *);
typedef void (*ghostty_config_finalize_fn)(ghostty_config_t);
typedef void (*ghostty_config_free_fn)(ghostty_config_t);
typedef bool (*ghostty_config_get_fn)(ghostty_config_t, void *, const char *, uintptr_t);
typedef ghostty_app_t (*ghostty_app_new_fn)(const ghostty_runtime_config_s *, ghostty_config_t);
typedef void (*ghostty_app_tick_fn)(ghostty_app_t);
typedef void (*ghostty_app_free_fn)(ghostty_app_t);
typedef ghostty_surface_config_s (*ghostty_surface_config_new_fn)(void);
typedef ghostty_surface_t (*ghostty_surface_new_fn)(ghostty_app_t, const ghostty_surface_config_s *);
typedef void (*ghostty_surface_draw_fn)(ghostty_surface_t);
typedef void (*ghostty_surface_refresh_fn)(ghostty_surface_t);
typedef void (*ghostty_surface_free_fn)(ghostty_surface_t);
typedef void (*ghostty_surface_set_size_fn)(ghostty_surface_t, uint32_t, uint32_t);
typedef ghostty_surface_size_s (*ghostty_surface_size_fn)(ghostty_surface_t);
typedef void (*ghostty_surface_set_focus_fn)(ghostty_surface_t, bool);
typedef void (*ghostty_surface_set_occlusion_fn)(ghostty_surface_t, bool);
typedef bool (*ghostty_surface_key_fn)(ghostty_surface_t, ghostty_input_key_s);
typedef void (*ghostty_surface_text_fn)(ghostty_surface_t, const char *, uintptr_t);
typedef bool (*ghostty_surface_binding_action_fn)(ghostty_surface_t, const char *, uintptr_t);
typedef bool (*ghostty_surface_read_text_fn)(ghostty_surface_t, ghostty_selection_s, ghostty_text_s *);
typedef void (*ghostty_surface_free_text_fn)(ghostty_surface_t, ghostty_text_s *);
typedef void (*ghostty_surface_mouse_button_fn)(ghostty_surface_t, ghostty_input_mouse_state_e, ghostty_input_mouse_button_e, ghostty_input_mods_e);
typedef void (*ghostty_surface_mouse_pos_fn)(ghostty_surface_t, double, double, ghostty_input_mods_e);
typedef void (*ghostty_surface_mouse_scroll_fn)(ghostty_surface_t, double, double, ghostty_input_scroll_mods_t);
typedef bool (*ghostty_surface_has_selection_fn)(ghostty_surface_t);
typedef bool (*ghostty_surface_read_selection_fn)(ghostty_surface_t, ghostty_text_s *);
typedef bool (*ghostty_surface_process_exited_fn)(ghostty_surface_t);
typedef bool (*ghostty_surface_needs_confirm_quit_fn)(ghostty_surface_t);
typedef void *(*ghostty_surface_userdata_fn)(ghostty_surface_t);
// Optional (newer libghostty): IME / keyboard-translation helpers used by the full key pipeline.
typedef ghostty_input_mods_e (*ghostty_surface_key_translation_mods_fn)(ghostty_surface_t, ghostty_input_mods_e);
typedef void (*ghostty_surface_preedit_fn)(ghostty_surface_t, const char *, uintptr_t);
typedef void (*ghostty_surface_ime_point_fn)(ghostty_surface_t, double *, double *, double *, double *);

struct balagan_ghostty_library {
    void *dl_handle;
    void *sparkle_handle;
    bool close_dl_handle;
    ghostty_init_fn ghostty_init;
    ghostty_config_new_fn ghostty_config_new;
    ghostty_config_load_default_files_fn ghostty_config_load_default_files;
    ghostty_config_load_file_fn ghostty_config_load_file;
    ghostty_config_finalize_fn ghostty_config_finalize;
    ghostty_config_free_fn ghostty_config_free;
    ghostty_config_get_fn ghostty_config_get;
    ghostty_app_new_fn ghostty_app_new;
    ghostty_app_tick_fn ghostty_app_tick;
    ghostty_app_free_fn ghostty_app_free;
    ghostty_surface_config_new_fn ghostty_surface_config_new;
    ghostty_surface_new_fn ghostty_surface_new;
    ghostty_surface_draw_fn ghostty_surface_draw;
    ghostty_surface_refresh_fn ghostty_surface_refresh;
    ghostty_surface_free_fn ghostty_surface_free;
    ghostty_surface_set_size_fn ghostty_surface_set_size;
    ghostty_surface_size_fn ghostty_surface_size;
    ghostty_surface_set_focus_fn ghostty_surface_set_focus;
    ghostty_surface_set_occlusion_fn ghostty_surface_set_occlusion;
    ghostty_surface_key_fn ghostty_surface_key;
    ghostty_surface_text_fn ghostty_surface_text;
    ghostty_surface_binding_action_fn ghostty_surface_binding_action;
    ghostty_surface_read_text_fn ghostty_surface_read_text;
    ghostty_surface_free_text_fn ghostty_surface_free_text;
    ghostty_surface_mouse_button_fn ghostty_surface_mouse_button;
    ghostty_surface_mouse_pos_fn ghostty_surface_mouse_pos;
    ghostty_surface_mouse_scroll_fn ghostty_surface_mouse_scroll;
    ghostty_surface_has_selection_fn ghostty_surface_has_selection;
    ghostty_surface_read_selection_fn ghostty_surface_read_selection;
    ghostty_surface_process_exited_fn ghostty_surface_process_exited;
    ghostty_surface_needs_confirm_quit_fn ghostty_surface_needs_confirm_quit;
    ghostty_surface_userdata_fn ghostty_surface_userdata;
    ghostty_surface_key_translation_mods_fn ghostty_surface_key_translation_mods;
    ghostty_surface_preedit_fn ghostty_surface_preedit;
    ghostty_surface_ime_point_fn ghostty_surface_ime_point;
};

// Process-wide event bridge. libghostty's action callback receives only the raw
// app/target, not our wrapper, so we route surface-targeted title/pwd actions through
// these globals: the callback resolves the per-surface context via surface userdata.
static balagan_ghostty_event_cb g_event_cb = NULL;
static ghostty_surface_userdata_fn g_surface_userdata_fn = NULL;

void balagan_ghostty_set_event_callback(balagan_ghostty_event_cb callback) {
    g_event_cb = callback;
}

struct balagan_ghostty_app {
    balagan_ghostty_library_t *library;
    ghostty_config_t config;
    ghostty_app_t app;
};

struct balagan_ghostty_surface {
    balagan_ghostty_app_t *app;
    ghostty_surface_t surface;
    char *working_directory;
    char *command;
    balagan_ghostty_env_var_t *env_vars;
    size_t env_var_count;
};

static bool balagan_ghostty_surface_key_text_with_mods(
    balagan_ghostty_surface_t *surface,
    uint32_t keycode,
    const char *text,
    uint32_t unshifted_codepoint,
    ghostty_input_mods_e mods,
    ghostty_input_mods_e consumed_mods
);

static void write_error(char *buffer, size_t len, const char *message) {
    if (buffer == NULL || len == 0) {
        return;
    }
    snprintf(buffer, len, "%s", message == NULL ? "unknown error" : message);
}

static void balagan_runtime_wakeup(void *userdata) {
    (void)userdata;
}

static bool balagan_runtime_read_clipboard(
    void *userdata,
    ghostty_clipboard_e clipboard,
    void *request
) {
    (void)userdata;
    (void)clipboard;
    (void)request;
    return false;
}

static void balagan_runtime_confirm_read_clipboard(
    void *userdata,
    const char *title,
    void *request,
    ghostty_clipboard_request_e request_type
) {
    (void)userdata;
    (void)title;
    (void)request;
    (void)request_type;
}

static void balagan_runtime_write_clipboard(
    void *userdata,
    ghostty_clipboard_e clipboard,
    const ghostty_clipboard_content_s *contents,
    size_t contents_len,
    bool confirm
) {
    (void)userdata;
    (void)clipboard;
    (void)contents;
    (void)contents_len;
    (void)confirm;
}

static void balagan_runtime_close_surface(void *userdata, bool process_alive) {
    (void)userdata;
    (void)process_alive;
}

static bool balagan_runtime_action(
    ghostty_app_t app,
    ghostty_target_s target,
    ghostty_action_s action
) {
    (void)app;

    if (g_event_cb == NULL || g_surface_userdata_fn == NULL) {
        return false;
    }
    if (target.tag != GHOSTTY_TARGET_SURFACE || target.target.surface == NULL) {
        return false;
    }

    void *context = g_surface_userdata_fn(target.target.surface);
    if (context == NULL) {
        return false;
    }

    switch ((int)action.tag) {
    case GHOSTTY_ACTION_SET_TITLE: {
        const ghostty_action_set_title_s *payload = (const ghostty_action_set_title_s *)&action.action;
        if (payload->title != NULL) {
            g_event_cb(context, BALAGAN_GHOSTTY_EVENT_TITLE, payload->title, NULL);
        }
        break;
    }
    case GHOSTTY_ACTION_PWD: {
        const ghostty_action_pwd_s *payload = (const ghostty_action_pwd_s *)&action.action;
        if (payload->pwd != NULL) {
            g_event_cb(context, BALAGAN_GHOSTTY_EVENT_PWD, payload->pwd, NULL);
        }
        break;
    }
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION: {
        const ghostty_action_desktop_notification_s *payload =
            (const ghostty_action_desktop_notification_s *)&action.action;
        g_event_cb(context, BALAGAN_GHOSTTY_EVENT_NOTIFICATION, payload->title, payload->body);
        // Report handled so libghostty does NOT also post its own native (ghost-icon) banner. The app
        // surfaces a single controlled banner + the in-app tab/task/project highlight instead.
        return true;
    }
    case GHOSTTY_ACTION_RING_BELL: {
        g_event_cb(context, BALAGAN_GHOSTTY_EVENT_BELL, NULL, NULL);
        // Handled: the app does its own NSSound.beep(), so suppress libghostty's default bell.
        return true;
    }
    // Scrollback search: the app draws the search bar; libghostty does the matching and highlights.
    case GHOSTTY_ACTION_START_SEARCH: {
        const ghostty_action_start_search_s *payload = (const ghostty_action_start_search_s *)&action.action;
        g_event_cb(context, BALAGAN_GHOSTTY_EVENT_SEARCH_START, payload->needle, NULL);
        return true;
    }
    case GHOSTTY_ACTION_END_SEARCH: {
        g_event_cb(context, BALAGAN_GHOSTTY_EVENT_SEARCH_END, NULL, NULL);
        return true;
    }
    case GHOSTTY_ACTION_SEARCH_TOTAL:
    case GHOSTTY_ACTION_SEARCH_SELECTED: {
        const ghostty_action_search_count_s *payload = (const ghostty_action_search_count_s *)&action.action;
        char count[32];
        snprintf(count, sizeof count, "%ld", (long)payload->value);
        g_event_cb(
            context,
            (int)action.tag == GHOSTTY_ACTION_SEARCH_TOTAL
                ? BALAGAN_GHOSTTY_EVENT_SEARCH_TOTAL
                : BALAGAN_GHOSTTY_EVENT_SEARCH_SELECTED,
            count,
            NULL
        );
        return true;
    }
    default:
        break;
    }

    return false;
}

static void *resolve_symbol(void *handle, const char *symbol, char *error_buffer, size_t error_buffer_len) {
    void *result = dlsym(handle, symbol);
    if (result == NULL) {
        char message[256];
        snprintf(message, sizeof(message), "missing symbol: %s", symbol);
        write_error(error_buffer, error_buffer_len, message);
    }
    return result;
}

static int resolve_library_symbols(balagan_ghostty_library_t *library, char *error_buffer, size_t error_buffer_len) {
#define RESOLVE(name) \
    do { \
        library->name = (name##_fn)resolve_symbol(library->dl_handle, #name, error_buffer, error_buffer_len); \
        if (library->name == NULL) { \
            return -2; \
        } \
    } while (0)

    RESOLVE(ghostty_init);
    RESOLVE(ghostty_config_new);
    RESOLVE(ghostty_config_finalize);
    RESOLVE(ghostty_app_new);
    RESOLVE(ghostty_app_tick);
    RESOLVE(ghostty_app_free);
    RESOLVE(ghostty_surface_config_new);
    RESOLVE(ghostty_surface_new);
    RESOLVE(ghostty_surface_free);
    RESOLVE(ghostty_surface_set_size);
    RESOLVE(ghostty_surface_size);
    RESOLVE(ghostty_surface_set_focus);
    RESOLVE(ghostty_surface_set_occlusion);
    RESOLVE(ghostty_surface_key);
    RESOLVE(ghostty_surface_text);
    RESOLVE(ghostty_surface_binding_action);

#undef RESOLVE

    library->ghostty_config_free = (ghostty_config_free_fn)dlsym(library->dl_handle, "ghostty_config_free");
    // Optional: present on Ghostty builds that expose user-config loading. When available we load the
    // user's ~/.config/ghostty/config so embedded terminals inherit their theme/font/colors (matches cmux).
    library->ghostty_config_load_default_files = (ghostty_config_load_default_files_fn)dlsym(library->dl_handle, "ghostty_config_load_default_files");
    library->ghostty_config_load_file = (ghostty_config_load_file_fn)dlsym(library->dl_handle, "ghostty_config_load_file");
    library->ghostty_config_get = (ghostty_config_get_fn)dlsym(library->dl_handle, "ghostty_config_get");
    library->ghostty_surface_draw = (ghostty_surface_draw_fn)dlsym(library->dl_handle, "ghostty_surface_draw");
    library->ghostty_surface_refresh = (ghostty_surface_refresh_fn)dlsym(library->dl_handle, "ghostty_surface_refresh");
    library->ghostty_surface_read_text = (ghostty_surface_read_text_fn)dlsym(library->dl_handle, "ghostty_surface_read_text");
    library->ghostty_surface_free_text = (ghostty_surface_free_text_fn)dlsym(library->dl_handle, "ghostty_surface_free_text");
    library->ghostty_surface_mouse_button = (ghostty_surface_mouse_button_fn)dlsym(library->dl_handle, "ghostty_surface_mouse_button");
    library->ghostty_surface_mouse_pos = (ghostty_surface_mouse_pos_fn)dlsym(library->dl_handle, "ghostty_surface_mouse_pos");
    library->ghostty_surface_mouse_scroll = (ghostty_surface_mouse_scroll_fn)dlsym(library->dl_handle, "ghostty_surface_mouse_scroll");
    library->ghostty_surface_has_selection = (ghostty_surface_has_selection_fn)dlsym(library->dl_handle, "ghostty_surface_has_selection");
    library->ghostty_surface_read_selection = (ghostty_surface_read_selection_fn)dlsym(library->dl_handle, "ghostty_surface_read_selection");
    library->ghostty_surface_process_exited = (ghostty_surface_process_exited_fn)dlsym(library->dl_handle, "ghostty_surface_process_exited");
    // Optional: Ghostty's own "is something other than the prompt running?" (its close-confirm check).
    library->ghostty_surface_needs_confirm_quit = (ghostty_surface_needs_confirm_quit_fn)dlsym(library->dl_handle, "ghostty_surface_needs_confirm_quit");
    library->ghostty_surface_userdata = (ghostty_surface_userdata_fn)dlsym(library->dl_handle, "ghostty_surface_userdata");
    if (library->ghostty_surface_userdata != NULL) {
        g_surface_userdata_fn = library->ghostty_surface_userdata;
    }
    // Optional IME / keyboard-translation helpers (full key pipeline). Absent on older libghostty,
    // in which case we degrade gracefully (no option-as-alt translation, no IME preedit overlay).
    library->ghostty_surface_key_translation_mods = (ghostty_surface_key_translation_mods_fn)dlsym(library->dl_handle, "ghostty_surface_key_translation_mods");
    library->ghostty_surface_preedit = (ghostty_surface_preedit_fn)dlsym(library->dl_handle, "ghostty_surface_preedit");
    library->ghostty_surface_ime_point = (ghostty_surface_ime_point_fn)dlsym(library->dl_handle, "ghostty_surface_ime_point");

    return 0;
}

static char *ghostty_app_sparkle_path(const char *path) {
    const char *suffix = "/Contents/MacOS/ghostty";
    if (path == NULL) {
        return NULL;
    }

    size_t path_len = strlen(path);
    size_t suffix_len = strlen(suffix);
    if (path_len <= suffix_len || strcmp(path + path_len - suffix_len, suffix) != 0) {
        return NULL;
    }

    size_t app_root_len = path_len - suffix_len;
    const char *framework_suffix = "/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle";
    size_t framework_suffix_len = strlen(framework_suffix);
    char *result = calloc(app_root_len + framework_suffix_len + 1, sizeof(char));
    if (result == NULL) {
        return NULL;
    }

    memcpy(result, path, app_root_len);
    memcpy(result + app_root_len, framework_suffix, framework_suffix_len);
    return result;
}

static void balagan_owned_surface_config_free(
    char *working_directory,
    char *command,
    balagan_ghostty_env_var_t *env_vars,
    size_t env_var_count
) {
    free(working_directory);
    free(command);
    if (env_vars != NULL) {
        for (size_t i = 0; i < env_var_count; i++) {
            free((void *)env_vars[i].key);
            free((void *)env_vars[i].value);
        }
        free(env_vars);
    }
}

static int balagan_owned_surface_config_copy(
    const char *working_directory,
    const char *command,
    const balagan_ghostty_env_var_t *env_vars,
    size_t env_var_count,
    char **out_working_directory,
    char **out_command,
    balagan_ghostty_env_var_t **out_env_vars,
    char *error_buffer,
    size_t error_buffer_len
) {
    *out_working_directory = NULL;
    *out_command = NULL;
    *out_env_vars = NULL;

    if (working_directory != NULL) {
        *out_working_directory = strdup(working_directory);
        if (*out_working_directory == NULL) {
            write_error(error_buffer, error_buffer_len, "working directory allocation failed");
            return -1;
        }
    }

    if (command != NULL) {
        *out_command = strdup(command);
        if (*out_command == NULL) {
            balagan_owned_surface_config_free(*out_working_directory, NULL, NULL, 0);
            *out_working_directory = NULL;
            write_error(error_buffer, error_buffer_len, "command allocation failed");
            return -1;
        }
    }

    if (env_var_count > 0) {
        *out_env_vars = calloc(env_var_count, sizeof(balagan_ghostty_env_var_t));
        if (*out_env_vars == NULL) {
            balagan_owned_surface_config_free(*out_working_directory, *out_command, NULL, 0);
            *out_working_directory = NULL;
            *out_command = NULL;
            write_error(error_buffer, error_buffer_len, "environment allocation failed");
            return -1;
        }

        for (size_t i = 0; i < env_var_count; i++) {
            (*out_env_vars)[i].key = env_vars[i].key == NULL ? NULL : strdup(env_vars[i].key);
            (*out_env_vars)[i].value = env_vars[i].value == NULL ? NULL : strdup(env_vars[i].value);
            if ((env_vars[i].key != NULL && (*out_env_vars)[i].key == NULL) ||
                (env_vars[i].value != NULL && (*out_env_vars)[i].value == NULL)) {
                balagan_owned_surface_config_free(*out_working_directory, *out_command, *out_env_vars, env_var_count);
                *out_working_directory = NULL;
                *out_command = NULL;
                *out_env_vars = NULL;
                write_error(error_buffer, error_buffer_len, "environment value allocation failed");
                return -1;
            }
        }
    }

    return 0;
}

int balagan_ghostty_library_open(
    const char *path,
    balagan_ghostty_library_t **out_library,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (out_library == NULL) {
        write_error(error_buffer, error_buffer_len, "out_library is null");
        return -1;
    }
    *out_library = NULL;

    void *sparkle_handle = NULL;
    char *sparkle_path = ghostty_app_sparkle_path(path);
    if (sparkle_path != NULL) {
        sparkle_handle = dlopen(sparkle_path, RTLD_NOW | RTLD_LOCAL);
        if (sparkle_handle == NULL) {
            write_error(error_buffer, error_buffer_len, dlerror());
            free(sparkle_path);
            return -1;
        }
        free(sparkle_path);
    }

    void *handle = path == NULL ? dlopen(NULL, RTLD_NOW) : dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        if (sparkle_handle != NULL) {
            dlclose(sparkle_handle);
        }
        write_error(error_buffer, error_buffer_len, dlerror());
        return -1;
    }

    balagan_ghostty_library_t *library = calloc(1, sizeof(balagan_ghostty_library_t));
    if (library == NULL) {
        if (path != NULL) {
            dlclose(handle);
        }
        if (sparkle_handle != NULL) {
            dlclose(sparkle_handle);
        }
        write_error(error_buffer, error_buffer_len, "allocation failed");
        return -1;
    }

    library->dl_handle = handle;
    library->sparkle_handle = sparkle_handle;
    library->close_dl_handle = path != NULL;

    int result = resolve_library_symbols(library, error_buffer, error_buffer_len);
    if (result != 0) {
        balagan_ghostty_library_close(library);
        return result;
    }

    *out_library = library;
    return 0;
}

void balagan_ghostty_library_close(balagan_ghostty_library_t *library) {
    if (library == NULL) {
        return;
    }
    if (library->close_dl_handle && library->dl_handle != NULL) {
        dlclose(library->dl_handle);
    }
    if (library->sparkle_handle != NULL) {
        dlclose(library->sparkle_handle);
    }
    free(library);
}

int balagan_ghostty_initialize(balagan_ghostty_library_t *library, uintptr_t argc, char **argv) {
    if (library == NULL || library->ghostty_init == NULL) {
        return -1;
    }
    return library->ghostty_init(argc, argv);
}

int balagan_ghostty_create_app(
    balagan_ghostty_library_t *library,
    balagan_ghostty_app_t **out_app,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (library == NULL || out_app == NULL) {
        write_error(error_buffer, error_buffer_len, "invalid app creation arguments");
        return -1;
    }
    *out_app = NULL;

    ghostty_config_t config = library->ghostty_config_new();
    if (config == NULL) {
        write_error(error_buffer, error_buffer_len, "ghostty_config_new returned null");
        return -1;
    }

    // Inherit the user's Ghostty configuration (~/.config/ghostty/config and friends) so embedded
    // terminals match their personal theme/font/colors, just like cmux. Optional symbol: skipped on
    // builds that don't export it, leaving Ghostty's built-in defaults.
    if (library->ghostty_config_load_default_files != NULL) {
        library->ghostty_config_load_default_files(config);
    }
    // Balagan's own overrides, layered on top of the user's config (see GhosttyConfigOverrides.swift).
    const char *overrides = getenv("BALAGAN_GHOSTTY_CONFIG_OVERRIDES");
    if (overrides != NULL && overrides[0] != '\0' && library->ghostty_config_load_file != NULL) {
        library->ghostty_config_load_file(config, overrides);
    }

    library->ghostty_config_finalize(config);

    ghostty_runtime_config_s runtime_config;
    memset(&runtime_config, 0, sizeof(runtime_config));
    runtime_config.userdata = NULL;
    runtime_config.supports_selection_clipboard = false;
    runtime_config.wakeup_cb = balagan_runtime_wakeup;
    runtime_config.action_cb = balagan_runtime_action;
    runtime_config.read_clipboard_cb = balagan_runtime_read_clipboard;
    runtime_config.confirm_read_clipboard_cb = balagan_runtime_confirm_read_clipboard;
    runtime_config.write_clipboard_cb = balagan_runtime_write_clipboard;
    runtime_config.close_surface_cb = balagan_runtime_close_surface;

    ghostty_app_t app = library->ghostty_app_new(&runtime_config, config);
    if (app == NULL) {
        // A malformed user config can make app creation fail. Fall back to a clean default config
        // (without loading user files) so terminals still launch, mirroring cmux's recovery.
        if (library->ghostty_config_free != NULL) {
            library->ghostty_config_free(config);
        }

        config = library->ghostty_config_new();
        if (config == NULL) {
            write_error(error_buffer, error_buffer_len, "ghostty_config_new returned null");
            return -1;
        }
        library->ghostty_config_finalize(config);

        app = library->ghostty_app_new(&runtime_config, config);
        if (app == NULL) {
            if (library->ghostty_config_free != NULL) {
                library->ghostty_config_free(config);
            }
            write_error(error_buffer, error_buffer_len, "ghostty_app_new returned null");
            return -1;
        }
    }

    balagan_ghostty_app_t *wrapper = calloc(1, sizeof(balagan_ghostty_app_t));
    if (wrapper == NULL) {
        library->ghostty_app_free(app);
        if (library->ghostty_config_free != NULL) {
            library->ghostty_config_free(config);
        }
        write_error(error_buffer, error_buffer_len, "allocation failed");
        return -1;
    }

    wrapper->library = library;
    wrapper->config = config;
    wrapper->app = app;
    *out_app = wrapper;
    return 0;
}

double balagan_ghostty_library_config_font_size(balagan_ghostty_library_t *library) {
    if (library == NULL || library->ghostty_config_new == NULL ||
        library->ghostty_config_finalize == NULL || library->ghostty_config_get == NULL) {
        return 0.0;
    }

    ghostty_config_t config = library->ghostty_config_new();
    if (config == NULL) {
        return 0.0;
    }
    if (library->ghostty_config_load_default_files != NULL) {
        library->ghostty_config_load_default_files(config);
    }
    library->ghostty_config_finalize(config);

    // Ghostty stores `font-size` as a 32-bit float; read into a float, not a double, or the bit
    // layout is misread (yields a denormal ~0).
    float value = 0.0f;
    const char *key = "font-size";
    bool ok = library->ghostty_config_get(config, &value, key, (uintptr_t)strlen(key));

    if (library->ghostty_config_free != NULL) {
        library->ghostty_config_free(config);
    }
    return ok ? (double)value : 0.0;
}

void balagan_ghostty_app_free(balagan_ghostty_app_t *app) {
    if (app == NULL) {
        return;
    }
    app->library->ghostty_app_free(app->app);
    if (app->library->ghostty_config_free != NULL) {
        app->library->ghostty_config_free(app->config);
    }
    free(app);
}

void balagan_ghostty_app_tick(balagan_ghostty_app_t *app) {
    if (app == NULL) {
        return;
    }
    app->library->ghostty_app_tick(app->app);
}

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
) {
    if (app == NULL || out_surface == NULL) {
        write_error(error_buffer, error_buffer_len, "invalid surface creation arguments");
        return -1;
    }
    *out_surface = NULL;

    char *owned_working_directory = NULL;
    char *owned_command = NULL;
    balagan_ghostty_env_var_t *owned_env_vars = NULL;
    if (balagan_owned_surface_config_copy(
            working_directory,
            command,
            env_vars,
            env_var_count,
            &owned_working_directory,
            &owned_command,
            &owned_env_vars,
            error_buffer,
            error_buffer_len
        ) != 0) {
        return -1;
    }

    ghostty_surface_config_s config = app->library->ghostty_surface_config_new();
    config.platform_tag = GHOSTTY_PLATFORM_MACOS;
    config.platform.macos.nsview = platform_view;
    config.userdata = event_context;
    config.scale_factor = scale_factor;
    config.font_size = font_size;
    config.working_directory = owned_working_directory;
    config.command = owned_command;
    config.initial_input = NULL;
    config.wait_after_command = false;
    config.context = GHOSTTY_SURFACE_CONTEXT_TAB;
    config.env_vars = (ghostty_env_var_s *)owned_env_vars;
    config.env_var_count = env_var_count;

    ghostty_surface_t surface = app->library->ghostty_surface_new(app->app, &config);
    if (surface == NULL) {
        balagan_owned_surface_config_free(owned_working_directory, owned_command, owned_env_vars, env_var_count);
        write_error(error_buffer, error_buffer_len, "ghostty_surface_new returned null");
        return -1;
    }

    balagan_ghostty_surface_t *wrapper = calloc(1, sizeof(balagan_ghostty_surface_t));
    if (wrapper == NULL) {
        app->library->ghostty_surface_free(surface);
        balagan_owned_surface_config_free(owned_working_directory, owned_command, owned_env_vars, env_var_count);
        write_error(error_buffer, error_buffer_len, "allocation failed");
        return -1;
    }

    wrapper->app = app;
    wrapper->surface = surface;
    wrapper->working_directory = owned_working_directory;
    wrapper->command = owned_command;
    wrapper->env_vars = owned_env_vars;
    wrapper->env_var_count = env_var_count;
    *out_surface = wrapper;
    return 0;
}

void balagan_ghostty_surface_free(balagan_ghostty_surface_t *surface) {
    if (surface == NULL) {
        return;
    }
    surface->app->library->ghostty_surface_free(surface->surface);
    balagan_owned_surface_config_free(
        surface->working_directory,
        surface->command,
        surface->env_vars,
        surface->env_var_count
    );
    free(surface);
}

void balagan_ghostty_surface_draw(balagan_ghostty_surface_t *surface) {
    if (surface == NULL) {
        return;
    }
    if (surface->app->library->ghostty_surface_draw != NULL) {
        surface->app->library->ghostty_surface_draw(surface->surface);
    }
}

void balagan_ghostty_surface_refresh(balagan_ghostty_surface_t *surface) {
    if (surface == NULL) {
        return;
    }
    if (surface->app->library->ghostty_surface_refresh != NULL) {
        surface->app->library->ghostty_surface_refresh(surface->surface);
    }
}

void balagan_ghostty_surface_resize(balagan_ghostty_surface_t *surface, uint32_t width, uint32_t height) {
    if (surface == NULL) {
        return;
    }
    surface->app->library->ghostty_surface_set_size(surface->surface, width, height);
}

void balagan_ghostty_surface_set_focus(balagan_ghostty_surface_t *surface, bool focused) {
    if (surface == NULL) {
        return;
    }
    surface->app->library->ghostty_surface_set_focus(surface->surface, focused);
}

void balagan_ghostty_surface_set_occlusion(balagan_ghostty_surface_t *surface, bool occluded) {
    if (surface == NULL) {
        return;
    }
    surface->app->library->ghostty_surface_set_occlusion(surface->surface, occluded);
}

bool balagan_ghostty_surface_binding_action(balagan_ghostty_surface_t *surface, const char *action, uintptr_t len) {
    if (surface == NULL || action == NULL) {
        return false;
    }
    return surface->app->library->ghostty_surface_binding_action(surface->surface, action, len);
}

bool balagan_ghostty_surface_size(
    balagan_ghostty_surface_t *surface,
    uint16_t *out_columns,
    uint16_t *out_rows,
    uint32_t *out_width_px,
    uint32_t *out_height_px,
    uint32_t *out_cell_width_px,
    uint32_t *out_cell_height_px
) {
    if (surface == NULL ||
        out_columns == NULL ||
        out_rows == NULL ||
        out_width_px == NULL ||
        out_height_px == NULL ||
        out_cell_width_px == NULL ||
        out_cell_height_px == NULL) {
        return false;
    }

    ghostty_surface_size_s size = surface->app->library->ghostty_surface_size(surface->surface);
    *out_columns = size.columns;
    *out_rows = size.rows;
    *out_width_px = size.width_px;
    *out_height_px = size.height_px;
    *out_cell_width_px = size.cell_width_px;
    *out_cell_height_px = size.cell_height_px;
    return true;
}

static bool balagan_ghostty_translate_keycode(balagan_ghostty_key_t key, uint32_t *out_keycode) {
    if (out_keycode == NULL) {
        return false;
    }

    switch (key) {
    case BALAGAN_GHOSTTY_KEY_ENTER:
        *out_keycode = 0x0024;
        return true;
    case BALAGAN_GHOSTTY_KEY_BACKSPACE:
        *out_keycode = 0x0033;
        return true;
    case BALAGAN_GHOSTTY_KEY_TAB:
        *out_keycode = 0x0030;
        return true;
    case BALAGAN_GHOSTTY_KEY_ESCAPE:
        *out_keycode = 0x0035;
        return true;
    case BALAGAN_GHOSTTY_KEY_ARROW_UP:
        *out_keycode = 0x007e;
        return true;
    case BALAGAN_GHOSTTY_KEY_ARROW_DOWN:
        *out_keycode = 0x007d;
        return true;
    case BALAGAN_GHOSTTY_KEY_ARROW_LEFT:
        *out_keycode = 0x007b;
        return true;
    case BALAGAN_GHOSTTY_KEY_ARROW_RIGHT:
        *out_keycode = 0x007c;
        return true;
    case BALAGAN_GHOSTTY_KEY_DELETE:
        *out_keycode = 0x0075;
        return true;
    case BALAGAN_GHOSTTY_KEY_HOME:
        *out_keycode = 0x0073;
        return true;
    case BALAGAN_GHOSTTY_KEY_END:
        *out_keycode = 0x0077;
        return true;
    }

    return false;
}

bool balagan_ghostty_surface_key(balagan_ghostty_surface_t *surface, balagan_ghostty_key_t key) {
    uint32_t keycode = 0;
    if (surface == NULL || !balagan_ghostty_translate_keycode(key, &keycode)) {
        return false;
    }

    return balagan_ghostty_surface_key_text(surface, keycode, NULL, 0);
}

bool balagan_ghostty_surface_key_with_mods(
    balagan_ghostty_surface_t *surface,
    balagan_ghostty_key_t key,
    uint32_t mods
) {
    uint32_t keycode = 0;
    if (surface == NULL || !balagan_ghostty_translate_keycode(key, &keycode)) {
        return false;
    }

    return balagan_ghostty_surface_key_text_with_mods(
        surface,
        keycode,
        NULL,
        0,
        (ghostty_input_mods_e)mods,
        GHOSTTY_MODS_NONE
    );
}

// Full key-event entry point used by the cmux-style input pipeline: carries action
// (0=release,1=press,2=repeat), mods, consumed_mods, the unshifted codepoint, composing state, and an
// optional UTF-8 text payload. libghostty's KeyEncoder turns this into the right bytes (legacy or
// kitty keyboard protocol). `text` need only stay valid for the duration of this call.
bool balagan_ghostty_surface_send_key(
    balagan_ghostty_surface_t *surface,
    uint32_t keycode,
    uint32_t mods,
    uint32_t consumed_mods,
    int action,
    uint32_t unshifted_codepoint,
    bool composing,
    const char *text
) {
    if (surface == NULL) {
        return false;
    }
    ghostty_input_key_s event = {
        .action = (ghostty_input_action_e)action,
        .mods = (ghostty_input_mods_e)mods,
        .consumed_mods = (ghostty_input_mods_e)consumed_mods,
        .keycode = keycode,
        .text = text,
        .unshifted_codepoint = unshifted_codepoint,
        .composing = composing,
    };
    return surface->app->library->ghostty_surface_key(surface->surface, event);
}

// Applies Ghostty's keyboard-config translation (e.g. macos-option-as-alt) to a modifier set.
// Returns the input unchanged when the optional symbol is unavailable.
uint32_t balagan_ghostty_surface_key_translation_mods(balagan_ghostty_surface_t *surface, uint32_t mods) {
    if (surface == NULL || surface->app->library->ghostty_surface_key_translation_mods == NULL) {
        return mods;
    }
    return (uint32_t)surface->app->library->ghostty_surface_key_translation_mods(
        surface->surface, (ghostty_input_mods_e)mods);
}

// Sets (or with text==NULL clears) the IME preedit overlay so libghostty renders composing text.
void balagan_ghostty_surface_preedit(balagan_ghostty_surface_t *surface, const char *text, uintptr_t len) {
    if (surface == NULL || surface->app->library->ghostty_surface_preedit == NULL) {
        return;
    }
    surface->app->library->ghostty_surface_preedit(surface->surface, text, len);
}

// Reports the current cursor rect (terminal coordinates) for IME candidate-window placement.
bool balagan_ghostty_surface_ime_point(
    balagan_ghostty_surface_t *surface,
    double *x, double *y, double *w, double *h
) {
    if (surface == NULL || surface->app->library->ghostty_surface_ime_point == NULL) {
        return false;
    }
    surface->app->library->ghostty_surface_ime_point(surface->surface, x, y, w, h);
    return true;
}

bool balagan_ghostty_surface_key_text(
    balagan_ghostty_surface_t *surface,
    uint32_t keycode,
    const char *text,
    uint32_t unshifted_codepoint
) {
    return balagan_ghostty_surface_key_text_with_mods(
        surface,
        keycode,
        text,
        unshifted_codepoint,
        GHOSTTY_MODS_NONE,
        GHOSTTY_MODS_NONE
    );
}

bool balagan_ghostty_surface_control_key_text(
    balagan_ghostty_surface_t *surface,
    uint32_t keycode,
    const char *text,
    uint32_t unshifted_codepoint
) {
    return balagan_ghostty_surface_key_text_with_mods(
        surface,
        keycode,
        text,
        unshifted_codepoint,
        GHOSTTY_MODS_CTRL,
        GHOSTTY_MODS_NONE
    );
}

static bool balagan_ghostty_surface_key_text_with_mods(
    balagan_ghostty_surface_t *surface,
    uint32_t keycode,
    const char *text,
    uint32_t unshifted_codepoint,
    ghostty_input_mods_e mods,
    ghostty_input_mods_e consumed_mods
) {
    if (surface == NULL) {
        return false;
    }

    ghostty_input_key_s event = {
        .action = GHOSTTY_ACTION_PRESS,
        .mods = mods,
        .consumed_mods = consumed_mods,
        .keycode = keycode,
        .text = text,
        .unshifted_codepoint = unshifted_codepoint,
        .composing = false,
    };

    return surface->app->library->ghostty_surface_key(surface->surface, event);
}

void balagan_ghostty_surface_text(balagan_ghostty_surface_t *surface, const char *text, uintptr_t len) {
    if (surface == NULL || text == NULL) {
        return;
    }
    surface->app->library->ghostty_surface_text(surface->surface, text, len);
}

void balagan_ghostty_surface_mouse_button(
    balagan_ghostty_surface_t *surface,
    balagan_ghostty_mouse_state_t state,
    balagan_ghostty_mouse_button_t button,
    uint32_t mods
) {
    if (surface == NULL || surface->app->library->ghostty_surface_mouse_button == NULL) {
        return;
    }
    surface->app->library->ghostty_surface_mouse_button(
        surface->surface,
        (ghostty_input_mouse_state_e)state,
        (ghostty_input_mouse_button_e)button,
        (ghostty_input_mods_e)mods
    );
}

void balagan_ghostty_surface_mouse_pos(
    balagan_ghostty_surface_t *surface,
    double x,
    double y,
    uint32_t mods
) {
    if (surface == NULL || surface->app->library->ghostty_surface_mouse_pos == NULL) {
        return;
    }
    surface->app->library->ghostty_surface_mouse_pos(surface->surface, x, y, (ghostty_input_mods_e)mods);
}

void balagan_ghostty_surface_mouse_scroll(
    balagan_ghostty_surface_t *surface,
    double x,
    double y,
    int scroll_mods
) {
    if (surface == NULL || surface->app->library->ghostty_surface_mouse_scroll == NULL) {
        return;
    }
    surface->app->library->ghostty_surface_mouse_scroll(surface->surface, x, y, (ghostty_input_scroll_mods_t)scroll_mods);
}

bool balagan_ghostty_surface_has_selection(balagan_ghostty_surface_t *surface) {
    if (surface == NULL || surface->app->library->ghostty_surface_has_selection == NULL) {
        return false;
    }
    return surface->app->library->ghostty_surface_has_selection(surface->surface);
}

bool balagan_ghostty_surface_process_exited(balagan_ghostty_surface_t *surface) {
    if (surface == NULL || surface->app->library->ghostty_surface_process_exited == NULL) {
        return false;
    }
    return surface->app->library->ghostty_surface_process_exited(surface->surface);
}

bool balagan_ghostty_surface_needs_confirm_quit(balagan_ghostty_surface_t *surface) {
    if (surface == NULL) {
        return false;
    }
    // Missing symbol: we can't tell, so say "busy" — callers use this to decide whether it's safe to
    // tear the terminal down.
    if (surface->app->library->ghostty_surface_needs_confirm_quit == NULL) {
        return true;
    }
    return surface->app->library->ghostty_surface_needs_confirm_quit(surface->surface);
}

int balagan_ghostty_surface_read_selection(
    balagan_ghostty_surface_t *surface,
    char **out_text,
    size_t *out_text_len,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (out_text == NULL || out_text_len == NULL) {
        write_error(error_buffer, error_buffer_len, "invalid selection read output arguments");
        return -1;
    }
    *out_text = NULL;
    *out_text_len = 0;

    if (surface == NULL) {
        write_error(error_buffer, error_buffer_len, "surface is null");
        return -1;
    }
    if (surface->app->library->ghostty_surface_read_selection == NULL ||
        surface->app->library->ghostty_surface_free_text == NULL) {
        write_error(error_buffer, error_buffer_len, "ghostty selection read symbols are unavailable");
        return -2;
    }

    ghostty_text_s text;
    memset(&text, 0, sizeof(text));

    bool ok = surface->app->library->ghostty_surface_read_selection(surface->surface, &text);
    if (!ok) {
        write_error(error_buffer, error_buffer_len, "ghostty_surface_read_selection returned false");
        return -3;
    }
    if (text.text == NULL) {
        surface->app->library->ghostty_surface_free_text(surface->surface, &text);
        write_error(error_buffer, error_buffer_len, "ghostty_surface_read_selection returned null text");
        return -3;
    }

    char *selection_copy = calloc(text.text_len + 1, sizeof(char));
    if (selection_copy == NULL) {
        surface->app->library->ghostty_surface_free_text(surface->surface, &text);
        write_error(error_buffer, error_buffer_len, "allocation failed");
        return -4;
    }

    memcpy(selection_copy, text.text, text.text_len);
    selection_copy[text.text_len] = '\0';
    *out_text = selection_copy;
    *out_text_len = text.text_len;

    surface->app->library->ghostty_surface_free_text(surface->surface, &text);
    return 0;
}

int balagan_ghostty_surface_read_text(
    balagan_ghostty_surface_t *surface,
    char **out_text,
    size_t *out_text_len,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (out_text == NULL || out_text_len == NULL) {
        write_error(error_buffer, error_buffer_len, "invalid text read output arguments");
        return -1;
    }
    *out_text = NULL;
    *out_text_len = 0;

    if (surface == NULL) {
        write_error(error_buffer, error_buffer_len, "surface is null");
        return -1;
    }
    if (surface->app->library->ghostty_surface_read_text == NULL ||
        surface->app->library->ghostty_surface_free_text == NULL) {
        write_error(error_buffer, error_buffer_len, "ghostty text read symbols are unavailable");
        return -2;
    }

    ghostty_selection_s selection;
    memset(&selection, 0, sizeof(selection));
    selection.top_left.tag = GHOSTTY_POINT_VIEWPORT;
    selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT;
    selection.bottom_right.tag = GHOSTTY_POINT_VIEWPORT;
    selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT;

    ghostty_text_s text;
    memset(&text, 0, sizeof(text));

    bool ok = surface->app->library->ghostty_surface_read_text(surface->surface, selection, &text);
    if (!ok) {
        write_error(error_buffer, error_buffer_len, "ghostty_surface_read_text returned false");
        return -3;
    }
    if (text.text == NULL) {
        surface->app->library->ghostty_surface_free_text(surface->surface, &text);
        write_error(error_buffer, error_buffer_len, "ghostty_surface_read_text returned null text");
        return -3;
    }

    char *copy = calloc(text.text_len + 1, sizeof(char));
    if (copy == NULL) {
        surface->app->library->ghostty_surface_free_text(surface->surface, &text);
        write_error(error_buffer, error_buffer_len, "allocation failed");
        return -4;
    }

    memcpy(copy, text.text, text.text_len);
    copy[text.text_len] = '\0';
    *out_text = copy;
    *out_text_len = text.text_len;

    surface->app->library->ghostty_surface_free_text(surface->surface, &text);
    return 0;
}

void balagan_ghostty_string_free(char *text) {
    free(text);
}
