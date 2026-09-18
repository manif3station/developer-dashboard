# Extracting a cohesive helper cluster from an oversized module

How this project splits a module that has grown past its 500-line
guideline without breaking any existing caller, and how to confirm a
candidate cluster is actually safe to move before touching anything.

## The pattern

1. **Find a cluster of subs that only call each other, and never touch
   the object's own instance state.** Confirm this by grepping the
   candidate line range for `$self->{` - zero hits means every value the
   cluster needs arrives through its own arguments, not the object it
   happens to be called on. A cluster that also calls `$self->_sibling`
   methods *within the same range* is still safe; a cluster that reaches
   outside itself into unrelated object state is not a clean cut.
2. **Move the cluster's subs into a new sibling module as plain
   functions** (drop the `$self` argument if the subs never needed it for
   anything but dispatch). Give the new module full `FULL-POD-DOC` POD -
   it is a first-class module now, not a fragment.
3. **Leave a thin one-line forwarder at every original call site**, so
   nothing outside the module - other lib/ code, tests, anything calling
   the old fully-qualified name - has to change:

   ```perl
   sub _run_command { shift; return Developer::Dashboard::CommandRunner::run_command(@_); }
   ```

4. **Full-suite regression before and after**, in a real Docker container,
   is the actual verification - not just "the new module compiles." A
   forwarder that silently drops an argument or changes call order is
   invisible to a syntax check and only shows up as a behavior change.

## Precedent

This is the same shape Tira's own team used for the identical problem on
their own board (`TKT-1103`, reviewed here as DD-937): `Tira::CLI::Police`
and `Tira::CLI::Serve` both crossed their line-count cap, and the fix was
exactly this - lift a genuinely cohesive, low-coupling helper cluster
(`police_world` and its own machine-reading helpers) into a new sibling
module, with one-line forwarders kept at every call site several existing
tests still used by fully-qualified name.

`DD-947` (extracting `CollectorRunner.pm`'s command-execution cluster -
`_run_command`, `_await_windows_command`, `_spawn_windows_command`,
`_record_command_pid`, `_command_launcher_argv`, `_command_pid_from_file`,
`_await_command_pid`, `_forward_command_signal`,
`_terminate_command_process`, `_exit_code_from_status` - into
`Developer::Dashboard::CommandRunner`) is this project's own first
application of the pattern, tracked as part of the wider oversized-module
finding `DD-641`.

## How to apply

- Before extracting anything, run the `$self->{` grep on the exact
  candidate line range and read the result yourself - do not assume a
  sub "looks stateless" from its name or purpose alone.
- Watch for subs in the same textual neighborhood that are actually a
  *different* concern (DD-947's own research first assumed a 277-line
  range including `_run_code`/`_shutdown_loop`/`_signal_stop`, then
  corrected to 241 lines after reading those three and finding they were
  in-process eval-with-alarm execution and collector-loop lifecycle, not
  command spawning at all) - proximity in the file is not the same as
  cohesion.
- Prefer plain functions over methods when the cluster never needed
  `$self` for anything but being called as `$obj->method(...)` - it makes
  the "does this touch instance state" question permanently answerable by
  reading the function signature alone, for every future reader.
- A module this large (CollectorRunner.pm was 1963 lines) rarely has just
  one clean extraction. Take the largest confirmed-safe cluster first,
  re-measure the remaining overage, and treat the next cluster as its own
  ticket rather than trying to plan the whole decomposition up front.
