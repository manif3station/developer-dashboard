# PageRuntime's `func` and `method` template helpers call subs differently

Saved-page and skill templates rendered by `Developer::Dashboard::PageRuntime`
have two ways to call out to a Perl sub from Template Toolkit: `method(...)`
and `func(...)`. Both take the same three arguments - a class/package name,
a sub name, and the arguments to pass - and both apply the same
availability check (`$class->can($method)`), but they invoke the resolved
sub differently.

## `method("Package", "sub", @args)` - calls it as an instance/class method

```perl
method => sub {
    my ( $class, $method, @rest ) = @_;
    return '' if !$class || !$method || !$class->can($method);
    return $class->$method(@rest);
},
```

`$class->$method(@rest)` is a normal Perl method call - Perl prepends
`$class` as the implicit first argument (`$_[0]`) to whatever `sub`
resolves to. Use this for a sub written the way object/class methods
normally are, expecting its own invocant first.

## `func("Package", "sub", @args)` - calls it as a plain function

```perl
func => sub {
    my ( $class, $method, @rest ) = @_;
    return '' if !$class || !$method || !$class->can($method);
    return UNIVERSAL::can( $class, $method )->(@rest);
},
```

`UNIVERSAL::can($class, $method)` resolves to the same coderef `method()`
would call - but `func` invokes that coderef directly, with only `@rest`
as arguments. No implicit invocant is prepended. Use this for a sub
written to be called as a plain function, where the first argument is
real data rather than a class name.

## Why both exist

A sub's own signature decides which helper is correct - there is no way
to tell from the template alone. Calling a plain-function sub through
`method()` accidentally hands it the class name as its first real
argument; calling an instance-method-shaped sub through `func()` loses
the invocant it expects. Picking the wrong one produces a subtly wrong
result, not an error - `$class->can($method)` succeeds for both cases
equally, since availability doesn't depend on calling convention.

## Reviewing a change against this

- **Both helpers apply identical validation** (empty class, empty method
  name, or a method `can` doesn't resolve all return an empty string).
  Any future change to one's validation logic should apply the same
  change to the other, or document why they diverge.
- **When adding a new template-callable sub, decide its calling
  convention up front** and document which helper it's meant to be
  called through - the same way this page exists so the next person
  doesn't have to guess from the two nearly-identical implementations.
