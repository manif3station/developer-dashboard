#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <sys/types.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>

/* -------------------------------------------------------------------------
 * Native threading portability layer
 *
 * Unix/macOS: pthreads
 * Windows:    Win32 threads + CRITICAL_SECTION + CONDITION_VARIABLE
 *
 * Do not expose any of this to Perl callers.  The Perl API remains exactly
 * the same on every platform.
 * ------------------------------------------------------------------------- */
#ifdef _WIN32
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#  include <process.h>
#  include <io.h>

typedef struct {
    HANDLE handle;
    DWORD  id;
} go_thread_t;
typedef CRITICAL_SECTION   go_mutex_t;
typedef CONDITION_VARIABLE go_cond_t;
typedef INIT_ONCE          go_once_t;
typedef DWORD              go_tls_key_t;

#  define GO_ONCE_INIT INIT_ONCE_STATIC_INIT
#  define GO_WAIT_INFINITE INFINITE

static int go_mutex_init(go_mutex_t *m) { InitializeCriticalSection(m); return 0; }
static int go_mutex_init_recursive(go_mutex_t *m) { InitializeCriticalSection(m); return 0; }
static int go_mutex_destroy(go_mutex_t *m) { DeleteCriticalSection(m); return 0; }
static int go_mutex_lock(go_mutex_t *m) { EnterCriticalSection(m); return 0; }
static int go_mutex_unlock(go_mutex_t *m) { LeaveCriticalSection(m); return 0; }

static int go_cond_init(go_cond_t *c) { InitializeConditionVariable(c); return 0; }
static int go_cond_destroy(go_cond_t *c) { (void)c; return 0; }
static int go_cond_broadcast(go_cond_t *c) { WakeAllConditionVariable(c); return 0; }
static int go_cond_signal(go_cond_t *c) { WakeConditionVariable(c); return 0; }

static int
go_cond_wait_ms(go_cond_t *c, go_mutex_t *m, DWORD milliseconds)
{
    BOOL ok = SleepConditionVariableCS(c, m, milliseconds);
    if (ok) return 0;
    {
        DWORD err = GetLastError();
        if (err == ERROR_TIMEOUT) return ETIMEDOUT;
        return (int)err;
    }
}

static int go_cond_wait(go_cond_t *c, go_mutex_t *m)
{
    return go_cond_wait_ms(c, m, GO_WAIT_INFINITE);
}

static BOOL CALLBACK
go_once_thunk(PINIT_ONCE once, PVOID param, PVOID *context)
{
    void (*fn)(void) = (void (*)(void))param;
    (void)once;
    (void)context;
    fn();
    return TRUE;
}

static int go_once(go_once_t *once, void (*fn)(void))
{
    return InitOnceExecuteOnce(once, go_once_thunk, (PVOID)fn, NULL) ? 0 : (int)GetLastError();
}

static int go_tls_key_create(go_tls_key_t *key)
{
    DWORD k = TlsAlloc();
    if (k == TLS_OUT_OF_INDEXES) return (int)GetLastError();
    *key = k;
    return 0;
}
static void *go_tls_get(go_tls_key_t key) { return TlsGetValue(key); }
static int go_tls_set(go_tls_key_t key, void *value) { return TlsSetValue(key, value) ? 0 : (int)GetLastError(); }

struct go_win_start {
    void *(*fn)(void *);
    void *arg;
};

static DWORD WINAPI
go_win_thread_thunk(LPVOID opaque)
{
    struct go_win_start *start = (struct go_win_start *)opaque;
    void *(*fn)(void *) = start->fn;
    void *arg = start->arg;
    free(start);
    (void)fn(arg);
    return 0;
}

static int
go_thread_create(go_thread_t *thread, void *(*fn)(void *), void *arg)
{
    struct go_win_start *start = (struct go_win_start *)malloc(sizeof(*start));
    HANDLE h;
    DWORD id = 0;
    if (start == NULL) return ENOMEM;
    start->fn = fn;
    start->arg = arg;
    h = CreateThread(NULL, 0, go_win_thread_thunk, start, 0, &id);
    if (h == NULL) {
        int err = (int)GetLastError();
        free(start);
        return err ? err : EAGAIN;
    }
    thread->handle = h;
    thread->id = id;
    return 0;
}

static int
go_thread_detach(go_thread_t thread)
{
    if (thread.handle != NULL && !CloseHandle(thread.handle))
        return (int)GetLastError();
    return 0;
}

/*
 * Windows has no pthread_kill equivalent.  Wake the worker's message queue
 * when possible.  GoRoutine cancellation remains cooperative: opcode-bound
 * work and channel waits see the cancellation immediately.  Perl's Win32
 * sleep/message wait also owns a thread message queue, so this poke prevents
 * a worker from being invisible to the scheduler while it is in that path.
 */
static void
go_thread_wake(go_thread_t thread)
{
    /* There is no safe Win32 equivalent of pthread_kill for an arbitrary
     * Perl interpreter thread.  Channel waits are explicitly broadcast and
     * opcode execution polls the cancellation flag.  Never use
     * TerminateThread(): it can leave Perl/CRT locks permanently corrupted. */
    (void)thread;
}

static double
go_monotonic_seconds(void)
{
    static LARGE_INTEGER frequency;
    static LONG initialized = 0;
    LARGE_INTEGER now;
    if (InterlockedCompareExchange(&initialized, 1, 0) == 0) {
        QueryPerformanceFrequency(&frequency);
    }
    QueryPerformanceCounter(&now);
    return (double)now.QuadPart / (double)frequency.QuadPart;
}

#else /* !_WIN32 */
#  include <pthread.h>
#  include <signal.h>
#  include <unistd.h>

typedef pthread_t       go_thread_t;
typedef pthread_mutex_t go_mutex_t;
typedef pthread_cond_t  go_cond_t;
typedef pthread_once_t  go_once_t;
typedef pthread_key_t   go_tls_key_t;

#  define GO_ONCE_INIT PTHREAD_ONCE_INIT

static int go_mutex_init(go_mutex_t *m) { return pthread_mutex_init(m, NULL); }
static int
go_mutex_init_recursive(go_mutex_t *m)
{
    pthread_mutexattr_t attr;
    int rc;
    if ((rc = pthread_mutexattr_init(&attr)) != 0) return rc;
    if ((rc = pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE)) != 0) {
        pthread_mutexattr_destroy(&attr);
        return rc;
    }
    rc = pthread_mutex_init(m, &attr);
    pthread_mutexattr_destroy(&attr);
    return rc;
}
static int go_mutex_destroy(go_mutex_t *m) { return pthread_mutex_destroy(m); }
static int go_mutex_lock(go_mutex_t *m) { return pthread_mutex_lock(m); }
static int go_mutex_unlock(go_mutex_t *m) { return pthread_mutex_unlock(m); }
static int go_cond_init(go_cond_t *c) { return pthread_cond_init(c, NULL); }
static int go_cond_destroy(go_cond_t *c) { return pthread_cond_destroy(c); }
static int go_cond_broadcast(go_cond_t *c) { return pthread_cond_broadcast(c); }
static int go_cond_signal(go_cond_t *c) { return pthread_cond_signal(c); }
static int go_cond_wait(go_cond_t *c, go_mutex_t *m) { return pthread_cond_wait(c, m); }

static int
go_cond_wait_ms(go_cond_t *c, go_mutex_t *m, unsigned long milliseconds)
{
    struct timespec deadline;
    unsigned long sec = milliseconds / 1000UL;
    unsigned long rem_ms = milliseconds % 1000UL;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t)sec;
    deadline.tv_nsec += (long)rem_ms * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000L;
    }
    return pthread_cond_timedwait(c, m, &deadline);
}

static int go_once(go_once_t *once, void (*fn)(void)) { return pthread_once(once, fn); }
static int go_tls_key_create(go_tls_key_t *key) { return pthread_key_create(key, NULL); }
static void *go_tls_get(go_tls_key_t key) { return pthread_getspecific(key); }
static int go_tls_set(go_tls_key_t key, void *value) { return pthread_setspecific(key, value); }
static int go_thread_create(go_thread_t *thread, void *(*fn)(void *), void *arg) { return pthread_create(thread, NULL, fn, arg); }
static int go_thread_detach(go_thread_t thread) { return pthread_detach(thread); }

#  define GO_WAKE_SIGNAL SIGURG
static void go_wake_signal_handler(int signo) { (void)signo; }
static void
go_thread_signal_init(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = go_wake_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(GO_WAKE_SIGNAL, &sa, NULL);
}
static void go_thread_wake(go_thread_t thread) { (void)pthread_kill(thread, GO_WAKE_SIGNAL); }
static double
go_monotonic_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}
#endif

static char *
go_strdup(const char *s)
{
    size_t len = strlen(s);
    char *out = (char *)malloc(len + 1);
    if (out != NULL) memcpy(out, s, len + 1);
    return out;
}

static UV
go_clone_flags(void)
{
    UV flags = CLONEf_KEEP_PTR_TABLE;
#ifdef _WIN32
#  ifdef CLONEf_CLONE_HOST
    flags |= CLONEf_CLONE_HOST;
#  endif
#endif
    return flags;
}

typedef enum {
    GO_STATE_RUNNING = 0,
    GO_STATE_DONE,
    GO_STATE_KILLED,
    GO_STATE_TIMED_OUT,
    GO_STATE_EXITED,
    GO_STATE_FAILED
} go_state;

typedef enum {
    GO_CANCEL_NONE = 0,
    GO_CANCEL_KILL,
    GO_CANCEL_TIMEOUT
} go_cancel_reason;

typedef struct go_control {
    go_mutex_t mutex;
    go_cond_t  cond;
    go_thread_t       thread;
    int             thread_valid;
    go_state        state;
    go_cancel_reason cancel_reason;
    int             cancel_requested;
    int             exit_requested;
    double          started_at;
    double          finished_at;
    unsigned long   timeout_generation;
    double          timeout_seconds;
} go_control;

typedef struct {
    PerlInterpreter *interp;
    SV              *callback;
    go_control      *control;
} go_job;

typedef struct {
    go_control    *control;
    unsigned long  generation;
    double         seconds;
} go_timeout_job;

typedef enum {
    SHARED_UNDEF = 0,
    SHARED_IV,
    SHARED_NV,
    SHARED_PV,
    SHARED_HASH,
    SHARED_ARRAY,
    SHARED_SCALARREF,
    SHARED_OBJECT,
    SHARED_CODE,
    SHARED_GLOB,
    SHARED_IO,
    SHARED_REGEXP,
    SHARED_FORMAT
} shared_type;

typedef struct shared_node shared_node;

typedef struct shared_code_state {
    PerlInterpreter *interp;
    SV              *callback;
    go_mutex_t  mutex;
} shared_code_state;

typedef struct shared_handle_state {
    PerlInterpreter *interp;
    SV              *handle;
    go_mutex_t  mutex;
} shared_handle_state;

typedef struct go_channel {
    go_mutex_t mutex;
    go_cond_t  can_send;
    go_cond_t  can_receive;
    size_t          capacity;
    int             closed;

    /* Unbuffered rendezvous slot. */
    shared_node    *slot;
    unsigned long   slot_seq;
    unsigned long   consumed_seq;
    unsigned long   next_seq;

    /* Buffered-channel ring. */
    shared_node   **buffer;
    size_t          head;
    size_t          tail;
    size_t          count;
} go_channel;

typedef struct {
    char        *key;
    STRLEN       key_len;
    shared_node *value;
} shared_hash_entry;

struct shared_node {
    shared_type type;
    IV iv;
    NV nv;
    char *pv;
    STRLEN pv_len;
    U8 pv_utf8;
    char *class_name;

    shared_hash_entry *hash_entries;
    size_t hash_count;
    size_t hash_capacity;

    shared_node **array_items;
    size_t array_size;
    size_t array_capacity;

    shared_node *scalarref_value;

    /* CODE references execute in a private cloned interpreter. */
    shared_code_state *code;

    /* GLOB/IO references keep a process-owned duplicate descriptor. */
    int io_fd;
    int io_mode; /* 0 = read, 1 = write, 2 = read/write */

    /* Typeglob slots are themselves shared graph nodes. */
    shared_node *glob_scalar;
    shared_node *glob_array;
    shared_node *glob_hash;
    shared_node *glob_code;

    /* Non-fd PerlIO (for example a scalar-backed handle) is served by a
     * private interpreter and exposed through a tied GLOB proxy. */
    shared_handle_state *handle_state;
};

typedef struct {
    const void  **source;
    shared_node **node;
    size_t count;
    size_t capacity;
} import_map;

static go_once_t go_tls_once = GO_ONCE_INIT;
static go_tls_key_t go_tls_key;
static go_once_t go_signal_once = GO_ONCE_INIT;

#define GO_CANCEL_EXCEPTION "__DEVELOPER_DASHBOARD_GOROUTINE_CANCEL__"
#define GO_EXIT_EXCEPTION   "__DEVELOPER_DASHBOARD_GOROUTINE_EXIT__"

static void
go_tls_init_once(void)
{
    if (go_tls_key_create(&go_tls_key) != 0) {
        abort();
    }
}

static void
go_signal_init_once(void)
{
#ifndef _WIN32
    go_thread_signal_init();
#endif
}

static int
go_control_is_running(go_control *ctl)
{
    int running;
    go_mutex_lock(&ctl->mutex);
    running = (ctl->state == GO_STATE_RUNNING);
    go_mutex_unlock(&ctl->mutex);
    return running;
}

static int
go_control_request_cancel(go_control *ctl, go_cancel_reason reason)
{
    go_thread_t tid;
    int valid = 0;
    int requested = 0;

    go_mutex_lock(&ctl->mutex);
    if (ctl->state == GO_STATE_RUNNING && !ctl->cancel_requested) {
        ctl->cancel_requested = 1;
        ctl->cancel_reason = reason;
        tid = ctl->thread;
        valid = ctl->thread_valid;
        requested = 1;
        go_cond_broadcast(&ctl->cond);
    }
    go_mutex_unlock(&ctl->mutex);

    if (requested && valid) {
        go_thread_wake(tid);
    }
    return requested;
}

static int
go_control_cancel_requested(go_control *ctl)
{
    int requested;
    go_mutex_lock(&ctl->mutex);
    requested = ctl->cancel_requested;
    go_mutex_unlock(&ctl->mutex);
    return requested;
}

static int
go_control_exit_requested(go_control *ctl)
{
    int requested;
    go_mutex_lock(&ctl->mutex);
    requested = ctl->exit_requested;
    go_mutex_unlock(&ctl->mutex);
    return requested;
}

static void
go_control_request_exit(go_control *ctl)
{
    go_mutex_lock(&ctl->mutex);
    ctl->exit_requested = 1;
    go_mutex_unlock(&ctl->mutex);
}

static int
go_runops(pTHX)
{
    go_control *ctl;

    go_once(&go_tls_once, go_tls_init_once);
    ctl = (go_control *)go_tls_get(go_tls_key);

    while (PL_op) {
        if (ctl && go_control_cancel_requested(ctl)) {
            croak(GO_CANCEL_EXCEPTION);
        }
        if (ctl && go_control_exit_requested(ctl)) {
            croak(GO_EXIT_EXCEPTION);
        }
        if (ctl && PL_op->op_type == OP_EXIT) {
            go_control_request_exit(ctl);
            croak(GO_EXIT_EXCEPTION);
        }

        PL_op = CALL_FPTR(PL_op->op_ppaddr)(aTHX);
        PERL_ASYNC_CHECK();
    }

    return 0;
}

static void
go_control_finish(go_control *ctl, go_state state)
{
    double now = go_monotonic_seconds();

    go_mutex_lock(&ctl->mutex);
    ctl->state = state;
    ctl->finished_at = now;
    ctl->thread_valid = 0;
    go_cond_broadcast(&ctl->cond);
    go_mutex_unlock(&ctl->mutex);
}

static void *
go_timeout_worker(void *arg)
{
    go_timeout_job *timer = (go_timeout_job *)arg;
    go_control *ctl = timer->control;
    double deadline = go_monotonic_seconds() + (timer->seconds > 0 ? timer->seconds : 0);
    int should_cancel = 0;

    go_mutex_lock(&ctl->mutex);
    while (ctl->state == GO_STATE_RUNNING
           && ctl->timeout_generation == timer->generation
           && ctl->timeout_seconds > 0) {
        double remaining = deadline - go_monotonic_seconds();
        unsigned long wait_ms;
        if (remaining <= 0) {
            should_cancel = 1;
            break;
        }
        wait_ms = (unsigned long)(remaining * 1000.0);
        if (wait_ms == 0) wait_ms = 1;
        if (wait_ms > 100UL) wait_ms = 100UL;
        (void)go_cond_wait_ms(&ctl->cond, &ctl->mutex, wait_ms);
    }
    go_mutex_unlock(&ctl->mutex);

    if (should_cancel) {
        go_control_request_cancel(ctl, GO_CANCEL_TIMEOUT);
    }

    free(timer);
    return NULL;
}

static go_control *
go_control_new(void)
{
    go_control *ctl = (go_control *)calloc(1, sizeof(*ctl));
    if (ctl == NULL) {
        croak("out of memory allocating go routine control");
    }
    go_mutex_init(&ctl->mutex);
    go_cond_init(&ctl->cond);
    ctl->state = GO_STATE_RUNNING;
    ctl->cancel_reason = GO_CANCEL_NONE;
    ctl->started_at = go_monotonic_seconds();
    return ctl;
}

static go_control *
go_control_from_uv(UV ptr)
{
    go_control *ctl = INT2PTR(go_control *, ptr);
    if (ctl == NULL) {
        croak("invalid go routine handle");
    }
    return ctl;
}

static SV *
go_handle_new(pTHX_ go_control *ctl)
{
    HV *hv = newHV();
    SV *rv;
    hv_store(hv, "ptr", 3, newSVuv(PTR2UV(ctl)), 0);
    rv = newRV_noinc((SV *)hv);
    sv_bless(rv, gv_stashpv("Developer::Dashboard::GoRoutine::Routine", GV_ADD));
    return rv;
}

static go_once_t go_count_once = GO_ONCE_INIT;
static go_mutex_t go_count_mutex;
static go_cond_t  go_count_cond;
static unsigned long go_active = 0;

static void
go_count_init_once(void)
{
    if (go_mutex_init(&go_count_mutex) != 0 || go_cond_init(&go_count_cond) != 0)
        abort();
}

static go_once_t shared_mutex_once = GO_ONCE_INIT;
static go_mutex_t shared_mutex;

static void
shared_mutex_init_once(void)
{
    if (go_mutex_init_recursive(&shared_mutex) != 0)
        abort();
}

static void shared_lock(void)
{
    go_once(&shared_mutex_once, shared_mutex_init_once);
    go_mutex_lock(&shared_mutex);
}

static void shared_unlock(void)
{
    go_mutex_unlock(&shared_mutex);
}

static void
go_wait_all_internal(void)
{
    go_once(&go_count_once, go_count_init_once);
    go_mutex_lock(&go_count_mutex);
    while (go_active != 0) {
        go_cond_wait(&go_count_cond, &go_count_mutex);
    }
    go_mutex_unlock(&go_count_mutex);
}

static void
go_root_atexit(pTHX_ void *owner_ptr)
{
    if (aTHX == (PerlInterpreter *)owner_ptr)
        go_wait_all_internal();
}

static void
go_active_inc(void)
{
    go_once(&go_count_once, go_count_init_once);
    go_mutex_lock(&go_count_mutex);
    ++go_active;
    go_mutex_unlock(&go_count_mutex);
}

static void
go_active_dec(void)
{
    go_once(&go_count_once, go_count_init_once);
    go_mutex_lock(&go_count_mutex);
    if (go_active > 0) {
        --go_active;
    }
    go_cond_broadcast(&go_count_cond);
    go_mutex_unlock(&go_count_mutex);
}

static void
go_destroy_interpreter(PerlInterpreter *interp)
{
    PERL_SET_CONTEXT(interp);
    {
        dTHXa(interp);
        PL_exit_flags &= ~PERL_EXIT_DESTRUCT_END;
    }
    perl_destruct(interp);
    perl_free(interp);
}

static void *
go_worker(void *arg)
{
    go_job *job = (go_job *)arg;
    PerlInterpreter *interp = job->interp;
    go_control *ctl = job->control;
    go_state final_state = GO_STATE_DONE;

    go_once(&go_tls_once, go_tls_init_once);
    go_tls_set(go_tls_key, ctl);

    PERL_SET_CONTEXT(interp);
    {
        dTHX;
        dSP;
        PL_runops = go_runops;

        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        PUTBACK;
        call_sv(job->callback, G_VOID | G_DISCARD | G_EVAL);
        SPAGAIN;

        if (SvTRUE(ERRSV)) {
            STRLEN len = 0;
            const char *msg = SvPV(ERRSV, len);

            if (strstr(msg, GO_CANCEL_EXCEPTION) != NULL) {
                go_mutex_lock(&ctl->mutex);
                final_state = (ctl->cancel_reason == GO_CANCEL_TIMEOUT)
                    ? GO_STATE_TIMED_OUT : GO_STATE_KILLED;
                go_mutex_unlock(&ctl->mutex);
            }
            else if (strstr(msg, GO_EXIT_EXCEPTION) != NULL) {
                final_state = GO_STATE_EXITED;
            }
            else {
                final_state = GO_STATE_FAILED;
                Perl_warn(aTHX_ "Developer::Dashboard::GoRoutine worker died: %.*s",
                          (int)len, msg);
            }
            sv_setsv(ERRSV, &PL_sv_undef);
        }

        PUTBACK;
        FREETMPS;
        LEAVE;
        SvREFCNT_dec(job->callback);
    }

    go_tls_set(go_tls_key, NULL);
    go_control_finish(ctl, final_state);
    go_destroy_interpreter(interp);
    free(job);
    go_active_dec();
    return NULL;
}

static shared_node *
shared_node_new(void)
{
    shared_node *n = (shared_node *)calloc(1, sizeof(*n));
    if (n == NULL) {
        croak("out of memory allocating shared node");
    }
    n->type = SHARED_UNDEF;
    n->io_fd = -1;
    return n;
}

static shared_node *
shared_from_uv(UV ptr)
{
    shared_node *n = INT2PTR(shared_node *, ptr);
    if (n == NULL) {
        croak("invalid shared value handle");
    }
    return n;
}

static void
shared_node_clear(shared_node *n)
{
    size_t i;

    if (n->pv != NULL) {
        free(n->pv);
        n->pv = NULL;
        n->pv_len = 0;
    }
    if (n->class_name != NULL) {
        free(n->class_name);
        n->class_name = NULL;
    }
    if (n->hash_entries != NULL) {
        for (i = 0; i < n->hash_count; ++i) {
            free(n->hash_entries[i].key);
        }
        free(n->hash_entries);
        n->hash_entries = NULL;
        n->hash_count = 0;
        n->hash_capacity = 0;
    }
    if (n->array_items != NULL) {
        free(n->array_items);
        n->array_items = NULL;
        n->array_size = 0;
        n->array_capacity = 0;
    }
    /* Frozen CODE interpreters are intentionally retained for process life.
     * A fetched callback may still be in flight when a graph slot is replaced. */
    n->code = NULL;

    if (n->io_fd >= 0) {
        PerlLIO_close(n->io_fd);
    }
    n->io_fd = -1;
    n->io_mode = 0;

    n->glob_scalar = NULL;
    n->glob_array = NULL;
    n->glob_hash = NULL;
    n->glob_code = NULL;
    /* Private handle interpreters are process-lifetime, like shared CODE
     * states, so an in-flight tied handle call can never be invalidated. */
    n->handle_state = NULL;
    n->scalarref_value = NULL;
    n->type = SHARED_UNDEF;
    n->iv = 0;
    n->nv = 0;
    n->pv_utf8 = 0;
}

static void
shared_set_class(shared_node *n, const char *name)
{
    size_t len;
    if (n->class_name != NULL) {
        free(n->class_name);
        n->class_name = NULL;
    }
    if (name == NULL || *name == '\0') {
        return;
    }
    len = strlen(name);
    n->class_name = (char *)malloc(len + 1);
    if (n->class_name == NULL) {
        croak("out of memory storing shared object class");
    }
    memcpy(n->class_name, name, len + 1);
}

static const char *
shared_sv_class(SV *value)
{
    SV *rv;
    HV *stash;
    if (!SvROK(value)) {
        return NULL;
    }
    rv = SvRV(value);
    if (!SvOBJECT(rv)) {
        return NULL;
    }
    stash = SvSTASH(rv);
    return stash ? HvNAME(stash) : NULL;
}

static shared_node *
import_map_find(import_map *map, const void *source)
{
    size_t i;
    for (i = 0; i < map->count; ++i) {
        if (map->source[i] == source) {
            return map->node[i];
        }
    }
    return NULL;
}

static void
import_map_add(import_map *map, const void *source, shared_node *node)
{
    if (map->count == map->capacity) {
        size_t newcap = map->capacity ? map->capacity * 2 : 16;
        const void **ns = (const void **)realloc((void *)map->source, newcap * sizeof(*ns));
        shared_node **nn = (shared_node **)realloc(map->node, newcap * sizeof(*nn));
        if (ns == NULL || nn == NULL) {
            free((void *)ns);
            free(nn);
            croak("out of memory importing shared structure");
        }
        map->source = ns;
        map->node = nn;
        map->capacity = newcap;
    }
    map->source[map->count] = source;
    map->node[map->count] = node;
    ++map->count;
}

static void
shared_hash_reserve(shared_node *n, size_t need)
{
    if (need > n->hash_capacity) {
        size_t cap = n->hash_capacity ? n->hash_capacity * 2 : 8;
        shared_hash_entry *p;
        while (cap < need) cap *= 2;
        p = (shared_hash_entry *)realloc(n->hash_entries, cap * sizeof(*p));
        if (p == NULL) {
            croak("out of memory growing shared hash");
        }
        memset(p + n->hash_capacity, 0,
               (cap - n->hash_capacity) * sizeof(*p));
        n->hash_entries = p;
        n->hash_capacity = cap;
    }
}

static void
shared_array_reserve(shared_node *n, size_t need)
{
    if (need > n->array_capacity) {
        size_t cap = n->array_capacity ? n->array_capacity * 2 : 8;
        shared_node **p;
        while (cap < need) cap *= 2;
        p = (shared_node **)realloc(n->array_items, cap * sizeof(*p));
        if (p == NULL) {
            croak("out of memory growing shared array");
        }
        memset(p + n->array_capacity, 0,
               (cap - n->array_capacity) * sizeof(*p));
        n->array_items = p;
        n->array_capacity = cap;
    }
}


static shared_node *shared_import_value(pTHX_ SV *value, import_map *map, shared_node *preferred);
static SV *shared_copy_scalar(pTHX_ const shared_node *n);

static int
shared_io_mode(IO *io)
{
    int type;
    if (io == NULL) return 2;
    type = (int)IoTYPE(io);
    switch (type) {
        case IoTYPE_RDONLY: return 0;
        case IoTYPE_WRONLY:
        case IoTYPE_APPEND: return 1;
        case IoTYPE_RDWR:   return 2;
        default:
            /* STD/implicit/socket/numeric handles may not encode access in
             * IoTYPE.  Infer from the active PerlIO sides when possible. */
            if (IoIFP(io) != NULL && IoOFP(io) == NULL) return 0;
            if (IoOFP(io) != NULL && IoIFP(io) == NULL) return 1;
            return 2;
    }
}

static void
shared_capture_io(shared_node *n, IO *io)
{
    PerlIO *fp = NULL;
    int fd = -1;

    n->io_fd = -1;
    n->io_mode = 0;
    if (io == NULL) return;

    fp = IoIFP(io);
    if (fp == NULL) fp = IoOFP(io);
    if (fp != NULL) fd = PerlIO_fileno(fp);
    if (fd < 0) return;

    n->io_fd = PerlLIO_dup(fd);
    if (n->io_fd < 0) {
        croak("could not duplicate shared filehandle descriptor: %s", Strerror(errno));
    }
    n->io_mode = shared_io_mode(io);
}

static shared_node *
shared_import_target_ref(pTHX_ SV *target, import_map *map)
{
    SV *tmp;
    shared_node *out;
    if (target == NULL) return NULL;
    tmp = newRV_inc(target);
    out = shared_import_value(aTHX_ tmp, map, NULL);
    SvREFCNT_dec(tmp);
    return out;
}

static shared_handle_state *
shared_freeze_handle(pTHX_ SV *value)
{
    PerlInterpreter *owner = aTHX;
    PerlInterpreter *frozen;
    SV *frozen_value = NULL;
    shared_handle_state *state;

    frozen = perl_clone(owner, go_clone_flags());
    if (frozen == NULL) {
        croak("perl_clone() failed while sharing non-fd filehandle");
    }

    PERL_SET_CONTEXT(frozen);
    {
        dTHXa(frozen);
        frozen_value = (SV *)ptr_table_fetch(PL_ptr_table, value);
        if (frozen_value != NULL) {
            SvREFCNT_inc(frozen_value);
        }
        else if (SvROK(value)) {
            SV *frozen_rv = (SV *)ptr_table_fetch(PL_ptr_table, SvRV(value));
            frozen_value = frozen_rv ? newRV_inc(frozen_rv) : NULL;
        }
    }
    PERL_SET_CONTEXT(owner);

    if (frozen_value == NULL) {
        go_destroy_interpreter(frozen);
        PERL_SET_CONTEXT(owner);
        croak("could not clone non-fd filehandle into private interpreter");
    }

    state = (shared_handle_state *)calloc(1, sizeof(*state));
    if (state == NULL) {
        PERL_SET_CONTEXT(frozen);
        {
            dTHXa(frozen);
            SvREFCNT_dec(frozen_value);
        }
        go_destroy_interpreter(frozen);
        PERL_SET_CONTEXT(owner);
        croak("out of memory allocating shared filehandle state");
    }

    state->interp = frozen;
    state->handle = frozen_value;
    if (go_mutex_init_recursive(&state->mutex) != 0)
        croak("could not initialize shared state mutex");
    return state;
}

static void
shared_import_glob(pTHX_ shared_node *n, SV *value, import_map *map)
{
    GV *gv = (GV *)SvRV(value);
    SV *slot;
    AV *av;
    HV *hv;
    CV *cv;
    IO *io;
    const char *class_name = shared_sv_class(value);

    shared_node_clear(n);
    n->type = SHARED_GLOB;
    shared_set_class(n, class_name);

    slot = GvSV(gv);
    if (slot != NULL) n->glob_scalar = shared_import_value(aTHX_ slot, map, NULL);

    av = GvAV(gv);
    if (av != NULL) n->glob_array = shared_import_target_ref(aTHX_ (SV *)av, map);

    hv = GvHV(gv);
    if (hv != NULL) n->glob_hash = shared_import_target_ref(aTHX_ (SV *)hv, map);

    cv = GvCV(gv);
    if (cv != NULL) n->glob_code = shared_import_target_ref(aTHX_ (SV *)cv, map);

    io = GvIOp(gv);
    shared_capture_io(n, io);
    if (io != NULL && n->io_fd < 0) {
        n->handle_state = shared_freeze_handle(aTHX_ value);
    }
}

static void
shared_import_io(pTHX_ shared_node *n, SV *value)
{
    IO *io = (IO *)SvRV(value);
    const char *class_name = shared_sv_class(value);
    shared_node_clear(n);
    n->type = SHARED_IO;
    shared_set_class(n, class_name);
    shared_capture_io(n, io);
    if (n->io_fd < 0) {
        n->handle_state = shared_freeze_handle(aTHX_ value);
    }
}

static void
shared_import_regexp(pTHX_ shared_node *n, SV *value)
{
    STRLEN len = 0;
    const char *pv;
    const char *class_name = shared_sv_class(value);

    shared_node_clear(n);
    n->type = SHARED_REGEXP;
    shared_set_class(n, class_name);

    pv = SvPV(value, len);
    n->pv = (char *)malloc(len + 1);
    if (n->pv == NULL) croak("out of memory storing shared regexp");
    memcpy(n->pv, pv, len);
    n->pv[len] = '\0';
    n->pv_len = len;
}

static void
shared_import_format(pTHX_ shared_node *n, SV *value)
{
    CV *fm = (CV *)SvRV(value);
    GV *gv = CvGV(fm);
    const char *stash = NULL;
    const char *name = NULL;
    STRLEN slen = 0, nlen = 0;
    size_t total;

    shared_node_clear(n);
    n->type = SHARED_FORMAT;

    if (gv != NULL) {
        HV *st = GvSTASH(gv);
        stash = st ? HvNAME(st) : NULL;
        name = GvNAME(gv);
    }
    if (stash == NULL || name == NULL) return;

    slen = (STRLEN)strlen(stash);
    nlen = (STRLEN)strlen(name);
    total = (size_t)slen + 2 + (size_t)nlen;
    n->pv = (char *)malloc(total + 1);
    if (n->pv == NULL) croak("out of memory storing shared format name");
    memcpy(n->pv, stash, slen);
    memcpy(n->pv + slen, "::", 2);
    memcpy(n->pv + slen + 2, name, nlen);
    n->pv[total] = '\0';
    n->pv_len = (STRLEN)total;
}

static void
shared_import_code(pTHX_ shared_node *n, SV *value)
{
    PerlInterpreter *owner = aTHX;
    PerlInterpreter *frozen;
    SV *frozen_callback = NULL;
    shared_code_state *state;

    /*
     * A CV is interpreter-owned and must never be dereferenced concurrently
     * from another interpreter.  Give every shared callback its own private
     * interpreter clone.  Calls from any go routine temporarily switch into
     * that private interpreter under a mutex, invoke the callback there, and
     * switch back.  Anonymous closures therefore keep their lexical pad.
     */
    frozen = perl_clone(owner, go_clone_flags());
    if (frozen == NULL) {
        croak("perl_clone() failed while sharing CODE reference");
    }

    PERL_SET_CONTEXT(frozen);
    {
        dTHXa(frozen);
        frozen_callback = (SV *)ptr_table_fetch(PL_ptr_table, value);
        if (frozen_callback != NULL) {
            SvREFCNT_inc(frozen_callback);
        }
        else {
            SV *frozen_cv = (SV *)ptr_table_fetch(PL_ptr_table, SvRV(value));
            frozen_callback = frozen_cv ? newRV_inc(frozen_cv) : NULL;
        }
    }
    PERL_SET_CONTEXT(owner);

    if (frozen_callback == NULL) {
        go_destroy_interpreter(frozen);
        PERL_SET_CONTEXT(owner);
        croak("could not clone CODE reference into shared callback store");
    }

    state = (shared_code_state *)calloc(1, sizeof(*state));
    if (state == NULL) {
        PERL_SET_CONTEXT(frozen);
        {
            dTHXa(frozen);
            SvREFCNT_dec(frozen_callback);
        }
        go_destroy_interpreter(frozen);
        PERL_SET_CONTEXT(owner);
        croak("out of memory allocating shared callback state");
    }

    state->interp = frozen;
    state->callback = frozen_callback;
    if (go_mutex_init_recursive(&state->mutex) != 0)
        croak("could not initialize shared state mutex");

    shared_node_clear(n);
    n->type = SHARED_CODE;
    n->code = state;
}

/* Return an existing shared graph node when VALUE is one of our Perl proxies. */
static shared_node *
shared_proxy_node_from_sv(pTHX_ SV *value)
{
    dSP;
    I32 count;
    SV *ret;
    UV ptr = 0;

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(value);
    PUTBACK;
    count = call_pv("Developer::Dashboard::GoRoutine::_proxy_ptr", G_SCALAR | G_EVAL);
    SPAGAIN;
    if (!SvTRUE(ERRSV) && count == 1) {
        ret = POPs;
        if (SvOK(ret)) ptr = SvUV(ret);
    }
    else if (SvTRUE(ERRSV)) {
        sv_setsv(ERRSV, &PL_sv_undef);
    }
    PUTBACK;
    FREETMPS;
    LEAVE;

    return ptr ? shared_from_uv(ptr) : NULL;
}

/* Build a Perl value suitable for a callback argument/result in THIS interpreter. */
static SV *
shared_value_for_call(pTHX_ shared_node *n)
{
    if (n == NULL) return newSV(0);

    if (n->type == SHARED_UNDEF || n->type == SHARED_IV ||
        n->type == SHARED_NV || n->type == SHARED_PV) {
        return shared_copy_scalar(aTHX_ n);
    }
    else {
        dSP;
        I32 count;
        SV *ret;

        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        XPUSHs(sv_2mortal(newSVuv(PTR2UV(n))));
        PUTBACK;
        count = call_pv("Developer::Dashboard::GoRoutine::_value_for_ptr", G_SCALAR | G_EVAL);
        SPAGAIN;
        if (SvTRUE(ERRSV)) {
            STRLEN len = 0;
            const char *msg = SvPV(ERRSV, len);
            SV *err = newSVpvn(msg, len);
            sv_setsv(ERRSV, &PL_sv_undef);
            PUTBACK;
            FREETMPS;
            LEAVE;
            croak_sv(err);
        }
        if (count != 1) {
            PUTBACK;
            FREETMPS;
            LEAVE;
            croak("could not materialize shared callback value");
        }
        ret = POPs;
        SvREFCNT_inc(ret);
        PUTBACK;
        FREETMPS;
        LEAVE;
        return ret;
    }
}

/*
 * Invoke a shared callback in its private interpreter.  Arguments/results are
 * marshalled through the same C-backed shared graph used by share().
 */
static void
shared_code_invoke(shared_code_state *state,
                   I32 gimme,
                   shared_node **args,
                   I32 argc,
                   shared_node ***out_nodes,
                   I32 *out_count,
                   char **out_error)
{
    PerlInterpreter *cb_interp = state->interp;
    I32 i;

    *out_nodes = NULL;
    *out_count = 0;
    *out_error = NULL;

    go_mutex_lock(&state->mutex);
    PERL_SET_CONTEXT(cb_interp);
    {
        dTHXa(cb_interp);
        dSP;
        I32 count;
        go_control local_ctl;
        go_control *old_ctl;

        memset(&local_ctl, 0, sizeof(local_ctl));
        go_mutex_init(&local_ctl.mutex);
        go_cond_init(&local_ctl.cond);
        local_ctl.state = GO_STATE_RUNNING;

        go_once(&go_tls_once, go_tls_init_once);
        old_ctl = (go_control *)go_tls_get(go_tls_key);
        /* Preserve the caller go-routine control when there is one so a
         * kill()/timeout() can cancel a long-running shared callback too.
         * Main-thread callback calls use the local control solely to make
         * Perl exit() local to the callback instead of process-wide. */
        go_tls_set(go_tls_key, old_ctl ? old_ctl : &local_ctl);
        PL_runops = go_runops;

        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        for (i = 0; i < argc; ++i) {
            SV *arg = shared_value_for_call(aTHX_ args[i]);
            XPUSHs(sv_2mortal(arg));
        }
        PUTBACK;

        count = call_sv(state->callback,
                        (gimme == G_ARRAY ? G_ARRAY :
                         gimme == G_VOID  ? G_VOID  : G_SCALAR) | G_EVAL);
        SPAGAIN;

        if (SvTRUE(ERRSV)) {
            STRLEN len = 0;
            const char *msg = SvPV(ERRSV, len);
            *out_error = (char *)malloc(len + 1);
            if (*out_error != NULL) {
                memcpy(*out_error, msg, len);
                (*out_error)[len] = '\0';
            }
            sv_setsv(ERRSV, &PL_sv_undef);
        }
        else if (gimme != G_VOID && count > 0) {
            shared_node **nodes = (shared_node **)calloc((size_t)count, sizeof(*nodes));
            if (nodes == NULL) {
                *out_error = go_strdup("out of memory storing shared callback return values");
            }
            else {
                /* POPs is reverse order, so fill from the end. */
                for (i = count - 1; i >= 0; --i) {
                    SV *ret = POPs;
                    shared_node *existing = shared_proxy_node_from_sv(aTHX_ ret);
                    if (existing != NULL) {
                        nodes[i] = existing;
                    }
                    else {
                        import_map map;
                        memset(&map, 0, sizeof(map));
                        shared_lock();
                        nodes[i] = shared_import_value(aTHX_ ret, &map, NULL);
                        shared_unlock();
                        free((void *)map.source);
                        free(map.node);
                    }
                }
                *out_nodes = nodes;
                *out_count = count;
            }
        }

        PUTBACK;
        FREETMPS;
        LEAVE;

        go_tls_set(go_tls_key, old_ctl);
        go_cond_destroy(&local_ctl.cond);
        go_mutex_destroy(&local_ctl.mutex);
    }
    go_mutex_unlock(&state->mutex);
}

static void
shared_handle_invoke(shared_handle_state *state,
                     const char *op,
                     I32 gimme,
                     shared_node **args,
                     I32 argc,
                     shared_node ***out_nodes,
                     I32 *out_count,
                     char **out_error)
{
    PerlInterpreter *hi = state->interp;
    I32 i;

    *out_nodes = NULL;
    *out_count = 0;
    *out_error = NULL;

    go_mutex_lock(&state->mutex);
    PERL_SET_CONTEXT(hi);
    {
        dTHXa(hi);
        dSP;
        I32 count;
        go_control local_ctl;
        go_control *old_ctl;

        memset(&local_ctl, 0, sizeof(local_ctl));
        go_mutex_init(&local_ctl.mutex);
        go_cond_init(&local_ctl.cond);
        local_ctl.state = GO_STATE_RUNNING;

        go_once(&go_tls_once, go_tls_init_once);
        old_ctl = (go_control *)go_tls_get(go_tls_key);
        go_tls_set(go_tls_key, old_ctl ? old_ctl : &local_ctl);
        PL_runops = go_runops;

        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        XPUSHs(state->handle);
        XPUSHs(sv_2mortal(newSVpv(op, 0)));
        for (i = 0; i < argc; ++i) {
            SV *arg = shared_value_for_call(aTHX_ args[i]);
            XPUSHs(sv_2mortal(arg));
        }
        PUTBACK;

        count = call_pv("Developer::Dashboard::GoRoutine::_handle_remote_dispatch",
                        (gimme == G_ARRAY ? G_ARRAY :
                         gimme == G_VOID  ? G_VOID  : G_SCALAR) | G_EVAL);
        SPAGAIN;

        if (SvTRUE(ERRSV)) {
            STRLEN len = 0;
            const char *msg = SvPV(ERRSV, len);
            *out_error = (char *)malloc(len + 1);
            if (*out_error != NULL) {
                memcpy(*out_error, msg, len);
                (*out_error)[len] = '\0';
            }
            sv_setsv(ERRSV, &PL_sv_undef);
        }
        else if (gimme != G_VOID && count > 0) {
            shared_node **nodes = (shared_node **)calloc((size_t)count, sizeof(*nodes));
            if (nodes == NULL) {
                *out_error = go_strdup("out of memory storing shared filehandle return values");
            }
            else {
                for (i = count - 1; i >= 0; --i) {
                    SV *ret = POPs;
                    shared_node *existing = shared_proxy_node_from_sv(aTHX_ ret);
                    if (existing != NULL) {
                        nodes[i] = existing;
                    }
                    else {
                        import_map map;
                        memset(&map, 0, sizeof(map));
                        shared_lock();
                        nodes[i] = shared_import_value(aTHX_ ret, &map, NULL);
                        shared_unlock();
                        free((void *)map.source);
                        free(map.node);
                    }
                }
                *out_nodes = nodes;
                *out_count = count;
            }
        }

        PUTBACK;
        FREETMPS;
        LEAVE;
        go_tls_set(go_tls_key, old_ctl);
        go_cond_destroy(&local_ctl.cond);
        go_mutex_destroy(&local_ctl.mutex);
    }
    go_mutex_unlock(&state->mutex);
}

static void
shared_import_scalar(pTHX_ shared_node *n, SV *value)
{
    STRLEN len;
    const char *pv;
    U8 is_utf8;

    is_utf8 = (U8)SvUTF8(value);
    SvGETMAGIC(value);
    shared_node_clear(n);

    if (!SvOK(value)) {
        return;
    }
    if (SvIOK(value) && !SvNOK(value) && !SvPOK(value)) {
        n->type = SHARED_IV;
        n->iv = SvIV(value);
        return;
    }
    if (SvNOK(value) && !SvPOK(value)) {
        n->type = SHARED_NV;
        n->nv = SvNV(value);
        return;
    }

    pv = SvPV(value, len);
    n->pv = (char *)malloc(len + 1);
    if (n->pv == NULL) {
        croak("out of memory storing shared string");
    }
    memcpy(n->pv, pv, len);
    n->pv[len] = '\0';
    n->pv_len = len;
    n->pv_utf8 = is_utf8;
    n->type = SHARED_PV;
}

static shared_node *
shared_import_value(pTHX_ SV *value, import_map *map, shared_node *preferred)
{
    shared_node *n = preferred ? preferred : shared_node_new();

    if (!SvROK(value)) {
        shared_import_scalar(aTHX_ n, value);
        return n;
    }
    else {
        SV *rv = SvRV(value);
        shared_node *existing = import_map_find(map, (const void *)rv);
        const char *class_name;

        if (existing != NULL) {
            return existing;
        }

        shared_node_clear(n);
        class_name = shared_sv_class(value);

        if (SvTYPE(rv) == SVt_PVCV) {
            import_map_add(map, (const void *)rv, n);
            shared_import_code(aTHX_ n, value);
            return n;
        }
        else if (SvTYPE(rv) == SVt_PVGV) {
            import_map_add(map, (const void *)rv, n);
            shared_import_glob(aTHX_ n, value, map);
            return n;
        }
        else if (SvTYPE(rv) == SVt_REGEXP) {
            import_map_add(map, (const void *)rv, n);
            shared_import_regexp(aTHX_ n, value);
            return n;
        }
        else if (SvTYPE(rv) == SVt_PVIO) {
            import_map_add(map, (const void *)rv, n);
            shared_import_io(aTHX_ n, value);
            return n;
        }
        else if (SvTYPE(rv) == SVt_PVFM) {
            import_map_add(map, (const void *)rv, n);
            shared_import_format(aTHX_ n, value);
            return n;
        }
        else if (SvTYPE(rv) == SVt_PVHV) {
            HV *hv = (HV *)rv;
            HE *he;
            import_map_add(map, (const void *)rv, n);
            n->type = SHARED_HASH;
            shared_set_class(n, class_name);

            hv_iterinit(hv);
            while ((he = hv_iternext(hv)) != NULL) {
                SV *keysv = hv_iterkeysv(he);
                SV *valsv = hv_iterval(hv, he);
                STRLEN klen = 0;
                const char *k = SvPV(keysv, klen);
                shared_node *child;
                shared_hash_reserve(n, n->hash_count + 1);
                n->hash_entries[n->hash_count].key = (char *)malloc(klen + 1);
                if (n->hash_entries[n->hash_count].key == NULL) {
                    croak("out of memory storing shared hash key");
                }
                memcpy(n->hash_entries[n->hash_count].key, k, klen);
                n->hash_entries[n->hash_count].key[klen] = '\0';
                n->hash_entries[n->hash_count].key_len = klen;
                child = shared_import_value(aTHX_ valsv, map, NULL);
                n->hash_entries[n->hash_count].value = child;
                ++n->hash_count;
            }
            return n;
        }
        else if (SvTYPE(rv) == SVt_PVAV) {
            AV *av = (AV *)rv;
            SSize_t last = av_len(av);
            SSize_t i;
            import_map_add(map, (const void *)rv, n);
            n->type = SHARED_ARRAY;
            shared_set_class(n, class_name);
            if (last >= 0) {
                shared_array_reserve(n, (size_t)last + 1);
                n->array_size = (size_t)last + 1;
                for (i = 0; i <= last; ++i) {
                    SV **svp = av_fetch(av, i, 0);
                    if (svp != NULL) {
                        n->array_items[i] = shared_import_value(aTHX_ *svp, map, NULL);
                    }
                }
            }
            return n;
        }
#if PERL_VERSION >= 40
        else if (SvTYPE(rv) == SVt_PVOBJ) {
            SSize_t max = ObjectMAXFIELD(rv);
            SSize_t i;
            import_map_add(map, (const void *)rv, n);
            n->type = SHARED_OBJECT;
            shared_set_class(n, class_name);
            if (max >= 0) {
                shared_array_reserve(n, (size_t)max + 1);
                n->array_size = (size_t)max + 1;
                for (i = 0; i <= max; ++i) {
                    SV *field = ObjectFIELDS(rv)[i];
                    if (field != NULL) {
                        n->array_items[i] = shared_import_value(aTHX_ field, map, NULL);
                    }
                }
            }
            return n;
        }
#endif
        else if (SvTYPE(rv) < SVt_PVAV) {
            import_map_add(map, (const void *)rv, n);
            n->type = SHARED_SCALARREF;
            shared_set_class(n, class_name);
            n->scalarref_value = shared_import_value(aTHX_ rv, map, NULL);
            return n;
        }

        croak("share() does not support reference type %s%s%s",
              sv_reftype(rv, 0),
              class_name ? " for object " : "",
              class_name ? class_name : "");
    }

    return n;
}

static void
shared_import_into(pTHX_ shared_node *dest, SV *value)
{
    import_map map;
    memset(&map, 0, sizeof(map));
    (void)shared_import_value(aTHX_ value, &map, dest);
    free((void *)map.source);
    free(map.node);
}

static SV *
shared_copy_scalar(pTHX_ const shared_node *n)
{
    switch (n->type) {
        case SHARED_IV: return newSViv(n->iv);
        case SHARED_NV: return newSVnv(n->nv);
        case SHARED_PV: {
            SV *copy = newSVpvn(n->pv ? n->pv : "", n->pv_len);
            if (n->pv_utf8) SvUTF8_on(copy);
            return copy;
        }
        case SHARED_UNDEF: return newSV(0);
        default:
            croak("shared value is a reference/container, not a scalar");
    }
    return newSV(0);
}

static NV
shared_as_nv(pTHX_ const shared_node *n)
{
    NV out;
    SV *tmp = shared_copy_scalar(aTHX_ n);
    out = SvNV(tmp);
    SvREFCNT_dec(tmp);
    return out;
}

static IV
shared_as_iv(pTHX_ const shared_node *n)
{
    IV out;
    SV *tmp = shared_copy_scalar(aTHX_ n);
    out = SvIV(tmp);
    SvREFCNT_dec(tmp);
    return out;
}

static void
shared_store_iv(shared_node *n, IV v)
{
    shared_node_clear(n);
    n->type = SHARED_IV;
    n->iv = v;
}

static void
shared_store_nv(shared_node *n, NV v)
{
    shared_node_clear(n);
    n->type = SHARED_NV;
    n->nv = v;
}

static void
shared_concat(pTHX_ shared_node *n, SV *arg, int reverse)
{
    SV *left = shared_copy_scalar(aTHX_ n);
    STRLEN llen = 0, rlen = 0;
    U8 result_utf8;
    const char *lp = SvPV(left, llen);
    const char *rp = SvPV(arg, rlen);
    result_utf8 = (U8)(SvUTF8(left) || SvUTF8(arg));
    STRLEN total = llen + rlen;
    char *buf = (char *)malloc(total + 1);
    if (buf == NULL) {
        SvREFCNT_dec(left);
        croak("out of memory concatenating shared scalar");
    }
    if (reverse) {
        memcpy(buf, rp, rlen);
        memcpy(buf + rlen, lp, llen);
    } else {
        memcpy(buf, lp, llen);
        memcpy(buf + llen, rp, rlen);
    }
    buf[total] = '\0';
    shared_node_clear(n);
    n->type = SHARED_PV;
    n->pv = buf;
    n->pv_len = total;
    n->pv_utf8 = result_utf8;
    SvREFCNT_dec(left);
}

static void
shared_apply(pTHX_ shared_node *n, const char *op, SV *arg, int reverse)
{
    NV left_nv, right_nv, out_nv;
    IV left_iv, right_iv;

    if (n->type >= SHARED_HASH) {
        croak("numeric/string operation attempted on shared reference");
    }

    if (strEQ(op, "inc")) {
        if (n->type == SHARED_IV) ++n->iv;
        else shared_store_nv(n, shared_as_nv(aTHX_ n) + 1.0);
    }
    else if (strEQ(op, "dec")) {
        if (n->type == SHARED_IV) --n->iv;
        else shared_store_nv(n, shared_as_nv(aTHX_ n) - 1.0);
    }
    else if (strEQ(op, "concat")) {
        shared_concat(aTHX_ n, arg, reverse);
    }
    else if (strEQ(op, "mod")) {
        left_iv = shared_as_iv(aTHX_ n);
        right_iv = SvIV(arg);
        if ((!reverse && right_iv == 0) || (reverse && left_iv == 0)) {
            croak("Illegal modulus zero");
        }
        shared_store_iv(n, reverse ? right_iv % left_iv : left_iv % right_iv);
    }
    else {
        left_nv = shared_as_nv(aTHX_ n);
        right_nv = SvNV(arg);
        if (strEQ(op, "add")) out_nv = reverse ? right_nv + left_nv : left_nv + right_nv;
        else if (strEQ(op, "sub")) out_nv = reverse ? right_nv - left_nv : left_nv - right_nv;
        else if (strEQ(op, "mul")) out_nv = reverse ? right_nv * left_nv : left_nv * right_nv;
        else if (strEQ(op, "div")) {
            if ((!reverse && right_nv == 0.0) || (reverse && left_nv == 0.0)) {
                croak("Illegal division by zero");
            }
            out_nv = reverse ? right_nv / left_nv : left_nv / right_nv;
        }
        else croak("unknown shared scalar operation '%s'", op);

        if (!strEQ(op, "div") && n->type == SHARED_IV
            && SvIOK(arg) && !SvNOK(arg) && !SvPOK(arg)) {
            shared_store_iv(n, (IV)out_nv);
        } else {
            shared_store_nv(n, out_nv);
        }
    }
}

static SSize_t
shared_hash_find(shared_node *n, const char *key, STRLEN key_len)
{
    size_t i;
    if (n->type != SHARED_HASH) croak("shared value is not a hash");
    for (i = 0; i < n->hash_count; ++i) {
        if (n->hash_entries[i].key_len == key_len
            && memcmp(n->hash_entries[i].key, key, key_len) == 0) {
            return (SSize_t)i;
        }
    }
    return -1;
}

static shared_node *
shared_hash_get_node(shared_node *n, const char *key, STRLEN key_len)
{
    SSize_t idx = shared_hash_find(n, key, key_len);
    return idx >= 0 ? n->hash_entries[idx].value : NULL;
}

static shared_node *
shared_hash_ensure_node(shared_node *n, const char *key, STRLEN key_len)
{
    SSize_t idx = shared_hash_find(n, key, key_len);
    shared_hash_entry *e;
    if (idx >= 0) return n->hash_entries[idx].value;
    shared_hash_reserve(n, n->hash_count + 1);
    e = &n->hash_entries[n->hash_count++];
    e->key = (char *)malloc(key_len + 1);
    if (e->key == NULL) croak("out of memory storing shared hash key");
    memcpy(e->key, key, key_len);
    e->key[key_len] = '\0';
    e->key_len = key_len;
    e->value = shared_node_new();
    return e->value;
}


/* Build a real Perl 5.40+ class instance with each field tied to a shared node. */
static SV *
shared_object_proxy(pTHX_ shared_node *n)
{
#if PERL_VERSION >= 40
    SV *obj;
    HV *stash;
    size_t i;

    if (n->type != SHARED_OBJECT)
        croak("shared value is not a class object");
    if (n->class_name == NULL || *n->class_name == '\0')
        croak("shared class object has no class name");

    stash = gv_stashpv(n->class_name, GV_ADD);
    obj = newSV_type(SVt_PVOBJ);

    if (n->array_size > 0) {
        ObjectMAXFIELD(obj) = (SSize_t)n->array_size - 1;
        Newxz(ObjectFIELDS(obj), n->array_size, SV *);

        for (i = 0; i < n->array_size; ++i) {
            dSP;
            I32 count;
            SV *field_ref;
            SV *field_sv;
            UV child_ptr;

            if (n->array_items[i] == NULL)
                n->array_items[i] = shared_node_new();
            child_ptr = PTR2UV(n->array_items[i]);

            ENTER;
            SAVETMPS;
            PUSHMARK(SP);
            XPUSHs(sv_2mortal(newSVuv(child_ptr)));
            PUTBACK;
            count = call_pv("Developer::Dashboard::GoRoutine::_field_ref_for_ptr", G_SCALAR);
            SPAGAIN;
            if (count != 1) {
                PUTBACK; FREETMPS; LEAVE;
                croak("failed to create shared class field proxy");
            }
            field_ref = POPs;
            if (!SvROK(field_ref)) {
                PUTBACK; FREETMPS; LEAVE;
                croak("shared class field helper did not return a reference");
            }
            field_sv = SvRV(field_ref);
            SvREFCNT_inc(field_sv);
            ObjectFIELDS(obj)[i] = field_sv;
            PUTBACK;
            FREETMPS;
            LEAVE;
        }
    }

    SvSTASH_set(obj, (HV *)SvREFCNT_inc((SV *)stash));
    SvOBJECT_on(obj);
    return newRV_noinc(obj);
#else
    PERL_UNUSED_ARG(n);
    croak("shared Perl class objects require Perl 5.40 or newer");
    return &PL_sv_undef;
#endif
}

static go_channel *
go_channel_from_uv(UV ptr)
{
    go_channel *ch = INT2PTR(go_channel *, ptr);
    if (ch == NULL) croak("invalid channel handle");
    return ch;
}

static SV *
go_channel_handle_new(pTHX_ go_channel *ch)
{
    HV *hv = newHV();
    SV *rv;
    hv_store(hv, "ptr", 3, newSVuv(PTR2UV(ch)), 0);
    rv = newRV_noinc((SV *)hv);
    sv_bless(rv, gv_stashpv("Developer::Dashboard::GoRoutine::Channel", GV_ADD));
    return rv;
}

static int
go_channel_current_cancelled(void)
{
    go_control *ctl;
    go_once(&go_tls_once, go_tls_init_once);
    ctl = (go_control *)go_tls_get(go_tls_key);
    return ctl ? go_control_cancel_requested(ctl) : 0;
}

/*
 * go_cond_wait() is not guaranteed to return when our cancellation
 * signal is delivered.  Use short timed waits so kill()/timeout() also wake
 * routines blocked inside channel send/receive rather than only at Perl op
 * boundaries.
 */
static int
go_channel_wait_interruptible(go_cond_t *cond, go_mutex_t *mutex)
{
    (void)go_cond_wait_ms(cond, mutex, 50UL);
    return go_channel_current_cancelled() ? 0 : 1;
}

static shared_node *
go_channel_import_value(pTHX_ SV *value)
{
    shared_node *node = shared_proxy_node_from_sv(aTHX_ value);

    if (node == NULL) {
        import_map map;
        memset(&map, 0, sizeof(map));
        shared_lock();
        node = shared_import_value(aTHX_ value, &map, NULL);
        shared_unlock();
        free((void *)map.source);
        free(map.node);
    }

    return node;
}
