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

my $default_workers = 3;
my $max_workers = $default_workers;
my $dl_dir   = $ENV{'HOME'} . '/' . '/ge-downloads/';
# Limit the usable fetchers.
$File::Fetch::BLACKLIST = [qw| wget curl lftp fetch lynx iosock|];

sub main {
	set_working_directory();
	if ($ARGV[0] =~ /^\d+$/) {
		fetch_manga($ARGV[0]);
	}
}


sub fetch_manga {

	my $manga_id = shift;
	my $title = fetch_title($manga_id);
	if (!defined($title)) {
		print "Couldn't find a title for id $manga_id. Skipping\n";
		return;
	}

	print "Downloading [$manga_id] : $title\n";
	mkdir($title);
	my $outdir = $title . "/";
	write_original_url($manga_id, $title);
	my %page_map = build_page_map($manga_id);
	download_all_pages(\%page_map, $title, $outdir);
}

sub set_working_directory {
	if (! -e $dl_dir) {
		mkdir($dl_dir);
	}
	if (! -d $dl_dir) {
		die("Download directory [$dl_dir] is not a directory!");
	}
	if (! -w $dl_dir) {
		die("Downlaod directory [$dl_dir] is not writable!");
	}
	chdir($dl_dir) or die("Unable to set working directory to [$dl_dir]");
}

sub write_original_url {
	my $manga_id = shift;
	my $title = shift;
	my $base_url = category_url($manga_id);
	open FILE, ">", $title . '/original_url.txt';
	print FILE $base_url . "\n";
	close FILE;
}

sub download_all_pages {
	my %page_map = %{ shift() };
	my $title = shift;
	my $outdir = shift;
	my $active_workers = 0;
	for my $key (sort keys(%page_map)) {
		my $outfile = $outdir . $title . ' - ' . sprintf("%04d", $key) . '.' . guess_extension($page_map{$key});
		$active_workers = wait_for_available_worker($active_workers, $max_workers);
		download_in_subprocess($page_map{$key}, $outfile);
		random_deep_sleep(20, 60);
	}
	wait_on_all_workers($active_workers);
}

sub download_in_subprocess {
	my $src = shift;
	my $dest = shift;
	my $pid = fork();
	if ($pid == 0) {
		download_file_with_retry_to($src, $dest, 5);
	}
}

sub wait_for_available_worker {
	my $actives = shift;
	my $limit = shift;
	$actives -= reap_finished_workers();
	if ($actives < $limit) {
		return $actives + 1;
	}
	wait();
	return $actives;
}

sub wait_on_all_workers {
	my $actives = shift;
	while($actives > 0) {
		wait();
		$actives--;
	}
	return;
}

sub reap_finished_workers {
	my $reaped = 0;
	use POSIX ":sys_wait_h";
	while(waitpid(-1, WNOHANG) > 0) {
                $reaped++;
        }
	return $reaped;
}

sub download_file_with_retry_to {
	my $url = shift;
	my $destination = shift;
	my $retries = shift;
	
	my $ff = undef;
        $ff = File::Fetch->new(uri => $url);
        $File::Fetch::WARN = (0 == 1);
        if(!$ff->fetch() || !check_file($ff->output_file)) {
	        print "Failed during fetch of image $url.\n";
                print "  Retries remaining: $retries \n";
		random_deep_sleep(30, 60);
		return download_file_with_retry_to($url, $destination, $retries - 1);
	}
        move($ff->output_file, $destination);
	print "Downloaded $url => $destination\n";
	exit();
}

sub check_file {
	return 1==1;
}

sub guess_extension {
	my $url = shift;
	if ($url =~ /\.([^.]+)$/) {
		return $1;
	}
	return 'jpg'; # Just give it something that will open in an image viewer
}

sub build_page_map {
	my $manga_id = shift();
	my %retval;

	my $last_url = "not defined";

	for (my $i = 1; ; $i++) {
		my $dom = getDomObj(construct_page_url($manga_id, $i));
		my $url = find_image_url_in_dom($dom);
		random_deep_sleep(2, 7);
		if ($url eq $last_url) {
			last;
		}
		print "Page\t$i\t$url\n";
		$retval{$i} = $url;
		$last_url = $url;
	}
	return %retval;
}

sub construct_page_url {
	my $manga_id = shift();
	my $page_number = shift();
	return 'http://thedoujin.com/index.php/pages/' . $manga_id . '?Pages_page=' . $page_number;
}

sub find_image_url_in_dom {
	my $dom = shift;
	my $ret = undef;
	$dom->find("#image")->each(sub {
		my $ent = shift;
		$ret = $ent->attr('src');
	});
	return $ret;
}

sub fetch_title {
	my $manga_id = shift();
	my $category_page = category_url($manga_id);
	my $dom = getDomObj($category_page);
	return find_title_in_dom($dom);
}

sub find_title_in_dom {
	my $dom = shift();
	my $ret = undef;
	$dom->find("#Categories_title")->each(sub {
                my $ent = shift;
                $ret = $ent->attr('value');

        });
	return $ret;
}

sub category_url {
	my $manga_id = shift;
	return "http://thedoujin.com/index.php/categories/" . $manga_id;
}

sub getDomObj {
        my $url = shift;
        my $dt = `curl --max-redirs 8 '$url' 2>/dev/null`;
        my $dom = Mojo::DOM->new($dt);

        return $dom;
}

sub random_deep_sleep {
	my $minimum = shift();
	my $maximum = shift();
	deepsleep($minimum + rand($maximum - $minimum));
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

main();
