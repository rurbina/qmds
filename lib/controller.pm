package controller;

use common::sense;
use db;

sub _new {

	my ( $class, $qmds, %args ) = @_;

	my $self = {
		app     => $qmds->{app},
		config  => $qmds->{config},
		db      => db->new( $qmds->{app} ),
		get     => $qmds->{app}->{get},
		post    => $qmds->{app}->{post},
		cookies => $qmds->{app}->{cookies},
		session => $qmds->{app}->{session},
		data    => $qmds->{app}->{data},
	};

	if ( $args{db_class} ) {
		$self->{db} = $args{db_class}->new( $qmds->{app} );
	}

	bless $self, $class;

	$self->_load_session() if $args{load_session};

	return $self;

}

sub _load_session {

	my ($self) = @_;

	# auth by cookie
	if ( ref $self->{cookies} eq 'HASH' && exists( $self->{cookies}->{session} ) ) {
		$self->{session} = $self->{db}->check_session( $self->{cookies}->{session} );
	}

	# auth by api key
	my $api_key = $self->{post}->{api_key} || $self->{get}->{api_key};
	if ( !exists( $self->{session}->{username} ) && $api_key ) {
		$self->{session} = $self->{db}->get_api_session($api_key);
	}

}

1;
