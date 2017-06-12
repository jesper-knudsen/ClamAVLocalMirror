#!/usr/bin/env perl
#############################################################################
#
# Script to be used if you create a local private ClamAV mirror.
#
# Author Jesper Knudsen, ScanMailX
#
# Strongly based on the previous work of Frederic Vanden Poel.
#
# $Header: /usr/local/cvs/scanmailx/GetClamAVDB.pl,v 1.1 2017/06/11 19:06:37 jkn Exp $
#
#############################################################################

use strict;
use warnings;

use Net::DNS;
use Getopt::Long;
use LWP::Simple;
use File::Basename;
use File::Path 'rmtree';
use Cwd;

# Your WebRoot
my $clamdb="/home/e-smith/files/ibays/clamdb/html";

# The temporary directory where files are download to and verified
my $tmpdir="/tmp/clam";

# Location of the log
my $logfile = "/var/log/GetClamAVDB.log";

# The mirrors, in prioritized order, where files are downloaded from.
my @mirrors = (
               "http://db.se.clamav.net",
               "http://db.local.clamav.net",
               "http://database.clamav.net"
               );


##### No need to alter anything below this line ####

my %optctl = ();
GetOptions (\%optctl, "crontab","debug","deamon");

my $crontab = $optctl{"crontab"} ? 1 : 0;
my $debug = $optctl{"debug"} ? 1 : 0;
my $deamon = $optctl{"deamon"} ? 1 : 0;


# Already active, then bail out.
if (-e $tmpdir and -d $tmpdir) {
  print_log("Instance already running - exiting...");
  exit;
}

GETDNS_AGAIN:

# get the TXT record for current.cvd.clamav.net
my ($txt,$ttl) = getTXT("current.cvd.clamav.net");

if (not $txt) {
  print_log("Cannot get DNS TXT from current.cvd.clamav.net");
  exit;
}

# decompile the TXT record.
my ( $clamv, $mainv , $dailyv, $x, $y, $z, $safebrowsingv, $bytecodev ) = split /:/, $txt ;

print_log("ClamAV DNS version=$clamv main=$mainv daily=$dailyv bytecode=$bytecodev safebrowsing=$safebrowsingv - updated again in $ttl secs.");


if ($ttl < 30 and not $deamon) {
  print_log("DNS TXT is almost changing - waiting the $ttl secs...");
  sleep(int($ttl + 2));
  goto GETDNS_AGAIN;
}

# Store current directory
my $cwd = getcwd();

# Create temp dir for DB updates
mkdir("$tmpdir");

updateDB("main",$mainv);
updateDB("daily",$dailyv);
updateDB("bytecode",$bytecodev);
updateDB("safebrowsing",$safebrowsingv);

# Move back 
chdir($cwd);

# Now clean up tmp dir
rmtree("$tmpdir");

if ($deamon) {
  print_log("Sleeping until next DNS TXT change in $ttl secs...");
  sleep(int($ttl + 2));
  goto GETDNS_AGAIN;
}

exit;

sub getTXT {
  my $domain = shift;

  my $res = Net::DNS::Resolver->new;
  my $txt_query = $res->query($domain,"TXT");
  if ($txt_query) {
    my $ttl = ($txt_query->answer)[0]->ttl;
    return (($txt_query->answer)[0]->txtdata,$ttl);
  } else {
    print_log("Unable to get TXT Record : $res->errorstring");
    return 0;
  }
}

sub getVerification {
  my $file = shift;

  if ($file =~ m/cdiff/) {
    my $basename = basename($file);
    my $dirname = dirname($file);

    my ($major) = $basename =~ /([^\-]+)/;
    print_log(" Verifying $file with $clamdb/$major.cvd");

    if (not chdir($tmpdir)) {
      print_log("Can't chdir to $tmpdir");
      return 0;
    } 

    print_log(" Unpacking $clamdb/$major.cvd to $tmpdir");
    my $cmd = `sigtool --unpack=$clamdb/$major.cvd 2>&1`;

    $cmd="sigtool --verify-cdiff=$file $clamdb/$major.cvd 2>&1";
    open P, "$cmd |" || die("Can't run $cmd : $!");
    while (my $line = <P>) {
      print_log(" $line");
      next unless ($line =~ /correctly applies/);
      return 1;
    }

    print_log(" Verifying failed $file with $major.cvd");
    return 0;

  } else {

    my $cmd="sigtool -i $file 2>%1";
    open P, "$cmd |" || die("Can't run $cmd : $!");
    while (<P>) {
      next unless /Verification OK/;
      return 1;
    }
    return 0;
  }
}


sub getLocalVersion {
  my $file = shift;

  my $cmd="sigtool -i $file";
  open P, "$cmd |" || die("Can't run $cmd : $!");
  while (<P>) {
    next unless /Version: (\d+)/;
    return $1;
  }
  return -1;
}

sub getFile {
  my $file = shift;
  my $currentversion = shift;

  my $browser = LWP::UserAgent->new(
                                    agent => 'GetClamAVDB/1.00'
                                    );
  
  $browser->timeout(10);

  for my $mirror (@mirrors) {

    print_log("Attempting to get $file from $mirror");
    
    my $response = $browser->get("$mirror/$file",
				 ':content_file' => "$tmpdir/$file"
				 );

    if ($response->is_success) {
      print_log(" Sucess getting $file from $mirror");
      if (-e "$tmpdir/$file") {
	if (getVerification("$tmpdir/$file")) {
	  if ($currentversion != 0 and getLocalVersion("$tmpdir/$file") == $currentversion) {
	    print_log(" Verified OK $tmpdir/$file from $mirror as version $currentversion");
	    return 1;
	  } elsif ($currentversion == 0) {
            print_log(" Verified OK $tmpdir/$file from $mirror");
	    return 1;
	  }
	} else {
	  print_log(" Verified failed $tmpdir/$file from $mirror");
	  next;
	}
      }
    } else {
      my $err = $response->status_line;
      print_log(" Error getting $file from $mirror ($err)");
    }
  }
  return 0;
}

sub updateDB {
  my $file = shift;
  my $currentversion = shift;

  my $old = 0;

  # First get the cdiff for the majors
  if  ( -e "$clamdb/$file.cvd" && ! -z "$clamdb/$file.cvd" ) {
    $old = getLocalVersion("$clamdb/$file.cvd");

    if ($old > 0) {
      print_log("$file.cvd: local=$old, mirror=$currentversion");    

      if ($currentversion != $old) {
	# mirror all the diffs
	for (my $count = $old + 1 ; $count <= $currentversion; $count++) {
	  if (getFile("$file-$count.cdiff",0)) {
	    my $cmd = `mv -v $tmpdir/$file-$count.cdiff $clamdb/$file-$count.cdiff 2>&1`;
	    print_log($cmd);
	  }
	}
      }
    } else {
      print_log("file $clamdb/$file.cvd version unknown, skipping cdiffs");
    }

  } else {
    print_log("file $clamdb/$file.cvd is zero, skipping cdiffs");
  }

  return if ( $currentversion == $old );
  print_log("Updating $file.cvd from $old to $currentversion");


  if (getFile("$file.cvd",$currentversion)) {
    my $cmd = `mv -v $tmpdir/$file.cvd $clamdb/$file.cvd 2>&1`;
    print_log("Moving to production $cmd (version $currentversion)");
  } else {
    print_log("file $tmpdir/$file.cvd not valid or renewed");
    unlink "$tmpdir/$file.cvd";
  }

}


sub print_log {
  my $msg = shift;

  # remove newlines
  $msg =~ s/[\n\r]//;

  my $LOG = OpenLog();
  if ($LOG) {
    printf $LOG ("%s - %s\n",_date(),$msg);
  }
}

sub OpenLog {

  my $LOG;
  if (not (open ($LOG, ">> $logfile"))) {
    printf("Cannot open logfile %s (%s)\n",$logfile,$!);
    return;
  } else {
    autoflush $LOG 1;
  }
  return $LOG;
}

sub _date {
  my $time = shift;

  $time = time() if (not defined($time));

  my @weekday = ("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat");
  my @month = ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec");

  my @date_info = localtime($time);
  my $date = sprintf("%s %d %s %4d, %02d:%02d:%02d",
                     $weekday[$date_info[6]],
                     $date_info[3], $month[$date_info[4]], $date_info[5] + 1900,
                     $date_info[2], $date_info[1], $date_info[0]);

  return $date;
}
