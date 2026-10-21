#!/usr/bin/perl

# Slow-reader, bounded socket-buffer comparison. Fork-only fixture.

use warnings;
use strict;
use Test::More;
use Time::HiRes qw(time);
use Socket qw(SOL_SOCKET SO_RCVBUF);
use JSON::PP;
use Digest::SHA qw(sha256_hex);
BEGIN { use FindBin; chdir("$FindBin::Bin/../.."); }
use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

{
	package SlowHTTP2;
	our @ISA = ('Test::Nginx::HTTP2');
	sub raw_read {
		my ($self, $buf, $len, $timeout) = @_;
		$timeout ||= 8;
		my $socket = $self->{socket};
		while (length($buf) < $len
			&& IO::Select->new($socket)->can_read($timeout))
		{
			my $got;
			my $n = $socket->sysread($got, 16384);
			last unless $n;
			Time::HiRes::sleep($n / (4 * 2**20));
			$buf .= $got;
		}
		return $buf;
	}
}

my $t = Test::Nginx->new()->has(qw/http http_v2/)->plan(6)
	->write_file_expand('nginx.conf', <<'EOF');
%%TEST_GLOBALS%%
daemon off;
master_process off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    sendfile on;
    http2 on;
    server {
        listen 127.0.0.1:8080 sndbuf=64k;
        server_name localhost;
    }
}
EOF
$t->write_file('download', 'x' x (8 * 2**20));
$t->write_file('late', 'x' x (4 * 2**20));
$t->run();

my @results;
for my $incremental (0, 1) {
	my $s = SlowHTTP2->new();
	setsockopt($s->{socket}, SOL_SOCKET, SO_RCVBUF, pack('i', 65536))
		or die "setsockopt: $!";
	my $rcvbuf = unpack('i', getsockopt($s->{socket}, SOL_SOCKET, SO_RCVBUF));
	$s->h2_settings(0, 0x4 => 2**24);
	$s->read(all => [{type => 'SETTINGS'}]);
	$s->h2_window(2**27);

	my @body;
	my %finished;
	for my $i (0, 1) {
		my $sid = $s->new_stream(request('/download', $incremental));
		collect($s->read(all => [{sid => $sid, fin => 4}]),
			\@body, \%finished);
	}
	my $start = time();
	my $sid = $s->new_stream(request('/late', $incremental));
	collect($s->read(all => [{sid => $sid, fin => 1}]), \@body, \%finished);
	my $late_seconds = time() - $start;
	my @at_late = map {length($_ || '')} @body;
	my @pending = map {{sid => $_, fin => 1}}
		grep {!$finished{$_}} (1, 3, 5);
	collect($s->read(all => \@pending), \@body, \%finished) if @pending;

	for my $i (0 .. 2) {
		my $size = ($i == 2 ? 4 : 8) * 2**20;
		ok(defined($body[$i]) && sha256_hex($body[$i])
			eq sha256_hex('x' x $size) && $finished{2 * $i + 1},
			"incremental=$incremental stream " . (2 * $i + 1));
	}
	push @results, {incremental => $incremental,
		late_seconds => $late_seconds, bytes_at_late_completion => \@at_late,
		client_rcvbuf_actual => $rcvbuf};
}
open my $out, '>', $ENV{BACKPRESSURE_RESULTS} or die $!;
print $out JSON::PP->new->canonical->pretty->encode({
	variant => $ENV{SCHEDULER_VARIANT}, client_read_mib_per_second => 4,
	server_sndbuf_requested => 65536, results => \@results});
close $out or die $!;
$t->stop();
undef $t;

sub request {
	my ($path, $incremental) = @_;
	return {headers => [
		{name => ':method', value => 'GET', mode => 0},
		{name => ':scheme', value => 'http', mode => 0},
		{name => ':path', value => $path, mode => 1},
		{name => ':authority', value => 'localhost', mode => 1},
		{name => 'priority', value => $incremental ? 'i' : 'i=?0', mode => 2}
	]};
}

sub collect {
	my ($frames, $body, $finished) = @_;
	for my $f (@$frames) {
		next unless $f->{type} eq 'DATA';
		$body->[($f->{sid} - 1) / 2] .= $f->{data};
		$finished->{$f->{sid}} = 1 if $f->{flags} & 1;
	}
}
