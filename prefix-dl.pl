#!/usr/bin/perl -w

use strict;
use warnings;
use QtCore4;
use QtGui4;
use QtCore4::debug qw(signals); #qw(ambiguous);
use Config::Simple;
use Data::Dumper;
use URI::URL;


my $config_file = $ENV{'HOME'} . '/.prefixes';

$ENV{'TMP'} = defined($ENV{'TMP'}) ? $ENV{'TMP'} : $ENV{'HOME'} . '/.pdl-tmp';

mkdir $ENV{'TMP'};

#print $config_file;

my $config = load_config();

main_window();


sub load_config {


	my $config = new Config::Simple(syntax=>'simple');
	if( -e $config_file) { 
		$config->read($config_file); 
	} else {
		$config->{_FILE_NAME} = $config_file;
	}
	$config->autosave(1);

	if(!defined($config->param('prefixes'))) {
		my @default_prefixes = ('ana', 'lol', 'les', 'dem', 'elf');
#		my @default_prefixes = ('a', 'b', 'c', 'd', 'e', 'f', 'g');
		$config->param('prefixes', \@default_prefixes);
	}

	return $config;

}


sub main_window {
	my @args = ($0 . ' ' . $ENV{'PWD'});
	my $app = Qt::Application( \@args );
	my $bs = Qt::Frame();
	my $split = Qt::VBoxLayout($bs);

	$bs->setWindowTitle($ENV{'PWD'} . ' - prefix-dl.pl' );

	my $history = Qt::TextEdit();
	$history->setReadOnly(1);
	$split->addWidget($history);

	my $ia_frame = Qt::Frame();
	my $input_area = Qt::HBoxLayout($ia_frame);
	$split->addWidget($ia_frame);


	#my $hello = Qt::Label( 'Hello, World!' );
	#$hello->show();
	#my $button = Qt::PushButton( 'Go');
	#my $tb = Qt::LineEdit('');

	my $pref_chooser = new prefix_chooser_widget();

	$split->addWidget($pref_chooser);

	#update_prefix_list($split, 1);

	my $line = new worker_line($pref_chooser, $history);

	$split->addWidget($line);


	#$button_area

	$bs->show();

	#$pref_chooser->{'bmenu'}->menu->actions->[0]->trigger();

	#$container->show();

	exit $app->exec();

}

sub hbox {

	my $hb = Qt::Frame();
	my $box = Qt::HBoxLayout($hb);

	return $hb;

}

package worker_line {

	use QtCore4;
	use QtCore4::isa qw( Qt::LineEdit );
	use QtCore4::slots
		onreturn => [],
		txtchanged => ['QString'];
	use File::Basename;	
	use Cwd;
	use Data::Validate::URI qw(is_uri);
	use File::Fetch;
	use File::Copy;

	sub NEW {

		my $t = shift;
		my @args = @_;
		my $logging_area = pop @args;
		my $prefchooser = pop @args;
		$t->SUPER::NEW(@args);
		this->{'prefix_chooser'} = $prefchooser;
		this->{'logging_area'}   = $logging_area;
		my $cr = this->connect(this, SIGNAL('returnPressed()'), this,  SLOT('onreturn()'));
		#print "Connect: $cr\n";
		$cr = this->connect(this, SIGNAL('textChanged(QString)'), this, SLOT('txtchanged(QString)'));
		#print "Connect: $cr\n";

	}

	sub filename_part {
                my $url = shift;
                if ($url !~ /\/([^\/]+\.[^\/]+)$/) {
                        return undef;
                }
                my $trailer = $1;
                if ($trailer =~ /^(.*)\?.*$/) {
                        return $1;
                }
                return $trailer;
        }

	sub construct_target_filename {
		my $prefix = shift;
		my $url = shift;
		my $base_dir = shift;
		my $fname_part = filename_part($url);
		if (length($fname_part) > 255) {
			my @bits = split(/\./, $fname_part);
			my $right = pop @bits;
			my $left = join('.', @bits);
			$left = substr($left, 0, 255 - 2 - length($right) - length ($prefix));
			$fname_part = $left . '.' . $right;
		}
		return $base_dir . '/' . $prefix . '-' . $fname_part;
	}

	sub target_exists {
		my $prefix = shift;
		my $url = shift;
		my $base_dir = shift;
		return -e construct_target_filename($prefix, $url, $base_dir);
	}

	sub gen_referer {
		my $url = shift;
		my $url_obj = new URI::URL $url;
		return $url_obj->scheme . '://' . $url_obj->netloc;
	}

	sub onreturn {
		#print this->{'prefix_chooser'}->prefix() .  this->text() . "\n";
		if(!is_uri(this->text())) {
			this->{'logging_area'}->append("The entered text doesn't look like a URL.\n");
			return;
		}
		if(this->prefix() eq "") {
			this->{'logging_area'}->append("No prefix selected.\n");
			return;
		}

		my $cwd = getcwd();
		my $prefix = this->prefix();
		this->{'prefix_chooser'}->promote_prefix($prefix);
		my $url = this->text();
		my $target = construct_target_filename($prefix, $url, $cwd);
		if (target_exists($prefix, $url, $cwd)) {
			this->{'logging_area'}->append("-e: " . $target . "\n");
			this->clear();
			return;		
		}
		my $referer = gen_referer($url);

		my $cline = "wget -O '$target' --referer='$referer' '$url' 2>&1";
		#print $cline . "\n";
		my $wget_output = `$cline`;
		my $rcode = $?;
		if ($rcode != 0) {
			this->{'logging_area'}->append("\n\n" . $wget_output . "\n\n");
			if (target_exists($prefix, $url, $cwd)) {
				unlink $target;
			}
		}
		
		if(-e $target) {
			this->{'logging_area'}->append(this->prefix() . ': ' . $target . "\n");
			this->clear();
		}

	}

	sub txtchanged {
		my $txt = shift;
		#print "Txt: " . this->presumedOutputFilename()  .  "\n";
	}

	sub prefix {
		return this->{'prefix_chooser'}->prefix();
	}

	sub presumedOutputFilename {

		my $of = this->{'prefix_chooser'}->prefix() . '-';
		my $bn = fileparse(this->text());
		
		return $of . $bn;
	}

1;
};

package toggle_excl_button {

	use QtCore4;
	use QtCore4::isa qw( Qt::PushButton );
	use QtCore4::slots
		checkr => ['bool'];

	sub NEW {


		shift->SUPER::NEW(@_);# Qt::PushButton($txt);
		this->setCheckable(1);
		this->setAutoExclusive(1);
		this->connect(this, SIGNAL('clicked(bool)'), this, SLOT('checkr(bool)'));

	}

	sub checkr {

		my $checked = shift;

		#print this->text() . ' ' . this->isChecked() . "\n";

	}

1;
};

sub in_array {

	my $arr = shift;
	my $val = shift;

	my @array = @{ $arr };

	for(my $i = 0; $i <= $#array; ++$i) {
		if($array[$i] eq $val) {
			return 1==1;
		}
	}

	return 0==1;

}

sub move_prefix_to_front {

	my $pref = shift;

	my @prefixes = @{ $config->param('prefixes') };

	#print "Old prefixes:\n";
	#print Dumper(\@prefixes);

	my $found = (1==0);

	for(my $i = 0; $i <= $#prefixes; ++$i) {

		if($pref ne $prefixes[$i]) {
			next;
		}

		splice(@prefixes, $i, 1);
		$found = (1==1);
		last;
	}

	if(!$found) {
		return;
	}

	unshift @prefixes, $pref;
	$config->param('prefixes', \@prefixes);

	#print "New prefixes:\n";
	#print Dumper(\@prefixes);

}


package menu_item {

	use QtCore4;
	use QtCore4::isa qw( Qt::Action );
	use QtCore4::slots
		hoverin => [''],
		menu_item_clicked => [''];
	use QtCore4::debug qw(slots signals);

	sub NEW {

		my @args = @_;
		my $t = shift @args;
		if($#args < 0) {
			$args[0] = '';
		}
		if($#args < 1) {
			$args[1] = undef;
		}
		my $func = sub { };
		if($#args > 1) {
			$func = pop @args;
		}

		$t->SUPER::NEW(@args);
		my $crv;
		$crv = this->connect(this, SIGNAL('triggered()'), this, SLOT('menu_item_clicked()'));
		#print "Connect 1: " . ($crv ? 'true' : 'false') . "\n";
		$crv = this->connect(this, SIGNAL('hovered()'), this, SLOT('hoverin()'));
		#print "Connect 2: " . ($crv ? 'true' : 'false') . "\n";
		this->{'name'} = $args[0];
		this->{'update_function'} = $func;

		#print "Blocked signals: " . (this->signalsBlocked() ? 'true' : 'false') . "\n";
		#this->trigger();
		#hoverin();
		this;

	}

	sub hoverin {

		#print "Hovering " . this->{'name'} . "\n";

	}

	sub setName {

		my $name = shift;

		this->{'name'} = $name;	
	}

	sub menu_item_clicked {

		#print "Hi\n";

		my $func = this->{'update_function'};
		&$func(this);

	}
1;
}; #End Package

package menu_sublet {

	use QtCore4;
	use QtCore4::isa qw( Qt::Menu );
	use QtCore4::slots
		action_intermediary => ['QAction'];

	sub NEW {
		shift->SUPER::NEW(@_);

		this->connect(this, SIGNAL('triggered(QAction)'), this, SLOT('action_intermediary(QAction)'));
		
	}

	sub action_intermediary {

		my $action = shift;

		#print "Got action: $action\n";
		$action->trigger();

	}

}


package prefix_chooser_widget {

	use QtCore4;
	use QtCore4::isa qw( Qt::Frame );
	use Data::Dumper;

	sub NEW {

		shift->SUPER::NEW(@_);

		this->{'button_count'} = 7;
		this->{'buttons_per_row'} = 4;
		my @empty;
		this->{'buttons'} = \@empty;
		this->{'bmenu'}  = undef;
		#this->setLayout(Qt::HBoxLayout(this));
		this->setLayout(Qt::GridLayout(this));
		this->update_buttons();
		my $i = 0;
		for(; $i < this->{'button_count'}; ++$i) {
			my($row, $column) = row_column(this->{'buttons_per_row'}, $i);
			this->layout->addWidget(this->{'buttons'}->[$i], $row, $column, 1, 1);
		}
		my($row, $column) = row_column(this->{'buttons_per_row'}, $i);		
		this->layout->addWidget(this->{'bmenu'}, $row, $column, 1, 1);
	}

	sub row_column {
		my $columns = shift;
		my $val = shift;
		return int($val / $columns), $val % $columns;
	}


	sub prefix {

		my @b = @{ this->{'buttons'} };

		for(my $i = 0; $i <= $#b; ++$i) {
			if($b[$i]->isChecked()) {
				return $b[$i]->text();
			}
		}

		return "";

	}

	sub setCheckedButton {

		my $but = shift;
		my @b = @{ this->{'buttons'} };
		for(my $i = 0; $i <= $#b; ++$i) {

			$b[$i]->setChecked($i == $but);

		}

	}

	sub promote_prefix {
		my $prefix = shift;
		main::move_prefix_to_front($prefix);
                this->setCheckedButton(0);
                this->update_buttons();
	}

	sub update_buttons {

		my @prefixes = $config->param('prefixes');

		for(my $i = 0; $i < this->{'button_count'}; ++$i) {
	
			if(!defined(this->{'buttons'}->[$i])) {
				this->{'buttons'}->[$i] = new toggle_excl_button($prefixes[$i]);
			} else {
				this->{'buttons'}->[$i]->setText($prefixes[$i]);
			}
		
		}


		if(!defined(this->{'bmenu'})) {

			this->{'bmenu'} = Qt::PushButton("Others");
		}

		my $menu = new menu_sublet();

		my $selfless = this;

		for(my $i = this->{'button_count'}; $i <= $#prefixes; ++$i) {
                	$menu->addAction(new menu_item($prefixes[$i], $menu, sub {

                        	my $self = shift;
	                        my $nm = $self->{'name'};
        	                #print "Moving to front: " . $nm  . "\n";
                	        $selfless->promote_prefix($nm);
        	        }));
	        }

		$menu->addAction(new menu_item("New prefix", $menu, sub {

        	        my $ntxt = Qt::InputDialog::getText($menu, "New Prefix", "");
                	if(!defined($ntxt) || $ntxt eq "") {
	                        return;
        	        }

	                my @prefs = @{ $config->param('prefixes') };
        	        if(main::in_array(\@prefs, $ntxt)) {
                	        return;
	                }
        	        unshift @prefs, $ntxt;
                	$config->param('prefixes', \@prefs);
			$selfless->update_buttons();

        	}));
		this->{'bmenu'}->setMenu($menu);

		my $actions = this->{'bmenu'}->menu->actions();

        	#print Dumper($actions);
		foreach my $act (@{$actions}) {
			#print Dumper($act->isEnabled()) . "\n";
		}
		#$actions->[0]->trigger();
		#$actions->[0]->trigger();
		#$actions->[0]->trigger();
		#print Dumper(this->{'bmenu'}->menu());
		#print "blah\n";

	}

1;
};

