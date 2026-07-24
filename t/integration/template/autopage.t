use strict;
use warnings;

use Test::More;
use Plack::Test;
use HTTP::Request;
use Path::Tiny ();

# The AutoPage handler serves any request whose path matches an existing view,
# with no route declared for it. It is off by default and switched on with
# 'auto_page: 1'.
#
# Because it turns the request path into a view path, it needs a carve-out so
# that layout templates are not served as pages, and it has one:
# Dancer2/Handler/AutoPage.pm:36-40 passes the request on when the path starts
# with the layout directory. That guard is what the last subtest here probes.
#
# auto_page has to come from a config file rather than 'set', because
# route_handlers - which is what registers this handler - is read once when the
# application object is constructed at import time.

my ( $DIR, $VIEWS, $CASE_INSENSITIVE_FS );

BEGIN {
    $DIR   = Path::Tiny->tempdir;
    $VIEWS = $DIR->child('views');
    $VIEWS->child('layouts')->mkpath;
    $VIEWS->child('sub')->mkpath;
    $DIR->child('conf')->mkpath;

    $VIEWS->child('autopage.tt')->spew_utf8('AUTO-PAGE-CONTENT');
    $VIEWS->child('shadowed.tt')->spew_utf8('VIEW-CONTENT');
    $VIEWS->child( 'sub', 'deep.tt' )->spew_utf8('DEEP-CONTENT');
    $VIEWS->child( 'layouts', 'main.tt' )->spew_utf8('MAIN{[% content %]}');

    # Does this filesystem resolve a differently-cased path to the same file?
    # macOS and Windows normally do; most Linux filesystems do not. The last
    # subtest is only meaningful where it does, so ask rather than assume.
    $CASE_INSENSITIVE_FS = -f $VIEWS->child( 'Layouts', 'main.tt' )->stringify;

    $DIR->child( 'conf', 'config.yml' )->spew_utf8( <<"YML" );
auto_page: 1
layout: main
views: "@{[ $VIEWS->stringify ]}"
template: template_toolkit
logger: "null"
YML
}

BEGIN { $ENV{DANCER_CONFDIR} = $DIR->child('conf')->stringify }

{
    package AutoPageApp;
    use Dancer2;

    # A declared route, to check it takes precedence over a view of the
    # same name.
    get '/shadowed' => sub { 'ROUTE-CONTENT' };
}

BEGIN { delete $ENV{DANCER_CONFDIR} }

my $test = Plack::Test->create( AutoPageApp->to_app );

sub get_path {
    my $path = shift;
    return $test->request( HTTP::Request->new( GET => $path ) );
}

subtest 'a request matching a view is served without a route' => sub {
    my $response = get_path('/autopage');

    is( $response->code, 200, 'the page is served' );
    is( $response->content, 'MAIN{AUTO-PAGE-CONTENT}',
        'rendered through the configured layout' );

    my $nested = get_path('/sub/deep');
    is( $nested->code, 200, 'a nested view is served too' );
    is( $nested->content, 'MAIN{DEEP-CONTENT}', 'also with the layout' );
};

subtest 'a request matching no view passes on' => sub {
    my $response = get_path('/no-such-page');

    # The handler passes rather than answering, so this reaches the
    # application's own 404 instead of an empty 200.
    is( $response->code, 404, 'a path with no matching view 404s' );
};

subtest 'a declared route wins over a view of the same name' => sub {
    my $response = get_path('/shadowed');

    is( $response->code, 200, 'the request is served' );
    is( $response->content, 'ROUTE-CONTENT',
        'by the declared route, not the view' );
    unlike( $response->content, qr/VIEW-CONTENT/,
        'the view is not used' );
};

subtest 'a layout cannot be requested as a page' => sub {
    my $response = get_path('/layouts/main');

    # The guard passes the request on, so it 404s like any unmatched path.
    is( $response->code, 404,
        'a path under the layout directory is refused' );
    unlike( $response->content, qr/MAIN\{/,
        'and the layout template is not rendered as a page' );

    # Paths that try to reach the layout directory indirectly are also
    # refused - here because the view lookup itself does not resolve them.
    for my $path ( '/x/../layouts/main', '/./layouts/main', '/sub/../layouts/main' ) {
        is( get_path($path)->code, 404, "$path is refused too" );
    }
};

subtest 'the layout guard is case-sensitive (known bug F11)' => sub {

    # F11. The guard compares the request path against the layout directory
    # name with a case-sensitive match (Dancer2/Handler/AutoPage.pm:38). Where
    # the filesystem is case-insensitive - macOS and Windows by default - a
    # request for /Layouts/main misses the guard but still resolves to the same
    # file, so the layout template is served as a page.
    #
    # The rendered result is the layout wrapped in itself, which is harmless
    # here, but a real layout typically contains the site chrome, navigation,
    # and sometimes conditional markup keyed off tokens that are absent when it
    # is rendered standalone.
    #
    # Deliberately not fixed; filed as F11 in
    # paad/test-roadmap/test-roadmap-findings.md.

  SKIP: {
        skip 'filesystem is case-sensitive, so the bypass does not apply here', 3
            if !$CASE_INSENSITIVE_FS;

        # The control: the correctly-cased path is refused.
        is( get_path('/layouts/main')->code, 404,
            'the correctly-cased layout path is refused' );

        my $response = get_path('/Layouts/main');
        is( $response->code, 200,
            'BUG: the same layout under a different case is served' );
        like( $response->content, qr/MAIN\{/,
            'BUG: and the layout template is rendered as a page' );
    }

    # Whatever the filesystem, the lower-cased path must be refused - that
    # assertion is not conditional.
    is( get_path('/layouts/main')->code, 404,
        'the layout directory is refused as spelled in the config' );
};

done_testing();
