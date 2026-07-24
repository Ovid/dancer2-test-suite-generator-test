use strict;
use warnings;

use Test::More;
use Test::Fatal qw<exception>;

use Dancer2::Core::Response;

# Unit tests for the response object: character encoding, Content-Length, and
# the conversion to a PSGI array.
#
# U+263A is used throughout as the non-ASCII character. It matters that it is
# above U+00FF: Perl stores a string of only Latin-1 codepoints as bytes with
# no UTF8 flag, and several branches in encode_content key off
# utf8::is_utf8(), so "caf\x{e9}" takes a different path from "hi\x{263A}"
# and would quietly test the wrong thing.
my $CHAR  = "\x{263A}";
my $BYTES = "\xe2\x98\xba";    # the same character, UTF-8 encoded

# Helper: the PSGI triplet with the headers as a hash, plus the raw header
# array for the cases where the array itself is what is being asserted.
sub psgi_parts {
    my $response = shift;
    my $psgi     = $response->to_psgi;
    my %header;
    for ( my $i = 0; $i < @{ $psgi->[1] }; $i += 2 ) {
        $header{ $psgi->[1][$i] } = $psgi->[1][ $i + 1 ];
    }
    return {
        status  => $psgi->[0],
        header  => \%header,
        raw     => $psgi->[1],
        body    => $psgi->[2],
    };
}

# THIS SUBTEST MUST RUN FIRST.
#
# The "no charset configured" report is gated by a file-scoped counter in
# Dancer2::Core::Response ($WARNED_NO_CHARSET), so it fires at most once per
# process and cannot be reset from outside. Any earlier subtest that assigned
# character content with no charset would consume it and make this one
# unfalsifiable.
subtest 'a missing charset is reported once per process' => sub {
    my @logged;
    my @warnings;

    my $response = Dancer2::Core::Response->new(
        log_cb => sub { push @logged, [@_] } );

    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $response->content("hi$CHAR");
    }

    is( scalar @logged, 1, 'the app is told, once' );
    is( $logged[0][0], 'warning', 'at warning level' );
    like( $logged[0][1], qr/no charset is configured/,
        'saying no charset was configured' );
    like( $logged[0][1], qr/assuming UTF-8/,
        'and what it assumed instead' );
    is( scalar @warnings, 0,
        'and nothing goes to STDERR when the app provides a log callback' );

    # Having assumed UTF-8, it must actually encode as UTF-8.
    my $got = psgi_parts($response);
    is( $got->{body}[0], "hi$BYTES", 'the body is UTF-8 encoded' );
    like( $got->{header}{'Content-Type'}, qr/charset=UTF-8/,
        'and the assumption is declared in the Content-Type' );

    # The second response is silent - the counter is per process, not per
    # response. Pinned because it is surprising: an app that starts warning
    # about this warns exactly once and then never again.
    my ( @logged2, @warnings2 );
    my $second = Dancer2::Core::Response->new(
        log_cb => sub { push @logged2, [@_] } );
    {
        local $SIG{__WARN__} = sub { push @warnings2, $_[0] };
        $second->content("again$CHAR");
    }
    is( scalar @logged2,   0, 'a later response does not report it again' );
    is( scalar @warnings2, 0, 'nor warn about it' );

    # But it still encodes. Only the reporting is suppressed, not the
    # behavior - which is why the silence above is safe rather than a bug.
    is( $second->content, "again$BYTES",
        'and it still encodes as UTF-8 despite saying nothing' );
};

subtest 'a missing charset is fatal under strict_utf8' => sub {
    # Unlike the report above, the croak happens before the once-per-process
    # counter is consulted, so this is repeatable.
    for my $attempt ( 1, 2 ) {
        my $response = Dancer2::Core::Response->new( strict_utf8 => 1 );
        my $err = exception { $response->content("hi$CHAR") };
        ok( defined $err, "attempt $attempt throws" );
        like( $err, qr/no charset is configured/,
            "attempt $attempt says why" );
    }

    # Byte content is not affected: there is nothing to encode, so strict
    # mode has no complaint.
    my $bytes = Dancer2::Core::Response->new( strict_utf8 => 1 );
    is( exception { $bytes->content("plain ascii") }, undef,
        'ASCII content is fine under strict_utf8' );
    is( $bytes->content, 'plain ascii', 'and passes through unchanged' );
};

subtest 'text content is encoded once, and Content-Length counts bytes' => sub {
    my $response = Dancer2::Core::Response->new( charset => 'UTF-8' );
    $response->content("hi$CHAR");

    ok( !utf8::is_utf8( $response->content ),
        'the stored content is bytes, not characters' );
    is( $response->content, "hi$BYTES", 'encoded as UTF-8' );
    ok( $response->is_encoded, 'and marked as encoded' );

    my $got = psgi_parts($response);
    is( $got->{body}[0], "hi$BYTES", 'the PSGI body is those bytes' );

    # 5 bytes, 3 characters. This is the assertion that fails if
    # Content-Length is ever taken before encoding.
    is( $got->{header}{'Content-Length'}, 5,
        'Content-Length is the byte count' );
    is( length $got->{body}[0], 5, 'which matches the body actually sent' );
    isnt( $got->{header}{'Content-Length'}, 3,
        'and is not the character count' );

    is( $got->{header}{'Content-Type'}, 'text/html; charset=UTF-8',
        'the charset is declared once, appended to the default type' );

    # Converting twice must not append a second charset or a second
    # Content-Length, and must not re-encode.
    my $again = psgi_parts($response);
    is( $again->{header}{'Content-Type'}, 'text/html; charset=UTF-8',
        'a second conversion does not append the charset again' );
    is( $again->{header}{'Content-Length'}, 5,
        'nor a second Content-Length' );
    is( $again->{body}[0], "hi$BYTES", 'and does not double-encode the body' );
};

subtest 'an explicit charset in the content type is respected' => sub {
    my $response = Dancer2::Core::Response->new( charset => 'UTF-8' );
    $response->content_type('text/plain; charset=UTF-8');
    $response->content("hi$CHAR");

    my $got = psgi_parts($response);
    is( $got->{header}{'Content-Type'}, 'text/plain; charset=UTF-8',
        'the content type is left exactly as given, with one charset' );
    is( $got->{body}[0], "hi$BYTES", 'and the content is encoded to match' );
};

subtest 'no charset is appended to a non-text content type' => sub {
    my $response = Dancer2::Core::Response->new( charset => 'UTF-8' );
    $response->content_type('application/json');
    $response->content(qq[{"m":"$CHAR"}]);

    my $got = psgi_parts($response);
    is( $got->{header}{'Content-Type'}, 'application/json',
        'the content type gains no charset parameter' );
    unlike( $got->{header}{'Content-Type'}, qr/charset/,
        'not even an empty one' );

    # Non-text content is deliberately not encoded here - a serializer is
    # expected to have produced bytes already and to have set is_encoded.
    # Pinned as current behavior: assigning characters under a non-text type
    # by hand leaves them as characters, and Content-Length then counts
    # characters rather than bytes.
    ok( !$response->is_encoded, 'and the content is not encoded' );
    ok( utf8::is_utf8( $got->{body}[0] ),
        'so a character string stays characters' );
    is( $got->{header}{'Content-Length'}, 9,
        'with Content-Length counting those characters' );
};

subtest 'replacing the content after the first set leaves it unencoded (known bug)' => sub {

    # This pins a real defect. is_encoded latches on the first assignment,
    # and encode_content returns early whenever it is set
    # (Dancer2/Core/Response.pm:162) - so a *second* assignment of character
    # content is never encoded, even though the 'around content' modifier
    # (Response.pm:137-151) runs encode_content on every assignment and the
    # response goes on advertising charset=UTF-8.
    #
    # This is reachable from ordinary code: an 'after' hook that rewrites
    # response->content, or halt() called once content was already set.
    #
    # Deliberately not fixed here; filed as F6 in
    # paad/test-roadmap/test-roadmap-findings.md. When is_encoded stops
    # latching across assignments, this subtest goes red - that red is the
    # fix landing.

    my $response = Dancer2::Core::Response->new( charset => 'UTF-8' );
    $response->content('first');           # ASCII, latches is_encoded
    ok( $response->is_encoded, 'the first assignment marks the response encoded' );

    $response->content("hi$CHAR");         # characters, silently not encoded

    my $got = psgi_parts($response);

    ok( utf8::is_utf8( $got->{body}[0] ),
        'BUG: the replacement content is still characters, not bytes' );
    is( $got->{body}[0], "hi$CHAR",
        'BUG: it was never encoded' );
    is( $got->{header}{'Content-Length'}, 3,
        'BUG: Content-Length is the character count, not the 5 bytes UTF-8 would need' );
    like( $got->{header}{'Content-Type'}, qr/charset=UTF-8/,
        'BUG: while the Content-Type still claims UTF-8' );
};

subtest 'statuses that forbid a body get no body and no Content-Length' => sub {
    for my $status ( 100, 101, 204, 304 ) {
        my $response = Dancer2::Core::Response->new( charset => 'UTF-8' );
        $response->status($status);
        $response->header( 'X-Keep' => 'yes' );
        $response->content('BODY');

        my $got = psgi_parts($response);
        is( $got->{status}, $status, "$status: the status is preserved" );
        is_deeply( $got->{body}, [], "$status: the body is dropped entirely" );
        is( $got->{header}{'Content-Length'}, undef,
            "$status: and no Content-Length is sent" );
        is( $got->{header}{'X-Keep'}, 'yes',
            "$status: other headers are still sent" );
    }

    # The neighbours must keep their bodies, or the check above is just
    # "everything is empty".
    for my $status ( 200, 205, 404 ) {
        my $response = Dancer2::Core::Response->new( charset => 'UTF-8' );
        $response->status($status);
        $response->content('BODY');

        my $got = psgi_parts($response);
        is_deeply( $got->{body}, ['BODY'], "$status: keeps its body" );
        is( $got->{header}{'Content-Length'}, 4,
            "$status: and reports its length" );
    }
};

subtest 'the default content type is applied when none was set' => sub {
    my $default = Dancer2::Core::Response->new( charset => 'UTF-8' );
    $default->content('x');
    is( psgi_parts($default)->{header}{'Content-Type'},
        'text/html; charset=UTF-8',
        'text/html is the default' );

    my $configured = Dancer2::Core::Response->new(
        charset              => 'UTF-8',
        default_content_type => 'text/plain',
    );
    $configured->content('x');
    is( psgi_parts($configured)->{header}{'Content-Type'},
        'text/plain; charset=UTF-8',
        'a configured default is used instead of text/html' );

    # A response nothing was ever done to still converts cleanly - this is
    # the "all routes passed" case.
    my $untouched = Dancer2::Core::Response->new;
    my $got       = psgi_parts($untouched);
    is( $got->{status}, 200, 'an untouched response is a 200' );
    is( $got->{header}{'Content-Type'}, 'text/html',
        'with the default content type' );
    is( $got->{header}{'Content-Length'}, 0, 'a zero Content-Length' );
    is_deeply( $got->{body}, [''], 'and an empty body' );
};

subtest 'CR and LF are stripped from header values' => sub {
    my $response = Dancer2::Core::Response->new( charset => 'UTF-8' );
    $response->content('x');

    # A CRLF in a header value is how a response-splitting attack injects a
    # header of its own. It must not survive into the PSGI array.
    $response->header( 'X-Split' => "ok\r\nInjected: yes" );

    # Folded continuation lines collapse to a single space instead.
    $response->header( 'X-Folded' => "a\r\n\tb" );

    my $got = psgi_parts($response);

    is( $got->{header}{'X-Split'}, 'okInjected: yes',
        'the CRLF is removed, leaving one header value' );
    unlike( $got->{header}{'X-Split'}, qr/[\r\n]/,
        'no carriage return or line feed remains' );

    is( $got->{header}{'X-Folded'}, 'a b',
        'linear whitespace folding collapses to a single space' );

    # Nothing anywhere in the array may carry a bare CR or LF.
    my @offending = grep { /[\r\n]/ } @{ $got->{raw} };
    is_deeply( \@offending, [],
        'no element of the PSGI header array contains CR or LF' );
};

subtest 'CR and LF survive in a header name (known bug)' => sub {

    # headers_to_array strips CR and LF from each header *value*
    # (Dancer2/Core/Response.pm:70-71, commented "remove CR and LF since the
    # char is invalid here") but applies nothing to the *name*, two lines
    # away in the same loop. A CRLF in the name therefore reaches the PSGI
    # array intact, which is the same response-splitting shape the value is
    # guarded against.
    #
    # Deliberately not fixed here; filed as F7 in
    # paad/test-roadmap/test-roadmap-findings.md. Sanitising the name turns
    # this subtest red.

    my $response = Dancer2::Core::Response->new( charset => 'UTF-8' );
    $response->content('x');
    $response->header( "X-Bad\r\nInjected: yes" => 'v' );

    my $got = psgi_parts($response);

    my @with_newlines = grep { /[\r\n]/ } @{ $got->{raw} };
    is( scalar @with_newlines, 1,
        'BUG: one element of the PSGI header array still contains CRLF' );
    like( $with_newlines[0], qr/\r\n/,
        'BUG: and it is the header name, carrying the injected line' );
    like( $with_newlines[0], qr/^X-Bad/,
        'BUG: which begins with the name that was set' );
};

done_testing();
