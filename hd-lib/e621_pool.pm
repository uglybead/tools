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
 
use hd_common qw(padTo4 getDomObj deepsleep filePutContents fileGetContents random_deep_sleep download_all_pages);

use Exporter qw(import);

our @EXPORT_OK = qw(fetch_from_e621 is_e621_pool_url);

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
	download_all_pages(\%page_map, $title, $outdir, \&check_file);
	print "Finished downloading: $title\n";
}

sub write_original_url {
	my $pool_id = shift;
	my $title = shift;
	my $base_url = pool_url($pool_id);
	open FILE, ">", $title . '/original_url.txt';
	print FILE $base_url . "\n";
	close FILE;
}

sub check_file {
	return 1==1;
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

1;
