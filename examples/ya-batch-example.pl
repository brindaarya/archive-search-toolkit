#!/usr/bin/perl
# ПРИМЕР пакетного прогона (замените запросы, имя и фильтр на свои).
# Исходная задача — детская колония в усадьбе Быково (ст. Быково
# Московско-Казанской ж.д., бывшее имение Воронцовых-Дашковых / Ильиных).
# Результат: results/bykovo-raw.csv + results/bykovo-report.md
#
# Запуск:  perl examples/ya-batch-example.pl

use strict;
use warnings;
use utf8;
use Encode qw(decode);
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

my $here = decode('UTF-8', dirname(abs_path($0)));
require File::Spec->catfile(dirname(abs_path($0)), '..', 'tools', 'perl', 'ya-archive.pl');
require File::Spec->catfile(dirname(abs_path($0)), '..', 'tools', 'perl', 'ya-batch.pl');

# Каждый запрос: текст, раздел, окно лет
my @queries = (
  { t => 'детская колония Быково',                 i => '', a => 1917, b => 1935 },
  { t => 'колония дача Воронцова-Дашкова Быково',  i => '', a => 1917, b => 1935 },
  { t => 'колония имени Ильиной Быково',           i => '', a => 1917, b => 1935 },
  { t => 'Быковская детская колония',              i => '', a => 1917, b => 1935 },
  { t => 'колония детей красноармейцев Быково',    i => '', a => 1917, b => 1935 },
  { t => 'детский дом Быково Московско-Казанской', i => '', a => 1917, b => 1935 },
  { t => 'усадьба Быково Марьино колония',         i => '', a => 1917, b => 1940 },
  { t => 'станция Быково колония школа',           i => '', a => 1918, b => 1930 },
  { t => 'детская колония Быково',                 i => 'archive',    a => 1917, b => 1935 },
  { t => 'Быковская волость колония дети',         i => 'archive',    a => 1917, b => 1930 },
  { t => 'детская колония Быково',                 i => 'books' },
);

run_ya_batch(
  dir     => $here,
  name    => 'bykovo',
  title   => 'Яндекс Архив — детская колония в усадьбе Быково',
  queries => \@queries,
  # оставляем то, где реально фигурирует Быково или владельцы усадьбы
  fields  => ['Snippet', 'Source'],
  any     => qr/Быков|Воронцов|Ильин|Марьин/,
);
