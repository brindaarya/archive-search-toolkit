# ya-batch.pl — общий прогон набора запросов к Яндекс Архиву.
#
# В версии для Windows этот код был скопирован в каждый из двух десятков
# search-*.ps1: они отличались только списком запросов, отбором и заголовком
# отчёта. Здесь он один, а каждый скрипт задаёт своё.
#
# Использование из скрипта-набора:
#   run_ya_batch(
#     queries => [ { t => 'текст запроса', i => 'mass_media', a => 1917, b => 1935 }, ... ],
#     name    => 'bykovo',                     # имена файлов: bykovo-raw.csv, bykovo-report.md
#     title   => 'Заголовок отчёта',
#     all     => [ qr/география/, qr/тема/ ],  # попадание обязано совпасть со всеми
#     any     => qr/Быков|Ильин/,              # ...либо хотя бы с одним из этих
#     fields  => ['Snippet', 'Source'],        # где искать отбор (по умолчанию Snippet)
#   );

use strict;
use warnings;
use utf8;
use POSIX qw(strftime);
use Encode qw(decode);

# В периодике даты приходят как dd-MM-yyyy, в справочниках формат плавает.
# Для сортировки приводим к виду ГГГГ-ММ-ДД, непонятное уходит в начало.
sub sortable_date {
  my ($d) = @_;
  return '0000-00-00' unless defined $d && length $d;
  return "$3-$2-$1" if $d =~ /^(\d{2})-(\d{2})-(\d{4})$/;
  return "$3-$2-$1" if $d =~ /^(\d{1,2})\.(\d{1,2})\.(\d{4})$/;
  return "$1-00-00"  if $d =~ /(\d{4})/;
  return '0000-00-00';
}

sub run_ya_batch {
  my (%o) = @_;
  my $queries = $o{queries} or die "не задан список запросов\n";
  my $dir     = $o{dir} or die "не задана папка\n";
  my $name    = $o{name} // 'search';
  my $fields  = $o{fields} // ['Snippet'];

  my $outDir = "$dir/results";
  mkdir fs($outDir) unless -d fs($outDir);

  # Ключи командной строки: --csv/--md задают свои имена файлов,
  # --suffix приписывает хвост к обычным. Пригодится, чтобы прогнать заново
  # и сравнить с прежним результатом, а не затереть его.
  my ($argCsv, $argMd, $suffix);
  {
    my @a = map { decode('UTF-8', $_) } @ARGV;
    while (@a) {
      my $x = shift @a;
      if    ($x eq '--csv')    { $argCsv = shift @a; }
      elsif ($x eq '--md')     { $argMd  = shift @a; }
      elsif ($x eq '--suffix') { $suffix = shift @a; }
    }
  }
  $suffix //= '';

  my $outCsv = $argCsv // $o{out_csv} // "$outDir/$name$suffix-raw.csv";
  my $outMd  = $argMd  // $o{out_md}  // "$outDir/$name$suffix-report.md";
  $outCsv = "$dir/$outCsv" unless $outCsv =~ m{^/};
  $outMd  = "$dir/$outMd"  unless $outMd  =~ m{^/};

  my @all;
  for my $q (@$queries) {
    my $span = $q->{a} ? " ($q->{a}-$q->{b})" : '';
    print "→ [" . ($q->{i} || 'all') . "] $q->{t}$span\n";

    my @res = search_ya_archive(
      text      => $q->{t},
      index     => $q->{i} // '',
      ($q->{a} ? (date_from => $q->{a}, date_to => $q->{b}) : ()),
      max_pages => $q->{pages} // $o{max_pages} // 4,
      ($q->{fuzzy} ? (fuzzy => 1) : ()),
    );
    @res = grep { defined } @res;     # undef = сервис не дал выдачу (см. предупреждение)

    print "   найдено: " . scalar(@res)
        . " (всего по запросу: " . (@res ? ($res[0]{Total} // '?') : 0) . ")\n";
    push @all, @res;
    nap($o{delay} // 600);
  }

  # Дедупликация по конкретной странице документа
  my (%seen, @uniq);
  for my $r (sort { $a->{Url} cmp $b->{Url} || $a->{Query} cmp $b->{Query} } @all) {
    next if $seen{ $r->{Url} }++;
    push @uniq, $r;
  }

  my @cols = qw(Query Index Date DateTo Source Snippet NodeId Page Url Total);
  csv_write($outCsv, \@uniq, \@cols);

  # Отбор релевантного. Обычно хватает all/any, но там, где правило сложнее
  # («то и это, либо вот это»), скрипт передаёт свою проверку в filter.
  my @hits = $o{filter}
    ? grep { $o{filter}->($_) } @uniq
    : grep { match_row($_, $fields, $o{all}, $o{any}) } @uniq;

  my @md;
  push @md, '# ' . ($o{title} // "Яндекс Архив — $name"), '';
  push @md, 'Прогон: ' . strftime('%Y-%m-%d %H:%M', localtime)
          . '. Запросов: ' . scalar(@$queries)
          . '. Уникальных страниц: ' . scalar(@uniq)
          . '. Релевантных: ' . scalar(@hits) . '.', '';

  for my $h (sort { sortable_date($a->{Date}) cmp sortable_date($b->{Date}) } @hits) {
    push @md, "## $h->{Date} — $h->{Source}", '';
    push @md, "> $h->{Snippet}", '';
    push @md, "[$h->{Url}]($h->{Url}) · запрос: `$h->{Query}` · раздел: $h->{Index}", '';
  }

  open(my $fh, '>:encoding(UTF-8)', fs($outMd)) or die "не пишется: $outMd\n";
  print $fh join("\n", @md);
  close $fh;

  print "\nГОТОВО. Уникальных: " . scalar(@uniq) . ", релевантных: " . scalar(@hits) . "\n";
  print "→ $outMd\n";

  return { uniq => \@uniq, hits => \@hits, csv => $outCsv, md => $outMd };
}

sub match_row {
  my ($row, $fields, $all, $any) = @_;
  my $text = join ' ', map { $row->{$_} // '' } @$fields;

  if ($all) {
    for my $rx (@$all) { return 0 unless $text =~ $rx; }
  }
  if ($any) {
    my @list = ref($any) eq 'ARRAY' ? @$any : ($any);
    my $ok = 0;
    for my $rx (@list) { $ok = 1, last if $text =~ $rx; }
    return 0 unless $ok;
  }
  return 1;
}

1;
