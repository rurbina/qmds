#! /usr/local/bin/perl

use common::sense;
use lib 'lib';
use qmds;
use render;
use db;
use Plack::Request;
use JSON::XS 'decode_json';
use File::Slurper qw(read_text);
use Capture::Tiny qw(capture_stdout);
use Encode;
use Data::Dumper 'Dumper';
$Data::Dumper::Sortkeys = 1;

binmode( STDIN,  ':utf8' );
binmode( STDOUT, ':utf8' );
binmode( STDERR, ':utf8' );

my $config_file    = decode_json( read_text( $ENV{QMDS_CONFIG} // "qmds.config" ) );
my $default_config = $config_file->{hosts}->{ $config_file->{hostname}->{default} };

my $app = sub {

	my $env = shift;

	my $_host  = $config_file->{hostname}->{ $env->{HTTP_HOST} };
	my $config = $_host ? $config_file->{hosts}->{$_host} : $default_config;

	my $db = db->new( { config => $config } );

	my $self = {
		status  => 200,
		headers => [],
		body    => undef,
		config  => $config,
		uri     => $env->{PATH_INFO},
		db      => $db,
		get     => undef,
		post    => undef,
		tt      => { variables => {} },
	};

	my $request = Plack::Request->new($env);
	$self->{get}     = $request->query_parameters;
	$self->{post}    = $request->body_parameters;
	$self->{cookies} = $request->cookies;
	$self->{data}    = {};
	$self->{session} = {};

	foreach my $key ( %{$self->{get}} ) {
		$self->{get}->{$key} = decode_utf8( $self->{get}->{$key} );
	}

	foreach my $key ( %{$self->{post}} ) {
		$self->{post}->{$key} = decode_utf8( $self->{post}->{$key} );
	}

	foreach my $key ( %{$self->{cookies}} ) {
		$self->{cookies}->{$key} = decode_utf8( $self->{cookies}->{$key} );
	}

	my $handler = qmds->new($self);

	( $self->{status}, $self->{body}->[0], $self->{headers} ) = $handler->dispatch( $env->{PATH_INFO} );

	if ( $self->{status} != 200 && exists( $config->{"error_$self->{status}"} ) ) {
		( $self->{status}, $self->{body}->[0], $self->{headers} ) = $handler->dispatch( $config->{"error_$self->{status}"} );
	}

	if ( ref( $self->{body}->[0] ) eq 'GLOB' ) {
		$self->{body} = $self->{body}->[0];
	}
	$self->{headers} = [] unless ref( $self->{headers} ) eq 'ARRAY';

	return [ @{$self}{ 'status', 'headers', 'body' } ];

};
