#!/usr/bin/perl
# Runs etl.pl against a scratch db: bad values, log rotation, overlapping runs.
# Setup: createdb weblogs_test   Run: prove t/
use strict;
use warnings;
use lib "$ENV{HOME}/perl5/lib/perl5";
use Test::More;
use DBI;
use File::Copy qw(copy);
use File::Temp qw(tempdir);
use FindBin;

my $dsn = $ENV{ETL_TEST_DSN} // 'dbi:Pg:dbname=weblogs_test';
my $dbh = eval { DBI->connect($dsn, '', '', { RaiseError => 1, PrintError => 0 }) }
    or plan skip_all => "no test database at $dsn (createdb weblogs_test)";

my $root = "$FindBin::Bin/..";
$dbh->do(slurp("$root/sql/schema.sql"));
$dbh->do('TRUNCATE log_events, etl_files');

# etl.pl works relative to its own directory, so run a copy in a temp dir
my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/$_" for qw(logs sql);
copy("$root/etl.pl", $dir) and copy("$root/sql/dq_checks.sql", "$dir/sql") or die "copy: $!";

my $t = 0;   # one second per line, so duplicate_events stays quiet
sub line {
    my %f = (ip => '10.0.0.1', date => '01/Jan/2026', status => 200, path => '/x', @_);
    $t++;
    sprintf qq{%s - - [%s:%02d:%02d:%02d +0000] "GET %s HTTP/1.1" %s 10 "-" "t"\n},
        $f{ip}, $f{date}, int($t / 3600), int($t / 60) % 60, $t % 60, $f{path}, $f{status};
}

# --- 1. bad values are rejected, rows after them still load
write_log('>', map(line(), 1 .. 100),
    line(status => '000'), line(date => '31/Feb/2026'),
    line(ip => '999.0.0.1'), line(path => "/\xff"),
    map(line(), 1 .. 10));
my ($exit, $out) = run_etl();
is $exit, 0, 'bad values: run succeeds' or diag $out;
is count(), 110, 'bad values: every good row loaded';
is lines("$dir/rejects/access.log.rej"), 4, 'bad values: all four rejected';

# --- 2. rotation: file truncated and refilled with less than the old offset
write_log('>', map(line(), 1 .. 5));
($exit, $out) = run_etl();
is count(), 115, 'rotation: new file loaded from the start' or diag $out;

# --- 3. overlapping runs: hold the lock as if a run were in progress
write_log('>>', map(line(), 1 .. 5));
$dbh->do(q{SELECT pg_advisory_lock(hashtext('perl-etl'))});
($exit, $out) = run_etl();
like $out, qr/in progress/, 'lock: second run skips';
is count(), 115, 'lock: nothing loaded while locked';
$dbh->do(q{SELECT pg_advisory_unlock(hashtext('perl-etl'))});
run_etl();
is count(), 120, 'lock: loads once released';

done_testing;

sub run_etl {
    local $ENV{ETL_DSN} = $dsn;
    open my $p, '-|', $^X, "$dir/etl.pl" or die "run etl.pl: $!";
    my $out = do { local $/; <$p> };
    close $p;
    return ($? >> 8, $out);
}

sub write_log {
    my $mode = shift;
    open my $fh, $mode, "$dir/logs/access.log" or die $!;
    print {$fh} @_;
}

sub count { $dbh->selectrow_array('SELECT count(*) FROM log_events') }
sub lines { open my $fh, '<', shift or return 0; my @l = <$fh>; scalar @l }
sub slurp { open my $fh, '<', shift or die $!; local $/; <$fh> }
