#!/usr/bin/perl

# Task-private measurement, not an upstream latency or fairness acceptance test.
# Example:
# perl measure_socket_backpressure.t --fair=on --flow=socket --output=on.ndjson

use warnings;
use strict;

use Test::More;
use Getopt::Long qw/ GetOptions /;
use Time::HiRes qw/ time sleep /;
use JSON::PP;
use Digest::SHA;
use IO::Select;
use IO::Socket::INET;
use Socket qw/ CRLF SOL_SOCKET SO_RCVBUF SO_SNDBUF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib ($ENV{FAIRNESS_TEST_LIB} // die "FAIRNESS_TEST_LIB is required\n");
use Test::Nginx;
use Test::Nginx::HTTP2;

my ($fair, $flow, $size, $stall, $delay, $output) =
	('on', 'socket', 8 * 1024 * 1024, 1, 0.001, undef);
GetOptions(
	'fair=s' => \$fair,
	'flow=s' => \$flow,
	'size=i' => \$size,
	'stall=f' => \$stall,
	'read-delay=f' => \$delay,
	'output=s' => \$output
) or die "Invalid arguments\n";
die "--fair must be on or off\n" unless $fair =~ /^(?:on|off)$/;
die "--flow must be socket or credit\n" unless $flow =~ /^(?:socket|credit)$/;
die "--size must be between 1MiB and 20MiB\n"
	unless $size >= 2**20 && $size <= 20 * 2**20;
die "Invalid reader delay\n" unless $stall >= 0 && $delay >= 0;

$output ||= "$FindBin::Bin/socket-$fair-$flow-$$.ndjson";
open my $log, '>', $output or die "Can't create $output: $!\n";
$log->autoflush(1);
my $json = JSON::PP->new()->canonical();
my $started = time();
my $stream_credit = 2**26;
my $late_size = 256 * 1024;
my $expected_total = 3 * $size + $late_size;
my %length = (1 => $size, 2 => $size, 3 => $size, 4 => $late_size);
my $quantum = 65536;
my $connection_credit = 65535 + ($flow eq 'socket' ? 2**26 : 0);
my ($received, $sequence, $late_active, $late_started, $late_elapsed) =
	(0, 0, 0, undef, undef);
my (%bytes, %hash, %fin, %last_byte, %max_gap, %source, %expected_hash);
my ($ping, $errors, $minimum_credit) = (0, 0, $connection_credit);
my @late_completion;

for my $id (1 .. 4) {
	my $digest = Digest::SHA->new(256);
	my $left = $length{$id};
	while ($left) {
		my $block = body_block($id, $length{$id} - $left);
		my $n = $left > length($block) ? length($block) : $left;
		$digest->add(substr($block, 0, $n));
		$left -= $n;
	}
	$expected_hash{$id} = $digest->hexdigest();
}

emit('conditions', {
	fair => $fair, flow => $flow, epoch => $started,
	large_body_bytes => $size, late_body_bytes => $late_size,
	total_expected_bytes => $expected_total,
	stream_window => $stream_credit,
	initial_connection_credit => $connection_credit,
	server_sndbuf_requested => 8192, client_rcvbuf_requested => 4096,
	origin_sndbuf_requested => 8192,
	reader_stall_seconds => $stall, reader_delay_per_frame_seconds => $delay,
	cpu_measurement => undef,
	note => 'Socket pressure is induced, not proved by elapsed time. Check the debug log or external socket telemetry to confirm actual blocked writes.'
});

my $t = Test::Nginx->new()->has(qw/http http_v2 proxy/)->plan(16);
my $config = <<'EOF';

%%TEST_GLOBALS%%

daemon off;

events {
    worker_connections 128;
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen 127.0.0.1:8080 sndbuf=8k;
        server_name localhost;
        http2 on;
        http2_fair_scheduling FAIR_MODE;
        send_timeout 60s;

        location / {
            proxy_pass http://127.0.0.1:8081;
            proxy_http_version 1.1;
            proxy_buffering off;
            proxy_buffer_size 4k;
            proxy_read_timeout 60s;
        }
    }
}

EOF
$config =~ s/FAIR_MODE/$fair/;
$t->write_file_expand('nginx.conf', $config);
$t->run_daemon(\&http_daemon);
$t->run()->waitforsocket('127.0.0.1:' . port(8081));
emit('nginx_started', { testdir => $t->testdir(), binary => $Test::Nginx::NGINX });

my $socket = IO::Socket::INET->new(
	Proto => 'tcp', PeerAddr => '127.0.0.1:' . port(8080)
) or die "Can't connect measurement socket: $!\n";
ok(setsockopt($socket, SOL_SOCKET, SO_RCVBUF, pack('i', 4096)),
	'client receive buffer configured');
emit('client_socket', {
	rcvbuf_actual => unpack('i', getsockopt($socket, SOL_SOCKET, SO_RCVBUF))
});
my $s = Test::Nginx::HTTP2->new(undef, socket => $socket);
$s->start_chain();
$s->h2_settings(0, 0x4 => $stream_credit);
$s->h2_window(2**26) if $flow eq 'socket';
$s->send_chain();
$s->read(all => [{ type => 'SETTINGS' }]);
ok($stream_credit > $size && ($flow ne 'socket'
	|| $connection_credit > $expected_total), 'advertised credit exceeds bodies');

$s->start_chain();
my @ids;
for my $id (1 .. 3) {
	my $sid = $s->new_stream({ path => "/stream/$id" });
	push @ids, $sid;
	$source{$sid} = $id;
	$hash{$sid} = Digest::SHA->new(256);
}
$s->send_chain();
my $initial = $s->read(all => [map { { sid => $_, fin => 4 } } @ids]);
observe($_) for @$initial;
is(scalar(grep { $_->{type} eq 'HEADERS'
	&& $_->{headers}{':status'} eq '200' } @$initial),
	3, 'all large origins returned headers');
ok(!(grep { $fin{$_} } @ids), 'large responses remain active at reader stall');

emit('reader_stall_start', { received => $received,
	active_large_streams => scalar(grep { !$fin{$_} } @ids) });
sleep($stall);
emit('reader_stall_end', { received => $received });
$s->start_chain();
my $late = $s->new_stream({ path => '/stream/4' });
$source{$late} = 4;
$hash{$late} = Digest::SHA->new(256);
$late_active = 1;
$late_started = time();
$last_byte{$late} = $received;
push @ids, $late;
$s->h2_ping('MEASURE!');
$s->send_chain();
emit('late_request', { sid => $late, received => $received });

my $deadline = time() + 120;
while (time() < $deadline) {
	if ($flow eq 'credit' && $received == $connection_credit) {
		$s->h2_window($quantum);
		$connection_credit += $quantum;
		emit('connection_grant', { bytes => $quantum,
			credit_total => $connection_credit, received => $received });
	}
	my $frames = $s->read();
	last unless @$frames;
	observe($_) for @$frames;
	last if $ping && !grep { !$fin{$_} } @ids;
	sleep($delay) if $delay;
}

for my $sid (@ids) {
	my $id = $source{$sid};
	is($hash{$sid}->hexdigest(), $expected_hash{$id}, "stream $sid SHA256 integrity");
	is($fin{$sid} || 0, 1, "stream $sid exactly one END_STREAM");
}
is($received, $expected_total, 'all expected payload bytes received');
ok($ping, 'PING acknowledged with pending response data');
is($errors, 0, 'no GOAWAY or RST_STREAM');
ok($flow ne 'socket' || ($minimum_credit > 0
	&& !grep { ($bytes{$_} || 0) >= $stream_credit } @ids),
	'socket variant never approaches connection or stream credit exhaustion');

my $debug = $t->read_file('error.log');
my @would_block = $debug =~ /^.*(?:EAGAIN|WSAEWOULDBLOCK|10035|not ready).*$/mg;
emit('summary', {
	received => $received, expected => $expected_total,
	connection_credit_total => $connection_credit,
	minimum_remaining_connection_credit => $minimum_credit,
	bytes_by_sid => \%bytes, fin_by_sid => \%fin,
	maximum_other_payload_between_data_frames => \%max_gap,
	large_bytes_at_late_completion => \@late_completion,
	late_seconds_observed => $late_elapsed,
	debug_would_block_pattern_count => scalar @would_block,
	debug_would_block_samples => [@would_block[0 .. ($#would_block < 4 ? $#would_block : 4)]],
	cpu_measurement => undef,
	note => 'No universal service-gap or latency threshold is asserted. Debug matches are hints, not a portable proof of send-side backpressure.'
});
diag "Measurement NDJSON: $output";

# Close the measured connection before the harness requests graceful shutdown.
undef $s;
close $socket;
$t->stop();

sub emit {
	my ($event, $fields) = @_;
	print $log $json->encode({ event => $event,
		seconds => time() - $started, %$fields }) . "\n";
}

sub observe {
	my ($frame) = @_;
	my $sid = $frame->{sid};
	$errors++ if $frame->{type} =~ /^(?:GOAWAY|RST_STREAM)$/;
	if ($frame->{type} eq 'PING' && ($frame->{flags} & 1)) {
		$ping++ if $frame->{value} eq 'MEASURE!';
		emit('ping_ack', { received => $received, late_active => $late_active });
	}
	if ($frame->{type} eq 'DATA') {
		my $n = $frame->{length};
		my $gap = $received - ($last_byte{$sid} || 0);
		$max_gap{$sid} = $gap if !defined $max_gap{$sid} || $gap > $max_gap{$sid};
		$received += $n;
		$bytes{$sid} += $n;
		$hash{$sid}->add($frame->{data}) if $hash{$sid};
		$last_byte{$sid} = $received;
		my $remaining = $connection_credit - $received;
		$minimum_credit = $remaining if $remaining < $minimum_credit;
		emit('data', { seq => ++$sequence, sid => $sid, bytes => $n,
			stream_received => $bytes{$sid}, received => $received,
			connection_credit_left => $remaining,
			stream_credit_left => $stream_credit - $bytes{$sid},
			other_payload_gap => $gap, late_active => $late_active });
	}
	if (($frame->{type} eq 'DATA' || $frame->{type} eq 'HEADERS')
		&& ($frame->{flags} & 1)) {
		$fin{$sid}++;
		emit('end_stream', { sid => $sid, received => $received });
		if ($source{$sid} && $source{$sid} == 4) {
			@late_completion = map { $bytes{$_} || 0 } @ids[0 .. 2];
			$late_active = 0;
			$late_elapsed = time() - $late_started;
			emit('late_completion', {
				large_bytes => \@late_completion,
				late_seconds_observed => $late_elapsed
			});
		}
	}
}

sub body_block {
	my ($id, $offset) = @_;
	return pack('N2', $id, $offset / 8192) x 1024;
}

sub http_daemon {
	my $server = IO::Socket::INET->new(
		Proto => 'tcp', LocalHost => '127.0.0.1:' . port(8081),
		Listen => 16, Reuse => 1
	) or die "Can't create origin socket: $!\n";
	local $SIG{PIPE} = 'IGNORE';
	my $read = IO::Select->new($server);
	my $write = IO::Select->new();
	my (%pending, %remaining, %origin, %offset);
	while (1) {
		my ($r, $w) = IO::Select->select($read, $write, undef, 1);
		for (@{$r || []}) {
			my $client = $server->accept() or next;
			my $headers = '';
			while (<$client>) {
				$headers .= $_;
				last if /^\x0d?\x0a$/;
			}
			unless ($headers =~ m!^GET /stream/([1-4]) !) {
				close $client;
				next;
			}
			my $id = $1;
			my $fd = $client->fileno();
			setsockopt($client, SOL_SOCKET, SO_SNDBUF, pack('i', 8192));
			$client->blocking(0);
			$pending{$fd} = 'HTTP/1.1 200 OK' . CRLF
				. 'Content-Length: ' . $length{$id} . CRLF
				. 'Connection: close' . CRLF . CRLF;
			$remaining{$fd} = $length{$id};
			$origin{$fd} = $id;
			$offset{$fd} = 0;
			$write->add($client);
		}
		for my $client (@{$w || []}) {
			my $fd = $client->fileno();
			if (!length($pending{$fd}) && $remaining{$fd}) {
				my $block = body_block($origin{$fd}, $offset{$fd});
				my $n = $remaining{$fd} > length($block)
					? length($block) : $remaining{$fd};
				$pending{$fd} = substr($block, 0, $n);
				$remaining{$fd} -= $n;
				$offset{$fd} += $n;
			}
			my $n = $client->syswrite($pending{$fd});
			next unless defined $n;
			substr($pending{$fd}, 0, $n, '');
			next if length($pending{$fd}) || $remaining{$fd};
			$write->remove($client);
			delete $pending{$fd};
			delete $remaining{$fd};
			delete $origin{$fd};
			delete $offset{$fd};
			close $client;
		}
	}
}
