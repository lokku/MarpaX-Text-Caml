use strict;
use warnings;

use Test::More tests => 5;

use MarpaX::Text::Caml;

use File::Basename ();
use File::Spec ();

my $renderer = MarpaX::Text::Caml->new;
my $templates_path = File::Spec->catfile(
    File::Basename::dirname(__FILE__), 'templates'
);
my $output;

# Had '@_' instead of 'ref $_[0] eq 'HASH' ? $_[0] : {@_}' in render_file.
# Without this test no tests actually caught that bug.
$output = $renderer->render_file(
    File::Spec->catfile($templates_path, 'partial-with-directives'),
    name => "Alex",
);
is $output => 'Hello Alex!', 'handle non-hashref context in render_file()';

# { and } were not being accepted as lexemes because strings excluded them in
# order to avoid having mustaches match as strings.
$output = $renderer->render('a {{name}}: {', { name => 'mustache' });
is $output => 'a mustache: {', 'renders single curly braces';

$output = $renderer->render('a {{direction}} {{name}}: }', { name => 'mustache', direction => 'backwards' });
is $output => 'a backwards mustache: }', 'renders single curly braces';

my $template = <<'EOF';
{{#results}}
    {{^has_error}}
        {{#listings}}
            {{#has_price}}
                {{#price}}{{currency}}{{amount}}{{/price}}
            {{/has_price}}
            {{^has_price}}
                {{#price}}
                    {{#visible}}
                        {{display}}
                    {{/visible}}
                {{/price}}
            {{/has_price}}

            {{#has_keywords}}
                {{#keywords}}
                    {{nicename}}
                {{/keywords}}
            {{/has_keywords}}

            A {{type}} in {{location}}
        {{/listings}}
    {{/has_error}}
{{/results}}
EOF

my $rh_data = {
    results => {
        has_error => 0,
        listings  => [
            {
                type        => 'House',
                location    => 'London',
                has_price   => 0,
                price => {
                    display => 'POA',
                    visible => 1,
                },
                has_keywords => 1,
                keywords => [
                    {
                        nicename => 'Pizza oven',
                    },
                    {
                        nicename => 'Tandoor',
                    },
                ],
            },
            {
                type        => 'Flat',
                location    => 'New York',
                has_price   => 1,
                price       => {
                    currency    => '$',
                    amount      => '295,000',
                }
            },
        ],
    },
};

is_deeply(
    MarpaX::Text::Caml::_resolve_context($rh_data, [], [qw(results has_error listings has_price price visible)])->(0),
    [qw(results listings 0 price visible)],
    'finds the correct context in nasty nested stuff'
);

is_deeply(
    MarpaX::Text::Caml::_resolve_context($rh_data, [], [qw(results has_error listings has_keywords keywords)])->(0)->(1),
    [qw(results listings 0 keywords 1)],
    'finds the correct context in nasty nested stuff'
);

$output = $renderer->render($template, $rh_data);
$output =~ s/\s+/ /g;
is $output => ' POA Pizza oven Tandoor A House in London $295,000 A Flat in New York ', 'array inside negative section';