#!/usr/bin/perl
# ETL: parse web access logs -> clean/transform -> bulk COPY into PostgreSQL.
# Incremental: tracks per-file byte offsets in etl_files, so cron can rerun
# freely; only new files or newly appended bytes are loaded.
use strict;
use warnings;
use lib "$ENV{HOME}/perl5/lib/perl5";
use DBI;
use File::Basename qw(basename);
use FindBin;
use Socket qw(inet_pton AF_INET AF_INET6);
use Time::Local qw(timegm);

chdir $FindBin::Bin or die "chdir $FindBin::Bin: $!";   # cron-friendly paths

my $DSN         = $ENV{ETL_DSN} // 'dbi:Pg:dbname=weblogs';
my $LOG_GLOB    = 'logs/*.log';
my $REJECT_DIR  = 'rejects';
my $DQ_FILE     = 'sql/dq_checks.sql';

my %MON = (Jan=>'01',Feb=>'02',Mar=>'03',Apr=>'04',May=>'05',Jun=>'06',
           Jul=>'07',Aug=>'08',Sep=>'09',Oct=>'10',Nov=>'11',Dec=>'12');

# Combined log format:
# ip ident user [dd/Mon/yyyy:HH:MM:SS +zzzz] "METHOD /path PROTO" status bytes "referer" "ua"
my $LOG_RE = qr{^(\S+) \S+ \S+ \[(\d{2})/(\w{3})/(\d{4}):(\d{2}:\d{2}:\d{2}) ([+-]\d{4})\] "(\S+) (\S+)[^"]*" (\d{3}) (\d+|-) "([^"]*)" "([^"]*)"};

my $dbh = DBI->connect($DSN, '', '',
    { AutoCommit => 0, RaiseError => 1, PrintError => 0 });

# don't overlap with a slow previous run (both would load from the same offset)
my ($locked) = $dbh->selectrow_array(q{SELECT pg_try_advisory_lock(hashtext('perl-etl'))});
unless ($locked) {
    print "another run is in progress, skipping\n";
    exit 0;
}

my ($total_loaded, $total_rejected, $files_touched) = (0, 0, 0);

for my $file (sort glob $LOG_GLOB) {
    my $size = -s $file or next;
    my ($done) = $dbh->selectrow_array(
        'SELECT bytes_done FROM etl_files WHERE filename = ?', undef, $file);
    $done //= 0;
    $done = 0 if $size < $done;   # rotated or truncated: start over
    next if $size <= $done;

    my ($loaded, $rejected, $consumed) = load_file($file, $done);
    $dbh->do(<<'SQL', undef, $file, $consumed, $loaded, $rejected);
        INSERT INTO etl_files (filename, bytes_done, loaded_at, rows_loaded, rows_rejected)
        VALUES ($1, $2, now(), $3, $4)
        ON CONFLICT (filename) DO UPDATE SET
            bytes_done    = EXCLUDED.bytes_done,
            loaded_at     = now(),
            rows_loaded   = etl_files.rows_loaded   + EXCLUDED.rows_loaded,
            rows_rejected = etl_files.rows_rejected + EXCLUDED.rows_rejected
SQL
    $dbh->commit;   # COPY + offset update land atomically: crash = clean retry

    printf "%s: loaded %d, rejected %d (offset %d -> %d)\n",
        $file, $loaded, $rejected, $done, $consumed;
    $total_loaded += $loaded; $total_rejected += $rejected; $files_touched++;
}

print $files_touched ? "TOTAL: $total_loaded loaded, $total_rejected rejected\n"
                     : "nothing to do\n";

my $dq_failed = run_dq_checks();
$dbh->disconnect;
exit($dq_failed ? 1 : 0);

# --- parse + COPY one file from byte offset; returns (loaded, rejected, new_offset)
sub load_file {
    my ($file, $offset) = @_;
    open my $fh, '<', $file or die "open $file: $!";
    seek $fh, $offset, 0 or die "seek $file: $!";

    mkdir $REJECT_DIR unless -d $REJECT_DIR;
    open my $rej, '>>', "$REJECT_DIR/" . basename($file) . '.rej'
        or die "open reject file: $!";

    $dbh->do('COPY log_events (ts, ip, method, path, status, bytes, referer, user_agent, source_file)
              FROM STDIN');
    my ($loaded, $rejected, $consumed) = (0, 0, $offset);

    while (my $line = <$fh>) {
        last unless $line =~ /\n\z/;   # incomplete tail (writer mid-append): pick up next run
        $consumed += length $line;
        chomp $line;
        next if $line =~ /^\s*$/;

        my @m = $line =~ $LOG_RE;
        if (@m && valid_row($line, @m)) {
            my ($ip,$dd,$mon,$yyyy,$hms,$tz,$meth,$path,$status,$bytes,$ref,$ua) = @m;
            my $ts = "$yyyy-$MON{$mon}-$dd $hms $tz";
            $bytes = '\N' if $bytes eq '-';
            $_ = ($_ eq '-' || $_ eq '') ? '\N' : copy_escape($_) for $ref, $ua;
            $dbh->pg_putcopydata(join("\t", $ts, $ip, $meth, copy_escape($path),
                                      $status, $bytes, $ref, $ua, $file) . "\n");
            $loaded++;
        } else {
            print {$rej} "$line\n";
            $rejected++;
        }
    }
    $dbh->pg_putcopyend;
    close $rej;
    return ($loaded, $rejected, $consumed);
}

# --- reject anything Postgres would refuse, since one bad value fails the whole COPY
sub valid_row {
    my ($line, $ip, $dd, $mon, $yyyy, $hms, $tz, undef, undef, $status) = @_;
    return 0 unless $MON{$mon} && $yyyy >= 1970
        && $status >= 100 && $status <= 599
        && $tz =~ /^[+-](?:0\d|1[0-4])[0-5]\d$/
        && (inet_pton(AF_INET, $ip) || inet_pton(AF_INET6, $ip))
        && $line !~ /\0/ && utf8::decode(my $copy = $line);
    my ($h, $mi, $s) = split /:/, $hms;
    return eval { timegm($s, $mi, $h, $dd, $MON{$mon} - 1, $yyyy); 1 };   # catches 31/Feb etc.
}

sub copy_escape {
    my $s = shift;
    $s =~ s/\\/\\\\/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/\r/\\r/g;
    return $s;
}

# --- run sql/dq_checks.sql; any query returning rows = failure
sub run_dq_checks {
    open my $fh, '<', $DQ_FILE or die "open $DQ_FILE: $!";
    local $/; my $sql = <$fh>;
    my $failed = 0;
    while ($sql =~ /--\s*name:\s*(\S+)\n(.*?);/gs) {
        my ($name, $query) = ($1, $2);
        my $rows = $dbh->selectall_arrayref($query);
        if (@$rows) {
            $failed = 1;
            print "DQ FAIL [$name]:\n";
            print '  ', join(' | ', map { $_ // 'NULL' } @$_), "\n" for @$rows;
        }
    }
    print $failed ? "DQ checks FAILED\n" : "DQ checks passed\n";
    return $failed;
}
