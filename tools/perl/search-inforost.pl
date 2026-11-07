#!/usr/bin/perl
# search-inforost.pl — пакетный поиск по сайтам на платформе «ИнфоРост»:
# docs.historyrussia.org («Исторические материалы») и elib.shpl.ru (ГПИБ).
#
# Перенос Search-Inforost.ps1 на Perl. В отличие от search-shpl.pl:
#   * принимает несколько запросов за раз и склеивает результат без повторов;
#   * оценивает привязку каждой находки к вашей теме по куску OCR вокруг попадания
#     (да / вероятно / нет данных) — по ВАШИМ регулярным выражениям;
#   * переживает капризы docs.historyrussia.org: сервер обрывает любой ответ
#     примерно на 15 КБ, поэтому нужны одновременно `--http1.1 --compressed`,
#     проверка закрывающего </html> и повтор; на странице не больше 10 записей.
#
# Привязку считайте по окну текста, а не по всему документу: на длинной аннотации
# «усадьба» и фамилия стоят в разных местах, а условие формально выполняется.
#
# Запуск:
#   perl search-inforost.pl --root https://docs.historyrussia.org \
#        --query '+Ильин +высылк*' --query '"Иван Александрович Ильин"~4' \
#        --strong 'Ильин\w{0,3}[^.]{0,60}философ' --weak 'Ильин[^.]{0,80}(?:ГПУ|ВЧК)' --csv итог.csv
#   perl search-inforost.pl --queries-file запросы.txt --max-pages 3     # по запросу на строку
#
# Ключи:
#   --root URL         по умолчанию https://docs.historyrussia.org
#   --query Q          повторяемый; синтаксис люценовский: "фраза", +слово, слов*, "а б"~4
#   --queries-file F   запросы из файла (по одному на строку, # — комментарий)
#   --strong RE        «сильные» признаки (дают «да»); повторяемый
#   --weak RE          «слабые» признаки (дают «вероятно»); повторяемый
#   --noise RE         признак ложного совпадения (например, фамилия вместо места)
#   --per-page N       по умолчанию 10 (на historyrussia больше не отдаёт), на elib.shpl.ru до 100
#   --max-pages N      по умолчанию 8        --hits N   попаданий на издание, по умолчанию 6
#   --delay N          пауза, мс (по умолчанию 1200 — площадка хрупкая)
#   --csv файл         куда сохранить таблицу

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
my %o = (root => 'https://docs.historyrussia.org', max_pages => 8, hits => 6, delay => 1200);
my (@queries, @strong, @weak, $noise, $qfile);
while (@args) {
  my $a = shift @args;
  if    ($a eq '--root')        { $o{root} = shift @args; $o{root} =~ s{/$}{}; }
  elsif ($a eq '--query')       { push @queries, shift @args; }
  elsif ($a eq '--queries-file'){ $qfile = shift @args; }
  elsif ($a eq '--strong')      { push @strong, shift @args; }
  elsif ($a eq '--weak')        { push @weak, shift @args; }
  elsif ($a eq '--noise')       { $noise = shift @args; }
  elsif ($a eq '--per-page')    { $o{per_page} = shift @args; }
  elsif ($a eq '--max-pages')   { $o{max_pages} = shift @args; }
  elsif ($a eq '--hits')        { $o{hits} = shift @args; }
  elsif ($a eq '--delay')       { $o{delay} = shift @args; }
  elsif ($a eq '--csv')         { $o{csv} = shift @args; }
  else                          { push @queries, $a; }
}
if ($qfile) {
  open(my $fh, '<:encoding(UTF-8)', fs($qfile)) or die "не читается $qfile\n";
  while (my $l = <$fh>) { chomp $l; $l =~ s/\r$//; next if $l =~ /^\s*(#|$)/; push @queries, $l; }
  close $fh;
}
die "Нужен хотя бы один запрос (--query, --queries-file или просто аргумент)\n" unless @queries;
$o{per_page} //= ($o{root} =~ /shpl\.ru/ ? 100 : 10);

# Ответ целиком или повтор: обрыв на ~15 КБ узнаём по отсутствию </html>
sub fetch_whole {
  my ($url, $retries) = @_;
  $retries ||= 4;
  for my $try (1 .. $retries) {
    my @cmd = ('curl', '-sSL', '--http1.1', '--compressed', '-m', 60, '-A', $main::UserAgent, encode_utf8_arg($url));
    my $body = '';
    if (open(my $ph, '-|', @cmd)) { binmode($ph, ':raw'); local $/; $body = <$ph> // ''; close $ph; }
    $body = decode('UTF-8', $body);
    return $body if $body =~ m{</html>\s*$}i;
    warn "  ответ оборван на " . length($body) . " знаках, повтор $try из $retries\n";
    nap(3000 * $try);
  }
  return undef;
}
sub encode_utf8_arg { return Encode::encode('UTF-8', $_[0]); }

sub search_term {
  my ($term) = @_;
  my @res;
  for my $page (1 .. $o{max_pages}) {
    my $url = sprintf('%s/ru/nodes/search?query=%s&search_in_metadata=on&search_in_texts=on&per_page=%d&page=%d',
                      $o{root}, url_encode($term), $o{per_page}, $page);
    my $html = fetch_whole($url);
    die "не удалось получить ответ целиком: $url\n" unless defined $html;

    my @tr = $html =~ m{(<tr[^>]*>.*?</tr>)}gs;
    last if @tr <= 1;
    my ($cur, $node_hits, $found) = (undef, 0, 0);
    for my $tr (@tr) {
      next unless $tr =~ /<td/;
      my ($href) = $tr =~ m{href="(/ru/nodes/\d+[^"]*)"};
      next unless $href;
      my @c = map { html_to_text($_) } ($tr =~ m{<td[^>]*>(.*?)</td>}gs);
      if ($tr =~ m{<td class='first'>\s*\d+\s*</td>}) {
        $found++; $node_hits = 0;
        (my $clean = $href) =~ s/\?.*$//;
        $cur = { Title => $c[1] // '', Url => $o{root} . $clean, Kind => $c[2] // '', Year => $c[10] // '', Parent => $c[11] // '' };
        push @res, { %$cur, Page => '', Snippet => join(' | ', grep { length } @c[1 .. ($#c < 6 ? $#c : 6)]) };
        next;
      }
      if ($cur && $node_hits < $o{hits} && ($c[1] // '') =~ /Страниц\w*\s*(\d+)/) {
        $node_hits++;
        push @res, { %$cur, Url => $o{root} . $href, Page => $1, Snippet => $c[2] // '' };
      }
    }
    last if $found < $o{per_page};
    nap($o{delay});
  }
  return @res;
}

sub signal {
  my ($text, $pats) = @_;
  my @f;
  for my $p (@$pats) { if ($text =~ /($p)/i) { my $v = $1; $v = substr($v, 0, 70) if length $v > 70; push @f, $v; } }
  my %s; @f = grep { !$s{$_}++ } @f;
  return join(' ; ', @f[0 .. ($#f > 2 ? 2 : $#f)]);
}

sub binding {
  my ($text) = @_;
  return ('нет данных', '') unless length $text;
  for my $p (@strong) { return ('да', signal($text, \@strong)) if $text =~ /$p/i; }
  for my $p (@weak)   { return ('вероятно', signal($text, \@weak)) if $text =~ /$p/i; }
  return ('нет данных', 'похоже на ложное совпадение') if defined $noise && $text =~ /$noise/;
  return ('нет данных', '');
}

my (@rows, %seen);
for my $q (@queries) {
  print "[запрос] $q\n";
  my @hits = eval { search_term($q) };
  if ($@) { warn "  $q — $@"; next; }
  print "    записей: " . scalar(@hits) . "\n";
  for my $h (@hits) {
    my $key = "$h->{Url}|$h->{Page}";
    next if $seen{$key}++;
    my ($b, $sig) = (@strong || @weak) ? binding($h->{Snippet}) : ('не оценивалась', '');
    push @rows, { Query => $q, Binding => $b, Signal => $sig, Year => $h->{Year}, Title => $h->{Title},
                  Parent => $h->{Parent}, Page => $h->{Page}, Snippet => substr($h->{Snippet}, 0, 400), Url => $h->{Url} };
  }
  nap($o{delay});
}

unless (@rows) { print "Ничего не найдено.\n"; exit 0; }
my %order = ('да' => 0, 'вероятно' => 1, 'не оценивалась' => 2, 'нет данных' => 3);
@rows = sort { $order{$a->{Binding}} <=> $order{$b->{Binding}} || ($a->{Year} // '') cmp ($b->{Year} // '') } @rows;
my %cnt; $cnt{$_->{Binding}}++ for @rows;
print "\nВсего записей: " . scalar(@rows) . "\n";
printf "  привязка %-16s %d\n", $_, $cnt{$_} for sort { $order{$a} <=> $order{$b} } keys %cnt;
for my $r (@rows[0 .. ($#rows < 14 ? $#rows : 14)]) {
  my $s = $r->{Snippet}; $s = substr($s, 0, 160) . '…' if length $s > 160;
  printf "\n[%s] %s %s%s\n    %s\n    %s\n", $r->{Binding}, $r->{Year}, $r->{Title}, ($r->{Page} ne '' ? " (скан $r->{Page})" : ''), $s, $r->{Url};
}
print "\n(показаны первые 15; полный список — в CSV)\n" if @rows > 15;
if ($o{csv}) {
  csv_write($o{csv}, \@rows, [qw(Query Binding Signal Year Title Parent Page Snippet Url)]);
  print "Сохранено: $o{csv}\n";
}
