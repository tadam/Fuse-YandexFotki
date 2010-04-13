package Fuse::YandexFotki::AtompubClient;

use strict;
use warnings;

our $VERSION = 0.0.3;

=head1 NAME

Fuse::YandexFotki::AtompubClient - Atompub client that makes auth on Yandex Fotki service

=head1 SYNOPSIS

    use Fuse::YandexFotki::AtompubClient;
    my $client = Fuse::YandexFotki::AtompubClient->new(
        auth_rsa_url     => 'http://auth.mobile.yandex.ru/yamrsa/key/',
        auth_token_url   => http://auth.mobile.yandex.ru/yamrsa/token/',
        auth_token_realm => 'fotki.yandex.ru',
        # and also Atompub::Client specific arguments
    );
    $client->username('some_username');
    $client->password('some_password');
    # ...
    # use here this module as original Atompub::Client when
    # you need to interact with Yandex Fotki service
    # ...

=head1 DESCRIPTION

This class override method C<munge_request> of Atompub::Client for making authorization on Yandex Fotki. In the rest it works exactly as original Atompub::Client.

=cut

use base qw(Atompub::Client);

use Atompub::MediaType qw(media_type);
use Carp qw(croak);
use HTTP::Request::Common;
use LWP::UserAgent;
use Math::BigInt;
use MIME::Base64 qw(encode_base64);
use XML::LibXML qw();

=head1 METHODS

=over 4

=item new

Makes new instance of Fuse::YandexFotki::AtompubClient. It takes additionally two mandatory params: C<auth_rsa_url> and C<auth_token_rsa_url>.
First is an url where module takes RSA key for encrypting, second is an url that checks encryped by this RSA key credentials and gives a token that confirms your authorization.

=cut

sub new {
    my $class = shift;
    my %params = @_;

    # cleaning additional params
    # just good tone of programming
    my $auth_rsa_url = delete $params{auth_rsa_url};
    croak("auth_rsa_url is not specified") unless defined($auth_rsa_url);
    my $auth_token_url = delete $params{auth_token_url};
    croak("auth_token_url is not specified") unless defined($auth_token_url);
    my $auth_token_realm = delete $params{auth_token_realm};
    $auth_token_realm = '' unless defined($auth_token_realm);

    my $self = $class->SUPER::new(%params);
    $self->{auth_rsa_url} = $auth_rsa_url;
    $self->{auth_token_url} = $auth_token_url;
    $self->{auth_tonen_realm} = $auth_token_realm;
    $self->{auth_libxml} = XML::LibXML->new;

    return $self;
}

=item auth

Makes requests to auth urls and sets token.
Returns true or false depending on auth success.
Detailed description of unsuccessful authorization you can get using C<auth_error>.

=cut

# TODO: - make more clean code,
#       - extract <error> from response
sub auth {
    my $self = shift;

    my $username = defined($self->username) ? $self->username : '';
    my $password = defined($self->password) ? $self->password : '';
    my $cred_str = qq!<credentials login="$username" password="$password"/>!;

    # getting request_id and rsa_key
    my $resp = $self->ua->get($self->{auth_rsa_url});
    unless ($resp->is_success) {
        $self->auth_error("Getting RSA key from $self->{auth_rsa_url} " .
                           "returned error code " . $resp->code .
                           " with message [" .
                           (defined($resp->content) ? $resp->content : "") . "]");
        return;
    }
    my $xml = eval { $self->{auth_libxml}->load_xml(string => $resp->content) };
    if ($@) {
        $self->auth_error("Couldn't parse XML from $self->{auth_rsa_url}: $@");
        return 0;
    }

    my $key = $xml->findnodes("/response/key")->string_value;
    my $request_id = $xml->findnodes("/response/request_id")->string_value;
    if (!defined($key) || !defined($request_id)) {
        $self->auth_error("Couldn't find <key> or <request_id> from $self->{auth_rsa_url} response. " .
                          "Response was:\n" . $resp->content);
        return;
    }

    # creating credentials_rsa
    my $cred_rsa = $self->encrypt_rsa($cred_str, $key);
    unless (defined($cred_rsa)) {
        $self->auth_error("Can't create encrypt_rsa with key $key\n");
        return 0;
    }

    # getting token
    my $token_resp = $self->ua->request(
        POST $self->{auth_token_url},
            [ request_id  => $request_id,
              credentials => $cred_rsa ]
    );
    unless ($token_resp->is_success) {
        $self->auth_error("Getting token from $self->{auth_token_url} " .
                          "returned error code " . $token_resp->code .
                          " with message [" .
                          (defined($token_resp->content) ? $token_resp->content : "") . "]");
        return 0;
    }

    my $token_xml = eval { $self->{auth_libxml}->load_xml(string => $token_resp->content) };
    if ($@) {
        $self->auth_error("Couldn't parse XML from $self->{auth_token_url}: $@");
        return 0;
    }
    my $token = $token_xml->findnodes("/response/token")->string_value;
    unless (defined($token)) {
        $self->auth_error("Couldn't find <token> or <request_id> from $self->{auth_token_url} response. " .
                          "Response was:\n" . $resp->content);
        return 0;
    }

    # and finally setting token
    $self->token($token);

    return 1;
}

=item encrypt_rsa($content, $rsa_key)

It is internal function for encrypting credentials.
You can use is it (or you can just copy-paste this code) in your projects when you need Yandex Fotki specific encrypt function.

It takes two params: C<$content> for encryption and C<$rsa_key> for this encryption.

Returns encryped key.

=cut

# AAAAA!
sub encrypt_rsa {
    my ($self, $content, $key) = @_;

    if ($key !~ /#/) {
        warn "key [$key] doesn't contains '#' separator";
        return;
    }
    my ($begin_key, $end_key) = split('#', $key);
    my @data_arr = map {ord($_)} split('', $content);
    my $n = Math::BigInt->new("0x" . $begin_key);
    my $e = Math::BigInt->from_hex("0x" . $end_key);
    my $step_size = (length($begin_key))/2 -1;

    my @prev_crypted = (0) x $step_size;

    my $hex_out = "";

    for my $i (0 .. (scalar(@data_arr) - 1)/$step_size) {
        my $end_tmp_range = ($i+1) * $step_size - 1;
        $end_tmp_range = scalar(@data_arr) - 1 if ($end_tmp_range > scalar(@data_arr) - 1);
        my @tmp = @data_arr[$i*$step_size .. $end_tmp_range];
        @tmp = map {$tmp[$_] ^ $prev_crypted[$i]} (0 .. scalar(@tmp)-1);
        @tmp = reverse @tmp;

        my $plain = Math::BigInt->new(0);
        for my $x (0 .. scalar(@tmp)-1) {
            $plain += $tmp[$x] * ((Math::BigInt->new(256)**$x) % $n);
        }

        my $hex_result = $plain->copy;
        $hex_result = $hex_result->bmodpow($e, $n)->as_hex;
        $hex_result =~ s/^0x//;
        $hex_result = ('0' x (length($begin_key) - length($hex_result))) . $hex_result;

        my $min = (length($hex_result) < (scalar(@prev_crypted) * 2)) ?
                   length($hex_result) :
                   scalar(@prev_crypted) * 2;
        for (my $x = 0; $x < $min; $x += 2) {
            $prev_crypted[$x/2] = hex(substr($hex_result, $x, 2));
        }
        $hex_out .= (scalar(@tmp) < 16 ? "0" : "") .
                    sprintf('%x', scalar(@tmp)) . "00"; # current size (WTF exactly?)
        my $ks = length($begin_key) / 2;
        $hex_out .= ($ks < 16 ? "0" : "") . sprintf('%x', $ks) . "00"; # key size
        $hex_out .= $hex_result;
    }
    my $out = "";
    for (my $i = 0; $i < length($hex_out); $i += 2) {
        $out .= chr(hex(substr($hex_out, $i, 2)));
    }
    my $rsa = encode_base64($out, '');
    print "content $content, key $key, rsa $rsa\n";

    return $rsa;
}


=item munge_request($req)

It is a developer function from Atompub::Client. I hope that internal API of Atompub::Client will not change in the future.
This method gets an HTTP::Request C<$req> and adds proper C<Authorization> header with value of C<token> for interacting with Yandex Fotki service.
If C<username> exists and C<token> doesn't exists it tries one time to make C<auth> call.

=cut

sub munge_request {
    my($self, $req) = @_;

    $req->accept(join(',',
                      media_type('entry')->without_parameters,
                      media_type('service'), media_type('categories'),
                      '*/*',
                  ));

    # no auth if no username specified
    return unless (defined($self->username));

    # there was a bad attempt to make auth in past
    return if ($self->{auth_dealed} && !defined($self->token));

    # attempt to get token
    unless ($self->{token}) {
        $self->auth;
        $self->{auth_dealed} = 1;
    }

    # all attempts were bad
    return unless (defined($self->{token}));

    # add auth header
    $req->header('Authorization' => qq!FimpToken realm="fotki.yandex.ru", token="$self->{token}"!);

    return $req;
}

=item token([$token_value])

For your convenience here is getter/setter of token value. You can set this value if you getted token from another place.

=cut

sub token {
    my $self = shift;
    $self->{token} = shift if @_;
    return $self->{token};
}

=item auth_error

Returns description of the last error of C<auth> call.

=back

=cut

sub auth_error {
    my $self = shift;
    $self->{auth_error} = shift if @_;
    return $self->{auth_error};
}

=head1 AUTHORS

Yury Zavarin C<yury.zavarin@gmail.com>.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

L<Atompub::Client>
L<http://api.yandex.ru/fotki/doc/overview/authorization.xml>

=cut

1;
