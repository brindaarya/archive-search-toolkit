#!/usr/bin/perl
# Поиск исторических фотографий на PastVu (pastvu.com) по описанию, координатам,
# месту или региону.
#
# Работает через открытый API https://pastvu.com/api2 (методы photo.giveNearestPhotos,
# photo.getByBounds, photo.givePS, photo.giveForPage, region.giveListPublic).
#
# ВАЖНО про «поиск по описанию»: полнотекстового поиска в API PastVu нет.
# Скрипт сначала выбирает снимки по географии (радиус / прямоугольник / регион),
# а затем фильтрует их по ключевым словам локально. Поэтому текстовый поиск всегда
# ограничен заданной областью и параметром --max-scan.
#
# Перенесено с PowerShell на macOS: Invoke-WebRequest → curl, ConvertFrom-Json → JSON::PP.
#
# Ключи:
#   --text «слово»      ключевые слова (можно несколько раз; они же — свободные аргументы)
#   --place «усадьба Быково»   место; координаты определит геокодер OpenStreetMap
#   --lat / --lon       координаты центра вручную
#   --radius 2000       радиус поиска в метрах (по умолчанию 2000)
#   --bbox «lat1,lon1,lat2,lon2»   прямоугольник
#   --region «Раменский городской округ»   регион PastVu целиком
#   --list-regions      показать список регионов (вместе с --region — отфильтровать)
#   --year-from / --year-to     годы съёмки
#   --type photo|painting|any   снимки или живопись
#   --match all|any     все слова или любое из них (по умолчанию all)
#   --regex             считать слова регулярными выражениями
#   --deep              читать карточку каждого снимка: описание, адрес, автор, источник
#   --comments          читать обсуждение под снимком
#   --limit 50          сколько выдать
#   --max-scan 1000     сколько просмотреть
#   --image-size d      размер ссылки на картинку: a d h m q s x
#   --csv путь / --json путь / --download-to папка
#
# Примеры:
#   perl Search-Pastvu.pl --place 'усадьба Быково' --radius 800
#   perl Search-Pastvu.pl --text церковь --place 'Быково, Раменский район' --radius 3000 --year-to 1950
#   perl Search-Pastvu.pl --text усадьб --region 'Раменский городской округ' --max-scan 2000 --csv usadby.csv
#   perl Search-Pastvu.pl --lat 55.6099 --lon 38.0583 --radius 500 --deep --text Баженов

use strict;
use warnings;
use utf8;
use Encode qw(decode);
use File::Basename qw(dirname basename);
use File::Spec;
use Cwd qw(abs_path);
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP;
use POSIX qw(floor ceil);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

require File::Spec->catfile(dirname(abs_path($0)), 'web-common.pl');

our $UserAgent = 'Search-Pastvu.pl/1.0 (personal archive research)';

my $ApiRoot  = 'https://pastvu.com/api2';
my $SiteRoot = 'https://pastvu.com';

# ---------------------------------------------------------------- ключи

my (@Text, $Place, $Lat, $Lon, $Bbox, $Region, $YearFrom, $YearTo);
my $Radius    = 2000;
my $Type      = 'any';
my $MatchMode = 'all';
my ($UseRegex, $Deep, $Comments, $ListRegions);
my $Limit     = 50;
my $MaxScan   = 1000;
my $ImageSize = 'd';
my ($CsvPath, $JsonPath, $DownloadTo);

my @argv = map { decode('UTF-8', $_) } @ARGV;
GetOptionsFromArray(\@argv,
  'text=s'        => \@Text,
  'place=s'       => \$Place,
  'lat=f'         => \$Lat,
  'lon=f'         => \$Lon,
  'radius=i'      => \$Radius,
  'bbox=s'        => \$Bbox,
  'region=s'      => \$Region,
  'year-from=i'   => \$YearFrom,
  'year-to=i'     => \$YearTo,
  'type=s'        => \$Type,
  'match=s'       => \$MatchMode,
  'regex'         => \$UseRegex,
  'deep'          => \$Deep,
  'comments'      => \$Comments,
  'limit=i'       => \$Limit,
  'max-scan=i'    => \$MaxScan,
  'image-size=s'  => \$ImageSize,
  'csv=s'         => \$CsvPath,
  'json=s'        => \$JsonPath,
  'download-to=s' => \$DownloadTo,
  'list-regions'  => \$ListRegions,
) or die "Непонятные ключи. Описание — в начале файла.\n";

push @Text, @argv;    # свободные аргументы тоже считаем ключевыми словами

# Годы и тип отдаём самому API там, где он их поддерживает
my $ApiYear  = $YearFrom;
my $ApiYear2 = $YearTo;
my $ApiType  = ($Type ne 'any') ? $Type : undef;

# ---------------------------------------------------------------- API

sub pastvu_api {
  my ($method, $params) = @_;
  my $json = JSON::PP->new->canonical->encode($params // {});
  my $uri  = "$ApiRoot?method=$method&params=" . url_encode($json);

  my $body = http_get($uri, headers => ['Accept: application/json'], timeout => 60);
  unless (defined $body) { warn "PastVu не отвечает ($method)\n"; return undef; }

  my $obj = from_json_text($body);
  return $obj->{result} if $obj && exists $obj->{result};

  warn "PastVu API ($method): " . (($obj && $obj->{message}) ? $obj->{message} : 'непонятный ответ') . "\n";
  return undef;
}

sub resolve_place {
  my ($query) = @_;
  my $uri = 'https://nominatim.openstreetmap.org/search?format=jsonv2&limit=5&accept-language=ru&q='
          . url_encode($query);
  my $hits = from_json_text(http_get($uri, timeout => 60));

  unless ($hits && @$hits) {
    die "Место «$query» геокодер не нашёл. Задайте --lat/--lon вручную.\n";
  }

  my $best = $hits->[0];
  print "Место: $best->{display_name}\n";
  print "Координаты: $best->{lat}, $best->{lon}\n";
  if (@$hits > 1) {
    print "Другие варианты геокодера:\n";
    print "  $_->{display_name} ($_->{lat}, $_->{lon})\n" for @$hits[1 .. $#$hits];
  }
  return { Lat => 0 + $best->{lat}, Lon => 0 + $best->{lon}, Name => $best->{display_name} };
}

# Гаверсинус, метры
sub distance_m {
  my ($lat1, $lon1, $lat2, $lon2) = @_;
  my $r  = 6371000.0;
  my $pi = 4 * atan2(1, 1);
  my $p1 = $lat1 * $pi / 180;
  my $p2 = $lat2 * $pi / 180;
  my $dp = ($lat2 - $lat1) * $pi / 180;
  my $dl = ($lon2 - $lon1) * $pi / 180;

  my $a = sin($dp / 2) ** 2 + cos($p1) * cos($p2) * sin($dl / 2) ** 2;
  return int($r * 2 * atan2(sqrt($a), sqrt(1 - $a)) + 0.5);
}

# ---------------------------------------------------------------- источники снимков

sub photos_by_radius {
  my ($clat, $clon, $radius, $max) = @_;
  my @collected;
  my $skip = 0;
  my $page_size = 30;    # предел API

  while (@collected < $max) {
    my %params = (geo => [0 + $clat, 0 + $clon], distance => $radius,
                  limit => $page_size, skip => $skip);
    $params{year}  = $ApiYear  if $ApiYear;
    $params{year2} = $ApiYear2 if $ApiYear2;
    $params{type}  = $ApiType  if $ApiType;

    my $res = pastvu_api('photo.giveNearestPhotos', \%params) or last;
    my @page = grep { $_ } @{ $res->{photos} // [] };
    last unless @page;

    push @collected, @page;
    print "  получено снимков: " . scalar(@collected) . "\r";
    last if @page < $page_size;

    $skip += $page_size;
    nap(200);
  }
  print "\n" if @collected;
  return @collected;
}

sub photos_by_bbox {
  my ($lat1, $lon1, $lat2, $lon2) = @_;
  my $south = $lat1 < $lat2 ? $lat1 : $lat2;
  my $north = $lat1 > $lat2 ? $lat1 : $lat2;
  my $west  = $lon1 < $lon2 ? $lon1 : $lon2;
  my $east  = $lon1 > $lon2 ? $lon1 : $lon2;

  # Кольцо против часовой стрелки, координаты в порядке [lon, lat]
  my $ring = [ [$west, $south], [$east, $south], [$east, $north], [$west, $north], [$west, $south] ];

  my %params = (
    z         => 17,     # с 17-го зума API отдаёт снимки, а не кластеры
    localWork => 1,
    geometry  => { type => 'Polygon', coordinates => [$ring] },
  );
  $params{year}      = $ApiYear  if $ApiYear;
  $params{year2}     = $ApiYear2 if $ApiYear2;
  $params{isPainting}= 1         if ($ApiType // '') eq 'painting';

  my $res = pastvu_api('photo.getByBounds', \%params) or return ();
  return grep { $_ } @{ $res->{photos} // [] };
}

# Справочник регионов весит несколько мегабайт, поэтому держим его месяц на диске
my $RegionCache;
sub region_list {
  return @$RegionCache if $RegionCache;

  my $cache_file = '/tmp/pastvu-regions.json';
  if (-e $cache_file && -M $cache_file < 30) {
    open(my $fh, '<:encoding(UTF-8)', $cache_file);
    local $/;
    my $cached = from_json_text(<$fh> // '');
    close $fh;
    if ($cached && $cached->{result}{regions} && @{ $cached->{result}{regions} }) {
      $RegionCache = $cached->{result}{regions};
      return @$RegionCache;
    }
  }

  print "Загружаю справочник регионов PastVu (один раз в месяц)...\n";
  my $body = http_get("$ApiRoot?method=region.giveListPublic&params=%7B%7D", timeout => 120);
  my $obj = from_json_text($body);
  $RegionCache = ($obj && $obj->{result}{regions}) ? $obj->{result}{regions} : [];

  if (@$RegionCache && open(my $out, '>:encoding(UTF-8)', $cache_file)) {
    print $out $body;
    close $out;
  }
  return @$RegionCache;
}

sub resolve_region {
  my ($name) = @_;
  my @all = region_list();

  my @exact = grep { ($_->{title_local} // '') eq $name || ($_->{title_en} // '') eq $name } @all;
  return $exact[0] if @exact;

  # Из частичных совпадений берём регион с наибольшим числом снимков
  my @like = sort { ($b->{phc} // 0) <=> ($a->{phc} // 0) }
             grep { index($_->{title_local} // '', $name) >= 0
                 || index($_->{title_en} // '', $name) >= 0 } @all;

  unless (@like) {
    die "Регион «$name» не найден. Список: perl Search-Pastvu.pl --list-regions --region <часть названия>\n";
  }
  if (@like > 1) {
    my @first = @like[0 .. ($#like > 4 ? 4 : $#like)];
    warn "Подходит несколько регионов, взят первый: "
       . join('; ', map { "$_->{title_local} ($_->{phc})" } @first) . "\n";
  }
  return $like[0];
}

sub photos_by_region {
  my ($cid, $max) = @_;

  my @parts = ("r!$cid");
  if ($ApiYear || $ApiYear2) {
    my $y1 = $ApiYear  || 1826;
    my $y2 = $ApiYear2 || (localtime)[5] + 1900;
    push @parts, "y!$y1!$y2";
  }
  push @parts, 't!1' if ($ApiType // '') eq 'photo';
  push @parts, 't!2' if ($ApiType // '') eq 'painting';
  my $filter = join '_', @parts;

  my @collected;
  my $skip = 0;
  my $total;

  while (@collected < $max) {
    my $take = ($max - @collected) < 100 ? ($max - @collected) : 100;
    my $res = pastvu_api('photo.givePS', { filter => $filter, limit => $take, skip => $skip }) or last;

    unless (defined $total) {
      $total = $res->{count} // 0;
      print "Снимков под фильтр: $total; будет просмотрено не более $max\n";
    }

    my @page = grep { $_ } @{ $res->{photos} // [] };
    last unless @page;

    # Цепочку регионов разворачиваем в читаемый путь
    for my $p (@page) {
      next unless $p->{rs} && $res->{rhash};
      my @names = grep { defined && length }
                  map  { $res->{rhash}{$_} ? $res->{rhash}{$_}{title_local} : undef } @{ $p->{rs} };
      $p->{regionPath} = join ' / ', @names;
    }

    push @collected, @page;
    print "  просмотрено: " . scalar(@collected) . " из $max\r";
    last if @page < $take;

    $skip += $take;
    nap(200);
  }
  print "\n" if @collected;
  return @collected;
}

# Комментарии приходят деревом — разворачиваем в плоский список по времени
sub comments_flat {
  my ($cid) = @_;
  my $r = pastvu_api('comment.giveForObj', { cid => 0 + $cid }) or return ();

  my @flat;
  my @stack = grep { $_ } @{ $r->{comments} // [] };
  my $guard = 5000;

  while (@stack && @flat < $guard) {
    my $c = pop @stack;
    next unless $c;

    my $name = $c->{user};
    if ($r->{users} && defined $c->{user} && $r->{users}{ $c->{user} }) {
      $name = $r->{users}{ $c->{user} }{disp} // $name;
    }
    push @flat, { Stamp => $c->{stamp} // 0, User => $name // '', Text => plain_text($c->{txt}) };

    push @stack, grep { $_ } @{ $c->{comments} } if $c->{comments};
  }
  warn "Снимок $cid: обсуждение обрезано на $guard комментариях\n" if @flat >= $guard;

  return sort { ($a->{Stamp} // 0) <=> ($b->{Stamp} // 0) } @flat;
}

sub photo_details {
  my ($cid) = @_;
  my $r = pastvu_api('photo.giveForPage', { cid => 0 + $cid }) or return undef;
  return $r->{photo};
}

# ---------------------------------------------------------------- фильтрация и вывод

sub text_match {
  my ($patterns, $haystack) = @_;
  return 1 unless $patterns && @$patterns;
  return 0 unless defined $haystack && length $haystack;

  my $hits = 0;
  for my $p (@$patterns) {
    my $needle = $UseRegex ? $p : quotemeta($p);
    $hits++ if $haystack =~ /$needle/i;
  }
  return $MatchMode eq 'all' ? ($hits == scalar @$patterns) : ($hits > 0);
}

# В описании, авторе и источнике PastVu хранит HTML
sub plain_text {
  my ($html) = @_;
  return '' unless defined $html && length $html;
  return html_to_text($html);
}

sub to_result {
  my ($photo, $details, $olat, $olon, $has_origin) = @_;

  my ($lat, $lon, $dist);
  my $geo = $photo->{geo};
  if ($geo && ref $geo eq 'ARRAY' && @$geo == 2) {
    ($lat, $lon) = @$geo;
    $dist = distance_m($olat, $olon, $lat, $lon) if $has_origin;
  }

  my $years = $photo->{year} // '';
  $years = "$photo->{year}-$photo->{year2}"
    if $photo->{year2} && $photo->{year} && $photo->{year2} ne $photo->{year};

  my %r = (
    Cid          => $photo->{cid} // '',
    Year         => $years,
    Title        => $photo->{title} // '',
    Distance     => (defined $dist ? $dist : ''),
    Lat          => (defined $lat ? $lat : ''),
    Lon          => (defined $lon ? $lon : ''),
    Region       => $photo->{regionPath} // '',
    CommentCount => 0 + ($photo->{ccount} // 0),
    Url          => "$SiteRoot/p/" . ($photo->{cid} // ''),
    Image        => "$SiteRoot/_p/$ImageSize/" . ($photo->{file} // ''),
  );
  if ($details) {
    $r{Description} = plain_text($details->{desc});
    $r{Address}     = plain_text($details->{address});
    $r{Author}      = plain_text($details->{author});
    $r{Source}      = plain_text($details->{source});
  }
  return \%r;
}

sub ensure_parent {
  my ($path) = @_;
  my $parent = dirname($path);
  return if !$parent || -d fs($parent);
  system('mkdir', '-p', fs($parent));
}

sub safe_filename {
  my ($name) = @_;
  $name = '' unless defined $name;
  $name =~ s{[/\\:*?"<>|]}{_}g;
  $name =~ s/^\s+|\s+$//g;
  $name = substr($name, 0, 80) if length($name) > 80;
  return length($name) ? $name : 'photo';
}

# ---------------------------------------------------------------- основной сценарий

if ($ListRegions) {
  my @list = region_list();
  @list = grep { index($_->{title_local} // '', $Region) >= 0
              || index($_->{title_en} // '', $Region) >= 0 } @list if $Region;

  printf("%-8s %-45s %-30s %s\n", 'Cid', 'Регион', 'English', 'Снимков');
  for my $r (sort { ($b->{phc} // 0) <=> ($a->{phc} // 0) } @list) {
    printf("%-8s %-45s %-30s %s\n",
           $r->{cid} // '', $r->{title_local} // '', $r->{title_en} // '', $r->{phc} // 0);
  }
  exit 0;
}

my $has_coords = defined($Lat) && defined($Lon);
my ($origin_lat, $origin_lon, $has_origin) = (0, 0, 0);
my (@photos, $mode);

if ($Bbox) {
  my @nums = grep { length } split /[,;\s]+/, $Bbox;
  die "Прямоугольник задаётся как «lat1,lon1,lat2,lon2».\n" unless @nums == 4;
  $mode = 'прямоугольник';
  $origin_lat = ($nums[0] + $nums[2]) / 2;
  $origin_lon = ($nums[1] + $nums[3]) / 2;
  $has_origin = 1;
  @photos = photos_by_bbox(@nums);
}
elsif ($has_coords || $Place) {
  if ($has_coords) { ($origin_lat, $origin_lon) = ($Lat, $Lon); }
  else {
    my $g = resolve_place($Place);
    ($origin_lat, $origin_lon) = ($g->{Lat}, $g->{Lon});
  }
  $has_origin = 1;
  $mode = "радиус $Radius м вокруг $origin_lat, $origin_lon";
  @photos = photos_by_radius($origin_lat, $origin_lon, $Radius, $MaxScan);
}
elsif ($Region) {
  my $reg = resolve_region($Region);
  print "Регион: $reg->{title_local} (cid $reg->{cid}, снимков в базе " . ($reg->{phc} // 0) . ")\n";
  $mode = "регион «$reg->{title_local}»";
  @photos = photos_by_region($reg->{cid}, $MaxScan);
}
elsif (@Text) {
  warn "Область не задана — просмотрю только последние загрузки всей базы.\n"
     . "Точнее будет с --place, --lat/--lon, --bbox или --region.\n";
  $mode = 'вся база, последние загрузки';
  @photos = photos_by_region(0, $MaxScan);
}
else {
  die "Нечего искать: задайте --text и/или область (--place, --lat/--lon, --bbox, --region).\n";
}

print "Просмотрено снимков: " . scalar(@photos) . " ($mode)\n";

# Годы дофильтровываем на своей стороне: getByBounds их учитывает не всегда строго
my @candidates = grep {
  my $y = $_->{year};
  !( ($ApiYear  && $y && $y < $ApiYear)
  || ($ApiYear2 && $y && $y > $ApiYear2) );
} @photos;

# Карточки нужны заранее только если по ним идёт текстовый поиск
my $deep_search = ($Deep && @Text) ? 1 : 0;
if ($deep_search) {
  printf("Режим --deep: читаю %d карточек, это примерно %d с\n",
         scalar(@candidates), ceil(scalar(@candidates) * 0.4));
}

my @results;
my $i = 0;
for my $p (@candidates) {
  $i++;
  my $details;
  my $haystack = $p->{title} // '';

  if ($deep_search) {
    print "  карточка $i из " . scalar(@candidates) . "\r";
    $details = photo_details($p->{cid});
    if ($details) {
      $haystack = join ' | ', map { $_ // '' }
                  @{$details}{qw(title desc address author source)};
    }
    nap(150);
  }

  next unless text_match(\@Text, $haystack);
  push @results, to_result($p, $details, $origin_lat, $origin_lon, $has_origin);

  # Без географии порядок выдачи и так финальный — можно остановиться раньше
  last if !$has_origin && !$deep_search && @results >= $Limit;
}
print "\n" if $deep_search;

if ($has_origin) {
  @results = sort { (length($a->{Distance}) ? $a->{Distance} : 9**9)
                <=> (length($b->{Distance}) ? $b->{Distance} : 9**9) } @results;
} else {
  @results = sort { ($a->{Year} // '') cmp ($b->{Year} // '') } @results;
}
@results = @results[0 .. ($Limit - 1)] if @results > $Limit;

# --deep без --text: карточки догружаем уже только для итоговой выдачи
if ($Deep && !@Text && @results) {
  print "Читаю карточки для " . scalar(@results) . " снимков\n";
  for my $r (@results) {
    my $d = photo_details($r->{Cid}) or next;
    $r->{Description} = plain_text($d->{desc});
    $r->{Address}     = plain_text($d->{address});
    $r->{Author}      = plain_text($d->{author});
    $r->{Source}      = plain_text($d->{source});
    nap(150);
  }
}

if ($Comments && @results) {
  my @with = grep { $_->{CommentCount} > 0 } @results;
  print "Читаю комментарии к " . scalar(@with) . " снимкам\n";
  for my $r (@with) {
    my @threads = comments_flat($r->{Cid});
    $r->{Comments} = join ' ¶ ', map { "$_->{User}: $_->{Text}" } @threads;
    nap(150);
  }
}

print "Найдено: " . scalar(@results) . "\n";

# Колонки: базовые всегда, остальные — если что-то догружали
my @cols = qw(Cid Year Title Distance Lat Lon Region CommentCount Url Image);
push @cols, qw(Description Address Author Source) if grep { exists $_->{Description} } @results;
push @cols, 'Comments' if grep { exists $_->{Comments} } @results;

if ($CsvPath) {
  ensure_parent($CsvPath);
  csv_write($CsvPath, \@results, \@cols);
  print "CSV: $CsvPath\n";
}

if ($JsonPath) {
  ensure_parent($JsonPath);
  open(my $fh, '>:encoding(UTF-8)', fs($JsonPath)) or die "не пишется: $JsonPath\n";
  print $fh JSON::PP->new->pretty->canonical->encode(\@results);
  close $fh;
  print "JSON: $JsonPath\n";
}

if ($DownloadTo) {
  system('mkdir', '-p', fs($DownloadTo)) unless -d fs($DownloadTo);
  for my $r (@results) {
    my $name = sprintf('%s_%s_%s.jpg', $r->{Cid}, $r->{Year}, safe_filename($r->{Title}));
    my $size = http_download($r->{Image}, "$DownloadTo/$name", timeout => 120);
    warn "Не скачалось $r->{Cid}\n" unless $size;
    nap(200);
  }
  print "Изображения: $DownloadTo\n";
}

# Короткая сводка на экран
for my $r (@results) {
  my $d = length($r->{Distance}) ? " · $r->{Distance} м" : '';
  print "$r->{Year}  $r->{Title}$d\n    $r->{Url}\n";
}
