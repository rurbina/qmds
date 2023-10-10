package db;

use DBD::SQLite;
use DBI;
use JSON::XS;
use Data::Dumper qw(Dumper);
$Data::Dumper::SortKeys = 1;

sub new {

	my ( $class, $app ) = @_;

	my $s = {
		app     => $app,
		db_file => $app->{config}->{db_file},
		dbh     => undef,
		json    => JSON::XS->new(),
	};

	$s->{dbh} = DBI->connect( "dbi:SQLite:dbname=$s->{db_file}", "", "" ) || die 'no db';

	bless $s;

}

sub touch {

	my ( $s, $uri, $filename, $headers ) = @_;

	my $sql = qq{
	insert into "index" (uri, path, mtime, title, last_check, tags, headers) values ( ?, ?, ?, ?, ?, ?, ?)
	on conflict do update set
 		path = excluded.path, mtime = excluded.mtime, title = excluded.title,
		last_check = excluded.last_check, tags = excluded.tags, headers = excluded.headers
	};

	$s->{dbh}->do( $sql, undef, $uri, $filename, $mtime, $headers->{title}, undef, $s->{json}->encode( $headers->{tags} // [] ), $s->{json}->encode( $headers // {} ) );

}

sub query {

	my ( $s, %pp ) = @_;

	my $sql = qq{select * from "index" limit 20};

	my @data = $s->{dbh}->selectall_array($sql);

	return @data ? \@data : undef;

}

1;
