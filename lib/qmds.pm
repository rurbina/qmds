package qmds;

use common::sense;
use File::Slurper 'read_text';
use File::MimeInfo::Magic;
use List::Util qw(any);
use Encode;
use render;

use Data::Dumper 'Dumper';
$Data::Dumper::Sortkeys = 1;

sub new {

	my ( $class, $app ) = @_;

	my $qmds = {
		app    => $app,
		config => $app->{config},
	};

	bless $qmds;

}

sub dispatch {

	my ( $s, $uri ) = @_;

	$uri = "/$s->{config}->{default}" if $uri eq '/';

	if ( $uri eq '/!rescan' ) {
		return ( 200, $s->rescan() );
	}

	if ( my $mdfile = $s->get_file_from_uri($uri) ) {
		push @{ $s->{app}->{headers} }, ( 'Content-Type' => 'text/html; charset=UTF-8' );
		my $tt_out = render->new($s)->markdown( uri => $uri, filename => $mdfile );
		return ( 200, Encode::encode_utf8($tt_out) );
	}

	if ( my $static = $s->get_static_file_from_uri($uri) ) {
		return ( 200, $static );
	}

	return ( 404, undef );

}

sub get_file_from_uri {

	my ( $s, $uri ) = @_;

	my @paths    = &arrayitize( $s->{config}->{md_root} );
	my @suffixes = &arrayitize( $s->{config}->{md_suffix} );

	foreach my $path (@paths) {
		foreach my $suffix (@suffixes) {
			my $filename = $path . $uri . $suffix;
			if ( -e $filename ) {
				return $filename;
			}
		}
	}

	return;

}

sub get_static_file_from_uri {

	my ( $s, $uri ) = @_;

	my @paths = &arrayitize( $s->{config}->{static_root} );

	foreach my $path (@paths) {
		my $filename = $path . $uri;
		if ( -e $filename ) {
			open( my $fh, "<", $filename ) || die "cant open $filename";
			push @{ $s->{app}->{headers} }, ( 'Content-Type' => mimetype($filename) );
			return $fh;
		}
	}

	return;

}

sub rescan {

	my ( $s, %args ) = @_;

	my @paths    = &arrayitize( $s->{config}->{md_root} );
	my @suffixes = &arrayitize( $s->{config}->{md_suffix} );

	my @dirs = $args{dirs} ? @{ $args{dirs} } : ".";

	my $render = render->new($s);

	# scan for files and recursive paths
	foreach my $base (@paths) {
		foreach my $dir (@dirs) {

			opendir DIR, "$base/$dir";
			my @dir = readdir(DIR);
			close DIR;

			foreach my $item (@dir) {

				next if $item =~ m/^\./;
				my $path     = "$base/$dir/$item";
				my $uri      = "/$dir/$item";
				my ($suffix) = grep { $item =~ m/$_$/ ? $_ : undef } @suffixes;
				$uri =~ s!/./!/!;
				$uri =~ s/$suffix$//g if $suffix;

				if ( -f $path && $suffix ) {
					print "\e[32m$path\e[m\n";
					$render->markdown( filename => $path, uri => $uri, touch_only => 1 );
				}
				elsif ( -d $path ) {
					print "\e[34m$path\e[m\n";
					$s->rescan( dirs => ["$dir/$item"] );
				}

			}
		}
	}

	if ( !$args{dirs} ) {
		my @check_docs = $s->{app}->{db}->query();

		foreach my $doc (@check_docs) {

			if ( any( sub { -f decode( 'utf8', $doc->{path} ) }, @paths ) ) {
			}
			else {
				$s->{app}->{db}->delete_uri( $doc->{uri} );
				print STDERR "\e[31m$doc->{path} deleted\e[m\n";
			}
		}

	}

	return "rescan ok\n";

}

sub arrayitize {

	my ($scalar) = @_;

	return ref($scalar) eq 'ARRAY' ? @{$scalar} : ($scalar);

}

1;
