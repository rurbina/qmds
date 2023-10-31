package db;

use DBI;
use DBD::SQLite;
use DBD::SQLite::Constants ':dbd_sqlite_string_mode';
use JSON::XS;
use Encode;
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
	$s->{dbh}->{sqlite_string_mode} = DBD_SQLITE_STRING_MODE_UNICODE_STRICT;

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

sub delete_uri {

	my ( $s, $uri ) = @_;

	my $sql = qq{delete from meta_index where uri = ?};

	$s->{dbh}->do( $sql, undef, $uri );

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

	if ( $arg{parse_meta} ) {

		foreach my $item (@rows) {

			my $link_title = $item->{title} // $item->{uri};
			$item->{link} = qq{<a href="$item->{uri}">$link_title</a>};

			my $meta = decode_json( Encode::encode( 'utf8', $item->{headers} ) );
			foreach my $key ( sort keys %$meta ) {
				$item->{"meta_$key"} = $meta->{$key};
			}

		}

	}

	return @rows;

}

sub get_absolute_uri {

	my ( $s, $uri ) = @_;

	my $sql = qq{
	select uri
	from meta_index
	where uri like ?
	order by length(uri) desc
	};

	my @uris = map { @{$_} } $s->{dbh}->selectall_array( $sql, {}, "\%$uri%" );

	return undef unless @uris;

	# find full matches
	my @matches = grep { $_ =~ m{/$uri} } @uris;

	return $matches[0] if scalar(@matches);

	return undef;

}

1;
