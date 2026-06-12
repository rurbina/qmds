#! /usr/local/bin/perl

use common::sense;
use lib 'lib';
use qmds;
use render;
use db;
use Plack::Request;
use JSON::XS 'decode_json';
use YAML::XS;
use File::Slurper qw(read_text);
use Capture::Tiny qw(capture_stdout);
use Encode;
use Data::Dumper 'Dumper';
$Data::Dumper::Sortkeys = 1;

binmode( STDIN,  ':utf8' );
binmode( STDOUT, ':utf8' );
binmode( STDERR, ':utf8' );

my $config_file = eval { decode_json( read_text( $ENV{QMDS_CONFIG} // "qmds.config" ) ) } // eval { YAML::XS::Load( read_text( $ENV{QMDS_CONFIG} // "qmds.config" ) ) } // die "config file not found";

bootstrap($config_file);

my $default_config = $config_file->{hosts}->{ $config_file->{hostname}->{default} };

my $app = sub {

	my $env = shift;

	my $_host  = $config_file->{hostname}->{ $env->{HTTP_HOST} };
	my $config = $_host ? $config_file->{hosts}->{$_host} : $default_config;

	my $db = db->new( { config => $config } ) || die 'db connection failed';

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

	foreach my $group ( qw(get post cookies) ) {
		foreach my $key ( %{$self->{$group}} ) {
			$self->{$group}->{$key} = decode_utf8( $self->{$group}->{$key} );
		}
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

sub bootstrap {

	my ($config) = @_;

	foreach my $host_key ( keys %{ $config->{hosts} } ) {

		my $host = $config->{hosts}->{$host_key};

		$host->{template_path} //= $host->{path} . '/tt';
		$host->{template}      //= 'base.tt';
		$host->{view_path}     //= $host->{path} . '/view';
		$host->{static_root}   //= $host->{path} . '/shared';
		$host->{md_suffix}     //= ['.md'];
		$host->{default}       //= 'index';

		die "$host_key: no md_root defined" unless $host->{md_root};

		my $db = db->new( { config => $host } );

		$db->bootstrap_db();

		if ( defined( $host->{controller} ) ) {
			do {
				eval { require $host->{controller}; 1 }
				or eval { require $host->{path} . '/' . $host->{controller}; 1 }
				or die "$host_key: $host->{controller} could not be loaded";
				controller::_bootstrap() if controller->can('_bootstrap');
			};
		}

	}

}
