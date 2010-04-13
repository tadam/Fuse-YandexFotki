#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 7;
use Test::Exception;

my $p = "Fuse::YandexFotki::AtompubClient"; # p means "package"
use_ok($p);

# pass args in new() (4)
{
    dies_ok(sub { $p->new }, 'creating client without params');
    dies_ok(sub { $p->new(auth_rsa_url => 'http://a.ru') },
            'creating client without auth_token_url');
    dies_ok(sub { $p->new('auth_token_url' => 'http://b.ru') },
            'creating client without auth_token_url');
    lives_ok(sub { my $client = $p->new(
                       auth_rsa_url => 'http://a.ru',
                       auth_token_url => 'http://b.ru'
                   );
             },
             'creating client with mandatory params');
}

# encrypt_rsa (2)
{
    my $cred_str = q{<credentials login="fusetest" password="asdffdsa"/>};
    my $key = "A61539CD696C288D87B8620ECB325017B519011ACE9E585D925C2E932BCE298DFEB012049F8BED3977DCD0F4BD3CF82833E30AB64F416207696B8A54A59FE8AF#10001";
    my $c = $p->new(auth_rsa_url => 'http://a.ru',
                    auth_token_url => 'http://b.ru');
    my $rsa = $c->encrypt_rsa($cred_str, $key);
    my $expected_rsa = "MwBAAIxyYDzjzbk1gJE+H2J2XHrFVMC67c3MC202TRmryzOE36n9fRSOl48lM7bTQnaKMGIMqyFcFcFY20ieq9gB7Gk=";
    is($rsa, $expected_rsa, "base encrypt_rsa test");

    my $bad_key = "ABC";
    is($c->encrypt_rsa($cred_str, $bad_key), undef,
       "encrypt_rsa with key that doesn't contain '#' separator");
}
