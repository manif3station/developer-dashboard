# Indicator strip sort ordering

## What this is

The web status strip and `dashboard ps1` prompt render a row of indicators
(docker status, git branch, project name, collector-managed indicators,
skill-contributed indicators, etc). The order they appear in is decided by
`Developer::Dashboard::IndicatorStore::_indicator_sort_cmp`, a `sort {}`
comparator used wherever the full indicator set is rendered.

## Sort keys, in order

1. **`priority`** - an integer. **Lower sorts first.** This is the primary,
   almost-always-decisive key. The built-in indicators registered by
   `refresh_core_indicators` use `docker => 20`, `git => 30`,
   `project => 50` - small numbers, deliberately leaving room for other
   indicators (built-in or skill-contributed) to slot in before, between,
   or after them by choosing their own priority value.
2. **`collector_order`** (only compared when both indicators are
   collector-managed) - same low-sorts-first convention, used to keep a
   single collector's own multiple indicators in a stable relative order
   against each other.

## The `priority => 0` case

`priority => 0` is not a placeholder or an error value - it is the
smallest priority a skill author or collector config can express, and by
the low-sorts-first convention above, it is the value someone reaches for
when they want their indicator to appear **first**, ahead of even the
built-in `docker`/`git`/`project` indicators.

**This must be read with `defined($priority) ? $priority : 999`, never
`$priority || 999`.** Perl's `||` treats `0` as false, so a bare `||`
fallback silently converts an explicit "sort me first" into "sort me last"
(999 is the fallback used for indicators that never set a priority at
all). This is exactly backwards from what the value means, and the defect
is silent - nothing errors, the indicator simply renders in the wrong
place with no diagnostic.

`_indicator_sort_cmp`'s own `collector_order` comparison, two lines below
the `priority` comparison in the same function, already uses the correct
`defined(...) ? ... : 999` form - that is the pattern to follow for any
future field added to this comparator whose valid range includes `0`.

## Where this is exercised

`t/02-indicator-collector.t` covers the indicator ordering contract
generally. `t/186-indicator-sort-cmp-zero-priority.t` (added for DD-885)
covers the `priority => 0` case specifically, including that it still
correctly outranks an indicator with no priority set at all, and that
ordering among positive-priority indicators and the unset-priority
fallback are both unaffected by the fix.
