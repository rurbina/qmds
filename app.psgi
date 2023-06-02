# qmds

use common::sense;
use lib 'lib';
use qmds;
use render;
use JSON::XS 'decode_json';
use File::Slurper 'read_text';

use Data::Dumper 'Dumper';
$Data::Dumper::Sortkeys = 1;

my $config = decode_json( read_text("qmds.config") );

my $app = sub {

	my $env = shift;

	my $self = {
		status => {},
		headers => {},
		body => {},
	};

	my $handler = qmds->new($self);

	die Dumper [ $env, $config ];
	
	return [ @{$self}{ 'status', 'headers', 'body' } ];

};
