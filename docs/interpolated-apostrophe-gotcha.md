# The interpolated-apostrophe gotcha in test descriptions

A specific Perl parsing trap that has landed in this codebase's test
descriptions, what it silently breaks, and how to avoid it. This page
describes the pattern, not any one ticket.

## The trap

Perl still recognizes `'` as an OLD PACKAGE SEPARATOR inside a
double-quoted (or interpolating) string. Writing a variable directly
followed by a possessive apostrophe -

```perl
"$pkg's $HELPER IS the shared one, not a local copy"
```

- parses `$pkg's` as `$pkg::s`: the package `$pkg`'s value, followed by
  `::s`, not the loop variable `$pkg` followed by an apostrophe. `$pkg::s`
  does not exist, so this interpolates to nothing, and Perl emits three
  warnings pointing at it (`Old package separator used in string`, `Name
  "pkg::s" used only once`, `Use of uninitialized value $pkg::s`).

## Why it is worse than noise (DD-692)

When this appears inside a loop generating a test description, every
iteration silently swallows the loop variable and produces the **same**
description with the variable's slot empty:

```
" _drain_ready_handle IS the shared one, not a local copy"
```

identical on every pass. The assertion itself still runs correctly - only
its identification is broken - which means a failure gives no clue *which*
iteration failed, defeating the entire purpose of looping to generate
per-item descriptions. Two identical test names in one file also make TAP
output ambiguous to anything parsing it.

## How to avoid it

Escaping the apostrophe (`"$pkg\'s ..."`) fixes the parse but is fragile -
easy to miss on the next edit, and it doesn't read well. **Prefer
rephrasing to avoid a variable immediately followed by `'s` entirely:**

```perl
"the $HELPER reached by $pkg IS the shared one, not a local copy"
```

## How to apply

Before writing an interpolated string with a possessive apostrophe
immediately after a variable, rephrase it. If you see `perl -c` warn "Old
package separator used in string", that is this exact trap - the fix is
almost always to remove the construct, not to escape it.
