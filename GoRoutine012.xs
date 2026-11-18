MODULE = Developer::Dashboard    PACKAGE = Developer::Dashboard::GoRoutine

PROTOTYPES: ENABLE

# _ev_invoke_callback(callback)
# Calls a Perl callback on the main thread with exit scoped to it: an
# exit() inside the callback (or in anything it calls) is caught and
# reported as the __GOROUTINE_EXIT__ token instead of terminating the
# process. Returns undef on success, or the error (string or reference)
# the callback died with. The custom runops is installed only for the
# duration of the call and is always restored.
SV *
_ev_invoke_callback(callback)
    SV *callback
  CODE:
    {
        runops_proc_t saved_runops = PL_runops;
        SV *err = NULL;
        PL_runops = go_ev_runops;
        {
            dSP;
            ENTER;
            SAVETMPS;
            PUSHMARK(SP);
            PUTBACK;
            call_sv(callback, G_VOID | G_DISCARD | G_EVAL);
            SPAGAIN;
            if (SvTRUE(ERRSV)) {
                err = newSVsv(ERRSV);
                sv_setsv(ERRSV, &PL_sv_undef);
            }
            PUTBACK;
            FREETMPS;
            LEAVE;
        }
        PL_runops = saved_runops;
        RETVAL = err ? err : newSV(0);
    }
  OUTPUT:
    RETVAL

# _ev_now()
# Monotonic clock in seconds, for scheduling timers on the event loop.
# Input: none. Output: seconds since an arbitrary fixed point.
NV
_ev_now()
  CODE:
    RETVAL = go_ev_now();
  OUTPUT:
    RETVAL

# _ev_add_timer(id, when, interval, kind)
# Registers a timer trigger for a routine id. when is an absolute
# monotonic time (see _ev_now); interval 0 is one-shot, > 0 repeats;
# kind 0 fires the callback, 1 is a timeout (the Perl side cancels the
# routine with status timed_out). Input: routine id, times, kind.
void
_ev_add_timer(id, when, interval, kind)
    IV id
    NV when
    NV interval
    IV kind
  CODE:
    go_ev_add_timer((int)id, when, interval, (int)kind);

# _ev_add_io(id, fd, want_read, want_write, repeat)
# Registers an IO-readiness trigger for a routine id. fd is a Unix file
# descriptor or, on Windows, a SOCKET value (Perl fileno on a socket).
# repeat 1 keeps the trigger registered after it fires; 0 removes it.
void
_ev_add_io(id, fd, want_read, want_write, repeat)
    IV id
    IV fd
    IV want_read
    IV want_write
    IV repeat
  CODE:
#ifdef _WIN32
    go_ev_add_io((int)id, (SOCKET)fd, (int)want_read, (int)want_write, (int)repeat);
#else
    go_ev_add_io((int)id, (int)fd, (int)want_read, (int)want_write, (int)repeat);
#endif

# _ev_add_pid(id, pid)
# Registers a process-exit trigger for a routine id. The pid is checked
# without reaping it (the caller still collects it with wait_process).
void
_ev_add_pid(id, pid)
    IV id
    IV pid
  CODE:
    go_ev_add_pid((int)id, (long)pid);

# _ev_cancel(id)
# Removes every trigger registered for a routine id (timers, IO, pids).
void
_ev_cancel(id)
    IV id
  CODE:
    go_ev_cancel((int)id);

# _ev_wait(timeout_ms)
# Waits for the next trigger and returns the due routine id as a flat
# list (at most one). A positive id means run the callback; a negative
# id means a timeout fired for that routine (id is the absolute value).
# Only one id per call: a callback may block (a channel send waits for
# its receiver), and a batch collected up front cannot be reached by
# the nested wait inside that callback, so due ids are dispatched one
# at a time. timeout_ms >= 0 bounds the wait; < 0 waits until the next
# trigger, or returns at once when nothing is registered.
void
_ev_wait(timeout_ms)
    IV timeout_ms
  PPCODE:
    {
        int due[1];
        long timeout = (long)timeout_ms;
        int n = go_ev_wait(timeout, due, 1);
        if (n > 0)
            XPUSHs(sv_2mortal(newSViv(due[0])));
    }
