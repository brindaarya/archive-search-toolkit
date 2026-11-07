#!/usr/bin/perl
# search-shpl.pl — поиск по ГПИБ (elib.shpl.ru) и другим сайтам на платформе ИнфоРост
# (например, docs.historyrussia.org). Без регистрации.
#
# Перенос Search-ShplText.ps1 на Perl: PowerShell на Mac и Linux по умолчанию нет.
#
# Синтаксис запроса люценовский:
#   "точная фраза"      +слово  (обязательно)     слово1 слово2  (пробел = ИЛИ)
#   слов*  (любое окончание)      в?домость  (? = одна любая буква)
#   "два слова"~15  (близость; морфологию внутри кавычек НЕ учитывает)
#
# Запуск:
#   perl search-shpl.pl 'исповѣдныя вѣдомости'
#   perl search-shpl.pl --max-pages 3 --csv out.csv '+Бронницк* +земск*'
#   perl search-shpl.pl --root https://docs.historyrussia.org 'Ильин'
#   perl search-shpl.pl --page-text 6114704          # распознанный текст страницы по id
#
# Ключи:
#   --max-pages N     сколько страниц выдачи (по 100 изданий), по умолчанию 3
#   --hits N          сколько попаданий в текст показывать на издание, по умолчанию 6
#   --metadata-only   искать только по описаниям, без полного текста
#   --csv путь        сохранить таблицу
#   --root URL        другой сайт на этой платформе
#   --delay N         пауза между страницами, мс (по умолчанию 1500)
#
# Ограничение сервиса: частые запросы получают «429 Too Many Requests». Паузу не убирайте.
# «page/N» в ссылке — номер СКАНА, а не печатной страницы (обложка и титул сдвигают номера):
# проверяйте по колонтитулу в тексте.

use strict;
use warnings;
use utf8;
use Encode qw(decode);
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
require File::Spec->catfile(dirname(abs_path($0)), 'web-common.pl');

my @args = map { decode('UTF-8', $_) } @ARGV;
my ($root, $max_pages, $max_hits, $meta_only, $csv, $delay, $page_text) =
   ('http://elib.shpl.ru', 3, 6, 0, undef, 1500, undef);
my @words;
while (@args) {
  my $a = shift @args;
  if    ($a eq '--root')          { $root = shift @args; $root =~ s{/$}{}; }
  elsif ($a eq '--max-pages')     { $max_pages = shift @args; }
  elsif ($a eq '--hits')          { $max_hits = shift @args; }
  elsif ($a eq '--metadata-only') { $meta_only = 1; }
  elsif ($a eq '--csv')           { $csv = shift @args; }
  elsif ($a eq '--delay')         { $delay = shift @args; }
  elsif ($a eq '--page-text')     { $page_text = shift @args; }
  else                            { push @words, $a; }
}

if (defined $page_text) {
  my $json = http_get("$root/ru/pages/$page_text/read", timeout => 60);
  my $d = from_json_text($json);
  die "страница $page_text не отдала текст\n" unless $d && defined $d->{text};
  print "$d->{text}\n";
  exit 0;
}

die "Нужен запрос: perl search-shpl.pl 'запрос'\n" unless @words;
my $query = join ' ', @words;

my @rows;
for my $page (1 .. $max_pages) {
  my $url = sprintf('%s/ru/nodes/search?query=%s&search_in_metadata=on&search_in_texts=%s&per_page=100&page=%d',
                    $root, url_encode($query), ($meta_only ? 'off' : 'on'), $page);
  my $html = http_get($url, timeout => 90);
  unless (defined $html) { warn "сайт не ответил, страница $page\n"; last; }
  if ($html =~ /429 Too Many Requests/) {
    warn "429: сервис просит не торопиться. Увеличьте --delay и повторите позже.\n";
    last;
  }

  my @tr = $html =~ m{(<tr[^>]*>.*?</tr>)}gs;
  last if @tr <= 1;

  my ($cur, $node_hits, $found) = (undef, 0, 0);
  for my $tr (@tr) {
    next unless $tr =~ /<td/;
    my ($href) = $tr =~ m{href="(/ru/nodes/\d+[^"]*)"};
    next unless $href;

    my @cells = map { html_to_text($_) } ($tr =~ m{<td[^>]*>(.*?)</td>}gs);

    if ($tr =~ m{<td class='first'>\s*\d+\s*</td>}) {
      # пронумерованная строка — само издание
      $found++; $node_hits = 0;
      (my $clean = $href) =~ s/\?.*$//;
      $cur = { Title => $cells[1] // '', Kind => $cells[2] // '', Author => $cells[3] // '',
               Year => $cells[10] // '', Parent => $cells[11] // '', Url => $root . $clean };
      push @rows, { Query => $query, %$cur, Page => '',
                    Snippet => join(' | ', grep { length } @cells[1 .. ($#cells < 6 ? $#cells : 6)]) };
      next;
    }

    # безномерная строка «Страница N» — попадание в распознанный текст последнего издания
    if ($cur && $node_hits < $max_hits && ($cells[1] // '') =~ /Страниц\w*\s*(\d+)/) {
      $node_hits++;
      push @rows, { Query => $query, %$cur, Page => $1, Snippet => $cells[2] // '', Url => $root . $href };
    }
  }

  last if $found < 100;
  nap($delay);
}

unless (@rows) { print "Ничего не найдено (или сервис не ответил).\n"; exit 0; }

for my $r (@rows) {
  if ($r->{Page} eq '') {
    printf "\n[%s] %s — %s  (%s)\n    %s\n", $r->{Year}, $r->{Author}, $r->{Title}, $r->{Kind}, $r->{Url};
  } else {
    my $s = $r->{Snippet}; $s = substr($s, 0, 220) . '…' if length $s > 220;
    printf "    скан %s: %s\n        %s\n", $r->{Page}, $s, $r->{Url};
  }
}

if ($csv) {
  csv_write($csv, \@rows, [qw(Query Year Author Title Kind Parent Page Snippet Url)]);
  print "\nСохранено: $csv\n";
}
