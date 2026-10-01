##############################################################################
# 99_Muell.pm  -  Abfuhrtermine Landkreis Erlangen-Hoechstadt (ICS)
# Aufruf: at_Muell (taeglich + Start) -> Muell_Update()
# Geraet: Muellabfuhr (dummy), Readings rest_*, papier_*, garten_*, problem_*,
#         naechste, naechste_tage, hinweis, letzte_aktualisierung, grund
# Konfig (Readings am Geraet): cfg_ort (ECKENTAL), cfg_strasse (Oberschoellenbach)
##############################################################################
package main;
use strict;
use warnings;
use vars qw(%defs);
use POSIX qw(strftime mktime);

my $MU_DEV = "Muellabfuhr";
my %MU_KAT = (rest=>"Rest/Bio", papier=>"Papier/Gelb", garten=>"Gartenabfall", problem=>"Problemabfall");

sub Muell_Initialize { my ($h) = @_; }

sub _mu_url {
  my ($jahr) = @_;
  my $ort = ReadingsVal($MU_DEV,"cfg_ort","ECKENTAL");
  my $str = ReadingsVal($MU_DEV,"cfg_strasse","Oberschöllenbach");
  my $enc = sub { my $s = shift; $s =~ s/([^A-Za-z0-9_.~-])/sprintf("%%%02X",ord($1))/ge; return $s; };
  return "https://www.erlangen-hoechstadt.de/komx/surface/dfxabfallics/GetAbfallIcs?ort=".$enc->($ort)
        ."&strasse=".$enc->($str)."&abfallart=Alle&jahr=$jahr";
}

sub Muell_Update {
  return "Geraet $MU_DEV fehlt" if(!defined($defs{$MU_DEV}));
  my $y = (localtime)[5] + 1900;
  $defs{$MU_DEV}{helper}{mu_ev} = [];
  $defs{$MU_DEV}{helper}{mu_offen} = 2;
  $defs{$MU_DEV}{helper}{mu_fehler} = "";
  for my $j ($y, $y + 1) {
    HttpUtils_NonblockingGet({ url=>_mu_url($j), timeout=>20, jahr=>$j, callback=>\&_mu_cb });
  }
  return "Abruf gestartet";
}

sub _mu_cb {
  my ($p, $err, $data) = @_;
  my $h = $defs{$MU_DEV} or return;
  my $akt = ($p->{jahr} == (localtime)[5] + 1900);
  if($err) { $h->{helper}{mu_fehler} .= "$p->{jahr}: $err " if($akt); }
  elsif(($p->{code} // 200) != 200) { $h->{helper}{mu_fehler} .= "$p->{jahr}: HTTP $p->{code} " if($akt); }
  else {
    my $txt = $data // "";
    $txt =~ s/\r?\n[ \t]//g;
    my @ev;
    for my $blk (split(/BEGIN:VEVENT/, $txt)) {
      my ($d) = $blk =~ /DTSTART[^:]*:(\d{8})/;
      my ($s) = $blk =~ /SUMMARY[^:]*:([^\r\n]*)/;
      next if(!$d || !defined($s));
      $s =~ s/\\,/,/g; $s =~ s/\\;/;/g; $s =~ s/\\n/ /g; $s =~ s/\s+/ /g;
      my $k = ($s =~ /^Restm|Biotonne/i) ? "rest" : ($s =~ /^Papier|Gelb/i) ? "papier"
            : ($s =~ /^Garten/i) ? "garten" : ($s =~ /^Problem/i) ? "problem" : "sonst";
      push @ev, [$d, $k, $s];
    }
    push @{$h->{helper}{mu_ev}}, @ev;
  }
  $h->{helper}{mu_offen}--;
  _mu_auswerten() if($h->{helper}{mu_offen} <= 0);
}

sub _mu_auswerten {
  my $h = $defs{$MU_DEV} or return;
  my @ev = sort { $a->[0] cmp $b->[0] } @{$h->{helper}{mu_ev} || []};
  my @lt = localtime;
  my $heute = strftime("%Y%m%d", @lt);
  my $t0 = mktime(0,0,12,$lt[3],$lt[4],$lt[5]);
  my @wt = qw(So Mo Di Mi Do Fr Sa);
  my %n;
  for my $e (@ev) {
    next if($e->[0] lt $heute);
    $n{$e->[1]} //= $e;
  }
  my $now = strftime("%H:%M:%S", localtime);
  if(!@ev) {
    readingsSingleUpdate($h, "grund", "$now Abruf fehlgeschlagen: ".($h->{helper}{mu_fehler} || "keine Termine"), 1);
    Log3($MU_DEV, 2, "Muell: Abruf fehlgeschlagen ".($h->{helper}{mu_fehler} || ""));
    Mon_Melde("MUELL","W","Sonstiges","Muellkalender: Abruf fehlgeschlagen",$MU_DEV,$h->{helper}{mu_fehler} || "keine Termine") if(defined(&Mon_Melde));
    return;
  }
  Mon_Ende("MUELL",$MU_DEV) if(defined(&Mon_Ende));
  readingsBeginUpdate($h);
  my ($best, $bt) = (undef, 9999);
  my %T;
  for my $k (sort keys %MU_KAT) {
    my $e = $n{$k};
    if(!$e) { readingsBulkUpdate($h, "${k}_datum", "-"); readingsBulkUpdate($h, "${k}_tage", -1); next; }
    my ($Y,$M,$D) = $e->[0] =~ /^(\d{4})(\d\d)(\d\d)$/;
    my $t = mktime(0,0,12,$D,$M-1,$Y-1900);
    my $tage = int(($t - $t0) / 86400 + 0.5);
    my $wd = $wt[(localtime($t))[6]];
    readingsBulkUpdate($h, "${k}_datum", "$wd $D.$M.");
    readingsBulkUpdate($h, "${k}_iso", "$Y-$M-$D");
    readingsBulkUpdate($h, "${k}_tage", $tage);
    $T{$k} = $tage;
    readingsBulkUpdate($h, "${k}_text", $e->[2]);
    if(($k eq "rest" || $k eq "papier") && $tage < $bt) { $bt = $tage; $best = [$k, "$wd $D.$M."]; }
  }
  if($best) {
    my $txt = $MU_KAT{$best->[0]}." ".$best->[1];
    for my $k (qw(rest papier)) { next if($k eq $best->[0] || !$n{$k} || ($T{$k} // 99) != $bt); $txt .= " + ".$MU_KAT{$k}; }
    readingsBulkUpdate($h, "naechste", $txt);
    readingsBulkUpdate($h, "naechste_tage", $bt);
    readingsBulkUpdate($h, "hinweis", $bt == 0 ? "heute: $txt" : ($bt == 1 ? "morgen: $txt" : "-"));
    readingsBulkUpdate($h, "state", ($bt == 0 ? "heute " : ($bt == 1 ? "morgen " : "in $bt T: ")).$txt);
  }
  readingsBulkUpdate($h, "termine_gesamt", scalar(@ev));
  readingsBulkUpdate($h, "letzte_aktualisierung", strftime("%Y-%m-%d %H:%M:%S", localtime));
  readingsBulkUpdate($h, "grund", "$now aktualisiert, ".scalar(@ev)." Termine".($h->{helper}{mu_fehler} ? " (Teilfehler: $h->{helper}{mu_fehler})" : ""));
  readingsEndUpdate($h, 1);
}

1;
