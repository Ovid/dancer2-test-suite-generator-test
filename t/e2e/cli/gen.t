use strict;
use warnings;

use Test::More;
use File::Temp qw< tempdir >;
use Path::Tiny qw< path >;
use Capture::Tiny qw< capture >;
use Config;

# End-to-end test for the `dancer2 gen` scaffold: it runs the real command as a
# separate process against share/skel, then compiles and runs what came out.
#
# It runs the command out of *this* source tree, never an installed Dancer2:
#   -s share/skel  points at the skeleton in the repo rather than the dist_dir
#   -x             skips the "is there a newer Dancer2 on CPAN?" check, which
#                  needs the network and warns when it cannot reach it
# The generated application only knows about Dancer2 through PERL5LIB, which is
# set to this repo's lib for every child process below.

my $repo   = path('.')->absolute;
my $script = $repo->child('script/dancer2');
my $skel   = $repo->child('share/skel');

-f $script && -d $skel
    or plan skip_all => 'must be run from the distribution root';

my $lib = $repo->child('lib')->stringify;

# Run the generator. Returns the exit status and both output streams; the
# generator is chatty on STDOUT ("+ path" per file written), and none of that
# should reach this suite's own output.
sub gen {
    my @args = @_;
    my ( $stdout, $stderr, $status ) = capture {
        local $ENV{'PERL5LIB'} = $lib;
        system( $Config{'perlpath'}, "-I$lib", "$script", 'gen',
            '-s', "$skel", '-x', '--overwrite', @args );
    };
    return { status => $status, stdout => $stdout, stderr => $stderr };
}

# Read a generated file, or give back the empty string if the generator never
# wrote it. A missing file is already reported by the file-presence subtest;
# this keeps the content assertions from dying and taking the rest of the run
# down with them, so one broken thing produces one clear list of failures.
sub slurp {
    my $file = shift;
    return $file->is_file ? $file->slurp_utf8 : '';
}

# The application the scaffold has to produce, listed here rather than derived
# from share/skel -- deriving it would make the check vacuous, since a file
# deleted from the skeleton would also vanish from the expectation. Every entry
# is something the generated app needs to start, serve its one route, or be
# packaged.
#
# environments/development.yml and environments/production.yml are deliberately
# absent from this list: they exist in the skeleton on disk but have never been
# committed, so a fresh clone does not generate them. See the last subtest.
my @required = qw<
    bin/app.psgi
    config.yml
    cpanfile
    views/index.tt
    views/layouts/main.tt
    public/404.html
    public/500.html
    public/css/style.css
    public/dispatch.cgi
    public/dispatch.fcgi
    t/001_base.t
    t/002_index_route.t
    .dancer
    Makefile.PL
    MANIFEST
    MANIFEST.SKIP
>;

my $tmp = tempdir( CLEANUP => 1 );
my $run = gen( '-a', 'MyApp::App', '-d', 'myapp', '--path', $tmp );
my $app = path( $tmp, 'myapp' );

subtest 'the generator runs cleanly and writes where it was told' => sub {
    is( $run->{'status'}, 0, 'dancer2 gen exits successfully' )
        or diag "STDERR:\n$run->{stderr}\nSTDOUT:\n$run->{stdout}";
    is( $run->{'stderr'}, '', 'and says nothing on STDERR' );

    ok( $app->is_dir, "--path and -d put the application in $app" );
    like( $run->{'stdout'}, qr/Your new application is ready/,
        'the run ends with the how-to-run banner' );
};

subtest 'every file the generated application needs is present' => sub {
    # This is the subtest that goes red if share/skel loses something.
    for my $file (@required) {
        ok( $app->child($file)->is_file, "generated $file" );
    }

    # The skeleton marks these two with a leading '+' to request the exec bit;
    # the '+' must not survive into the generated name.
    ok( !$app->child('bin/+app.psgi')->exists,
        'the + marker is stripped from the generated filename' );

    SKIP: {
        skip 'no meaningful exec bit on this platform', 2
            if $^O eq 'MSWin32';
        ok( -x $app->child('bin/app.psgi')->stringify,
            'bin/app.psgi is executable' );
        ok( -x $app->child('public/dispatch.cgi')->stringify,
            'public/dispatch.cgi is executable' );
    }
};

subtest '-a decides the package name and the module path' => sub {
    my $module = $app->child('lib/MyApp/App.pm');
    ok( $module->is_file, 'the module is written at the path -a implies' );

    my $source = slurp($module);
    like( $source, qr/^package MyApp::App;/m, 'and declares that package' );
    ok( length $source && $source !~ /AppFile/,
        'no trace of the skeleton\'s placeholder package name' );

    # The same name has to reach the files that refer to the app by name, or
    # the generated app starts but cannot be packaged or served.
    like( slurp( $app->child('bin/app.psgi') ), qr/\buse MyApp::App\b/,
        'the .psgi entry point loads the generated module' );
    like( slurp( $app->child('Makefile.PL') ), qr/NAME\s*=>\s*'MyApp::App'/,
        'Makefile.PL names the generated module' );

    # Template tokens are [d2% ... %2d]; any left behind means a variable was
    # never substituted.
    for my $file (qw< bin/app.psgi Makefile.PL config.yml >) {
        my $content = slurp( $app->child($file) );
        ok( length $content && $content !~ /\Q[d2%\E/,
            "no unsubstituted template token left in $file" );
    }
};

subtest 'the generated application compiles' => sub {
    my ( $stdout, $stderr, $status ) = capture {
        system( $Config{'perlpath'}, "-I$lib",
            '-I' . $app->child('lib')->stringify,
            '-c', $app->child('lib/MyApp/App.pm')->stringify );
    };

    is( $status, 0, 'perl -c on the generated module succeeds' )
        or diag "STDERR:\n$stderr";
    like( $stderr, qr/syntax OK/, 'and perl says so' );
};

subtest 'the generated application passes its own bundled tests' => sub {
    # The app's tests are run the way its author would run them, from inside
    # the generated directory. Its output is captured rather than let through:
    # in the development environment the console logger writes core-level lines
    # to STDERR, and that is the child's business, not this suite's.
    my ( $stdout, $stderr, $status ) = capture {
        local $ENV{'PERL5LIB'} = $lib;
        my $cwd = path('.')->absolute;
        chdir $app->stringify or die "cannot chdir to $app: $!";
        my $rv = system( 'prove', '-lr', 't' );
        chdir $cwd->stringify or die "cannot chdir back to $cwd: $!";
        $rv;
    };

    is( $status, 0, 'prove -lr t passes in the generated application' )
        or diag "STDOUT:\n$stdout\nSTDERR:\n$stderr";
    like( $stdout, qr/Result: PASS/, 'the harness agrees' );
};

subtest 'the application directory keeps the :: from -a (known bug F12)' => sub {
    # Current behavior, pinned deliberately. Without -d, the directory is named
    # after the application verbatim -- colons and all -- even though the
    # generator computes a dashed name for exactly this purpose and then
    # discards it. See F12 in paad/test-roadmap/test-roadmap-findings.md. When
    # that is fixed this test goes red; update it to expect Other-App.
    my $dir = tempdir( CLEANUP => 1 );
    my $res = gen( '-a', 'Other::App', '--path', $dir );

    is( $res->{'status'}, 0, 'generating without -d still succeeds' );
    ok( path( $dir, 'Other::App' )->is_dir,
        'the directory is named Other::App, colons included' );
    ok( !path( $dir, 'Other-App' )->exists,
        'and the dashed name the generator computed is not used' );

    # The dashed name does reach the generated Makefile.PL, which is what makes
    # the two spellings visibly disagree inside one generated application.
    like(
        slurp( path( $dir, 'Other::App', 'Makefile.PL' ) ),
        qr/FILES\s*=>\s*'Other-App-\*'/,
        'while Makefile.PL cleans the dashed name instead',
    );
};

subtest 'MANIFEST.SKIP gets an absolute path pattern (known bug F13)' => sub {
    # Current behavior, pinned deliberately: the line appended to MANIFEST.SKIP
    # is built from the full application path rather than the distribution
    # name, so it starts with a '/' and can never match the relative paths
    # MANIFEST.SKIP is compared against. See F13. When fixed, this goes red;
    # update it to expect '^MyApp-App-'.
    my @lines = split /\n/, slurp( $app->child('MANIFEST.SKIP') );
    my $appended = @lines ? $lines[-1] : '';

    like( $appended, qr{^\^/},
        'the appended pattern is anchored to an absolute filesystem path' );
    like( $appended, qr{\Q$app\E-$},
        'it is the generated application\'s own full path with a dash' );

    # The rest of the file is what a MANIFEST.SKIP is supposed to look like,
    # which is what makes the last line stand out.
    ok( ( grep { $_ eq '^\.gitignore' || $_ eq '^.gitignore' } @lines ),
        'the other patterns are relative, as MANIFEST.SKIP expects' );
};

subtest 'the skeleton environment configs are not in git (known bug F14)' => sub {
    # Current state, pinned deliberately. share/.gitignore is shipped as data
    # -- Dancer2::CLI::Gen copies it into a generated app when -g is given --
    # but because it sits inside share/, git also applies its patterns to this
    # repository's own tree, and one of them is 'environments/'. So the
    # skeleton's environment configs can never be committed: they are on this
    # working copy's disk but absent from a fresh clone, which then generates
    # applications without them. See F14 in
    # paad/test-roadmap/test-roadmap-findings.md. When that is fixed, these
    # assertions go red and the two files belong back in @required above.
    my $probe = 'share/skel/default/environments/development.yml';

    my ( undef, undef, $rev_status ) = capture {
        system( 'git', 'rev-parse', '--is-inside-work-tree' );
    };
    $rev_status == 0
        or plan skip_all => 'not a git checkout, so tracking cannot be checked';

    my ( $ignored_by, undef, $ci_status ) = capture {
        system( 'git', 'check-ignore', '-v', $probe );
    };
    is( $ci_status, 0, 'git ignores the skeleton environments directory' );
    like( $ignored_by, qr{share/\.gitignore.*environments/},
        'and the rule doing it is the .gitignore shipped for generated apps' );

    my ($tracked) = capture {
        system( 'git', 'ls-files', 'share/skel/default/environments' );
    };
    is( $tracked, '', 'so no file under it is tracked' );
};

done_testing();
