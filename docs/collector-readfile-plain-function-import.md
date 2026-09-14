# `Developer::Dashboard::Collector` exports a plain-function `readfile`

`Developer::Dashboard::Collector` is normally used as an object:
`Developer::Dashboard::Collector->new(paths => $paths)`, or
`->new_from_all_folders` to build one from the public path inventory
directly. For a caller that only wants one collector's latest output and
does not want to construct or hold onto that object itself, the module also
exports a plain function.

## Usage

```perl
use Developer::Dashboard::Collector qw(readfile);

my ( $stdout, $stderr, $last_run, $collector ) = readfile('my-collector');
```

`readfile` is listed in `@EXPORT_OK`, not exported by default - a bare
`use Developer::Dashboard::Collector;` imports nothing, exactly as before
this existed.

## What it does

`readfile($alias)` is a thin wrapper:

```perl
sub readfile {
    my ($alias) = @_;
    my $collector = __PACKAGE__->new_from_all_folders;
    my ( $stdout, $stderr, $last_run ) = @{ $collector->read_output($alias) }{qw(stdout stderr last_run)};
    return ( $stdout, $stderr, $last_run, $collector );
}
```

It builds a collector from the public path inventory
(`new_from_all_folders`), calls the existing `read_output($alias)` method,
and returns its `stdout`, `stderr`, and `last_run` values as a flat list -
plus the collector object itself as a fourth value, in case the caller
wants to make further calls (`read_status`, `read_log`, and so on) without
constructing a second object.

## Behaviour for a collector with no persisted state

`read_output` never dies for a name with no files on disk - it returns
empty strings for each artifact. `readfile` inherits that behaviour
unchanged: `readfile('does-not-exist')` returns `('', '', '', $collector)`,
never a thrown exception.

## Reviewing a change against this

- **`readfile` must stay a thin wrapper.** Any behavioural difference from
  calling `read_output` directly (a validation, a transform, an error case)
  belongs in `read_output` itself, or must be documented here as a
  deliberate divergence - callers should be able to treat the two as
  interchangeable except for the calling convention.
- **`@EXPORT_OK`, never `@EXPORT`.** A collector-heavy caller may need
  several unrelated identifiers named `readfile` in scope; forcing it into
  every consumer's namespace by default would be a much larger footprint
  than this module needs.
