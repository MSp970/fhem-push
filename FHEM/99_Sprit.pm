##############################################################################
# 99_Sprit.pm  -  guenstigster Super-Plus-Preis im Umkreis (clever-tanken.de)
# Aufruf: at_Sprit (alle 30 min, 06-22 Uhr) -> Sprit_Update()
# Geraet: Spritpreis (dummy)
# Konfig (Readings): cfg_ort (90542 Eckental), cfg_radius (10), cfg_sorte (6 = SuperPlus)
##############################################################################
package main;
use strict;
use warnings;
use vars qw(%defs);
use POSIX qw(strftime);

my $SP_DEV = "Spritpreis";

sub Sprit_Initialize { my ($h) = @_; }

sub Sprit_Update {
  return "Geraet $SP_DEV fehlt" if(!defined($defs{$SP_DEV}));
  my $ort = ReadingsVal($SP_DEV,"cfg_ort","90542 Eckental");
  my $r = ReadingsNum($SP_DEV,"cfg_radius",10);
  my $s = ReadingsNum($SP_DEV,"cfg_sorte",6);
  $ort =~ s/([^A-Za-z0-9_.~-])/sprintf("%%%02X",ord($1))/ge;
  HttpUtils_NonblockingGet({
    url => "https://www.clever-tanken.de/tankstelle_liste?spritsorte=$s&ort=$ort&r=$r&sort=p",
    timeout => 25,
    header => "User-Agent: Mozilla/5.0 (FHEM Spritpreis)",
    callback => \&_sp_cb });
  return "Abruf gestartet";
}

sub _sp_cb {
  my ($p, $err, $data) = @_;
  my $h = $defs{$SP_DEV} or return;
  my $now = strftime("%H:%M:%S", localtime);
  my @st;
  if(!$err && ($p->{code} // 200) == 200) {
    for my $blk (split(/<a href="\/tankstelle_details\//, $data // "")) {
      my ($e,$c,$m) = $blk =~ /class="price-text[^"]*"[^>]*>\s*(\d)\.(\d\d)<sup>(\d)<\/sup>/s;
      next if(!defined($e));
      my ($name) = $blk =~ /fuel-station-location-name">([^<]*)</;
      my ($km)   = $blk =~ /fuel-station-location-distance[^>]*>\s*<span>([^<]*)</s;
      my ($str)  = $blk =~ /fuel-station-location-street">([^<]*)</;
      my ($ort)  = $blk =~ /fuel-station-location-city">\s*([^<]*)</;
      my $gt = join(" ", $blk =~ /class="price-changed">([^<]*)/g);
      $gt =~ s/geändert//; $gt =~ s/\s+/ /g; $gt =~ s/^\s+|\s+$//g;
      s/^\s+|\s+$//g for grep { defined } ($name,$km,$str,$ort);
      push @st, { preis => "$e.$c$m", name => $name // "?", km => $km // "", str => $str // "", ort => $ort // "", gt => $gt };
    }
  }
  if(!@st) {
    my $why = $err || ("HTTP ".($p->{code} // "?")." / keine Preise gefunden");
    readingsSingleUpdate($h, "grund", "$now Abruf fehlgeschlagen: $why", 1);
    Mon_Melde("SPRIT","W","Sonstiges","Spritpreis: Abruf fehlgeschlagen",$SP_DEV,$why)
      if(defined(&Mon_Melde) && ReadingsAge($SP_DEV,"preis",0) > 6*3600);
    return;
  }
  Mon_Ende("SPRIT",$SP_DEV) if(defined(&Mon_Ende));
  @st = sort { $a->{preis} <=> $b->{preis} } @st;
  my $b = $st[0];
  my $alt = ReadingsVal($SP_DEV,"preis","");
  readingsBeginUpdate($h);
  readingsBulkUpdate($h, "preis", $b->{preis});
  readingsBulkUpdate($h, "tankstelle", $b->{name});
  readingsBulkUpdate($h, "adresse", "$b->{str}, $b->{ort}");
  readingsBulkUpdate($h, "entfernung", $b->{km});
  readingsBulkUpdate($h, "geaendert", $b->{gt});
  readingsBulkUpdate($h, "top3", join(" | ", map { "$_->{preis} $_->{name} $_->{ort} ($_->{km})" } @st[0..($#st < 2 ? $#st : 2)]));
  readingsBulkUpdate($h, "anzahl", scalar(@st));
  readingsBulkUpdate($h, "state", "$b->{preis} EUR $b->{name} $b->{ort}");
  readingsBulkUpdate($h, "letzte_aktualisierung", strftime("%Y-%m-%d %H:%M:%S", localtime));
  readingsBulkUpdate($h, "grund", "$now ".scalar(@st)." Preise, guenstigster $b->{preis} $b->{name}".($alt ne "" && $alt ne $b->{preis} ? " (vorher $alt)" : ""));
  readingsEndUpdate($h, 1);
}

1;
