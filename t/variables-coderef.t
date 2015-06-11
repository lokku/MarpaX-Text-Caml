use strict;
use warnings;

use Test::More tests => 1;

use MarpaX::Text::Caml;

my $renderer = MarpaX::Text::Caml->new;

my $output = $renderer->render(
    '{{foo}}',
    {   foo => sub {'bar'}
    }
);
is $output => 'bar', 'sub returning "bar" renders as "bar"';
