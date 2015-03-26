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
use POSIX ();
use Fcntl qw(:flock SEEK_END);
use Tie::File;
use English;
use Storable;
use File::Copy;
use DateTime;
use JSON::RPC::Legacy::Server::Daemon;

my $stop = 0;
my $start = 0;
my $max_workers = 3;
my $max_retries = 5;
my @newurls;
my $pidfile  = $ENV{'HOME'} . '/' . '.ge-downloader.pid';
my $queue    = $ENV{'HOME'} . '/' . '.ge-queue';
my $tmp_file = $ENV{'HOME'} . '/' . '.ge-sync-tmp';
my $dl_dir   = $ENV{'HOME'} . '/' . '/ge-downloads/';
my $rpc_pid = -1;
chdir($dl_dir);
my $long_retries_file = $ENV{'HOME'} . '/' . '.ge-long-retries';

my $started = 0;
my @tied_queue;

my $bindir = dirname(__FILE__);
my @badfiles = ($bindir . '/g-e-bad-image-1.gif', $bindir . '/g-e-bad-image-2.gif');

my @redownloads;

GetOptions( 	"stop" => \$stop,
		"start" => \$start,
		"workers=i" => \$max_workers,
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

sub reverse_queue {

	print "Reversing queue\n";
	@tied_queue = reverse @tied_queue;

}

sub handle_stop {
	print "Received stop request. Will stop after this download completes.\n";
	$stop = (1 == 1);
	if ($rpc_pid > 0) {
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
			$tied_queue[$#tied_queue+1] = $line;		
			print "\tAdded:  " . $line . "\n";
		}
		unlink $tmp_file;
		close($file);
	}

	print "Add request finished :" . timestamp() . "\n";

};

sub timestamp {
	my $dt = DateTime->now();
        return $dt->ymd . ' ' . $dt->hms;
}

sub get_processor_pid {

	open(my $file, '<', $pidfile);
	my $pid = <$file>;
	close($file);
	if($pid !~ /(\d+)/) {
		return undef;
	}

	return $1;
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

	for(my $i = 0; $i <= $#newurls; ++$i) {
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

	open(my $file, '>', $pidfile);
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

sub do_start {

	tie @tied_queue, 'Tie::File', $queue or die("Unable to tie the processing queue");

	write_pid();

	$started = 1;

	my $wait_notify = 0;
	print "Download directory: [" . getcwd() . "]\n";

	kill('USR1', $PID); # Check for enqueued items

	#run_rpc_daemon();

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

		my $nxturl = shift(@tied_queue);
		main($nxturl);
		$wait_notify = 0;

	}

	unlink $pidfile;

}



sub main {

	my $baseurl = shift;

	print "Finding first page for: $baseurl\n";

	my $lasturl = "";
	my $url = getFirstPage($baseurl);

	my $imgcnt = 0;

	my $max_children = $max_workers > 3 ? $max_workers : 3;
	print "Using $max_children worker processes\n";
	my $current_children = 0;

	my $title = undef;
	my $outdir = undef;

	while($url ne $lasturl) {

		my $tailid = getTailId($url);

		my $current_page = $url;

		my $dm = getDomObj($url);

		if(!defined($title)) {
			$title = decode_entities(findTitle($dm));
			$title =~ s/\//-/g;
			if(-d $title) {
				$outdir = $title;
			} else {
				mkdir("." . $title);
				$outdir = "." . $title;
			}
			filePutContents($outdir . '/original_address.url',
					$baseurl);
		}

		$dm->find("div.sni > a")->each(sub {

			my $ent = shift;

			if($ent->{href} =~ /$tailid-(\d+)\/?/) {
				$lasturl = $url;
				$url = $ent->{href};
				print "Next url: $url\n";
			
			}

			$imgcnt++;
			my $pid = fork();

			if(!defined($pid)) {
				print "Fork Failed!\n";
				print "  Downloading in main process.\n";
				getImageOnPage($current_page, $ent, $title, $imgcnt, $tailid, $outdir, $max_retries);
				return;
			}

			if($pid != 0) {
				use POSIX ":sys_wait_h";
				$current_children++;
				while(waitpid(-1, WNOHANG) > 0) {
					$current_children--;
				}
				while($current_children >= $max_children) {
					wait();
					$current_children--;
				}
				deepsleep(2+rand(5));
				return;
			} 

			getImageOnPage($current_page, $ent, $title, $imgcnt, $tailid, $outdir, $max_retries);

			exit 0;
		});

	}

	print "All images enqueued, waiting on workers to finish. (" . $current_children . " outstanding workers) " . timestamp() . "\n";

	while(wait() != -1) { }

	move("." . $title, $title);
	my $slptime = 60 + rand(3 * 60);
	if($stop) { 
		$slptime = 1; # Don't wait if we're quitting
	}
	print "Finished downloading: $title\n";
	print "Sleeping $slptime seconds before starting next " . timestamp() . "\n";
	deepsleep($slptime);
}

sub getImageOnPage {

	my $pageurl = shift;
	my $domentity = shift;
	my $title = shift;
	my $imgcnt = shift;
	my $tailid = shift;
	my $outdir = shift;
	my $retrylimit = shift;
	my $is_retry   = shift;

	my $success = (0 == 1);

	if($retrylimit < 0) {
		print "Gave up on image number $imgcnt in '$title'.\n";
		print "  Too many failed attempts to download.\n";
		return;
	}


	if(!$domentity) {
		my $dm = getDomObj($pageurl);
		$dm->find("div.sni > a")->each(sub {
			my $ent = $_;
			if($ent->{href} =~ /$tailid-(\d+)\/?/) {
				$domentity = $ent;
			}
		});
	}

	if(!$domentity) {
		print "Couldn't get dom object for image page: $pageurl\n";
		print "  Retries remaining: $retrylimit\n";
		deepsleep(10 + rand(80));
		return getImageOnPage($pageurl, undef, $title, $imgcnt, $tailid, $outdir, $retrylimit - 1);
	}

	$domentity->find("img")->each(sub {
		my $img = shift;

		my $ff = undef;
		$ff = File::Fetch->new(uri => $img->{src});
		$File::Fetch::WARN = (0 == 1);
		if(!$ff->fetch() || !checkFile($ff->output_file)) {
			print "Failed during fetch of image # $imgcnt.\n";
			print "  Retries remaining: $retrylimit \n";
			deepsleep(30 + rand(30));
			return getImageOnPage($pageurl, undef, $title, $imgcnt, $tailid, $outdir, $retrylimit - 1);
		}

		my($a,$b,$suffix) = fileparse($ff->output_file, qr/\.[^.]*/);
		my $ouput_file = $outdir . '/' . $title . ' ' . padTo4($imgcnt)  . $suffix;
		move($ff->output_file, $ouput_file);
		print "Fetched: $ouput_file\n";
	});


}

sub checkFile {

	my $lfile = shift;

	for my $bdfile (@badfiles) {
		if(compare($bdfile, $lfile) == 0) {
			print "Found bandwidth exceeded image! Sleeping for quite a while\n";
			deepsleep(4 * 60 * 60);
			return 0==1;
		}
        }
	return 1==1;

}

sub padTo4 {

	my $val = shift;

	while(length($val) < 4) {
		$val = '0' . $val;
	}
	return $val;

}

sub findTitle {

	my $dom = shift;

	my $ret = undef;

	$dom->find("div.sni > h1")->each(sub {

		my $ent = shift;

		$ret = $ent;

		$ret =~ s/\<\/?h1\/?\>//g;


	});
	
	print "Found title: $ret\n";

	return $ret;

}

sub getTailId {

	my $url = shift;

	if($url =~ /(\d+)-(\d+)\/?$/) {
		return $1;
	}
	return undef;

}

sub getDomObj {

        my $url = shift;

        my $dt = `curl --max-redirs 8 '$url' 2>/dev/null`;

        my $dom = Mojo::DOM->new($dt);

        return $dom;

}


sub findFirstPage {

	my $infourl = shift;

	my $dom = getDomObj($infourl);

	my $outurl = undef;

	$dom->find("div.gdtm a")->each(sub {

		my $ent = shift;

		if($ent->{href} =~ /\d+-0*1\/?$/) {
                        $outurl = $ent->{href};
                        print "First image: $outurl\n";

                } else {
			#print "Rejected link: " . $ent->{href} . "\n";
		}
	});

	if(!defined($outurl)) {
		print "Unable to find first page...\n";
	}

	return $outurl;

}

sub getFirstPage {

	my $url = shift;

	if( $url =~ /-\d+\/?$/) {
		return $url; # We were just given it
	}

	return findFirstPage($url);
	

}

sub deepsleep {
	# To keep the various signals from cutting sleeps short
	my $limit = shift;

	my $end = time() + $limit;

	while(time() < $end) {
		my $ns = $end - time();
		if($ns >= 1) {
			sleep($ns);
		} else {
			sleep(1);
		}
	}

}

sub saveDelayedRetry {

	my $infourl = shift;
	my $title = shift;
	my $imgcnt = shift;
	my $tailid = shift;
	my $long_retries_remaining = shift;

	my @bits = (60 * 60 * 6, $infourl, $title, $imgcnt, $tailid, $long_retries_remaining);

	my $arr = lock_retrieve($long_retries_file);

	my @ar = @{ $arr };
	$ar[$#ar+1] = \@bits;

	lock_store(\@ar, $long_retries_file);
	

}

sub filePutContents {

	my $filename = shift;
	my $contents = shift;

	open(FILBY, '>', $filename);

        print FILBY $contents;

	close(FILBY);

}

sub fileGetContents {
	my $filename = shift;
	open(FILBY, '<', $filename);
	my $ret = '';
	while(<FILBY>) {
		$ret .= $_;
	}
	close(FILBY);
	return $ret;
}

sub find_redownloads {

	my @dirs = shift;
	my @ret;
	for my $dir (@dirs) {
		if(-d $dir && -r $dir . '/original_address.url') {
			$ret[$#ret+1] = fileGetContents($dir . '/original_address.url');
		}
	}
	return @ret;

}

##################
##  RPC Server  ##
##################

my $parent_pid;

sub run_rpc_daemon {
	$parent_pid = $$;
	my $pid = fork();
	if ($pid < 0) {
		die("Failed to fork RPC daemon\n");
	}
	if ($pid != 0) {
		$rpc_pid = $pid;
		print "RPC Daemon running with pid: $pid\n";
		# Parent just continues on.
		return;
	}
	JSON::RPC::Legacy::Server::Daemon->new(
		LocalPort => ord('g') * 256 + ord('e'),  # 26469
		LocalAddr => '127.0.0.1')
            ->dispatch({'/jsonrpc/API' => 'GehdRpc'})
            ->handle();
}

package GehdRpc;

use base qw(JSON::RPC::Legacy::Procedure);

sub enqueue : Public(addr:string) {
	my ($s, $req) = @_;
	print  $req->{'addr'} . " requested via rpc\n";
	my @urls;
	$urls[0] = $req->{'addr'};
	add_new_urls_args($tmp_file, \@urls);
}
