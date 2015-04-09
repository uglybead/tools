#!/usr/bin/perl -w

package g_e_hentai;

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

my $bindir = dirname(__FILE__);
$INC[$#INC+1] = $bindir;

use hd_common qw(padTo4 getDomObj deepsleep filePutContents fileGetContents timestamp);

use Exporter qw(import);

our @EXPORT_OK = qw(fetch_from_g_e is_g_e_url);

my $ge_max_workers = 3;
my $ge_max_retries = 5;
my @ge_badfiles = ($bindir . '/g-e-bad-image-1.gif', $bindir . '/g-e-bad-image-2.gif');
my $ge_long_retries_file = $ENV{'HOME'} . '/' . '.ge-long-retries';

sub is_g_e_url {
        my $url = shift;
        if ($url =~ /^http:\/\/g\.e-hentai\.org\/g\/[0-9a-f]+\/[0-9a-f]+\/?$/) {
                return 1==1;
        }
        return 0==1;
}

sub fetch_from_g_e {

	my $baseurl = shift;

	print "Finding first page for: $baseurl\n";

	my $lasturl = "";
	my $url = getFirstPage($baseurl);

	my $imgcnt = 0;

	my $max_children = $ge_max_workers > 3 ? $ge_max_workers : 3;
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
				getImageOnPage($current_page, $ent, $title, $imgcnt, $tailid, $outdir, $ge_max_retries);
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

			getImageOnPage($current_page, $ent, $title, $imgcnt, $tailid, $outdir, $ge_max_retries);

			exit 0;
		});

	}

	print "All images enqueued, waiting on workers to finish. (" . $current_children . " outstanding workers) " . timestamp() . "\n";

	while(wait() != -1) { }

	move("." . $title, $title);
	my $slptime = 60 + rand(3 * 60);
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

	for my $bdfile (@ge_badfiles) {
		if(compare($bdfile, $lfile) == 0) {
			print "Found bandwidth exceeded image! Sleeping for quite a while\n";
			deepsleep(4 * 60 * 60);
			return 0==1;
		}
        }
	return 1==1;

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

sub saveDelayedRetry {

	my $infourl = shift;
	my $title = shift;
	my $imgcnt = shift;
	my $tailid = shift;
	my $long_retries_remaining = shift;

	my @bits = (60 * 60 * 6, $infourl, $title, $imgcnt, $tailid, $long_retries_remaining);

	my $arr = lock_retrieve($ge_long_retries_file);

	my @ar = @{ $arr };
	$ar[$#ar+1] = \@bits;

	lock_store(\@ar, $ge_long_retries_file);
	

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

1;
