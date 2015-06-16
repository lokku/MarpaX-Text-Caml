use strict;
use warnings;

use feature qw(say);

use Test::More;

use MarpaX::Text::Caml;

require Scalar::Util;
use Data::Dumper;

my $input = {
    results => {
        listings => [
            {
                has_price   => 1,
                price       => {
                    currency    => '£',
                    amount      => '295,000'
                },
            },
            {
                has_price       => 0,
                price           => undef,
                has_keywords    => 1,
                keywords        => [
                    {
                        name        => 'bathroom',
                        nicename    => 'Bathroom',
                    },
                ],
            },
        ],
    },
};

is_deeply(
    MarpaX::Text::Caml::_resolve_context($input, [], [qw(results listings has_price)])->(1),
    [qw(results listings 1 has_price)],
    'sections in arrays are resolved to a sub that returns the section context with index'
);

is_deeply(
    MarpaX::Text::Caml::_resolve_context($input, [], [qw(results listings has_price price)])->(0),
    [qw(results listings 0 price)],
    'sections in arrays are resolved to a sub that returns the section context with index'
);

is_deeply(
    MarpaX::Text::Caml::_resolve_context($input, [], [qw(results listings)])->(1),
    [qw(results listings 1)],
    'arrays resolve to a sub that returns the context for that index'
);

is_deeply(
    MarpaX::Text::Caml::_resolve_context($input, [], [qw(results listings has_keywords keywords)])->(1)->(0),
    [qw(results listings 1 keywords 0)],
    'array within array resolves to nested subs that return the context for the indices'
);

done_testing;