package db;

use common::sense;
use DBI;
use DBD::SQLite;
use DBD::SQLite::Constants ':dbd_sqlite_string_mode';
use Data::GUID;
use JSON::XS;
use Crypt::ScryptKDF qw(scrypt_hash scrypt_hash_verify);
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

	return $s;

}

sub bootstrap_db {

	my ($s) = @_;

	my @tables = (
		# meta_index
		qq{create table if not exists meta_index (uri primary key, path, mtime, title, last_check, tags, headers)},

		# users
		qq{
		create table if not exists users (
			username primary key not null,
			password,
			name,
			email,
			created_at default (datetime('now'))
		);
		},

		# sessions
		qq{
		create table if not exists sessions (
			session_id primary key not null,
			username references users(username) on delete cascade,
			last_touch_time default (datetime('now'))
		);
		},

		# session messages
		qq{
		create table if not exists session_messages (
			id integer primary key not null,
			username references users(username) on delete cascade,
			class,
			text,
			timestamp default (datetime('now')),
			seen
		);
		},

		# api_keys
		qq{
		create table if not exists api_keys (
			api_key text primary key not null,
			username references users(username) on delete cascade
		);
		},

	);

	foreach my $table (@tables) {
		$s->{dbh}->do($table) || die Dumper { bootstrap_error => $s->{dbh}->errstr, query => $table };
	}

}

sub insert {

	my ( $s, $data, $table, %arg ) = @_;

	my $p_data = $s->parametrize($data);
	my $names  = join( ',', @{ $p_data->{names} } );
	my $qmarks = join( ',', ('?') x scalar( @{ $p_data->{names} } ) );
	my $sql    = qq{INSERT INTO $table ($names) VALUES ($qmarks)};

	$sql =~ s/^INSERT/INSERT OR REPLACE/ if $arg{replace};

	my $sth = $s->{dbh}->prepare($sql) || die Dumper { error => $s->{dbh}->errstr, query => $sql };
	$sth->execute( @{ $p_data->{params} } );
	$sth->finish();

}

sub upsert {

	my ( $s, $data, $table, $conflict_keys ) = @_;

	my $p_data = $s->parametrize($data);
	my $names  = join( ',', @{ $p_data->{names} } );
	my $qmarks = join( ',', ('?') x scalar( @{ $p_data->{names} } ) );

	# prepare update data (exclude conflict keys)
	my %update_data = %$data;
	delete @update_data{@$conflict_keys};
	my $p_update = $s->parametrize( \%update_data, glue => ', ' );

	my $conflict_clause = join( ',', @$conflict_keys );
	my $sql = qq{INSERT INTO $table ($names) VALUES ($qmarks) ON CONFLICT($conflict_clause) DO UPDATE SET $p_update->{sql}};

	my $sth = $s->{dbh}->prepare($sql) || die Dumper { error => $s->{dbh}->errstr, query => $sql };
	$sth->execute( @{ $p_data->{params} }, @{ $p_update->{params} } );
	$sth->finish();

}

sub update {

	my ( $s, $index, $data, $table ) = @_;

	my $p_data  = $s->parametrize( $data, glue => ', ' );
	my $p_index = $s->parametrize($index);

	my $sql    = qq{UPDATE $table SET $p_data->{sql} WHERE $p_index->{sql}};
	my @params = ( @{ $p_data->{params} }, @{ $p_index->{params} } );

	my $sth = eval { $s->{dbh}->prepare($sql) } || die $sql;
	$sth->execute(@params);
	$sth->finish();

}

sub delete {

	my ( $s, $index, $table ) = @_;

	my $p_index = $s->parametrize($index);

	my $sql    = qq{DELETE FROM $table WHERE $p_index->{sql}};
	my @params = @{ $p_index->{params} };

	my $sth = $s->{dbh}->prepare($sql);
	$sth->execute(@params);
	$sth->finish();

}

sub parametrize {

	my ( $s, $hash, %arg ) = @_;

	my ( @params, @sql, @names );

	foreach my $key ( sort keys %{$hash} ) {
		if ( $key =~ m/(date|time)/ && $hash->{$key} eq 'now' ) {
			push @sql, qq{$key = datetime('now')};
		}
		else {
			push @sql,    qq{$key = ?};
			push @params, $hash->{$key};
			push @names,  $key;
		}
	}
	my $glue = $arg{glue} // ' and ';

	return { params => \@params, sql => join( $glue, @sql ), names => \@names };

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

sub query_index {

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

sub check_login {

	my ( $s, $user, $pass ) = @_;

	my $sql = qq{select password from users where username = ?};

	my $sth = $s->{dbh}->prepare($sql) || die $s->{dbh}->errstr;
	$sth->execute($user)               || die $s->{dbh}->errstr;

	my ($hash) = $sth->fetchrow_array();

	$sth->finish();

	return $s->test_password( $pass, $hash ) ? $user : undef;

}

sub create_session {

	my ( $s, $user ) = @_;

	my $session_id = Data::GUID->new()->as_string();

	$s->insert( { session_id => $session_id, username => $user }, 'sessions' );

	return $session_id;

}

sub check_session {

	my ( $s, $session_id ) = @_;

	# delete old registration requests -- do we need to?
	$s->{dbh}->do(
		qq{
		      DELETE FROM new_users
		      WHERE ((strftime('%s', timestamp) - strftime('%s', 'now')) / 86400) > 7}
	) if 0;

	# delete old sessions
	$s->{dbh}->do(
		qq{
		      DELETE FROM sessions
		      WHERE ((strftime('%s', last_touch_time) - strftime('%s', 'now')) / 86400) > 35}
	);

	my $sql = qq{SELECT username FROM sessions WHERE session_id = ?};

	my $sth = $s->{dbh}->prepare($sql);
	$sth->execute($session_id);

	my ($username) = $sth->fetchrow_array();

	$sth->finish();

	if ($username) {

		my $session = {
			username   => $username,
			session_id => $session_id,
			data       => {},
		};

		$session->{messages} = $s->session_pop_messages($username);

		return $session;
	}

	return;

}

sub delete_session {

	my ( $s, $session_id ) = @_;

	my $sql = qq{DELETE FROM sessions WHERE session_id = ?};

	my $sth = $s->{dbh}->prepare($sql);
	$sth->execute( $session_id );
	$sth->finish();

}

sub get_api_key {

	my ( $s, $key ) = @_;

	my $sql = qq{select api_key,username,description from api_keys where api_key = ?};

	my $sth = $s->{dbh}->prepare($sql);
	$sth->execute($key);

	my $api_key = $sth->fetchrow_hashref();

	$sth->finish;

	return $api_key;

}

sub get_api_session {

	my ( $s, $param_api_key ) = @_;

	my $api_key = $s->get_api_key($param_api_key);
	return undef unless $api_key;

	my $session_id = 'API_' . Data::GUID->new()->as_string();

	my $session = {
		user       => $api_key->{username},
		session_id => $session_id,
		is_api     => 1,
		data       => {},
	};

	return $session;

}

sub create_user {

	my ( $s, $user, $clear_pass, $name, $email ) = @_;

	my $pass = $s->encrypt_password($clear_pass);

	$s->insert( { username => $user, password => $pass, name => $name, email => $email }, 'users' );

	$s->create_session($user);

}

sub session_push_message {

	my ( $s, $username, $class, $message ) = @_;

	$s->insert( { username => $username, class => $class, text => $message, seen => 0 }, 'session_messages' );
	
}

sub session_pop_messages {

	my ( $s, $username ) = @_;

	my @messages;

	my $sql = qq{select id,class,text,timestamp from session_messages where username = ? and not coalesce(seen,0) order by timestamp desc};

	my $sth = $s->{dbh}->prepare($sql) || die Dumper { error => $s->{dbh}->errstr, query => $sql };
	$sth->execute($username) || die Dumper { error => $s->{dbh}->errstr, query => $sql };

	while ( my $message = $sth->fetchrow_hashref() ) {
		push @messages, $message;
	}

	$sth->finish;

	foreach my $message (@messages) {

		$s->update( { id => $message->{id} }, { seen => 1 }, 'session_messages' );
	}

	return wantarray ? @messages : \@messages;

}

sub encrypt_password {

	my ( $s, $pass ) = @_;

	my $cypher_hashed = scrypt_hash($pass);

	return $cypher_hashed;

}

sub test_password {

	my ( $s, $pass, $hash ) = @_;

	return scrypt_hash_verify( $pass, $hash );

}

1;
