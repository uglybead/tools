#!/usr/bin/perl -w

package the_doujin;

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
 
use hd_common qw(padTo4 getDomObj deepsleep filePutContents fileGetContents download_all_pages random_deep_sleep);

use Exporter qw(import);

our @EXPORT_OK = qw(fetch_from_the_doujin is_the_doujin_url);

my $default_workers = 3;
my $max_workers = $default_workers;
# Limit the usable fetchers.
$File::Fetch::BLACKLIST = [qw| wget curl lftp fetch lynx iosock|];

sub is_the_doujin_url {
	my $url = shift;
	return match_the_doujin($url);
}

sub match_the_doujin {
	my $url = shift;
	if ($url =~ /^http:\/\/thedoujin.com\/index.php\/categories\/\d+$/) {
		return 1==1;
	}
	return 1==0;
}

sub fetch_from_the_doujin {
	my $url = shift;
	if ($url !~ /^http:\/\/thedoujin.com\/index.php\/categories\/(\d+)$/) {
		print "Invalid the doujin url.\n";
		return;
	}
	fetch_manga($1);
}


sub fetch_manga {

	my $manga_id = shift;
	my $title = fetch_title($manga_id);
	if (!defined($title)) {
		print "Couldn't find a title for id $manga_id. Skipping\n";
		return;
	}
	if ($title =~ /^\s*$/) {
		print "Title was empty, using id instead.\n";
		$title = $manga_id;
	}

	print "Downloading [$manga_id] : $title\n";
	mkdir($title);
	my $outdir = $title . "/";
	write_original_url($manga_id, $title);
	my %page_map = build_page_map($manga_id);
	download_all_pages(\%page_map, $title, $outdir, \&check_file);
	print "Finished downloading: $title\n";
}

sub write_original_url {
	my $manga_id = shift;
	my $title = shift;
	my $base_url = category_url($manga_id);
	open FILE, ">", $title . '/original_url.txt';
	print FILE $base_url . "\n";
	close FILE;
}

sub check_file {
	return 1==1;
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

1;
