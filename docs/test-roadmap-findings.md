# Findings — code that looks wrong

Things noticed while planning the test suite in `docs/test-roadmap.md`. **None
of these are being fixed as part of writing tests.** Pinning down what a system
currently does and changing what it does are two separate jobs, and mixing them
means you can no longer tell a real regression from an intended change.

So the tests write down the behavior *as it is today*, including the behavior
listed here. When you fix one of these, the test that pinned it will go red.
That red is the fix working — update the test, don't revert the fix.

Every entry below was reproduced by running the code, not inferred by reading
it. Each names two things in this repository that disagree with each other;
which of the two is the one to change is your call, not the plan's.

This file is added to over time and is never rewritten.

---

## F1 — `uri_for_route` refuses a route parameter whose value is `0`

Where:       lib/Dancer2/Core/App.pm:1894
Behavior:    For a route declared as `get 'item' => '/item/:id' => sub {...}`,
             `uri_for_route('item', { id => 7 })` returns
             `http://localhost/item/7` and `uri_for_route('item', { id => 'abc' })`
             returns `http://localhost/item/abc`, but
             `uri_for_route('item', { id => 0 })` dies with
             *"Route item uses the parameter 'id', which was not provided"*.
             The empty string behaves the same way. The value is tested for
             truth (`my $value = $route_params->{$param} or die ...`), so any
             false-but-present value is rejected.
Contradicts: the error message the same line raises (lib/Dancer2/Core/App.pm:1895)
             states the parameter "was not provided" — but it *was* provided.
             `0` is an ordinary database ID, list index, or page number.
Action:      decide whether a defined-but-false route parameter should be
             accepted. If it should, test the key with `exists` or the value
             with `defined` at lib/Dancer2/Core/App.pm:1894 instead of testing
             it for truth.
Pinned by:   Phase 14 — its tests lock in the current "dies on `0`" behavior.

## F2 — `%D` is documented as a log format character but is not implemented

Where:       lib/Dancer2/Core/Role/Logger.pm:126-147 (`map_chars_to_subs`)
Behavior:    A logger configured with a format containing `%D` — for example
             `log_format: '[%D] %m'` — warns *"%D not supported."* through
             `Carp` on every single message logged, and renders the field as
             `-`. Reproduced against `Dancer2::Logger::Capture`; it applies to
             every logger engine, since the formatting lives in the shared
             role.
Contradicts: the same module's own documentation, which lists `%D` as a
             supported value under the `log_format` attribute with the
             description "timer" (lib/Dancer2/Core/Role/Logger.pm, `=item %D`
             in the POD). `map_chars_to_subs` returns no `D` key.
Action:      either implement `%D` in `map_chars_to_subs`, or remove `%D` from
             the documented list. Note that anyone who followed the docs is
             currently getting a `Carp` warning per log line.
Pinned by:   Phase 13 — its tests lock in the current warn-and-render-`-`
             behavior for unrecognised format characters.

## F3 — The `Mutable` serializer's header priority is the reverse of its documentation when serializing

Where:       lib/Dancer2/Serializer/Mutable.pm:64-108
Behavior:    Given a request carrying both `Content-Type: text/x-yaml` and
             `Accept: application/json`, `serialize()` produces JSON
             (`{"a":1}`) and reports its content type as `application/json`.
             `serialize` calls `_get_content_type('accept')`, which then checks
             the headers in the order `accept`, `content_type`, `accept` — so
             `Accept` wins. (`deserialize` is unaffected: it passes
             `'content_type'`, giving the documented order.)
Contradicts: the module's own DESCRIPTION (lib/Dancer2/Serializer/Mutable.pm,
             the "it will pick the first valid content type found from the
             following list" list), which states the order as: the
             `content_type` from the request headers, then the `accept` from
             the request headers, then the `application/json` default. By that
             description the example above should produce YAML.
Action:      decide which order is correct. Arguably `Accept` *is* the right
             header to consult when choosing a response format, in which case
             the documentation is what needs changing — but the code and the
             docs currently cannot both be right.
Pinned by:   Phase 7 — its tests lock in the current "`Accept` wins when
             serializing" behavior.
