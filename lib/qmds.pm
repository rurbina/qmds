package qmds;

use common::sense;
use File::Slurper 'read_text';
use File::MimeInfo::Magic;
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

	if ( my $mdfile = $s->get_file_from_uri($uri) ) {
		push @{ $s->{app}->{headers} }, ( 'Content-Type' => 'text/html' );
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

sub arrayitize {

	my ($scalar) = @_;

	return ref($scalar) eq 'ARRAY' ? @{$scalar} : ($scalar);

}

1;
