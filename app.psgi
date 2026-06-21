#! /usr/local/bin/perl

use common::sense;
use lib 'lib';
use qmds;
use render;
use db;
use Plack::Request;
use Plack::Builder;
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

my $config_file = &load_config();

bootstrap($config_file);

my $default_config = $config_file->{hosts}->{ $config_file->{hostname}->{default} };

my $app = sub {

	my $env = shift;

	my $http_host = $config_file->{hostname}->{ $env->{HTTP_HOST} };
	my $config    = $http_host ? $config_file->{hosts}->{$http_host} : $default_config;

	my $db = db->new( { config => $config } ) || die 'db connection failed';

	my $self = {
		status  => 200,
		headers => [],
		body    => undef,
		config  => $config,
		uri     => $env->{PATH_INFO},
		db      => $db,
		render  => undef,
		get     => undef,
		post    => undef,
		tt      => { variables => {} },
	};

	$self->{request} = Plack::Request->new($env);
	$self->{get}     = $self->{request}->query_parameters;
	$self->{post}    = $self->{request}->body_parameters;
	$self->{cookies} = $self->{request}->cookies;
	$self->{data}    = {};
	$self->{session} = {};
	$self->{render}  = render->new($self);

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

builder {
	# %v: Server name
	# %{X-Forwarded-For}i: The real IP passed by Nginx
	# %t: Time
	# "%r": Request line
	# %>s: Status
	# %b: Bytes
	# "%{Referer}i": Referer
	# "%{User-Agent}i": User Agent

	enable "ContentLength";
	enable "Head";
	enable "AccessLog", format => qq{\e[1m%t\e[m\t\e[36m%{Host}i\t\e[m\t%r\t%>s\t%b\t%{X-Forwarded-For}i\t%{Referer}i};
	enable "HTTPExceptions";

	$app;
};

sub load_config {

	my $config_file =
	  eval { decode_json( read_text( $ENV{QMDS_CONFIG} // "qmds.config" ) ) } // eval { YAML::XS::Load( read_text( $ENV{QMDS_CONFIG} // "qmds.config" ) ) } // die "config file not found";

	if ( !exists( $config_file->{hostname} ) ) {
		$config_file->{hostname} = {};
		foreach my $key ( keys %{ $config_file->{hosts} } ) {
			my $site = $config_file->{hosts}->{$key};
			foreach my $hostname ( ref( $site->{hostname} ) eq 'ARRAY' ? @{ $site->{hostname} } : $site->{hostname} ) {
				$config_file->{hostname}->{$hostname} = $key;
			}
		}
	}

	return $config_file;
}

sub bootstrap {

	my ($config) = @_;

	foreach my $host_key ( keys %{ $config->{hosts} } ) {

		my $host = $config->{hosts}->{$host_key};

		$host->{timezone}      //= $config->{timezone} // 'UTC';
		$host->{template_path} //= $host->{path} . '/tt';
		$host->{template}      //= 'base.tt';
		$host->{view_path}     //= $host->{path} . '/view';
		$host->{static_root}   //= $host->{path} . '/shared';
		$host->{md_suffix}     //= ['.md'];
		$host->{default}       //= 'index';
		$host->{db}            //= $host->{path} . '/metadata.db';

		die "$host_key: no md_root defined" unless $host->{md_root};

		my $db = db->new( { config => $host } );

		$db->bootstrap_db();

		if ( exists( $host->{controller} ) && defined( $host->{controller} ) ) {
			do {
				eval { require $host->{controller}; 1 }
				  or eval { require $host->{path} . '/' . $host->{controller}; 1 }
				  or die "$host_key: $host->{controller} could not be loaded";
				controller::_bootstrap() if controller->can('_bootstrap');
			};
		}

	}

}
