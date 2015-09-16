#!/usr/bin/perl -w

package pururin2;

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
use File::Temp qw/ tempfile /;
use DateTime;
use File::Spec;
use lib dirname(File::Spec->rel2abs(__FILE__));
use DateTime::Format::Strptime;
use WWW::Mechanize::Firefox;
use Firefox::Application;
 
use hd_common qw(padTo4 getDomObj deepsleep filePutContents fileGetContents random_deep_sleep download_all_pages);

use Exporter qw(import);

our @EXPORT_OK = qw(fetch_from_pururin is_pururin_url);

# Limit the usable fetchers.
$File::Fetch::BLACKLIST = [qw| wget curl lftp fetch lynx iosock|];

sub is_pururin_url {
	my $url = shift;
	return $url =~ /^http:\/\/pururin.com\/gallery\/\d+\/[A-Za-z0-9+-]+\.html$/;
}

sub fetch_from_pururin {
	my $url = shift;
	my $mech = setup_mechanize($url);
	download_manga($url, $mech);
	random_deep_sleep(60, 90);
}

sub setup_mechanize {
	my $url = shift;
	my $mech = WWW::Mechanize::Firefox->new(create => 1);
	$mech->autodie(0);
	$mech->allow( javascript => 1, plugins => 0 );
	$mech->get($url);
	random_deep_sleep(2, 10);
	$mech->reload(1);
	return $mech;
}

sub download_manga {

	my $url = shift;
	my $mech = shift;
	my %metadata = fetch_metadata($url, $mech, 5);
	my $title = $metadata{'title'};
	if (!defined($title)) {
		print "Couldn't find a title for [$url]. Skipping\n";
		return;
	}
	$title =~ s/\//-/;  # remove backslashes

	print "Downloading [$url]: $title\n";
	mkdir($title);
	my $outdir = $title . "/";
	write_original_url($url, $title);
	write_tag_data($title, $metadata{'tags'});
	my %page_map = build_page_map($url, $mech, 6);
	download_all_pages(\%page_map, $title, $outdir, \&check_file, undef, $mech);
	print "Finished downloading: $title\n";
}

sub write_original_url {
	my $url = shift;
	my $title = shift;
	open FILE, ">", $title . '/original_url.txt';
	print FILE $url . "\n";
	close FILE;
}

sub write_tag_data {
	my $title = shift;
	my $tags = shift;
        open FILE, ">", $title . '/tags.txt';
        print FILE $tags . "\n";
        close FILE;

}

sub check_file {
	return 1==1;
}

sub base_url_to_thumb_url {
	my $url = shift;
	my $orig = $url;
	$url =~ s/\/gallery\//\/thumbs\//;
	if ($url eq $orig) {
		return undef;
	}
	return $url;
}

sub find_actual_image_url {
	my $url = shift;
	my $mech = shift;
	my $retries = shift;
	my $dom = getDomObj($url, $mech);
	my $ret = undef;
	$dom->find(".image > a > img")->each(sub {
		my $ent = shift;
		if ($ent->attr('src') !~ /^\/f\//) {
			return;
		}
		my $url = $ent->attr('src');
		$url =~ s/^\/*//;
                $url = 'http://pururin.com/' . $url;
		$ret = $url;
	});
	random_deep_sleep(1,2);
	if (!defined($ret) && $retries > 0) {
		print "    Coudln't find image, retrying\n";
		return find_actual_image_url($url, $mech, $retries - 1);
	}
	return $ret;
}

sub build_page_map {
	my $base_url = shift;
	my $mech = shift;
	my $retries = shift;
	my $thumb_url = base_url_to_thumb_url($base_url);
	my %retval;
	if (!defined($thumb_url)) {
		print "Couldn't convert base url to thumb url\n";
		return %retval;
	}

	my $image_number = 1;
	my $dom = getDomObj($thumb_url, $mech);
	#print Dumper($dom);
	$dom->find(".thumblist > li > a")->each(sub {
		my $ent = shift;
		if ($ent->attr('href') !~ /^\/view\/\d+\/\d+\//) {
			print "    Thumbnail didn't have valid href? [" . $ent->attr('href') . "]\n";
			return;
		}
		my $url = $ent->attr('href');
		if ($url !~ /^https?:\/\//) {
			$url =~ s/^\/*//;
			$url = 'http://pururin.com/' . $url;
		}
		my $image_url = find_actual_image_url($url, $mech, 5);
		if (!defined($image_url)) {
			print "    Couldn't find image for page [$image_number]\n";
			return;
		}
		$retval{$image_number} = $image_url;
		print "    Added page [$image_number]\t\t" . $image_url . "\n";
		$image_number++;
	});
	if (scalar(keys %retval) == 0 && $retries > 0) {
		print "    Couldn't find any images, retrying.\n";
		return build_page_map($base_url, $mech, $retries - 1);
	}
	print "  All pages added\n";
	random_deep_sleep(2, 7);

	return %retval;
}

sub get_single_text_by_selector {
	my $dom = shift;
	my $matcher = shift;
	my $ret = undef;
	$dom->find($matcher)->each(sub {
		my $ent = shift;
		$ret = $ent->text;
	});
	return $ret;
}

sub get_multi_text_by_selector {
	my $dom = shift;
        my $matcher = shift;
        my @ret;
	$dom->find($matcher)->each(sub {
                my $ent = shift;
                $ret[scalar(@ret)] = $ent->text;
        });
        return @ret;
}

sub fetch_metadata {
	my $url = shift;
	my $mech = shift;
	my $retries = shift;
	my $dom = getDomObj($url, $mech);
	my %md;
	$md{'title'} = get_single_text_by_selector($dom, ".otitle");
	$md{'tags'} = join("\n", get_multi_text_by_selector($dom, ".tag-list > li > a"));
	if (!defined($md{'title'}) && $retries > 0) {
		print "Couldn't get dom:\n\n\n" . Dumper(\$dom) . "\n\n\n";
		return fetch_metadata($url, $mech, $retries - 1);
	}
	return %md;
}

1;
