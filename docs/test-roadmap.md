# Test roadmap — Dancer2

A phased plan for building this project a test suite that catches real
regressions. Work one phase at a time; each phase says what breakage it would
turn red for.

The companion document `docs/test-suite-analysis.md` records the state of the
suite when this plan was written, and the list of stand-ins and fixtures the
plan expects to use. `docs/test-roadmap-findings.md` lists code that looks
wrong and is deliberately *not* being fixed by these tests.

## Decisions

Settled once, at plan time. These are not re-asked on later runs.

**Starting point:** this repository had no test suite when the plan was
written — no `t/` directory, and nothing test-related tracked in git. Every
phase below is new work.

**Testing toolkit:** `Test::More`, with `Test::Fatal`/`Test::Exception` for
"does this die?" checks and `Capture::Tiny` for grabbing output. Chosen because
all four are already declared test dependencies in `cpanfile`, they work on
Perl 5.14 (this project's stated floor), and `CLAUDE.md` already documents
`Test::More` as the convention. Not `Test2::V0` — it would add a dependency to
a widely-installed CPAN distribution.

**HTTP-level testing:** `Plack::Test` with `HTTP::Request::Common`. Not
`Dancer2::Test` — that module ships in this distribution but deliberately dies
with *"DEPRECATED: Dancer2::Test. Please use Plack::Test instead"*. `Plack` is
already a hard runtime dependency, so this adds nothing.

**Build order:** riskiest behavior first — dispatch, sessions, character
encoding, and file-path containment before the small self-contained classes.
Whole-request tests (`Plack::Test`) are used wherever dispatch behavior is what
is being checked, so the realism of end-to-end testing is available without
giving up the ability to say *which* behavior broke.

**Test organization:** this is a Perl distribution, so tests live in an
external `t/` tree and each tier is selected by its directory — `t/unit/`,
`t/integration/`, `t/e2e/`. This follows the ecosystem's convention; it was
detected, not chosen.

**Test applications:** declared inline in each test file
(`package MyApp { use Dancer2; ... }`). Dancer2 registers an application per
package at import time, so no separate fixture app directory is needed.

**Coverage tooling:** `Devel::Cover` 1.52 is installed and the `cover` command
is on `PATH`. It is used **only** to find code with no test at all — never as
evidence that a test is any good. Note that when this plan was written there
were no tests to run it against, so the gaps below were identified by reading
the source, not by running a coverage tool.

Tiers (run | coverage):

- unit:
  `prove -lr t/unit`
  | `HARNESS_PERL_SWITCHES='-MDevel::Cover=-db,cover_db/unit,-select,^lib/,-ignore,\.t$' prove -lr t/unit && cover -report text -silent cover_db/unit`
- integration:
  `prove -lr t/integration`
  | `HARNESS_PERL_SWITCHES='-MDevel::Cover=-db,cover_db/integration,-select,^lib/,-ignore,\.t$' prove -lr t/integration && cover -report text -silent cover_db/integration`
- e2e:
  `prove -lr t/e2e`
  | (none — this tier runs the `dancer2` command-line tool as a separate
  process, which `Devel::Cover` cannot follow reliably)

Both coverage commands above were run and confirmed working before being
recorded here. `cover_db/` is already git-ignored.

**Whole-suite command:** `prove -lr t/` continues to work and runs all three
tiers, as `CLAUDE.md` describes.

**Before merging upstream:** once the accumulated tests on the working branch
are ready to go up, running `agentic-review` over that branch is recommended.
That has to happen in a fresh session, so it is not part of executing these
phases.

---

## Phase 1: Route pattern compilation and matching

Tier:     unit
Catches:  a `:token` capturing across a `/` so `/user/:id` matches
          `/user/1/2`; a `.` in a route path being treated as a regex wildcard
          so `/file.txt` matches `/fileXtxt`; a `**` megasplat not splitting
          its capture on `/`; a typed token `:id[Int]` accepting a
          non-integer; a route prefix not being prepended; the deprecated
          names `:splat` and `:captures` silently working instead of dying;
          a route `options` condition (`agent`, `content_type`) failing to
          reject a non-matching request.
Produces: t/unit/core/route.t
Branch:   ovid/test-roadmap
Landed:   2026-07-24 bb2689e (alter a constant; negate a condition; drop a
          state transition; flip a comparison)

## Phase 2: Dispatch flow control — pass, halt, forward, redirect

Tier:     integration
Catches:  `pass` leaking the first route's content or its leftover `splat`
          parameters into the second route; `halt` still running `after`
          hooks; `forward` losing the request body, the added parameters, or
          the session cookie; `forward` with `{ method => 'GET' }` not
          changing the method; `redirect '/x'` not prefixing the mount path
          when the app is mounted somewhere other than `/`; an unsupported
          HTTP verb returning something other than 405.
Produces: t/integration/dispatch/flow.t
Branch:   ovid/test-roadmap
Landed:   2026-07-24 24e4afa (negate a condition; drop a state transition;
          alter a constant)

## Phase 3: File serving and path containment

Tier:     integration
Catches:  `send_file` with a `../../` path escaping the public directory and
          returning file content instead of 403; a null byte in a static file
          path returning something other than 400; a request for a file that
          exists but is unreadable returning 200 instead of 403; a request for
          a missing static file failing to fall through to the next route
          instead of 404-ing immediately; `send_file` dropping the
          `Content-Disposition` filename.
Produces: t/integration/handler/file.t
Branch:   ovid/test-roadmap
Findings: F4 (Handler::File serves files outside public_dir),
          F5 (NUL in a static path warns and 404s on one code path, 400s on the
          other)
Landed:   2026-07-24 78b5e6f (negate a condition; alter a constant)

## Phase 4: Session lifecycle and cookie header

Tier:     integration
Catches:  session data surviving `destroy_session`; `change_session_id`
          losing the session's data or leaving the old ID in the response
          cookie; the session cookie being emitted without `HttpOnly`, or
          without `Secure`/`SameSite` when those are configured; a session
          that was never modified triggering a write to the backend on every
          request; a request carrying a session cookie for a session that no
          longer exists blowing up instead of starting a fresh session.
Produces: t/integration/session/lifecycle.t
Branch:   ovid/test-roadmap
Landed:   2026-07-24 71747d6 (drop a state transition; flip a comparison;
          negate a condition)
## Phase 5: Request parameter decoding and precedence

Tier:     unit
Catches:  a route parameter failing to take precedence over a query or body
          parameter of the same name in `params`; a repeated query parameter
          collapsing to a single value instead of a list; UTF-8 in a query
          string or path coming back as raw bytes; invalid UTF-8 crashing the
          request in lenient mode (it should warn and pass the bytes through)
          or *not* crashing it when `strict_utf8` is on; `splat` and
          `captures` leaking into `route_parameters`; `forward`'s request
          clone losing already-decoded body parameters.
Produces: t/unit/core/request.t
Branch:   ovid/test-roadmap
Landed:   2026-07-24 3139f55 (drop a state transition; negate a condition;
          alter a constant)
## Phase 6: Response encoding and PSGI conversion

Tier:     unit
Catches:  text content being character-encoded twice; a charset being
          appended to a non-`text/*` content type; `Content-Length` reporting
          character count instead of encoded byte count; a 204 or 304
          response carrying a body; a response with no content type set
          losing its configured default; headers containing a newline
          reaching the PSGI array unsanitised (a response-splitting hole).
Produces: t/unit/core/response.t
Branch:   ovid/test-roadmap
Landed:

## Phase 7: Serializer round-trip and failure handling

Tier:     integration
Catches:  a malformed JSON request body returning 500 instead of 400; a
          serialized response coming back with `text/html` instead of the
          serializer's own content type; the `Mutable` serializer picking the
          wrong format for a given `Content-Type`/`Accept` pair, or failing to
          fall back to JSON when neither is recognised; a GET request being
          deserialized when it should not be; a `multipart/form-data` upload
          being run through the deserializer.
Produces: t/integration/serializer/
Branch:   ovid/test-roadmap
Landed:

## Phase 8: Error rendering and sensitive-value censoring

Tier:     integration
Catches:  a stack trace appearing on a 4xx response when `show_stacktrace` is
          on (it should only appear on 5xx); a value under a key like
          `password` or `card_number` appearing uncensored in the error page's
          settings or session dump; an error template that itself throws
          taking down the 500 handler instead of falling back to the static
          page or the built-in one; an error message containing HTML being
          rendered unescaped into the error page.
Produces: t/integration/error/
Branch:   ovid/test-roadmap
Landed:

## Phase 9: Hook chain and hook exception handling

Tier:     integration
Catches:  a `before` hook that dies producing a 500 without firing the
          `on_hook_exception` and `on_route_exception` hooks; a hook that sets
          a response and halts having that response overwritten by the
          error handler; hooks continuing to run after the response was
          halted; a hook registered for an engine (`before_template_render`)
          never reaching that engine; a hook registered before its engine
          exists being dropped instead of applied when the engine is built.
Produces: t/integration/hooks/
Branch:   ovid/test-roadmap
Landed:

## Phase 10: Template rendering, layout, and default tokens

Tier:     integration
Catches:  `layout => 0` in the options failing to suppress the layout, or a
          named layout in the options being ignored in favour of the
          configured one; the `session`, `params`, `vars`, or `settings`
          tokens missing from a rendered view; a view that produces no content
          returning empty instead of raising "Template did not produce any
          content"; the auto-page handler serving a file out of the layouts
          directory as if it were a page.
Produces: t/integration/template/
Branch:   ovid/test-roadmap
Landed:

## Phase 11: Configuration loading, merging, and strict-key warnings

Tier:     unit
Catches:  an environment-specific config failing to override the base config,
          or overriding a whole nested block instead of merging into it; the
          recursion guard on `additional_config_readers` not firing (an
          infinite config loop instead of a clear error); `strict_config`
          failing to warn about an unrecognised top-level key or an
          unrecognised per-engine key; `strict_config_allow` not suppressing a
          warning for a key it lists; an unsupported engine name in `engines:`
          being accepted silently.
Produces: t/unit/configreader/
Branch:   ovid/test-roadmap
Landed:

## Phase 12: Cookie and time-expression formatting

Tier:     unit
Catches:  `expires => '2 hours'` emitting the literal string instead of a GMT
          date; an unparseable expression being silently converted to
          something wrong rather than passed through unchanged; a
          multi-value cookie losing values or failing to escape them; the
          `Secure`, `HttpOnly`, `SameSite`, `Path`, or `Domain` attributes
          being dropped from the generated header; `http_only => 0` still
          emitting `HttpOnly`.
Produces: t/unit/core/cookie.t
Branch:   ovid/test-roadmap
Landed:

## Phase 13: Logger level filtering and message formatting

Tier:     unit
Catches:  a message below the configured level still being emitted (or one at
          or above it being swallowed); internal `core`-level messages
          appearing in normal output; `%m`, `%L`, `%a`, or `%i` not being
          substituted in the log format; an unrecognised format character
          aborting the log call instead of warning and rendering `-`; a
          `%{Header}h` lookup failing to read the named request header.
Produces: t/unit/logger/
Branch:   ovid/test-roadmap
Landed:

## Phase 14: Multi-app dispatch and URL generation

Tier:     integration
Catches:  a request that no route in the first app matches never being
          offered to the second app; a "real" 404 from the first app being
          treated as "no match" and leaking through to the second; a forward
          crossing between apps losing the session; `uri_for_route` producing
          a URL with an unsubstituted `:token` in it instead of failing;
          `uri_for_route` on a regex route silently producing garbage rather
          than refusing; a mounted app's `uri_for` dropping its mount path.
Produces: t/integration/dispatch/multiapp.t
Branch:   ovid/test-roadmap
Landed:

## Phase 15: The `dancer2 gen` scaffold produces a working application

Tier:     e2e
Catches:  the generated application failing to compile; `share/skel` losing a
          file the generated app needs at runtime (a view, a layout, the
          config, the `.psgi` entry point); the generated app's own bundled
          tests failing; `--path` or `-a` writing the application to the wrong
          directory or under the wrong package name.
Produces: t/e2e/cli/gen.t
Branch:   ovid/test-roadmap
Landed:
