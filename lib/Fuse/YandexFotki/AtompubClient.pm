package Fuse::YandexFotki::AtompubClient;

use strict;
use warnings;

use base qw(Atompub::Client);

use Atompub::MediaType qw(media_type);
use HTTP::Request::Common;
use LWP::UserAgent;
use Math::BigInt;
use MIME::Base64 qw(encode_base64);
use XML::LibXML qw();

sub new {
    my $class = shift;
    my %params = @_;

    my $self = $class->SUPER::new(%params);
    $self->{auth_ua} = LWP::UserAgent->new(agent => "Yandex-Fotki-Fuse/0.0.1",
                                           timeout => 5);
    $self->{auth_rsa_url} = $params{auth_rsa_url};
    $self->{auth_token_url} = $params{auth_token_url};
    $self->{auth_libxml} = XML::LibXML->new;

    return $self;
}

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
    return if ($self->{auth_dealed} && !defined($self->{token}));

    # attempt to get token
    unless ($self->{token}) {
        $self->auth;
    }

    # all attempts were bad
    return unless (defined($self->{token}));

    # send auth header
    $req->header('Authorization' => qq!FimpToken realm="fotki.yandex.ru", token="$self->{token}"!);
}

# AAAAA!
sub encrypt_rsa {
    my ($self, $content, $key) = @_;

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
}

# TODO: - make more clean code,
#       - extract <error> from response
sub auth {
    my $self = shift;

    my $username = defined($self->username) ? $self->username : '';
    my $password = defined($self->password) ? $self->password : '';
    my $cred_str = qq!<credentials login="$username" password="$password"/>!;

    # getting request_id and rsa_key
    my $resp = $self->{auth_ua}->get($self->{auth_rsa_url});
    unless ($resp->is_success) {
        $self->{auth_error} = "Getting RSA key from $self->{auth_rsa_url} " .
                              "returned error code " . $resp->code .
                              " with message [" . (defined($resp->content) ? $resp->content : "") . "]";
        return;
    }
    my $xml = eval { $self->{auth_libxml}->load_xml(string => $resp->content) };
    if ($@) {
        $self->{auth_error} = "Couldn't parse XML from $self->{auth_rsa_url}: $@";
        return;
    }

    my $key = $xml->findnodes("/response/key")->string_value;
    my $request_id = $xml->findnodes("/response/request_id")->string_value;
    if (!defined($key) || !defined($request_id)) {
        $self->{auth_error} = "Couldn't find <key> or <request_id> from $self->{auth_rsa_url} response. " .
                              "Response was:\n" . $resp->content;
        return;
    }

    # creating credentials_rsa
    my $cred_rsa = $self->encrypt_rsa($cred_str, $key);
    unless (defined($cred_rsa)) {
        $self->{auth_error} = "Can't create encrypt_rsa with key $key\n";
        return;
    }

    # getting token
    my $token_resp = $self->{auth_ua}->request(
        POST $self->{auth_token_url},
            [ request_id  => $request_id,
              credentials => $cred_rsa ]
    );
    unless ($token_resp->is_success) {
        $self->{auth_error} = "Getting token from $self->{auth_token_url} " .
                              "returned error code " . $token_resp->code .
                              " with message [" . (defined($token_resp->content) ? $token_resp->content : "") . "]";
        return;
    }

    my $token_xml = eval { $self->{auth_libxml}->load_xml(string => $token_resp->content) };
    if ($@) {
        $self->{auth_error} = "Couldn't parse XML from $self->{auth_token_url}: $@";
        return;
    }
    my $token = $token_xml->findnodes("/response/token")->string_value;
    unless (defined($token)) {
        $self->{auth_error} = "Couldn't find <token> or <request_id> from $self->{auth_token_url} response. " .
                              "Response was:\n" . $resp->content;
        return;
    }

    # setting token
    $self->{token} = $token;

    return;
}

1;
