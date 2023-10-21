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
use Data::Dumper 'Dumper';
$Data::Dumper::Sortkeys = 1;

binmode( STDIN,  ':utf8' );
binmode( STDOUT, ':utf8' );
binmode( STDERR, ':utf8' );

my $config_file = decode_json( read_text( $ENV{QMDS_CONFIG} // "qmds.config" ) );
my $config      = $config_file->{hosts}->{ $config_file->{hostname}->{default} };
my $db;

my $app = sub {

	my $env = shift;

	my $_host = $config_file->{hostname}->{ $env->{HTTP_HOST} };
	$config = $config_file->{hosts}->{$_host} if $_host;

	$db = db->new( { config => $config } );

	my $self = {
		status  => 200,
		headers => [],
		body    => undef,
		config  => $config,
		uri     => $env->{PATH_INFO},
		db      => $db,
	};

	my $request = Plack::Request->new($env);
	$self->{get}  = $request->query_parameters;
	$self->{post} = $request->body_parameters;

	my $handler = qmds->new($self);

	( $self->{status}, $self->{body}->[0] ) = $handler->dispatch( $env->{PATH_INFO} );
	if ( ref( $self->{body}->[0] ) eq 'GLOB' ) {
		$self->{body} = $self->{body}->[0];
	}

	if ( $self->{status} != 200 && exists( $config->{"error_$self->{status}"} ) ) {
		( undef, $self->{body}->[0] ) = capture_stdout sub { $handler->dispatch( $config->{"error_$self->{status}"} ) };
	}

	return [ @{$self}{ 'status', 'headers', 'body' } ];

};
