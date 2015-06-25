#!/usr/bin/perl -w

package e621_pool;

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
use File::Spec;
use lib dirname(File::Spec->rel2abs(__FILE__));
 
use hd_common qw(padTo4 getDomObj deepsleep filePutContents fileGetContents);

use Exporter qw(import);

our @EXPORT_OK = qw(fetch_from_e621 is_e621_pool_url);

my $default_workers = 3;
my $max_workers = $default_workers;
# Limit the usable fetchers.
$File::Fetch::BLACKLIST = [qw| wget curl lftp fetch lynx iosock|];

sub is_e621_pool_url {
	my $url = shift;
	return defined(get_pool_number($url));
}

sub get_pool_number {
	my $url = shift;
	if ($url =~ /^https:\/\/e621.net\/pool\/show\/(\d+)$/) {
		return $1;
	}
	return undef;
}

sub fetch_from_e621 {
	my $url = shift;
	my $pool_number = get_pool_number($url);
	fetch_pool($pool_number);
	random_deep_sleep(60, 90);
}

sub fetch_pool {

	my $pool_id = shift;
	my $title = fetch_title($pool_id);
	if (!defined($title)) {
		print "Couldn't find a title for id $pool_id. Skipping\n";
		return;
	}
	if ($title =~ /^Pool:\s*/) {
		$title =~ s/^Pool:\s*//;
	}
	if ($title =~ /^\s*$/) {
		print "Title was empty, using id instead.\n";
		$title = $pool_id;
	}

	print "Downloading [$pool_id] : $title\n";
	mkdir($title);
	my $outdir = $title . "/";
	write_original_url($pool_id, $title);
	my %page_map = build_page_map($pool_id);
	download_all_pages(\%page_map, $title, $outdir);
}

sub write_original_url {
	my $pool_id = shift;
	my $title = shift;
	my $base_url = pool_url($pool_id);
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
	if ($retries < 0) {
		print "Unable to download [$url] => [$destination]\n";
		exit();
	}

	# So, file::fetch doesn't work with https, yet (though a fix has been recently merged). We'll just degrade for now and maybe someday someone will fix it.
	$url =~ s/^https:\/\//http:\/\//;
	
	my $ff = undef;
        $ff = File::Fetch->new(uri => $url);
	$File::Fetch::USER_AGENT = "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36";
        #$File::Fetch::WARN = (0 == 1);
        if(!$ff->fetch() || !check_file($ff->output_file)) {
	        print "Failed during fetch of image $url\n\n";
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

sub find_actual_url_on_image_page {
	my $image_page = shift();
	my $dom = getDomObj($image_page);
	my $ret = undef();
	$dom->find("div.content img")->each(sub {
		my $ent = shift;
		if ($ent->attr('alt') !~ /e621/) {
			return;
		}
		if ($ent->attr('class') =~ /avatar/) {
                        return; # Comment images.
                }
		$ret = $ent->attr('src');
	});
	return $ret;
}

sub add_images_in_page {
	my $image_hash_ref = shift();
	my $dom = shift();
	my $image_number = shift();
	$dom->find("span.thumb > a")->each(sub {
		my $ent = shift;
		random_deep_sleep(2, 5);
		my $href = $ent->attr('href');
		if ($href !~ /^\/post\//) {
			print "Doesn't look like a page url? : " . $href . "\n";
			return;
		}
		$href = "https://e621.net" . $href;
		my $actual_href = find_actual_url_on_image_page($href);
		if (!defined($actual_href)) {
			print "Couldn't find an image on nominal page " . $image_number . " ( " . $href . " )\n";
			return;
		}
		$image_hash_ref->{$image_number} = $actual_href;
		print $image_number . "\t\t" . $href . "\t\t" . $actual_href . "\n";
		$image_number++;
	});
	return $image_number;
}

sub is_last_page {
	my $dom = shift;
	my $ret = (1==1);
	$dom->find("div.pagination > a")->each(sub {
		my $ent = shift;
		if ($ent->attr('rel') eq 'next') {
			$ret = (1==0);
		}
	});
	return $ret;
}

sub build_page_map {
	my $pool_id = shift();
	my %retval;

	my $last_url = "not defined";

	my $image_number = 1;
	for (my $i = 1; ; $i++) {
		my $dom = getDomObj(construct_page_url($pool_id, $i));
		$image_number = add_images_in_page(\%retval, $dom, $image_number);
		random_deep_sleep(2, 7);
		if (is_last_page($dom)) {
			last;
		}
	}
	return %retval;
}

sub construct_page_url {
	my $pool_id = shift();
	my $page_number = shift();
	return 'https://e621.net/pool/show/' . $pool_id . '?page=' . $page_number;
}

sub fetch_title {
	my $pool_id = shift();
	my $category_page = pool_url($pool_id);
	my $dom = getDomObj($category_page);
	return find_title_in_dom($dom);
}

sub find_title_in_dom {
	my $dom = shift();
	my $ret = undef;
	$dom->find("h4")->each(sub {
                my $ent = shift;
                $ret = $ent->text;
        });
	return $ret;
}

sub pool_url {
	my $pool_id = shift;
	return "https://e621.net/pool/show/" . $pool_id;
}

sub random_deep_sleep {
	my $minimum = shift();
	my $maximum = shift();
	deepsleep($minimum + rand($maximum - $minimum));
}

1;
