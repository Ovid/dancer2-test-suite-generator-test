use strict;
use warnings;

use Test::More;
use Plack::Test;
use HTTP::Request;

# Dancer2::Serializer::Mutable picks a format per request from the HTTP
# headers. It makes that choice twice, by two different rules:
#
#   deserialize - _get_content_type('content_type'), so the request's
#                 Content-Type decides how the incoming body is read.
#   serialize   - _get_content_type('accept'), so the request's Accept
#                 decides how the outgoing body is written.
#
# Those two rules disagree with the module's own documentation, which states a
# single priority order for both. That disagreement is asserted below rather
# than smoothed over, and is filed as F3.
#
# The lookup is also an exact hash-key match on the raw header value, which a
# perfectly ordinary '; charset=utf-8' defeats. Filed as F8.

{
    package MutableApp;
    use Dancer2;
    set logger     => 'null';
    set serializer => 'Mutable';

    get  '/out'   => sub { { a => 1 } };
    post '/round' => sub { { got => request->data } };
}

my $test = Plack::Test->create( MutableApp->to_app );

sub hit {
    my ( $method, $path, $headers, $body ) = @_;
    return $test->request(
        HTTP::Request->new( $method, $path, $headers || [], $body ) );
}

subtest 'Accept chooses the outgoing format' => sub {
    my %expected = (
        'application/json'   => [ 'application/json',   qr/^\{"a":1\}$/ ],
        'text/x-json'        => [ 'text/x-json',         qr/^\{"a":1\}$/ ],
        'text/x-yaml'        => [ 'text/x-yaml',         qr/^---\na: 1\n$/ ],
        'text/html'          => [ 'text/html',           qr/^---\na: 1\n$/ ],
        'text/x-data-dumper' => [ 'text/x-data-dumper',  qr/VAR1/ ],
    );

    for my $accept ( sort keys %expected ) {
        my ( $content_type, $body_like ) = @{ $expected{$accept} };
        my $response = hit( GET => '/out', [ Accept => $accept ] );

        is( $response->code, 200, "Accept: $accept responds" );
        is( $response->header('Content-Type'), $content_type,
            "Accept: $accept sets Content-Type to match" );
        like( $response->content, $body_like,
            "Accept: $accept serializes in that format" );
    }
};

subtest 'an unrecognised or absent Accept falls back to JSON' => sub {
    for my $accept ( 'application/xml', 'text/plain', '*/*' ) {
        my $response = hit( GET => '/out', [ Accept => $accept ] );
        is( $response->header('Content-Type'), 'application/json',
            "Accept: $accept falls back to JSON" );
        is( $response->content, '{"a":1}', "Accept: $accept body is JSON" );
    }

    my $bare = hit( GET => '/out' );
    is( $bare->header('Content-Type'), 'application/json',
        'no Accept header at all falls back to JSON' );
    is( $bare->content, '{"a":1}', 'with a JSON body' );
};

subtest 'Content-Type chooses the incoming format' => sub {
    # YAML in, and (with no Accept header) JSON is *not* what comes back -
    # _get_content_type('accept') falls through to content_type, so the
    # response follows the request's Content-Type here.
    my $yaml = hit( POST => '/round', [ 'Content-Type' => 'text/x-yaml' ],
        "---\na: 1\n" );
    is( $yaml->code, 200, 'a YAML body is accepted' );
    like( $yaml->content, qr/^---\n/, 'and answered in YAML' );
    like( $yaml->content, qr/a: 1/, 'with the deserialized value' );

    my $json = hit( POST => '/round', [ 'Content-Type' => 'application/json' ],
        '{"a":1}' );
    is( $json->code, 200, 'a JSON body is accepted' );
    is( $json->content, '{"got":{"a":1}}',
        'deserialized and answered in JSON' );

    # An unrecognised Content-Type falls back to JSON for the *input* too,
    # which is why a JSON body under a bogus type still works.
    my $unknown = hit( POST => '/round',
        [ 'Content-Type' => 'application/xml' ], '{"a":1}' );
    is( $unknown->code, 200,
        'an unrecognised Content-Type falls back to JSON' );
    is( $unknown->content, '{"got":{"a":1}}',
        'so a JSON body under a bogus content type is still read' );
};

subtest 'Accept wins over Content-Type when serializing (known bug)' => sub {

    # F3. The module's DESCRIPTION states one priority order for choosing a
    # format: the request's Content-Type, then its Accept, then a JSON
    # default. By that order a request with Content-Type: text/x-yaml should
    # be answered in YAML whatever Accept says.
    #
    # It is not. serialize() calls _get_content_type('accept'), which checks
    # the headers in the order accept, content_type, accept
    # (Dancer2/Serializer/Mutable.pm:68 and :95), so Accept wins on the way
    # out while Content-Type still wins on the way in. The round trip is
    # therefore asymmetric: YAML in, JSON out.
    #
    # Deliberately not fixed; filed as F3 in
    # paad/test-roadmap/test-roadmap-findings.md. Whichever way it is
    # reconciled - code to match the docs, or docs to match the code - this
    # subtest is what goes red.

    my $response = hit(
        POST => '/round',
        [ 'Content-Type' => 'text/x-yaml', 'Accept' => 'application/json' ],
        "---\na: 1\n",
    );

    is( $response->code, 200, 'the request succeeds' );

    # The body was read as YAML, per the documented rule.
    like( $response->content, qr/"got"/,
        'BUG: the response is JSON, chosen from Accept' );
    is( $response->header('Content-Type'), 'application/json',
        'BUG: and says so, rather than the documented text/x-yaml' );

    # The mirror image, to show it is the Accept header doing this and not
    # something about YAML: JSON in, YAML out.
    my $mirror = hit(
        POST => '/round',
        [ 'Content-Type' => 'application/json', 'Accept' => 'text/x-yaml' ],
        '{"a":1}',
    );
    is( $mirror->header('Content-Type'), 'text/x-yaml',
        'BUG: a JSON request is answered in YAML when Accept asks for it' );
    like( $mirror->content, qr/^---\n/, 'BUG: with a YAML body' );
};

subtest 'a charset parameter on Content-Type breaks the lookup (known bug)' => sub {

    # F8. The mapping is an exact hash-key match on the raw header value
    # (Dancer2/Serializer/Mutable.pm:96-97), so 'text/x-yaml; charset=utf-8'
    # misses the 'text/x-yaml' key, falls through to the JSON default, and
    # then JSON is handed a YAML body and fails the request as a 400.
    #
    # A charset parameter on Content-Type is entirely ordinary, so this is
    # reachable from any normal client.
    #
    # Deliberately not fixed; filed as F8 in
    # paad/test-roadmap/test-roadmap-findings.md.

    # The control: the identical request without the parameter works.
    my $plain = hit( POST => '/round', [ 'Content-Type' => 'text/x-yaml' ],
        "---\na: 1\n" );
    is( $plain->code, 200, 'text/x-yaml alone is understood' );

    my $with_charset = hit( POST => '/round',
        [ 'Content-Type' => 'text/x-yaml; charset=utf-8' ], "---\na: 1\n" );
    is( $with_charset->code, 400,
        'BUG: the same body with "; charset=utf-8" is rejected as 400' );

    # JSON happens to survive the same treatment, but only by accident: the
    # fallback when the lookup misses *is* JSON, so the miss goes unnoticed.
    my $json_charset = hit( POST => '/round',
        [ 'Content-Type' => 'application/json; charset=utf-8' ], '{"a":1}' );
    is( $json_charset->code, 200,
        'JSON with a charset parameter still works' );
    is( $json_charset->content, '{"got":{"a":1}}',
        'but only because the fallback happens to be JSON' );

    # Same miss on the way out: the Accept lookup is the same exact match.
    my $accept_charset = hit( GET => '/out',
        [ Accept => 'text/x-yaml; charset=utf-8' ] );
    is( $accept_charset->header('Content-Type'), 'application/json',
        'BUG: an Accept with a parameter also misses and falls back to JSON' );
};

done_testing();
