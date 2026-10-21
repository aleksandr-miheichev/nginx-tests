#!/usr/bin/perl

# Controlled scheduling measurements; this fixture is for the fork only.

use warnings;
use strict;
use Test::More;
use Time::HiRes qw(time);
use JSON::PP;
BEGIN { use FindBin; chdir("$FindBin::Bin/../.."); }
use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

my $t = Test::Nginx->new()->has(qw/http http_v2/)->plan(216)
	->write_file_expand('nginx.conf', <<'EOF');
%%TEST_GLOBALS%%
daemon off;
master_process off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    http2 on;
    server {
        listen 127.0.0.1:8080;
        server_name localhost;
    }
}
EOF

$t->write_file('large', 'x' x (2**20));
$t->write_file('small', 'x' x 8192);
$t->run();

my @small = (8192) x 12;
my @cases = (
	['incremental-small-grants', ['i', 'i', 'i'], \@small],
	['default-small-grants', [undef, undef, undef], \@small],
	['incremental-large-grant', ['i', 'i', 'i'], [196608]],
	['higher-urgency', ['u=3, i', 'u=0, i', 'u=3, i'], \@small],
	['mixed-incremental', ['i', 'i=?0', 'i'], \@small],
	['late-small-incremental', ['i', 'i', 'i'], \@small,
		undef, ['/large', '/small', '/large']],
	['late-small-default', [undef, undef, undef], \@small,
		undef, ['/large', '/small', '/large']],
	['switch-to-nonincremental', ['i', 'i', 'i'], \@small,
		['i=?0', 'i=?0', 'i=?0']],
);

my @results;
push @results, run_case(@$_) for @cases;
my $before_cpu = server_ticks();
my $before = time();
for my $i (1 .. 64) {
	push @results, run_case("bulk-$i", ['i', 'i', 'i'], [3 * 2**20 - 65535]);
}
my $bulk_seconds = time() - $before;
my $bulk_cpu_ticks = server_ticks() - $before_cpu;

my $output = {
	variant => $ENV{SCHEDULER_VARIANT},
	bulk_seconds => $bulk_seconds,
	bulk_server_cpu_ticks => $bulk_cpu_ticks,
	bulk_mib => 192,
	cases => \@results,
};
open my $out, '>', $ENV{SCHEDULER_RESULTS} or die $!;
print $out JSON::PP->new->canonical->pretty->encode($output);
close $out or die $!;

$t->stop();
undef $t;

sub server_ticks {
	my $pid = $t->read_file('nginx.pid');
	chomp $pid;
	open my $stat, '<', "/proc/$pid/stat" or die $!;
	my $line = <$stat>;
	close $stat;
	$line =~ s/^\d+ \(.*\) //;
	my @fields = split / /, $line;
	return $fields[11] + $fields[12];
}

sub request {
	my ($path, $priority) = @_;
	return {headers => [
		{name => ':method', value => 'GET', mode => 0},
		{name => ':scheme', value => 'http', mode => 0},
		{name => ':path', value => $path, mode => 1},
		{name => ':authority', value => 'localhost', mode => 1},
		defined $priority
			? {name => 'priority', value => $priority, mode => 2} : ()
	]};
}

sub run_case {
	my ($name, $priorities, $grants, $updates, $paths) = @_;
	$paths ||= [('/large') x 3];
	my $s = Test::Nginx::HTTP2->new();
	$s->h2_settings(0, 0x4 => 2**24);
	$s->read(all => [{type => 'SETTINGS'}]);

	my (@body, %finished);
	for my $i (0 .. 2) {
		my $sid = $s->new_stream(request($paths->[$i], $priorities->[$i]));
		my $frames = $s->read(all => [$i == 0
			? {sid => $sid, length => 65535}
			: {sid => $sid, fin => 4}]);
		collect($frames, \@body, \%finished);
	}

	my @trace;
	my @first = (undef, undef, undef);
	for my $n (0 .. $#$grants) {
		if ($updates && $n == 1) {
			$s->h2_priority_update(2 * $_ + 1, $updates->[$_])
				for (0 .. 2);
		}
		$s->h2_window($grants->[$n]);
		my $frames = $s->read(all => [{length => $grants->[$n]}]);
		collect($frames, \@body, \%finished);
		my @bytes = (0, 0, 0);
		for my $f (@$frames) {
			next unless $f->{type} eq 'DATA';
			my $i = ($f->{sid} - 1) / 2;
			$bytes[$i] += $f->{length};
			$first[$i] = $n + 1 if !defined($first[$i]) && $f->{length};
		}
		push @trace, \@bytes;
	}

	my @pending = map {{sid => 2 * $_ + 1, fin => 1}}
		grep {!$finished{2 * $_ + 1}} (0 .. 2);
	if (@pending) {
		$s->h2_window(4 * 2**20);
		my $frames = $s->read(all => \@pending);
		collect($frames, \@body, \%finished);
	}
	for my $i (0 .. 2) {
		my $size = $paths->[$i] eq '/small' ? 8192 : 2**20;
		ok(defined($body[$i]) && $body[$i] eq ('x' x $size)
			&& $finished{2 * $i + 1}, "$name - stream " . (2 * $i + 1));
	}
	return {name => $name, grants => $grants, bytes => \@trace,
		first_grant => \@first};
}

sub collect {
	my ($frames, $body, $finished) = @_;
	for my $f (@$frames) {
		next unless $f->{type} eq 'DATA';
		$body->[($f->{sid} - 1) / 2] .= $f->{data};
		$finished->{$f->{sid}} = 1 if $f->{flags} & 1;
	}
}
