#!/usr/bin/perl
# get-pdf-text.pl — текстовый слой из PDF без pdftotext и других программ.
#
# Перенос Get-PdfText.ps1 на Perl (нужны только модули из состава Perl: Compress::Zlib, Encode).
# Разбирает FlateDecode-потоки и достаёт операнды текстовых операторов Tj / TJ.
# Дореформенный текст со сканов РГБ читается через приём «latin-1 → cp1251»: строку, пришедшую
# как latin-1, перекодируют в cp1251 и берут тот вариант, где больше кириллицы.
#
# Дополнения к исходному скрипту:
#   * восьмеричные экранирования \344 внутри строк PDF;
#   * разбор таблиц /ToUnicode (beginbfchar / beginbfrange): современные делопроизводственные PDF
#     (письма ведомств, сохранённые из Word с подмножествами шрифтов) хранят текст в шестнадцатеричных
#     строках <0246><0242>… — без таблицы получаются одни цифры и латиница. Таблица собирается одна на
#     весь файл, поэтому у документов с несколькими шрифтами возможны ошибки; если ToUnicode в файле
#     нет, кириллицу не восстановить — читайте глазами.
#
# Как заранее понять, есть ли текстовый слой: посчитать в сыром файле /Font и /ToUnicode.
# Если /ObjStm > 0, по сырым байтам судить нельзя (шрифты спрятаны в объектных потоках).
# DjVu этим скриптом не читается.
#
# Запуск:
#   perl get-pdf-text.pl файл.pdf
#   perl get-pdf-text.pl файл.pdf --match 'іог|Патанджали'
#   perl get-pdf-text.pl файл.pdf --out текст.txt --max-streams 500
#
# Ключи: --match RE (отбор потоков), --max-streams N (0 — все), --out файл, --info (только оценка слоя)

use strict;
use warnings;
use utf8;
use Encode qw(decode);
use Compress::Zlib;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

my @args = map { decode('UTF-8', $_) } @ARGV;
my ($path, $match, $max, $outfile, $info) = (undef, undef, 0, undef, 0);
while (@args) {
  my $a = shift @args;
  if    ($a eq '--match')       { $match = shift @args; }
  elsif ($a eq '--max-streams') { $max = shift @args; }
  elsif ($a eq '--out')         { $outfile = shift @args; }
  elsif ($a eq '--info')        { $info = 1; }
  else                          { $path = $a; }
}
die "Использование: perl get-pdf-text.pl файл.pdf [--match RE] [--out файл] [--info]\n" unless defined $path;
my $fpath = Encode::encode('UTF-8', $path);
open(my $fh, '<:raw', $fpath) or die "не читается: $path\n";
my $s = do { local $/; <$fh> };
close $fh;

if ($info) {
  my $fonts = () = $s =~ m{/Font}g; my $tou = () = $s =~ m{/ToUnicode}g; my $obj = () = $s =~ m{/ObjStm}g;
  print "/Font: $fonts, /ToUnicode: $tou, /ObjStm: $obj\n";
  print "Есть признаки текстового слоя.\n" if $fonts && !$obj;
  print "/ObjStm > 0: по сырым байтам судить нельзя, запустите без --info.\n" if $obj;
  exit 0;
}

sub inflate_zlib {
  my ($data) = @_;
  my $i = inflateInit() or return undef;
  my ($out, $st) = $i->inflate($data);
  return undef unless defined $out && ($st == Z_OK || $st == Z_STREAM_END);
  return $out;
}

# ---- 1. распаковать все потоки (нужны и CMap, и текст) ----
my (@streams, $idx);
$idx = 0;
while (1) {
  my $p = index($s, 'stream', $idx);
  last if $p < 0;
  my $start = $p + 6;
  $start++ if substr($s, $start, 1) eq "\r";
  $start++ if substr($s, $start, 1) eq "\n";
  my $end = index($s, 'endstream', $start);
  last if $end < 0;
  $idx = $end + 9;
  my $len = $end - $start;
  next if $len <= 0;
  my $plain = inflate_zlib(substr($s, $start, $len));
  push @streams, defined $plain ? $plain : undef;
}

# ---- 2. таблица /ToUnicode ----
my %cmap;
sub hex_to_text { my ($h) = @_; return decode('UTF-16BE', pack('H*', $h)); }
for my $t (grep { defined } @streams) {
  next unless $t =~ /beginbf(?:char|range)/;
  while ($t =~ /beginbfchar(.*?)endbfchar/gs) {
    my $sec = $1;
    while ($sec =~ /<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/g) { $cmap{ uc $1 } = hex_to_text($2); }
  }
  while ($t =~ /beginbfrange(.*?)endbfrange/gs) {
    my $sec = $1;
    while ($sec =~ /<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(<([0-9A-Fa-f]+)>|\[(.*?)\])/gs) {
      my ($lo, $hi, $dst, $one, $arr) = (hex($1), hex($2), $3, $4, $5);
      my $w = length $1;
      if (defined $one) {
        my $base = hex($one); my $blen = length $one;
        for my $c ($lo .. $hi) { $cmap{ sprintf("%0${w}X", $c) } = hex_to_text(sprintf("%0${blen}X", $base + $c - $lo)); }
      } else {
        my @d = $arr =~ /<([0-9A-Fa-f]+)>/g;
        for my $k (0 .. $#d) { last if $lo + $k > $hi; $cmap{ sprintf("%0${w}X", $lo + $k) } = hex_to_text($d[$k]); }
      }
    }
  }
}

sub decode_hex_string {
  my ($h) = @_;
  $h = uc $h; $h .= '0' if length($h) % 2;
  my $w = (grep { length($_) == 4 } keys %cmap) ? 4 : 2;
  my $out = '';
  for (my $i = 0; $i + $w <= length $h; $i += $w) { my $c = substr($h, $i, $w); $out .= exists $cmap{$c} ? $cmap{$c} : ''; }
  return $out;
}

# ---- 3. текст из потоков ----
sub unescape_pdf_string {
  my ($v) = @_;
  $v =~ s/\\([0-7]{1,3})/chr(oct($1))/ge;
  $v =~ s/\\n/ /g; $v =~ s/\\r/ /g;
  $v =~ s/\\([()\\])/$1/g;
  return $v;
}
sub cyr_count { my ($t) = @_; return scalar(() = $t =~ /[\x{0400}-\x{04FF}]/g); }

my @out; my $n = 0;
for my $k (0 .. $#streams) {
  my $t = $streams[$k];
  next unless defined $t && $t =~ /(?:Tj|TJ)/;
  $n++;
  last if $max > 0 && $n > $max;

  my ($bytes_piece, $uni_piece) = ('', '');
  while ($t =~ /(\[[^\]]*\]\s*TJ|(?:\((?:\\.|[^\\()])*\)|<[0-9A-Fa-f]+>)\s*Tj)/gs) {
    my $op = $1;
    while ($op =~ /(\((?:\\.|[^\\()])*\))|<([0-9A-Fa-f]+)>/g) {
      if (defined $1) { my $v = substr($1, 1, length($1) - 2); $bytes_piece .= unescape_pdf_string($v); }
      elsif (%cmap)   { $uni_piece .= decode_hex_string($2); }
    }
  }
  # OCR русских сканов обычно cp1251, пришедший как latin-1
  my $best = $bytes_piece;
  if (length $bytes_piece) {
    my $as_1251 = decode('cp1251', $bytes_piece);
    my $as_l1   = decode('latin1', $bytes_piece);
    $best = cyr_count($as_1251) > cyr_count($as_l1) ? $as_1251 : $as_l1;
  }
  $best .= ' ' . $uni_piece if length $uni_piece;
  $best =~ s/\s+/ /g; $best =~ s/^\s+|\s+$//g;
  next unless length $best;
  next if defined $match && $best !~ /$match/i;
  push @out, { stream => $k + 1, text => $best };
}

my $fh_out;
if ($outfile) { open($fh_out, '>:encoding(UTF-8)', Encode::encode('UTF-8', $outfile)) or die "не пишется $outfile\n"; }
for my $r (@out) {
  my $line = "[поток $r->{stream}, " . length($r->{text}) . " знаков] $r->{text}\n";
  if ($fh_out) { print $fh_out $line } else { print $line }
}
close $fh_out if $fh_out;
my $total = 0; $total += length $_->{text} for @out;
print STDERR "Потоков с текстом: " . scalar(@out) . ", знаков: $total" . (%cmap ? ", таблица ToUnicode: " . scalar(keys %cmap) . " символов" : '') . ($outfile ? ", записано в $outfile" : '') . "\n";
