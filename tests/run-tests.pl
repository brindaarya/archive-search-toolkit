#!/usr/bin/perl
# Офлайн-проверка: орфография и разбор выдачи ГПИБ и ЦГА Москвы на образцах страниц.
# Запуск: perl tests/run-tests.pl
use strict; use warnings; use utf8;
use Encode qw(decode encode);
use File::Basename qw(dirname);
use File::Spec; use Cwd qw(abs_path);
binmode(STDOUT, ':encoding(UTF-8)');
my $root = abs_path(File::Spec->catdir(dirname(abs_path($0)), '..'));
my ($pass, $fail) = (0, 0);
sub ok { my ($c, $name) = @_; if ($c) { $pass++; print "  ok   $name\n" } else { $fail++; print "  FAIL $name\n" } }
sub run { my $cmd = encode('UTF-8', $_[0]); my $out = `$cmd 2>&1`; return decode('UTF-8', $out) }

print "Орфография:\n";
my $sv = "perl '$root/tools/perl/spelling-variants.pl' --plain";
my $o = run("$sv 'Йога'");                      ok((($o =~ /^Іога$/m) ? 1 : 0), 'Йога → Іога');
$o = run("$sv 'в Бронницком уезде'");            ok((($o =~ /^въ Бронницкомъ уѣздѣ$/m) ? 1 : 0), 'въ Бронницкомъ уѣздѣ');
$o = run("$sv 'Фёдор Ильин'");                   ok((($o =~ /^Ѳедоръ Ильинъ$/m) ? 1 : 0), 'Ѳедоръ Ильинъ');
$o = run("$sv 'исповедные ведомости'");          ok((($o =~ /^исповѣдныя вѣдомости$/m) ? 1 : 0), 'исповѣдныя вѣдомости');
$o = run("$sv 'крестьяне'");                     ok((($o !~ /ѣ/) ? 1 : 0), 'крестьяне не получают ѣ');
$o = run("$sv 'в 1907 г.'");                     ok((($o =~ /^въ 1907 г\.$/m) ? 1 : 0), 'сокращение «г.» без ъ');

print "ГПИБ (образец выдачи):\n";
my $port = 40000 + $$ % 20000;
my $pid = fork();
if (!$pid) { exec('perl', "$root/tests/fixture-server.pl", $port, "$root/tests/fixtures") }
select(undef, undef, undef, 0.6);
$o = run("perl '$root/tools/perl/search-shpl.pl' --root http://127.0.0.1:$port --max-pages 1 'Бронницк*'");
ok((($o =~ /Вся Москва/) ? 1 : 0), 'издание найдено');
ok((($o =~ /скан 57/ && $o =~ /скан 58/) ? 1 : 0), 'попадания в текст привязаны к изданию');
ok((($o =~ /Дурилин/ && $o =~ /скан 18/) ? 1 : 0), 'второе издание отделено от первого');

print "ЦГА Москвы (образец выдачи):\n";
$o = run("perl '$root/tools/perl/search-cgamos.pl' --root http://127.0.0.1:$port БЫКОВО");
ok((($o =~ /Отобрано: 2/) ? 1 : 0), 'два дела разобраны');
ok((($o =~ /ф\.203 оп\.780 д\.3579/) ? 1 : 0), 'фонд/опись/дело');
$o = run("perl '$root/tools/perl/search-cgamos.pl' --root http://127.0.0.1:$port --years 1900-1917 БЫКОВО");
ok((($o =~ /Отобрано: 1/ && $o !~ /745/) ? 1 : 0), 'фильтр по годам отсекает дело 1777–1864');
print "rusarchives (привязка по окну):\n";
$o = run("perl '$root/tools/perl/search-rusarchives.pl' --guides-root http://127.0.0.1:$port --source guides --deep --delay 0 --max-pages 1 --strong 'усадьб|дворец' --place 'Быков|Раменск' --noise 'Быкова\\s+[А-Я]\\.' --query Быково");
ok(($o =~ /привязка да\s+1/ ? 1 : 0), '«да» только при признаке и месте в одном окне');
ok(($o =~ /привязка нет данных\s+1/ ? 1 : 0), 'однофамилица не засчитана');
print "РГБ (просмотрщик, образец):\n";
my $rg = "perl '$root/tools/perl/rgb-viewer.pl'";
$o = run("$rg info 12345678 --root http://127.0.0.1:$port");
ok(($o =~ /читать онлайн можно/ && $o =~ /страниц: 3/ ? 1 : 0), 'info: открытый документ');
my $rd = "$root/tests/_rgb"; system("rm -rf '$rd'");
$o = run("$rg pages 12345678 --page 1-3 --limit 2 --delay 0 --out-dir '$rd' --root http://127.0.0.1:$port");
ok(((-s "$rd/rsl12345678-стр001.jpg") == 2007 ? 1 : 0), 'страница скачана, проверен JPEG');
ok((!-e "$rd/rsl12345678-стр003.jpg" ? 1 : 0), '--limit не даёт выкачать документ целиком');
system("rm -rf '$rd'");
$o = run("$rg pages 99999999 --page 1 --out-dir '$rd' --root http://127.0.0.1:$port");
ok(($o =~ /онлайн нельзя/ && !-e $rd ? 1 : 0), 'закрытый документ: отказ, ничего не скачано');
print "PDF:\n";
my $pdf = "$root/tests/_t.pdf";
system("perl '$root/tests/make-pdf-fixture.pl' '$pdf'");
$o = run("perl '$root/tools/perl/get-pdf-text.pl' '$pdf' 2>&1");
ok(($o =~ /Йога и Ильин в Быкове/ ? 1 : 0), 'текст cp1251 из круглых скобок');
ok(($o =~ /Илаб/ ? 1 : 0), 'шестнадцатеричные строки через ToUnicode (bfchar и bfrange)');
unlink $pdf;
print "ИнфоРост (пакетный поиск с привязкой и докачка сканов):\n";
$o = run("perl '$root/tools/perl/search-inforost.pl' --root http://127.0.0.1:$port --max-pages 1 --delay 0 --strong 'Бронницк[^.]{0,60}Ильин' --query x");
ok(($o =~ /привязка да\s+1/ ? 1 : 0),        'привязка «да» считается по окну текста');
ok(($o =~ /Всего записей: 5/ ? 1 : 0),       'издания и попадания разобраны, без повторов');
my $dl = "$root/tests/_scans"; system("rm -rf '$dl'");
$o = run("perl '$root/tools/perl/get-inforost-page.pl' --root http://127.0.0.1:$port --node 438361 --all --out-dir '$dl'");
ok(($o =~ /всего сканов: 2/ ? 1 : 0),        'список страниц узла найден');
ok(((-s "$dl/node438361-стр001.jpg") == 12351 ? 1 : 0), 'скан 1 скачан целиком');
ok(((-s "$dl/node438361-стр002.jpg") == 9006 ? 1 : 0),  'скан 2 скачан целиком (id = первый + N − 1)');
system("rm -rf '$dl'");

kill 'TERM', $pid; waitpid($pid, 0);

print "\nИтого: $pass ок, $fail ошибок\n";
exit($fail ? 1 : 0);
