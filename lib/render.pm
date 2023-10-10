package render;

use common::sense;
use File::Slurper qw(read_text);
use Template;
use CommonMark qw(:node :event);
use YAML       qw(thaw);
use Try::Tiny;
use Data::Dumper qw(Dumper);
use tt;
$Data::Dumper::SortKeys = 1;

sub new {

	my ( $class, $app ) = @_;

	my $s = {
		app    => $app->{app},
		config => $app->{config},
		tt     => {
			headers => {},
			body    => '',
		},
	};

	bless $s;

}

sub get_file {

	my ( $s, %arg ) = @_;

	die 'unreadable file' unless -r $arg{filename};

	my $file = read_text( $arg{filename} );

	my ( $file_headers, $file_body ) = split( '\n\n', $file, 2 );

	$file_headers =~ s/^---$//mg;

	my $headers = thaw($file_headers);

	return ( $headers, $file_body );

}

sub markdown {

	my ( $s, %arg ) = @_;

	die 'bad file descriptor' unless $arg{filename};

	my $md;

	my ( $headers, $file_body ) = try { $s->get_file( filename => $arg{filename} ) } catch { return 404 };

	$s->{tt}->{headers} = $headers;

	if ( $headers->{parse} ) {
		$file_body = $s->template( template_data => $file_body, return_string => 1 );
	}

	# links
	if ( $file_body =~ m/\[\[.*?\]\]/m ) {

		#$file_body = $s->mext_pre_links($file_body);
	}

	$md = CommonMark->parse( string => $file_body, validate_utf8 => 1 ) || die 'file parse error';

	$s->{app}->{db}->touch( $arg{uri}, $arg{filename}, $headers );

	$s->{tt}->{body} = $s->markdown_render($md);

	$s->{app}->{body}->[0] = $s->template();

}

sub markdown_apply_extensions {

	my ( $s, $node ) = @_;

	if ( $node->get_type == NODE_TEXT ) {
	}
	elsif ( $node->get_type == NODE_BLOCK_QUOTE ) {

		# check for callouts
		if ( $node->first_child->first_child->get_literal =~ /\[!.*?\]/ ) {

			# extract heading line and remove it along with its newline
			my $heading = $node->first_child->first_child->get_literal;
			$node->first_child->first_child->unlink;

			# this one may not work if title is not set
			eval { $node->first_child->first_child->unlink };

			my ( $icon, $title ) = $heading =~ m/^\w*\[!(.*?)\]\w*(.*?)\w*$/;
			$title = ucfirst($icon) unless $title;

			# extract all children
			my @children;
			my $child = $node->first_child;
			do { push @children, $child } while ( $child = $child->next );

			# create heading block
			my $heading_node = CommonMark->create_custom_block(
				on_enter => qq{<div class="callout-title">},
				on_exit  => qq{</div>},
				children => [
					CommonMark->create_custom_block(
						on_enter => qq{<div class="callout-icon" data-callout="$icon">},
						on_exit  => qq{</div>},
					),
					CommonMark->create_custom_block(
						on_enter => qq{<div class="callout-title-inner">},
						on_exit  => qq{</div>},
						children => [ CommonMark->create_text( literal => $title ) ],
					),
				],
			);

			# create new custom block
			my $callout = CommonMark->create_custom_block(
				on_enter => qq{<div class="callout" data-callout="$icon">},
				on_exit  => qq{</div>},
				children => [
					$heading_node,
					CommonMark->create_custom_block(
						on_enter => qq{<div class="callout-content">},
						on_exit  => qq{</div>},
						children => \@children,
					),
				],
			);

			my $parent_node = $node->parent;
			$node->replace($callout);

			print STDERR "\t\t\t\e[33mrecursing!\e[m\n";
			return $s->markdown_apply_extensions($parent_node);

		}

	}
	elsif ( $node->get_type == NODE_IMAGE ) {
		print STDERR "\t\e[1m " . $node->get_start_line . ":" . $node->get_start_column . " " . "(" . $node->get_type_string . ") " . $node->get_url . "\e[m\n";
	}
	elsif ( my $child = $node->first_child ) {

		print STDERR "\ttraversing children\n";
		do {
			$s->markdown_apply_extensions($child);
		} while ( $child = $child->next );

	}

	return $node;

}

sub mext_pre_links {

	my ( $s, $txt ) = @_;

	my $parse = sub {

		my ( $is_pic, $inner ) = @_;

		if ($is_pic) { return qq{![$inner]($inner)}; }

		my ( $uri, $text );

		if ( $inner =~ /\|/ ) {
			( $uri, $text ) = $inner =~ m/^(.*?)\|(.*)$/;
		}
		else {
			$text = $inner;
			$uri  = $inner;
		}

		$uri =~ s/ /+/g;

		return qq{[$text]($uri)};

	};

	$txt =~ s/(!)*\[\[(.*?)\]\]/&$parse($1,$2)/meg;

	return $txt;

}

sub markdown_render {

	my ( $s, $md ) = @_;

	$md = $s->markdown_apply_extensions($md);

	return $md->render_html(CommonMark::OPT_UNSAFE);

}

sub template {

	my ( $s, %arg ) = @_;

	my $output  = "";
	my $tt_file = $arg{template} // $s->{config}->{template};

	$tt_file = \$arg{template_data} if $arg{template_data};

	my $tt = Template->new(
		{
			ENCODING     => 'UTF-8',
			INCLUDE_PATH => $s->{config}->{template_path},

			#LOAD_PLUGINS => [ tt->new({}) ],
			#POST_CHOMP => 1,
		}
	) || die $Template::ERROR;

	my $result = $tt->process( $tt_file, $s->{tt}, \$output );

	die $tt->error() unless $result;

	return $output;

}

1;
