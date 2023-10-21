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
		json    => JSON::XS->new()->canonical(),
	};

	$s->{dbh} = DBI->connect( "dbi:SQLite:dbname=$s->{db_file}", "", "" ) || die 'no db';

	bless $s;

}

sub touch {

	my ( $s, %arg ) = @_;

	my $sql = qq{
	insert into meta_index (uri, path, mtime, title, last_check, tags, headers)
		values ( ?, ?, ?, ?, datetime('now'), ?, ?)
	on conflict do update set
 		path = excluded.path, mtime = excluded.mtime, title = excluded.title,
		last_check = excluded.last_check, tags = excluded.tags, headers = excluded.headers
	};

	$s->{dbh}->do( $sql, undef, $arg{uri}, $arg{filename}, $arg{mtime}, $arg{headers}->{title}, $s->{json}->encode( $arg{headers}->{tags} // [] ), $s->{json}->encode( $arg{headers} // {} ) );

}

sub query {

	my ( $s, %arg ) = @_;

	$arg{limit}  //= 20;
	$arg{offset} //= 0;

	my @keys = qw(uri path mtime title last_check tags headers);

	my $columns = join( ',', @keys );

	if ( $arg{count} ) {
		@keys    = "count";
		$columns = "count(*)";
	}

	my $sql = qq{
	select $columns
	from meta_index
	where true $arg{where}
	$arg{order}
	limit $arg{limit} offset $arg{offset}
	};

	my @data = $s->{dbh}->selectall_array($sql);

	return $data[0]->[0] if $arg{count};

	return () unless @data;

	my @rows = map { my %a; @a{@keys} = @{$_}; \%a } @data;

	return @rows;

}

1;
