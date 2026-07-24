# Findings — code that looks wrong

Things noticed while planning the test suite in `paad/test-roadmap/test-roadmap.md`. **None
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

## F4 — `Dancer2::Handler::File` serves files from outside `public_dir`

Where:       lib/Dancer2/Handler/File.pm:98-105
Behavior:    With the `File` route handler enabled
             (`route_handlers: [[ File => { public_dir => ... } ]]`), a request
             for `/../secret.txt` is answered `200` with the contents of a file
             one directory above `public_dir`. The handler joins `public_dir`
             with the request path and then only asks whether the result is a
             readable file — it never asks whether the result is still inside
             `public_dir`. `Path::Tiny::path` does not collapse `..`, so the
             joined path escapes and `-f` is happy with it.
Contradicts: two places in this same distribution:
             (a) `lib/Dancer2/Core/App.pm:1180-1182`, the `send_file` code path,
             which performs exactly the missing check — commented "We need to
             check whether they are trying to access a directory outside their
             scope" — and answers 403; and
             (b) `lib/Dancer2/Handler/File.pm:100` itself:
             `return $self->standard_response( $app, 403 ) if !defined
             $file_path_str;` — a 403 guard on the result of
             `Path::Tiny::stringify`, which never returns undef. That branch is
             unreachable, so the containment refusal the code appears to make is
             never actually made.
Action:      decide whether line 100's dead 403 guard was meant to be the
             containment check. If so, replace it with the same test
             `send_file` uses — `$dir->realpath->subsumes($file_path)` — so
             both file-serving paths agree.
Pinned by:   Phase 3 — the subtest "Dancer2::Handler::File does not contain ../
             paths (known bug)" in t/integration/handler/file.t locks in the
             current 200-and-disclose behavior. Adding the check turns that
             subtest red; that red is the fix landing, not a regression.

## F5 — The default static handler warns and 404s on a NUL in the path where `Handler::File` returns 400

Where:       lib/Dancer2/Core/App.pm:1587-1594
Behavior:    A request for `/hello.txt\0.png` against an application using the
             default static handler emits a warning from `Path::Tiny` —
             `Invalid \0 character in pathname for ftis: .../hello.txt\0.png` —
             and is then answered `404` by the application. The warning comes
             from the middleware's file-existence condition calling
             `->child( $env->{PATH_INFO} )->is_file` on the unvalidated path.
             Nothing is disclosed, but an attacker-supplied path reaches the
             server's log as a warning on every such request.
Contradicts: lib/Dancer2/Handler/File.pm:90-92, the other static-file path in
             this distribution, which checks `$path =~ /\0/` first and answers
             `400 Bad Request` without touching the filesystem.
Action:      decide which of the two responses is correct for a NUL-bearing
             path and make both paths agree — most likely by moving the
             existing `/\0/` check ahead of the `is_file` condition in
             `App::to_app` so the request is rejected before Path::Tiny is
             asked about it.
Pinned by:   Phase 3 — the subtest "a null byte in a static path is survived,
             not served" in t/integration/handler/file.t asserts both the 404
             and the single warning. Unifying the two paths turns it red.

## F6 — Content assigned a second time is never encoded, while the response still claims a charset

Where:       lib/Dancer2/Core/Response.pm:162 (the guard), with
             lib/Dancer2/Core/Response.pm:137-151 (the wrapper it defeats)
Behavior:    With `charset` set to UTF-8, assigning `content` twice leaves the
             second value unencoded. `$response->content('first')` encodes and
             latches `is_encoded`; the following
             `$response->content("hi\x{263A}")` returns the character string
             untouched, because `encode_content` begins with
             `return $content if $self->is_encoded`. The resulting PSGI body
             still holds a wide character, `Content-Length` is 3 (the character
             count) rather than the 5 bytes UTF-8 needs, and the response's own
             `Content-Type` still says `charset=UTF-8`.
             This is reachable from ordinary application code: an `after` hook
             that rewrites `response->content`, or `halt($content)` called once
             content had already been set.
Contradicts: the response contradicts itself in a single object — the
             `Content-Type` header it sets at
             lib/Dancer2/Core/Response.pm:192 announces `charset=UTF-8` while
             the body it emits at lib/Dancer2/Core/Response.pm:243 is not
             UTF-8 encoded, and the `Content-Length` computed at
             lib/Dancer2/Core/Response.pm:237 counts characters rather than the
             bytes that header promises. Separately, the `around content`
             modifier at lib/Dancer2/Core/Response.pm:137-151 routes *every*
             assignment through `encode_content`, which the line 162 guard then
             makes a no-op for all assignments after the first.
Action:      decide whether `is_encoded` is a property of the response or of the
             content currently assigned to it. If the latter, clear it in the
             `around content` modifier before calling `encode_content`, so each
             fresh assignment is encoded on its own merits — leaving the
             externally-set uses (`Handler/File.pm:138`, `Core/App.pm:1249`,
             which mark already-read bytes) working as they do now.
Pinned by:   Phase 6 — the subtest "replacing the content after the first set
             leaves it unencoded (known bug)" in t/unit/core/response.t locks in
             the current character body and character-count Content-Length.
             Fixing the code turns that subtest red; that red is the fix.

## F7 — `headers_to_array` sanitises header values but not header names

Where:       lib/Dancer2/Core/Response.pm:63-76
Behavior:    `$response->header("X-Bad\r\nInjected: yes" => 'v')` produces a
             PSGI header array in which one element still contains a literal
             CRLF: `to_psgi` returns the name `X-Bad\r\nInjected: Yes` verbatim.
             The equivalent injection through a header *value* is stripped, so
             only the name is exposed. Whether the CRLF then reaches the wire
             depends on the PSGI server — some validate header names, many do
             not — so this is stated as "reaches the PSGI array unsanitised",
             which is demonstrable, rather than as a confirmed wire-level split.
Contradicts: the same loop, two lines apart. Lines 70-71 apply
             `s/\015\012[\040|\011]+/chr(32)/ge` and `s/\015|\012//g` to `$v`,
             the second commented "remove CR and LF since the char is invalid
             here" — while `$k`, pushed onto the same array at line 72, has
             nothing applied to it. The function states the invariant for one
             half of each header pair and not the other.
Action:      apply the same two substitutions to `$k`, or reject a header name
             containing CR or LF outright. Rejecting is arguably better here: a
             header name with a newline in it is never legitimate, whereas a
             value can plausibly arrive folded.
Pinned by:   Phase 6 — the subtest "CR and LF survive in a header name (known
             bug)" in t/unit/core/response.t asserts that exactly one element of
             the PSGI header array still contains CRLF. Sanitising the name
             turns it red. The companion subtest "CR and LF are stripped from
             header values" pins the half that already works, so a fix that
             breaks the value path would be caught too.

## F8 — A `charset` parameter on `Content-Type` defeats the `Mutable` serializer's format lookup

Where:       lib/Dancer2/Serializer/Mutable.pm:96-97
Behavior:    `POST` with `Content-Type: text/x-yaml` and the body `---\na: 1\n`
             is deserialized as YAML and answered 200. The identical request
             with `Content-Type: text/x-yaml; charset=utf-8` is answered **400**.
             The lookup is an exact hash-key match on the raw header value
             (`$self->mapping->{$value}` where
             `$value = $self->request->header($method)`), so the parameter makes
             the key miss, the fallback selects JSON, and JSON is then handed a
             YAML body and fails the request.
             The same miss happens on `Accept`: `Accept: text/x-yaml;
             charset=utf-8` silently returns JSON instead of YAML.
             JSON escapes notice only by accident — the fallback when the lookup
             misses *is* JSON, so `application/json; charset=utf-8` still works
             and hides the defect for the most common case.
Contradicts: this distribution elsewhere treats a content-type header as a type
             plus separable parameters. `lib/Dancer2/Core/Response.pm:169` calls
             `$self->headers->content_type_charset` precisely to split the
             charset off the type, and `HTTP::Headers`' own `content_type`
             accessor (used throughout Plack, on which this distribution
             depends) strips parameters and lowercases. `Mutable.pm:96` instead
             uses the whole raw header, parameters included, as a hash key.
             Separately, the module's own documented mapping table lists bare
             content types (`text/x-yaml`, `application/json`, ...), naming them
             "content types" rather than exact header values.
Action:      normalise before the lookup — split the header on `;`, trim, and
             lowercase (or read it through `HTTP::Headers`' `content_type`
             accessor, which already does this) — then match against the
             mapping. Note this interacts with F3: both live in
             `_get_content_type`, so fixing them together is likely cheaper than
             separately.
Pinned by:   Phase 7 — the subtest "a charset parameter on Content-Type breaks
             the lookup (known bug)" in t/integration/serializer/mutable.t pins
             the 400, the silent JSON fallback on `Accept`, and the control case
             that works without the parameter. Normalising the lookup turns it
             red; that red is the fix.
