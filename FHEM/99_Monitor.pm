##############################################################################
# 99_Monitor.pm  -  Anlagenmonitoring (Journal, Sammelmeldungen, Checks)
# Journal: /opt/fhem/log/monitor_journal.json  (7 Tage)
# Aufruf:  at_Monitor (jede Minute) -> Mon_Check()
# API:     Mon_Melde(key,sev,kat,titel,quelle,text)  offene (Sammel-)Meldung
#          Mon_Ende(key,quelle)                         Quelle wieder OK
#          Mon_Info(key,kat,titel,text[,sev])           Einzelereignis
#          Mon_JSON(tage)                               fuer FTUI
#          Mon_VD_JSON()                                Verdichterstarts (Tage) fuer FTUI
##############################################################################
package main;
use strict;
use warnings;
use vars qw(%defs);
use JSON::PP;
use POSIX qw(strftime);

my $MON_FILE = $ENV{MONF} // "/opt/fhem/log/monitor_journal.json";
my $MON_KEEP = 7*86400;
my $MON_MAX  = 4000;
my %MON;            # Laufzeit-Zustaende (nicht persistent)
my $MON_J;          # Journal im Speicher

sub Monitor_Initialize { my ($h) = @_; }

sub _mon_load {
  return $MON_J if($MON_J);
  $MON_J = [];
  if(open(my $f,"<",$MON_FILE)) {
    local $/; my $t = <$f>; close $f;
    my $d = eval { JSON::PP->new->decode($t) };
    $MON_J = $d if(ref($d) eq "ARRAY");
  }
  return $MON_J;
}
sub _mon_save {
  my $j = _mon_load();
  my $lim = time() - $MON_KEEP;
  @$j = grep { ($_->{tl}||0) >= $lim || $_->{offen} } @$j;
  splice(@$j,0,@$j-$MON_MAX) if(@$j > $MON_MAX);
  if(open(my $f,">",$MON_FILE.".tmp")) {
    print $f JSON::PP->new->canonical->encode($j); close $f;
    rename($MON_FILE.".tmp",$MON_FILE);
  }
}
sub _mon_dirty { if($MON{inchk}) { $MON{dirty} = 1; } else { _mon_save(); } }
sub _mon_sum {
  my $j = _mon_load();
  my ($e,$w) = (0,0);
  for my $x (@$j) { next if(!$x->{offen}); $e++ if($x->{sev} eq "E"); $w++ if($x->{sev} eq "W"); }
  return if(!defined($defs{Monitor}));
  readingsBeginUpdate($defs{Monitor});
  readingsBulkUpdateIfChanged($defs{Monitor},"offen_fehler",$e);
  readingsBulkUpdateIfChanged($defs{Monitor},"offen_warnungen",$w);
  readingsBulkUpdateIfChanged($defs{Monitor},"state",($e ? "FEHLER $e" : ($w ? "WARNUNG $w" : "OK")));
  readingsEndUpdate($defs{Monitor},1);
}
sub _mon_last {
  my ($titel) = @_;
  return if(!defined($defs{Monitor}));
  readingsSingleUpdate($defs{Monitor},"letzte_meldung",strftime("%H:%M:%S",localtime)." ".$titel,1);
}

# offene Sammelmeldung anlegen/aktualisieren
sub Mon_Melde {
  my ($key,$sev,$kat,$titel,$quelle,$text) = @_;
  $quelle //= "-"; $text //= "";
  my $j = _mon_load(); my $now = time();
  my ($x) = grep { $_->{key} eq $key && $_->{offen} } reverse @$j;
  if($x) {
    my $neu = !exists($x->{akt}{$quelle});
    $x->{akt}{$quelle} = $now;
    $x->{q}{$quelle} = $text;
    $x->{tl} = $now;
    $x->{sev} = $sev if($sev eq "E");
    if($neu) { $x->{n}++; push @{$x->{h}}, [$now,"+",$quelle,$text]; }
    $x->{titel} = $titel;
    _mon_dirty() if($neu);
    return 0;
  }
  push @$j, { id=>$now.int(rand(1000)), key=>$key, sev=>$sev, kat=>$kat, titel=>$titel,
              t0=>$now, tl=>$now, offen=>1, n=>1, akt=>{$quelle=>$now}, q=>{$quelle=>$text},
              h=>[[$now,"+",$quelle,$text]] };
  _mon_dirty(); _mon_sum(); _mon_last($titel." (".$quelle.")");
  Log3(undef,3,"Monitor: $sev $kat $titel - $quelle $text");
  return 1;
}
# Quelle wieder in Ordnung
sub Mon_Ende {
  my ($key,$quelle) = @_;
  my $j = _mon_load(); my $now = time();
  my ($x) = grep { $_->{key} eq $key && $_->{offen} } reverse @$j;
  return 0 if(!$x);
  if(defined($quelle)) {
    return 0 if(!exists($x->{akt}{$quelle}));
    delete $x->{akt}{$quelle};
    push @{$x->{h}}, [$now,"-",$quelle,"wieder OK"];
  } else { $x->{akt} = {}; }
  if(!%{$x->{akt}}) { $x->{offen} = 0; $x->{te} = $now; $x->{tl} = $now; }
  _mon_dirty(); _mon_sum();
  return 1;
}
# Einzelereignis; gleiche key + gleicher Text-Typ direkt hintereinander -> zusammengefasst
sub Mon_Info {
  my ($key,$kat,$titel,$text,$sev,$ex) = @_;
  $sev //= "I"; $text //= "";
  my $j = _mon_load(); my $now = time();
  my $norm = sub { my $s = shift // ""; $s =~ s/[-+]?\d+([.,]\d+)?/#/g; return $s; };
  my ($x) = grep { $_->{key} eq $key && !$_->{offen} } reverse @$j;
  if($x && $x->{sum} && $norm->($x->{text}) eq $norm->($text) && $now - $x->{tl} < 3600) {
    $x->{n}++; $x->{tl} = $now; $x->{text} = $text;
    push @{$x->{h}}, [$now,"=","",$text]; shift @{$x->{h}} if(@{$x->{h}} > 60);
    return 0;
  }
  my $ev = { id=>$now.int(rand(1000)), key=>$key, sev=>$sev, kat=>$kat, titel=>$titel,
              text=>$text, t0=>$now, tl=>$now, offen=>0, n=>1, sum=>($ex ? 0 : 1), h=>[[$now,"=","",$text]] };
  if(ref($ex) eq "HASH") { $ev->{$_} = $ex->{$_} for keys %$ex; }
  push @$j, $ev;
  _mon_dirty();
  _mon_last($titel) if($sev ne "I");
  return 1;
}
sub Mon_JSON {
  my ($tage) = @_; $tage ||= 7;
  my $lim = time() - $tage*86400;
  my @r = grep { ($_->{tl}||0) >= $lim || $_->{offen} } @{_mon_load()};
  return JSON::PP->new->canonical->encode({ now=>time(), ev=>\@r });
}

# ---------------------------------------------------------------- Checks ----
sub _mon_cfg { my ($n,$d) = @_; return defined($defs{Monitor}) ? ReadingsVal("Monitor","cfg_$n",$d) : $d; }
sub _mon_age {                      # Alter des juengsten Readings eines Geraets
  my ($d) = @_;
  my $R = $defs{$d}{READINGS} or return undef;
  my $best;
  for my $r (keys %$R) {
    next if($r =~ /^(state|IODev|lastCmd|.*_setzen)$/);
    my $ts = $R->{$r}{TIME} or next;
    $best = $ts if(!defined($best) || $ts gt $best);
  }
  return undef if(!defined($best));
  return time() - time_str2num($best);
}
sub _mon_tag { return (defined(&isday) ? isday() : ((localtime)[2] >= 8 && (localtime)[2] < 19)); }
sub _mon_dauer { my $s = int(shift); return sprintf("%dh%02d",int($s/3600),int(($s%3600)/60)) if($s >= 3600); return sprintf("%d min",int($s/60)); }
sub _mon_num { my ($d,$r,$def) = @_; return defined($defs{$d}) ? ReadingsNum($d,$r,$def) : $def; }

sub Mon_Check {
  my $now = time();
  _mon_load();
  $MON{inchk} = 1; $MON{dirty} = 0;
  my $tag = _mon_tag();

  # 1) Kommunikation / Schnittstellen (Sammelmeldung KOMM)
  my $typen = _mon_cfg("typen","ModbusAttr|ModbusSDM630M|HTTPMOD|Shelly|DWD_OpenData|JsonMod|Tado|TadoAPI|LUXTRONIK2|THZ|RPI_1Wire");
  my $mqre  = _mon_cfg("mqtt_geraete","^OpenWB_Garage_(links|rechts)\$|^OpenWB\$");
  my $ign   = _mon_cfg("ignorieren","^(Monitor|global)\$");
  my $pvre  = _mon_cfg("pv_geraete","Deye|Gaube|Huette|Solar|PV_|WR_");
  for my $d (sort keys %defs) {
    my $h = $defs{$d};
    next if(!$h->{TYPE} || $h->{TEMPORARY});
    next if($h->{TYPE} !~ /^($typen)$/ && !($h->{TYPE} eq "MQTT2_DEVICE" && $d =~ /$mqre/));
    next if($d =~ /$ign/ || IsDisabled($d) || ReadingsVal("Monitor","cfg_aus_$d",0));
    my $max = (ReadingsVal("Monitor","cfg_maxAge_$d",
               $h->{TYPE} eq "DWD_OpenData" ? 8*3600 : _mon_cfg("maxAge",900)));
    my $age = _mon_age($d);
    next if(!defined($age));
    my $off = (defined($h->{READINGS}{EMSPowerMode}) && ReadingsNum($d,"EMSPowerMode",0) == 255) ? 1 : 0;
    if($off) {
      Mon_Melde("KOMM","E","Kommunikation","Kommunikationsfehler",$d,"Wechselrichter meldet offline (Mode 255)");
    } elsif($age > $max && !($d =~ /$pvre/ && !$tag)) {
      Mon_Melde("KOMM","E","Kommunikation","Kommunikationsfehler",$d,
        "keine Daten seit "._mon_dauer($age)." (".$h->{TYPE}.")");
    } elsif($age <= $max) {
      Mon_Ende("KOMM",$d);
    }
  }

  # 1b) Gateways fuer ereignisgesteuerte Geraete (KNX, MQTT): Verbindungsstatus
  for my $d (sort grep { ($defs{$_}{TYPE}//"") =~ /^(KNXIO|KNXTUL|TUL|MQTT2_SERVER|MQTT2_CLIENT|MQTT|HMUARTLGW|CUL|ModbusTCP)$/ } keys %defs) {
    next if(IsDisabled($d) || ReadingsVal("Monitor","cfg_aus_$d",0));
    my $st = ($defs{$d}{STATE} // "")." ".ReadingsVal($d,"state","");
    if($st =~ /disconnect|closed|dead|failed|error|timeout/i && $st !~ /\bopened\b|\bconnected\b|\bInitialized\b/i) {
      Mon_Melde("KOMM","E","Kommunikation","Kommunikationsfehler",$d,"Gateway: ".$st);
    } else { Mon_Ende("KOMM",$d); }
  }

  # 2) Logik-Fehler (DOIF error) und Gruende-Journal
  for my $d (sort grep { ($defs{$_}{TYPE}//"") eq "DOIF" } keys %defs) {
    next if(IsDisabled($d));
    my $err = ReadingsVal($d,"error","");
    my $eage = ReadingsAge($d,"error",99999) // 99999;
    my $harmlos = ($err =~ /:\s*[01]?\s*$/ && $err !~ /(syntax|Global symbol|undefined|Can.t|error at|at \(eval)/i) ? 1 : 0;
    if($err ne "" && $eage < 900 && !$harmlos) { Mon_Melde("LOGIK","W","Logik","Logikfehler",$d,(length($err) > 300 ? substr($err,-300) : $err)); }
    else { Mon_Ende("LOGIK",$d); }
    my $R = $defs{$d}{READINGS} || {};
    for my $r (keys %$R) {
      next if($r !~ /grund/i || $r =~ /grundlast/i);
      my $v = $R->{$r}{VAL}; next if(!defined($v) || $v eq "");
      my $k = "G:$d:$r";
      if(!defined($MON{$k})) { $MON{$k} = $v; next; }
      next if($MON{$k} eq $v);
      $MON{$k} = $v;
      Mon_Info($k,"Logik","$d".($r ne "grund" ? " ($r)" : ""),$v);
    }
  }

  # 3) Speicher / EMS (grosse Anlage und S9 generisch ueber DOIF_GoodWe_v2)
  if(defined($defs{DOIF_GoodWe_v2}) && !IsDisabled("DOIF_GoodWe_v2") && _mon_num("EMS_Control","v2Aktiv",0)) {
    my $a = ReadingsAge("DOIF_GoodWe_v2","state",99999) // 99999;
    if($a > 300) { Mon_Melde("EMS","E","Speicher","EMS-Regelung steht","DOIF_GoodWe_v2","letzter Lauf vor "._mon_dauer($a)); }
    else { Mon_Ende("EMS","DOIF_GoodWe_v2"); }
    my $R = $defs{DOIF_GoodWe_v2}{READINGS} || {};
    for my $r (grep { /^vollladen_rest_/ } keys %$R) {
      my $k = "VL:$r"; my $v = $R->{$r}{VAL} // 0;
      if(defined($MON{$k}) && $MON{$k} <= 0 && $v > 0) {
        (my $id = $r) =~ s/^vollladen_rest_//;
        Mon_Info("SOCK:$id","Speicher","SOC-Zusammenbruch Speicher $id","Vollladen fuer $v Tage aktiviert","W");
      }
      $MON{$k} = $v;
    }
  }
  for my $w (sort grep { ($defs{$_}{TYPE}//"") eq "ModbusAttr" && defined($defs{$_}{READINGS}{EMSPowerMode}) } keys %defs) {
    my $bp = _mon_num("EMS_Control","bypassBat".($w =~ /(\d{4})$/ ? $1 : "1"),0);
    if($bp) { Mon_Melde("BYPASS","W","Speicher","Speicher-Bypass aktiv",$w,"bypassBat gesetzt"); }
    else { Mon_Ende("BYPASS",$w); }
  }

  # 4) Netz: ungewoehnlicher Bezug bzw. naechtliche Einspeisung
  if(defined($defs{HA_SDM630M_Nergie})) {
    my $bz = ReadingsNum("HA_SDM630M_Nergie","Bezugsleistung",0);
    my $es = ReadingsNum("HA_SDM630M_Nergie","Einspeiseleistung",0);
    my $wb = 0; $wb += ReadingsNum($_,"Ladeleistung_gesamt",0) for (grep { /^OpenWB/ && defined($defs{$_}) } keys %defs);
    my $lim = _mon_cfg("bezugW",1500);
    $MON{bz_t} = ($bz > $lim && $wb < 100) ? ($MON{bz_t} // $now) : undef;
    if($MON{bz_t} && $now - $MON{bz_t} >= 600) { Mon_Melde("NETZ","W","Netz","Hoher Netzbezug","HA_SDM630M_Nergie",int($bz)." W seit "._mon_dauer($now-$MON{bz_t})); }
    elsif(!$MON{bz_t}) { Mon_Ende("NETZ","HA_SDM630M_Nergie"); }
    $MON{es_t} = (!$tag && $es > _mon_cfg("nachtEinspeisW",800)) ? ($MON{es_t} // $now) : undef;
    if($MON{es_t} && $now - $MON{es_t} >= 600) { Mon_Melde("NETZN","W","Netz","Hohe Einspeisung nachts","HA_SDM630M_Nergie",int($es)." W"); }
    elsif(!$MON{es_t}) { Mon_Ende("NETZN","HA_SDM630M_Nergie"); }
  }

  # 5) PV: Wechselrichter liefert tagsueber nichts, waehrend andere erzeugen
  my @pvw = grep { ($defs{$_}{TYPE}//"") eq "ModbusAttr" && defined($defs{$_}{READINGS}{PV_Total_Power}) } keys %defs;
  my $pvmax = 0; for (@pvw) { my $p = ReadingsNum($_,"PV_Total_Power",0); $pvmax = $p if($p > $pvmax); }
  for my $w (sort @pvw) {
    my $p = ReadingsNum($w,"PV_Total_Power",0);
    my $k = "pv0:$w";
    $MON{$k} = ($tag && $pvmax > 1500 && $p < 0.03*$pvmax) ? ($MON{$k} // $now) : undef;
    if($MON{$k} && $now - $MON{$k} >= 900) { Mon_Melde("PV","W","PV","PV-Ertrag fehlt",$w,int($p)." W, andere WR bis ".int($pvmax)." W"); }
    elsif(!$MON{$k}) { Mon_Ende("PV",$w); }
  }

  # 6) Laufzeiten: Waermepumpe und Wallboxen
  my @lz = ();
  push @lz, ["WP","Waermepumpe","HA_SDM630M_Heatpump","Power_Sum__W",_mon_cfg("wpEinW",300)] if(defined($defs{HA_SDM630M_Heatpump}));
  push @lz, ["WB:$_","Wallbox ".($_ =~ /links/ ? "links" : ($_ =~ /rechts/ ? "rechts" : "")),$_,"Ladeleistung_gesamt",100]
    for (grep { /^OpenWB/ && defined($defs{$_}{READINGS}{Ladeleistung_gesamt}) } sort keys %defs);
  for my $l (@lz) {
    my ($id,$name,$d,$r,$schw) = @$l;
    my $p = ReadingsNum($d,$r,0); my $an = ($p > $schw) ? 1 : 0;
    my $s = $MON{"lz:$id"} //= { an=>$an, t=>$now, e=>0, starts=>[] };
    $s->{e} += $p * 60 / 3600000 if($an);
    if($an && !$s->{an}) {
      $s->{an} = 1; $s->{t} = $now; $s->{e} = 0;
      push @{$s->{starts}}, $now; @{$s->{starts}} = grep { $now - $_ < 3600 } @{$s->{starts}};
      if($id eq "WP" && @{$s->{starts}} > _mon_cfg("wpStartsProH",3)) {
        Mon_Melde("TAKT","W","Heizung","Waermepumpe taktet",$d,scalar(@{$s->{starts}})." Starts in 60 min");
      }
    } elsif(!$an && $s->{an}) {
      my $dau = $now - $s->{t};
      $s->{an} = 0;
      Mon_Info("LZ:$id:$s->{t}",($id eq "WP" ? "Heizung" : "E-Auto"),"$name lief "._mon_dauer($dau),
        strftime("%H:%M",localtime($s->{t}))."-".strftime("%H:%M",localtime($now)).sprintf(", ca. %.1f kWh",$s->{e}),"I",{lz=>$id,dur=>$dau,kwh=>sprintf("%.2f",$s->{e})+0,t0=>$s->{t}}) if($dau >= 120);
      $s->{e} = 0;
    }
    if($id eq "WP" && !@{[grep { $now - $_ < 3600 } @{$s->{starts}}]} ) { Mon_Ende("TAKT",$d); }
    if(defined($defs{Monitor})) {
      my $tk = "lz_heute_".($id =~ s/\W/_/gr);
      my $d0 = strftime("%Y%m%d",localtime);
      my $ts = ReadingsTimestamp("Monitor",$tk,"");
      $ts =~ s/[^0-9]//g;
      my $sec = (substr($ts,0,8) eq $d0) ? ReadingsNum("Monitor",$tk,0) : 0;
      $sec += 60 if($an);
      readingsSingleUpdate($defs{Monitor},$tk,$sec,0);
    }
  }


  # 6b) Verdichterstarts: Tages-/Monatsstatistik, Saisonschwellen, Kurzlauf
  _mon_vd($now);

  # 6c) Zaehlerstaende: Monatsende-Snapshot pruefen
  _mon_zaehler($now);

  # 7) FHEM selbst: Laufzeit dieses Checks
  $MON{lauf} = time() - $now;
  $MON{inchk} = 0;
  _mon_save() if($MON{dirty});
  _mon_sum();
  return undef;
}

# ------------------------------------------------------ Verdichterstarts ----
my $MON_VDF = $ENV{MONVD} // "/opt/fhem/log/monitor_vd.json";
my $MON_VD;
sub _mon_vd_load {
  return $MON_VD if($MON_VD);
  $MON_VD = { d=>{} };
  if(open(my $f,"<",$MON_VDF)) { local $/; my $t = <$f>; close $f;
    my $x = eval { JSON::PP->new->decode($t) }; $MON_VD = $x if(ref($x) eq "HASH" && ref($x->{d}) eq "HASH"); }
  return $MON_VD;
}
sub _mon_vd_save {
  my $v = _mon_vd_load();
  my @k = sort keys %{$v->{d}}; if(@k > 800) { delete $v->{d}{$_} for @k[0..$#k-800]; }
  if(open(my $f,">",$MON_VDF.".tmp")) { print $f JSON::PP->new->canonical->encode($v); close $f; rename($MON_VDF.".tmp",$MON_VDF); }
}
sub _mon_vd_quelle {
  my $q = _mon_cfg("vdQuelle","");
  return $q if($q);
  return "LambdaWP:Verdichter_aktiv" if(defined($defs{LambdaWP}));
  return "Mythz:Verdichter_sGlobal" if(defined($defs{Mythz}));
  return "";
}
sub _mon_vd_grenze {
  my ($t) = @_;
  my $m = (localtime($t))[4] + 1;
  return ($m == 12 || $m <= 2) ? _mon_cfg("vdMaxWinter",6)
       : ($m >= 6 && $m <= 8)  ? _mon_cfg("vdMaxSommer",2)
       :                         _mon_cfg("vdMaxUebergang",4);
}
sub _mon_vd {
  my ($now) = @_;
  my ($d,$r) = split(/:/, _mon_vd_quelle(), 2);
  return if(!$d || !$r || !defined($defs{$d}));
  my $raw = ReadingsVal($d,$r,"");
  return if($raw eq "");
  my $an = ($raw =~ /^\s*(on|ein|an|true|aktiv|yes)\b/i) ? 1
         : (($raw =~ /^\s*(-?\d+(?:\.\d+)?)/) ? (($1 > 0) ? 1 : 0) : 0);
  my $ts = ReadingsTimestamp($d,$r,"");
  my $tc = $now;
  if($ts =~ /^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)/) {
    my $t = POSIX::mktime($6,$5,$4,$3,$2-1,$1-1900);
    $tc = $t if(defined($t) && $t <= $now && $now - $t <= 180);
  }
  my $v = _mon_vd_load();
  my $tag = strftime("%Y%m%d",localtime($now));
  my $x = ($v->{d}{$tag} //= { n=>0, lz=>0, kurz=>0 });
  my $dirty = 0;
  if(!defined($v->{an})) { $v->{an} = $an; $v->{t0} = $tc; $dirty = 1; }
  elsif($an && !$v->{an}) {
    $v->{an} = 1; $v->{t0} = $tc; $x->{n}++; $x->{last} = $tc; $dirty = 1;
    my $g = _mon_vd_grenze($now);
    if($x->{n} > $g) {
      my $sev = ($x->{n} > $g + _mon_cfg("vdFehlerPlus",3)) ? "E" : "W";
      Mon_Melde("VDSTARTS",$sev,"Heizung","Verdichter: zu viele Starts","heute",
        "$x->{n} Starts heute (Warnung ab ".($g+1).", Fehler ab ".($g+_mon_cfg("vdFehlerPlus",3)+1).")");
    }
  }
  elsif(!$an && $v->{an}) {
    my $t0 = $v->{t0} || $tc; my $dau = $tc - $t0; $dau = 0 if($dau < 0);
    $v->{an} = 0; $dirty = 1;
    my $x0 = ($v->{d}{strftime("%Y%m%d",localtime($t0))} //= { n=>0, lz=>0, kurz=>0 });
    $x0->{lz} += $dau;
    $x0->{min} = $dau if(!defined($x0->{min}) || $dau < $x0->{min});
    $x0->{max} = $dau if(!defined($x0->{max}) || $dau > $x0->{max});
    my $minS = _mon_cfg("vdMinLaufS",1200);
    if($dau < $minS) {
      $x0->{kurz}++;
      my $txt = strftime("%H:%M:%S",localtime($t0))."-".strftime("%H:%M:%S",localtime($tc))
        .", Laufzeit ".int($dau/60)." min ".($dau%60)." s (Minimum ".int($minS/60)." min)";
      Mon_Melde("VDKURZ","E","Heizung","Verdichter Kurzlauf",strftime("%d.%m. %H:%M",localtime($t0)),$txt);
    }
  }
  # Kurzlauf-Fehler nach 12 h automatisch schliessen, Starts-Meldung am Folgetag
  my ($ko) = grep { $_->{key} eq "VDKURZ" && $_->{offen} } @{_mon_load()};
  if($ko) { for my $q (keys %{$ko->{akt}}) { Mon_Ende("VDKURZ",$q) if($now - $ko->{akt}{$q} > _mon_cfg("vdKurzHaltS",43200)); } }
  my ($so) = grep { $_->{key} eq "VDSTARTS" && $_->{offen} } @{_mon_load()};
  Mon_Ende("VDSTARTS") if($so && strftime("%Y%m%d",localtime($so->{t0})) ne $tag);
  _mon_vd_save() if($dirty || !$v->{saved} || $v->{saved} ne $tag);
  $v->{saved} = $tag;
  return if(!defined($defs{Monitor}));
  my $mon = substr($tag,0,6);
  my $gest = strftime("%Y%m%d",localtime($now - 86400));
  my $vm = strftime("%Y%m",localtime(POSIX::mktime(0,0,12,1,(localtime($now))[4]-1,(localtime($now))[5])));
  my ($nm,$nvm) = (0,0);
  for my $k (keys %{$v->{d}}) { my $n = $v->{d}{$k}{n} // 0; $nm += $n if(substr($k,0,6) eq $mon); $nvm += $n if(substr($k,0,6) eq $vm); }
  my $lzh = $x->{lz} + (($v->{an} && $v->{t0}) ? $now - $v->{t0} : 0);
  my $h = $defs{Monitor};
  readingsBeginUpdate($h);
  readingsBulkUpdateIfChanged($h,"vd_status",$v->{an} ? "an" : "aus");
  readingsBulkUpdateIfChanged($h,"vd_starts_heute",$x->{n});
  readingsBulkUpdateIfChanged($h,"vd_starts_gestern",($v->{d}{$gest} ? ($v->{d}{$gest}{n} // 0) : 0));
  readingsBulkUpdateIfChanged($h,"vd_starts_monat",$nm);
  readingsBulkUpdateIfChanged($h,"vd_starts_vormonat",$nvm);
  readingsBulkUpdateIfChanged($h,"vd_grenze_heute",_mon_vd_grenze($now));
  readingsBulkUpdateIfChanged($h,"vd_kurzlaeufe_heute",$x->{kurz});
  readingsBulkUpdateIfChanged($h,"vd_lz_heute_min",int($lzh/60));
  readingsBulkUpdateIfChanged($h,"vd_min_lauf_heute_min",defined($x->{min}) ? int($x->{min}/60) : "-");
  readingsBulkUpdateIfChanged($h,"vd_letzter_start",$x->{last} ? strftime("%H:%M:%S",localtime($x->{last})) : "-");
  readingsBulkUpdateIfChanged($h,"vd_quelle",_mon_vd_quelle());
  readingsEndUpdate($h,1);
}
sub Mon_VD_JSON { return JSON::PP->new->canonical->encode({ now=>time(), grenze=>_mon_vd_grenze(time()), quelle=>_mon_vd_quelle(), an=>_mon_vd_load()->{an}, t0=>_mon_vd_load()->{t0}, d=>_mon_vd_load()->{d} }); }
# Zaehlerstaende: Monatsende-Snapshot (di_Zaehler_Monat) pruefen
sub _mon_zaehler {
  my ($now) = @_;
  my $d = "di_Zaehler_Monat";
  return unless defined($defs{$d});
  my $fn = "/opt/fhem/log/Zaehlerstaende.csv";
  my @lt = localtime($now);
  my $exp = strftime("%d.%m.%Y",
    localtime($now - $lt[3] * 86400 + (12 - $lt[2]) * 3600));
  my $frueh = ($lt[3] == 1 && $lt[2] == 0 && $lt[1] < 10) ? 1 : 0;
  my $gwc = _mon_num("Monitor", "cfg_zaehler_goodwe", 1);
  my @g = grep {
    defined(ReadingsNum($_, "Erz_PV_DC_Energie_kWh_monthLast", undef))
  } sort grep { /^GoodWe/i } keys %defs;
  my $dc = 0;
  $dc += ReadingsNum($_, "Erz_PV_DC_Energie_kWh_monthLast", 0) for @g;
  my $mt = (stat($fn))[9] // 0;
  my $ck = join("|", $mt, $exp, $frueh, $gwc, int($dc));
  return if(($MON{zm_ck} // "") eq $ck);
  $MON{zm_ck} = $ck;
  my (@hd, @rows);
  if(open(my $h, "<", $fn)) {
    my $l = <$h>;
    if(defined $l) { chomp $l; @hd = split(/;/, $l, -1); }
    while(my $z = <$h>) {
      chomp $z;
      next unless $z =~ /^(\d\d)\.(\d\d)\.(\d\d\d\d);/;
      push @rows, [ "$3$2$1", split(/;/, $z, -1) ];
    }
    close($h);
  }
  @rows = sort { $a->[0] cmp $b->[0] } @rows;
  my $num = sub {
    my $v = shift // "";
    $v =~ s/\s//g;
    if($v =~ /,/) { $v =~ s/\.//g; $v =~ s/,/./; }
    return $v =~ /^-?\d+(?:\.\d+)?$/ ? $v : undef;
  };
  my ($ei) = grep { $rows[$_][1] eq $exp } 0 .. $#rows;
  my ($si) = grep { $hd[$_] eq "Status" } 0 .. $#hd;
  my $st = (defined($ei) && defined($si))
    ? ($rows[$ei][$si + 1] // "") : "";
  if(!defined($ei) || $st !~ /^(ok|import)/) {
    Mon_Melde("ZAEHLER", "W", "Zaehler", "Monats-Snapshot fehlt/auffaellig",
      "$d:snapshot", "$exp: " . (!defined($ei) ? "Zeile fehlt"
      : ($st eq "" ? "Status leer" : $st))) unless $frueh;
  } else {
    Mon_Ende("ZAEHLER", "$d:snapshot");
  }
  return unless defined($ei) && $ei > 0;
  my (@neg, @spr);
  for my $j (1 .. $#hd) {
    next if(defined($si) && $j == $si);
    next if($hd[$j] =~ m{/Monat|^Gesamtstrom});
    my $c = $num->($rows[$ei][$j + 1]);
    my $p = $num->($rows[$ei - 1][$j + 1]);
    next unless defined($c) && defined($p);
    my $df = $c - $p;
    if($df < 0) { push @neg, sprintf("%s %.1f", $hd[$j], $df); next; }
    next unless $ei > 1;
    my $pp = $num->($rows[$ei - 2][$j + 1]);
    next unless defined($pp);
    my $dv = $p - $pp;
    push @spr, sprintf("%s %.0f (Vormonat %.0f)", $hd[$j], $df, $dv)
      if($dv > 0 && $df > 4 * $dv && $df - $dv > 300);
  }
  if(@neg) {
    Mon_Melde("ZAEHLER", "W", "Zaehler", "Zaehlerstand ruecklaeufig",
      "$d:ruecklaeufig", "$exp: " . join(", ", @neg));
  } else {
    Mon_Ende("ZAEHLER", "$d:ruecklaeufig");
  }
  if(@spr && !$MON{"zm_spr_$exp"}) {
    Mon_Info("ZAEHLER:$exp", "Zaehler", "Zaehler-Sprung $exp",
      join(", ", @spr));
    $MON{"zm_spr_$exp"} = 1;
  }
  my ($gj) = grep { $hd[$_] =~ /^GoodWe Erz/ } 0 .. $#hd;
  return unless $gwc && defined($gj) && @g && $dc > 50;
  my $c = $num->($rows[$ei][$gj + 1]);
  my $p = $num->($rows[$ei - 1][$gj + 1]);
  return unless defined($c) && defined($p);
  my $q = ($c - $p) / $dc;
  if($q < 0.85 || $q > 1.10) {
    Mon_Melde("ZAEHLER", "W", "Zaehler", "GoodWe-Monatswert unplausibel",
      "$d:goodwe", sprintf("%s: Zaehler %.0f kWh, DC-Statistik %.0f kWh"
      . " (%.0f %%)", $exp, $c - $p, $dc, 100 * $q));
  } else {
    Mon_Ende("ZAEHLER", "$d:goodwe");
  }
}
1;
