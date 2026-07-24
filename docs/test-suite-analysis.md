# Test suite analysis — Dancer2

Companion to `docs/test-roadmap.md`. This file records the state of the test
suite when the roadmap was written, and the stand-ins and fixtures the plan
expects to use.

## State of the suite

**There is no test suite.** At the time this was written the repository had:

- no `t/` directory,
- no `xt/` directory (the author-only checks — perlcritic, whitespace, POD —
  that `CLAUDE.md` describes are also absent),
- no test files tracked in git anywhere,
- a single commit, "Testing the roadmap skill".

Because there were no tests, there was nothing to grade. No weak tests were
found, because no tests were found.

The `.t` files under `share/skel/` are **not** this project's tests. They are
part of the scaffold template that `dancer2 gen` copies into a newly created
application, so they are shipped source, not tests of Dancer2 itself. Phase 15
of the roadmap runs them as part of checking that the scaffold works.

### The leftover coverage database

There is a `cover_db/` directory in the working tree containing an HTML
coverage report. It is stale and was not used:

- It refers to test files that do not exist — `t/unit/logger/logger.t`,
  `t/integration/template/rendering.t` — so it was produced by an earlier
  run against tests that have since been deleted.
- Coverage numbers would not have been used as a quality signal in any case.
  Coverage answers "is there any test touching this line", which it does well.
  It never answers "is that test any good" — a line can be fully covered by a
  test that checks nothing at all.

It is already listed in `.gitignore` and can be deleted.

## What the plan checked for, and what it found instead

**Was there a way to build test data?** No — no fixtures directory, no factory
module, no seed script, nothing. This does not block any phase, because the
data these tests need is small and local: temporary directories for views,
public files, and session files, built with `File::Temp` and `Path::Tiny`
inside each test. Both are already runtime dependencies of this project.

**Was there a coverage tool?** Yes, `Devel::Cover` 1.52. It could not be used
for gap-finding here, because with no tests there is nothing to measure. The
untested behaviors listed in the roadmap were therefore identified by reading
the source, not by running a tool. Once phases start landing, the per-tier
coverage commands recorded in the roadmap's `## Decisions` section become
useful for spotting code no phase has reached yet.

**How does this project separate test tiers?** It doesn't yet, but Perl's
convention is an external `t/` tree selected by directory, so the roadmap uses
`t/unit/`, `t/integration/`, and `t/e2e/`. Each is independently runnable and
independently coverage-runnable; the exact commands are in the roadmap.

## Stand-ins and fixtures

Every fake or piece of constructed test data these phases will use is listed
here with a classification. Three classes are used:

- **`boundary`** — a stand-in for a genuine edge of the system: the network,
  the clock, randomness, the terminal, another company's API. These are
  permanent and correct; a test that reaches the real thing would be slow,
  flaky, or destructive.
- **`data`** — constructed test data that is permanent and correct: a fixture
  file, a seeded record, a temporary directory built to a known shape. Not a
  fake of anything; just the input the test needs.
- **`scaffold`** — a stand-in that exists *only* because the surrounding code
  is hard to test as written. This is debt. Each one names the change to the
  production code that would let it be deleted. That change is noted now and
  actually done later, when it is actually planned — not as part of writing
  tests.

When it isn't obvious whether something is `boundary` or `scaffold`, it is
recorded as `scaffold`. The two mistakes are not equally bad: debt wrongly
marked permanent stays hidden forever, while a permanent fake wrongly marked
as debt just leaves a note someone deletes later.

| # | What | Used by | Class | Notes |
|---|------|---------|-------|-------|
| 1 | Temporary `views/`, `public/`, and session directories built with `File::Temp` + `Path::Tiny` | Phases 3, 4, 8, 10, 11, 15 | `data` | Real directories with known contents. Nothing is faked; the code under test does real file I/O against them. |
| 2 | `Dancer2::Logger::Capture` — the in-repo logger engine that stores messages instead of printing them | Phases 8, 9, 11, 13 | `boundary` | Log output going to a terminal or a file is a genuine external edge. This engine already ships as a supported part of the project; it is not a workaround. |
| 3 | Fixed epoch values (e.g. `expires => 1288817656`) instead of a fake clock | Phase 12 | `data` | `Dancer2::Core::Time` passes a plain integer straight through without consulting `time()`, so an absolute expiry makes the assertion deterministic with no clock fake at all. `Test::MockTime` is only an author dependency and is not installed; deliberately not used. |
| 4 | An intentionally-dying route and an intentionally-dying hook | Phase 9 | `data` | Ordinary test input, not a fake — the whole point of the phase is what the framework does when user code throws. |
| 5 | A skipped assertion for the "file exists but is unreadable" case when the tests run as root | Phase 3 | `scaffold` | `chmod 0000` does not stop root from reading a file, and CI for this project runs in Docker as root (see the `Module::Pluggable` note in `cpanfile`). The test will skip with a stated reason rather than assert something false. **The change that retires it:** make the readability check in `Dancer2::Core::App::send_file` and `Dancer2::Handler::File` injectable so the test can force a failure without depending on filesystem permissions. Noted now, done when that refactor is actually planned. |

Nothing else in the plan needs a fake. In particular:

- Sessions do not need one — `Dancer2::Session::Simple` already stores
  sessions in memory.
- Templates do not need one — `Template::Tiny` and `Template` are both already
  runtime dependencies, so the phases render through a real engine.
- Cookie header generation does not need one — `Dancer2::Core::Cookie` exposes
  `pp_to_header` and `xs_to_header` as separate methods, so both the pure-Perl
  and the accelerated path can be tested directly without manipulating which
  optional modules are installed.
- HTTP does not need one — `Plack::Test` runs the application in-process; no
  socket, no server, no port.
