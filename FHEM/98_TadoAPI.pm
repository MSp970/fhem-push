#===============================================================================
# $Id: 98_TadoAPI.pm 107 2025-05-12 15:45:00Z psycho160 $
#
#         FILE: 98_TadoAPI.pm 
#               - for oauth2 (2025)
#
#         USAGE: Module for FHEM
#         Info: Turn verbose on for debugging
#
# REQUIREMENTS: Below modules should be pre-installed.
# 				HTTP::Request::Common
# 				HTTP::Headers
#			  	Data::Dumper;
# 				JSON
#
#         BUGS: tell me
#        NOTES: https://git.wolfmajer.at
#       AUTHOR: Philipp Wolfmajer
# ORGANIZATION:
#       CREATED:    04/12/2019
#       EXTENDED:   05/11/2025 " GET & SET reading HomePresence added"   HG
#===============================================================================
package main;

use strict;
use warnings;
use utf8;
use HTTP::Request::Common qw (POST GET PUT);
use HTTP::Headers;
use JSON;
use POSIX qw(strftime);

####DEFAULTS############
my $client_id     = '1bb50063-6b0c-4d11-bd99-387f4a91cc46';
my $scope         = 'offline_access';
my $AuthURL       = qq{https://login.tado.com/oauth2/token};
my $DataURL       = qq{https://my.tado.com/api/v2/me};
my $QueryURL      = qq{https://my.tado.com/api/v2/homes};
my $tokenFile     = "./FHEM/FhemUtils/TadoAPI_token";
my $header        = {};
# FHEM Loglevel for API Requests
my $reqDebug      = 5;

# helpers
my $apiStatus = 1;

my %sets = (
    "zoneUpdate"        => "",
    "refreshToken"      => "noArg",
    "update"            => "noArg",
    "setGeo"            => "",
    "setZoneOverlay"    => "",
    "timedZoneOverlay"  => "",
    "updateAllOverlays" => "noArg",
    "setAllOverlays"    => "",
    "setHomePresence"   => ""
);

my %gets = (
    "getZoneDevices" => "noArg",
    "getZoneInfo"    => "noArg",
    "getGeo"         => "",
    "getDeviceCode" => "noArg",
    "getMobileDevices" => "noArg",
    "getHomePresence"  => "noArg"
);

sub TadoAPI_Initialize {
    my $hash = shift;

    $hash->{DefFn}    = \&TadoAPI_Define;
    $hash->{InitFn}   = \&TadoAPI_Init;
    $hash->{UndefFn}  = \&TadoAPI_Undefine;
    $hash->{DeleteFn} = \&TadoAPI_Delete;
    $hash->{SetFn}    = \&TadoAPI_Set;
    $hash->{GetFn}    = \&TadoAPI_Get;
    $hash->{AttrList} = ""
      . "homeID "
      . "mobileID "
      . "showPosData:0,1 "
      . "updateIntervall "
      . "disable:0,1 "
      . $readingFnAttributes;

      return;
}

sub TadoAPI_Init {
    my $hash = shift;
    my $def = shift;

    my @args = split( "[ \t][ \t]*", $def );
    
    my $u = "wrong syntax: define <name> TadoAPI <device_code>";
    return $u if ( int(@args) < 2 );
    return;
}

sub TadoAPI_Define {
    my $hash = shift;
    my $def  = shift;

    my @a             = split( "[ \t]+", $def );
    my $name          = shift @a;
    my $type          = shift @a;
    my $tokenFileName = $tokenFile . "_" . $name;

    my ( $dev_code ) = @a;
    Log3 $name, 3, "TadoAPI_Define $name: called ";

    my $u = "wrong define syntax: define <name> TadoAPI";
    return $u if ( int(@a) > 1 );

    defined $dev_code ? ($hash->{STATE} = "defined") : ($hash->{DEF} = "no_device_code_set");

    # Initialize the device
    return $@ unless ( FHEM::Meta::SetInternals($hash) );

    $hash->{TOKEN_FILE} = $tokenFileName;
    $hash->{TADO_DEV_CODE}  = $dev_code;

    if ($main::init_done) {

        # do something?
        return TadoAPI_Catch($@) if $@;
    }

    if ( defined($dev_code) && $dev_code ne "no_device_code_set" ) {
        TadoAPI_CheckStatus($hash);
        TadoAPI_NewTokenRequest($hash);

        # start the status update timer
        RemoveInternalTimer($hash);
        InternalTimer( gettimeofday() + 15, "TadoAPI_Update", $hash, 0 );     

        my $id = TadoAPI_GetHomeId($hash);
        if ( defined($id) && $id ne "" ) {
            $attr{$name}{homeID} = $id;
        }
        
    }
    else {
        $hash->{STATE} = "no_device_code_set";
    }
    return;

}

sub TadoAPI_Set {
    my $hash  = shift;
    my $name  = shift;
    my $cmd   = shift // return qq{set $name needs at least one argument};
    my $value = shift;
    my $value2 = shift;
    my $value3 = shift;

    my $message = undef;

    if ( !defined( $sets{$cmd} ) ) {
        my @cmds = ();
        for my $key ( sort keys %sets ) {
            push @cmds,
              $sets{$key} ? $key . ":" . join( ",", $sets{$key} ) : $key;
        }
        return "Unknown argument $cmd, choose one of " . join( " ", @cmds );
    }

    if ( $cmd eq 'setGeo' ) {
        return "Need at least two parameters (mobileID, Setting)" if ( !defined($value) );
        if ( $value2 eq "on" ) {
            Log3 $name, 3, "TadoAPI: set $name: processing ($cmd)";
            TadoAPI_SetGeoById( $hash, $value, 1 );
        }
        else {
            Log3 $name, 3, "TadoAPI: set $name: processing ($cmd)";
            TadoAPI_SetGeoById( $hash, $value, 0 );
        }
        TadoAPI_GetGeoById( $hash, $value );

    }
    elsif ( $cmd eq 'setZoneOverlay' ) {
        Log3 $name, 5, "TadoAPI $name" . ": " . "processing ($cmd)";
        return
"Need at least two parameters [ZoneID] [Setting] (duration in sec); Setting Info: remove=delete overlay; 0=heating power off; 1<=desired temperature (overlay)"
          if ( !defined($value2) );

        if ( $value2 eq "remove" ) {
            TadoAPI_SetZoneOverlayById( $hash, $value, "remove" );
        }
        elsif ( defined( $value3 ) ) {
            TadoAPI_SetZoneOverlayById( $hash, $value, $value2, $value3 );
        }
        elsif ( $value2 >= 0 ) {
            TadoAPI_SetZoneOverlayById( $hash, $value, $value2 );
        }
        Log3 $name, 4, "TadoAPI $name" . ": " . "$cmd finished";

    }
    elsif ( $cmd eq 'timedZoneOverlay' ) {
        Log3 $name, 5, "TadoAPI $name" . ": " . "processing ($cmd)";
        return
          "Need at least three parameters [ZoneID] [Duration (sec)] [Setting]"
          if (!defined($value3) );

        if ( defined( $value3 ) ) {
            TadoAPI_SetTimedZoneOverlay( $hash, $value, $value2, $value3 );
        }
        Log3 $name, 4, "TadoAPI $name" . ": " . "$cmd finished";

    }
    elsif ( $cmd eq 'setAllOverlays' ) {
        Log3 $name, 5, "TadoAPI $name" . ": " . "processing ($cmd)";
        return "Need at least one parameter (Setting) - Setting: remove=delete overlay; 0=heating power off; 1<=desired temperature (overlay)" if ( !defined($value) );
        if ( $value eq "remove" ) {
            TadoAPI_SetAllOverlays( $hash, "remove" );
        }
        elsif ( $value >= 0 ) {
            TadoAPI_SetAllOverlays( $hash, $value );
        }
        Log3 $name, 4, "TadoAPI $name" . ": " . "$cmd finished\n";
    }  
    elsif ( $cmd eq 'setHomePresence' ) {
        Log3 $name, 5, "TadoAPI $name" . ": " . "processing ($cmd)";
        return "Need at least one parameter (Presence) - Setting: HOME ; AWAY " if ( !defined($value) );
        if ( $value eq "HOME" ) {
            TadoAPI_SetHomePresence( $hash, "HOME" );
        }
        elsif ( $value eq "AWAY" ) {
            TadoAPI_SetHomePresence( $hash, "AWAY" );
        }
        Log3 $name, 4, "TadoAPI $name" . ": " . "$cmd finished\n";
    }
    elsif ( $cmd eq 'updateAllOverlays' ) {
        Log3 $name, 5, "TadoAPI $name" . ": " . "processing ($cmd)";
        TadoAPI_GetAllZoneOverlays($hash);
        Log3 $name, 4, "TadoAPI $name" . ": " . "$cmd finished\n";

    }
    elsif ( $cmd eq 'refreshToken' ) {
        Log3 $name, 3, "TadoAPI: set $name: processing ($cmd)";
        RemoveInternalTimer($hash);
        InternalTimer( gettimeofday() + 10, "TadoAPI_Update", $hash, 0 );
        TadoAPI_LoadToken($hash);
        Log3 $name, 3, "TadoAPI $name" . ": " . "$cmd finished\n";

    }
    elsif ( $cmd eq 'update' ) {
        Log3 $name, 3, "TadoAPI: set $name: processing ($cmd)";
        TadoAPI_UpdateFn($hash);
        Log3 $name, 3, "TadoAPI $name" . ": " . "$cmd finished\n";

    }
    elsif ( $cmd eq 'zoneUpdate' ) {
        Log3 $name, 5, "TadoAPI $name" . ": " . "processing ($cmd)";
        return "ZoneID as parameter needed" if ( !$value );
        if ( $value >= 1 ) {
            my ( $temperature, $humidity, $desiredTemp, $currentHeatingPower,
                $overlay )
              = TadoAPI_GetZoneReadingsById( $hash, $value );
            my $zoneName = TadoAPI_GetZoneNameById( $hash, $value );
            if ( defined($zoneName) ) {
                readingsBeginUpdate($hash);
                readingsBulkUpdate( $hash, "Temperatur_" . $zoneName,
                    $temperature );
                readingsBulkUpdate( $hash, "Luftfeuchtigkeit_" . $zoneName,
                    $humidity );
                readingsBulkUpdate( $hash, "Heizleistung_" . $zoneName,
                    $currentHeatingPower );
                readingsBulkUpdate( $hash, "OverlayType_" . $zoneName,
                    $overlay );
                readingsBulkUpdate( $hash, "DesiredTemp_" . $zoneName,
                    $desiredTemp );
                readingsEndUpdate( $hash, 1 );

                $message = "OK";
            }
        }
        else {
            return "Wrong ZoneID";
        }
        Log3 $name, 3, "TadoAPI $name" . ": " . "$cmd finished\n";

    }
    return $message if $message;
    return TadoAPI_Catch($@) if $@;
    return;
}

sub TadoAPI_Get {
    my $hash   = shift;
    my $name   = shift;
    my $cmd    = shift // return qq{get $name needs at least one argument};
    my $value  = shift;

    my $homeID  = $attr{$name}{homeID};
    my $message = undef;

    if ( !defined( $gets{$cmd} ) ) {
        my @cmds = ();
        for my $key ( sort keys %gets ) {
            push @cmds,
              $gets{$key} ? $key . ":" . join( ",", $gets{$key} ) : $key;
        }
        return "Unknown argument $cmd, choose one of " . join( " ", @cmds );
    }

    if ( $cmd =~ /\Qget\E/ ) {

      COMMAND_HANDLER: {
            $cmd eq "getGeo" and do {
                return "Need at least one parameter (mobileID)" if ( !defined($value) );
                return "Wrong MobileID" if ( length($value) < 6 );
                Log3 $name, 3, "TadoAPI $name" . ": " . "processing ($cmd)";
                TadoAPI_GetGeoById( $hash, $value );
                Log3 $name, 3, "TadoAPI $name" . ": " . "$cmd finished\n";
                last;
            };

            $cmd eq "getMobileDevices" and do {
                Log3 $name, 3, "TadoAPI $name" . ": " . "processing ($cmd)";
                my @data = TadoAPI_GetMobileDevices($hash);
                $message = "Device List:\n";
                for my $item (@data) {
                    $message .= $item->{'name'} . ": " . $item->{'id'} . "\n";
                }
                Log3 $name, 3, "TadoAPI $name" . ": " . "$cmd finished";
                last;
            };

            $cmd eq "getZoneDevices" and do {
                Log3 $name, 3, "TadoAPI $name" . ": " . "processing ($cmd)";
                my @devArr      = TadoAPI_GetTadoDevices($hash);
                my $devicecount = 0;
                $message = "Tado-Device(s):\n";
                for ( my $i = 0 ; $i < @devArr ; $i++ ) {
                    my $tadodevices = $devArr[$i]->{'devices'};
                    $message .= "ZoneID: " . ( $devArr[$i]->{'id'} );
                    my $spacer = 0;
                    for my $item (@$tadodevices) {
                        $message .= "\t " if ( $spacer > 0 );
                        $message .= " "
                          . $item->{'serialNo'}
                          . " Battery: "
                          . $item->{'batteryState'} . "\n";
                        $devicecount++;
                        $spacer++;
                    }
                }
                $message .=
                  "There are $devicecount Tado-Device(s) in this HomeID("
                  . $attr{$name}{homeID} . ").";
                Log3 $name, 3, "TadoAPI $name" . ": " . "$cmd finished\n";
                last;
            };

            $cmd eq "getZoneInfo" and do {
                Log3 $name, 3, "TadoAPI $name" . ": " . "processing ($cmd)";
                TadoAPI_GetZoneInfo($hash);
                my $zonecount = TadoAPI_GetZoneCount($hash);
                $message = "You have $zonecount Zones in Home "
                  . $attr{$name}{homeID} . ".\n";
                my @devArr = TadoAPI_GetTadoDevices($hash);
                for ( my $i = 0 ; $i < @devArr ; $i++ ) {
                    my $zoneID = $devArr[$i]->{'id'};
                    $message .= "Zone ID $zoneID: "
                      . TadoAPI_GetZoneNameById( $hash, $zoneID ) . "\n";
                }
                $message .= "See Logfile for more Info";
                Log3 $name, 3, "TadoAPI $name" . ": " . "$cmd finished\n";
                last;
            };
            $cmd eq "getDeviceCode" and do {
                Log3 $name, 3, "TadoAPI $name" . ": " . "processing ($cmd)";
                my ($register_url, $device_code) = TadoAPI_RegisterNewDevice($hash);
                $message = "1. Register your device at: $register_url" . "\n" 
                . "2. tado device_code for define: " . $device_code . "\n\n";
                #Tipp
                $message .= "defmod " . $name . " " . $device_code . "\n\n";
                $message .= "See Logfile for more Info";
                Log3 $name, 3, "TadoAPI $name" . ": " . "$cmd finished\n";
                last;
            };
$cmd eq "getHomePresence" and do {
                Log3 $name, 3, "TadoAPI $name" . ": " . "processing ($cmd)";
                my $presence = TadoAPI_GetHomePresence($hash);
                $message = "Home Presence: ";
                $message .=  $presence ;
                Log3 $name, 3, "TadoAPI $name" . ": " . "$cmd finished";
                last;
            };        
        }
        return $message if $message;
        return TadoAPI_Catch($@) if $@;
        return;
    }
}

sub TadoAPI_Catch {
    my $exception = shift;
    if ($exception) {
        $exception =~ /^(.*)( at.*FHEM.*)$/;
        return $1;
    }
    return;
}

sub TadoAPI_Undefine {
    my $hash = shift;
    my $name = shift;
    RemoveInternalTimer($hash);
    return;
}

sub TadoAPI_Delete {                     
	my ( $hash, $name ) = @_;       
    RemoveInternalTimer($hash);
    # Löschen von Token-File
	unlink($tokenFile . "_" . $name);

	return;
}

sub TadoAPI_CheckStatus {
    my $hash = shift;
    my $name = $hash->{NAME};

    # test api status
    my $param = {
        url      => $AuthURL,
        timeout  => 5,
        hash     => $hash,
        method   => "GET",
        header   => "",
        callback => \&TadoAPI_callback
    };

    #test if api is reachable
    Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request Status from $AuthURL";

    HttpUtils_NonblockingGet($param);
    return;
}

sub TadoAPI_LoadToken {
    my $hash          = shift;
    my $name          = $hash->{NAME};
    my $tokenFileName = $tokenFile . "_" . $name;
    my $tokenLifeTime = $hash->{TOKEN_LIFETIME};
    $tokenLifeTime = 0 if ( !defined $tokenLifeTime || $tokenLifeTime eq '' );
    my $Token = undef;

    if ($apiStatus) {
        my $TOKENFILE;
        eval{
        open( $TOKENFILE, q{<}, $tokenFileName ) or do {
          $apiStatus = 0;
          $hash->{STATE} = "Token error";
          return;
        };
        $Token = decode_json(<$TOKENFILE>) };
        close($TOKENFILE);

        Log3 $name, 5,
            "TadoAPI $name" . ": "
            . "Token expires at "
            . localtime($tokenLifeTime);

        # if token is about to expire, refresh him
        if ( ( $tokenLifeTime - 45 ) < gettimeofday() ) {
            Log3 $name, 5,
                "TadoAPI $name" . ": " . "Access Token will expire soon, refreshing";
            $Token = TadoAPI_TokenRefresh($hash);
            TadoAPI_CheckStatus($hash);
        }
        
        return $Token if $Token;
    }
    TadoAPI_CheckStatus($hash);
    return;
}

sub TadoAPI_RegisterNewDevice {
    my $hash          = shift;
    my $name          = $hash->{NAME};
    my $tokenFileName = $tokenFile . "_" . $name;
    

    my $data = {
        client_id     => $client_id,
        scope         => $scope,
        grant_type    => 'urn:ietf:params:oauth:grant-type:device_code'
    };

    my $param = {
        url     => 'https://login.tado.com/oauth2/device_authorize',
        method  => 'POST',
        timeout => 5,
        hash    => $hash,
        data    => $data
    };

    #Log3 $name, 5, 'Blocking GET: ' . Dumper($param);
    Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request NEW $AuthURL";
    my ( $err, $returnData ) = HttpUtils_BlockingGet($param);

    if ( $err ne "" ) {
        Log3 $name, 3,
            "TadoAPI $name" . ": "
          . "RegisterNewDevice: Error while requesting "
          . $param->{url}
          . " - $err";
    }
    elsif ( $returnData ne "" ) {
        Log3 $name, 5, "Device registration URL: " . $param->{url} . " - returned: $returnData";
        my $decoded_data = eval { decode_json($returnData) };
        if ($@) {
            Log3 $name, 3, "TadoAPI $name" . ": "
              . "RegisterNewDevice: decode_json failed, invalid json. error: $@ ";
        }
        else {
            Log3 $name, 3,
                "TadoAPI $name" . ": "
              . "New Device - Please go to URL: "
              . $decoded_data->{'verification_uri_complete'};

            $hash->{STATE} = "OK";

            return ($decoded_data->{'verification_uri_complete'}, $decoded_data->{'device_code'});
        }
    }
    return;
}

sub TadoAPI_NewTokenRequest {
    my $hash          = shift;
    my $name          = $hash->{NAME};
    my $device_code   = $hash->{TADO_DEV_CODE};
    my $tokenFileName = $tokenFile . "_" . $name;
    my $Token         = undef;

    Log3 $name, 5, "TadoAPI $name" . ": " . "calling NewTokenRequest()";

    # Check if 'refresh_token' exists or  a new token is needed
    my $TOKENFILE;
    eval {
        open( $TOKENFILE, q{<}, $tokenFileName ) or do {
            return; 
        };
    $Token = decode_json(<$TOKENFILE>) };
    close($TOKENFILE);

    if (exists $Token->{'refresh_token'}) {
        Log3 $name, 3, "TadoAPI $name" . ": " . "Refresh token exists - OK\n";
        return;
    } else {
        Log3 $name, 3, "TadoAPI $name" . ": " . "No Refresh token - NewTokenRequest start\n";
    }


    my $data = {
        client_id     => $client_id,
        device_code => $device_code,
        grant_type    => 'urn:ietf:params:oauth:grant-type:device_code'
    };

    my $param = {
        url     => $AuthURL,
        method  => 'POST',
        timeout => 5,
        hash    => $hash,
        data    => $data
    };

    #Log3 $name, 5, 'Blocking GET: ' . Dumper($param);
    Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request NEW Token from: $AuthURL";
    my ( $err, $returnData ) = HttpUtils_BlockingGet($param);

    if ( $err ne "" ) {
        Log3 $name, 3,
            "TadoAPI $name" . ": "
          . "NewTokenRequest: Error while requesting "
          . $param->{url}
          . " - $err";
    }
    elsif ( $returnData ne "" ) {
        Log3 $name, 5, "url " . $param->{url} . " returned: $returnData";
        my $decoded_data = eval { decode_json($returnData) };
        if ($@) {
            Log3 $name, 3, "TadoAPI $name" . ": "
              . "NewTokenRequest: decode_json failed, invalid json. error: $@ ";
        }
        else {
            #write token data in file
            open( my $TOKENFILE, q{>}, $tokenFileName ) or do {
              $apiStatus = 0;
              $hash->{STATE} = "Token error";
              return; 
            };
            print $TOKENFILE $returnData . "\n";
            close($TOKENFILE);

            # token lifetime management
            if ( defined($decoded_data->{'expires_in'}) ){
              $hash->{TOKEN_LIFETIME} = gettimeofday() + $decoded_data->{'expires_in'};
            }
            $hash->{TOKEN_LIFETIME_HR} = localtime( $hash->{TOKEN_LIFETIME} );
            Log3 $name, 5,
                "TadoAPI $name" . ": "
              . "Retrived new authentication token successfully. Valid until "
              . localtime( $hash->{TOKEN_LIFETIME} );
            $hash->{STATE} = "reachable";
            # refresh FHEM device
            TadoAPI_UpdateFn($hash);
            return $decoded_data;
        }
    }
    return;
}




sub TadoAPI_TokenRefresh {
    my $hash          = shift;
    my $name          = $hash->{NAME};
    my $tokenFileName = $tokenFile . "_" . $name;
    my $Token         = undef;

    # load token
    my $TOKENFILE;
    eval {
    open( $TOKENFILE, q{<}, $tokenFileName ) or do {
          $apiStatus = 0;
          $hash->{STATE} = "Tokenfile error";
          return; 
        };
    $Token = decode_json(<$TOKENFILE>) };
    close($TOKENFILE);



    my $data = {
        client_id     => $client_id,
        scope         => $scope,
        grant_type    => 'refresh_token',
        refresh_token => $Token->{'refresh_token'}
    };

    my $param = {
        url     => $AuthURL,
        method  => 'POST',
        timeout => 5,
        hash    => $hash,
        data    => $data
    };

    #Log3 $name, 5, 'Blocking GET TokenRefresh: ' . Dumper($param);
    Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request refresh $AuthURL";
    my ( $err, $returnData ) = HttpUtils_BlockingGet($param);

    if ( $err ne "" ) {
        Log3 $name, 3,
            "TadoAPI $name" . ": "
          . "TokenRefresh: Error in token retrival while requesting "
          . $param->{url}
          . " - $err";
        $hash->{STATE} = "error";
    }

    elsif ( $returnData ne "" ) {
        Log3 $name, 5, "url " . $param->{url} . " returned: $returnData";
        my $decoded_data = eval { decode_json($returnData); };

        if ($@) {
            Log3 $name, 3,
              "TadoAPI $name" . ": "
              . "TokenRefresh: decode_json failed, invalid json. error:$@\n"
              if $@;
            $hash->{STATE} = "error";
        }
        elsif (exists $decoded_data->{error}) {
            Log3 $name, 3, "TadoAPI $name: Error in TokenData - " . $decoded_data->{error} . ": " . ($decoded_data->{error_description} // "No description");
            $hash->{STATE} = "error";
            return;
        } else {
            #write token data in file
            open( $TOKENFILE, q{>}, $tokenFileName ) or do {
              $apiStatus = 0;
              $hash->{STATE} = "Token open error";
              return; 
            };
            print $TOKENFILE $returnData . "\n";
            close($TOKENFILE);

            # token lifetime management
            $hash->{TOKEN_LIFETIME} =
              gettimeofday() + $decoded_data->{'expires_in'};
            $hash->{TOKEN_LIFETIME_HR} = localtime( $hash->{TOKEN_LIFETIME} );
            Log3 $name, 5,
                "TadoAPI $name" . ": "
              . "TokenRefresh: Refreshed authentication token successfully. Valid until "
              . localtime( $hash->{TOKEN_LIFETIME} );
            $hash->{STATE} = "reachable";
            return $decoded_data;
        }
    }
    return;
}

sub TadoAPI_Update {
    my $hash = shift;
    my $name = $hash->{NAME};

    Log3 $name, 5, "TadoAPI $name" . ": " . "TadoAPI_Update called";

    if ( AttrVal( $name, "disable", 0 ) == 1 ){
            Log3 $name, 3, "TadoAPI: $name global disabled (attr) :-(";
            $hash->{STATE} = "disabled";
            return;
    }

    my $nextTimer = "none";
    my $intervall = 300;

    $intervall = $attr{$name}{updateIntervall}
      if ( defined( $attr{$name}{updateIntervall} )
        && $attr{$name}{updateIntervall} =~ m/^-?\d+$/ );
    $nextTimer = gettimeofday() + $intervall;
    $hash->{NEXT_UPDATE} = localtime($nextTimer);

    Log3 $name, 5, "TadoAPI $name" . ": " . "Next Timer = $nextTimer";

    RemoveInternalTimer($hash);
    InternalTimer( $nextTimer, "TadoAPI_Update", $hash, 0 );

    # update subs
    TadoAPI_UpdateFn($hash);
    return;
}

######################## tado methods ########################
##############################################################

sub TadoAPI_SetZoneOverlayById {
    my $hash     = shift;
    my $zoneID   = shift;
    my $setting  = shift;
    my $duration = shift;

    my $name             = $hash->{NAME};
    my $homeID           = $attr{$name}{homeID};
    my $URL              = $QueryURL . qq{/$homeID/zones/$zoneID/overlay};
    my $CurrentTokenData = TadoAPI_LoadToken($hash);

    if ( defined($CurrentTokenData) ) {
        my $method = "";
        my $myjson = undef;

        Log3 $name, 5,
            "TadoAPI $name"
          . ": SetOverlay for Zone $zoneID (Setting: "
          . $setting . ") - "
          . "query-URL: $URL";

        my $dt = time();
        $dt += $duration if defined($duration);


        # remove overlay & lock
        if ( $setting eq "remove" ) {
            $method = "DELETE";
            Log3 $name, 3,
              "TadoAPI $name" . ": " . "Deleting Overlay for Zone $zoneID";
              delete( $hash->{helper}{LockedZones}{$zoneID} );
        }

        # turn heating of
        elsif ( $setting == 0 ) {

            # turn off for timer
            if ( defined($duration) && $duration > 0 ) {
                $method = "PUT";
                $myjson = {
                    type    => "MANUAL",
                    setting => {
                        type  => "HEATING",
                        power => "OFF"
                    },
                    termination => {
                        type              => "TIMER",
                        durationInSeconds => $duration,
                        expiry => strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime($dt) )
                    }
                };
                Log3 $name, 3, "TadoAPI $name" . ": "
                  . "Timer Overlay for Zone $zoneID . Power off for: $duration seconds";
            }

            # infinite off
            else {
                $method = "PUT";
                $myjson = {
                    setting => {
                        type  => "HEATING",
                        power => "OFF",
                    },
                    termination => {
                        type => "MANUAL"
                    },
                };
            }
        }
        elsif ( $setting > 0 ) {

            # set timed overlay
            if ( defined($duration) && $duration > 0 ) {
                $method = "PUT";
                $myjson = {
                    type    => "MANUAL",
                    setting => {
                        type        => "HEATING",
                        power       => "ON",
                        temperature => {
                            celsius => $setting
                        }
                    },
                    termination => {
                        type              => "TIMER",
                        durationInSeconds => $duration,
                        expiry => strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime($dt) ),
                    }
                };
                Log3 $name, 3, "TadoAPI $name" . ": "
                  . "Set Timer Overlay for Zone $zoneID with $duration seconds expire.";

                # set lock for this zone
                $hash->{helper}{LockedZones}{$zoneID} = "locked";
            }
            else {
                # infinite setting
                $method = "PUT";
                $myjson = {
                    setting => {
                        type        => "HEATING",
                        power       => "ON",
                        temperature => {
                            celsius => $setting
                        },
                    },
                    termination => {
                        type => "MANUAL"
                    },
                };
            }
        }

        $myjson = encode_json($myjson) if ( defined($myjson) );

        my $request = {
            url    => $URL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" =>
"$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method   => $method,
            timeout  => 5,
            callback => \&Tado_UpdateZoneOverlayCallback,
            hash     => $hash,
            setting  => $setting,
            zoneID   => $zoneID,
            data     => $myjson
        };

        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $URL";
        HttpUtils_NonblockingGet($request);
    }
    return;
}

sub TadoAPI_SetAllOverlays {
    my $hash     = shift;
    my $setting  = shift;
    my $duration = shift;

    my $name   = $hash->{NAME};
    my $homeID = $attr{$name}{homeID};
    my @zones  = TadoAPI_GetTadoDevices($hash);

    for ( my $i = 0 ; $i < @zones ; $i++ ) {
        my $zoneID = $zones[$i]->{'id'};
        if ( defined($duration) && $duration > 0 ) {
            TadoAPI_SetZoneOverlayById( $hash, $zoneID, $setting, $duration );
        }
        else {
            TadoAPI_SetZoneOverlayById( $hash, $zoneID, $setting );
        }
    }
    return;
}

sub TadoAPI_GetAllZoneOverlays {
    my $hash = shift;

    my $name  = $hash->{NAME};
    my @zones = TadoAPI_GetTadoDevices($hash);

    for my $zone (@zones) {
        my $zoneID   = $zone->{'id'};
        my $zoneName = TadoAPI_ReplaceUmlaute( $zone->{'name'} );
        my ( $temperature, $humidity, $desiredTemp, $currentHeatingPower,
            $overlay )
          = TadoAPI_GetZoneReadingsById( $hash, $zoneID );
        readingsSingleUpdate( $hash, "OverlayType_" . $zoneName, $overlay, 1 );
    }
    return;
}

sub TadoAPI_UpdateFn {
    my $hash = shift;

    my $name             = $hash->{NAME};
    my $CurrentTokenData = TadoAPI_LoadToken($hash);
    my $homeID           = $attr{$name}{homeID};

    return $hash->{STATE} = "disabled" if ( AttrVal( $name, "disable", 0 ) == 1 );

    if ( $apiStatus == 1 && defined($CurrentTokenData) ) {

        # zone specific updates
        my $URL     = $QueryURL . qq{/$homeID/zones};
        my $request = {
            url    => $URL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" =>
"$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method            => 'GET',
            timeout           => 25,
            incrementalTimout => 1,
            hash              => $hash,
            callback          => \&TadoAPI_UpdateAllZoneReadingsCallback
        };
        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "UpdFN: Request $URL";
        HttpUtils_NonblockingGet($request);

        # mobile devices
        $URL     = $QueryURL . qq{/$homeID/mobileDevices};
        $request = {
            url    => $URL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" =>
"$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method            => 'GET',
            timeout           => 7,
            incrementalTimout => 1,
            callback          => \&TadoAPI_UpdateMobileReadingsCallback,
            hash              => $hash
        };
        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $URL";
        HttpUtils_NonblockingGet($request);
    }
    return;
}

########################################################################################################################################################################
# Callback Subs
########################################################################################################################################################################
sub TadoAPI_callback {
    my $param = shift;
    my $err   = shift;
    my $data  = shift;

    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    
    $param->{code} = 0 unless defined $param->{code};

    if ( $param->{code} == 405 || $param->{code} == 400 ) {
        $apiStatus = 1;
        $hash->{STATE} = "reachable";
        Log3 $name, 5,
            "TadoAPI $name" . ": "
          . "API is reachable. Callback Status: "
          . $param->{code};

    }
    else {
        $apiStatus = 0;
        $hash->{STATE} = "error";
        Log3 $name, 3,
          "TadoAPI $name" . ": " . "API error (TadoAPI_callback): apiStatus $apiStatus ($err)";
    }
    return;
}

sub TadoAPI_UpdateAllZoneReadingsCallback {
    my $param = shift;
    my $err   = shift;
    my $data  = shift;

    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ( $err ne "" ) {
        Log3 $name, 3,
            "Error in TadoAPI_UpdateZoneCallback while requesting "
          . $param->{url}
          . " - $err";
    }
    elsif ( $data ne "" ) {
        Log3 $name, 5, "url " . $param->{url} . " returned: $data";
        my $decoded_data = eval { decode_json($data) };

        # if api returns error
        eval { my $error = @$decoded_data; };

        if ($@) {
            Log3 $name, 3,
              "TadoAPI $name" . ": "
              . "UpdateAllZonesCallback: decode_json failed, invalid json. error:$@\n"
              if $@;
            Log3 $name, 3,
                "TadoAPI $name" . ": "
              . "UpdateAllZonesCallback: Error in decoded data, Code: "
              . $decoded_data->{'errors'}->[0]->{'code'}
              if ( exists( $decoded_data->{'errors'}->[0]->{'code'} ) );
            $hash->{LastRequest} = "error";
        }
        else {
            readingsBeginUpdate($hash);
            for my $zone (@$decoded_data) {
                my $zoneID   = $zone->{'id'};
                my $zoneName = TadoAPI_ReplaceUmlaute( $zone->{'name'} );
                Log3 $name, 5, "TadoAPI $name" . ": "
                  . "Set Reading Update for Zone $zoneID ";

                my ( $temperature, $humidity, $desiredTemp,
                    $currentHeatingPower, $overlay )
                  = TadoAPI_GetZoneReadingsById( $hash, $zoneID );

                # updates zone readings
                readingsBulkUpdate( $hash, "ZoneID_" . $zoneName, $zoneID );
                readingsBulkUpdate( $hash, "Temperatur_" . $zoneName, $temperature );
                readingsBulkUpdate( $hash, "Luftfeuchtigkeit_" . $zoneName, $humidity );
                readingsBulkUpdate( $hash, "Heizleistung_" . $zoneName, $currentHeatingPower );
                readingsBulkUpdate( $hash, "OverlayType_" . $zoneName, $overlay );
                readingsBulkUpdate( $hash, "DesiredTemp_" . $zoneName, $desiredTemp );

                # iterate through all devices in zone
                my $devices = $zone->{'devices'};
                for my $device (@$devices) {
                    readingsBulkUpdate(
                        $hash,
                        "Battery_" . $device->{'serialNo'},
                        $device->{'batteryState'}
                    );
                    readingsBulkUpdate(
                        $hash,
                        "ChildLockEnabled_" . $device->{'serialNo'},
                        $device->{'childLockEnabled'}
                    );
                }
            }
            my $presence = TadoAPI_GetHomePresence($hash);
            readingsBulkUpdate( $hash, "HomePresence", $presence );
            readingsEndUpdate( $hash, 1 );
        }
        my $zonecount = TadoAPI_GetZoneCount($hash);
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, "ActiveZones", $zonecount );
        readingsEndUpdate( $hash, 0 );
        $hash->{LastRequest} = "OK";
    }
    return;
}

sub Tado_UpdateZoneOverlayCallback {
    my $param  = shift;
    my $err    = shift;
    my $data   = shift;

    my $hash    = $param->{hash};
    my $name    = $hash->{NAME};
    my $zoneID  = $param->{zoneID};
    my $setting = $param->{setting};

    if ( $err ne "" ) {
        Log3 $name, 3,
            "Error in UpdateZoneOverlayCallback while requesting "
          . $param->{url}
          . " - $err";
    }

    elsif ( $data ne "" ) {
        Log3 $name, 5, "url " . $param->{url} . " returned: $data";
        Log3 $name, 3, "TadoAPI $name" . ": "
          . "set (async) Overlay for Zone $zoneID to: $setting";

    }

    # finaly update readings
    my ( $temperature, $humidity, $desiredTemp, $currentHeatingPower, $overlay )
      = TadoAPI_GetZoneReadingsById( $hash, $zoneID );
    my $zoneName = TadoAPI_GetZoneNameById( $hash, $zoneID );
    if ( defined($zoneName) ) {

        # updates zone readings
        readingsBeginUpdate($hash);

 # readingsBulkUpdate($hash, "Temperatur_" . $zoneName, $temperature);
 # readingsBulkUpdate($hash, "Luftfeuchtigkeit_" . $zoneName, $humidity);
 # readingsBulkUpdate($hash, "Heizleistung_" . $zoneName, $currentHeatingPower);
        readingsBulkUpdate( $hash, "OverlayType_" . $zoneName, $overlay );
        readingsBulkUpdate( $hash, "DesiredTemp_" . $zoneName, $desiredTemp );

        # lock zone if timed overlay
        if ( exists( $hash->{helper}->{LockedZones}{$zoneID} ) ) {
            readingsBulkUpdate( $hash, "Zone" . $zoneID . "Lock", "timer" );
            readingsEndUpdate( $hash, 1 );
        }
        else {
            readingsEndUpdate( $hash, 1 );
            readingsDelete( $hash, "Zone" . $zoneID . "Lock" );
        }
    }
    return;
}

sub TadoAPI_LogInfoCallback {
    my $param = shift;
    my $err   = shift;
    my $data  = shift;

    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ( $err ne "" ) {
        Log3 $name, 3,
            "Error in LogInfoCallback while requesting "
          . $param->{url}
          . " - $err";
    }

    elsif ( $data ne "" ) {
        Log3 $name, 3,
          "TadoAPI $name" . ": " . $param->{infotext} . ":\n" . $data . "\n";
    }
    return;
}

sub TadoAPI_SetGeoByIdCallback {
    my $param = shift; 
    my $err   = shift; 
    my $data  = shift;

    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ( $err ne "" ) {
        Log3 $name, 3,
            "Error in TadoAPI_SetGeoByIdCallback while requesting "
          . $param->{url}
          . " - $err";
    }
    elsif ( $data ne "" ) {
        Log3 $name, 3, "SetGeoById URL: " . $param->{url} . " returned: $data";
    }
    return;
}

sub TadoAPI_UpdateMobileReadingsCallback {
    my $param = shift;
    my $err   = shift;
    my $data  = shift;

    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ( $err ne "" ) {
        Log3 $name, 3,
            "Error in UpdateMobileReadingsCallback while requesting "
          . $param->{url}
          . " - $err";
    }

    elsif ( $data ne "" ) {
        Log3 $name, 5, "url " . $param->{url} . " returned: $data";
        my $decoded_data = eval { decode_json($data) };

        # if api returns error
        eval { my $error = @$decoded_data; };

        if ($@) {
            Log3 $name, 3,
              "TadoAPI $name" . ": "
              . "Decode_json failed, invalid json. error:$@\n"
              if $@;
            Log3 $name, 3,
                "TadoAPI $name" . ": "
              . "Error in UpdateMobileReadingsCallback, Code: "
              . $decoded_data->{'errors'}->[0]->{'code'};
            $hash->{LastRequest} = "error";
        }
        else {
            for my $item (@$decoded_data) {
                TadoAPI_GetGeoById( $hash, $item->{'id'}, $item );
            }
        }
    }
    return;
}

sub TadoAPI_SetHomePresenceCallback {
    my $param = shift; 
    my $err   = shift; 
    my $data  = shift;

    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ( $err ne "" ) {
        Log3 $name, 3,
            "Error in TadoAPI_SetHomePresenceCallback while requesting "
          . $param->{url}
          . " - $err";
    }
    elsif ( $data ne "" ) {
        Log3 $name, 3, "SetHomePresence URL: " . $param->{url} . " returned: $data";
    }
    return;
}

sub TadoAPI_GetZoneInfo {
    my $hash             = shift;
    my $name             = $hash->{NAME};
    my $homeID           = $attr{$name}{homeID};
    my $CurrentTokenData = TadoAPI_LoadToken($hash);

    if ( defined($CurrentTokenData) ) {

        # HomeInfo
        my $URL     = qq{https://my.tado.com/api/v2/me};
        my $request = {
            url    => $URL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method   => 'GET',
            timeout  => 8,
            infotext => "HomeInfos",
            hash     => $hash,
            callback => \&TadoAPI_LogInfoCallback
        };

        HttpUtils_NonblockingGet($request);

        # TadoDevicesInfo
        $URL     = $QueryURL . qq{/$homeID/zones};
        $request = {
            url    => $URL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method   => 'GET',
            timeout  => 3,
            infotext => "Tado Devices Info",
            hash     => $hash,
            callback => \&TadoAPI_LogInfoCallback
        };
        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $URL";
        HttpUtils_NonblockingGet($request);

        # Mobileinfo
        $URL     = $QueryURL . qq{/$homeID/mobileDevices};
        $request = {
            url    => $URL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method   => 'GET',
            timeout  => 3,
            infotext => "Mobile Devices Info",
            hash     => $hash,
            callback => \&TadoAPI_LogInfoCallback
        };
        HttpUtils_NonblockingGet($request);

        my @mobDev = TadoAPI_GetMobileDevices($hash);
        for ( my $i = 0 ; $i < @mobDev ; $i++ ) {
            my $mobileID = $mobDev[$i]->{'id'};
            $URL = $QueryURL . qq{/$homeID/mobileDevices/$mobileID/settings};
            $request = {
                url    => $URL,
                header => {
                    "Content-Type" => "application/json;charset=UTF-8",
                    "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
                },
                method   => 'GET',
                timeout  => 3,
                infotext => "Mobile Device $mobileID",
                hash     => $hash,
                callback => \&TadoAPI_LogInfoCallback
            };
            Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $URL";
            HttpUtils_NonblockingGet($request);
        }

        # zones
        my @devArr = TadoAPI_GetTadoDevices($hash);
        for ( my $i = 0 ; $i < @devArr ; $i++ ) {
            my $zoneID = $devArr[$i]->{'id'};
            $URL = $QueryURL . qq{/$homeID/zones/$zoneID/state};
            my $infotext =
                "ZoneID $zoneID ("
              . TadoAPI_GetZoneNameById( $hash, $zoneID )
              . ") Status";
            $request = {
                url    => $URL,
                header => {
                    "Content-Type" => "application/json;charset=UTF-8",
                    "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
                },
                method   => 'GET',
                timeout  => 3,
                infotext => $infotext,
                hash     => $hash,
                callback => \&TadoAPI_LogInfoCallback
            };
            Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $URL";
            HttpUtils_NonblockingGet($request);
        }
    }
    return;
}

sub TadoAPI_SetGeoById {
    my $hash      = shift;
    my $mobileID  = shift;
    my $geo       = shift;

    my $name   = $hash->{NAME};
    my $homeID = $attr{$name}{homeID};
    my $URL    = $QueryURL . qq{/$homeID/mobileDevices/$mobileID/settings};
    my $CurrentTokenData = TadoAPI_LoadToken($hash);
    my $data             = {};

    if ( defined($CurrentTokenData) ) {
        if ($geo) {
            $data = { geoTrackingEnabled => "true" };
        }
        else {
            $data = { geoTrackingEnabled => "false" };
        }

        $data = encode_json($data);

        my $request = {
            url    => $URL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method   => 'PUT',
            timeout  => 3,
            mobileID => $mobileID,
            data     => $data,
            hash     => $hash,
            callback => \&TadoAPI_SetGeoByIdCallback
        };
        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $URL";
        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "PUT setting $data";
        HttpUtils_NonblockingGet($request);
    }
    return;
}

# helper sub for fhem tablet-ui thermostat widget: set timedZoneOverlay <zoneID> <duration> <setting>
sub TadoAPI_SetTimedZoneOverlay {
    my $hash      = shift;
    my $zoneID    = shift;
    my $duration  = shift;
    my $setting   = shift;

    my $name = $hash->{NAME};
    TadoAPI_SetZoneOverlayById( $hash, $zoneID, $setting, $duration );
    return;
}

sub TadoAPI_GetHomeId {
    # returns first home id only
    my $hash             = shift;
    my $name             = $hash->{NAME};
    my $CurrentTokenData = TadoAPI_LoadToken($hash);

    if ( defined($CurrentTokenData) ) {
        my $param = {
            url    => $DataURL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method  => 'GET',
            timeout => 2,
            hash    => $hash,
        };

        #Log3 $name, 5, 'Blocking GET: ' . Dumper($param);
        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $DataURL";
        my ( $err, $data ) = HttpUtils_BlockingGet($param);

        if ( $err ne "" ) {
            Log3 $name, 3,
                "TadoAPI $name" . ": "
              . "GetHomeId: Error while requesting "
              . $param->{url}
              . " - $err";
        }
        elsif ( $data ne "" ) {
            Log3 $name, 5, "URL " . $param->{url} . " returned: $data";
            my $decoded_data = eval { decode_json($data) };
            if ($@) {
                Log3 $name, 3,
                  "TadoAPI $name" . ": "
                  . "GetHomeId: Decode_json failed, invalid json. error:$@"
                  if $@;
                $hash->{LastRequest} = "error";
            }
            else {
                $hash->{LastRequest} = "OK";
                return $decoded_data->{'homes'}->[0]->{'id'}
                  if ( exists( $decoded_data->{'homes'} ) );
            }
        }
    }
    return;
}

sub TadoAPI_GetGeoById {

# returns geo setting and distance from home; takes an item object or querys itself
    my $hash       = shift;
    my $mobileID   = shift;
    my $item       = shift;

    my $name   = $hash->{NAME};
    my $homeID = $attr{$name}{homeID};
    my $URL    = $QueryURL . qq{/$homeID/mobileDevices};

    if ( !defined($item) ) {
        my $CurrentTokenData = TadoAPI_LoadToken($hash);

        if ( defined($CurrentTokenData) ) {
            my $param = {
                url    => $URL,
                header => {
                    "Content-Type" => "application/json;charset=UTF-8",
                    "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
                },
                method  => 'GET',
                timeout => 4,
                hash    => $hash,
            };

            #Log3 $name, 5, 'Blocking GET: ' . Dumper($param);
            Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $URL";
            my ( $err, $data ) = HttpUtils_BlockingGet($param);

            if ( $err ne "" ) {
                Log3 $name, 3,
                    "TadoAPI $name" . ": "
                  . "GetGeoById: Error while requesting "
                  . $param->{url}
                  . " - $err";
            }
            elsif ( $data ne "" ) {
                Log3 $name, 5,
                  "GetGeoById URL: " . $param->{url} . " returned: $data";
                my $decoded_data = eval { decode_json($data) };
                if ($@) {
                    Log3 $name, 3,
                      "TadoAPI $name" . ": "
                      . "GetGeoById: Decode_json failed, invalid json. error:$@\n"
                      if $@;
                    Log3 $name, 3,
                        "TadoAPI $name" . ": "
                      . "GetGeoById: Error in UpdateMobileReadingsCallback, Code: "
                      . $decoded_data->{'errors'}->[0]->{'code'};
                    $hash->{LastRequest} = "error";
                }
                else {
                    for my $item (@$decoded_data) {
                        if ( $item->{'id'} eq $mobileID ) {
                            return my ( $setting, $distance ) =
                              TadoAPI_ParseMobileItem( $hash, $item );
                        }
                    }
                }
            }
        }
    }
    elsif ( defined($item) ) {
        Log3 $name, 5,
          "TadoAPI $name" . ": " . "GetGeoById: parsing passed item";
        return my ( $setting, $distance ) =
          TadoAPI_ParseMobileItem( $hash, $item );
    }
    return;
}

sub TadoAPI_ParseMobileItem {
    my $hash = shift;
    my $item = shift;

    my $name    = $hash->{NAME};
    my $setting = 0;
    $setting = 1 if $item->{'settings'}->{'geoTrackingEnabled'};
    my $distance = "-";
    $distance = $item->{'location'}->{'relativeDistanceFromHomeFence'}
      if $setting;

    readingsBeginUpdate($hash);
    readingsBulkUpdate(
        $hash,
        "GeoTracking_" . $item->{'id'},
        $item->{'settings'}->{'geoTrackingEnabled'}
    );
    if ( defined( $item->{'location'}->{'atHome'} )
        && $item->{'location'}->{'atHome'} )
    {
        # present
        readingsBulkUpdate( $hash, "GeoLocation_" . $item->{'id'}, "present" );
    }
    elsif ( defined( $item->{'location'}->{'atHome'} ) ) {

        # away
        readingsBulkUpdate( $hash, "GeoLocation_" . $item->{'id'}, "away" );
    }
    else {
        # no state
        readingsDelete( $hash, "GeoLocation_" . $item->{'id'} );
    }
    readingsBulkUpdate( $hash, "GeoDistance_" . $item->{'id'}, $distance )
      if $setting && $attr{$name}{showPosData};
    readingsDelete( $hash, "GeoDistance_" . $item->{'id'} )
      if !defined( $attr{$name}{showPosData} )
      || $attr{$name}{showPosData} == 0
      || !$setting;
    readingsEndUpdate( $hash, 1 );

    $hash->{LastRequest} = "OK";
    return ( $setting, $distance );
}

sub TadoAPI_GetMobileDevices {
    my $hash             = shift;

    my $name             = $hash->{NAME};
    my $homeID           = $attr{$name}{homeID};
    my $URL              = $QueryURL . qq{/$homeID/mobileDevices};
    my $CurrentTokenData = TadoAPI_LoadToken($hash);

    if ( defined($CurrentTokenData) ) {
        my $param = {
            url    => $URL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method  => 'GET',
            timeout => 2,
            hash    => $hash
        };

        #Log3 $name, 5, 'Blocking GET: ' . Dumper($param);
        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $URL";
        my ( $err, $data ) = HttpUtils_BlockingGet($param);

        if ( $err ne "" ) {
            Log3 $name, 3,
                "TadoAPI $name" . ": "
              . "GetMobileDevices: Error while requesting "
              . $param->{url}
              . " - $err";
        }
        elsif ( $data ne "" ) {
            my @devices = ();
            Log3 $name, 5, "url " . $param->{url} . " returned: $data";
            my $decoded_data = eval { decode_json($data) };
            if ($@) {
                Log3 $name, 3, "TadoAPI $name" . ": "
                  . "GetMobileDevices: decode_json failed, invalid json. error:$@\n";
            }
            else {
                if ( ref($decoded_data) eq 'ARRAY' ) {
                    for my $item (@$decoded_data) {
                        push @devices, $item;
                    }

                    # default case
                    return @devices;
                }
                elsif ( ref($decoded_data) eq 'HASH' ) {

                    # error, api response is a hash in case of error
                    Log3 $name, 3,
                        "TadoAPI $name" . ": "
                      . "GetMobileDevices: "
                      . $decoded_data->{'errors'}->[0]->{'code'}
                      if ( exists( $decoded_data->{'errors'} ) );
                }
            }
        }
    }
    return;
}

sub TadoAPI_GetZoneCount {
    my $hash             = shift;

    my $name             = $hash->{NAME};
    my $homeID           = $attr{$name}{homeID};
    my $URL              = $QueryURL . qq{/$homeID/zones};
    my $zonecount        = 0;
    my $CurrentTokenData = TadoAPI_LoadToken($hash);

    if ( defined($CurrentTokenData) ) {
        my $param = {
            url    => $URL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" =>
"$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method  => 'GET',
            timeout => 2,
            hash    => $hash
        };

        #Log3 $name, 5, 'Blocking GET: ' . Dumper($param);
        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $URL";
        my ( $err, $data ) = HttpUtils_BlockingGet($param);

        if ( $err ne "" ) {
            Log3 $name, 3,
                "TadoAPI $name" . ": "
              . "GetZoneCount: Error while requesting "
              . $param->{url}
              . " - $err";
        }
        elsif ( $data ne "" ) {
            my @devices = ();
            Log3 $name, 5, "url " . $param->{url} . " returned: $data";
            my $decoded_data = eval { decode_json($data) };

            if ($@) {
                Log3 $name, 3, "TadoAPI $name" . ": "
                  . "GetZoneCount: decode_json failed, invalid json. error:$@\n";
            }
            else {
                if ( ref($decoded_data) eq 'ARRAY' ) {
                    for my $item (@$decoded_data) {
                        $zonecount++;
                    }
                    return $zonecount;
                }
                elsif ( ref($decoded_data) eq 'HASH' ) {
                    Log3 $name, 3,
                        "TadoAPI $name" . ": "
                      . "GetZoneCount: "
                      . $decoded_data->{'errors'}->[0]->{'code'}
                      if ( exists( $decoded_data->{'errors'} ) );
                }
            }
        }
    }
    return;
}

sub TadoAPI_GetZoneNameById {
    my $hash     = shift;
    my $zoneID   = shift;

    my $name     = $hash->{NAME};
    my $zoneName = undef;
    my @zones    = TadoAPI_GetTadoDevices($hash);

    for my $zone (@zones) {
        if ( $zone->{'id'} == $zoneID ) {
            $zoneName = TadoAPI_ReplaceUmlaute( $zone->{'name'} );
            return $zoneName;
        }
    }
    Log3 $name, 3,
      "TadoAPI $name" . ": " . "Error GetZoneNameById: Wrong zone ID ($zoneID)";
    return;
}

sub TadoAPI_GetZoneReadingsById {
    my $hash   = shift;
    my $zoneID = shift;

    my $name                = $hash->{NAME};
    my $homeID              = $attr{$name}{homeID};
    my $URL                 = $QueryURL . qq{/$homeID/zones/$zoneID/state};
    my $temperature         = 0;
    my $humidity            = 0;
    my $desiredTemp         = 0;
    my $currentHeatingPower = 0;
    my $overlay             = 0;
    my $CurrentTokenData    = TadoAPI_LoadToken($hash);

    if ( defined($CurrentTokenData) ) {
        my $param = {
            url    => $URL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method  => 'GET',
            timeout => 4,
            hash    => $hash
        };

        #Log3 $name, 5, 'Blocking GET: ' . Dumper($param);
        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $URL";
        my ( $err, $data ) = HttpUtils_BlockingGet($param);

        if ( $err ne "" ) {
            Log3 $name, 3,
                "TadoAPI $name" . ": "
              . "GetZoneReadingsById: Error while requesting "
              . $param->{url}
              . " - $err";
        }
        elsif ( $data ne "" ) {
            Log3 $name, 5, "url " . $param->{url} . " returned: $data";
            my $decoded_data = eval { decode_json($data) };
            if ($@) {
                Log3 $name, 3, "TadoAPI $name" . ": "
                  . "GetZoneReadingsById: Zone $zoneID decode_json failed, invalid json. error:$@\n";
            }
            else {
                $temperature = sprintf( "%.1f",
                    $decoded_data->{'sensorDataPoints'}->{'insideTemperature'}
                      ->{'celsius'} );
                $humidity = $decoded_data->{'sensorDataPoints'}->{'humidity'}
                  ->{'percentage'};
                if ( $decoded_data->{'setting'}->{'power'} eq "OFF" ) {
                    $desiredTemp = "OFF";
                }
                else {
                    $desiredTemp =
                      $decoded_data->{'setting'}->{'temperature'}->{'celsius'};
                }
                $currentHeatingPower =
                  $decoded_data->{'activityDataPoints'}->{'heatingPower'}
                  ->{'percentage'};
                $overlay = $decoded_data->{'overlayType'};
                if ( !defined $overlay ) { $overlay = "no overlay" }

                return ( $temperature, $humidity, $desiredTemp,
                    $currentHeatingPower, $overlay );
            }
        }
    }
    return;
}

sub TadoAPI_GetTadoDevices {
    # returns array with zonenames and zone devices
    my $hash             = shift;

    my $name             = $hash->{NAME};
    my $homeID           = $attr{$name}{homeID};
    my $URL              = $QueryURL . qq{/$homeID/zones};
    my $CurrentTokenData = TadoAPI_LoadToken($hash);

    if ( defined($CurrentTokenData) ) {
        my $param = {
            url    => $URL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" =>
"$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method  => 'GET',
            timeout => 5,
            hash    => $hash
        };

        #Log3 $name, 5, 'Blocking GET: ' . Dumper($param);
        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $URL";
        my ( $err, $data ) = HttpUtils_BlockingGet($param);

        if ( $err ne "" ) {
            Log3 $name, 3,
                "TadoAPI $name" . ": "
              . "RequestTadoDevices: Error while requesting "
              . $param->{url}
              . " - $err";
        }
        elsif ( $data ne "" ) {
            Log3 $name, 5, "url " . $param->{url} . " returned: $data";
            my $decoded_data = eval { decode_json($data) };

            if ($@) {
                Log3 $name, 3, "TadoAPI $name" . ": "
                  . "RequestTadoDevices: decode_json failed, invalid json. error:$@\n";
            }
            else {
                if ( ref($decoded_data) eq 'ARRAY' ) {
                    my @devices = ();
                    for my $dev (@$decoded_data) {
                        push @devices, $dev;
                    }
                    return @devices;
                }
            }
        }
    }
    return;
}

# https://my.tado.com/api/v2/homes/<homeid>/state
sub TadoAPI_GetHomePresence {
    my $hash             = shift;

    my $name             = $hash->{NAME};
    my $homeID           = $attr{$name}{homeID};
    my $URL              = $QueryURL . qq{/$homeID/state};
    my $CurrentTokenData = TadoAPI_LoadToken($hash);

    if ( defined($CurrentTokenData) ) {
        my $param = {
            url    => $URL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method  => 'GET',
            timeout => 2,
            hash    => $hash
        };

        #Log3 $name, 5, 'Blocking GET: ' . Dumper($param);
        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $URL";
        my ( $err, $data ) = HttpUtils_BlockingGet($param);

        if ( $err ne "" ) {
            Log3 $name, 3,
                "TadoAPI $name" . ": "
              . "GetHomePresence: Error while requesting "
              . $param->{url}
              . " - $err";
        }
        elsif ( $data ne "" ) {
            Log3 $name, $reqDebug, "URL " . $param->{url} . " returned: $data";
            my $decoded_data = eval { decode_json($data) };
            if ($@) {
                Log3 $name, 3,
                  "TadoAPI $name" . ": "
                  . "GetHomePresence: Decode_json failed, invalid json. error:$@"
                  if $@;
                $hash->{LastRequest} = "error";
            }
            else {
                    my $presence = $decoded_data->{'presence'};
                    $hash->{LastRequest} = "OK";
                    return ( $presence ) ;
            }
        }
    }
    return;
}

# https://my.tado.com/api/v2/homes/<homeid>/presenceLock
sub TadoAPI_SetHomePresence {
    my $hash             = shift;
    my $presence         = shift;
    my $name             = $hash->{NAME};
    my $homeID           = $attr{$name}{homeID};
    my $URL              = $QueryURL . qq{/$homeID/presenceLock};
    my $CurrentTokenData = TadoAPI_LoadToken($hash);
    my $data             = {};

    if ( defined($CurrentTokenData) ) {
        if ($presence eq "HOME") {
            $data = { homePresence => "HOME" };
        }
        else  {
            $data = { homePresence => "AWAY" };
        }
        $data = encode_json($data);


        my $request = {
            url    => $URL,
            header => {
                "Content-Type" => "application/json;charset=UTF-8",
                "Authorization" => "$CurrentTokenData->{'token_type'} $CurrentTokenData->{'access_token'}"
            },
            method   => 'PUT',
            timeout  => 3,
            data     => $data,
            hash     => $hash,
            callback => \&TadoAPI_SetHomePresenceCallback
        };
        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "Request $URL";
        Log3 $name, $reqDebug, "TadoAPI $name" . ": " . "PUT setting $data";
        HttpUtils_NonblockingGet($request);

    }
    return;
}

######################################
############ Helpers #################
######################################
sub TadoAPI_ReplaceUmlaute {
    my $string = shift;

    my %umlaute = (
        "ä" => "ae",
        "Ä" => "Ae",
        "ü" => "ue",
        "Ü" => "Ue",
        "ö" => "oe",
        "Ö" => "Oe",
        "ß" => "ss"
    );
    my $umlautkeys = join( "|", keys(%umlaute) );

    $string =~ s/($umlautkeys)/$umlaute{$1}/g;
    return $string;
}


1;

=pod
=item device
=item summary integration of the Tado API
=item summary_DE Anbindung der Tado Heizungssteuerung &uuml;ber API
=begin html

<a name="TadoAPI" id="tadoapi"></a>
<h3>TadoAPI</h3>
<ul>
  The TadoAPI module connects your tado devices to FHEM. Most zone readings are shown and desired temperature for a zone can be set.<br>
  TadoAPI makes use of the (unofficial) tado api and does NOT rely on any addition local client installed.<br>
  Notes:
    <ul>
      <li>JSON has to be installed on the FHEM host.<br>
      Please install the module (e.g. with <code>sudo apt-get install libjson-perl</code>) or the correct method for the underlying platform/system.</li>
    </ul>

  <a name="TadoAPIdefine" id="TadoAPIdefine"></a>
  <b>Define</b>
  <ul>
  <li>Define a new tado device <b><code>define &lt;name&gt; TadoAPI</code></b></li>
  <li>Get a new <b>device_code</b> from tado with: <code>get getDeviceCode</code> (Tipp: copy &lt;device_code&gt; for next step)</li>
  <li>After successful registration with the link - add &lt;device_code&gt; to your tado-device definition (DEF) or with command <code>defmod &lt;name&gt; TadoAPI &lt;device_code&gt;</code></li>
  </ul><br>
  
  Note: All requests to the API are handeld via oauth2 token.
  <br>

  <a name="TadoAPIset" id="TadoAPIset"></a>
  <b>Set</b>
  <ul>

    <li>
      <code>set &lt;name&gt; update</code><br>
      Reloads all information from the tado installation (devices, battery state, geolocation,...).
    </li>

    <li>
      <code>set &lt;name&gt; setZoneOverlay &lt;zoneID&gt; &lt;setting&gt; [&lt;duration&gt;]</code><br>    
      Setting: remove = delete overlay; 0 = heating power off; &gt; 1 sets desired temperature to given value (overlay)
    </li>

    <li>
      <code>set &lt;name&gt; setAllOverlays  &lt;setting&gt;</code><br>
      Same as above, but for all zones<br>
      Setting: remove = delete overlay; 0 = heating power off; &gt; 1 sets desired temperature to given value (overlay)</li>
    <br>
  </ul>
  <br>

  <a name="TadoAPIattr" id="TadoAPIattr"></a>
  <b>Attributes</b>
  <ul>
    <li>homeID<br>
      Home ID that will be used for <b>API</b> querys. 
    </li>
    <li>updateIntervall<br>
      Intervall (in seconds) that is used for polling the tado API to update readings. 
    </li>
    <li>showPosData<br>
      If set to <b>1</b> readings with relative distance to tado home are shown. 
    </li>
  </ul>
  <br>
</ul>

=end html

=for :application/json;q=META.json 98_TadoAPI.pm
{
  "author": [
    "Philipp Wolfmajer <philipp@wolfmajer.at>"
  ],
  "x_fhem_maintainer": [
    "psycho160"
  ],
  "keywords": [
    "Heating",
    "Tado",
    "Heatingcontrol"
  ]
}
=end :application/json;q=META.json

# Ende der Commandref
=cut
