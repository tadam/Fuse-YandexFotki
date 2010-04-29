#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Mock::LWP::Dispatch;

use t::utils;

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



my $key_req;
my $key_map_index = $mock_ua->map(qr/key/,
    sub {
        my $r = shift;
        $key_req = $r;
        get_response('client_key_ok')
    }
);

my $token_req;
my $token_map_index = $mock_ua->map(qr/token/,
    sub {
        my $r = shift;
        $token_req = $r;
        return get_response('client_token_ok');
    }
);
my $params = {
    'auth_rsa_url'     => 'http://auth.mobile.yandex.ru/yamrsa/key/',
    'auth_token_url'   => 'http://auth.mobile.yandex.ru/yamrsa/token/',
    'auth_token_realm' => 'fotki.yandex.ru',
};

# checking auth and munge_request in good case
{
    my $client = new_client();

    $client->auth;

    is($key_req->method, 'GET', 'key request method is GET');
    is($key_req->uri, $params->{auth_rsa_url}, 'key request goes to auth_rsa_url');
    is($key_req->content, '', 'key request contains empty content');

    is($token_req->method, 'POST', 'request method for getting token is POST');
    is($token_req->uri, $params->{auth_token_url}, 'token request goes to auth_token_url');
    is($token_req->content, 'request_id=12345&credentials=MwBAAIxyYDzjzbk1gJE%2BH2J2XHrFVMC67c3MC202TRmryzOE36n9fRSOl48lM7bTQnaKMGIMqyFcFcFY20ieq9gB7Gk%3D', 'right content for auth_token_url');

    is($client->token, 'e78cf1a0ebbb19', 'token setted');

    ok(!defined($client->auth_error), 'no error on good auth');

    my $munge_req = HTTP::Request->new('GET', 'http://api-fotki.yandex.ru/api/users/fusetest');
    $client->munge_request($munge_req);
    is($munge_req->header('Accept'),
       'application/atom+xml,application/atomsvc+xml,application/atomcat+xml,*/*',
       'munge_request adds proper accept headers');
    is($munge_req->header('Authorization'),
       'FimpToken realm="fotki.yandex.ru", token="e78cf1a0ebbb19"',
       'munge_request adds proper Authorization header');
}

# unsuccessful try to get token
{
    $mock_ua->unmap($token_map_index);
    $mock_ua->map(qr/token/, get_response('client_token_bad'));
    my $client = new_client();

    $client->auth;
    ok(!defined($client->token), 'token not defined on bad auth');
    like($client->auth_error, qr/some error occured/, 'check auth_error');

    my $munge_req = HTTP::Request->new('GET', 'http://api-fotki.yandex.ru/api/users/fusetest');
    $client->munge_request($munge_req);
    is($munge_req->header('Accept'),
       'application/atom+xml,application/atomsvc+xml,application/atomcat+xml,*/*',
       'munge_request adds proper accept headers');
    ok(!defined($munge_req->header('Authorization')),
       "no Authorization header if we haven't token");
}

# setting token
{
    my $client = new_client();

    $client->token('abc');
    is($client->token, 'abc', 'setting token');
}

done_testing;

sub new_client {
    my $client = $p->new(%{$params});

    $client->username('fusetest');
    $client->password('asdffdsa');

    return $client;
}
