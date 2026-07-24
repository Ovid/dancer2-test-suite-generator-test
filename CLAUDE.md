# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Dancer2 is a lightweight Perl web application framework built on Moo (object system) and Plack/PSGI (server interface). It is distributed on CPAN and built with Dist::Zilla.

## Commands

```bash
# Install dev/build deps (needs Dist::Zilla)
dzil authordeps --missing | cpanm -n   # Dist::Zilla plugins
dzil listdeps  --missing | cpanm -n    # runtime/test deps

# Run the whole test suite (fast, no build) — the usual dev loop
prove -lr t/                # -l = lib/, -r = recurse
prove -lvr t/route.t        # single file, verbose

# Full author/release checks (whitespace, perlcritic, POD) — run before pushing.
# (CI itself is .github/workflows/ci.yml: a Perl 5.20 + 5.36 matrix.)
dzil test --author --release
dzil build                  # produce the tarball

# Run the CLI from the source tree (avoids a system-installed Dancer2)
perl -Ilib script/dancer2 gen -s share/skel --overwrite --path /tmp/d2app -a MyApp::App
```

Tests are plain `Test::More`/`Test::Builder` scripts under `t/`. There is no
mock framework — tests build real app/request objects. Author-only tests
(perlcritic, whitespace, POD) live in `xt/` and only run under `dzil test --author`.

## Conventions

- **Perl 5.14+** is the enforced floor (`cpanfile`; CI matrix bottoms out at `5.20`). Must stay installable back to 5.14 — don't use newer syntax without checking it works there. (Note: `lib/Dancer2.pm` still declares `use 5.12.0`; that should be raised to `use 5.14.0` to match.)
- **Moo / Moo::Role** everywhere, not Moose. Types come from `Dancer2::Core::Types` (Type::Tiny based), not `Moose::Util::TypeConstraints`.
- **`croak`, not `die`** (enforced by perlcritic `RequireCarping`). Line width 79 (`.perltidyrc`). Perl::Critic config: `xt/perlcritic.rc`.
- **Fatpackable**: core must stay pure-Perl-loadable; XS modules are optional accelerators only. Don't add a hard XS dependency.
- Changelog entries go in `Changes` (managed by Dist::Zilla `NextRelease`). Version lives in `dist.ini`, not in `.pm` files.

## Architecture

`use Dancer2` (`lib/Dancer2.pm`) is an import-time DSL installer, not a normal
module. On import it: creates a singleton `Dancer2::Core::Runner` if none
exists, creates/looks up a `Dancer2::Core::App` named after the caller package,
and injects the DSL keywords (`get`, `post`, `route`, `template`, ...) into the
caller. The whole framework is keyword-driven and package-scoped — each
package that says `use Dancer2` becomes its own app.

The request path, most-to-least central:

- **`Core::Runner`** — owns the app registry (`has apps`) and the top-level
  PSGI coderef. `psgi_app()` builds the dispatcher that fronts all registered apps.
- **`Core::App`** — the heavy object. Holds routes, hooks, plugins, and the
  configured engines. `to_app()` returns this app's PSGI sub; `dispatch()` →
  `_dispatch_route()` runs the matched route and hook chain. Start here when
  tracing behavior.
- **`Core::DSL`** — maps each DSL keyword to the App method it calls. This is
  the bridge between user syntax and the object model.
- **`Core::Dispatcher` / `Core::Route`** — route matching and invocation.
- **`Core::Request` / `Core::Response` / `Core::Cookie`** — the HTTP objects
  (Request wraps the PSGI env).

**Engines are pluggable roles.** Each engine category is a `Core::Role::*`
consumed by interchangeable implementations, selected via config:

| Category  | Role                          | Implementations (`lib/Dancer2/...`)        |
|-----------|-------------------------------|--------------------------------------------|
| Session   | `Role::SessionFactory`        | `Session/Simple.pm`, `Session/YAML.pm`     |
| Template  | `Role::Template`              | `Template/Tiny.pm`, `Template/TemplateToolkit.pm` |
| Logger    | `Role::Logger`                | `Logger/Console.pm`, `File.pm`, `Capture.pm` (tests) |
| Serializer| `Role::Serializer`            | `Serializer/JSON.pm`, `YAML.pm`, `Mutable.pm` |

When adding/fixing engine behavior, change the **role** if it affects all
implementations, the specific engine if not — same root-cause rule as any
shared function.

**Plugins** (`Dancer2::Plugin`) register extra keywords and hooks into an App.
`Handler/` (`AutoPage`, `File`) serves non-route requests (static files, auto pages).

`share/skel/` is the scaffold template copied by `dancer2 gen`. `examples/` and
`tools/` (perf scripts) are not part of the shipped dist.
