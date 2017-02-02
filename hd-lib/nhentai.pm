#!/usr/bin/perl -w

package nhentai;

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

our @EXPORT_OK = qw(fetch_from_nhentai is_nhentai_url);

# Limit the usable fetchers.
$File::Fetch::BLACKLIST = [qw| wget curl lftp fetch lynx iosock|];

sub is_nhentai_url {
	my $url = shift;
	return defined(get_manga_number($url));
}

sub get_manga_number {
	my $url = shift;
	if ($url =~ /^https?:\/\/(?:www.)?nhentai.net\/g\/(\d+)\/?/) {
		return $1;
	}
	return undef;
}

sub fetch_from_nhentai {
	my $url = shift;
	my $pool_number = get_manga_number($url);
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
	print "Finished downloading : $title\n";
}

sub write_original_url {
	my $pool_id = shift;
	my $title = shift;
	my $base_url = manga_url($pool_id);
	open FILE, ">", $title . '/original_url.txt';
	print FILE $base_url . "\n";
	close FILE;
}

sub check_file {
	return 1==1;
}

sub find_actual_image_url {
	my $page_url = shift;
	my $retries = shift;
	if (!defined($retries)) {
		$retries = 5;
	}
	my $dom = getDomObj($page_url);
	my $ret = undef;
	$dom->find("#image-container img")->each(sub {
		my $ent = shift();
		if ($ent->attr('src') !~ /galleries/) {
			return;
		}
		my $url = $ent->attr('src');
		if ($url !~ /^https?:\/\//) {
			$url =~ s/^\/*//;
			$url = 'https://' . $url;
		}
		$ret = $url;
	});
	random_deep_sleep(1, 3);
	if (!defined($ret) && $retries > 0) {
		return find_actual_image_url($page_url, $retries - 1);
	}
	return $ret;
}

sub build_page_map {
	my $pool_id = shift();
	my %retval;

	my $last_url = "not defined";

	my $image_number = 1;
	my $dom = getDomObj(manga_url($pool_id));
	$dom->find(".gallerythumb")->each(sub {
		my $ent = shift;
		if ($ent->attr('href') !~ /g\/\d+\/(\d+)/) {
			print "    Thumbnail didn't have valid href? [" . $ent->attr('href') . "]\n";
			return;
		}
		my $number = $1;
		my $url = $ent->attr('href');
		if ($url !~ /^https?:\/\//) {
			$url =~ s/^\/*//;
			$url = 'https://nhentai.net/' . $url;
		}
		my $image_url = find_actual_image_url($url);
		if (!defined($image_url)) {
			print "    Couldn't find image for page [$number]\n";
			return;
		}
		$retval{$number} = $image_url;
		print "    Added page [$number]\t\t" . $image_url . "\n";
	});
	print "  All pages added\n";
	random_deep_sleep(2, 7);

	return %retval;
}

sub fetch_title {
	my $pool_id = shift();
	my $category_page = manga_url($pool_id);
	my $dom = getDomObj($category_page);
	return find_title_in_dom($dom);
}

sub find_title_in_dom {
	my $dom = shift();
	my $ret = undef;
	$dom->find("#info > h1")->each(sub {
                my $ent = shift;
                $ret = $ent->text;
        });
	# Slashes become spaces.
	$ret =~ s/\// /g;
	return $ret;
}

sub manga_url {
	my $pool_id = shift;
	return "https://nhentai.net/g/" . $pool_id . '/';
}

1;
