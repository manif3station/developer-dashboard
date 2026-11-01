MODULE = Developer::Dashboard    PACKAGE = Developer::Dashboard::GoRoutine

PROTOTYPES: ENABLE

BOOT:
    call_atexit(go_root_atexit, (void *)aTHX);

SV *
go(callback)
    SV *callback
  PROTOTYPE: &
  PREINIT:
    PerlInterpreter *parent;
    PerlInterpreter *child;
    SV *child_callback;
    go_job *job;
    go_control *ctl;
    go_thread_t tid;
    int rc;
  CODE:
    if (!SvROK(callback) || SvTYPE(SvRV(callback)) != SVt_PVCV) {
        croak("go() expects a code reference");
    }

    go_once(&go_signal_once, go_signal_init_once);
    ctl = go_control_new();
    parent = aTHX;
    child = perl_clone(parent, go_clone_flags());
    if (child == NULL) croak("perl_clone() failed");

    PERL_SET_CONTEXT(child);
    {
        dTHXa(child);
        child_callback = (SV *)ptr_table_fetch(PL_ptr_table, callback);
        if (child_callback != NULL) {
            SvREFCNT_inc(child_callback);
        } else {
            SV *child_cv = (SV *)ptr_table_fetch(PL_ptr_table, SvRV(callback));
            child_callback = child_cv ? newRV_inc(child_cv) : NULL;
        }
    }
    PERL_SET_CONTEXT(parent);

    if (child_callback == NULL) {
        go_destroy_interpreter(child);
        PERL_SET_CONTEXT(parent);
        croak("could not map callback into cloned Perl interpreter");
    }

    job = (go_job *)malloc(sizeof(*job));
    if (job == NULL) {
        PERL_SET_CONTEXT(child);
        { dTHXa(child); SvREFCNT_dec(child_callback); }
        go_destroy_interpreter(child);
        PERL_SET_CONTEXT(parent);
        croak("out of memory allocating go routine job");
    }
    job->interp = child;
    job->callback = child_callback;
    job->control = ctl;

    go_active_inc();
    rc = go_thread_create(&tid, go_worker, job);
    if (rc != 0) {
        PERL_SET_CONTEXT(child);
        { dTHXa(child); SvREFCNT_dec(child_callback); }
        go_destroy_interpreter(child);
        PERL_SET_CONTEXT(parent);
        free(job);
        go_active_dec();
        croak("native thread creation failed: %d", rc);
    }

    go_mutex_lock(&ctl->mutex);
    ctl->thread = tid;
    ctl->thread_valid = 1;
    go_mutex_unlock(&ctl->mutex);

    go_thread_detach(tid);
    RETVAL = go_handle_new(aTHX_ ctl);
  OUTPUT:
    RETVAL

SV *
channel(capacity = 0)
    IV capacity
  PREINIT:
    go_channel *ch;
  CODE:
    if (capacity < 0) croak("channel() capacity must be zero or greater");
    ch = (go_channel *)calloc(1, sizeof(*ch));
    if (ch == NULL) croak("out of memory allocating channel");
    go_mutex_init(&ch->mutex);
    go_cond_init(&ch->can_send);
    go_cond_init(&ch->can_receive);
    ch->capacity = (size_t)capacity;
    if (ch->capacity > 0) {
        ch->buffer = (shared_node **)calloc(ch->capacity, sizeof(*ch->buffer));
        if (ch->buffer == NULL) {
            free(ch);
            croak("out of memory allocating channel buffer");
        }
    }
    RETVAL = go_channel_handle_new(aTHX_ ch);
  OUTPUT:
    RETVAL

void
_channel_send(ptr, value)
    UV ptr
    SV *value
  PREINIT:
    go_channel *ch;
    shared_node *message;
    unsigned long seq = 0;
    int cancelled = 0;
    int closed = 0;
  CODE:
    ch = go_channel_from_uv(ptr);

    if (go_channel_current_cancelled()) croak(GO_CANCEL_EXCEPTION);

    go_mutex_lock(&ch->mutex);
    closed = ch->closed;
    go_mutex_unlock(&ch->mutex);
    if (closed) croak("send on closed channel");

    /* Marshal before taking the channel mutex: importing CODE/IO/object
     * values may itself execute Perl and must not block other channel users. */
    message = go_channel_import_value(aTHX_ value);

    go_mutex_lock(&ch->mutex);

    if (ch->capacity == 0) {
        while (ch->slot != NULL && !ch->closed) {
            if (!go_channel_wait_interruptible(&ch->can_send, &ch->mutex)) {
                cancelled = 1;
                break;
            }
        }

        if (!cancelled && !ch->closed) {
            seq = ++ch->next_seq;
            ch->slot = message;
            ch->slot_seq = seq;
            go_cond_broadcast(&ch->can_receive);

            while (ch->consumed_seq < seq && !ch->closed) {
                if (!go_channel_wait_interruptible(&ch->can_send, &ch->mutex)) {
                    cancelled = 1;
                    break;
                }
            }

            if (cancelled && ch->consumed_seq < seq
                && ch->slot != NULL && ch->slot_seq == seq) {
                ch->slot = NULL;
                go_cond_broadcast(&ch->can_send);
                go_cond_broadcast(&ch->can_receive);
            }
        }
    }
    else {
        while (ch->count == ch->capacity && !ch->closed) {
            if (!go_channel_wait_interruptible(&ch->can_send, &ch->mutex)) {
                cancelled = 1;
                break;
            }
        }

        if (!cancelled && !ch->closed) {
            ch->buffer[ch->tail] = message;
            ch->tail = (ch->tail + 1) % ch->capacity;
            ++ch->count;
            go_cond_broadcast(&ch->can_receive);
        }
    }

    closed = ch->closed;
    if (ch->capacity == 0 && seq != 0 && ch->consumed_seq >= seq) {
        /* A rendezvous completed before a simultaneous close/cancel. */
        closed = 0;
        cancelled = 0;
    }
    go_mutex_unlock(&ch->mutex);

    if (cancelled) croak(GO_CANCEL_EXCEPTION);
    if (closed) croak("send on closed channel");

void
_channel_receive(ptr)
    UV ptr
  PREINIT:
    go_channel *ch;
    shared_node *message = NULL;
    int cancelled = 0;
    int closed_empty = 0;
    I32 gimme;
    SV *ret;
  PPCODE:
    ch = go_channel_from_uv(ptr);
    gimme = GIMME_V;

    if (go_channel_current_cancelled()) croak(GO_CANCEL_EXCEPTION);

    go_mutex_lock(&ch->mutex);

    if (ch->capacity == 0) {
        while (ch->slot == NULL && !ch->closed) {
            if (!go_channel_wait_interruptible(&ch->can_receive, &ch->mutex)) {
                cancelled = 1;
                break;
            }
        }

        if (!cancelled && ch->slot != NULL) {
            message = ch->slot;
            ch->consumed_seq = ch->slot_seq;
            ch->slot = NULL;
            go_cond_broadcast(&ch->can_send);
        }
        else if (!cancelled && ch->closed) {
            closed_empty = 1;
        }
    }
    else {
        while (ch->count == 0 && !ch->closed) {
            if (!go_channel_wait_interruptible(&ch->can_receive, &ch->mutex)) {
                cancelled = 1;
                break;
            }
        }

        if (!cancelled && ch->count > 0) {
            message = ch->buffer[ch->head];
            ch->buffer[ch->head] = NULL;
            ch->head = (ch->head + 1) % ch->capacity;
            --ch->count;
            go_cond_broadcast(&ch->can_send);
        }
        else if (!cancelled && ch->closed) {
            closed_empty = 1;
        }
    }

    go_mutex_unlock(&ch->mutex);

    if (cancelled) croak(GO_CANCEL_EXCEPTION);

    if (closed_empty) {
        if (gimme == G_ARRAY) {
            XPUSHs(&PL_sv_undef);
            XPUSHs(sv_2mortal(newSViv(0)));
        }
        else if (gimme != G_VOID) {
            XPUSHs(&PL_sv_undef);
        }
        XSRETURN(gimme == G_ARRAY ? 2 : (gimme == G_VOID ? 0 : 1));
    }

    if (message == NULL) {
        croak("channel receive failed without a value");
    }

    ret = shared_value_for_call(aTHX_ message);
    if (gimme == G_ARRAY) {
        XPUSHs(sv_2mortal(ret));
        XPUSHs(&PL_sv_yes);
        XSRETURN(2);
    }
    if (gimme == G_VOID) {
        SvREFCNT_dec(ret);
        XSRETURN_EMPTY;
    }
    XPUSHs(sv_2mortal(ret));
    XSRETURN(1);

void
_channel_close(ptr)
    UV ptr
  PREINIT:
    go_channel *ch;
  CODE:
    ch = go_channel_from_uv(ptr);
    go_mutex_lock(&ch->mutex);
    if (ch->closed) {
        go_mutex_unlock(&ch->mutex);
        croak("close of closed channel");
    }
    ch->closed = 1;
    if (ch->capacity == 0) {
        /* A waiting unbuffered sender has not completed until a receive.
         * Closing therefore cancels that pending send, matching Go. */
        ch->slot = NULL;
    }
    go_cond_broadcast(&ch->can_send);
    go_cond_broadcast(&ch->can_receive);
    go_mutex_unlock(&ch->mutex);

int
_channel_is_closed(ptr)
    UV ptr
  PREINIT:
    go_channel *ch;
  CODE:
    ch = go_channel_from_uv(ptr);
    go_mutex_lock(&ch->mutex);
    RETVAL = ch->closed ? 1 : 0;
    go_mutex_unlock(&ch->mutex);
  OUTPUT:
    RETVAL

UV
_channel_size(ptr)
    UV ptr
  PREINIT:
    go_channel *ch;
  CODE:
    ch = go_channel_from_uv(ptr);
    go_mutex_lock(&ch->mutex);
    RETVAL = (UV)(ch->capacity == 0 ? (ch->slot ? 1 : 0) : ch->count);
    go_mutex_unlock(&ch->mutex);
  OUTPUT:
    RETVAL

UV
_channel_capacity(ptr)
    UV ptr
  PREINIT:
    go_channel *ch;
  CODE:
    ch = go_channel_from_uv(ptr);
    RETVAL = (UV)ch->capacity;
  OUTPUT:
    RETVAL

void
wait_all()
  CODE:
    go_wait_all_internal();

int
_routine_is_running(ptr)
    UV ptr
  PREINIT:
    go_control *ctl;
  CODE:
    ctl = go_control_from_uv(ptr);
    RETVAL = go_control_is_running(ctl);
  OUTPUT:
    RETVAL

double
_routine_age(ptr)
    UV ptr
  PREINIT:
    go_control *ctl;
    double end;
  CODE:
    ctl = go_control_from_uv(ptr);
    go_mutex_lock(&ctl->mutex);
    end = (ctl->state == GO_STATE_RUNNING)
        ? go_monotonic_seconds() : ctl->finished_at;
    RETVAL = end - ctl->started_at;
    go_mutex_unlock(&ctl->mutex);
  OUTPUT:
    RETVAL

int
_routine_kill(ptr)
    UV ptr
  PREINIT:
    go_control *ctl;
  CODE:
    ctl = go_control_from_uv(ptr);
    RETVAL = go_control_request_cancel(ctl, GO_CANCEL_KILL);
  OUTPUT:
    RETVAL

void
_routine_timeout(ptr, seconds)
    UV ptr
    double seconds
  PREINIT:
    go_control *ctl;
    go_timeout_job *timer;
    go_thread_t tid;
    unsigned long generation;
    int rc;
  CODE:
    ctl = go_control_from_uv(ptr);

    go_mutex_lock(&ctl->mutex);
    ++ctl->timeout_generation;
    generation = ctl->timeout_generation;
    ctl->timeout_seconds = seconds > 0 ? seconds : 0;
    go_cond_broadcast(&ctl->cond);
    if (ctl->state != GO_STATE_RUNNING || seconds <= 0) {
        go_mutex_unlock(&ctl->mutex);
    } else {
        go_mutex_unlock(&ctl->mutex);

        timer = (go_timeout_job *)malloc(sizeof(*timer));
        if (timer == NULL) croak("out of memory allocating go routine timeout");
        timer->control = ctl;
        timer->generation = generation;
        timer->seconds = seconds;

        rc = go_thread_create(&tid, go_timeout_worker, timer);
        if (rc != 0) {
            free(timer);
            croak("native thread creation failed for timeout watcher: %d", rc);
        }
        go_thread_detach(tid);
    }

const char *
_routine_status(ptr)
    UV ptr
  PREINIT:
    go_control *ctl;
    const char *status;
  CODE:
    ctl = go_control_from_uv(ptr);
    go_mutex_lock(&ctl->mutex);
    switch (ctl->state) {
        case GO_STATE_RUNNING:   status = "running"; break;
        case GO_STATE_DONE:      status = "done"; break;
        case GO_STATE_KILLED:    status = "killed"; break;
        case GO_STATE_TIMED_OUT: status = "timed_out"; break;
        case GO_STATE_EXITED:    status = "exited"; break;
        case GO_STATE_FAILED:    status = "failed"; break;
        default:                 status = "unknown"; break;
    }
    go_mutex_unlock(&ctl->mutex);
    RETVAL = status;
  OUTPUT:
    RETVAL

UV
_shared_node_new()
  PREINIT:
    shared_node *n;
  CODE:
    shared_lock();
    n = shared_node_new();
    shared_unlock();
    RETVAL = PTR2UV(n);
  OUTPUT:
    RETVAL

const char *
_shared_node_kind(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
    const char *kind;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    switch (n->type) {
        case SHARED_HASH: kind = "hash"; break;
        case SHARED_ARRAY: kind = "array"; break;
        case SHARED_SCALARREF: kind = "scalarref"; break;
        case SHARED_OBJECT: kind = "object"; break;
        case SHARED_CODE: kind = "code"; break;
        case SHARED_GLOB: kind = "glob"; break;
        case SHARED_IO: kind = "io"; break;
        case SHARED_REGEXP: kind = "regexp"; break;
        case SHARED_FORMAT: kind = "format"; break;
        default: kind = "scalar"; break;
    }
    shared_unlock();
    RETVAL = kind;
  OUTPUT:
    RETVAL

IV
_shared_handle_fd(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_GLOB && n->type != SHARED_IO) {
        shared_unlock();
        croak("shared value is not a GLOB/IO handle");
    }
    RETVAL = (IV)n->io_fd;
    shared_unlock();
  OUTPUT:
    RETVAL

const char *
_shared_handle_mode(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
    const char *mode;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_GLOB && n->type != SHARED_IO) {
        shared_unlock();
        croak("shared value is not a GLOB/IO handle");
    }
    mode = (n->io_mode == 0) ? "<&" : (n->io_mode == 1) ? ">&" : "+<&";
    shared_unlock();
    RETVAL = mode;
  OUTPUT:
    RETVAL

UV
_shared_glob_slot_ptr(ptr, slot)
    UV ptr
    const char *slot
  PREINIT:
    shared_node *n;
    shared_node *child = NULL;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_GLOB) {
        shared_unlock();
        croak("shared value is not a GLOB reference");
    }
    if (strEQ(slot, "scalar")) child = n->glob_scalar;
    else if (strEQ(slot, "array")) child = n->glob_array;
    else if (strEQ(slot, "hash")) child = n->glob_hash;
    else if (strEQ(slot, "code")) child = n->glob_code;
    else {
        shared_unlock();
        croak("unknown GLOB slot '%s'", slot);
    }
    RETVAL = child ? PTR2UV(child) : 0;
    shared_unlock();
  OUTPUT:
    RETVAL

SV *
_shared_node_text(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    RETVAL = n->pv ? newSVpvn(n->pv, n->pv_len) : newSV(0);
    shared_unlock();
  OUTPUT:
    RETVAL

void
_shared_handle_remote(ptr, op, ...)
    UV ptr
    const char *op
  PREINIT:
    shared_node *n;
    shared_handle_state *state;
    shared_node **args = NULL;
    I32 argc = 0;
    I32 i;
    I32 gimme;
    shared_node **results = NULL;
    I32 result_count = 0;
    char *error = NULL;
    PerlInterpreter *caller;
  PPCODE:
    caller = aTHX;
    gimme = GIMME_V;
    argc = items - 2;

    shared_lock();
    n = shared_from_uv(ptr);
    if ((n->type != SHARED_GLOB && n->type != SHARED_IO) || n->handle_state == NULL) {
        shared_unlock();
        croak("shared filehandle has no remote PerlIO state");
    }
    state = n->handle_state;
    shared_unlock();

    if (argc > 0) {
        args = (shared_node **)calloc((size_t)argc, sizeof(*args));
        if (args == NULL) croak("out of memory marshalling shared filehandle arguments");
    }

    for (i = 0; i < argc; ++i) {
        SV *arg = ST(i + 2);
        shared_node *existing = shared_proxy_node_from_sv(aTHX_ arg);
        if (existing != NULL) {
            args[i] = existing;
        }
        else {
            import_map map;
            memset(&map, 0, sizeof(map));
            shared_lock();
            args[i] = shared_import_value(aTHX_ arg, &map, NULL);
            shared_unlock();
            free((void *)map.source);
            free(map.node);
        }
    }

    shared_handle_invoke(state, op, gimme, args, argc,
                         &results, &result_count, &error);
    free(args);

    PERL_SET_CONTEXT(caller);

    if (error != NULL) {
        SV *errsv = newSVpv(error, 0);
        free(error);
        if (results != NULL) free(results);
        croak_sv(errsv);
    }

    if (gimme != G_VOID) {
        for (i = 0; i < result_count; ++i) {
            SV *ret = shared_value_for_call(aTHX_ results[i]);
            XPUSHs(sv_2mortal(ret));
        }
    }
    if (results != NULL) free(results);

void
_shared_code_call(ptr, ...)
    UV ptr
  PREINIT:
    shared_node *n;
    shared_code_state *state;
    shared_node **args = NULL;
    I32 argc = 0;
    I32 i;
    I32 gimme;
    shared_node **results = NULL;
    I32 result_count = 0;
    char *error = NULL;
    PerlInterpreter *caller;
  PPCODE:
    caller = aTHX;
    gimme = GIMME_V;
    argc = items - 1;

    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_CODE || n->code == NULL) {
        shared_unlock();
        croak("shared value is not a CODE reference");
    }
    state = n->code;
    shared_unlock();

    if (argc > 0) {
        args = (shared_node **)calloc((size_t)argc, sizeof(*args));
        if (args == NULL) croak("out of memory marshalling shared callback arguments");
    }

    for (i = 0; i < argc; ++i) {
        SV *arg = ST(i + 1);
        shared_node *existing = shared_proxy_node_from_sv(aTHX_ arg);
        if (existing != NULL) {
            args[i] = existing;
        }
        else {
            import_map map;
            memset(&map, 0, sizeof(map));
            shared_lock();
            args[i] = shared_import_value(aTHX_ arg, &map, NULL);
            shared_unlock();
            free((void *)map.source);
            free(map.node);
        }
    }

    shared_code_invoke(state, gimme, args, argc,
                       &results, &result_count, &error);
    free(args);

    PERL_SET_CONTEXT(caller);

    if (error != NULL) {
        SV *errsv = newSVpv(error, 0);
        free(error);
        if (results != NULL) free(results);
        croak_sv(errsv);
    }

    if (gimme != G_VOID) {
        for (i = 0; i < result_count; ++i) {
            SV *ret = shared_value_for_call(aTHX_ results[i]);
            XPUSHs(sv_2mortal(ret));
        }
    }
    if (results != NULL) free(results);

SV *
_shared_node_class(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    RETVAL = n->class_name ? newSVpv(n->class_name, 0) : newSV(0);
    shared_unlock();
  OUTPUT:
    RETVAL

SV *
_shared_object_proxy(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    RETVAL = shared_object_proxy(aTHX_ n);
    shared_unlock();
  OUTPUT:
    RETVAL

SV *
_shared_scalar_get(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    RETVAL = shared_copy_scalar(aTHX_ n);
    shared_unlock();
  OUTPUT:
    RETVAL

void
_shared_node_set(ptr, value, utf8 = 0)
    UV ptr
    SV *value
    int utf8
  PREINIT:
    shared_node *n;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    shared_import_into(aTHX_ n, value);
    if (utf8 && !SvROK(value) && n->type == SHARED_PV) n->pv_utf8 = 1;
    shared_unlock();

void
_shared_scalar_apply(ptr, op, arg, reverse)
    UV ptr
    const char *op
    SV *arg
    int reverse
  PREINIT:
    shared_node *n;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    shared_apply(aTHX_ n, op, arg, reverse);
    shared_unlock();

UV
_shared_hash_fetch_ptr(ptr, key)
    UV ptr
    SV *key
  PREINIT:
    shared_node *n;
    shared_node *child;
    STRLEN len;
    const char *k;
  CODE:
    k = SvPV(key, len);
    shared_lock();
    n = shared_from_uv(ptr);
    child = shared_hash_get_node(n, k, len);
    RETVAL = child ? PTR2UV(child) : 0;
    shared_unlock();
  OUTPUT:
    RETVAL

int
_shared_hash_exists(ptr, key)
    UV ptr
    SV *key
  PREINIT:
    shared_node *n;
    STRLEN len;
    const char *k;
  CODE:
    k = SvPV(key, len);
    shared_lock();
    n = shared_from_uv(ptr);
    RETVAL = shared_hash_get_node(n, k, len) ? 1 : 0;
    shared_unlock();
  OUTPUT:
    RETVAL

void
_shared_hash_store(ptr, key, value)
    UV ptr
    SV *key
    SV *value
  PREINIT:
    shared_node *n;
    shared_node *child;
    STRLEN len;
    const char *k;
  CODE:
    k = SvPV(key, len);
    shared_lock();
    n = shared_from_uv(ptr);
    child = shared_hash_ensure_node(n, k, len);
    shared_import_into(aTHX_ child, value);
    shared_unlock();

void
_shared_hash_store_ptr(ptr, key, child_ptr)
    UV ptr
    SV *key
    UV child_ptr
  PREINIT:
    shared_node *n;
    shared_node *child;
    SSize_t idx;
    shared_hash_entry *e;
    STRLEN len;
    const char *k;
  CODE:
    k = SvPV(key, len);
    shared_lock();
    n = shared_from_uv(ptr);
    child = shared_from_uv(child_ptr);
    idx = shared_hash_find(n, k, len);
    if (idx >= 0) {
        n->hash_entries[idx].value = child;
    } else {
        shared_hash_reserve(n, n->hash_count + 1);
        e = &n->hash_entries[n->hash_count++];
        e->key = (char *)malloc(len + 1);
        if (e->key == NULL) { shared_unlock(); croak("out of memory storing shared hash key"); }
        memcpy(e->key, k, len);
        e->key[len] = '\0';
        e->key_len = len;
        e->value = child;
    }
    shared_unlock();

UV
_shared_hash_delete_ptr(ptr, key)
    UV ptr
    SV *key
  PREINIT:
    shared_node *n;
    shared_node *old = NULL;
    SSize_t idx;
    size_t i;
    STRLEN len;
    const char *k;
  CODE:
    k = SvPV(key, len);
    shared_lock();
    n = shared_from_uv(ptr);
    idx = shared_hash_find(n, k, len);
    if (idx >= 0) {
        old = n->hash_entries[idx].value;
        free(n->hash_entries[idx].key);
        for (i = (size_t)idx + 1; i < n->hash_count; ++i) {
            n->hash_entries[i - 1] = n->hash_entries[i];
        }
        --n->hash_count;
    }
    RETVAL = old ? PTR2UV(old) : 0;
    shared_unlock();
  OUTPUT:
    RETVAL

void
_shared_hash_clear(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
    size_t i;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_HASH) { shared_unlock(); croak("shared value is not a hash"); }
    for (i = 0; i < n->hash_count; ++i) free(n->hash_entries[i].key);
    free(n->hash_entries);
    n->hash_entries = NULL;
    n->hash_count = 0;
    n->hash_capacity = 0;
    shared_unlock();

UV
_shared_hash_count(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_HASH) { shared_unlock(); croak("shared value is not a hash"); }
    RETVAL = (UV)n->hash_count;
    shared_unlock();
  OUTPUT:
    RETVAL

void
_shared_hash_keys(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
    size_t i;
  PPCODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_HASH) { shared_unlock(); croak("shared value is not a hash"); }
    EXTEND(SP, (SSize_t)n->hash_count);
    for (i = 0; i < n->hash_count; ++i) {
        PUSHs(sv_2mortal(newSVpvn(n->hash_entries[i].key, n->hash_entries[i].key_len)));
    }
    shared_unlock();

UV
_shared_array_size(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    RETVAL = (UV)n->array_size;
    shared_unlock();
  OUTPUT:
    RETVAL

UV
_shared_array_fetch_ptr(ptr, index)
    UV ptr
    IV index
  PREINIT:
    shared_node *n;
    shared_node *child = NULL;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    if (index >= 0 && (size_t)index < n->array_size) child = n->array_items[index];
    RETVAL = child ? PTR2UV(child) : 0;
    shared_unlock();
  OUTPUT:
    RETVAL

int
_shared_array_exists(ptr, index)
    UV ptr
    IV index
  PREINIT:
    shared_node *n;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    RETVAL = (index >= 0 && (size_t)index < n->array_size && n->array_items[index] != NULL) ? 1 : 0;
    shared_unlock();
  OUTPUT:
    RETVAL

void
_shared_array_store(ptr, index, value)
    UV ptr
    IV index
    SV *value
  PREINIT:
    shared_node *n;
  CODE:
    if (index < 0) croak("negative shared array index not supported for STORE");
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    shared_array_reserve(n, (size_t)index + 1);
    if ((size_t)index >= n->array_size) n->array_size = (size_t)index + 1;
    if (n->array_items[index] == NULL) n->array_items[index] = shared_node_new();
    shared_import_into(aTHX_ n->array_items[index], value);
    shared_unlock();

void
_shared_array_store_ptr(ptr, index, child_ptr)
    UV ptr
    IV index
    UV child_ptr
  PREINIT:
    shared_node *n;
    shared_node *child;
  CODE:
    if (index < 0) croak("negative shared array index not supported for STORE");
    shared_lock();
    n = shared_from_uv(ptr);
    child = shared_from_uv(child_ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    shared_array_reserve(n, (size_t)index + 1);
    if ((size_t)index >= n->array_size) n->array_size = (size_t)index + 1;
    n->array_items[index] = child;
    shared_unlock();

UV
_shared_array_delete_ptr(ptr, index)
    UV ptr
    IV index
  PREINIT:
    shared_node *n;
    shared_node *old = NULL;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    if (index >= 0 && (size_t)index < n->array_size) {
        old = n->array_items[index];
        n->array_items[index] = NULL;
    }
    RETVAL = old ? PTR2UV(old) : 0;
    shared_unlock();
  OUTPUT:
    RETVAL

UV
_shared_array_push(ptr, value)
    UV ptr
    SV *value
  PREINIT:
    shared_node *n;
    shared_node *child;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    child = shared_node_new();
    shared_import_into(aTHX_ child, value);
    shared_array_reserve(n, n->array_size + 1);
    n->array_items[n->array_size++] = child;
    RETVAL = (UV)n->array_size;
    shared_unlock();
  OUTPUT:
    RETVAL

void
_shared_array_push_ptr(ptr, child_ptr)
    UV ptr
    UV child_ptr
  PREINIT:
    shared_node *n;
    shared_node *child;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    child = shared_from_uv(child_ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    shared_array_reserve(n, n->array_size + 1);
    n->array_items[n->array_size++] = child;
    shared_unlock();

UV
_shared_array_unshift(ptr, value)
    UV ptr
    SV *value
  PREINIT:
    shared_node *n;
    shared_node *child;
    size_t i;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    child = shared_node_new();
    shared_import_into(aTHX_ child, value);
    shared_array_reserve(n, n->array_size + 1);
    for (i = n->array_size; i > 0; --i) n->array_items[i] = n->array_items[i - 1];
    n->array_items[0] = child;
    ++n->array_size;
    RETVAL = (UV)n->array_size;
    shared_unlock();
  OUTPUT:
    RETVAL

void
_shared_array_unshift_ptr(ptr, child_ptr)
    UV ptr
    UV child_ptr
  PREINIT:
    shared_node *n;
    shared_node *child;
    size_t i;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    child = shared_from_uv(child_ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    shared_array_reserve(n, n->array_size + 1);
    for (i = n->array_size; i > 0; --i) n->array_items[i] = n->array_items[i - 1];
    n->array_items[0] = child;
    ++n->array_size;
    shared_unlock();

UV
_shared_array_pop_ptr(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
    shared_node *old = NULL;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    if (n->array_size > 0) {
        old = n->array_items[n->array_size - 1];
        n->array_items[n->array_size - 1] = NULL;
        --n->array_size;
    }
    RETVAL = old ? PTR2UV(old) : 0;
    shared_unlock();
  OUTPUT:
    RETVAL

UV
_shared_array_shift_ptr(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
    shared_node *old = NULL;
    size_t i;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    if (n->array_size > 0) {
        old = n->array_items[0];
        for (i = 1; i < n->array_size; ++i) n->array_items[i - 1] = n->array_items[i];
        --n->array_size;
        n->array_items[n->array_size] = NULL;
    }
    RETVAL = old ? PTR2UV(old) : 0;
    shared_unlock();
  OUTPUT:
    RETVAL

void
_shared_array_clear(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    memset(n->array_items, 0, n->array_capacity * sizeof(*n->array_items));
    n->array_size = 0;
    shared_unlock();

void
_shared_array_resize(ptr, new_size)
    UV ptr
    UV new_size
  PREINIT:
    shared_node *n;
    size_t i;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_ARRAY) { shared_unlock(); croak("shared value is not an array"); }
    shared_array_reserve(n, (size_t)new_size);
    if ((size_t)new_size > n->array_size) {
        for (i = n->array_size; i < (size_t)new_size; ++i) n->array_items[i] = NULL;
    }
    n->array_size = (size_t)new_size;
    shared_unlock();

UV
_shared_scalarref_ptr(ptr)
    UV ptr
  PREINIT:
    shared_node *n;
  CODE:
    shared_lock();
    n = shared_from_uv(ptr);
    if (n->type != SHARED_SCALARREF) { shared_unlock(); croak("shared value is not a scalar reference"); }
    RETVAL = n->scalarref_value ? PTR2UV(n->scalarref_value) : 0;
    shared_unlock();
  OUTPUT:
    RETVAL
