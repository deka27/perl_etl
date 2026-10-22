#!/usr/bin/perl
# Appends N sample combined-format access log lines to logs/access.log.
# ~2% are deliberately malformed to exercise the reject path.
# Usage: perl gen_logs.pl [N]   (default 300)
use strict;
use warnings;
use POSIX qw(strftime);
use FindBin;

chdir $FindBin::Bin or die $!;
my $n = $ARGV[0] // 300;

my @paths  = qw(/ /index.html /about /api/users /api/orders /login /logout
                /static/app.js /static/style.css /img/logo.png /search /admin);
my @meths  = (('GET') x 8, 'POST', 'PUT');
my @status = ((200) x 14, 301, 304, 404, 404, 403, 500);
my @uas    = ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Firefox/128.0',
              'curl/8.4.0', 'Googlebot/2.1 (+http://www.google.com/bot.html)');

mkdir 'logs' unless -d 'logs';
open my $fh, '>>', 'logs/access.log' or die $!;

my $t = time - $n;   # one line per ~second, ending now
for my $i (1 .. $n) {
    $t += rand() < 0.8 ? 1 : 0;
    if (rand() < 0.02) {
        print {$fh} "garbled line no. $i \x{7f}!!\n";   # malformed on purpose
        next;
    }
    my $ip   = join '.', 10, 0, int(rand 256), 1 + int(rand 254);
    my $ts   = strftime('%d/%b/%Y:%H:%M:%S %z', localtime $t);
    my $path = $paths[rand @paths];
    my $st   = $status[rand @status];
    my $ref  = rand() < 0.5 ? '-' : 'https://example.com/';
    printf {$fh} '%s - - [%s] "%s %s HTTP/1.1" %d %d "%s" "%s"' . "\n",
        $ip, $ts, $meths[rand @meths], $path, $st, int(rand 50_000), $ref, $uas[rand @uas];
}
close $fh;
print "appended $n lines to logs/access.log\n";
