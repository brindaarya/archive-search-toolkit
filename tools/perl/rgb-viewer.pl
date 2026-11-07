#!/usr/bin/perl
# rgb-viewer.pl — чтение оцифрованных документов РГБ через публичный API просмотрщика viewer.rsl.ru.
#
# Что умеет:
#   info  <ID>                       сведения о документе: название, число страниц, доступ, есть ли текстовый слой
#   pages <ID> --page 1,3,5-7        сохранить страницы как JPEG (для чтения глазами)
#   text  <ID> <N>                   распознанный текст страницы — только если у документа есть текстовый слой
#
# <ID> — номер из адреса просмотрщика: viewer.rsl.ru/ru/rsl01004892721 → 01004892721 (можно с «rsl» или целой ссылкой).
#
# Что НЕ умеет и почему:
#   * ПОИСК по РГБ (search.rsl.ru) — это клиентское приложение, публичного API мы не знаем; ищите в браузере
#     (см. docs/03-источники.md, раздел про РГБ).
#   * Документы с закрытым доступом, с обязательной авторизацией или «только в читальном зале»: скрипт проверяет
#     `info` и честно отказывается. Закрытое не обходим.
#   * Скачивать документ целиком: правила РГБ запрещают скачивание (isDownloadable: false у таких документов),
#     поэтому за один запуск сохраняется не больше --limit страниц (по умолчанию 40), между страницами пауза.
#     Это инструмент чтения нужных листов, а не копирования фонда.
#
# Проверено 5 ноября 2026 на описи ф. 814 «Ильины» (760 страниц, accessLevel: free, текстового слоя нет).
# У оцифрованных описей текстового слоя обычно нет: страница отдаётся только картинкой, читать приходится глазами.
#
# Запуск:
#   perl rgb-viewer.pl info 01004892721
#   perl rgb-viewer.pl pages 01004892721 --page 7,9,15 --out-dir ф814
#   perl rgb-viewer.pl text <ID> 12
#
# Ключи: --page 1,3,5-7 (обязателен для pages), --out-dir (по умолчанию ргб-сканы), --prefix, --limit N (40),
#        --delay мс (1500), --root URL (по умолчанию https://viewer.rsl.ru; нужен для проверки без сети)

use strict;
use warnings;
use utf8;
use Encode qw(decode);
use File::Basename qw(dirname);
use File::Spec;
use File::Path qw(make_path);
use Cwd qw(abs_path);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
require File::Spec->catfile(dirname(abs_path($0)), 'web-common.pl');

my @args = map { decode('UTF-8', $_) } @ARGV;
my %o = (root => 'https://viewer.rsl.ru', out_dir => 'ргб-сканы', prefix => '', limit => 40, delay => 1500);
my @pos;
while (@args) {
  my $a = shift @args;
  if    ($a eq '--page')    { $o{page} = shift @args; }
  elsif ($a eq '--out-dir') { $o{out_dir} = shift @args; }
  elsif ($a eq '--prefix')  { $o{prefix} = shift @args; }
  elsif ($a eq '--limit')   { $o{limit} = shift @args; }
  elsif ($a eq '--delay')   { $o{delay} = shift @args; }
  elsif ($a eq '--root')    { $o{root} = shift @args; $o{root} =~ s{/$}{}; }
  else                      { push @pos, $a; }
}
my $cmd = shift @pos // '';
my $raw_id = shift @pos // '';
die "Использование: perl rgb-viewer.pl info|pages|text <ID> ...\n" unless $cmd && $raw_id;

my ($id) = $raw_id =~ /(?:rsl)?(\d{6,})/;
die "Не разобрал ID документа: $raw_id\n" unless defined $id;
my $doc = "rsl$id";
my $api = "$o{root}/api/v1/document/$doc";
my $referer = "$o{root}/ru/$doc";

sub get_info {
  my $json = http_get("$api/info", referer => $referer, timeout => 60, retries => 2);
  die "РГБ не отдала сведения о документе $doc (неверный ID или сервис недоступен)\n" unless defined $json;
  return from_json_text($json) // die "РГБ вернула не JSON для $doc\n";
}

# Читать можно только открытое: иначе отказываем и объясняем причину
sub check_open {
  my ($i) = @_;
  my @why;
  push @why, 'документ недоступен онлайн' unless $i->{isAvailable};
  push @why, 'нужна авторизация' if $i->{isAuthorizationRequired};
  push @why, 'нужна проверка через Госуслуги' if $i->{isGosuslugiVerificationRequired};
  push @why, "уровень доступа «$i->{accessLevel}», не free" if defined $i->{accessLevel} && $i->{accessLevel} ne 'free';
  return @why;
}

sub allowed_page {
  my ($i, $n) = @_;
  my $ranges = $i->{viewAccess}{availablePdfPages};
  return 1 unless $ranges && @$ranges;
  for my $r (@$ranges) { return 1 if $n >= $r->{min} && $n <= $r->{max}; }
  return 0;
}

my $info = get_info();

if ($cmd eq 'info') {
  my $d = $info->{description} || {};
  print "Документ $doc\n";
  print "  автор/заглавие: " . join(' — ', grep { defined && length } ($d->{author}, $d->{title})) . "\n";
  print "  страниц: " . ($info->{pageCount} // '?') . "\n";
  print "  доступ: " . ($info->{accessLevel} // '?') . ", авторизация: " . ($info->{isAuthorizationRequired} ? 'нужна' : 'не нужна') . "\n";
  print "  текстовый слой: " . ($info->{hasTextLayer} ? 'есть' : 'нет') . ", поиск по тексту: " . ($info->{isSearchable} ? 'есть' : 'нет') . "\n";
  print "  скачивание: " . (($info->{downloadAccess}{isDownloadable}) ? 'разрешено' : 'запрещено') . "\n";
  my @r = map { "$_->{min}–$_->{max}" } @{ $info->{viewAccess}{availablePdfPages} || [] };
  print "  доступные страницы: " . (@r ? join(', ', @r) : 'не указаны') . "\n";
  my @why = check_open($info);
  print @why ? "  ВНИМАНИЕ, читать онлайн нельзя: " . join('; ', @why) . "\n" : "  читать онлайн можно\n";
  print "  просмотрщик: $referer\n";
  exit 0;
}

my @why = check_open($info);
die "Читать этот документ онлайн нельзя: " . join('; ', @why) . ".\nПриходить за ним нужно в читальный зал.\n" if @why;

if ($cmd eq 'text') {
  my $n = shift @pos or die "Укажите номер страницы: perl rgb-viewer.pl text <ID> 12\n";
  die "У документа нет текстового слоя: страницы только картинками (команда pages), читать глазами.\n" unless $info->{hasTextLayer};
  die "Страница $n вне доступных\n" unless allowed_page($info, $n);
  my $json = http_get("$api/page/$n/text", referer => $referer, timeout => 60, retries => 2);
  my $d = from_json_text($json // '');
  print(($d && defined $d->{text}) ? "$d->{text}\n" : ($json // "нет ответа\n"));
  exit 0;
}

if ($cmd eq 'pages') {
  die "Укажите страницы: --page 7,9,15 или 5-8\n" unless $o{page};
  my @pages;
  for my $part (split /,/, $o{page}) {
    if ($part =~ /^(\d+)-(\d+)$/) { push @pages, $1 .. $2 } elsif ($part =~ /^\d+$/) { push @pages, $part }
  }
  die "Не разобрал список страниц: $o{page}\n" unless @pages;
  if (@pages > $o{limit}) {
    warn "Запрошено " . scalar(@pages) . " страниц, за один запуск берём первые $o{limit} (--limit): РГБ запрещает скачивание документов целиком.\n";
    splice(@pages, $o{limit});
  }
  make_path(fs($o{out_dir})) unless -d fs($o{out_dir});
  my $total = $info->{pageCount};
  for my $n (@pages) {
    if ($n < 1 || ($total && $n > $total) || !allowed_page($info, $n)) { warn "  стр. $n — вне доступных, пропускаю\n"; next; }
    my $name = $o{prefix} ne '' ? sprintf('%s-стр%03d.jpg', $o{prefix}, $n) : sprintf('%s-стр%03d.jpg', $doc, $n);
    my $file = File::Spec->catfile($o{out_dir}, $name);
    if (-s fs($file)) { print "  стр. $n — уже есть: $name\n"; next; }
    my $size = http_download("$api/page/$n", $file, referer => $referer, timeout => 120);
    my $ok = 0;
    if ($size && open(my $fh, '<:raw', fs($file))) { read($fh, my $magic, 3); close $fh; $ok = ($magic eq "\xFF\xD8\xFF"); }
    if (!$ok) { unlink fs($file); warn "  стр. $n — не скачалась или пришло не изображение\n"; }
    else      { printf "  стр. %-4s -> %s (%s б)\n", $n, $name, $size; }
    nap($o{delay});
  }
  exit 0;
}

die "Неизвестная команда «$cmd». Доступны: info, pages, text\n";
