#!/usr/bin/perl
# goskatalog.pl — доступ к Госкаталогу Музейного фонда РФ (goskatalog.ru) без браузера и входа.
#
# Перенос goskatalog.ps1 на Perl (PowerShell на Mac и Linux по умолчанию нет).
# Портал — обёртка над открытым REST API:
#   POST /muzfo-rest/rest/exhibits/ext   поиск (фильтры в строке запроса, критерии — JSON-массив в теле)
#   GET  /muzfo-rest/rest/exhibits/{id}  полная карточка
#   GET  /muzfo-imaginator/rest/images/public/{size}/{id}/{id}.jpg   изображение
#   POST /ai-search/by_image             похожие предметы по картинке
#
# Особенности API (добыты опытом):
#   * тело запроса — JSON-МАССИВ критериев; {} даёт 400, [] можно;
#   * подсчёт общего числа (--total) и фильтры без текста ставят сервер в таймаут;
#   * полнотекстовый поиск нечёткий («Быково» подмешивает «Быковского»): сужайте запрос;
#   * публичные копии изображений — примерно до 1024 px, оригиналы наружу не отдаются.
#
# Команды:
#   perl goskatalog.pl search 'усадьба Быково' --with-image --max 200 [--details]
#            [--name X] [--author X] [--technology X] [--typology фотографии] [--museum-id 2732,100]
#            [--gik 'ГНИМА НФ-ОФ-1348/254'] [--inv X] [--reg N] [--total]
#            [--csv файл.csv] [--gallery файл.html] [--download папка [--all] [--size 2000]]
#   perl goskatalog.pl item 12345 67890            полная карточка (описание, датировка, размеры)
#   perl goskatalog.pl museum --name Щусева [--city Раменское]
#   perl goskatalog.pl typology                    типы предметов
#   perl goskatalog.pl by-image фото.jpg [--gallery файл.html]    визуально похожие предметы
#
# Справочники (музеи, типология) лежат в cache/ рядом со скриптом и обновляются раз в 30 дней.

use strict;
use warnings;
use utf8;
use Encode qw(decode encode);
use File::Basename qw(dirname);
use File::Spec;
use File::Path qw(make_path);
use Cwd qw(abs_path);
use JSON::PP;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
my $here = dirname(abs_path($0));
require File::Spec->catfile($here, 'web-common.pl');

my $Base = 'https://goskatalog.ru';
my @Headers = ('Accept-Language: ru-RU,ru;q=0.9');
my $Referer = 'https://goskatalog.ru/portal/';
my $CacheDir = File::Spec->catdir($here, 'cache');
my $Published = 6;     # statusId 6 = «в реестре», то же, что видно на сайте

# --------------------------------------------------------------------- сеть

sub query_string {
  my ($q) = @_;
  return join '&', map { "$_=" . url_encode($q->{$_}) } grep { defined $q->{$_} && $q->{$_} ne '' } sort keys %$q;
}

sub gk_post {
  my ($path, $query, $criteria, $timeout) = @_;
  my $url = $Base . $path . '?' . query_string($query);
  my $body = '[' . join(',', map { JSON::PP->new->utf8(0)->canonical->encode($_) } @{ $criteria || [] }) . ']';
  my $resp = http_get($url, post => $body, content_type => 'application/json',
                      headers => \@Headers, referer => $Referer, timeout => $timeout || 120, retries => 2);
  die "Госкаталог не ответил: $path\n" unless defined $resp;
  return from_json_text($resp) // die "Госкаталог вернул не JSON: $path\n";
}

sub gk_get {
  my ($path, $timeout) = @_;
  my $resp = http_get($Base . $path, headers => \@Headers, referer => $Referer, timeout => $timeout || 120, retries => 2);
  die "Госкаталог не ответил: $path\n" unless defined $resp;
  return from_json_text($resp) // die "Госкаталог вернул не JSON: $path\n";
}

# --------------------------------------------------------------------- справочники

sub cached_json {
  my ($name, $path) = @_;
  make_path(fs($CacheDir)) unless -d fs($CacheDir);
  my $file = File::Spec->catfile($CacheDir, "$name.json");
  my $stale = !-e fs($file) || (-M fs($file)) > 30;
  if ($stale) {
    my $txt = http_get($Base . $path, headers => \@Headers, referer => $Referer, timeout => 180, retries => 2);
    die "не скачался справочник $name\n" unless defined $txt;
    open(my $fh, '>:encoding(UTF-8)', fs($file)) or die "не пишется $file\n";
    print $fh $txt; close $fh;
  }
  open(my $fh, '<:encoding(UTF-8)', fs($file)) or die "не читается $file\n";
  local $/; my $t = <$fh>; close $fh;
  return from_json_text($t);
}

my ($MuseumMap, $TypologyMap);
sub museum_map {
  return $MuseumMap if $MuseumMap;
  my $d = cached_json('museums', '/muzfo-rest/rest/museums?cacheEnabled=true');
  $MuseumMap = { map { $_->{id} => $_ } @{ $d->{museums} || [] } };
  return $MuseumMap;
}

sub typology_list {
  my $d = cached_json('dicts', '/muzfo-rest/rest/dicts');
  return sort { $a->{id} <=> $b->{id} } @{ $d->{typology} || [] };
}

sub typology_map {
  return $TypologyMap if $TypologyMap;
  $TypologyMap = { map { $_->{id} => $_->{name} } typology_list() };
  return $TypologyMap;
}

sub resolve_typology {
  my ($v) = @_;
  return undef unless defined $v && length $v;
  return $v + 0 if $v =~ /^\d+$/;
  my @all = typology_list();
  my @hit = grep { index(lc $_->{name}, lc $v) >= 0 } @all;
  return $hit[0]{id} if @hit == 1;
  die "Типология «$v» не найдена. Доступно: " . join('; ', map { $_->{name} } @all) . "\n" unless @hit;
  die "Типология «$v» неоднозначна: " . join('; ', map { $_->{name} } @hit) . "\n";
}

# --------------------------------------------------------------------- предметы

sub img_url {
  my ($id, $size) = @_;
  return "$Base/muzfo-imaginator/rest/images/public/$size/$id/$id.jpg";
}

sub to_item {
  my ($o, $full) = @_;
  my @img = map { $_->{id} } grep { !$_->{deleted} } @{ $o->{images} || [] };
  my $main = ($o->{mainImage} && $o->{mainImage}{id}) ? $o->{mainImage}{id} : $img[0];
  $main = $img[0] if $full;
  my $m = museum_map()->{ $o->{museumId} // '' };
  my $item = {
    Id => $o->{id}, Name => $o->{name} // '', Museum => $m ? $m->{name} : '', MuseumId => $o->{museumId} // '',
    Typology => typology_map()->{ $o->{typologyId} // '' } // '',
    Authors => join('; ', map { $_->{name} } @{ $o->{authors} || [] }),
    Technologies => join(', ', map { $_->{name} } @{ $o->{technologies} || [] }),
    RegNumber => $o->{regNumber} // '', GikNumber => $o->{gikNumber} // '',
    ImageCount => scalar(@img), ImageId => $main, ImageIds => \@img,
    Thumb => $main ? img_url($main, 350) : '', Image => $main ? img_url($main, 2000) : '',
    Url => "$Base/portal/#/collections?id=$o->{id}",
  };
  if ($full) {
    $item->{Description} = $o->{description} // '';  $item->{Period} = $o->{periodStr} // '';
    $item->{Dimensions} = $o->{dimStr} // '';        $item->{ProductionPlace} = $o->{productionPlace} // '';
    $item->{FindPlace} = $o->{findPlace} // '';
  }
  return $item;
}

sub criterion {
  my ($field, $value, %o) = @_;
  return { fieldName => $field, fieldType => $o{type} // 'String', operator => $o{op} // 'CONTAINS',
           fromValue => undef, toValue => undef, value => $value };
}

sub search_gk {
  my (%o) = @_;
  my @crit;
  push @crit, criterion('name', $o{name})               if $o{name};
  push @crit, criterion('authors', $o{author})          if $o{author};
  push @crit, criterion('producers', $o{producer})      if $o{producer};
  push @crit, criterion('technologies', $o{technology}) if $o{technology};
  push @crit, criterion('gikNumber', $o{gik}, op => 'EQUALS') if $o{gik};
  push @crit, criterion('invNumber', $o{inv}, op => 'EQUALS') if $o{inv};
  push @crit, criterion('regNumber', $o{reg} + 0, type => 'Number', op => 'EQUALS') if $o{reg};

  my %qp = (statusIds => $Published, publicationLimit => 'false', calcCountsType => 0,
            sortFields => 'id', dirFields => 'desc');
  $qp{q} = $o{query} if $o{query};
  $qp{museumIds} = $o{museum_id} if $o{museum_id};
  $qp{typologyId} = resolve_typology($o{typology}) if $o{typology};
  $qp{imageExists} = 'true'  if $o{with_image};
  $qp{imageExists} = 'false' if $o{no_image};

  warn "Запрос без текстовых условий — сервер может отвечать очень долго.\n" unless $o{query} || @crit;

  if ($o{total}) {
    my %cq = (%qp, calcCountsType => 1, limit => 0, offset => 0);
    delete @cq{qw(sortFields dirFields)};
    my $c = eval { gk_post('/muzfo-rest/rest/exhibits/ext', \%cq, \@crit, 120) };
    if ($c) { print "Всего совпадений: " . ($c->{statistics}[0]{count} // '?') . "\n" }
    else    { warn "Подсчёт не удался (обычно таймаут сервера)\n" }
  }

  my ($offset, @out) = (0);
  my $max = $o{max} || 100;
  while (@out < $max) {
    my $take = $max - @out; $take = 100 if $take > 100;
    my $r = gk_post('/muzfo-rest/rest/exhibits/ext', { %qp, limit => $take, offset => $offset }, \@crit, 120);
    my @objs = @{ $r->{objects} || [] };
    last unless @objs;
    push @out, map { to_item($_) } @objs;
    $offset += @objs;
    last if @objs < $take;
    nap(300);
  }
  return @out;
}

sub get_item {
  my ($id) = @_;
  my $d = gk_get("/muzfo-rest/rest/exhibits/$id");
  $d->{id} //= $id;
  return to_item($d, 1);
}

# --------------------------------------------------------------------- изображения

sub slug {
  my ($t) = @_;
  return 'item' unless defined $t && length $t;
  $t =~ s{[\\/:*?"<>|]}{ }g; $t =~ s/\s+/ /g; $t =~ s/^\s+|\s+$//g;
  $t = substr($t, 0, 60) if length $t > 60;
  $t =~ s/\s+$//;
  return length $t ? $t : 'item';
}

# -f: на 404 curl не сохраняет страницу ошибки в файл
sub download_image {
  my ($url, $file) = @_;
  my @cmd = ('curl', '-sS', '-f', '-L', '--max-time', 180, '-A', $main::UserAgent, '-H', 'Accept-Language: ru-RU,ru;q=0.9',
             '-e', $Referer, '-o', fs($file), $url);
  my $rc = system(@cmd);
  if ($rc != 0 || !-s fs($file)) { unlink fs($file); return 0; }
  return 1;
}

sub save_images {
  my ($items, $dir, %o) = @_;
  make_path(fs($dir)) unless -d fs($dir);
  my ($n, $skipped, $failed) = (0, 0, 0);
  my $size = $o{size} || 2000;
  for my $it (@$items) {
    my @ids = ($o{all} && @{ $it->{ImageIds} || [] }) ? @{ $it->{ImageIds} } : ($it->{ImageId} ? ($it->{ImageId}) : ());
    next unless @ids;
    my $i = 0;
    for my $img (@ids) {
      $i++;
      my $suffix = @ids > 1 ? "-$i" : '';
      my $file = File::Spec->catfile($dir, "$it->{Id}$suffix " . slug($it->{Name}) . '.jpg');
      if (-e fs($file) && !$o{force}) { $skipped++; next; }
      my $ok = download_image(img_url($img, $size), $file);
      $ok = download_image(img_url($img, 350), $file) if !$ok && $size != 350;     # крупной копии может не быть
      if ($ok) { $n++; print "  $file\n"; } else { $failed++; warn "Не скачалось $img ($it->{Id})\n"; }
      nap(250);
    }
  }
  print "Скачано: $n, пропущено (уже есть): $skipped, ошибок: $failed\n";
}

sub search_by_image {
  my ($path) = @_;
  die "Файл не найден: $path\n" unless -f fs($path);
  my @cmd = ('curl', '-sS', '-L', '--max-time', 180, '-A', $main::UserAgent, '-e', $Referer,
             '-F', 'image=@"' . fs($path) . '";filename=query.jpg;type=image/jpeg',   # кавычки: запятая и ; в имени файла иначе ломают -F
             "$Base/ai-search/by_image?collection_types=PUBLIC");
  open(my $ph, '-|', @cmd) or die "curl не запустился\n";
  binmode($ph, ':raw'); local $/; my $raw = <$ph> // ''; close $ph;
  my $j = from_json_text(decode('UTF-8', $raw)) or die "Поиск по картинке не вернул JSON\n";
  if ($j->{predicted_classes} && @{ $j->{predicted_classes} }) {
    print 'ИИ считает, что это: ' . join(', ', map { sprintf('%s (%.0f%%)', $_->{category_name}, $_->{category_probability} * 100) } @{ $j->{predicted_classes} }) . "\n";
  }
  return map {
    { Id => $_->{nearest_parent_id}, Name => $_->{item_name} // '', Similarity => sprintf('%.1f', $_->{mean_similarity_score} * 100),
      Category => $_->{item_category} // '', ImageId => $_->{nearest_image_id}, ImageIds => [ $_->{nearest_image_id} ],
      Thumb => img_url($_->{nearest_image_id}, 350), Image => img_url($_->{nearest_image_id}, 2000),
      Url => "$Base/portal/#/collections?id=$_->{nearest_parent_id}", Museum => '', GikNumber => '', RegNumber => '' }
  } @{ $j->{items} || [] };
}

# --------------------------------------------------------------------- вывод

sub h { my $s = shift // ''; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g; return $s; }

sub export_gallery {
  my ($items, $path, $title) = @_;
  $title ||= 'Госкаталог — результаты поиска';
  my $cards = join "\n", map {
    my $it = $_;
    my $thumb = $it->{Thumb} ? sprintf('<a href="%s" target="_blank"><img loading="lazy" src="%s" alt=""></a>', h($it->{Image}), h($it->{Thumb}))
                             : '<div class="noimg">без изображения</div>';
    my @meta;
    push @meta, "похоже на $it->{Similarity}%" if $it->{Similarity};
    push @meta, map { h($it->{$_}) } grep { $it->{$_} } qw(Period Authors Technologies Dimensions);
    qq{<figure>$thumb<figcaption><a class="ttl" href="} . h($it->{Url}) . qq{" target="_blank">} . h($it->{Name}) . '</a>'
      . '<div class="meta">' . join(' · ', @meta) . '</div><div class="mus">' . h($it->{Museum}) . '</div>'
      . '<div class="num">' . h($it->{GikNumber}) . ' &nbsp; № ' . h($it->{RegNumber}) . '</div></figcaption></figure>'
  } @$items;
  my $n = @$items;
  my @t = localtime;
  my $stamp = sprintf('%02d.%02d.%04d %02d:%02d', $t[3], $t[4] + 1, $t[5] + 1900, $t[2], $t[1]);
  my $html = <<"HTML";
<!doctype html>
<meta charset="utf-8">
<title>${\ h($title)}</title>
<style>
  body { font: 14px/1.45 -apple-system, "Segoe UI", Roboto, sans-serif; margin: 24px; background:#fafaf8; color:#1c1b19; }
  h1 { font-size: 20px; font-weight: 600; margin: 0 0 4px; } .sub { color:#6b6862; margin-bottom: 20px; }
  .grid { display:grid; grid-template-columns: repeat(auto-fill, minmax(230px,1fr)); gap:18px; }
  figure { margin:0; background:#fff; border:1px solid #e6e3dd; border-radius:6px; overflow:hidden; }
  figure img { width:100%; height:200px; object-fit:cover; display:block; background:#f0eeea; }
  .noimg { height:200px; display:flex; align-items:center; justify-content:center; color:#a8a49c; background:#f0eeea; font-size:12px; }
  figcaption { padding:10px 12px 12px; } .ttl { display:block; color:#1c1b19; text-decoration:none; font-weight:600; margin-bottom:5px; }
  .meta { color:#57534d; font-size:12px; } .mus { color:#6b6862; font-size:12px; margin-top:5px; } .num { color:#a8a49c; font-size:11px; margin-top:3px; }
</style>
<h1>${\ h($title)}</h1>
<div class="sub">$n предметов · выгружено $stamp · goskatalog.ru</div>
<div class="grid">
$cards
</div>
HTML
  open(my $fh, '>:encoding(UTF-8)', fs($path)) or die "не пишется: $path\n";
  print $fh $html; close $fh;
  print "Галерея: $path ($n предметов)\n";
}

sub print_items {
  my ($items) = @_;
  for my $it (@$items) {
    my @bits = grep { defined && length } ($it->{Similarity} ? "похоже на $it->{Similarity}%" : (), $it->{Typology}, $it->{Period}, $it->{Authors}, $it->{Museum});
    printf "%s  %s\n    %s\n    %s\n", $it->{Id}, $it->{Name}, join(' · ', @bits), $it->{Url};
    printf "    %s\n", $it->{Description} if $it->{Description};
  }
  print "\nНайдено: " . scalar(@$items) . "\n";
}

# --------------------------------------------------------------------- командная строка

my @args = map { decode('UTF-8', $_) } @ARGV;
my $cmd = shift @args // '';
my (%o, @pos);
my %flags = map { $_ => 1 } qw(with-image no-image total details all force);
while (@args) {
  my $a = shift @args;
  if ($a =~ /^--(.+)$/) {
    my $raw = $1;
    (my $k = $raw) =~ s/-/_/g;
    $o{$k} = $flags{$raw} ? 1 : shift(@args);
  } else { push @pos, $a }
}

sub emit {
  my ($items) = @_;
  print_items($items);
  csv_write($o{csv}, $items, [qw(Id Name Museum Typology Authors Technologies Period Dimensions RegNumber GikNumber ImageCount Image Url)]) && print "CSV: $o{csv}\n" if $o{csv};
  export_gallery($items, $o{gallery}, $o{title}) if $o{gallery};
  save_images($items, $o{download}, all => $o{all}, size => $o{size}, force => $o{force}) if $o{download};
}

if ($cmd eq 'search') {
  my @items = search_gk(query => $pos[0], name => $o{name}, author => $o{author}, producer => $o{producer},
                        technology => $o{technology}, typology => $o{typology}, museum_id => $o{museum_id},
                        gik => $o{gik}, inv => $o{inv}, reg => $o{reg}, with_image => $o{with_image},
                        no_image => $o{no_image}, max => $o{max}, total => $o{total});
  @items = map { get_item($_->{Id}) } @items if $o{details};       # по запросу на предмет: медленно
  emit(\@items);
}
elsif ($cmd eq 'item') {
  die "Нужен id предмета: perl goskatalog.pl item 12345\n" unless @pos;
  my @items; for my $id (@pos) { push @items, get_item($id); nap(200); }
  emit(\@items);
}
elsif ($cmd eq 'museum') {
  my @m = values %{ museum_map() };
  @m = grep { index(lc($_->{name} // ''), lc $o{name}) >= 0 || index(lc($_->{abbreviation} // ''), lc $o{name}) >= 0 } @m if $o{name};
  @m = grep { index(lc($_->{addressString} // ''), lc $o{city}) >= 0 } @m if $o{city};
  @m = sort { ($a->{name} // '') cmp ($b->{name} // '') } @m;
  splice(@m, $o{max} || 50) if @m > ($o{max} || 50);
  printf "%s  %s\n    %s\n", $_->{id}, $_->{name}, $_->{addressString} // '' for @m;
}
elsif ($cmd eq 'typology') {
  printf "%s  %s\n", $_->{id}, $_->{name} for typology_list();
}
elsif ($cmd eq 'by-image') {
  die "Нужен файл: perl goskatalog.pl by-image фото.jpg\n" unless @pos;
  emit([ search_by_image($pos[0]) ]);
}
else {
  print "Команды: search | item | museum | typology | by-image. Подробности — в начале файла goskatalog.pl\n";
  exit($cmd eq '' || $cmd eq '--help' ? 0 : 1);
}
