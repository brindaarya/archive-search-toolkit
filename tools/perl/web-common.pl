# Общая основа для поисковых скриптов: сеть, разбор HTML, чтение и запись CSV.
#
# Перенесено с Windows (PowerShell) на macOS. Вместо Invoke-WebRequest —
# curl, он входит в систему; вместо ConvertFrom-Json — JSON::PP из состава Perl.
# Ставить ничего не нужно.
#
# Подключается так:
#   require File::Spec->catfile(dirname(abs_path($0)), 'web-common.pl');

use strict;
use warnings;
use utf8;
use Encode qw(encode decode);
use JSON::PP;

# Пути внутри скриптов — строки символов, файловой системе нужны байты UTF-8
sub fs { return encode('UTF-8', $_[0]); }

our $UserAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';
our $Verbose   = 0;

# ---------------------------------------------------------------- сеть

# Запрос с повторами. Возвращает тело ответа строкой символов (UTF-8),
# либо undef, если все попытки провалились.
# Именованные параметры: retries, timeout, headers (ссылка на массив),
# cookiejar, post (тело), content_type, raw (не декодировать), referer.
sub http_get {
  my ($url, %opt) = @_;
  my $retries = $opt{retries} // 3;
  my $timeout = $opt{timeout} // 90;

  for my $attempt (1 .. $retries) {
    my @cmd = ('curl', '-sS', '-L', '--compressed',
               '--max-time', $timeout,
               '-A', $UserAgent,
               '-H', 'Accept-Language: ru-RU,ru;q=0.9');

    push @cmd, '-H', encode('UTF-8', $_) for @{ $opt{headers} // [] };
    push @cmd, '-H', 'Referer: ' . encode('UTF-8', $opt{referer}) if $opt{referer};
    push @cmd, '-b', fs($opt{cookiejar}), '-c', fs($opt{cookiejar}) if $opt{cookiejar};

    if (defined $opt{post}) {
      push @cmd, '-X', 'POST', '--data-binary', encode('UTF-8', $opt{post});
      push @cmd, '-H', 'Content-Type: ' . ($opt{content_type} // 'application/json');
    }

    push @cmd, encode('UTF-8', $url);

    my $body = '';
    if (open(my $ph, '-|', @cmd)) {
      binmode($ph, ':raw');
      local $/;
      $body = <$ph> // '';
      close $ph;
    }

    if (length $body) {
      return $body if $opt{raw};
      # Сайты не всегда объявляют кодировку — декодируем сами,
      # иначе кириллица приходит битой
      return decode('UTF-8', $body, Encode::FB_DEFAULT);
    }

    if ($attempt < $retries) {
      warn "  сеть подвела, попытка " . ($attempt + 1) . " из $retries\n" if $Verbose;
      sleep($attempt * 3);
    }
  }
  return undef;
}

# Скачать файл на диск. Возвращает размер в байтах или 0.
sub http_download {
  my ($url, $path, %opt) = @_;
  my @cmd = ('curl', '-sS', '-L', '--compressed',
             '--max-time', $opt{timeout} // 180,
             '-A', $UserAgent,
             '-o', fs($path));
  push @cmd, '-H', encode('UTF-8', $_) for @{ $opt{headers} // [] };
  push @cmd, '-H', 'Referer: ' . encode('UTF-8', $opt{referer}) if $opt{referer};
  push @cmd, '-b', fs($opt{cookiejar}), '-c', fs($opt{cookiejar}) if $opt{cookiejar};
  push @cmd, encode('UTF-8', $url);

  system(@cmd);
  return (-e fs($path)) ? (-s fs($path)) : 0;
}

sub url_encode {
  my ($s) = @_;
  my $bytes = encode('UTF-8', $s // '');
  $bytes =~ s{([^A-Za-z0-9\-._~])}{sprintf('%%%02X', ord($1))}ge;
  return $bytes;
}

sub from_json_text {
  my ($text) = @_;
  return undef unless defined $text && length $text;
  my $data = eval { JSON::PP->new->utf8(0)->decode($text) };
  warn "  не разобрался JSON: $@\n" if $@ && $Verbose;
  return $data;
}

# Пауза в миллисекундах — чтобы не долбить сайт очередями запросов
sub nap {
  my ($ms) = @_;
  select(undef, undef, undef, ($ms // 0) / 1000);
}

# ---------------------------------------------------------------- HTML

my %Entities = (
  'nbsp' => ' ', 'amp' => '&', 'lt' => '<', 'gt' => '>', 'quot' => '"',
  'apos' => "'", 'laquo' => '«', 'raquo' => '»', 'mdash' => '—', 'ndash' => '–',
  'hellip' => '…', 'rsquo' => '’', 'lsquo' => '‘', 'ldquo' => '“', 'rdquo' => '”',
  'shy' => '', 'deg' => '°', 'numero' => '№', 'copy' => '©',
);

sub html_decode {
  my ($s) = @_;
  return '' unless defined $s;
  $s =~ s/&#x([0-9a-fA-F]+);/chr(hex($1))/ge;
  $s =~ s/&#(\d+);/chr($1)/ge;
  $s =~ s/&([a-zA-Z]+);/exists $Entities{$1} ? $Entities{$1} : "&$1;"/ge;
  return $s;
}

# Текст из куска HTML: без разметки, скриптов и лишних пробелов
sub html_to_text {
  my ($html) = @_;
  return '' unless defined $html && length $html;
  my $s = $html;
  $s =~ s{<script.*?</script>}{ }gsi;
  $s =~ s{<style.*?</style>}{ }gsi;
  $s =~ s{<br\s*/?>}{ }gi;
  $s =~ s{<[^>]+>}{ }g;
  $s = html_decode($s);
  $s =~ s/\s+/ /g;
  $s =~ s/^\s+|\s+$//g;
  return $s;
}

# ---------------------------------------------------------------- CSV

# Разбор CSV с кавычками и переводами строк внутри полей.
# Возвращает массив хешей по заголовку первой строки.
sub csv_read {
  my ($path) = @_;
  open(my $fh, '<:encoding(UTF-8)', fs($path)) or die "не открывается: $path\n";
  local $/;
  my $text = <$fh> // '';
  close $fh;
  $text =~ s/\r\n/\n/g;
  $text =~ s/^\x{FEFF}//;

  my (@rows, @row);
  my $field = '';
  my $inq   = 0;
  my @chars = split //, $text;

  for (my $i = 0; $i < @chars; $i++) {
    my $c = $chars[$i];
    if ($inq) {
      if ($c eq '"') {
        if (defined $chars[$i + 1] && $chars[$i + 1] eq '"') { $field .= '"'; $i++; }
        else { $inq = 0; }
      } else { $field .= $c; }
    } else {
      if    ($c eq '"')  { $inq = 1; }
      elsif ($c eq ',')  { push @row, $field; $field = ''; }
      elsif ($c eq "\n") { push @row, $field; $field = ''; push @rows, [@row]; @row = (); }
      else               { $field .= $c; }
    }
  }
  push @row, $field if length $field;
  push @rows, [@row] if @row;

  my $header = shift @rows;
  return () unless $header;

  my @out;
  for my $r (@rows) {
    next unless grep { defined && length } @$r;
    my %h;
    @h{@$header} = @$r;
    push @out, \%h;
  }
  return @out;
}

# Запись CSV в том же виде, что делал Export-Csv: заголовок,
# все поля в кавычках, кодировка UTF-8 — Excel и Numbers открывают как есть.
sub csv_write {
  my ($path, $rows, $cols) = @_;
  open(my $fh, '>:encoding(UTF-8)', fs($path)) or die "не пишется: $path\n";

  my @columns = @{ $cols // [] };
  unless (@columns) {
    die "нечего писать: не заданы колонки и нет строк\n" unless @$rows;
    @columns = sort keys %{ $rows->[0] };
  }

  print $fh join(',', map { csv_quote($_) } @columns), "\n";
  for my $r (@$rows) {
    print $fh join(',', map { csv_quote($r->{$_}) } @columns), "\n";
  }
  close $fh;
  return scalar @$rows;
}

sub csv_quote {
  my ($v) = @_;
  $v = '' unless defined $v;
  $v =~ s/"/""/g;
  return '"' . $v . '"';
}

1;
