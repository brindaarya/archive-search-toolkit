#!/usr/bin/perl
# ya-probe.pl — «зонд» по вариантам написания в Яндекс Архиве.
#
# Берёт фразу в современной орфографии, строит варианты (spelling-variants.pl),
# делает по каждому один запрос и печатает, сколько документов нашлось. Так сразу
# видно, в какой орфографии искать: «іога» — 277, «йога» — 10.
# Правило из практики: сначала зонд, потом пакетный прогон лучшей формой.
#
# Запуск:
#   perl ya-probe.pl 'хатха-йога'
#   perl ya-probe.pl --years 1860-1918 'в Бронницком уезде'
#   perl ya-probe.pl --index archive --pause 3000 'Ильинъ'
#
# Ключи:
#   --years A-B    ограничить годами (четыре цифры)
#   --index X      mass_media | archive | books; по умолчанию без индекса — весь корпус
#                  (mass_media сужает выдачу до небольшой периодики и скрывает сканы ЦГА Москвы)
#   --pause N      пауза между запросами, мс (по умолчанию 2500 — не торопим сервис)
#   --variants     только показать варианты, в сеть не ходить
#
# Если сайт отдаёт капчу или перенаправляет — скрипт остановится. Капчу не обходим:
# откройте тот же запрос в браузере и пройдите проверку сами.

use strict;
use warnings;
use utf8;
use Encode qw(decode);
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

my $here = dirname(abs_path($0));
require File::Spec->catfile($here, 'spelling-variants.pl');
require File::Spec->catfile($here, 'ya-archive.pl');

my @args = map { decode('UTF-8', $_) } @ARGV;
my ($from, $to, $index, $pause, $only_variants) = (undef, undef, '', 2500, 0);
my @words;
while (@args) {
  my $a = shift @args;
  if    ($a eq '--years')    { ($from, $to) = (shift(@args) // '') =~ /^(\d{4})-(\d{4})$/ or die "--years ГГГГ-ГГГГ\n"; }
  elsif ($a eq '--index')    { $index = shift @args; }
  elsif ($a eq '--pause')    { $pause = shift @args; }
  elsif ($a eq '--variants') { $only_variants = 1; }
  else                       { push @words, $a; }
}
die "Нужна фраза: perl ya-probe.pl 'фраза'\n" unless @words;
my $phrase = join ' ', @words;

my @variants = spelling_variants($phrase);

if ($only_variants) {
  print "$_->{text}\t$_->{note}\n" for @variants;
  exit 0;
}

my @results;
for my $v (@variants) {
  my @hits = search_ya_archive(
    text      => $v->{text},
    index     => $index,
    date_from => $from,
    date_to   => $to,
    max_pages => 1,
  );
  if (@hits && !defined $hits[0]) {
    # undef от search_ya_archive = сервис не дал выдачу; это не ноль находок
    push @results, { %$v, total => -1, sample => '' };
  } elsif (!@hits) {
    push @results, { %$v, total => 0, sample => '' };    # сервис ответил, но находок нет
  } else {
    push @results, { %$v, total => $hits[0]{Total} || 0, sample => $hits[0]{Source} || '' };
  }
  nap($pause);
}

print "\nВарианты написания: «$phrase»", ($from ? " ($from–$to)" : ''), ($index ? ", индекс $index" : ', весь корпус'), "\n\n";
printf "%8s  %-40s  %s\n", 'найдено', 'вариант', 'примечание';
for my $r (sort { $b->{total} <=> $a->{total} } @results) {
  printf "%8s  %-40s  %s\n", ($r->{total} < 0 ? 'нет ответа' : $r->{total}), $r->{text}, $r->{note};
}

my ($best) = sort { $b->{total} <=> $a->{total} } @results;
print "\nСамая результативная форма: $best->{text}\n" if $best && $best->{total};
print "\nПомните: ноль — это «не нашлось в этой орфографии», а не «этого нет в архиве».\n";
print "Для пакетного прогона берите две-три лучшие формы и фильтруйте выдачу по именам и топонимам:\n";
print "в Яндекс Архиве короткие слова ловятся внутри имён («Іога» → «Іоганнъ»).\n";
