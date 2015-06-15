use strict;
use warnings;

use Test::More tests => 2;

use MarpaX::Text::Caml;

use File::Basename ();
use File::Spec ();

# Had '@_' instead of 'ref $_[0] eq 'HASH' ? $_[0] : {@_}' in render_file.
# Without this test no tests actually caught that bug.
{
    my $renderer = MarpaX::Text::Caml->new;

    my $templates_path = File::Spec->catfile(
        File::Basename::dirname(__FILE__), 'templates'
    );

    my $output = $renderer->render_file(
        File::Spec->catfile($templates_path, 'partial-with-directives'),
        name => "Alex",
    );

    is(
        $output,
        'Hello Alex!',
        'handle non-hashref context in render_file()'
    );
}

{
    my $renderer = MarpaX::Text::Caml->new;

    my $output = $renderer->render('a {{name}}: {', { name => 'mustache' });
    is $output => 'a mustache: {', 'renders single curly braces';
}
