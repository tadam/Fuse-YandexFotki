package Yandex::Fotki::XMLClient;

use strict;
use warnings;

use base qw(Atompub::Client);

sub munge_request {
}

sub auth {
}

# 0 - name of script
# 1 - $key
# 2 - $content
sub encrypt_rsa {
    use bigint;

    my ($content, $key) = @_;
    my ($begin_key, $end_key) = split('#', $key);
    my @data_arr = map {ord($_)} split('', $content);
    my ($n, $e, $step_size) = (hex($begin_key), hex($end_key), length($begin_key)/2 - 1);

    my @prev_crypted = (0 x $step_size);

    my $hex_out = "";

    for my $i (0 .. (scalar(@data_arr) - 1)/$step_size + 1) {
        my @tmp = @data_arr[$i*$step_size:($i+1)*$step_size];
        @tmp = map {$tmp[$_] ^ $prev_crypted[$i]} (0..scalar(@tmp));
        @tmp = reverse @tmp;
        my $plain = 0;
        for my $x (0..scalar(@tmp)) {
            $plain += $tmp[$x] * ((256**$x) % $n);
        }
        $hex_rusult = sprintf('%x', ($plain ** $e) % $n);
        $hex_result .= 
    }
}

#-*- coding:utf-8 -*-

import sys, copy

  NSTR,ESTR = sys.argv[1].split("#")
  DATA_ARR = [ord(x) for x in sys.argv[2]]
  N,E,STEP_SIZE = int(NSTR,16),int(ESTR,16), len(NSTR)/2-1
  
  prev_crypted = [0]*STEP_SIZE
  
  hex_out = ""
  for i in range(0,(len(DATA_ARR)-1)/STEP_SIZE+1):
    tmp = DATA_ARR[i*STEP_SIZE:(i+1)*STEP_SIZE]
    tmp = [tmp[i] ^ prev_crypted[i] for i in range(0,len(tmp))]
    tmp.reverse()
    plain = 0
    for x in range(0,len(tmp)): plain+= tmp[x]*pow(256, x, N)
    hex_result = "%x" % pow(plain,E,N)
    hex_result = "".join(['0']*( len(NSTR)- len(hex_result))) + hex_result

    for x in range(0,min(len(hex_result),len(prev_crypted)*2),2):
      prev_crypted[x/2] = int(hex_result[x:x+2],16)
      
    hex_out += ("0" if len(tmp) < 16 else "") + ("%x" % len(tmp)) + "00" # current size
    ks = len(NSTR)/2
    hex_out += ("0" if ks < 16 else "") + ("%x" % ks) + "00" # key size
    hex_out += hex_result

  print hex_out.decode("hex").encode("base64").replace("\n","")

1;
