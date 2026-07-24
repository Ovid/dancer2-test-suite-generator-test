use strict;
use warnings;

use Test::More;
use Plack::Test;
use HTTP::Request::Common;

# The hook chain: what runs, in what order, and what happens when a hook dies.
#
# Every app hook is wrapped by App::compile_hooks (Dancer2/Core/App.pm:1313),
# which does three things worth pinning: it skips the hook entirely if the
# response is already halted, it fires core.app.hook_exception when the hook
# dies, and it decides between keeping a response the exception handler set and
# croaking on to the 500 handler.
#
# Traces are collected in package arrays rather than asserted through the
# response body, because several of these cases never reach a route at all and
# the ordering is the thing being tested.
#
# Each app's PSGI coderef is built exactly once, at file scope. That is not
# tidiness: to_app is not idempotent for hooks (see the last subtest, F10), so
# calling it per subtest would add a wrapper layer each time and inflate the
# exception counts these tests assert on.

{
    package OrderApp;
    use Dancer2;
    set logger => 'null';

    our @trace;

    hook on_hook_exception  => sub { push @trace, "hook_exception:$_[2]" };
    hook on_route_exception => sub { push @trace, 'route_exception' };

    hook before => sub {
        push @trace, 'before';
        die "before blew up\n" if request->path =~ /boom/;
    };
    hook after => sub { push @trace, 'after' };

    get '/ok'   => sub { push @trace, 'route';               'OK' };
    get '/boom' => sub { push @trace, 'route-MUST-NOT-RUN';  'NOPE' };
}

{
    package HaltApp;
    use Dancer2;
    set logger => 'null';

    our @trace;

    hook before => sub { push @trace, 'before-1'; halt('HALTED-IN-BEFORE') };
    hook before => sub { push @trace, 'before-2-MUST-NOT-RUN' };
    hook after  => sub { push @trace, 'after-MUST-NOT-RUN' };

    get '/x' => sub { push @trace, 'route-MUST-NOT-RUN'; 'ROUTE' };
}

# A hook_exception handler that sets its own response and halts. The wrapper
# in compile_hooks explicitly supports this (see its comment at
# Dancer2/Core/App.pm:1343-1347), which is what makes the outcome below a bug
# rather than a design choice.
{
    package HaltInExceptionApp;
    use Dancer2;
    set logger => 'null';

    our @trace;

    hook on_hook_exception => sub {
        my ( $app, $err, $position ) = @_;
        $err =~ s/\n.*//s;
        push @trace, "hook_exception:$position";
        $app->response->status(418);
        $app->response->content('CUSTOM-FROM-HANDLER');
        $app->response->is_halted(1);
    };
    hook on_route_exception => sub { push @trace, 'route_exception' };

    hook before => sub { push @trace, 'before'; die "before blew up\n" };
    hook after  => sub { push @trace, 'after' };

    get '/x' => sub { push @trace, 'route'; 'ROUTE-BODY' };
}

# Built once each - see the note at the top of this file.
my $order_test = Plack::Test->create( OrderApp->to_app );
my $halt_test  = Plack::Test->create( HaltApp->to_app );
my $halt_in_exception_test =
    Plack::Test->create( HaltInExceptionApp->to_app );

subtest 'hooks run around the route in order' => sub {
    my $test = $order_test;

    @OrderApp::trace = ();
    my $response = $test->request( GET '/ok' );

    is( $response->code, 200, 'the request succeeds' );
    is( $response->content, 'OK', 'the route produced the body' );
    is_deeply( \@OrderApp::trace, [ 'before', 'route', 'after' ],
        'before, then the route, then after' );
};

subtest 'a dying before hook fires both exception hooks and 500s' => sub {
    my $test = $order_test;

    @OrderApp::trace = ();
    my $response = $test->request( GET '/boom' );

    is( $response->code, 500, 'the request becomes a 500' );

    # Both hooks fire, and hook_exception is told which position died. The
    # route must not run: the before hook refused the request.
    is_deeply(
        \@OrderApp::trace,
        [
            'before',
            'hook_exception:core.app.before_request',
            'route_exception',
        ],
        'hook_exception fires first with the position, then route_exception, and the route never runs',
    );

    like( $response->content, qr/<!DOCTYPE html>/,
        'and an error page is rendered' );
};

subtest 'halt in a before hook stops the whole chain' => sub {
    my $test = $halt_test;

    @HaltApp::trace = ();
    my $response = $test->request( GET '/x' );

    is( $response->code, 200, 'halt keeps the status it was given' );
    is( $response->content, 'HALTED-IN-BEFORE',
        'and the halted body is what is returned' );

    # This is the assertion: exactly one hook ran. A second before hook, the
    # route, and the after hook are all skipped, which is compile_hooks'
    # is_halted check (Dancer2/Core/App.pm:1322-1324) doing its job.
    is_deeply( \@HaltApp::trace, ['before-1'],
        'no later hook and no route runs after halt' );
};

subtest 'a halting hook_exception handler lets the route run anyway (known bug)' => sub {

    # F9. The wrapper captures is_halted, then calls $app->cleanup, then
    # returns without croaking because the handler halted. But cleanup
    # (Dancer2/Core/App.pm:945-956) clears the request, the response and the
    # session - so dispatch resumes with a *fresh* unhalted response, runs the
    # route that the before hook had just refused, and then dies inside the
    # after_request hook because the request it needs is gone.
    #
    # The 418 the client finally receives is arrived at by accident, on the
    # second trip through the exception handler.
    #
    # Deliberately not fixed; filed as F9 in
    # paad/test-roadmap/test-roadmap-findings.md.

    my $test = $halt_in_exception_test;

    @HaltInExceptionApp::trace = ();
    my $response = $test->request( GET '/x' );

    # The response does end up being the handler's, which is why this is easy
    # to miss.
    is( $response->code, 418, 'the handler\'s status is what the client gets' );
    is( $response->content, 'CUSTOM-FROM-HANDLER',
        'and the handler\'s body' );

    # But the route body ran, despite the before hook having died.
    ok(
        scalar( grep { $_ eq 'route' } @HaltInExceptionApp::trace ),
        'BUG: the route runs even though the before hook died and the handler halted',
    );

    # And the exception handler is entered twice: once for the before hook,
    # once for the internal failure that cleanup caused in after_request.
    my @exceptions = grep { /^hook_exception:/ } @HaltInExceptionApp::trace;
    is( scalar @exceptions, 2,
        'BUG: the exception handler fires twice, not once' );
    is( $exceptions[0], 'hook_exception:core.app.before_request',
        'the first is the before hook that really failed' );
    is( $exceptions[1], 'hook_exception:core.app.after_request',
        'BUG: the second is an internal failure caused by the cleanup' );

    is_deeply(
        \@HaltInExceptionApp::trace,
        [
            'before',
            'hook_exception:core.app.before_request',
            'route',
            'hook_exception:core.app.after_request',
        ],
        'BUG: the full sequence, with the route wedged in the middle',
    );
};

subtest 'to_app compiles the hooks again every time (known bug)' => sub {

    # F10. finish() calls compile_hooks(), which wraps each hook and puts the
    # wrappers back via replace_hook - so a second to_app() wraps the already
    # wrapped hooks again. On the success path this is invisible: the innermost
    # wrapper runs the hook once. On the *failure* path each layer treats the
    # inner layer's croak as a fresh hook failure and fires
    # core.app.hook_exception itself, so a single dying hook reports N times
    # after N calls to to_app.
    #
    # That defeats the single-fire intent the wrapper states for itself: it
    # carries an explicit guard against firing hook_exception recursively
    # (Dancer2/Core/App.pm:1329-1334), which only considers recursion through
    # the handler, not through a second layer of wrapping.
    #
    # This is why every app in this file builds its PSGI coderef once. It bites
    # test authors first, but any code that calls to_app twice on one app hits
    # it.
    #
    # Deliberately not fixed; filed as F10 in
    # paad/test-roadmap/test-roadmap-findings.md.

    {
        package RecompiledApp;
        use Dancer2;
        set logger => 'null';

        our @trace;

        hook on_hook_exception  => sub { push @trace, 'hook_exception' };
        hook on_route_exception => sub { push @trace, 'route_exception' };
        hook before => sub { push @trace, 'before'; die "boom\n" };

        get '/x' => sub { 'X' };
    }

    my @counts;
    for my $call ( 1 .. 3 ) {
        my $test = Plack::Test->create( RecompiledApp->to_app );
        @RecompiledApp::trace = ();
        $test->request( GET '/x' );
        push @counts,
            scalar grep { $_ eq 'hook_exception' } @RecompiledApp::trace;
    }

    is( $counts[0], 1,
        'the first to_app reports the failing hook once, correctly' );
    is_deeply( \@counts, [ 1, 2, 3 ],
        'BUG: each further to_app adds another hook_exception for the same failure' );
};

done_testing();
