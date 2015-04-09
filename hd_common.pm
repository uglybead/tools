#!/usr/bin/perl -w

package hd_common;

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

use Exporter qw(import);

our @EXPORT_OK = qw(padTo4 getDomObj deepsleep filePutContents fileGetContents);

sub padTo4 {

	my $val = shift;

	while(length($val) < 4) {
		$val = '0' . $val;
	}
	return $val;

}

sub getDomObj {

        my $url = shift;

        my $dt = `curl --max-redirs 8 '$url' 2>/dev/null`;

        my $dom = Mojo::DOM->new($dt);

        return $dom;

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

1;
