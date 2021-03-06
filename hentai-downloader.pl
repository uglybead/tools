#!/usr/bin/perl -w

use strict;
use warnings;
use Cwd;
use Mojo::DOM;
use File::Compare;
use File::Fetch;
use File::Basename;
use Data::Dumper;
use HTML::Entities;
use Getopt::Long;
use POSIX ":sys_wait_h";
use Fcntl qw(:flock SEEK_END);
use Tie::File;
use English;
use Storable;
use File::Copy;
use DateTime;
use JSON::RPC::Legacy::Server::Daemon;
use URI::Encode qw(uri_encode uri_decode);
use File::Spec;
use lib dirname(File::Spec->rel2abs(__FILE__)) . '/hd-lib';

use g_e_hentai qw(fetch_from_g_e is_g_e_url);
use the_doujin qw(fetch_from_the_doujin is_the_doujin_url);
use e621_pool  qw(fetch_from_e621 is_e621_pool_url);
use nhentai    qw(fetch_from_nhentai is_nhentai_url);
use pururin2   qw(fetch_from_pururin is_pururin_url);
use hd_common qw(padTo4 getDomObj deepsleep filePutContents fileGetContents timestamp pathOrUndef);

my @handlers = (make_pair(\&is_g_e_url,        \&fetch_from_g_e),
		make_pair(\&is_the_doujin_url, \&fetch_from_the_doujin),
		make_pair(\&is_e621_pool_url,  \&fetch_from_e621),
		make_pair(\&is_nhentai_url,    \&fetch_from_nhentai),
		make_pair(\&is_pururin_url,    \&fetch_from_pururin));

my $stop = 0;
my $start = 0;
my $max_retries = 5;
my @newurls;
my $pidfile          = $ENV{'HOME'} . '/' . '.ge-downloader.pid';
my $enablerpcdaemon  = (1 == 1);
my $rpcdaemonpidfile = $ENV{'HOME'} . '/' . '.ge-downloader-rpc-daemon.pid';
my $queue    	     = $ENV{'HOME'} . '/' . '.ge-queue';
my $tmp_file         = $ENV{'HOME'} . '/' . '.ge-sync-tmp';
my $dl_dir           = $ENV{'HOME'} . '/' . '/ge-downloads/';
my $curr_file        = $ENV{'HOME'} . '/' . '.ge-current-download';
# To generate ssl keys do this:
# openssl req -nodes -new -newkey rsa:8192 -x509 -keyout ~/.ge-ssl-key -out ~/.ge-ssl-cert
my $ssl_key	     = pathOrUndef($ENV{'HOME'} . '/' . '.ge-ssl-key');
my $ssl_cert	     = pathOrUndef($ENV{'HOME'} . '/' . '.ge-ssl-cert');
my $rpc_pid = -1;
binmode(STDOUT, ":utf8");
chdir($dl_dir);

my $started = 0;
my @tied_queue;

my @redownloads;

GetOptions( 	"stop" => \$stop,
		"start" => \$start,
		"add=s" => \@newurls,
		"re=s" =>  \@redownloads);

$SIG{'USR1'} = \&handle_new_urls;
$SIG{'USR2'} = \&reverse_queue;
$SIG{'TERM'} = \&handle_stop;
# Disable everything except lwp and http::lite, otherwise we loop through way, way too much.
$File::Fetch::BLACKLIST = [qw| wget curl lftp fetch lynx iosock|];

if(!$stop && !$start && $#ARGV >= 0) {
	push @newurls, @ARGV;
}

if($#redownloads >= 0) {
	my @redowns = find_redownloads(@redownloads);
	push @newurls, @redowns;
}

if($#newurls >= 0) {
	add_new_urls();
}

if($start) {

	if(check_running()) {
		print "Already running\n";
		exit 1;
	}

	do_start();
}

if(!$start && $stop) {
	do_stop();
}

sub is_understood_url {
	my $url = shift;
	for (my $i = 0; $i <= $#handlers; ++$i) {
		my ($validator, $unused) = @{$handlers[$i]};
		if (&$validator($url)) {
			return 1==1;
		}
	}
	return 1==0;
}

sub reverse_queue {

	print "Reversing queue\n";
	@tied_queue = reverse @tied_queue;

}

sub handle_stop {
	print "Received stop request. Will stop after this download completes.\n";
	$stop = (1 == 1);
	return if ! $enablerpcdaemon;
	my $rpc_pid = get_rpc_daemon_pid();
	if (defined($rpc_pid) && $rpc_pid > 0) {
		kill 'TERM', $rpc_pid;
	}
}

sub handle_new_urls {

	print "Request to add new urls for processing\n";

	my $limit = 20;

	while(! $started) {
		deepsleep(5);
		if($limit-- < 0) {
			return;
		}
	}

	if( -e $tmp_file) {
		open(my $file, '<', $tmp_file);
		flock($file, LOCK_SH);
		while(<$file>) {
			my $line = $_;
			$line =~ s/\s*$//;
			if (is_understood_url($line)) {
				$tied_queue[$#tied_queue+1] = $line;
				print "\tAdded:  " . $line . "\n";
			} else {
				print "\tDon't know how to handle:  " . $line . "\n";
			}
		}
		unlink $tmp_file;
		close($file);
	}

	print "Add request finished :" . timestamp() . "\n";

}

sub get_rpc_daemon_pid {
	return get_processor_pid_from_file($rpcdaemonpidfile);
}

sub get_processor_pid {
	return get_processor_pid_from_file($pidfile);
}

sub get_processor_pid_from_file {
	my $filename = shift;
	open(my $file, '<', $filename) or return undef;
	my $pid = <$file>;
	close($file);
	if($pid !~ /(\d+)/) {
		return undef;
	}

	return int($1);
}

sub add_new_urls {
	return add_new_urls_args($tmp_file, \@newurls);
}

sub add_new_urls_args {
	my $tmpfile = shift();
	my @urls = @{ shift() };
	open(my $file, '+>', $tmpfile);
	flock($file, LOCK_EX);
	seek($file, 0, SEEK_END);

	for(my $i = 0; $i <= $#urls; ++$i) {
		print $file $urls[$i] . "\n";
	}
	flock($file, LOCK_UN);
	close($file);

	my $pid = get_processor_pid();

	if(defined($pid)) {
		kill('USR1', $pid);
	}

}

sub do_stop {
	my $pid = get_processor_pid();
	kill('TERM', $pid);
}

sub write_pid {
	return write_pid_to_file($pidfile);
}

sub write_rpc_daemon_pid {
	return write_pid_to_file($rpcdaemonpidfile);
}

sub write_pid_to_file {
	my $filename = shift;
	open(my $file, '>', $filename);
	print $file $PID;
	close($file);
}

sub check_running {

	if( ! -e $pidfile) {
		return 0 == 1;
	}

	my $ppid = get_processor_pid();	

	my $running = `ps aux | grep '^$ppid' | grep -v grep | grep perl | wc -l`;

	if($running !~ /(\d+)/) {
		print "Unable to determine if we're already running\n";
		print "Bailing\n";
		exit 1;
	}

	return $1 > 0;
}

sub run_appropriate_handler {
	my $url = shift;
	for (my $i = 0; $i <=$#handlers; ++$i) {
		my ($checker, $downloader) = @{ $handlers[$i] };
		if (&$checker($url)) {
			return &$downloader($url);
		}
	}
	print "None of the handlers knew how to handle: [$url]\n";
}

sub load_current_file {
	my $curr_file = shift;
	my $queue_ref = shift;
	for (my $i = 0; $i < scalar(@handlers); ++$i) {
		my $old_url = fileGetContents($curr_file . '-' . $i);
		if ($old_url =~ /^\s*$/) {
			print "No interrupted download to restart.\n";
			next;
		}
		unshift($queue_ref, $old_url);
		print "Added a previously running download to the front of the queue: [$old_url]\n";
	}
}

sub get_handlable_url {
	my $queue_ref = shift;
	my $matcher = shift;
	for (my $i = 0; $i < scalar(@{$queue_ref}); ++$i) {
		if(&$matcher($queue_ref->[$i])) {
			my $ent = $queue_ref->[$i];
			splice($queue_ref, $i, 1);
			return $ent;
		}
	}
	return undef;
}

sub child_is_done {
	my $child_pid = shift;
	my $check = waitpid($child_pid, WNOHANG);
	return $child_pid == $check;
}

sub fork_download {
	my $url = shift;
	my $index = shift;
	my $childpid = fork();
	if ($childpid == 0) {
		filePutContents($curr_file . '-' . $index, $url);
		run_appropriate_handler($url);
		filePutContents($curr_file . '-' . $index, "");
		exit;
	} else {
		return $childpid;
	}
}

sub do_start {

	tie @tied_queue, 'Tie::File', $queue or die("Unable to tie the processing queue");

	write_pid();

	$started = 1;

	my $wait_notify = 0;
	print "Download directory: [" . getcwd() . "]\n";

	kill('USR1', $PID); # Check for enqueued items

	run_rpc_daemon();

	load_current_file($curr_file, \@tied_queue);

	my @processors;
	for(my $i = 0; $i < scalar(@handlers); ++$i) {
		$processors[$i] = undef;
	}

	while(! $stop) {
		if($#tied_queue < 0) {
			if(!$wait_notify) {
				print "Waiting for new queue items.\n";
				print "Queue empty since: " . timestamp() . "\n";
				$wait_notify = 1;
			}
			deepsleep(10);
			next;
		}
		for (my $i = 0; $i < scalar(@handlers); ++$i) {
			if (defined($processors[$i])) {
				if (child_is_done($processors[$i])) {
					$processors[$i] = undef;
				} else {
					deepsleep(1);
					next;
				}
			}
			my $matcher = $handlers[$i]->[0];
			my $nxturl = get_handlable_url(\@tied_queue, $matcher);
			if (!defined($nxturl)) {
				next;
			}
			$processors[$i] = fork_download($nxturl, $i);
			$wait_notify = 0;
		}
	}

	unlink $pidfile;

}

##################
##  RPC Server  ##
##################

my $parent_pid;

sub run_rpc_daemon {
	if (!$enablerpcdaemon) {
		return;
	}
	$parent_pid = $$;
	my $pid = fork();
	if ($pid < 0) {
		die("Failed to fork RPC daemon\n");
	}
	if ($pid != 0) {
		# Parent just continues on.
		return;
	}
	my $pid2 = fork();
	if ($pid2 != 0) {
		# Double fork
		exit();
	}
	use Mojo::Server::Daemon;
	print "Starting RPC daemon with pid: $PID\n";
	write_rpc_daemon_pid();
	$SIG{'TERM'} = "DEFAULT";  # Infinite kill loops are bad
	my $port = int(ord('g') * 256 + ord('e'));  # 26469
	my $ssl_stanza = (!defined($ssl_key) || !defined($ssl_cert)) ? "" :
			 "?cert=" . $ssl_cert . "&key=" . $ssl_key;
	my $http = "http" . ($ssl_stanza eq "" ? "" : "s");
	my $daemon = Mojo::Server::Daemon->new(
		listen => [$http . '://127.0.0.1:' . $port . $ssl_stanza]);
	$daemon->unsubscribe('request');
	$daemon->on(request => \&rpc_daemon_request_handler);
	$daemon->run;
	die();
}

sub make_pair {
	my $a = shift;
	my $b = shift;
	my @arr = ($a, $b);
	return \@arr;
}

sub finalize_tx {
	my $tx = shift;
	my $response = shift;
	$tx->on(finish => sub {
		print $response . "\n";
		print "Transaction finished.\n";
	});
	$tx->res->body($response);
	$tx->resume();
}

sub rpc_daemon_request_handler {
	my ($daemon, $tx) = @_;
	my $method = $tx->req->method;
	my $path   = $tx->req->url->path;

	$tx->res->code(200);
	$tx->res->headers->content_type('text/plain');
	$tx->res->headers->add('Access-Control-Allow-Origin', '*');

	if (!defined($tx->req->url->query)) {
		return finalize_tx($tx, "FAIL: no query");
	}
	if ($tx->req->url->query !~ /^addr=(.*)$/) {
		return finalize_tx($tx, "FAIL: needs an addr");
	}
	my $url = uri_decode($1);
	if (!is_understood_url($url)) {
		return finalize_tx($tx, "FAIL: couldn't validate url");
	}
	print "RPC request to add url: $url\n";
	my @urls = [];
	$urls[0] = $url;
	add_new_urls_args($tmp_file, \@urls);
	finalize_tx($tx, "SUCCESS");
}

