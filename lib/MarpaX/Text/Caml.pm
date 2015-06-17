package MarpaX::Text::Caml;

use strict;
use warnings;

use feature 'say';

require Scalar::Util;
use List::Util qw(any none);
use Array::Compare;
use File::Slurp qw(read_file);
use Text::Trim qw(trim);
use Marpa::R2;
use Data::Dumper::OneLine;

our $VERSION = '0.1';

sub dumpit {
    require Data::Dumper;

    say Data::Dumper::Dumper \@_;
}

sub new {
    my $class = shift;
    my %opts = @_;

    return bless \%opts, $class;
}

sub render {
    my $self = shift;
    my $template = shift;
    my $data = ref $_[0] eq 'HASH' ? $_[0] : {@_};

    return $self->compile($template)->($data);
}

sub _inline_partials {
    my $self = shift;
    my $template = shift;

    foreach my $filename ( $template =~ m/{{>(.*)}}/g ) {
        my $partial = read_file($self->_path_for(trim($filename)));

        $partial = $self->_inline_partials($partial);
        $partial = trim($partial);

        $template =~ s/{{>$filename}}/$partial/;
    };

    return $template;
}

sub _path_for {
    my $self = shift;
    my $filename = shift;

    return join '/', grep { $_ } $self->{templates_path}, $filename;
}

sub render_file {
    my $self = shift;
    my $filename = shift;
    my $data = ref $_[0] eq 'HASH' ? $_[0] : {@_};

    return $self->compile_file($filename)->($data);
}

sub compile_file {
    my $self = shift;
    my $filename = shift;
    my $template = read_file($self->_path_for($filename));

    return $self->compile($template);
}

sub compile {
    my $self = shift;
    my $template = shift;

    return sub { '' } unless $template;

    $template = $self->_inline_partials($template);

    return $self->_compile($template);
}

sub _compile {
    my $self = shift;
    my $template = shift;
    my $parsed = $self->_parse($template);

    dumpit $parsed;

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
                $input->{$key} = $self->_expand_array_hashes($value);
            }
            else {
                $input->{$key} = [ map { $self->_expand_variables($_) } @$value ];
            }

            $input->{$key} = $self->_add_indexes($input->{$key});
        }
    }

    return $input;
}

sub _expand_array_hashes {
    my $self = shift;
    my $value = shift;

    return [ map {
        if ( ref $_ eq 'ARRAY' ) {
            { _self => $self->_expand_array_hashes($_) };
        }
        else {
            { _self => $_ };
        }
    } @$value ];
}

sub _add_indexes {
    my $self = shift;
    my $value = shift;

    my $i = -1;
    return [
        map {
            $i++;

            {
                _idx    => $i,
                _first  => $i == 0 ? 1 : 0,
                _last   => $i == scalar(@$value) - 1 ? 1 : 0,
                _even   => $i % 2 == 0 ? 1 : 0,
                _odd    => $i % 2 == 0 ? 0 : 1,
                %$_,
            }
        } @$value
    ];
}

sub _find_key_in_parent_scope {
    my $input = shift;
    my @keys = @_;
    my $last = pop @keys;

    my ($value, $ra_actual_keys) = _find_key($input, @keys);

    my $comp = Array::Compare->new;
    if ( !$comp->compare(\@keys, $ra_actual_keys) ) {
        return _find_key($input, @$ra_actual_keys, $last);
    };

    pop @keys; # remove the containing scope

    return _find_key($input, @keys, $last);
}

sub _find_key {
    my $input = shift;
    my @keys = @_;
    my $value = $input;

    # Walk down the context to find the value
    foreach my $key ( @keys ) {
        if ( Scalar::Util::blessed($value) ) {
            $value = $value->$key
        }
        elsif ( ref $value eq 'ARRAY' ) {
            if ( Scalar::Util::looks_like_number($key) ) {
                $value = $value->[$key];
            }
            else {
                return _find_key_in_parent_scope($input, @keys);
            }
        }
        elsif ( ref $value eq 'HASH' ) {
            if ( Scalar::Util::blessed($value->{_self}) ) {
                $value = $value->{_self}->$key;
            }
            else {
                $value = $value->{$key};
            }
        }
        elsif ( scalar @keys > 1 ) {
            return _find_key_in_parent_scope($input, @keys);
        }
        else {
            return undef;
        }
    }

    if ( !defined $value && scalar @keys > 1 ) {
        return _find_key_in_parent_scope($input, @keys);
    }

    if ( wantarray ) {
        return ($value, \@keys);
    }
    else {
        return $value;
    }
}

sub _resolve_context {
    my $input = shift;
    my $ra_left = shift;
    my $ra_right = shift;

    my @left = @$ra_left;
    my @right = @$ra_right;

    while ( @right ) {
        my $current = shift @right;

        my ($value, $ra_actual_left) = _find_key($input, @left, $current);

        if ( ref $value eq 'ARRAY' ) {
            return sub {
                my $index = shift;

                return _resolve_context($input, [ @$ra_actual_left, $index ], \@right);
            }
        }

        push @left, $current;
    }

    my ($value, $ra_actual_left) = _find_key($input, @left);

    return $ra_actual_left;
}

sub _in_array_section {
    my $input = shift;
    my $actual_context = shift;
    my $inverse = shift;
    my @children = @_;

    return sub {
        my $index = shift;
        my $inner_context = $actual_context->($index);

        if ( ref $inner_context eq 'CODE' ) {
            return _in_array_section($input, $inner_context, $inverse, @children);
        }
        else {
            return _section($input, $inner_context, $inverse, @children);
        }
    };
}

sub _array_section {
    my $value = shift;
    my $input = shift;
    my $ra_context = shift;
    my $inverse = shift;
    my @children = @_;

    dumpit $value;

    return map {
        my $index = $_->{_idx};

        my @inner = @children;
        while ( grep { ref $_ eq 'CODE' } @inner ) {
            @inner = map { ref $_ eq 'CODE' ? $_->($index) : $_ } @inner;
        }

        _section($input, $ra_context->($index), $inverse, @inner);
    } @$value;
}

sub _section {
    my $input = shift;
    my $ra_context = shift;
    my $inverse = shift;
    my @children = @_;

    my $actual_context = _resolve_context($input, [], $ra_context);
    my $value = _find_key($input, @$ra_context);

    if ( !defined $value && ref $actual_context eq 'CODE' ) {
        return _in_array_section($input, $actual_context, $inverse, @children);
    }

    if ( ref $value eq 'ARRAY' ) {
        if ( scalar @$value == 0 ) {
            $value = 0;
        }
        else {
            return _array_section($value, $input, $actual_context, $inverse, @children);
        }
    }

    # If inverted section and false => show
    # If normal section and true => show
    # Otherwise do not show
    return () unless ($value xor $inverse);

    @children = _interpolate_variables($input, $ra_context, @children);
    @children = grep { defined } @children;

    return @children;
};

sub _interpolate_variables {
    my $input = shift;
    my $ra_context = shift;
    my @children = @_;

    return map {
        if ( ref $_ eq 'HASH' && $_->{type} eq 'variable' ) {
            my $value = _find_key($input, @$ra_context, $_->{value});

            $value = $value->() if ref $value eq 'CODE';

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

    return "sub {
        my (\$c, \$s) = \@_;

        my \@elements = $output;

        \@elements = map {
            s/^\\n//;
            s/\\n\$//;

            \$_;
        } \@elements;

        return join '', \@elements;
    }";
}

sub _parse_tree {
    my $self = shift;
    my $ra_tree = shift;
    my $context = shift // '';
    my $inverse = shift // 0;

    $ra_tree = $self->_flatten_trees($ra_tree);
    $ra_tree = $self->_insert_variables($ra_tree);
    $ra_tree = $self->_parse_children($ra_tree, $context);

    return "\$s->(\$c, [ $context ], $inverse, " . join(', ', @$ra_tree) . ")";
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

            $self->_parse_tree($_->{tree}, $context_string, $_->{inverse});
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

    mustache ::= interpolate_node | string_node

    interpolate_node ::= interpolate
                      | interpolate string_node
                      | interpolate interpolate_node

    interpolate ::= '{{' word '}}'                              action => do_interpolate_escaped
                  | '{{{' word '}}}'                            action => do_interpolate
                  | '{{&' word '}}'                             action => do_interpolate
                  | '{{-' word '}}'                             action => do_literal
                  | '{{#' word '}}' mustache '{{/' word '}}'    action => do_section
                  | '{{^' word '}}' mustache '{{/' word '}}'    action => do_inverse_section

    word ~ maybe_whitespace just_word maybe_whitespace

    just_word ~ [-\w.]+

    maybe_whitespace ~ whitespace*

    whitespace ~ [\s]+

    string_node ::= string
                  | string interpolate_node

    string ::= lstring+

    lstring ::= not_curly_brace     action => do_string
            | '{'                   action => do_string
            | '}'                   action => do_string

    not_curly_brace ~ [^{}]+

    :discard ~ comment
    comment ~ maybe_newline '{{!' anything '}}' maybe_newline

    maybe_newline ~ newline*

    newline ~ [\n]+

    anything ~ [\d\D]+

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

        $string =~ s/'/\\'/g;

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

    sub do_inverse_section {
        my (undef, undef, $context, undef, $ra_tree) = @_;

        $context = do_section(undef, undef, $context, undef, $ra_tree);
        $context->{inverse} = 1;

        return $context;
    }

    sub do_section {
        my (undef, undef, $context, undef, $ra_tree) = @_;

        $context = '_self' if $context eq '.';

        my ($first, @rest) = split /\./, $context;

        if ( @rest ) {
            $ra_tree = [ [ do_section(undef, undef, join('.', @rest), undef, $ra_tree) ] ];
        }

        return {
            type    => 'context',
            value   => trim($first),
            tree    => $ra_tree,
            inverse => 0,
        };
    }

    sub do_literal {
        my (undef, undef, $variable, undef) = @_;

        return "'{{$variable}}'";
    }
}

1;