#!/usr/bin/perl
# Собирает маленький PDF для проверки get-pdf-text.pl: поток 1 — текст cp1251 в круглых скобках,
# поток 2 — таблица /ToUnicode и текст в шестнадцатеричных строках.
use strict; use warnings; use utf8;
use Compress::Zlib; use Encode qw(encode);
my ($out) = @ARGV;
my $t1 = "BT /F1 12 Tf (" . encode('cp1251', 'Йога и Ильин в Быкове') . ") Tj ET";
my $cmap = "/CIDInit begin begincmap 2 beginbfchar <0246> <0418> <0242> <043B> endbfchar 1 beginbfrange <0300> <0302> <0430> endbfrange endcmap";
my $t2 = "BT [<0246><0242><0300><0301>] TJ ET";
open my $fh, '>:raw', $out or die;
print $fh "%PDF-1.4\n";
for my $x ($t1, $cmap, $t2) { my $z = compress($x); print $fh "1 0 obj << /Filter /FlateDecode >>\nstream\n$z\nendstream\nendobj\n"; }
print $fh "%%EOF\n"; close $fh;
