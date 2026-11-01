#ifndef DEVELOPER_DASHBOARD_GOROUTINE_SHARED_H
#define DEVELOPER_DASHBOARD_GOROUTINE_SHARED_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef enum {
    DD_SHARED_UNDEF = 0,
    DD_SHARED_IV,
    DD_SHARED_NV,
    DD_SHARED_PV,
    DD_SHARED_HASH,
    DD_SHARED_ARRAY,
    DD_SHARED_SCALARREF,
    DD_SHARED_REGEXP,
    DD_SHARED_FORMAT
} dd_shared_type;

typedef struct dd_shared_node dd_shared_node;

typedef struct {
    char *key;
    STRLEN key_len;
    dd_shared_node *value;
} dd_shared_hash_entry;

struct dd_shared_node {
    dd_shared_type type;
    IV iv;
    NV nv;
    char *pv;
    STRLEN pv_len;
    int utf8; /* Preserve Perl's character-string flag across the XS boundary. */
    char *class_name;
    dd_shared_hash_entry *hash_entries;
    size_t hash_count;
    size_t hash_capacity;
    dd_shared_node **array_items;
    size_t array_size;
    size_t array_capacity;
    dd_shared_node *scalarref_value;
};

typedef struct {
    const void *source;
    dd_shared_node *node;
} dd_shared_import_entry;

typedef struct {
    dd_shared_import_entry *entries;
    size_t count;
    size_t capacity;
} dd_shared_import_map;

/* All shared graph operations use this process-wide native lock. */
static dd_mutex_t dd_shared_graph_mutex = DD_MUTEX_INITIALIZER;

/* Allocate one graph node; returns NULL rather than raising while locked. */
static dd_shared_node *
dd_shared_node_alloc(void)
{
    return (dd_shared_node *)calloc(1, sizeof(dd_shared_node));
}

/* Resolve a handle created by this module; returns NULL for an invalid handle. */
static dd_shared_node *
dd_shared_node_from_uv(UV handle)
{
    return INT2PTR(dd_shared_node *, handle);
}

/* Release the node's current payload without freeing aliased child nodes. */
static void
dd_shared_node_clear(dd_shared_node *node)
{
    size_t i;
    if (node->pv != NULL) free(node->pv);
    if (node->class_name != NULL) free(node->class_name);
    for (i = 0; i < node->hash_count; ++i) free(node->hash_entries[i].key);
    free(node->hash_entries);
    free(node->array_items);
    node->type = DD_SHARED_UNDEF;
    node->iv = 0;
    node->nv = 0;
    node->pv = NULL;
    node->pv_len = 0;
    node->utf8 = 0;
    node->class_name = NULL;
    node->hash_entries = NULL;
    node->hash_count = 0;
    node->hash_capacity = 0;
    node->array_items = NULL;
    node->array_size = 0;
    node->array_capacity = 0;
    node->scalarref_value = NULL;
}

/* Copy a Perl stash name onto a node; returns false on allocation failure. */
static int
dd_shared_set_class(dd_shared_node *node, const char *name)
{
    size_t length;
    if (name == NULL || *name == '\0') return 1;
    length = strlen(name);
    node->class_name = (char *)malloc(length + 1);
    if (node->class_name == NULL) return 0;
    memcpy(node->class_name, name, length + 1);
    return 1;
}

/* Return the package name of a blessed reference, or NULL for an unblessed value. */
static const char *
dd_shared_sv_class(SV *value)
{
    SV *referent;
    HV *stash;
    if (!SvROK(value)) return NULL;
    referent = SvRV(value);
    if (!SvOBJECT(referent)) return NULL;
    stash = SvSTASH(referent);
    return stash ? HvNAME(stash) : NULL;
}

/* Find a referent already imported, preserving aliases and cyclic structures. */
static dd_shared_node *
dd_shared_import_find(dd_shared_import_map *map, const void *source)
{
    size_t index;
    for (index = 0; index < map->count; ++index) {
        if (map->entries[index].source == source) return map->entries[index].node;
    }
    return NULL;
}

/* Add one referent mapping; returns false rather than raising on allocation failure. */
static int
dd_shared_import_add(dd_shared_import_map *map, const void *source,
                     dd_shared_node *node)
{
    if (map->count == map->capacity) {
        size_t capacity = map->capacity ? map->capacity * 2 : 16;
        dd_shared_import_entry *entries;
        if (capacity < map->capacity || capacity > SIZE_MAX / sizeof(*entries)) return 0;
        entries = (dd_shared_import_entry *)realloc(map->entries,
                                                     capacity * sizeof(*entries));
        if (entries == NULL) return 0;
        map->entries = entries;
        map->capacity = capacity;
    }
    map->entries[map->count].source = source;
    map->entries[map->count].node = node;
    ++map->count;
    return 1;
}

/* Grow a hash entry vector; returns false on overflow or allocation failure. */
static int
dd_shared_hash_reserve(dd_shared_node *node, size_t need)
{
    size_t capacity;
    dd_shared_hash_entry *entries;
    if (need <= node->hash_capacity) return 1;
    capacity = node->hash_capacity ? node->hash_capacity : 8;
    while (capacity < need) {
        if (capacity > SIZE_MAX / 2) return 0;
        capacity *= 2;
    }
    if (capacity > SIZE_MAX / sizeof(*entries)) return 0;
    entries = (dd_shared_hash_entry *)realloc(node->hash_entries,
                                               capacity * sizeof(*entries));
    if (entries == NULL) return 0;
    memset(entries + node->hash_capacity, 0,
           (capacity - node->hash_capacity) * sizeof(*entries));
    node->hash_entries = entries;
    node->hash_capacity = capacity;
    return 1;
}

/* Grow an array node; returns false on overflow or allocation failure. */
static int
dd_shared_array_reserve(dd_shared_node *node, size_t need)
{
    size_t capacity;
    dd_shared_node **items;
    if (need <= node->array_capacity) return 1;
    capacity = node->array_capacity ? node->array_capacity : 8;
    while (capacity < need) {
        if (capacity > SIZE_MAX / 2) return 0;
        capacity *= 2;
    }
    if (capacity > SIZE_MAX / sizeof(*items)) return 0;
    items = (dd_shared_node **)realloc(node->array_items,
                                        capacity * sizeof(*items));
    if (items == NULL) return 0;
    memset(items + node->array_capacity, 0,
           (capacity - node->array_capacity) * sizeof(*items));
    node->array_items = items;
    node->array_capacity = capacity;
    return 1;
}

/* Import a scalar value into an existing graph node. */
static int
dd_shared_import_scalar(pTHX_ dd_shared_node *node, SV *value)
{
    STRLEN length = 0;
    const char *text;
    dd_shared_node_clear(node);
    if (!SvOK(value)) return 1;
    if (SvIOK(value) && !SvNOK(value) && !SvPOK(value)) {
        node->type = DD_SHARED_IV;
        node->iv = SvIV(value);
        return 1;
    }
    if (SvNOK(value) && !SvPOK(value)) {
        node->type = DD_SHARED_NV;
        node->nv = SvNV(value);
        return 1;
    }
    text = SvPV(value, length);
    if (length == (STRLEN)-1 || length == (STRLEN)-2) return 0;
    node->pv = (char *)malloc((size_t)length + 1);
    if (node->pv == NULL) return 0;
    memcpy(node->pv, text, length);
    node->pv[length] = '\0';
    node->pv_len = length;
    node->type = DD_SHARED_PV;
    node->utf8 = SvUTF8(value) ? 1 : 0;
    return 1;
}

/* Recursively import supported Perl data references into the C-backed graph. */
static dd_shared_node *
dd_shared_import_value(pTHX_ SV *value, dd_shared_import_map *map,
                       dd_shared_node *preferred, const char **error,
                       char *error_detail, size_t error_detail_size)
{
    dd_shared_node *node = preferred;
    SV *referent;
    const char *class_name;
    if (!SvROK(value)) {
        if (node == NULL) node = dd_shared_node_alloc();
        if (node == NULL) { *error = "out of memory allocating shared node"; return NULL; }
        if (!dd_shared_import_scalar(aTHX_ node, value)) {
            *error = "out of memory storing shared scalar";
            return NULL;
        }
        return node;
    }

    referent = SvRV(value);
    {
        dd_shared_node *existing = dd_shared_import_find(map, (const void *)referent);
        if (existing != NULL) return existing;
    }
    if (node == NULL) node = dd_shared_node_alloc();
    if (node == NULL) { *error = "out of memory allocating shared node"; return NULL; }
    dd_shared_node_clear(node);
    class_name = dd_shared_sv_class(value);

    if (SvTYPE(referent) == SVt_PVHV) {
        HV *hash = (HV *)referent;
        HE *entry;
        if (!dd_shared_import_add(map, (const void *)referent, node)) {
            *error = "out of memory mapping shared hash";
            return NULL;
        }
        node->type = DD_SHARED_HASH;
        if (!dd_shared_set_class(node, class_name)) {
            *error = "out of memory storing shared object class";
            return NULL;
        }
        hv_iterinit(hash);
        while ((entry = hv_iternext(hash)) != NULL) {
            SV *key_value = hv_iterkeysv(entry);
            SV *item_value = hv_iterval(hash, entry);
            STRLEN key_length = 0;
            const char *key = SvPV(key_value, key_length);
            dd_shared_hash_entry *destination;
            dd_shared_node *child;
            if (key_length == (STRLEN)-1 || key_length == (STRLEN)-2
                || !dd_shared_hash_reserve(node, node->hash_count + 1)) {
                *error = "unable to grow shared hash";
                return NULL;
            }
            destination = &node->hash_entries[node->hash_count];
            destination->key = (char *)malloc((size_t)key_length + 1);
            if (destination->key == NULL) {
                *error = "out of memory storing shared hash key";
                return NULL;
            }
            memcpy(destination->key, key, key_length);
            destination->key[key_length] = '\0';
            destination->key_len = key_length;
            child = dd_shared_import_value(aTHX_ item_value, map, NULL, error,
                                            error_detail, error_detail_size);
            if (child == NULL) return NULL;
            destination->value = child;
            ++node->hash_count;
        }
        return node;
    }

    if (SvTYPE(referent) == SVt_REGEXP) {
        STRLEN pattern_length = 0;
        const char *pattern;
        if (!dd_shared_import_add(map, (const void *)referent, node)) {
            *error = "out of memory mapping shared regular expression";
            return NULL;
        }
        pattern = SvPV(value, pattern_length);
        if (pattern_length == (STRLEN)-1 || pattern_length == (STRLEN)-2) {
            *error = "unable to read shared regular expression";
            return NULL;
        }
        node->pv = (char *)malloc((size_t)pattern_length + 1);
        if (node->pv == NULL) {
            *error = "out of memory storing shared regular expression";
            return NULL;
        }
        memcpy(node->pv, pattern, pattern_length);
        node->pv[pattern_length] = '\0';
        node->pv_len = pattern_length;
        node->type = DD_SHARED_REGEXP;
        if (!dd_shared_set_class(node, class_name)) {
            *error = "out of memory storing shared regular expression class";
            return NULL;
        }
        return node;
    }

    if (SvTYPE(referent) == SVt_PVFM) {
        CV *format_cv = (CV *)referent;
        GV *format_gv = CvGV(format_cv);
        HV *format_stash = format_gv != NULL ? GvSTASH(format_gv) : NULL;
        const char *package_name = format_stash != NULL
            ? HvNAME(format_stash) : NULL;
        const char *format_name = format_gv != NULL
            ? GvNAME(format_gv) : NULL;
        size_t package_length;
        size_t format_length;
        size_t full_length;
        if (package_name == NULL || format_name == NULL) {
            *error = "shared format reference has no fully qualified name";
            return NULL;
        }
        if (!dd_shared_import_add(map, (const void *)referent, node)) {
            *error = "out of memory mapping shared format reference";
            return NULL;
        }
        package_length = strlen(package_name);
        format_length = strlen(format_name);
        if (package_length > SIZE_MAX - format_length - 3) {
            *error = "shared format name is too long";
            return NULL;
        }
        full_length = package_length + 2 + format_length;
        node->pv = (char *)malloc(full_length + 1);
        if (node->pv == NULL) {
            *error = "out of memory storing shared format name";
            return NULL;
        }
        memcpy(node->pv, package_name, package_length);
        memcpy(node->pv + package_length, "::", 2);
        memcpy(node->pv + package_length + 2, format_name, format_length);
        node->pv[full_length] = '\0';
        node->pv_len = (STRLEN)full_length;
        node->type = DD_SHARED_FORMAT;
        return node;
    }

    if (SvTYPE(referent) == SVt_PVAV) {
        AV *array = (AV *)referent;
        SSize_t last = av_len(array);
        SSize_t index;
        if (!dd_shared_import_add(map, (const void *)referent, node)) {
            *error = "out of memory mapping shared array";
            return NULL;
        }
        node->type = DD_SHARED_ARRAY;
        if (!dd_shared_set_class(node, class_name)) {
            *error = "out of memory storing shared object class";
            return NULL;
        }
        if (last >= 0) {
            if ((UV)last >= (UV)(SIZE_MAX / sizeof(*node->array_items))
                || !dd_shared_array_reserve(node, (size_t)last + 1)) {
                *error = "unable to grow shared array";
                return NULL;
            }
            node->array_size = (size_t)last + 1;
            for (index = 0; index <= last; ++index) {
                SV **item = av_fetch(array, index, 0);
                if (item != NULL) {
                    node->array_items[index] = dd_shared_import_value(
                        aTHX_ *item, map, NULL, error, error_detail,
                        error_detail_size);
                    if (node->array_items[index] == NULL) return NULL;
                }
            }
        }
        return node;
    }

    if (SvTYPE(referent) < SVt_PVAV) {
        if (!dd_shared_import_add(map, (const void *)referent, node)) {
            *error = "out of memory mapping shared scalar reference";
            return NULL;
        }
        node->type = DD_SHARED_SCALARREF;
        if (!dd_shared_set_class(node, class_name)) {
            *error = "out of memory storing shared object class";
            return NULL;
        }
        node->scalarref_value = dd_shared_import_value(aTHX_ referent, map,
                                                        NULL, error,
                                                        error_detail,
                                                        error_detail_size);
        return node->scalarref_value ? node : NULL;
    }

    {
        const char *type_name = sv_reftype(referent, 0);
        if (type_name == NULL) type_name = "unknown";
        (void)snprintf(error_detail, error_detail_size,
                       "share() does not support reference type %s",
                       type_name);
        *error = error_detail;
    }
    return NULL;
}

/* Replace the contents of one graph node with a Perl scalar or data graph. */
static int
dd_shared_import_into(pTHX_ dd_shared_node *destination, SV *value,
                      const char **error, char *error_detail,
                      size_t error_detail_size)
{
    dd_shared_import_map map;
    dd_shared_node *result;
    memset(&map, 0, sizeof(map));
    result = dd_shared_import_value(aTHX_ value, &map, destination, error,
                                   error_detail, error_detail_size);
    free(map.entries);
    return result != NULL;
}

/* Create a Perl scalar copy from a primitive shared node. */
static SV *
dd_shared_copy_scalar(pTHX_ const dd_shared_node *node)
{
    switch (node->type) {
        case DD_SHARED_IV: return newSViv(node->iv);
        case DD_SHARED_NV: return newSVnv(node->nv);
        case DD_SHARED_PV: {
            SV *copy = newSVpvn(node->pv ? node->pv : "", node->pv_len);
            if (node->utf8) SvUTF8_on(copy);
            return copy;
        }
        case DD_SHARED_UNDEF: return newSV(0);
        default: croak("shared value is a reference, not a scalar");
    }
    return newSV(0);
}

/* Convert a primitive graph node to Perl numeric values for arithmetic. */
static NV
dd_shared_as_nv(pTHX_ const dd_shared_node *node)
{
    SV *copy = dd_shared_copy_scalar(aTHX_ node);
    NV value = SvNV(copy);
    SvREFCNT_dec(copy);
    return value;
}

/* Convert a primitive graph node to Perl integer semantics. */
static IV
dd_shared_as_iv(pTHX_ const dd_shared_node *node)
{
    SV *copy = dd_shared_copy_scalar(aTHX_ node);
    IV value = SvIV(copy);
    SvREFCNT_dec(copy);
    return value;
}

/* Store an integer value after clearing any old primitive payload. */
static void
dd_shared_store_iv(dd_shared_node *node, IV value)
{
    dd_shared_node_clear(node);
    node->type = DD_SHARED_IV;
    node->iv = value;
}

/* Store a floating-point value after clearing any old primitive payload. */
static void
dd_shared_store_nv(dd_shared_node *node, NV value)
{
    dd_shared_node_clear(node);
    node->type = DD_SHARED_NV;
    node->nv = value;
}

/* Apply one overloaded scalar operation while the shared graph lock is held. */
static int
dd_shared_apply(pTHX_ dd_shared_node *node, const char *operation, SV *argument,
                int reverse, const char **error)
{
    NV left_nv, right_nv, result;
    IV left_iv, right_iv;
    if (node->type >= DD_SHARED_HASH) {
        *error = "numeric/string operation attempted on shared reference";
        return 0;
    }
    if (strEQ(operation, "inc")) {
        if (node->type == DD_SHARED_IV) ++node->iv;
        else dd_shared_store_nv(node, dd_shared_as_nv(aTHX_ node) + 1.0);
        return 1;
    }
    if (strEQ(operation, "dec")) {
        if (node->type == DD_SHARED_IV) --node->iv;
        else dd_shared_store_nv(node, dd_shared_as_nv(aTHX_ node) - 1.0);
        return 1;
    }
    if (strEQ(operation, "concat")) {
        SV *left = dd_shared_copy_scalar(aTHX_ node);
        STRLEN left_length = 0, right_length = 0;
        const char *left_text = SvPV(left, left_length);
        const char *right_text = SvPV(argument, right_length);
        char *buffer;
        STRLEN total;
        int utf8 = SvUTF8(left) || SvUTF8(argument);
        if (right_length > (STRLEN)-1 - left_length - 1) {
            SvREFCNT_dec(left);
            *error = "shared scalar concatenation is too large";
            return 0;
        }
        total = left_length + right_length;
        buffer = (char *)malloc((size_t)total + 1);
        if (buffer == NULL) {
            SvREFCNT_dec(left);
            *error = "out of memory concatenating shared scalar";
            return 0;
        }
        if (reverse) {
            memcpy(buffer, right_text, right_length);
            memcpy(buffer + right_length, left_text, left_length);
        }
        else {
            memcpy(buffer, left_text, left_length);
            memcpy(buffer + left_length, right_text, right_length);
        }
        buffer[total] = '\0';
        dd_shared_node_clear(node);
        node->type = DD_SHARED_PV;
        node->pv = buffer;
        node->pv_len = total;
        node->utf8 = utf8;
        SvREFCNT_dec(left);
        return 1;
    }
    if (strEQ(operation, "mod")) {
        left_iv = dd_shared_as_iv(aTHX_ node);
        right_iv = SvIV(argument);
        if ((!reverse && right_iv == 0) || (reverse && left_iv == 0)) {
            *error = "Illegal modulus zero";
            return 0;
        }
        dd_shared_store_iv(node, reverse ? right_iv % left_iv : left_iv % right_iv);
        return 1;
    }
    left_nv = dd_shared_as_nv(aTHX_ node);
    right_nv = SvNV(argument);
    if (strEQ(operation, "add")) result = reverse ? right_nv + left_nv : left_nv + right_nv;
    else if (strEQ(operation, "sub")) result = reverse ? right_nv - left_nv : left_nv - right_nv;
    else if (strEQ(operation, "mul")) result = reverse ? right_nv * left_nv : left_nv * right_nv;
    else if (strEQ(operation, "div")) {
        if ((!reverse && right_nv == 0.0) || (reverse && left_nv == 0.0)) {
            *error = "Illegal division by zero";
            return 0;
        }
        result = reverse ? right_nv / left_nv : left_nv / right_nv;
    }
    else {
        *error = "unknown shared scalar operation";
        return 0;
    }
    if (!strEQ(operation, "div") && node->type == DD_SHARED_IV
        && SvIOK(argument) && !SvNOK(argument) && !SvPOK(argument))
        dd_shared_store_iv(node, (IV)result);
    else dd_shared_store_nv(node, result);
    return 1;
}

/* Find a key in a shared hash; returns -1 when the key is absent. */
static IV
dd_shared_hash_find(dd_shared_node *node, const char *key, STRLEN key_length)
{
    size_t index;
    if (node->type != DD_SHARED_HASH) return -2;
    for (index = 0; index < node->hash_count; ++index) {
        if (node->hash_entries[index].key_len == key_length
            && memcmp(node->hash_entries[index].key, key, key_length) == 0)
            return (IV)index;
    }
    return -1;
}

/* Return a shared hash child by key, or NULL if absent. */
static dd_shared_node *
dd_shared_hash_get(dd_shared_node *node, const char *key, STRLEN key_length)
{
    IV index = dd_shared_hash_find(node, key, key_length);
    return index >= 0 ? node->hash_entries[index].value : NULL;
}

/* Find or allocate a child node for a hash key; sets an error on failure. */
static dd_shared_node *
dd_shared_hash_ensure(dd_shared_node *node, const char *key, STRLEN key_length,
                      const char **error)
{
    IV index = dd_shared_hash_find(node, key, key_length);
    dd_shared_hash_entry *entry;
    if (index == -2) { *error = "shared value is not a hash"; return NULL; }
    if (index >= 0) return node->hash_entries[index].value;
    if (!dd_shared_hash_reserve(node, node->hash_count + 1)) {
        *error = "unable to grow shared hash";
        return NULL;
    }
    entry = &node->hash_entries[node->hash_count];
    entry->key = (char *)malloc((size_t)key_length + 1);
    if (entry->key == NULL) { *error = "out of memory storing shared hash key"; return NULL; }
    memcpy(entry->key, key, key_length);
    entry->key[key_length] = '\0';
    entry->key_len = key_length;
    entry->value = dd_shared_node_alloc();
    if (entry->value == NULL) {
        free(entry->key);
        entry->key = NULL;
        *error = "out of memory allocating shared hash value";
        return NULL;
    }
    ++node->hash_count;
    return entry->value;
}

/* Return a child node from an array, or NULL for a hole or out-of-range index. */
static dd_shared_node *
dd_shared_array_get(dd_shared_node *node, IV index)
{
    if (node->type != DD_SHARED_ARRAY || index < 0
        || (size_t)index >= node->array_size) return NULL;
    return node->array_items[index];
}

/* Ensure one array slot exists and return its node, reporting allocation errors. */
static dd_shared_node *
dd_shared_array_ensure(dd_shared_node *node, IV index, const char **error)
{
    if (node->type != DD_SHARED_ARRAY) { *error = "shared value is not an array"; return NULL; }
    if (index < 0) { *error = "negative shared array index not supported for STORE"; return NULL; }
    if ((UV)index >= (UV)(SIZE_MAX / sizeof(*node->array_items))
        || !dd_shared_array_reserve(node, (size_t)index + 1)) {
        *error = "unable to grow shared array";
        return NULL;
    }
    if ((size_t)index >= node->array_size) node->array_size = (size_t)index + 1;
    if (node->array_items[index] == NULL) {
        node->array_items[index] = dd_shared_node_alloc();
        if (node->array_items[index] == NULL) {
            *error = "out of memory allocating shared array value";
            return NULL;
        }
    }
    return node->array_items[index];
}

/* Create a value safe to croak with after releasing the native shared lock. */
static void
dd_shared_error(const char *error)
{
    croak("%s", error ? error : "unknown shared data error");
}

#endif
