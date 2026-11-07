# ya-archive.pl — доступ к Яндекс Архиву (yandex.ru/archive) без браузера.
# Поиск отдаётся server-side рендерингом Next.js, поэтому весь результат
# лежит в <script id="__NEXT_DATA__"> и достаётся обычным запросом.
# Ни браузер, ни авторизация не нужны.
#
# Перенесено с PowerShell: Invoke-WebRequest → curl, ConvertFrom-Json → JSON::PP.
#
# Использование:
#   require '.../ya-archive.pl';
#   my @hits = search_ya_archive(text => 'детская колония Быково',
#                                index => '', date_from => 1918, date_to => 1925);
#   my $t = get_ya_page_text('8cddf8a4-...', 4);

use strict;
use warnings;
use utf8;
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);

# общая основа лежит рядом
require File::Spec->catfile(dirname(abs_path(__FILE__)), 'web-common.pl');

our $YaDelay = 400;    # пауза между страницами выдачи, мс

sub get_ya_next_data {
  my ($url) = @_;
  my $html = http_get($url, timeout => 90);
  unless (defined $html) { warn "не отвечает: $url\n"; return undef; }

  my ($json) = $html =~ m{<script id="__NEXT_DATA__" type="application/json">(.*?)</script>}s;
  unless (defined $json) { warn "не найден __NEXT_DATA__ на $url\n"; return undef; }

  return from_json_text($json);
}

# Именованные параметры:
#   text       — что ищем (обязательно)
#   index      — mass_media (периодика) | archive (архивные дела) | books (справочники)
#   date_from, date_to — годы четырёхзначным числом
#   fuzzy      — неточное совпадение
#   max_pages  — сколько страниц выдачи забрать
sub search_ya_archive {
  my (%o) = @_;
  my $text      = $o{text} // return ();
  my $index     = $o{index} // '';   # пусто = весь корпус; index=mass_media режет выдачу до узкой периодики
  my $max_pages = $o{max_pages} // 5;

  my $qs = 'text=' . url_encode($text);
  $qs .= "&index=$index" if length $index;
  $qs .= "&dateFrom=$o{date_from}" if $o{date_from};
  $qs .= "&dateTo=$o{date_to}"     if $o{date_to};
  $qs .= '&fuzzy=1'                if $o{fuzzy};

  my @out;
  my $total;
  my $page = 1;

  while ($page <= $max_pages) {
    my $data = get_ya_next_data("https://yandex.ru/archive/search?$qs&p=$page");
    last unless $data;

    my $pp = eval { $data->{props}{pageProps} } or last;
    unless (defined $pp->{totalDocs}) {
      warn "Яндекс Архив не вернул выдачу. С осени 2026 он требует вход в Яндекс ID: без него идёт редирект 307 на /archive. Используйте tools/browser/ya-search.js в браузере, где вы вошли. Ноль здесь не результат.\n";
      return (undef);
    }
    $total //= $pp->{totalDocs};
    my $items = $pp->{items};
    last unless $items && @$items;

    for my $it (@$items) {
      my $snippet = $it->{snippet} // '';
      # подсветку совпадения Яндекс отдаёт управляющим символом — заменяем кавычками
      $snippet =~ s/\x07\[/«/g;
      $snippet =~ s/\x07\]/»/g;

      push @out, {
        Query   => $text,
        Index   => (length $index ? $index : 'all'),
        Date    => $it->{dateFrom} // '',
        DateTo  => $it->{dateTo} // '',
        Source  => $it->{namepath} // '',
        Snippet => $snippet,
        NodeId  => $it->{parentId} // '',
        Page    => $it->{sheetPageNumber} // '',
        Url     => 'https://yandex.ru/archive/catalog/'
                   . ($it->{parentId} // '') . '/' . ($it->{sheetPageNumber} // ''),
        Total   => $total // '',
      };
    }

    last if $pp->{totalPages} && $page >= $pp->{totalPages};
    $page++;
    nap($YaDelay);
  }

  return @out;
}

# id и размеры конкретной страницы документа — нужны для картинки и кадрирования
sub get_ya_sheet_id {
  my ($node_id, $page) = @_;
  my $data = get_ya_next_data("https://yandex.ru/archive/catalog/$node_id/$page") or return undef;
  my $cn = eval { $data->{props}{pageProps}{currentNode} } or return undef;
  return {
    SheetId => $cn->{id},
    Width   => eval { $cn->{originalImageSize}{width} },
    Height  => eval { $cn->{originalImageSize}{height} },
    Source  => $cn->{namepath},
  };
}

# Полный распознанный текст страницы. $match фильтрует блоки по регулярке.
sub get_ya_page_text {
  my ($node_id, $page, $match) = @_;
  my $data = get_ya_next_data("https://yandex.ru/archive/catalog/$node_id/$page") or return undef;
  my $pp = eval { $data->{props}{pageProps} } or return undef;

  my @blocks = @{ $pp->{currentNode}{textBlocks} // [] };
  @blocks = grep { ($_->{text} // '') =~ /$match/ } @blocks if defined $match && length $match;

  my @texts = map { my $t = $_->{text} // ''; $t =~ s/^\s+|\s+$//g; $t } @blocks;

  return {
    Source => $pp->{currentNode}{namepath} // '',
    Url    => "https://yandex.ru/archive/catalog/$node_id/$page",
    Text   => join("\n", @texts),
  };
}

# Скан страницы. $type: preview — небольшая картинка; original — полное
# разрешение, для него сначала берётся подписанная ссылка (живёт около суток)
# и качать надо в той же сессии, поэтому нужен файл с куками.
sub get_ya_image {
  my ($sheet_id, $outfile, $type) = @_;
  $type //= 'original';

  if ($type eq 'preview') {
    my $size = http_download("https://yandex.ru/archive/api/image?id=$sheet_id&type=preview", $outfile);
    return $size;
  }

  my $jar = "/tmp/ya-archive-cookies-$$.txt";
  my $resp = http_get('https://yandex.ru/archive/api/image-grant',
                      post => qq({"nodeId":"$sheet_id"}),
                      cookiejar => $jar,
                      timeout => 60);
  my $grant = from_json_text($resp);
  unless ($grant && $grant->{url}) {
    warn "не выдана ссылка на скан: $sheet_id\n";
    unlink $jar;
    return 0;
  }

  my $size = http_download('https://yandex.ru' . $grant->{url}, $outfile,
                           cookiejar => $jar,
                           referer   => "https://yandex.ru/archive/catalog/$sheet_id",
                           timeout   => 180);
  unlink $jar;
  return $size;
}

1;
