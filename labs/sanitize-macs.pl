#!/usr/bin/env perl
# Replace every real unicast MAC in host-capture output with a stable fake
# (02:00:00:00:00:NN, locally-administered), in both "aa:bb:.." and hex-dump
# "aa bb .." forms. Broadcast/multicast MACs are kept — they are protocol
# constants, not identities. Reads stdin, writes stdout.
use strict; use warnings;
my @lines = <STDIN>;
my $text = join '', @lines;
my (%map, $n);
my $hx = qr/[0-9a-f]{2}/i;
for my $mac ($text =~ /\b($hx(?::$hx){5})\b/g) {
  my $m = lc $mac;
  next if exists $map{$m};
  my $first = hex substr($m, 0, 2);
  next if $first & 1;                     # multicast/broadcast bit set
  $map{$m} = sprintf '02:00:00:00:00:%02x', ++$n;
}
for my $real (keys %map) {
  my $fake = $map{$real};
  (my $real_hex = $real) =~ s/:/ /g;
  (my $fake_hex = $fake) =~ s/:/ /g;
  $text =~ s/\Q$real\E/$fake/gi;
  $text =~ s/\Q$real_hex\E/$fake_hex/gi;
  # Vendor-resolved form, e.g. "GigaByteTech_b0:1a:67"
  my $tail = substr($real, 9);
  $text =~ s/\b\w+_\Q$tail\E\b/$fake/gi;
}
# Hex-dump ASCII column still spells the original bytes: rebuild it from hex.
$text =~ s{^([0-9a-f]{4}  )((?:[0-9a-f]{2} ){1,16})(\s*)(.*)$}{
  my ($off, $hex, $pad) = ($1, $2, $3);
  my $ascii = join '', map { my $c = hex; ($c >= 32 && $c < 127) ? chr $c : '.' } split ' ', $hex;
  "$off$hex$pad$ascii"
}gme;
print $text;
