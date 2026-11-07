#!/usr/bin/perl
# search-cyberleninka.pl — поиск научных статей в КиберЛенинке (cyberleninka.ru) без входа.
#
# Эндпоинт: POST https://cyberleninka.ru/api/search, тело JSON:
#   {"mode":"articles","q":"<запрос>","size":<сколько>,"from":<смещение>}
# Ответ: {"found":N,"articles":[{name, annotation, authors[], journal, year, link, ocr, ...}]}.
# Параметры именно такие: в августе 2026 запрос «в другом виде» отдавал found:0, и казалось, что поиск сломан;
# 5 ноября 2026 с этим телом он работает (бессмысленный запрос даёт 0, настоящий — сотни).
#
# Запуск:
#   perl search-cyberleninka.pl 'усадьба Быково'
#   perl search-cyberleninka.pl --max 50 --year-from 2000 --csv статьи.csv 'метрические книги'
#
# Ключи: --max N (сколько вернуть, по умолчанию 20; запрашивается страницами по 20),
#        --year-from Y / --year-to Y (фильтр на нашей стороне), --csv файл, --delay мс (по умолчанию 1500)
#
# Это поиск по статьям (в основном современные журналы), а не по архивным документам.
# Для темы «найти, кто писал о месте или человеке» подходит хорошо; для дореформенных текстов — нет.

use strict;
use warnings;
use utf8;
use Encode qw(decode);
use JSON::PP;
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
require File::Spec->catfile(dirname(abs_path($0)), 'web-common.pl');

my @args = map { decode('UTF-8', $_) } @ARGV;
my %o = (max => 20, delay => 1500);
my @words;
while (@args) {
  my $a = shift @args;
  if    ($a eq '--max')       { $o{max} = shift @args; }
  elsif ($a eq '--year-from') { $o{from} = shift @args; }
  elsif ($a eq '--year-to')   { $o{to} = shift @args; }
  elsif ($a eq '--csv')       { $o{csv} = shift @args; }
  elsif ($a eq '--delay')     { $o{delay} = shift @args; }
  else                        { push @words, $a; }
}
die "Нужен запрос: perl search-cyberleninka.pl 'запрос'\n" unless @words;
my $q = join ' ', @words;

sub clean { my $s = html_to_text(shift // ''); return $s; }

my (@rows, $found);
my $offset = 0;
while (@rows < $o{max}) {
  my $size = 20;
  my $body = JSON::PP->new->utf8(0)->canonical->encode({ mode => 'articles', q => $q, size => $size, from => $offset });
  my $resp = http_get('https://cyberleninka.ru/api/search', post => $body, content_type => 'application/json', timeout => 60, retries => 2);
  die "КиберЛенинка не ответила\n" unless defined $resp;
  my $d = from_json_text($resp) or die "КиберЛенинка вернула не JSON (возможно, проверка на робота: откройте сайт в браузере)\n";
  $found //= $d->{found};
  my @arts = @{ $d->{articles} || [] };
  last unless @arts;
  for my $a (@arts) {
    my $y = $a->{year} // '';
    next if $o{from} && $y && $y < $o{from};
    next if $o{to} && $y && $y > $o{to};
    push @rows, {
      Year => $y, Title => clean($a->{name}), Authors => join(', ', @{ $a->{authors} || [] }),
      Journal => clean($a->{journal}), Url => 'https://cyberleninka.ru' . ($a->{link} // ''),
      Annotation => substr(clean($a->{annotation}), 0, 400),
    };
    last if @rows >= $o{max};
  }
  $offset += @arts;
  last if @arts < $size || $offset >= ($found // 0);
  nap($o{delay});
}

print "Найдено на сайте: " . ($found // 0) . ", показано: " . scalar(@rows) . "\n\n";
for my $r (@rows) {
  printf "[%s] %s\n    %s · %s\n    %s\n", $r->{Year}, $r->{Title}, $r->{Authors}, $r->{Journal}, $r->{Url};
}
if ($o{csv}) { csv_write($o{csv}, \@rows, [qw(Year Title Authors Journal Url Annotation)]); print "\nСохранено: $o{csv}\n"; }
