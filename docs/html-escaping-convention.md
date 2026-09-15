# HTML escaping convention

## What this is

Any code that builds an HTML string containing caller-supplied or
page-derived data (a label, a URL, a value pulled from a saved page or
skill config) must HTML-entity-escape that data before interpolating it
into the markup. This project has one established, repeated shape for
that escaping, used identically in more than one module:

```perl
sub _escape_html {
    my ($text) = @_;
    $text = '' if !defined $text;
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    return $text;
}

sub _escape_html_attr {
    my ($value) = @_;
    $value = _escape_html($value);
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&#39;/g;
    return $value;
}
```

`_escape_html` is for text that ends up as HTML element **content**
(between an opening and closing tag). `_escape_html_attr` is for text that
ends up **inside a quoted HTML attribute value** - it does everything
`_escape_html` does, plus escapes the quote characters that would
otherwise let the value break out of its surrounding `"..."` early.

## Where this lives

`Developer::Dashboard::Web::App` has the original, most complete version
(used for rendering saved pages, syntax highlighting, and several other
HTML-building paths). `Developer::Dashboard::Zipper` carries its own local
copy (added for DD-892), used by `acmdx` when building the `html` field of
its returned link bundle.

**Each copy is module-private** (not exported), matching how the original
in `Web::App` is itself private - this is a small enough utility that a
shared module has not been introduced for it. If a third module needs the
same escaping, check whether the duplication has grown large enough to be
worth extracting (see the project's own duplication-tracking precedent:
DD-762's `DirEntries.pm` extraction, and DD-888/DD-891's filed findings
about other small duplicated helpers) before adding a fourth copy.

## Why this matters

`Developer::Dashboard::Zipper::acmdx` is a public, exported function
(`our @EXPORT` includes `acmdx`) meant for skill and bookmark page authors
to build clickable ajax-triggering links from their own page data. Before
DD-892, its `html` field was built via a bare `sprintf` with no escaping
at all - a label or target value containing HTML metacharacters (`<`, `>`,
`"`) could break out of its attribute or content position and inject
arbitrary markup, including a `<script>` tag or an `onerror`-bearing
attribute. Since that page data can itself originate from saved page
content or skill configuration - not necessarily something the developer
wrote by hand - this was a genuine stored/reflected XSS vector, not merely
a theoretical one.

## Where this is exercised

`t/85-zipper-coverage.t` covers `acmdx`'s escaping directly (added for
DD-892: a label containing `</a><script>...` and a target containing
`"><img ... onerror=...>`, both asserted to survive only as
entity-escaped text, never as literal markup in the returned `html`
field).
