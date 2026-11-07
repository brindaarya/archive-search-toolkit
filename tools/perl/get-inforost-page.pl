#!/usr/bin/perl
# get-inforost-page.pl — выгрузка сканов страниц с сайтов на платформе «ИнфоРост»:
# elib.shpl.ru (ГПИБ) и docs.historyrussia.org.
#
# Перенос Get-InforostPage.ps1 на Perl.
# Просмотрщик отдаёт список страниц прямо в HTML узла: "pages":[{"id":1735914,...}].
# Идентификаторы идут подряд, поэтому id страницы N = первый id + N − 1.
# Картинка: /pages/<id>/zooms/<z>, уровни 0..8 (0 — 82×104, 4 — 656×829, 8 — ≈1966×2485).
# Для обычного текста хватает 4, для мелкого набора в колонку (адрес-календари) нужен 8.
# Не верьте набору размеров в HTML просмотрщика: zooms/8 бывает доступен, даже если в HTML
# перечислены одни миниатюры.
#
# Номер N — номер СКАНА из ссылки #mode/inspect/page/N, а не печатная страница.
#
# docs.historyrussia.org обрывает любой ответ примерно на 15 КБ. HTML лечится gzip, а скан —
# уже сжатый JPEG, поэтому файл докачивается кусками по 10 КБ (сервер отдаёт Accept-Ranges).
#
# Запуск:
#   perl get-inforost-page.pl --node 438361 --page 1,2 --root https://docs.historyrussia.org
#   perl get-inforost-page.pl --node 27332 --page 18 --zoom 8 --prefix ВсяМосква-1904
#   perl get-inforost-page.pl --node 438361 --all --root https://docs.historyrussia.org
#
# Ключи: --node ID (обязателен), --page 1,3,5-7 или --all, --root (по умолчанию http://elib.shpl.ru),
#        --out-dir (по умолчанию сканы), --prefix, --zoom 0..8 (по умолчанию 4)

use strict;
use warnings;
use utf8;
use Encode qw(decode encode);
use File::Basename qw(dirname);
use File::Spec;
use File::Path qw(make_path);
use Cwd qw(abs_path);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
require File::Spec->catfile(dirname(abs_path($0)), 'web-common.pl');

my @args = map { decode('UTF-8', $_) } @ARGV;
my %o = (root => 'http://elib.shpl.ru', out_dir => 'сканы', prefix => '', zoom => 4);
while (@args) {
  my $a = shift @args;
  if    ($a eq '--node')    { $o{node} = shift @args; }
  elsif ($a eq '--page')    { $o{page} = shift @args; }
  elsif ($a eq '--all')     { $o{all} = 1; }
  elsif ($a eq '--root')    { $o{root} = shift @args; $o{root} =~ s{/$}{}; }
  elsif ($a eq '--out-dir') { $o{out_dir} = shift @args; }
  elsif ($a eq '--prefix')  { $o{prefix} = shift @args; }
  elsif ($a eq '--zoom')    { $o{zoom} = shift @args; }
}
die "Нужен --node ID и --page 1,2 или --all\n" unless $o{node} && ($o{page} || $o{all});
die "--zoom от 0 до 8\n" unless $o{zoom} =~ /^[0-8]$/;
make_path(fs($o{out_dir})) unless -d fs($o{out_dir});

sub curl_run { my @c = ('curl', @_); return system(@c); }

# Размер файла из заголовков; без него нельзя отличить целый файл от оборванного
sub expected_size {
  my ($url) = @_;
  for my $try (1 .. 3) {
    my @cmd = ('curl', '-s', '-I', '--http1.1', '-m', 45, '-A', $main::UserAgent, encode('UTF-8', $url));
    if (open(my $ph, '-|', @cmd)) {
      while (my $l = <$ph>) { if ($l =~ /^Content-Length:\s*(\d+)/i) { close $ph; return $1; } }
      close $ph;
    }
    nap(500 * $try);
  }
  return 0;
}

sub save_chunked {
  my ($url, $path, $chunk) = @_;
  $chunk ||= 10000;
  my $expected = expected_size($url) or die "не удалось узнать размер файла, качать вслепую нельзя: $url\n";

  # короткий пробник: на ГПИБ придёт целиком, на historyrussia оборвётся
  curl_run('-s', '-L', '--http1.1', '-m', 30, '-A', $main::UserAgent, '-o', fs($path), encode('UTF-8', $url));
  return 1 if -e fs($path) && -s fs($path) >= $expected;

  warn "  ответ оборван, добираю кусками по $chunk б (всего $expected)\n";
  open(my $out, '>:raw', fs($path)) or die "не пишется $path\n";
  for (my $from = 0; $from < $expected; $from += $chunk) {
    my $to = $from + $chunk - 1; $to = $expected - 1 if $to > $expected - 1;
    my $part = "$path.part"; my $ok = 0;
    for my $try (1 .. 5) {
      curl_run('-s', '--http1.1', '-m', 60, '-A', $main::UserAgent, '-H', "Range: bytes=$from-$to", '-o', fs($part), encode('UTF-8', $url));
      if (-e fs($part) && -s fs($part) == $to - $from + 1) { $ok = 1; last; }
      nap(400 * $try);
    }
    unlink fs($part), die "не пришёл кусок $from-$to после 5 попыток\n" unless $ok;
    open(my $in, '<:raw', fs($part)) or die; local $/; my $b = <$in>; close $in; unlink fs($part);
    print $out $b;
  }
  close $out;
  return 1;
}

my $html = http_get("$o{root}/ru/nodes/$o{node}", timeout => 90);
die "пустой ответ: $o{root}/ru/nodes/$o{node}\n" unless defined $html;
my ($first) = $html =~ /"pages":\[\{"id":(\d+)/;
die "В узле $o{node} не нашёлся список страниц — возможно, у него нет сканов.\n" unless defined $first;
my $total = () = $html =~ /"id":\d+,"w":/g;
my ($title) = $html =~ m{<title>(.*?)</title>}s;
$title = html_to_text($title // '');
print "Узел $o{node}: $title\n  первая страница id=$first, всего сканов: $total\n";

my @pages;
if ($o{all}) { @pages = (1 .. $total) }
else {
  for my $part (split /,/, $o{page}) {
    if ($part =~ /^(\d+)-(\d+)$/) { push @pages, $1 .. $2 } elsif ($part =~ /^\d+$/) { push @pages, $part }
  }
}

for my $n (@pages) {
  if ($n < 1 || ($total && $n > $total)) { warn "  стр. $n — вне диапазона (в узле $total сканов), пропускаю\n"; next; }
  my $id = $first + $n - 1;
  my $name = $o{prefix} ne '' ? sprintf('%s-стр%03d.jpg', $o{prefix}, $n) : sprintf('node%s-стр%03d.jpg', $o{node}, $n);
  my $path = File::Spec->catfile($o{out_dir}, $name);
  eval { save_chunked("$o{root}/pages/$id/zooms/$o{zoom}", $path); 1 } or do { warn "  стр. $n — не скачалась: $@"; next; };
  my $size = -s fs($path) // 0;
  if ($size < 3000) { warn "  стр. $n — файл подозрительно мал ($size б)\n" }
  else { printf "  стр. %-4s -> %s (%s б)\n", $n, $name, $size; }
  nap(500);
}
