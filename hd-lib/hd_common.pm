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
use File::Spec;
use lib dirname(File::Spec->rel2abs(__FILE__));

my $bindir = dirname(File::Spec->rel2abs(__FILE__));;

use Exporter qw(import);

our @EXPORT_OK = qw(timestamp padTo4 getDomObj deepsleep filePutContents fileGetContents download_all_pages random_deep_sleep get_single_text_by_selector get_multi_text_by_selector pathOrUndef);

my $default_workers = 3;

sub pathOrUndef {
	my $path = shift;
	if (-e $path && -r $path) {
		return $path;
	}
	return undef;
}

sub timestamp {
        my $dt = DateTime->now();
        return $dt->ymd . ' ' . $dt->hms;
}

sub padTo4 {

	my $val = shift;

	while(length($val) < 4) {
		$val = '0' . $val;
	}
	return $val;

}

# As getDomObj, but uses a WWW::Mechanize::Firefox to do it.
sub getDomObjWithMech {
	my $url = shift;
	my $mech = shift;
	$mech->get($url);
	my $cont = $mech->content( format => 'html');
	my $dom = Mojo::DOM->new($cont);
	return $dom;
}

sub getDomObj {

        my $url = shift;
	my $mech = shift;
	if (defined($mech)) {
		return getDomObjWithMech($url, $mech);
	}
	my $dt = '';
        for (my $i = 0; $i < 5; ++$i) {
		my $execstr = "curl --max-redirs 8 '$url' 2>/dev/null";
		print "Running: [$execstr] \n";
		$dt = `$execstr`;
		if ($dt !~ /^\s+$/) {
			last;
		}
		random_deep_sleep(1, 3);
	}

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
	open(FILBY, '<', $filename) or return "";
	my $ret = '';
	while(<FILBY>) {
		$ret .= $_;
	}
	close(FILBY);
	return $ret;
}

sub outfile_name {
	my $outdir = shift;
	my $title = shift;
	my $key = shift;
	my $url = shift;
	return $outdir . $title . ' - ' . sprintf("%04d", $key) . '.' . guess_extension($url);
}

sub minimal_check {
	my $filename = shift;
	return (0==1) if (! -e $filename);
	return (0==1) if (-z $filename);
	return 1==1;
}

sub fetch_page_via_mech {
	my $mech = shift;
	my $url = shift;
	my $outfile = shift;
	my $check_function = shift;
	my $retries = shift;
	print "Downloading $url\t\tto\t\t $outfile\n";
	$mech->get($url);
	$mech->save_url($url, $outfile);
	if ((!minimal_check($outfile) || !&$check_function($outfile)) && $retries > 0) {
		random_deep_sleep(2, 5);
		return fetch_page_via_mech($mech, $url, $outfile, $check_function, $retries - 1);
	}
	
}

sub download_all_pages_with_mech {
	my %page_map = %{ shift() };
	my $title = shift;
	my $outdir = shift;
	my $check_function = shift;
	my $mech = shift;
	for my $key (nkeys(%page_map)) {
		my $outfile = outfile_name($outdir, $title, $key, $page_map{$key});
		fetch_page_via_mech($mech, $page_map{$key}, $outfile, $check_function, 5);
		random_deep_sleep(20, 60);
	}
}

sub nkeys {
	my %map = @_;
	return sort( map {int($_);} keys(%map));
}

sub download_all_pages_standard {
	my %page_map = %{ shift() };
	my $title = shift;
	my $outdir = shift;
	my $check_function = shift;
	my $workers = shift;

	my $double_check = sub {
		my $file = shift;
		return &$check_function($file) && minimal_check($file);
	};

	$workers = defined($workers) ? $workers : $default_workers;
	my $active_workers = 0;
	for my $key (nkeys(%page_map)) {
                my $outfile = outfile_name($outdir, $title, $key, $page_map{$key});
                $active_workers = wait_for_available_worker($active_workers, $workers);
                download_in_subprocess($page_map{$key}, $outfile, $double_check);
                random_deep_sleep(20, 60);
        }
        wait_on_all_workers($active_workers);	
}

sub download_all_pages {
        my %page_map = %{ shift() };
        my $title = shift;
        my $outdir = shift;
	my $check_function = shift;
	my $workers = shift;
	my $mech = shift;
	if (defined($mech)) {
		return download_all_pages_with_mech(\%page_map, $title, $outdir, $check_function, $mech);
	} else {
		return download_all_pages_standard(\%page_map, $title, $outdir, $check_function, $mech);
	}
}

sub download_in_subprocess {
        my $src = shift;
        my $dest = shift;
        my $check_function = shift;
        my $pid = fork();
        if ($pid == 0) {
                download_file_with_retry_to($src, $dest, 5, $check_function);
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
        my $check_function = shift;
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
        if(!$ff->fetch() || ! (&$check_function($ff->output_file))) {
                print "Failed during fetch of image $url\n\n";
                print "  Retries remaining: $retries \n";
                random_deep_sleep(30, 60);
                return download_file_with_retry_to($url, $destination, $retries - 1, $check_function);
        }
        move($ff->output_file, $destination);
        print "Downloaded $url => $destination\n";
        exit();
}

sub guess_extension {
        my $url = shift;
        if ($url =~ /\.([^.]+)$/) {
                return $1;
        }
        return 'jpg'; # Just give it something that will open in an image viewer
}

sub random_deep_sleep {
        my $minimum = shift();
        my $maximum = shift();
        deepsleep($minimum + rand($maximum - $minimum));
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

1;
