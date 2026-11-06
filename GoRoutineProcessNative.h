#ifndef DEVELOPER_DASHBOARD_GOROUTINE_PROCESS_NATIVE_H
#define DEVELOPER_DASHBOARD_GOROUTINE_PROCESS_NATIVE_H

#include <stdlib.h>
#include <string.h>
#include <limits.h>
#ifdef _WIN32
#  include <windows.h>
#  include <io.h>
#  include <fcntl.h>
#else
#  include <spawn.h>
#  include <sys/types.h>
#  include <sys/wait.h>
#  include <signal.h>
#  include <errno.h>
#  include <fcntl.h>
#  include <unistd.h>
#  include <stdio.h>
extern char **environ;
#endif

static const char *dd_option_text(pTHX_ HV *options, const char *name) {
    SV **slot = hv_fetch(options, name, (I32)strlen(name), 0);
    if (slot == NULL || !SvOK(*slot)) return NULL;
    if (SvROK(*slot)) croak("GoRoutine process option '%s' must be a scalar", name);
    STRLEN len = 0;
    const char *text = SvPVbyte(*slot, len);
    if (memchr(text, '\0', len) != NULL)
        croak("GoRoutine process option '%s' contains a NUL byte", name);
    return text;
}

static char **dd_argv_from_av(pTHX_ AV *array, I32 *argc_out) {
    I32 last = av_len(array);
    if (last < 0) croak("GoRoutine spawn requires a non-empty argv array");
    if ((UV)last > (UV)(SIZE_MAX / sizeof(char *)) - 1)
        croak("GoRoutine argv array is too large");
    char **argv = (char **)calloc((size_t)last + 2, sizeof(char *));
    if (argv == NULL) croak("out of memory building GoRoutine argv");
    for (I32 index = 0; index <= last; ++index) {
        SV **slot = av_fetch(array, index, 0);
        if (slot == NULL || !SvOK(*slot) || SvROK(*slot)) {
            free(argv);
            croak("GoRoutine argv[%ld] must be a defined scalar", (long)index);
        }
        STRLEN len = 0;
        const char *text = SvPVbyte(*slot, len);
        if (memchr(text, '\0', len) != NULL) {
            free(argv);
            croak("GoRoutine argv[%ld] contains a NUL byte", (long)index);
        }
        argv[index] = (char *)text;
    }
    argv[last + 1] = NULL;
    *argc_out = last + 1;
    return argv;
}

#ifndef _WIN32
static char **dd_child_environment(pTHX_ HV *options) {
    SV **slot = hv_fetch(options, "env", 3, 0);
    char **result;
    size_t count = 0;
    size_t capacity;

    if (slot == NULL) return environ;
    if (!SvROK(*slot) || SvTYPE(SvRV(*slot)) != SVt_PVHV)
        croak("GoRoutine process option 'env' must be a hash reference");

    while (environ[count] != NULL) ++count;
    capacity = count + (size_t)HvTOTALKEYS((HV *)SvRV(*slot)) + 1;
    result = (char **)calloc(capacity, sizeof(char *));
    if (result == NULL) croak("out of memory copying child environment");

    for (size_t i = 0; i < count; ++i) {
        result[i] = strdup(environ[i]);
        if (result[i] == NULL) croak("out of memory copying child environment");
    }

    HV *overrides = (HV *)SvRV(*slot);
    hv_iterinit(overrides);
    HE *entry;
    while ((entry = hv_iternext(overrides)) != NULL) {
        SV *key_sv = hv_iterkeysv(entry);
        SV *value_sv = hv_iterval(overrides, entry);
        STRLEN key_len = 0, value_len = 0;
        const char *key = SvPVbyte(key_sv, key_len);
        const char *value;
        if (key_len == 0 || memchr(key, '=', key_len) || memchr(key, '\0', key_len))
            croak("GoRoutine child environment keys must be non-empty and contain no '=' or NUL");
        if (!SvOK(value_sv) || SvROK(value_sv))
            croak("GoRoutine child environment values must be defined scalars");
        value = SvPVbyte(value_sv, value_len);
        if (memchr(value, '\0', value_len))
            croak("GoRoutine child environment values must not contain NUL");

        char *assignment = (char *)malloc((size_t)key_len + (size_t)value_len + 2);
        if (assignment == NULL) croak("out of memory preparing child environment override");
        memcpy(assignment, key, key_len);
        assignment[key_len] = '=';
        memcpy(assignment + key_len + 1, value, value_len);
        assignment[key_len + value_len + 1] = '\0';

        size_t i;
        for (i = 0; i < count; ++i) {
            if (strncmp(result[i], key, key_len) == 0 && result[i][key_len] == '=') {
                free(result[i]);
                result[i] = assignment;
                break;
            }
        }
        if (i == count) result[count++] = assignment;
    }
    result[count] = NULL;
    return result;
}

static void dd_child_environment_free(char **environment) {
    if (environment == NULL || environment == environ) return;
    for (size_t i = 0; environment[i] != NULL; ++i) free(environment[i]);
    free(environment);
}
#endif

#ifdef _WIN32
static char *dd_windows_command_line(pTHX_ char **argv, I32 argc) {
    size_t capacity = 1;
    for (I32 i = 0; i < argc; ++i) {
        size_t len = strlen(argv[i]);
        if (len > (SIZE_MAX - capacity - 4) / 2)
            croak("GoRoutine command line is too large");
        capacity += (len * 2) + 4;
    }
    char *line = (char *)malloc(capacity);
    if (line == NULL) croak("out of memory building GoRoutine command line");
    char *out = line;
    for (I32 i = 0; i < argc; ++i) {
        const char *arg = argv[i];
        int quote = *arg == '\0' || strpbrk(arg, " \t\n\v\"") != NULL;
        if (i) *out++ = ' ';
        if (quote) *out++ = '"';
        size_t slashes = 0;
        for (; *arg; ++arg) {
            if (*arg == '\\') {
                ++slashes;
                continue;
            }
            if (*arg == '"') {
                while (slashes--) { *out++ = '\\'; *out++ = '\\'; }
                *out++ = '\\';
                *out++ = '"';
                slashes = 0;
                continue;
            }
            while (slashes--) { *out++ = '\\'; }
            slashes = 0;
            *out++ = *arg;
        }
        if (quote) {
            while (slashes--) { *out++ = '\\'; *out++ = '\\'; }
            *out++ = '"';
        }
        else while (slashes--) { *out++ = '\\'; }
    }
    *out = '\0';
    return line;
}

/* A private Windows environment block is required for child-only env overrides.
 * Do not mutate the parent's process environment: spawn may run concurrently
 * with another request or a GoRoutine thread. */
static int dd_windows_environment_entry_cmp(const void *left, const void *right) {
    const char *a = *(const char * const *)left;
    const char *b = *(const char * const *)right;
    return _stricmp(a, b);
}

static char *dd_windows_child_environment(pTHX_ HV *options) {
    SV **slot = hv_fetch(options, "env", 3, 0);
    if (slot == NULL) return NULL; /* inherit without constructing a block */
    if (!SvROK(*slot) || SvTYPE(SvRV(*slot)) != SVt_PVHV)
        croak("GoRoutine process option 'env' must be a hash reference");
    HV *overrides = (HV *)SvRV(*slot);
    LPCH inherited = GetEnvironmentStringsA();
    if (inherited == NULL)
        croak("unable to read GoRoutine parent environment (Windows error %lu)",
              (unsigned long)GetLastError());

    size_t count = 0, capacity = 2;
    const char *entry;
    for (entry = inherited; *entry; entry += strlen(entry) + 1) {
        size_t len = strlen(entry) + 1;
        if (len > SIZE_MAX - capacity) {
            FreeEnvironmentStringsA(inherited);
            croak("GoRoutine child environment is too large");
        }
        capacity += len;
        ++count;
    }
    hv_iterinit(overrides);
    HE *item;
    while ((item = hv_iternext(overrides)) != NULL) {
        SV *key_sv = hv_iterkeysv(item);
        SV *value_sv = hv_iterval(overrides, item);
        STRLEN key_len = 0, value_len = 0;
        const char *key = SvPVbyte(key_sv, key_len);
        if (key_len == 0 || memchr(key, '=', key_len) || memchr(key, '\0', key_len)) {
            FreeEnvironmentStringsA(inherited);
            croak("GoRoutine child environment keys must be non-empty and contain no '=' or NUL");
        }
        if (!SvOK(value_sv) || SvROK(value_sv)) {
            FreeEnvironmentStringsA(inherited);
            croak("GoRoutine child environment values must be defined scalars");
        }
        const char *value = SvPVbyte(value_sv, value_len);
        if (memchr(value, '\0', value_len)) {
            FreeEnvironmentStringsA(inherited);
            croak("GoRoutine child environment values must not contain NUL");
        }
        if ((size_t)key_len > SIZE_MAX - capacity - 2
            || (size_t)value_len > SIZE_MAX - capacity - (size_t)key_len - 2) {
            FreeEnvironmentStringsA(inherited);
            croak("GoRoutine child environment is too large");
        }
        capacity += (size_t)key_len + (size_t)value_len + 2;
        ++count;
    }
    if (count > SIZE_MAX / sizeof(char *)) {
        FreeEnvironmentStringsA(inherited);
        croak("GoRoutine child environment has too many entries");
    }
    char *strings = (char *)malloc(capacity);
    char **entries = (char **)calloc(count ? count : 1, sizeof(char *));
    char *block = (char *)malloc(capacity);
    if (strings == NULL || entries == NULL || block == NULL) {
        free(strings); free(entries); free(block);
        FreeEnvironmentStringsA(inherited);
        croak("out of memory preparing GoRoutine child environment");
    }

    size_t used = 0;
    char *write = strings;
    for (entry = inherited; *entry; entry += strlen(entry) + 1) {
        const char *separator = strchr(entry, '=');
        int overridden = 0;
        /* Windows environment keys are case-insensitive. Preserve inherited
         * special drive entries such as =C:=C:\... as they are not overrides. */
        if (separator != NULL && separator != entry) {
            size_t original_key_len = (size_t)(separator - entry);
            hv_iterinit(overrides);
            while ((item = hv_iternext(overrides)) != NULL) {
                SV *key_sv = hv_iterkeysv(item);
                STRLEN key_len = 0;
                const char *key = SvPVbyte(key_sv, key_len);
                if ((size_t)key_len == original_key_len
                    && _strnicmp(entry, key, original_key_len) == 0) {
                    overridden = 1;
                    break;
                }
            }
        }
        if (overridden) continue;
        size_t len = strlen(entry) + 1;
        entries[used++] = write;
        memcpy(write, entry, len);
        write += len;
    }
    hv_iterinit(overrides);
    while ((item = hv_iternext(overrides)) != NULL) {
        SV *key_sv = hv_iterkeysv(item);
        SV *value_sv = hv_iterval(overrides, item);
        STRLEN key_len = 0, value_len = 0;
        const char *key = SvPVbyte(key_sv, key_len);
        const char *value = SvPVbyte(value_sv, value_len);
        entries[used++] = write;
        memcpy(write, key, key_len); write += key_len;
        *write++ = '=';
        memcpy(write, value, value_len); write += value_len;
        *write++ = '\0';
    }
    FreeEnvironmentStringsA(inherited);

    /* A CreateProcess environment block must be sorted and double-NUL ended. */
    qsort(entries, used, sizeof(char *), dd_windows_environment_entry_cmp);
    write = block;
    for (size_t i = 0; i < used; ++i) {
        size_t len = strlen(entries[i]) + 1;
        memcpy(write, entries[i], len);
        write += len;
    }
    if (used == 0) *write++ = '\0';
    *write = '\0';
    free(entries);
    free(strings);
    return block;
}

static HANDLE dd_windows_redirect(const char *path, DWORD access) {
    if (path == NULL) return INVALID_HANDLE_VALUE;
    SECURITY_ATTRIBUTES inheritable = { sizeof(inheritable), NULL, TRUE };
    return CreateFileA(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       &inheritable, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
}

static UV dd_spawn_process(pTHX_ AV *argv_array, HV *options) {
    I32 argc = 0;
    char **argv = dd_argv_from_av(aTHX_ argv_array, &argc);
    char *line = dd_windows_command_line(aTHX_ argv, argc);
    const char *cwd = dd_option_text(aTHX_ options, "cwd");
    const char *stdout_path = dd_option_text(aTHX_ options, "stdout");
    const char *stderr_path = dd_option_text(aTHX_ options, "stderr");
    const char *stdin_path = dd_option_text(aTHX_ options, "stdin");
    STARTUPINFOA startup;
    PROCESS_INFORMATION process;
    SECURITY_ATTRIBUTES inheritable = { sizeof(inheritable), NULL, TRUE };
    char *child_environment = dd_windows_child_environment(aTHX_ options);
    HANDLE child_in = stdin_path ? CreateFileA(stdin_path, GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE, &inheritable, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL)
        : GetStdHandle(STD_INPUT_HANDLE);
    HANDLE child_out = dd_windows_redirect(stdout_path, GENERIC_WRITE);
    HANDLE child_err = dd_windows_redirect(stderr_path, GENERIC_WRITE);
    if (stdin_path && child_in == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError(); free(line); free(argv); free(child_environment);
        croak("unable to open GoRoutine child stdin (Windows error %lu)", (unsigned long)error);
    }
    if (stdout_path && child_out == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError(); free(line); free(argv); free(child_environment);
        croak("unable to open GoRoutine child stdout (Windows error %lu)", (unsigned long)error);
    }
    if (stderr_path && child_err == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError(); free(line); free(argv); free(child_environment);
        croak("unable to open GoRoutine child stderr (Windows error %lu)", (unsigned long)error);
    }
    if (stdout_path && SetFilePointer(child_out, 0, NULL, FILE_END) == INVALID_SET_FILE_POINTER
        && GetLastError() != NO_ERROR) croak("unable to seek GoRoutine child stdout");
    if (stderr_path && SetFilePointer(child_err, 0, NULL, FILE_END) == INVALID_SET_FILE_POINTER
        && GetLastError() != NO_ERROR) croak("unable to seek GoRoutine child stderr");
    ZeroMemory(&startup, sizeof(startup));
    ZeroMemory(&process, sizeof(process));
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = child_in;
    startup.hStdOutput = stdout_path ? child_out : GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = stderr_path ? child_err : GetStdHandle(STD_ERROR_HANDLE);
    if (!CreateProcessA(NULL, line, NULL, NULL, TRUE, CREATE_NO_WINDOW,
                        child_environment, cwd, &startup, &process)) {
        DWORD error = GetLastError();
        if (stdin_path) CloseHandle(child_in);
        if (stdout_path) CloseHandle(child_out);
        if (stderr_path) CloseHandle(child_err);
        free(line); free(argv); free(child_environment);
        croak("unable to create GoRoutine child process (Windows error %lu)", (unsigned long)error);
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    if (stdin_path) CloseHandle(child_in);
    if (stdout_path) CloseHandle(child_out);
    if (stderr_path) CloseHandle(child_err);
    free(line); free(argv); free(child_environment);
    return (UV)process.dwProcessId;
}
#else
extern char **environ;

static UV dd_spawn_process(pTHX_ AV *argv_array, HV *options) {
    I32 argc = 0;
    char **argv = dd_argv_from_av(aTHX_ argv_array, &argc);
    const char *cwd = dd_option_text(aTHX_ options, "cwd");
    const char *stdout_path = dd_option_text(aTHX_ options, "stdout");
    const char *stderr_path = dd_option_text(aTHX_ options, "stderr");
    const char *stdin_path = dd_option_text(aTHX_ options, "stdin");
    char **child_env = dd_child_environment(aTHX_ options);
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    posix_spawnattr_t *attributes_ptr = NULL;
    int attributes_initialized = 0;
    int process_group = 0;
    SV **group_slot = hv_fetch(options, "process_group", 13, 0);
    if (group_slot != NULL && SvOK(*group_slot)) process_group = SvTRUE(*group_slot) ? 1 : 0;
    int rc = posix_spawn_file_actions_init(&actions);
    if (rc != 0) { dd_child_environment_free(child_env); free(argv); croak("unable to initialise GoRoutine process actions: %s", strerror(rc)); }
    if (stdin_path) rc = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, stdin_path, O_RDONLY, 0);
    if (rc == 0 && stdout_path) rc = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, stdout_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (rc == 0 && stderr_path) rc = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, stderr_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (rc != 0) {
        posix_spawn_file_actions_destroy(&actions); dd_child_environment_free(child_env); free(argv);
        croak("unable to configure GoRoutine child file actions: %s", strerror(rc));
    }
    if (process_group) {
        short flags = POSIX_SPAWN_SETPGROUP;
        rc = posix_spawnattr_init(&attributes);
        if (rc == 0) attributes_initialized = 1;
        if (rc == 0) rc = posix_spawnattr_setflags(&attributes, flags);
        if (rc == 0) rc = posix_spawnattr_setpgroup(&attributes, 0);
        if (rc != 0) {
            if (attributes_initialized) posix_spawnattr_destroy(&attributes);
            posix_spawn_file_actions_destroy(&actions); dd_child_environment_free(child_env); free(argv);
            croak("unable to configure GoRoutine child process group: %s", strerror(rc));
        }
        attributes_ptr = &attributes;
    }
    char **child_argv = argv;
    char **wrapped_argv = NULL;
    if (cwd && *cwd) {
#if defined(__GLIBC__) || defined(__APPLE__)
        rc = posix_spawn_file_actions_addchdir_np(&actions, cwd);
        if (rc != 0) {
            posix_spawn_file_actions_destroy(&actions); free(argv);
            croak("unable to set GoRoutine child working directory: %s", strerror(rc));
        }
#else
        static char chdir_script[] = "cd \"$1\" || exit; shift; exec \"$@\"";
        wrapped_argv = (char **)calloc((size_t)argc + 5, sizeof(char *));
        if (wrapped_argv == NULL) {
            posix_spawn_file_actions_destroy(&actions); free(argv);
            croak("out of memory preparing GoRoutine child working directory");
        }
        wrapped_argv[0] = (char *)"/bin/sh";
        wrapped_argv[1] = (char *)"-c";
        wrapped_argv[2] = chdir_script;
        wrapped_argv[3] = (char *)"goroutine-spawn";
        wrapped_argv[4] = (char *)cwd;
        for (I32 i = 0; i < argc; ++i) wrapped_argv[i + 5] = argv[i];
        child_argv = wrapped_argv;
#endif
    }
    pid_t pid = 0;
    rc = posix_spawnp(&pid, child_argv[0], &actions, attributes_ptr, child_argv, child_env);
    if (attributes_ptr != NULL) posix_spawnattr_destroy(attributes_ptr);
    posix_spawn_file_actions_destroy(&actions);
    free(wrapped_argv);
    free(argv);
    dd_child_environment_free(child_env);
    if (rc != 0) croak("unable to spawn GoRoutine child process: %s", strerror(rc));
    return (UV)pid;
}
#endif



#endif

