#!/usr/bin/perl
# Крошечный HTTP-сервер для проверки скриптов без сети. Отдаёт файлы из tests/fixtures,
# игнорируя строку запроса: /ru/nodes/search?query=... -> fixtures/ru/nodes/search,
# /book_search/?... -> fixtures/book_search/index.html. Понимает HEAD и Range (для докачки).
use strict; use warnings;
use IO::Socket::INET;
my ($port, $dir) = @ARGV;
my $srv = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $port, Listen => 5, ReuseAddr => 1) or die "порт занят\n";
while (my $c = $srv->accept) {
  my $req = <$c>; my ($method, $path) = ($req // '') =~ m{^(GET|HEAD)\s+([^\s?]+)};
  my $range;
  while (my $l = <$c>) { last if $l =~ /^\r?\n$/; $range = [$1, $2] if $l =~ /^Range:\s*bytes=(\d+)-(\d+)/i; }
  my $f = ($dir // '') . ($path // ''); $f .= 'index.html' if $f =~ m{/$};
  if (defined $path && -f $f) {
    open my $fh, '<:raw', $f; local $/; my $b = <$fh>; close $fh;
    my $len = length $b; my $status = '200 OK'; my $extra = '';
    if ($range && $method eq 'GET') {
      my ($from, $to) = @$range; $to = $len - 1 if $to > $len - 1;
      $b = substr($b, $from, $to - $from + 1); $status = '206 Partial Content';
      $extra = "Content-Range: bytes $from-$to/$len\r\n";
    }
    print $c "HTTP/1.0 $status\r\nAccept-Ranges: bytes\r\nContent-Type: text/html; charset=utf-8\r\n$extra"
           . ($method eq 'HEAD' ? "Content-Length: $len\r\n\r\n" : "Content-Length: " . length($b) . "\r\n\r\n$b");
  } else { print $c "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n" }
  close $c;
}
