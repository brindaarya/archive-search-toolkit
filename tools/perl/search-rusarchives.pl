#!/usr/bin/perl
# search-rusarchives.pl — поиск по открытым архивным ресурсам без регистрации:
#   guides — guides.rusarchives.ru, сводная база путеводителей по российским архивам
#            (полнотекст по аннотациям фондов и описей: показывает состав описи там, где сама опись не выложена);
#   istmat — istmat.org, открытый корпус советских документов;
#   sovdoc — sovdoc.rusarchives.ru, «Документы советской эпохи». НА 4 АВГУСТА 2026 backend ЛЕЖАЛ (404/500):
#            ветка оставлена, при недоступности источник пропускается с предупреждением.
#
# Перенос Search-Rusarchives.ps1 на Perl; предметная логика одной темы (усадьба) заменена вашими
# регулярными выражениями.
#
# Привязка к теме считается ПО ОКНУ ±300 знаков вокруг вхождения слова запроса, а не по документу
# целиком: на длинной аннотации путеводителя «Быков» и «усадьба» стоят в разных фондах, и оценка по
# всему тексту даёт ложное «да» (так было — четыре ложных «да»). Правила:
#   да          в окне есть --strong И --place
#   вероятно    есть --strong, либо --place вместе с --inst
#   нет данных  иначе (если задан --noise и он совпал — с пометкой «похоже на ложное совпадение»)
# Без --strong/--place/--inst привязка не оценивается.
#
# Особенности:
#   * полнотекст guides матчит по ОСНОВЕ слова: «Быково» тащит «Быкова Э. Б.» пачками — нужен --noise;
#   * аннотация описи у guides лежит только внутри узла /node/NNNNN: без --deep виден лишь заголовок;
#   * у guides.rusarchives.ru сертификат с неполной цепочкой, поэтому по умолчанию проверка сертификата
#     ОСТАЁТСЯ ВКЛЮЧЁННОЙ, и guides может не отвечать. Ключ --insecure вызывает curl с -k (без проверки
#     сертификата) для запросов к этому источнику: данные публичные и только читаются, но решение за вами.
#
# Запуск:
#   perl search-rusarchives.pl --query 'дом отдыха' --query Марьино --source guides,istmat --deep \
#        --strong 'усадьб|дворец|Воронцов' --place 'Быков|Верея|Раменск' --noise 'Быков\w*\s+[А-Я]\.\s*[А-Я]\.' --csv итог.csv
#
# Ключи: --query (повторяемый), --source guides,istmat,sovdoc (по умолчанию все), --deep, --insecure, --stem RE
#        (основа слова для окон; по умолчанию — слово без типового окончания), --max-pages N (5),
#        --max-hits N (60), --delay мс (700), --csv файл

use strict;
use warnings;
use utf8;
use Encode qw(decode encode);
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
require File::Spec->catfile(dirname(abs_path($0)), 'web-common.pl');

my @args = map { decode('UTF-8', $_) } @ARGV;
my %o = (source => 'guides,istmat,sovdoc', max_pages => 5, max_hits => 60, delay => 700,
         guides_root => 'https://guides.rusarchives.ru', istmat_root => 'https://istmat.org',
         sovdoc_api => 'https://sovdoc.rusarchives.ru/api/public/search');
my (@queries, @strong, @place, @inst);
while (@args) {
  my $a = shift @args;
  if    ($a eq '--query')       { push @queries, shift @args; }
  elsif ($a eq '--source')      { $o{source} = shift @args; }
  elsif ($a eq '--deep')        { $o{deep} = 1; }
  elsif ($a eq '--insecure')    { $o{insecure} = 1; }
  elsif ($a eq '--strong')      { push @strong, shift @args; }
  elsif ($a eq '--place')       { push @place, shift @args; }
  elsif ($a eq '--inst')        { push @inst, shift @args; }
  elsif ($a eq '--noise')       { $o{noise} = shift @args; }
  elsif ($a eq '--stem')        { $o{stem} = shift @args; }
  elsif ($a eq '--max-pages')   { $o{max_pages} = shift @args; }
  elsif ($a eq '--max-hits')    { $o{max_hits} = shift @args; }
  elsif ($a eq '--delay')       { $o{delay} = shift @args; }
  elsif ($a eq '--csv')         { $o{csv} = shift @args; }
  elsif ($a eq '--guides-root') { $o{guides_root} = shift @args; }
  elsif ($a eq '--istmat-root') { $o{istmat_root} = shift @args; }
  else                          { push @queries, $a; }
}
die "Нужен хотя бы один запрос: --query 'слово'\n" unless @queries;
my @sources = split /,/, $o{source};
my $scored = (@strong || @place || @inst) ? 1 : 0;

# ------------------------------------------------------------------ сеть

sub fetch {
  my ($url, %opt) = @_;
  my $retries = $opt{retries} // 3;
  for my $try (1 .. $retries) {
    my @cmd = ('curl', '-sL', '--compressed', '-m', 60, '-A', $main::UserAgent, '-w', "\n%{http_code}");
    push @cmd, '-k' if $opt{insecure};
    push @cmd, '-H', 'Accept: application/json' if $opt{json};
    push @cmd, encode('UTF-8', $url);
    my $raw = '';
    if (open(my $ph, '-|', @cmd)) { binmode($ph, ':raw'); local $/; $raw = <$ph> // ''; close $ph; }
    my ($body, $code) = $raw =~ /^(.*)\n(\d{3})\z/s;
    $body = decode('UTF-8', $body // '');
    $code //= 0;
    return ($code, $body) if $code >= 500 || $code == 404;      # лежащий backend повторять незачем
    return ($code, $body) if $code >= 200 && $code < 300 && length $body;
    nap(3000 * $try);
  }
  return (0, undef);
}

# ------------------------------------------------------------------ источники

sub search_guides {
  my ($term) = @_;
  my (@res, %seen);
  for my $page (0 .. $o{max_pages} - 1) {
    my $url = sprintf('%s/search?search_api_views_fulltext=%s&page=%d', $o{guides_root}, url_encode($term), $page);
    my ($code, $html) = fetch($url, insecure => $o{insecure});
    die "guides: HTTP $code" . ($code == 0 ? " (не проверился сертификат сайта: он у них с неполной цепочкой; если согласны отключить проверку для этого источника, добавьте --insecure)" : "") . "\n" unless defined $html;
    my @m = $html =~ m{<a href="(/node/\d+)"[^>]*>(.*?)</a>}gs;
    last unless @m;
    while (my ($href, $title) = splice(@m, 0, 2)) {
      next if $seen{$href}++;
      push @res, { Url => $o{guides_root} . $href, Title => html_to_text($title) };
    }
    last if @res >= $o{max_hits};
    nap($o{delay});
  }
  splice(@res, $o{max_hits}) if @res > $o{max_hits};
  return @res;
}

sub search_istmat {
  my ($term) = @_;
  my ($code, $html) = fetch(sprintf('%s/search/node/%s', $o{istmat_root}, url_encode($term)));
  die "istmat: HTTP $code\n" unless defined $html;
  my @res;
  for my $chunk (split /(?=<h3[^>]*class="title")/, $html) {
    my ($href, $title) = $chunk =~ m{<h3[^>]*class="title"[^>]*>\s*<a href="([^"]+)"[^>]*>(.*?)</a>}s or next;
    my ($snip) = $chunk =~ m{<p class="search-snippet">(.*?)</p>}s;
    $href = $o{istmat_root} . $href unless $href =~ m{^https?://};
    push @res, { Url => $href, Title => html_to_text($title), Snippet => html_to_text($snip // '') };
  }
  splice(@res, $o{max_hits}) if @res > $o{max_hits};
  return @res;
}

my $sovdoc_down = 0;
sub search_sovdoc {
  my ($term) = @_;
  return () if $sovdoc_down;
  my ($code, $body) = fetch(sprintf('%s?title=%s&limit=%d', $o{sovdoc_api}, url_encode($term), $o{max_hits}), json => 1, retries => 1);
  if (!defined $body || $code >= 400 || $code == 0) {
    warn "sovdoc недоступен (HTTP $code) — backend лежит на их стороне, пропускаю\n";
    $sovdoc_down = 1;
    return ();
  }
  my $d = from_json_text($body) or return ();
  my $items = $d->{items} || $d->{data} || [];
  return map { { Url => 'https://sovdoc.rusarchives.ru/details/' . $_->{id}, Title => $_->{title} // '', Snippet => $_->{annotation} // '' } } @$items;
}

# ------------------------------------------------------------------ привязка по окну

sub stem_regex {
  my ($term) = @_;
  return $o{stem} if defined $o{stem};
  (my $s = $term) =~ s/(ое|ий|ый|ая|о|а|е|я|ь)$//;
  return quotemeta($s);
}

sub windows {
  my ($text, $term) = @_;
  return () unless length $text;
  my $rx = stem_regex($term);
  my @w;
  while ($text =~ /$rx/gi) {
    my $start = $-[0] - 300; $start = 0 if $start < 0;
    push @w, substr($text, $start, 600);
    last if @w >= 12;
  }
  push @w, substr($text, 0, 400) unless @w;
  return @w;
}

sub any_match { my ($t, $pats) = @_; for my $p (@$pats) { return 1 if $t =~ /$p/i } return 0; }
sub first_hits {
  my ($t, @lists) = @_;
  my (@f, %s);
  for my $l (@lists) { for my $p (@$l) { if ($t =~ /($p)/i && !$s{$1}++) { push @f, $1 } } }
  return join('; ', @f[0 .. ($#f > 4 ? 4 : $#f)]);
}

sub binding {
  my ($w) = @_;
  my ($hs, $hp, $hi) = (any_match($w, \@strong), any_match($w, \@place), any_match($w, \@inst));
  my $sig = first_hits($w, \@strong, \@inst);
  return ('да', $sig)       if $hs && $hp;
  return ('вероятно', $sig) if $hs || ($hp && $hi);
  return ('нет данных', 'похоже на ложное совпадение') if defined $o{noise} && $w =~ /$o{noise}/ && !$hi;
  return ('нет данных', $sig);
}

# ------------------------------------------------------------------ прогон

my (@rows, %seen);
my %rank = ('да' => 2, 'вероятно' => 1, 'нет данных' => 0);
for my $term (@queries) {
  for my $src (@sources) {
    next if $src eq 'sovdoc' && $sovdoc_down;
    print "[$src] $term\n";
    my @hits = eval { $src eq 'guides' ? search_guides($term) : $src eq 'istmat' ? search_istmat($term) : search_sovdoc($term) };
    if ($@) { warn "  $@"; next; }
    print "    найдено: " . scalar(@hits) . "\n";
    for my $h (@hits) {
      next if $seen{"$src|$h->{Url}"}++;
      my $context = $h->{Title} . ($h->{Snippet} ? " $h->{Snippet}" : '');
      if ($o{deep} && $src eq 'guides') {
        nap($o{delay});
        my ($c, $page) = fetch($h->{Url}, insecure => $o{insecure});
        $context = html_to_text($page) if defined $page;
      }
      my ($best, $sig, $snip) = ($scored ? 'нет данных' : 'не оценивалась', '', '');
      my @w = windows($context, $term);
      if ($scored) {
        for my $w (@w) {
          my ($b, $s) = binding($w);
          if ($rank{$b} > $rank{$best} || $snip eq '') { if ($rank{$b} >= $rank{$best}) { ($best, $sig, $snip) = ($b, $s, $w) } }
        }
      } else { $snip = $w[0] // ''; }
      $snip = substr($snip, 0, 320);
      push @rows, { Source => $src, Query => $term, Title => $h->{Title}, Url => $h->{Url}, Binding => $best, Signal => $sig, Snippet => $snip };
    }
    nap($o{delay});
  }
}

unless (@rows) { print "Ничего не найдено.\n"; exit 0; }
my %order = ('да' => 0, 'вероятно' => 1, 'не оценивалась' => 2, 'нет данных' => 3);
@rows = sort { $order{$a->{Binding}} <=> $order{$b->{Binding}} || $a->{Source} cmp $b->{Source} || $a->{Query} cmp $b->{Query} } @rows;
my %cnt; $cnt{$_->{Binding}}++ for @rows;
print "\nВсего записей: " . scalar(@rows) . "\n";
printf "  привязка %-16s %d\n", $_, $cnt{$_} for sort { $order{$a} <=> $order{$b} } keys %cnt;
for my $r (grep { $_->{Binding} eq 'да' || $_->{Binding} eq 'вероятно' || $_->{Binding} eq 'не оценивалась' } @rows[0 .. ($#rows < 24 ? $#rows : 24)]) {
  printf "\n[%s] %s · %s\n    %s\n    %s\n", $r->{Binding}, $r->{Source}, $r->{Query}, $r->{Title}, $r->{Url};
}
if ($o{csv}) { csv_write($o{csv}, \@rows, [qw(Source Query Title Url Binding Signal Snippet)]); print "\nСохранено: $o{csv}\n"; }
print "\nsovdoc.rusarchives.ru не отвечал — прогнать отдельно, когда поднимется: --source sovdoc\n" if $sovdoc_down;
