package t::utils;

use strict;
use warnings;

use base qw(Exporter);
our @EXPORT = qw(get_response);

sub get_response {
    my $name = shift;
    my $fname = "t/data/$name";
    my $resp = do($fname);
    return $resp;
}

1;
