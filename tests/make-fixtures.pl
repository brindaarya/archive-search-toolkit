#!/usr/bin/perl
# Пересобирает образец страницы выдачи ЦГА Москвы (разметка воспроизведена по рабочему разбору).
use strict; use warnings; use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
my $pad = "<!-- pad -->" x 600;
my @rows = (["203","780","3579","1907","47 Приходъ Быково, 48 Другое"], ["203","745","2053","1777-1864","12 Быково"]);
print "<html><body><p>Найдено: 2 результата</p>\n";
for my $r (@rows) {
  print qq{<div class="reports-list-item"><a href="/metric-books/$r->[2]-x">дело</a>\n};
  my @f = (['UF_FOND','Фонд'], ['UF_OPIS','Опись'], ['UF_DELO','Дело'], ['UF_YEARS','Годы'], ['UF_DESC','Описание']);
  for my $i (0 .. 4) {
    print qq{<div class=" $f[$i][0]"><div class="mobile_title">$f[$i][1]</div><div>$r->[$i]</div></div>\n};
  }
  print "</div>\n";
}
print "$pad<!-- /data --></body></html>\n";
