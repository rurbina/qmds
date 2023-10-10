package tt;

use common::sense;
use base qw( Template::Plugin );
use Template::Plugin;

use Data::Dumper qw(Dumper);
$Data::Dumper::SortKeys = 1;

sub new {

	my ( $class, $context ) = @_;

	bless { tt => 1, }, $class;

}

sub load { return shift }

sub get_hash {

	my ( $class, $app ) = @_;

	my %hash = (
		_app     => $app,
		db_query => \&db_query,
		dump     => \&dump,
		test     => \&test,
	);

	return %hash;

}

sub test {

	return [ 'one', 'two', 'three' ];

}

sub increase_headers {

	my ( $s, $txt ) = @_;

	$txt =~ s/^#####(?!#)(?=\w)/######/mg;
	$txt =~ s/^####(?!#)(?=\w)/#####/mg;
	$txt =~ s/^###(?!#)(?=\w)/####/mg;
	$txt =~ s/^##(?!#)(?=\w)/###/mg;
	$txt =~ s/^#(?!#)(?=\w)/##/mg;

	return $txt;

}

sub db_query {

	my ( $s, %pp ) = @_;

	return $s;

}

sub dump {

	my $s = shift;

	return Dumper( \@_ );

}

1;
