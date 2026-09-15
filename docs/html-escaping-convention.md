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

`Developer::Dashboard::HtmlEscape` holds the canonical pair (DD-898,
extracting what were until then two identical private copies:
`Developer::Dashboard::Web::App`'s original, most complete version, used
for rendering saved pages, syntax highlighting, and several other
HTML-building paths; and `Developer::Dashboard::Zipper`'s local copy,
added for DD-892 and used by `acmdx` when building the `html` field of its
returned link bundle). Both modules now `use Developer::Dashboard::HtmlEscape
qw(_escape_html _escape_html_attr)` and define no private copy of their
own - matching this project's own duplication-tracking precedent (DD-762's
`DirEntries.pm`, and DD-888/DD-891/DD-894's own extractions of the same
shape). A third module needing this escaping simply imports it the same
way; no extraction decision is needed since the shared module already
exists.

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

## A sibling context: escaping for a JS string, not HTML

DD-895 found the same defect shape one output-context over. HTML-entity
escaping (`_escape_html`/`_escape_html_attr`) protects data landing inside
HTML markup; it does nothing for data landing inside a **JS string
literal** written directly into a `<script>` block - a single quote there
needs `_js_single_quote` (already present in `Zipper.pm`), not
`_escape_html`, because the injection boundary is the JS string's own
quote character and the `</script>` tag, not an HTML tag or attribute.

`Ajax()`'s two `<script>set_chain_value(...)</script>` call sites
interpolate `jvar`'s split `$path` component into a single-quoted JS
string slot, but - unlike `$args{singleton}` two lines away in the same
`sprintf` - never routed it through `_js_single_quote`. A `jvar`
containing a single quote and a `</script>` sequence broke out of the
surrounding script tag entirely, confirmed by live reproduction inside a
`developer-dashboard:latest` container (see DD-895's card for the exact
payload and output).

**The general lesson**: this file's `_escape_html`/`_escape_html_attr`
pair is the right tool for HTML markup, and a *different* escaper
(`_js_single_quote`) is the right tool for a JS string literal inside a
`<script>` tag - using the HTML pair (or no escaper at all) for the
latter context does not protect it. When auditing a `sprintf`/`qq{}`
block for unescaped interpolation, identify the OUTPUT CONTEXT of each
`%s` slot first (HTML content, HTML attribute, JS string, JS bare
expression, URL) - each has its own correct escaper, and applying the
wrong one (or none) leaves that slot exploitable even while a sibling
slot two lines away is handled correctly.
