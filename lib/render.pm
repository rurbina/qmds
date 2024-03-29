package render;

use common::sense;
use feature 'unicode_strings';
use Encode qw(from_to);
use File::Slurper qw(read_text);
use Template;
use CommonMark qw(:node :event);
use YAML       qw(thaw);
use JSON::XS;
use Try::Tiny;
use List::Util qw(any);
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

	my ( $file_headers, $file_body );

	if ( $file =~ m/^---\n(.*)\n---\n(.*)$/s ) {
		( $file_headers, $file_body ) = ( $1, $2 );
	}
	else {
		( $file_headers, $file_body ) = split( '\n\n', $file, 2 );
	}

	my $headers = YAML::thaw($file_headers);

	return ( $headers, $file_body );

}

sub markdown {

	my ( $s, %arg ) = @_;

	die 'bad file descriptor' unless $arg{filename};

	my $md;

	my ( $headers, $file_body ) = try { $s->get_file( filename => $arg{filename} ) } catch { return ( 404, undef ) };

	$s->{tt}->{headers} = $headers;

	if ( $headers->{parse} ) {
		$file_body = $s->template( template_data => $file_body, return_string => 1, binmode => ':utf8' );
	}

	# wikilinks
	if ( $file_body =~ m/\[\[.*?\]\]/g ) {
		$file_body = $s->mext_pre_links($file_body);
	}

	$md = CommonMark->parse( string => $file_body, validate_utf8 => 1 ) || die 'file parse error';

	$s->{app}->{db}->touch( uri => $arg{uri}, filename => $arg{filename}, headers => $headers );

	return 1 if $arg{touch_only};

	my $body = $s->markdown_render($md);

	return $body if $arg{no_template};

	$s->{tt}->{body} = $body;

	return $s->template();

}

sub markdown_apply_extensions {

	my ( $s, $node ) = @_;

	if ( $node->get_type == NODE_TEXT ) {
	}
	elsif ( $node->get_type == NODE_PARAGRAPH && ( $node->first_child ? $node->first_child->get_literal =~ m/^\|/ : undef ) ) {

		# markdown tables
		my @children = $node->get_children;

		# rows are separated by softbreaks
		my @rows;
		my $row = [];
		foreach my $child (@children) {
			if ( $child->get_type_string eq 'softbreak' ) {
				push @rows, $row;
				$row = [];
			}
			else {
				push @$row, $child;
			}
		}
		push @rows, $row if @$row;

		# properly convert rows to html
		my @html_rows;
		foreach my $row (@rows) {

			next if $row->[0]->get_literal =~ m/\|-+\|/;

			my $p    = CommonMark->create_paragraph( children => $row );
			my $html = $p->render_html;

			$html =~ s/^<p>\|\s*/<td>/s;
			$html =~ s/\s*\|<\/p>/<\/td>/s;
			$html =~ s/\s*(?<!\\)\|\s*/<\/td><td>/g;

			push @html_rows, $html;
		}

		$html_rows[0] =~ s/(<\/?)td(>)/\1th\2/g;

		my @html = ( '<table>', map( { ( '<tr>', $_, '</tr>' ) } @html_rows ), '</table>' );
		my $html = join( "\n", @html );
		$html =~ s/\n+/\n/g;

		my $new_node = CommonMark->create_html_block( literal => $html );
		$node->replace($new_node);

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

			return $s->markdown_apply_extensions($parent_node);

		}

	}
	elsif ( $node->get_type == NODE_LIST ) {

		# the holy grail: <dl>
		# check in list->item->p->text
		if ( $node->first_child->first_child->first_child->get_literal =~ m/\s::\s/ ) {

			my $dl = {
				on_enter => qq{<dl>},
				on_exit  => qq{</dl>},
				children => [],
			};

			my @items = $node->get_children();

			foreach my $item (@items) {

				my ( $dt, $dd );

				$dd = { on_enter => qq{<dd>}, on_exit => qq{</dd>}, children => [] };

				# avoid the <p> if we can
				if ( scalar( $item->get_children ) == 1 && $item->first_child->get_type == NODE_PARAGRAPH ) {
					$dd->{children} = [ $item->first_child->get_children ];
				}
				else {
					$dd->{children} = [ $item->get_children ];
				}

				if ( $item->first_child->first_child->get_type == NODE_TEXT ) {

					$item->first_child->first_child->get_literal =~ m/^(.*?)\w*::\w*(.*?)?$/;

					my ( $dt_text, $dd_text ) = ( $1, $2 );

					# if text is found, adjust first child in <dd>
					if ($dt_text) {
						$dt = { on_enter => qq{<dt>}, on_exit => qq{</dt>}, text => $dt_text };

						shift @{ $dd->{children} };
						unshift @{ $dd->{children} }, CommonMark->create_text( literal => $dd_text );
					}
				}

				push( @{ $dl->{children} }, CommonMark->create_custom_block( %{$dt} ) ) if $dt;
				push( @{ $dl->{children} }, CommonMark->create_custom_block( %{$dd} ) ) if $dd;

			}

			my $dl_node = CommonMark->create_custom_block( %{$dl} );

			my $parent_node = $node->parent;
			$node->replace($dl_node);

			return $s->markdown_apply_extensions($parent_node);

		}

	}
	elsif ( $node->get_type == NODE_IMAGE ) {

		my ( $url, $text );

		$url = $node->get_url;

		next unless scalar $node->get_children;

		$text = $node->first_child->get_literal // '';

		$text      =~ m/^(?<title>.*?)\|(?<class>[^|]+)\|(?<size>[^|]+)$/
		  || $text =~ m/^(?<title>.*?)\|(?<size>[^|]+)$/
		  || $text =~ m/^(?<title>.*)$/;

		my ( $title, $size, $class ) = @+{ 'title', 'size', 'class' };

		my $escaped_title = $s->escape_xml($title);

		my $style;
		if ($size) {
			if ( $size =~ m/^(\d+)x(\d+)$/ ) {
				$style = qq(style="width:${1}px;height:${2}px");
			}
		}

		my $html = qq{<img src="$url" $class $style title="$escaped_title" />};
		$html =~ s/  +/ /;

		my $img = CommonMark->create_html_inline( literal => $html );

		my $parent_node = $node->parent;
		$node->replace($img);
		return $s->markdown_apply_extensions($parent_node);

	}
	elsif ( $node->get_type == NODE_HTML_BLOCK && $node->get_literal =~ m/^<!--#blog-posts\s/ ) {

		my $items_per_page = 20;
		my $page           = $s->{app}->{get}->{page};
		my $offset         = ( $page - 1 ) * $items_per_page;

		my $where = qq{and tags like '%"blog"%'};
		my @posts = $s->{app}->{db}->query(
			where  => $where,
			offset => $offset,
			limit  => $items_per_page,
			order  => q{order by json_extract(headers,'$.timestamp') desc},
		);

		my @md_posts;

		foreach my $post (@posts) {

			my ( $headers, $md_body ) = $s->get_file( filename => $post->{path} );

			$md_body = "<div class=\"blog-post-meta\">$headers->{author} \@ $headers->{timestamp}</div>\n\n" . $md_body;

			# truncate at first hr
			if ( $md_body =~ m/^(.*?)\n----+\n/s ) {
				$md_body = $1;
				$md_body .= "\n\n[Seguir leyendo]($post->{uri})";
			}

			# increase header level
			$md_body =~ s/^(#{1,5}) /#$1 /smg;

			# first header should link to the full post
			$md_body =~ s/^(#+) ([^\n]+)/$1 [$2]($post->{uri})/sm;

			# apply wikilinks
			$md_body = $s->mext_pre_links($md_body);

			push @md_posts, $md_body;
		}

		# pagination
		my $count = $s->{app}->{db}->query( count => 1, where => $where );

		my $total_pages = int( $count / $items_per_page ) + ( $count % $items_per_page ? 1 : 0 );

		if ( $total_pages > 1 ) {

			my $uri = $s->{app}->{uri};

			my @items;

			push( @items, $page > 1 ? qq{<a href="$uri?page=1">&lt;&lt;</a>} : "&lt;&lt;" );

			my $prev = $page - 1;
			push( @items, $prev > 0 ? qq{<a href="$uri?page=$prev">&lt;</a>} : "&lt;" );

			foreach my $n ( 1 .. $total_pages ) {
				push @items, ( $n == $page ? $n : qq{<a href="$uri?page=$n">$n</a>} );
			}

			my $next = $page + 1;
			push( @items, $next <= $total_pages ? qq{<a href="$uri?page=$next">&gt;</a>} : "&gt;" );

			push( @items, $page < $total_pages ? qq{<a href="$uri?page=$total_pages">&gt;&gt;</a>} : "&gt;&gt;" );

			my $items = join( '', map { qq{\t<span>$_</span>\n} } @items );
			my $div   = qq{<div class="pagination"><span>Páginas</span>$items</div>};
			push @md_posts, $div;

		}

		my $md_posts = join "\n\n----\n\n", @md_posts;
		my $md       = CommonMark->parse( string => $md_posts );
		my $html     = $s->markdown_render($md);

		$node->set_literal($html);

	}
	elsif ( $node->get_type == NODE_HTML_BLOCK && $node->get_literal =~ m/^<!--#index-table\s+(?<options>.*?)-->/ ) {

		my $options = eval { decode_json( $+{options} ) } // { defaults => 1 };
		if ( $options->{defaults} ) {
			print STDERR "\e[31mindex-table options not parsed: $+{options}\e[m\n";
		}

		my $where;

		if ( $options->{tag} || $options->{tags} ) {
			my @tags;
			push( @tags, $options->{tag} )       if $options->{tag};
			push( @tags, @{ $options->{tags} } ) if ref( $options->{tags} ) eq 'ARRAY';

			$where .= 'AND (' . join( ' OR ', map { "tags like '%\"$_\"%'" } @tags ) . ') ';
		}

		if ( $options->{headers_like} ) {
			$where .= "AND headers LIKE '$options->{headers_like}' ";
		}

		my @items = $s->{app}->{db}->query(
			where      => $where,
			order      => 'order by title',
			parse_meta => 1,
		);

		my @rows;

		my @columns = ref( $options->{columns} ) eq 'ARRAY' ? @{ $options->{columns} } : ( [ link => 'Link' ] );

		my @th = map { qq{<th>$_->[1]</th>} } @columns;
		push( @rows, join( "\n", '<tr>', @th, '</tr>' ) );

		foreach my $item (@items) {
			my @values;
			foreach my $col (@columns) {

				my ( $key, $name ) = @{$col};

				push @values, $item->{$key};

			}

			my $row = join( "\n", '<tr>', map( { qq{<td>$_</td>} } @values ), '</tr>' );
			push @rows, $row;
		}

		my @html = ( '<table class="index-table">', map( { qq{<tr>$_</tr>} } @rows ), '</table>' );

		my $html = join( "\n", @html );

		$node->set_literal($html);

	}
	elsif ( my $child = $node->first_child ) {

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
			$uri  = lc($inner);
		}

		$uri =~ s/ /_/g;
		$uri =~ tr/áéíóúüñ/aeiouun/;

		# smart match uris with no path
		if ( $uri !~ m/^(\.\.|https?|\/)/ ) {
			$uri = $s->{app}->{db}->get_absolute_uri($uri);
		}

		return $uri ? qq{[$text]($uri)} : "[[$inner]]";

	};

	my $newtxt = $txt;
	$newtxt =~ s/(!)*\[\[(.*?)\]\]/&$parse($1,$2)/meg;

	return $newtxt;

}

sub markdown_render {

	my ( $s, $md ) = @_;

	$md = $s->markdown_apply_extensions($md);

	my $html = $md->render_html( CommonMark::OPT_UNSAFE | CommonMark::OPT_VALIDATE_UTF8 );

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

	my $result = $tt->process( $tt_file, $s->{tt}, \$output, binmode => ':utf8' );

	die $tt->error() unless $result;

	return $output;

}

sub escape_xml {

	my ( $s, $data ) = @_;

	$data =~ s/&/&amp;/sg;
	$data =~ s/</&lt;/sg;
	$data =~ s/>/&gt;/sg;
	$data =~ s/"/&quot;/sg;

	return $data;

}

sub CommonMark::Node::is_leaf {

	my ( $item ) = @_;

	my @leaves = (
		CommonMark::NODE_HTML,
		CommonMark::NODE_HRULE,
		CommonMark::NODE_CODE_BLOCK,
		CommonMark::NODE_TEXT,
		CommonMark::NODE_SOFTBREAK,
		CommonMark::NODE_LINEBREAK,
		CommonMark::NODE_CODE,
		CommonMark::NODE_INLINE_HTML,
	);

	return any sub { $_ == $item->get_type }, @leaves;
	
}

sub CommonMark::Node::get_children {

	my ( $parent ) = @_;

	my @children;

	if ( my $node = $parent->first_child ) {
		do {
			push @children, $node;
		} while ( $node = $node->next );
	}

	return @children;

}

1;
