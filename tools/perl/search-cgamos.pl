#!/usr/bin/perl
# search-cgamos.pl — поиск дел в «Метрических книгах» и смежных разделах ЦГА Москвы
# (cgamos.ru/book_search/). Без регистрации; сканы по ссылке открыты.
#
# Перенос Search-Cgamos.ps1 на Perl.
#
# Важно про результат: одно дело метрической книги — подшивка по всей губернии,
# в заголовке перечислены десятки приходов под номерами. Поиск по названию села
# находит дело, но не лист: колонка «Позиция» показывает номер прихода в заголовке,
# по нему и листают скан. Ревизские сказки и исповедные ведомости озаглавлены по
# УЕЗДУ — село в заголовок не попадает, ищите по названию уезда.
#
# Запуск:
#   perl search-cgamos.pl БЫКОВО
#   perl search-cgamos.pl --section исповедные --years 1850-1917 БРОННИЦК
#   perl search-cgamos.pl --section ревизии --csv rev.csv БРОННИЦК
#
# Разделы: метрики (по умолчанию) | ревизии | исповедные | обыски | личные | кладбища | иноверцы
# Запрос — ЗАГЛАВНЫМИ, в современной орфографии (в заголовках дел так).
#
# Архив придушивает серии запросов (200 с нулём байт): в скрипте пауза и повтор.

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

my $root = 'https://cgamos.ru';     # для проверки без сети можно подменить ключом --root
my %codes = (
  'метрики'    => '73,60',
  'иноверцы'   => '67,68,69,70',
  'ревизии'    => '63',
  'исповедные' => '65',
  'обыски'     => '76',
  'личные'     => '77',
  'кладбища'   => '80',
);

my @args = map { decode('UTF-8', $_) } @ARGV;
my ($section, $from, $to, $csv, $max_pages, $delay) = ('метрики', 0, 0, undef, 40, 800);
my @words;
while (@args) {
  my $a = shift @args;
  if    ($a eq '--root')      { $root = shift @args; $root =~ s{/$}{}; }
  elsif ($a eq '--section')   { $section = shift @args; }
  elsif ($a eq '--years')     { (shift(@args) // '') =~ /^(\d{4})-(\d{4})$/ or die "--years ГГГГ-ГГГГ\n"; ($from, $to) = ($1, $2); }
  elsif ($a eq '--csv')       { $csv = shift @args; }
  elsif ($a eq '--max-pages') { $max_pages = shift @args; }
  elsif ($a eq '--delay')     { $delay = shift @args; }
  else                        { push @words, $a; }
}
die "Нужен термин: perl search-cgamos.pl БЫКОВО\n" unless @words;
die "Неизвестный раздел «$section». Доступны: " . join(', ', sort keys %codes) . "\n" unless $codes{$section};
my $term = join ' ', @words;

# Страница с повтором: слишком короткий ответ — это «придушенный» пустой, не выдача.
sub get_page {
  my ($url) = @_;
  for my $try (1 .. 4) {
    my $body = http_get($url, timeout => 90, retries => 1);
    return $body if defined $body && length $body > 5000;
    warn "  ответ пустой, пауза и повтор $try из 4\n";
    nap(5000 * $try);
  }
  die "архив не отдал страницу за 4 попытки: $url\n";
}

# Значение лежит во втором <div> блока: первый — подпись для мобильной вёрстки.
sub field {
  my ($block, $name) = @_;
  my ($v) = $block =~ m{<div class="\s*\Q$name\E">.*?<div class="mobile_title">.*?</div>\s*<div>(.*?)</div>}s;
  return defined $v ? html_to_text($v) : '';
}

my @rows;
PAGE: for my $page (1 .. $max_pages) {
  my $url = sprintf('%s/book_search/?placeToSearch=%s&title=%s', $root, $codes{$section}, url_encode($term));
  $url .= "&page=page-$page" if $page > 1;
  my $html = get_page($url);

  if ($page == 1) {
    my $plain = html_to_text($html);
    print "Найдено дел: $1\n" if $plain =~ /Найдено:\s*([\d\s]+?)\s*результат/;
    if ($plain =~ /Ничего не найдено/) { print "По запросу «$term» в разделе «$section» ничего нет.\n"; exit 0; }
  }

  my @blocks = $html =~ m{(<div class="reports-list-item">.*?)(?=<div class="reports-list-item">|<!-- /data -->|\z)}gs;
  last unless @blocks;

  for my $b (@blocks) {
    my ($href) = $b =~ m{href="(/metric-books/[^"]+)"};
    next unless $href;
    my $desc = field($b, 'UF_DESC');
    my ($pos) = $desc =~ /(\d+)\.?\s+[^\d]{0,40}\Q$term\E/i;
    push @rows, {
      'Фонд' => field($b, 'UF_FOND'), 'Опись' => field($b, 'UF_OPIS'), 'Дело' => field($b, 'UF_DELO'),
      'Годы' => field($b, 'UF_YEARS'), 'Позиция' => $pos // '',
      'Описание' => substr($desc, 0, 300), 'Ссылка' => $root . $href,
    };
  }

  last if @blocks < 10;
  nap($delay);
}

# фильтр по пересечению с диапазоном лет
if ($from || $to) {
  my ($lo, $hi) = ($from || 0, $to || 9999);
  @rows = grep {
    my @y = $_->{'Годы'} =~ /(\d{4})/g;
    @y && (sort { $a <=> $b } @y)[0] <= $hi && (sort { $b <=> $a } @y)[0] >= $lo;
  } @rows;
}

unless (@rows) { print "После фильтра ничего не осталось.\n"; exit 0; }
print "Отобрано: " . scalar(@rows) . "\n\n";
printf "ф.%s оп.%s д.%s  %s  позиция %s\n    %s\n", @{$_}{'Фонд','Опись','Дело','Годы','Позиция','Ссылка'} for @rows;

if ($csv) {
  csv_write($csv, \@rows, ['Фонд', 'Опись', 'Дело', 'Годы', 'Позиция', 'Описание', 'Ссылка']);
  print "\nСохранено: $csv\n";
}
