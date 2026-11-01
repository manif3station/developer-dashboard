#ifndef DEVELOPER_DASHBOARD_GOROUTINE_NATIVE_H
#define DEVELOPER_DASHBOARD_GOROUTINE_NATIVE_H

#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <limits.h>
#include <time.h>

#ifdef _WIN32
#  include <windows.h>
#  include <io.h>
#  include <fcntl.h>
typedef SRWLOCK dd_mutex_t;
typedef CONDITION_VARIABLE dd_cond_t;
typedef HANDLE dd_thread_t;
#  define DD_MUTEX_INITIALIZER SRWLOCK_INIT
#  define DD_COND_INITIALIZER CONDITION_VARIABLE_INIT
static int dd_mutex_init(dd_mutex_t *mutex) { InitializeSRWLock(mutex); return 0; }
static int dd_mutex_lock(dd_mutex_t *mutex) { AcquireSRWLockExclusive(mutex); return 0; }
static int dd_mutex_unlock(dd_mutex_t *mutex) { ReleaseSRWLockExclusive(mutex); return 0; }
static int dd_cond_wait(dd_cond_t *cond, dd_mutex_t *mutex) {
    return SleepConditionVariableSRW(cond, mutex, INFINITE, 0) ? 0 : (int)GetLastError();
}
static int dd_cond_broadcast(dd_cond_t *cond) { WakeAllConditionVariable(cond); return 0; }
static int dd_thread_create(dd_thread_t *thread, LPTHREAD_START_ROUTINE worker, void *arg) {
    *thread = CreateThread(NULL, 0, worker, arg, 0, NULL);
    return *thread ? 0 : (int)GetLastError();
}
static int dd_thread_detach(dd_thread_t thread) { return CloseHandle(thread) ? 0 : (int)GetLastError(); }
#  define DD_WORKER_RETURN DWORD WINAPI
#  define DD_WORKER_DONE return 0
static int dd_cond_init(dd_cond_t *cond) { InitializeConditionVariable(cond); return 0; }
static int dd_mutex_destroy(dd_mutex_t *mutex) { (void)mutex; return 0; }
static int dd_cond_destroy(dd_cond_t *cond) { (void)cond; return 0; }
static int dd_cond_timedwait_ms(dd_cond_t *cond, dd_mutex_t *mutex, unsigned long ms) {
    if (SleepConditionVariableSRW(cond, mutex, (DWORD)ms, 0)) return 0;
    return (int)GetLastError();
}
static int dd_worker_wake(dd_thread_t thread, unsigned long thread_id) {
    (void)thread;
    return PostThreadMessage((DWORD)thread_id, WM_NULL, 0, 0) ? 0 : (int)GetLastError();
}
static int dd_thread_release(dd_thread_t thread) {
    return thread && !CloseHandle(thread) ? (int)GetLastError() : 0;
}
#  define DD_TIMEOUT_RESULT ERROR_TIMEOUT
#  define DD_THREAD_NULL NULL
#else
#  include <pthread.h>
#  include <spawn.h>
#  include <sys/types.h>
#  include <sys/wait.h>
#  include <signal.h>
#  include <errno.h>
#  include <fcntl.h>
#  include <unistd.h>
#  include <stdio.h>
#  include <limits.h>
typedef pthread_mutex_t dd_mutex_t;
typedef pthread_cond_t dd_cond_t;
typedef pthread_t dd_thread_t;
#  define DD_MUTEX_INITIALIZER PTHREAD_MUTEX_INITIALIZER
#  define DD_COND_INITIALIZER PTHREAD_COND_INITIALIZER
static int dd_mutex_init(dd_mutex_t *mutex) { return pthread_mutex_init(mutex, NULL); }
static int dd_mutex_lock(dd_mutex_t *mutex) { return pthread_mutex_lock(mutex); }
static int dd_mutex_unlock(dd_mutex_t *mutex) { return pthread_mutex_unlock(mutex); }
static int dd_cond_wait(dd_cond_t *cond, dd_mutex_t *mutex) { return pthread_cond_wait(cond, mutex); }
static int dd_cond_broadcast(dd_cond_t *cond) { return pthread_cond_broadcast(cond); }
static int dd_thread_create(dd_thread_t *thread, void *(*worker)(void *), void *arg) {
    return pthread_create(thread, NULL, worker, arg);
}
static int dd_thread_detach(dd_thread_t thread) { return pthread_detach(thread); }
#  define DD_WORKER_RETURN void *
#  define DD_WORKER_DONE return NULL
static int dd_cond_init(dd_cond_t *cond) { return pthread_cond_init(cond, NULL); }
static int dd_mutex_destroy(dd_mutex_t *mutex) { return pthread_mutex_destroy(mutex); }
static int dd_cond_destroy(dd_cond_t *cond) { return pthread_cond_destroy(cond); }
static int dd_cond_timedwait_ms(dd_cond_t *cond, dd_mutex_t *mutex, unsigned long ms) {
    struct timespec deadline;
    unsigned long long nsec;
    if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) return errno;
    nsec = (unsigned long long)deadline.tv_nsec + (unsigned long long)ms * 1000000ULL;
    deadline.tv_sec += (time_t)(nsec / 1000000000ULL);
    deadline.tv_nsec = (long)(nsec % 1000000000ULL);
    return pthread_cond_timedwait(cond, mutex, &deadline);
}
static int dd_worker_wake(dd_thread_t thread, unsigned long thread_id) {
    (void)thread_id;
    return pthread_kill(thread, SIGURG);
}
static int dd_thread_release(dd_thread_t thread) { (void)thread; return 0; }
#  define DD_TIMEOUT_RESULT ETIMEDOUT
#  define DD_THREAD_NULL ((pthread_t)0)
#endif

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
    dd_mutex_t mutex;
    dd_cond_t cond;
    dd_thread_t thread;
    unsigned long thread_id;
    PerlInterpreter *owner;
    unsigned long refs;
    unsigned long timeout_generation;
    double started_at;
    double finished_at;
    double timeout_seconds;
    go_state state;
    go_cancel_reason cancel_reason;
    int thread_valid;
    int worker_ready;
    int cancel_requested;
    int exit_requested;
    int wake_error;
} go_control;

typedef struct { PerlInterpreter *interp; SV *callback; go_control *control; } go_job;
typedef struct { go_control *control; unsigned long generation; double deadline; } go_timeout_job;
typedef enum { SHARED_UNDEF = 0, SHARED_IV, SHARED_NV, SHARED_PV } shared_type;

/*
 * Select clone flags for a worker interpreter.
 * Input: none; uses the platform compile target and Perl clone constants.
 * Output: flags retaining the pointer map, plus host-clone semantics on
 * Windows Perl builds that provide CLONEf_CLONE_HOST.
 */
static UV go_clone_flags(void) {
    UV flags = CLONEf_KEEP_PTR_TABLE;
#ifdef _WIN32
#  ifdef CLONEf_CLONE_HOST
    flags |= CLONEf_CLONE_HOST;
#  endif
#endif
    return flags;
}

typedef struct {
    dd_mutex_t mutex;
    shared_type type;
    IV iv;
    NV nv;
    char *pv;
    STRLEN pv_len;
} shared_scalar;

static dd_mutex_t go_count_mutex = DD_MUTEX_INITIALIZER;
static dd_cond_t go_count_cond = DD_COND_INITIALIZER;
static unsigned long go_active = 0;

static void go_active_inc(void) {
    dd_mutex_lock(&go_count_mutex);
    ++go_active;
    dd_mutex_unlock(&go_count_mutex);
}

static void go_active_dec(void) {
    dd_mutex_lock(&go_count_mutex);
    if (go_active > 0) --go_active;
    dd_cond_broadcast(&go_count_cond);
    dd_mutex_unlock(&go_count_mutex);
}

static void go_wait_all_internal(void) {
    dd_mutex_lock(&go_count_mutex);
    while (go_active != 0) dd_cond_wait(&go_count_cond, &go_count_mutex);
    dd_mutex_unlock(&go_count_mutex);
}

static void go_root_atexit(pTHX_ void *owner_ptr) {
    PerlInterpreter *owner = (PerlInterpreter *)owner_ptr;
    if (aTHX != owner) return;
    go_wait_all_internal();
}

static void go_destroy_interpreter(PerlInterpreter *interp) {
    PERL_SET_CONTEXT(interp);
    {
        dTHXa(interp);
        PL_exit_flags &= ~PERL_EXIT_DESTRUCT_END;
    }
    perl_destruct(interp);
    perl_free(interp);
}

static double go_monotonic_seconds(void) {
#ifdef _WIN32
    return (double)GetTickCount64() / 1000.0;
#else
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0.0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
#endif
}

#ifdef _WIN32
static INIT_ONCE go_tls_once = INIT_ONCE_STATIC_INIT;
static DWORD go_tls_key = TLS_OUT_OF_INDEXES;
static BOOL CALLBACK go_tls_init_once(PINIT_ONCE once, PVOID param, PVOID *context) {
    (void)once; (void)param; (void)context;
    go_tls_key = TlsAlloc();
    return go_tls_key != TLS_OUT_OF_INDEXES;
}
static int go_tls_set(go_control *control) {
    if (!InitOnceExecuteOnce(&go_tls_once, go_tls_init_once, NULL, NULL))
        return (int)GetLastError();
    return TlsSetValue(go_tls_key, control) ? 0 : (int)GetLastError();
}
static go_control *go_tls_get(void) {
    if (!InitOnceExecuteOnce(&go_tls_once, go_tls_init_once, NULL, NULL)) return NULL;
    return (go_control *)TlsGetValue(go_tls_key);
}
#else
static pthread_once_t go_tls_once = PTHREAD_ONCE_INIT;
static pthread_key_t go_tls_key;
static int go_tls_error = 0;
static void go_tls_init_once(void) {
    go_tls_error = pthread_key_create(&go_tls_key, NULL);
}
static int go_tls_set(go_control *control) {
    pthread_once(&go_tls_once, go_tls_init_once);
    if (go_tls_error != 0) return go_tls_error;
    return pthread_setspecific(go_tls_key, control);
}
static go_control *go_tls_get(void) {
    pthread_once(&go_tls_once, go_tls_init_once);
    return go_tls_error == 0 ? (go_control *)pthread_getspecific(go_tls_key) : NULL;
}
#endif

#ifndef _WIN32
static pthread_once_t go_signal_once = PTHREAD_ONCE_INIT;
static int go_signal_error = 0;
static int go_signal_enabled = 0;
static void go_wake_signal_handler(int signo) { (void)signo; }
static void go_signal_init_once(void) {
    struct sigaction previous_action;
    struct sigaction action;
    if (sigaction(SIGURG, NULL, &previous_action) != 0) {
        go_signal_error = errno;
        return;
    }
    if (previous_action.sa_handler != SIG_DFL) return;
    memset(&action, 0, sizeof(action));
    action.sa_handler = go_wake_signal_handler;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGURG, &action, NULL) != 0) {
        go_signal_error = errno;
        return;
    }
    go_signal_enabled = 1;
}
#endif

static double go_control_age_locked(go_control *control) {
    double end = control->state == GO_STATE_RUNNING
        ? go_monotonic_seconds() : control->finished_at;
    double age = end - control->started_at;
    return age > 0.0 ? age : 0.0;
}

static void go_control_free(go_control *control) {
    if (control == NULL) return;
    dd_cond_destroy(&control->cond);
    dd_mutex_destroy(&control->mutex);
    free(control);
}

static void go_control_retain(go_control *control) {
    dd_mutex_lock(&control->mutex);
    ++control->refs;
    dd_mutex_unlock(&control->mutex);
}

static void go_control_release(go_control *control) {
    int release;
    dd_mutex_lock(&control->mutex);
    release = control->refs > 0 && --control->refs == 0;
    dd_mutex_unlock(&control->mutex);
    if (release) go_control_free(control);
}

static go_control *go_control_new(pTHX) {
    go_control *control = (go_control *)calloc(1, sizeof(*control));
    int rc;
    if (control == NULL) croak("out of memory allocating GoRoutine control");
    rc = dd_mutex_init(&control->mutex);
    if (rc != 0) { free(control); croak("native mutex initialization failed: %d", rc); }
    rc = dd_cond_init(&control->cond);
    if (rc != 0) {
        dd_mutex_destroy(&control->mutex);
        free(control);
        croak("native condition initialization failed: %d", rc);
    }
    control->owner = aTHX;
    control->refs = 1; /* worker reference */
    control->state = GO_STATE_RUNNING;
    control->cancel_reason = GO_CANCEL_NONE;
    control->started_at = go_monotonic_seconds();
    control->thread = DD_THREAD_NULL;
    return control;
}

static int go_control_is_running(go_control *control) {
    int running;
    dd_mutex_lock(&control->mutex);
    running = control->state == GO_STATE_RUNNING;
    dd_mutex_unlock(&control->mutex);
    return running;
}

static int go_control_cancel_requested(go_control *control) {
    int requested;
    dd_mutex_lock(&control->mutex);
    requested = control->cancel_requested;
    dd_mutex_unlock(&control->mutex);
    return requested;
}

static int go_control_exit_requested(go_control *control) {
    int requested;
    dd_mutex_lock(&control->mutex);
    requested = control->exit_requested;
    dd_mutex_unlock(&control->mutex);
    return requested;
}

static void go_control_request_exit(go_control *control) {
    dd_mutex_lock(&control->mutex);
    control->exit_requested = 1;
    dd_mutex_unlock(&control->mutex);
}

static int go_control_request_cancel(go_control *control, go_cancel_reason reason) {
    dd_thread_t thread = DD_THREAD_NULL;
    unsigned long thread_id = 0;
    int valid = 0;
    int requested = 0;
    int rc = 0;
    dd_mutex_lock(&control->mutex);
    if (control->state == GO_STATE_RUNNING && !control->cancel_requested) {
        control->cancel_requested = 1;
        control->cancel_reason = reason;
        thread = control->thread;
        thread_id = control->thread_id;
        valid = control->thread_valid;
        requested = 1;
        dd_cond_broadcast(&control->cond);
    }
    dd_mutex_unlock(&control->mutex);
#ifndef _WIN32
    if (requested && valid) {
        pthread_once(&go_signal_once, go_signal_init_once);
        if (go_signal_error != 0) rc = go_signal_error;
        else if (go_signal_enabled) {
            rc = dd_worker_wake(thread, thread_id);
            if (rc == ESRCH) rc = 0;
        }
    }
#else
    if (requested && valid) rc = dd_worker_wake(thread, thread_id);
#endif
    if (rc != 0) {
        dd_mutex_lock(&control->mutex);
        control->wake_error = rc;
        dd_mutex_unlock(&control->mutex);
        croak("unable to wake GoRoutine worker: %d", rc);
    }
    return requested;
}

static void go_control_finish(go_control *control, go_state state) {
    dd_mutex_lock(&control->mutex);
    if (control->wake_error != 0) state = GO_STATE_FAILED;
    else if (control->cancel_requested) {
        state = control->cancel_reason == GO_CANCEL_TIMEOUT
            ? GO_STATE_TIMED_OUT : GO_STATE_KILLED;
    }
    control->state = state;
    control->finished_at = go_monotonic_seconds();
    control->thread_valid = 0;
    dd_cond_broadcast(&control->cond);
    dd_mutex_unlock(&control->mutex);
}

static void go_control_timeout(go_control *control, unsigned long generation) {
    dd_thread_t thread = DD_THREAD_NULL;
    unsigned long thread_id = 0;
    int valid = 0;
    int should_wake = 0;
    int rc = 0;
    dd_mutex_lock(&control->mutex);
    if (control->state == GO_STATE_RUNNING
        && control->timeout_generation == generation
        && control->timeout_seconds > 0.0
        && !control->cancel_requested) {
        control->cancel_requested = 1;
        control->cancel_reason = GO_CANCEL_TIMEOUT;
        thread = control->thread;
        thread_id = control->thread_id;
        valid = control->thread_valid;
        should_wake = 1;
        dd_cond_broadcast(&control->cond);
    }
    dd_mutex_unlock(&control->mutex);
    if (should_wake && valid) {
#ifndef _WIN32
        pthread_once(&go_signal_once, go_signal_init_once);
        if (go_signal_error != 0) rc = go_signal_error;
        else if (go_signal_enabled) {
            rc = dd_worker_wake(thread, thread_id);
            if (rc == ESRCH) rc = 0;
        }
#else
        rc = dd_worker_wake(thread, thread_id);
#endif
    }
    if (rc != 0) {
        dd_mutex_lock(&control->mutex);
        control->wake_error = rc;
        dd_mutex_unlock(&control->mutex);
    }
}

static DD_WORKER_RETURN go_timeout_worker(void *arg) {
    go_timeout_job *job = (go_timeout_job *)arg;
    go_control *control = job->control;
    unsigned long generation = job->generation;
    double deadline = job->deadline;
    int rc = 0;
    dd_mutex_lock(&control->mutex);
    while (control->state == GO_STATE_RUNNING
        && control->timeout_generation == generation
        && control->timeout_seconds > 0.0) {
        double remaining = deadline - go_monotonic_seconds();
        unsigned long milliseconds;
        if (remaining <= 0.0) {
            rc = DD_TIMEOUT_RESULT;
            break;
        }
        if (remaining >= (double)ULONG_MAX / 1000.0) milliseconds = ULONG_MAX;
        else {
            milliseconds = (unsigned long)(remaining * 1000.0 + 0.999);
            if (milliseconds == 0) milliseconds = 1;
        }
        rc = dd_cond_timedwait_ms(&control->cond, &control->mutex, milliseconds);
        if (rc == DD_TIMEOUT_RESULT) continue;
        if (rc != 0) {
            control->wake_error = rc;
            break;
        }
    }
    {
        int expired = rc == DD_TIMEOUT_RESULT
            && control->state == GO_STATE_RUNNING
            && control->timeout_generation == generation;
        int failed = rc != 0 && rc != DD_TIMEOUT_RESULT;
        if (failed) control->wake_error = rc;
        dd_mutex_unlock(&control->mutex);
        if (expired || failed) go_control_timeout(control, generation);
    }
    free(job);
    go_active_dec();
    go_control_release(control);
    DD_WORKER_DONE;
}

static void go_control_set_timeout(go_control *control, double seconds) {
    go_timeout_job *job = NULL;
    dd_thread_t thread;
    int rc;
    unsigned long generation;
    dd_mutex_lock(&control->mutex);
    if (control->state != GO_STATE_RUNNING) {
        dd_mutex_unlock(&control->mutex);
        return;
    }
    generation = ++control->timeout_generation;
    control->timeout_seconds = seconds;
    dd_cond_broadcast(&control->cond);
    dd_mutex_unlock(&control->mutex);
    if (seconds == 0.0) return;

    job = (go_timeout_job *)malloc(sizeof(*job));
    if (job == NULL) {
        dd_mutex_lock(&control->mutex);
        if (control->timeout_generation == generation) {
            control->timeout_seconds = 0.0;
            ++control->timeout_generation;
        }
        dd_mutex_unlock(&control->mutex);
        croak("out of memory allocating GoRoutine timeout");
    }
    job->control = control;
    job->generation = generation;
    job->deadline = go_monotonic_seconds() + seconds;
    go_control_retain(control);
    go_active_inc();
    rc = dd_thread_create(&thread, go_timeout_worker, job);
    if (rc != 0) {
        go_active_dec();
        go_control_release(control);
        free(job);
        dd_mutex_lock(&control->mutex);
        if (control->timeout_generation == generation) {
            control->timeout_seconds = 0.0;
            ++control->timeout_generation;
        }
        dd_mutex_unlock(&control->mutex);
        croak("native timeout thread creation failed: %d", rc);
    }
#ifndef _WIN32
    rc = dd_thread_detach(thread);
    if (rc != 0) croak("native timeout thread detach failed: %d", rc);
#else
    dd_thread_detach(thread);
#endif
}

#define GO_CANCEL_EXCEPTION "__DEVELOPER_DASHBOARD_GOROUTINE_CANCEL__"
#define GO_EXIT_EXCEPTION   "__DEVELOPER_DASHBOARD_GOROUTINE_EXIT__"

static int go_runops(pTHX) {
    go_control *control = go_tls_get();
    while (PL_op) {
        if (control && go_control_cancel_requested(control)) croak(GO_CANCEL_EXCEPTION);
        if (control && go_control_exit_requested(control)) croak(GO_EXIT_EXCEPTION);
        if (control && PL_op->op_type == OP_EXIT) {
            go_control_request_exit(control);
            croak(GO_EXIT_EXCEPTION);
        }
        PL_op = CALL_FPTR(PL_op->op_ppaddr)(aTHX);
        PERL_ASYNC_CHECK();
    }
    return 0;
}

static go_control *go_control_from_uv(UV ptr) {
    go_control *control = INT2PTR(go_control *, ptr);
    if (control == NULL) croak("invalid GoRoutine routine handle");
    return control;
}

static go_control *go_control_from_sv(pTHX_ SV *handle_sv) {
    HV *handle;
    SV **slot;
    UV ptr;
    go_control *control;
    if (!SvROK(handle_sv) || SvTYPE(SvRV(handle_sv)) != SVt_PVHV)
        croak("invalid GoRoutine routine handle");
    handle = (HV *)SvRV(handle_sv);
    slot = hv_fetch(handle, "ptr", 3, 0);
    if (slot == NULL || !SvOK(*slot)) croak("invalid GoRoutine routine handle");
    ptr = SvUV(*slot);
    control = go_control_from_uv(ptr);
    if (control->owner != aTHX) croak("GoRoutine handle belongs to another interpreter");
    return control;
}

static SV *go_handle_new(pTHX_ go_control *control) {
    HV *handle = newHV();
    hv_store(handle, "ptr", 3, newSVuv(PTR2UV(control)), 0);
    control->refs++;
    return sv_bless(newRV_noinc((SV *)handle), gv_stashpv("Developer::Dashboard::GoRoutine::Routine", GV_ADD));
}

static DD_WORKER_RETURN go_worker(void *arg) {
    go_job *job = (go_job *)arg;
    PerlInterpreter *interp = job->interp;
    go_control *control = job->control;
    go_state final_state = GO_STATE_DONE;
    int tls_rc;
#ifdef _WIN32
    MSG message;
    PeekMessage(&message, NULL, 0, 0, PM_NOREMOVE);
#endif
    dd_mutex_lock(&control->mutex);
#ifdef _WIN32
    control->thread_id = (unsigned long)GetCurrentThreadId();
#endif
    control->worker_ready = 1;
    dd_cond_broadcast(&control->cond);
    while (!control->thread_valid && control->state == GO_STATE_RUNNING)
        dd_cond_wait(&control->cond, &control->mutex);
    dd_mutex_unlock(&control->mutex);
    PERL_SET_CONTEXT(interp);
    {
        dTHX;
        dSP;
        tls_rc = go_tls_set(control);
        if (tls_rc != 0) {
            final_state = GO_STATE_FAILED;
            Perl_warn(aTHX_ "Developer::Dashboard::GoRoutine TLS initialization failed: %d", tls_rc);
        }
        else {
            PL_runops = go_runops;
            ENTER;
            SAVETMPS;
            PUSHMARK(SP);
            PUTBACK;
            call_sv(job->callback, G_VOID | G_DISCARD | G_EVAL);
            /* Avoid re-raising a caught cancel/exit while Perl unwinds callback
             * temporaries and runs destructors. */
            tls_rc = go_tls_set(NULL);
            if (tls_rc != 0)
                Perl_warn(aTHX_ "Developer::Dashboard::GoRoutine TLS cleanup failed: %d", tls_rc);
            SPAGAIN;
            if (SvTRUE(ERRSV)) {
                STRLEN len = 0;
                const char *msg = SvPV(ERRSV, len);
                if (strstr(msg, GO_CANCEL_EXCEPTION) != NULL) {
                    dd_mutex_lock(&control->mutex);
                    final_state = control->cancel_reason == GO_CANCEL_TIMEOUT
                        ? GO_STATE_TIMED_OUT : GO_STATE_KILLED;
                    dd_mutex_unlock(&control->mutex);
                }
                else if (strstr(msg, GO_EXIT_EXCEPTION) != NULL) final_state = GO_STATE_EXITED;
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
        }
        SvREFCNT_dec(job->callback);
        dd_mutex_lock(&control->mutex);
        tls_rc = control->wake_error;
        dd_mutex_unlock(&control->mutex);
        if (tls_rc != 0) {
            final_state = GO_STATE_FAILED;
            Perl_warn(aTHX_ "Developer::Dashboard::GoRoutine control failed to wake worker: %d", tls_rc);
        }
    }
    go_control_finish(control, final_state);
    go_destroy_interpreter(interp);
    free(job);
    go_active_dec();
    go_control_release(control);
    DD_WORKER_DONE;
}

static shared_scalar *shared_from_uv(UV ptr) {
    shared_scalar *value = INT2PTR(shared_scalar *, ptr);
    if (value == NULL) croak("invalid shared scalar handle");
    return value;
}

static void shared_clear_value(shared_scalar *value) {
    if (value->type == SHARED_PV && value->pv != NULL) {
        free(value->pv);
        value->pv = NULL;
        value->pv_len = 0;
    }
    value->type = SHARED_UNDEF;
}

static void shared_store_sv(pTHX_ shared_scalar *value, SV *input) {
    STRLEN len = 0;
    const char *text;
    shared_clear_value(value);
    if (!SvOK(input)) return;
    if (SvIOK(input) && !SvNOK(input) && !SvPOK(input)) {
        value->type = SHARED_IV;
        value->iv = SvIV(input);
        return;
    }
    if (SvNOK(input) && !SvPOK(input)) {
        value->type = SHARED_NV;
        value->nv = SvNV(input);
        return;
    }
    text = SvPV(input, len);
    if (len == (STRLEN)-1) croak("shared scalar string is too large");
    value->pv = (char *)malloc(len + 1);
    if (value->pv == NULL) croak("out of memory storing shared scalar string");
    memcpy(value->pv, text, len);
    value->pv[len] = '\0';
    value->pv_len = len;
    value->type = SHARED_PV;
}

static SV *shared_copy_sv(pTHX_ const shared_scalar *value) {
    switch (value->type) {
        case SHARED_IV: return newSViv(value->iv);
        case SHARED_NV: return newSVnv(value->nv);
        case SHARED_PV: return newSVpvn(value->pv ? value->pv : "", value->pv_len);
        case SHARED_UNDEF:
        default: return newSV(0);
    }
}

static NV shared_as_nv(pTHX_ const shared_scalar *value) {
    NV result;
    SV *copy = shared_copy_sv(aTHX_ value);
    result = SvNV(copy);
    SvREFCNT_dec(copy);
    return result;
}

static IV shared_as_iv(pTHX_ const shared_scalar *value) {
    IV result;
    SV *copy = shared_copy_sv(aTHX_ value);
    result = SvIV(copy);
    SvREFCNT_dec(copy);
    return result;
}

static void shared_store_nv(shared_scalar *value, NV number) {
    shared_clear_value(value);
    value->type = SHARED_NV;
    value->nv = number;
}

static void shared_store_iv(shared_scalar *value, IV number) {
    shared_clear_value(value);
    value->type = SHARED_IV;
    value->iv = number;
}

static void shared_concat(pTHX_ shared_scalar *value, SV *arg, int reverse) {
    SV *left = shared_copy_sv(aTHX_ value);
    STRLEN left_len = 0, right_len = 0;
    const char *left_text = SvPV(left, left_len);
    const char *right_text = SvPV(arg, right_len);
    if (right_len > (STRLEN)-1 - left_len - 1) {
        SvREFCNT_dec(left);
        croak("shared scalar concatenation is too large");
    }
    STRLEN total = left_len + right_len;
    char *buffer = (char *)malloc(total + 1);
    if (buffer == NULL) {
        SvREFCNT_dec(left);
        croak("out of memory concatenating shared scalar");
    }
    if (reverse) {
        memcpy(buffer, right_text, right_len);
        memcpy(buffer + right_len, left_text, left_len);
    }
    else {
        memcpy(buffer, left_text, left_len);
        memcpy(buffer + left_len, right_text, right_len);
    }
    buffer[total] = '\0';
    shared_clear_value(value);
    value->type = SHARED_PV;
    value->pv = buffer;
    value->pv_len = total;
    SvREFCNT_dec(left);
}

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

static HANDLE dd_windows_redirect(const char *path, DWORD access) {
    if (path == NULL) return INVALID_HANDLE_VALUE;
    return CreateFileA(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
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
    HANDLE child_in = stdin_path ? CreateFileA(stdin_path, GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL)
        : GetStdHandle(STD_INPUT_HANDLE);
    HANDLE child_out = dd_windows_redirect(stdout_path, GENERIC_WRITE);
    HANDLE child_err = dd_windows_redirect(stderr_path, GENERIC_WRITE);
    if (stdin_path && child_in == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError(); free(line); free(argv);
        croak("unable to open GoRoutine child stdin (Windows error %lu)", (unsigned long)error);
    }
    if (stdout_path && child_out == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError(); free(line); free(argv);
        croak("unable to open GoRoutine child stdout (Windows error %lu)", (unsigned long)error);
    }
    if (stderr_path && child_err == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError(); free(line); free(argv);
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
                        NULL, cwd, &startup, &process)) {
        DWORD error = GetLastError();
        if (stdin_path) CloseHandle(child_in);
        if (stdout_path) CloseHandle(child_out);
        if (stderr_path) CloseHandle(child_err);
        free(line); free(argv);
        croak("unable to create GoRoutine child process (Windows error %lu)", (unsigned long)error);
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    if (stdin_path) CloseHandle(child_in);
    if (stdout_path) CloseHandle(child_out);
    if (stderr_path) CloseHandle(child_err);
    free(line); free(argv);
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
    posix_spawn_file_actions_t actions;
    int rc = posix_spawn_file_actions_init(&actions);
    if (rc != 0) { free(argv); croak("unable to initialise GoRoutine process actions: %s", strerror(rc)); }
    if (stdin_path) rc = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, stdin_path, O_RDONLY, 0);
    if (rc == 0 && stdout_path) rc = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, stdout_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (rc == 0 && stderr_path) rc = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, stderr_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (rc != 0) {
        posix_spawn_file_actions_destroy(&actions); free(argv);
        croak("unable to configure GoRoutine child file actions: %s", strerror(rc));
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
    rc = posix_spawnp(&pid, child_argv[0], &actions, NULL, child_argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    free(wrapped_argv);
    free(argv);
    if (rc != 0) croak("unable to spawn GoRoutine child process: %s", strerror(rc));
    return (UV)pid;
}
#endif

#include "GoRoutineShared.h"

#endif
