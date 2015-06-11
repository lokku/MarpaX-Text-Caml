package MarpaX::Text::Caml;

use strict;
use warnings;

use feature 'say';

require Scalar::Util;
use Clone qw(clone);
use List::Util qw(any);
use Marpa::R2;
use Data::Dumper::OneLine;

our $VERSION = '0.1';

sub dumper {
    require Data::Dumper;

    return Data::Dumper::Dumper @_;
}

sub new {
    my $class = shift;

    return bless {}, $class;
}

sub render {
    my $self = shift;
    my $template = shift;
    my $data = shift;

    return '' unless $template;

    return $self->_compile($template)->($data);
}

sub _compile {
    my $self = shift;
    my $template = shift;
    my $parsed = $self->_parse($template);

    my $code = eval $parsed // die $@;

    return sub {
        my $input = shift;

        $input = $self->_expand_variables($input);

        return $code->($input, \&_section);
    };
}

sub _expand_variables {
    my $self = shift;
    my $input = shift // {};

    foreach my $key ( keys $input ) {
        my $value = $input->{$key};

        if ( ref $value eq 'HASH' && !Scalar::Util::blessed($value) ) {
            $input->{$key} = $self->_expand_variables($value);
        }
        elsif ( ref $value eq 'ARRAY' ) {
            if ( any { ref $_ ne 'HASH' } @$value ) {
                $input->{$key} = [ map { { _self => $_ } } @$value ];
            }
            else {
                $input->{$key} = [ map { $self->_expand_variables($_) } @$value ];
            }

            $input->{$key} = $self->_add_indexes($input->{$key});
        }
    }

    return $input;
}

sub _add_indexes {
    my $self = shift;
    my $value = shift;

    my $i = -1;
    return [
        map {
            $i++;

            {
                _first  => $i == 0 ? 1 : 0,
                _last   => $i == scalar(@$value) - 1 ? 1 : 0,
                _idx    => $i,
                _even   => $i % 2 == 0 ? 1 : 0,
                _odd    => $i % 2 == 0 ? 0 : 1,
                %$_,
            }
        } @$value
    ];
}

sub _get_type {
    my $scalar = shift;

    if ( Scalar::Util::blessed($scalar) ) {
        return 'OBJECT';
    }
    elsif ( defined $scalar ) {
        return ref $scalar;
    }
    else {
        return 'UNDEF';
    }
}

sub _find_key {
    my $input = shift;
    my @keys = @_;
    $input = clone($input);

    # Walk down the context to find the value
    foreach my $key ( @keys ) {
        if ( Scalar::Util::blessed($input) ) {
            $input = $input->$key
        }
        elsif ( ref $input eq 'HASH' ) {
            $input = $input->{$key};
        }
        elsif ( ref $input eq 'ARRAY' ) {
            $input = $input->[$key];
        }
    }

    if ( !defined $input && scalar @keys > 1 ) {
        my $last = pop @keys;
        pop @keys;

        return _find_key($input, @keys, $last);
    }

    return $input;
}

sub _section {
    my $input = shift;
    my $ra_context = shift;
    my $value = shift // _find_key($input, @$ra_context);
    my @children = @_;

    return '' unless $value;

    if ( ref $value eq 'ARRAY' ) {
        return map {
            say dumper $input, [ @$ra_context, $_->{_idx} ];

            _section(
                $input,
                [ @$ra_context ],
                $_,
                @children
            )
        } @$value;
    }

    @children = _interpolate_variables($input, $ra_context, @children);
    @children = _remove_whitespace($input, $ra_context, @children);

    return join '', @children;
};

sub _remove_whitespace {
    my $input = shift;
    my $ra_context = shift;
    my @children = @_;

    return grep { defined && m/\S/ } @children;
}

sub _interpolate_variables {
    my $input = shift;
    my $ra_context = shift;
    my @children = @_;

    return map {
        if ( ref $_ eq 'HASH' && $_->{type} eq 'variable' ) {
            my $value = _find_key($input, @$ra_context, $_->{value});

            $_->{escape} ? _escape($value) : $value;
        }
        else {
            $_;
        }
    } @children;
}

sub _escape {
    my $value = shift;

    return $value unless defined $value;

    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;

    return $value;
}

sub _parse {
    my $self = shift;
    my $template = shift;
    my $ra_tree = ${$self->_parser->parse(\$template, 'MarpaX::Text::Caml::Actions')};

    my $output = $self->_parse_tree($ra_tree);

    return "sub { my (\$c, \$s) = \@_; return $output; }";
}

sub _parse_tree {
    my $self = shift;
    my $ra_tree = shift;
    my $context = shift // '';

    $ra_tree = $self->_flatten_trees($ra_tree);
    $ra_tree = $self->_insert_variables($ra_tree);
    $ra_tree = $self->_parse_children($ra_tree, $context);

    return "\$s->(\$c, [ $context ], undef, " . join(', ', @$ra_tree) . ")";
}


sub _insert_variables {
    my $self = shift;
    my $ra_tree = shift;

    return [
        map {
            if ( ref $_ eq 'HASH' && $_->{type} eq 'variable' ) {
                Dumper($_);
            }
            else {
                $_
            }
        } @$ra_tree
    ];
}

sub _parse_children {
    my $self = shift;
    my $ra_tree = shift;
    my $context = shift;

    return [ map {
        if ( ref $_ eq 'HASH' && $_->{type} eq 'context' ) {
            my $context_string = $context ? "$context, '" . $_->{value} . "'" : "'" . $_->{value} . "'";

            $self->_parse_tree($_->{tree}, $context_string);
        }
        else {
            $_;
        }
    } @$ra_tree ];
}

sub _flatten_trees {
    my $self = shift;
    my $ra_tree = shift;

    my @output = $self->_flatten($ra_tree);

    foreach my $el ( @output ) {
        if ( ref $el eq 'HASH' && $el->{type} eq 'context' ) {
            $el->{tree} = $self->_flatten_trees($el->{tree});
        }
    }

    return \@output;
}

sub _flatten {
    my $self = shift;
    my $arrayref = shift;

    return map { ref $_ eq 'ARRAY' ? $self->_flatten($_) : $_ } @$arrayref;
}

sub _parser {
    my $self = shift;
    my $grammar = $self->_grammar;

    return Marpa::R2::Scanless::G->new({
        source          => \$grammar,
        default_action  => 'do_rest_args',
    });
}

sub _grammar {
    my $self = shift;

    return <<'    GRAMMAR';

    lexeme default = latm => 1

    :start ::= mustache

    mustache ::= string_node
                | interpolate_node

    interpolate_node ::= interpolate
                      | interpolate string_node
                      | interpolate interpolate_node

    interpolate ::= '{{' word '}}'                              action => do_interpolate_escaped
                  | '{{{' word '}}}'                            action => do_interpolate
                  | '{{&' word '}}'                             action => do_interpolate
                  | '{{#' word '}}' mustache '{{/' word '}}'    action => do_section
                  | '{{^' word '}}' mustache '{{/' word '}}'    action => do_section

    word ~ maybe_whitespace just_word maybe_whitespace

    just_word ~ [\w.]+

    maybe_whitespace ~ whitespace*

    whitespace ~ [\s]+

    string_node ::= string
                  | string interpolate_node

    string ::= lstring+ action => do_string

    lstring ~ [^{}]+

    GRAMMAR
}

package MarpaX::Text::Caml::Actions {
    use Text::Trim qw(trim);

    sub do_rest_args {
        shift;

        return \@_;
    }

    sub do_string {
        my (undef, @chars) = @_;
        my $string = join '', @chars;

        return "'$string'";
    }

    sub do_interpolate {
        my (undef, undef, $variable, undef) = @_;

        return _interpolate($variable, 0);
    }

    sub do_interpolate_escaped {
        my (undef, undef, $variable, undef) = @_;

        return _interpolate($variable, 1);
    }

    sub _interpolate {
        my ($variable, $escape) = @_;

        if ( $variable =~ m/\.$/ ) {
            $variable = $variable . '_self';
        }

        my @context = grep { $_ } split /\./, $variable;

        $variable = pop @context;
        $variable = { type => 'variable', value => trim($variable), escape => $escape };

        if ( @context ) {
            return do_section(undef, undef, join('.', @context), undef, [[ $variable ]]);
        }

        return $variable;
    }

    sub do_section {
        my (undef, undef, $context, undef, $ra_tree) = @_;
        my ($first, @rest) = split /\./, $context;

        if ( @rest ) {
            $ra_tree = [ [ do_section(undef, undef, join('.', @rest), undef, $ra_tree) ] ];
        }

        return {
            type    => 'context',
            value   => trim($first),
            tree    => $ra_tree,
        };
    }
}

1;