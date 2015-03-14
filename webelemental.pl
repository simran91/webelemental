#!/usr/bin/perl

##################################################################################################################
# 
# File         : webelemental.pl
# Description  : simple configurable ad/content blocking proxy
# Original Date: ~1998
# Author       : simran@dn.gs
#
##################################################################################################################


require 5.002;
use Socket;
use Carp;
use FileHandle;
use POSIX;

$|=1;
$version = "1.0 24/Feb/1998";

# $debug_printfull = 1;


################ read in args etc... ###################################################################################
#
#
#

($cmd = $0) =~ s:(.*/)::g;
($startdir = $0) =~ s/$cmd$//g;
$configfile = "${startdir}webelemental.conf";
$printstats = 0;

while (@ARGV) { 
  $arg = "$ARGV[0]";
  $nextarg = "$ARGV[1]";
  if ($arg =~ /^-sampleconf$/i) {
    &sampleconf();
    exit(0);
  }
  elsif ($arg =~ /^-c$/i) {
    $configfile = "$nextarg";
    die "Valid configfile not defined after -c switch : $!" if (! -f "$configfile");
    shift(@ARGV);
    shift(@ARGV);
    next;
  }
  elsif ($arg =~ /^-ps$/i) {
    $printstats = 1;
    shift(@ARGV);
    next;
  }
  elsif ($arg =~ /^-p$/i) {
    $arg_port = $nextarg;
    die "A valid numeric port number must be given with the -p argument : $!" if ($arg_port !~ /^\d+$/);
    shift(@ARGV);
    shift(@ARGV);
  }
  elsif ($arg =~ /^-nologs$/i) {
    $arg_logsdir = "";
    shift(@ARGV);
  }
  elsif ($arg =~ /^-about$/i) {
    shift(@ARGV);
    &about();
  }
  else { 
    print "\n\nArgument $arg not understood.\n";
    &usage();
  }
}

#
#
#
########################################################################################################################


############### forward declarations for subroutines ... ###############################################################
#
#
#

# forward declarations for subroutines
sub readconf; # reads in the configuration file $configfile ... 
sub debug;    # used for debugging purposes... 
sub strip;    # strips leading and traling whitespaces and tabs.. 
sub spawn;    # subroutine that spawns code... 
sub logmsg;   # subroutine that logs stuff on STDOUT 
sub REAPER;   # reaps zombie process... 
sub alarmcall; # Gets called when it takes more than "$timeout" seconds to answer a request... 

#
#
#
########################################################################################################################

################# main program #########################################################################################
#
#
#

$SIG{CHLD} = \&REAPER;

&readconf();

&initialise_quotes();

# change some values (eg the port number the server has to run on) if they were specified on the command line... 

$port = $arg_port if ($arg_port);
$logsdir = $arg_logsdir if (defined($arg_logsdir));

if ($printstats) {
  $pid = $$;
  $pf_sf = "/tmp/${cmd}_sendfilter.$pid";
  $pf_rf = "/tmp/${cmd}_recvfilter.$pid";
  open(PS_SF, "> $pf_sf") || warn "Could not open $pf_sf for writing : $!";
  open(PS_RF, "> $pf_rf") || warn "Could not open $pf_rf for writing : $!";
  PS_SF->autoflush();
  PS_RF->autoflush();
}


&setupServer();

&startServer();

#
#
#
########################################################################################################################


########################################################################################################################
# readconf: Reads config file
#
#  global vars read: 
# 
#  global vars possibly created/modified: 
#        # $real_proxy_host
#        # $real_proxy_port
#        # $port                 - port on which server should run...
#        # $returnfiledir        - the directory where the 'returnfile's are stored..
#        # %sendfilter_exclude   - $sendfilter_exclude{"$pattern"}
#        # %recvfilter_exclude   - $recvfilter_exclude{"$pattern"}
#        # %recvfilter           - $recvfilter{"pattern"}{"$pattern"}{"$conffile_linenum"} = 1;
#        #                       - $recvfilter{"returnfile"}{"$pattern"}{"$conffile_linenum"} = filename
#        #                       - $recvfilter{"inclheader"}{"$pattern"}{"$conffile_linenum"} = headervalue
#        # %sendfilter           - $sendfilter{"pattern"}{"$pattern"}{"$conffile_linenum"} = 1;
#        #                       - $sendfilter{"modheader"}{"$pattern"}{"$conffile_linenum"} = headervalue
#
sub readconf {

  my (@conffile, $tag, $returnfile, $confline, $conffile_linenum, $rest, $pattern);

  open(CONFFILE, "$configfile") || &usage("Could not open $configfile : $!");
  @conffile = <CONFFILE>;
  close(CONFFILE);
 
  $confile_linenum = 1; 
  while(@conffile) {
    $confline = shift(@conffile);
    chomp($confline);
    if ($confline =~ /^[\s\t]*#/i) { $conffile_linenum++; next; }    # ignore comment lines 
    if ($confline =~ /^[\s\t]*$/i) { $conffile_linenum++; next; }    # ignore blank lines 

    $confline =~ s/#.*$//g; # remote comments bits after the '#' symbol in conffile 

    $conffile_linenum++;

    # handle 'real_proxy' line 
    if ($confline =~ /^real_proxy:/i) {
      ($tag, $rest) = split(/:/,"$confline", 2);
      ($real_proxy_host, $real_proxy_port) = split(/:/, "$rest", 2);
      $real_proxy_host = strip("$real_proxy_host");
      $real_proxy_port = strip("$real_proxy_port");
      if (! $real_proxy_host) {
        die "real_proxy host not defined, please comment line if not needed - config file line $conffile_linenum:";
      }
      elsif ($real_proxy_port !~ /^\d+$/) {
	die "real_proxy port is either not defined or not numeric - config file line $conffile_linenum:";
      }
    }
    # handle 'port' line
    elsif ($confline =~ /^port:/i) {
      ($tag,$port) = split(/:/, "$confline", 2);
      $port = strip("$port");
      if ($port !~ /^\d+$/) {
	die "port must be a numeric number - config file line $conffile_linenum:";
      }
    }
    # handle 'host_timeout' line
    elsif ($confline =~ /^host_timeout:/i) {
      ($tag,$host_timeout) = split(/:/, "$confline", 2);
      $host_timeout = strip("$host_timeout");
      if ($host_timeout !~ /^\d+$/) {
	die "HOSTTIMEOUT = $hosttimeout | host_timeout must be a numeric number - config file line $conffile_linenum:";
      }
    }
    # handle 'content_start_timeout' line
    elsif ($confline =~ /^content_start_timeout:/i) {
      ($tag,$content_start_timeout) = split(/:/, "$confline", 2);
      $content_start_timeout = strip("$content_start_timeout");
      if ($content_start_timeout !~ /^\d+$/) {
	die "content_start_timeout must be a numeric number - config file line $conffile_linenum:";
      }
    }
    # handle 'content_end_timeout' line
    elsif ($confline =~ /^content_end_timeout:/i) {
      ($tag,$content_end_timeout) = split(/:/, "$confline", 2);
      $content_end_timeout = strip("$content_end_timeout");
      if ($content_end_timeout !~ /^\d+$/) {
	die "content_end_timeout must be a numeric number - config file line $conffile_linenum:";
      }
    }
    # handle 'returnfiledir' line
    elsif ($confline =~ /^returnfiledir:/i) {
      ($tag,$returnfiledir) = split(/:/, "$confline", 2);
      $returnfiledir = strip("$returnfiledir");
      if (! -d "$returnfiledir") {
        die "returnfiledir directory not defined or does not exist - config file line $conffile_linenum:";
      }
    }
    # handle 'logsdir' line
    elsif ($confline =~ /^logsdir:/i) {
      ($tag,$logsdir) = split(/:/, "$confline", 2);
      $logsdir = strip("$logsdir");
      # print STDERR "logsdir=$logsdir\n";
      if ("$logsdir" && (! -d "$logsdir")) {
        die "logs directory does not exist - config file line $conffile_linenum:";
      }
    } 
    # handle 'sendfilter_exclude' line
    elsif ($confline =~ /^sendfilter_exclude:/i) {
      ($tag,$pattern) = split(/:/, "$confline", 2);
      $pattern =~ s!/!\\/!g; # put in escapes for all the '/'s
      $pattern = strip("$pattern");
      $sendfilter_exclude{"$pattern"} = "1";
    }
    # handle 'recvfilter_exclude' line
    elsif ($confline =~ /^recvfilter_exclude:/i) {
      ($tag,$pattern) = split(/:/, "$confline", 2);
      $pattern =~ s!/!\\/!g; # put in escapes for all the '/'s
      $pattern = strip("$pattern");
      $recvfilter_exclude{"$pattern"} = "1";
    }
    # handle 'recvfilter' line
    elsif ($confline =~ /^recvfilter:/i) {
      ($tag,$pattern) = split(/:/, "$confline", 2);
      $pattern =~ s!/!\\/!g; # put in escapes for all the '/'s
      $pattern = strip("$pattern");
      $recvfilter{"pattern"}{"$pattern"}{"$conffile_linenum"} = "1";

      $returnfile = ""; # initialise variable so that next time we get recvfilter its not already defined...
      while($confline !~ /^[\s\t]*$/) {
	$conffile_linenum++;
	$confline = shift(@conffile);
	next if ($confline =~ /^[\s\t]*$/);
	next if ($confline =~ /^[\s\t]#/);
	($tag, $rest) = split(/:/, "$confline", 2);
	$tag = strip("$tag");
	$rest = strip("$rest");
	# handle 'returnfile' line 
	if ($tag =~ /^returnfile$/i) {
	  $returnfile = "$rest";
	  print STDERR "Cannot find tag 'returnfiledir' in config file....\n" if (! -d "$returnfiledir");
	  die "File $returnfile does not exist - config file line $conffile_linenum:" if (! -f "$returnfiledir/$returnfile"); 
	  $recvfilter{"returnfile"}{"$pattern"}{"$conffile_linenum"} = "$returnfile";
	  $filesize{"$returnfile"} = &getFileSize("$returnfile");
	  @filecontents["$returnfile"] = &getFileContents("$returnfile");
	}
	elsif ($tag =~ /^inclheader$/i) {
	  $recvfilter{"inclheader"}{"$pattern"}{"$conffile_linenum"} = "$rest";
	}
	else {
	  next if ($confline =~ /^[\s\t]*#/);
	  die "Tag $tag not defined under recvfilter - config file line $conffile_linenum:"; 
	}
      }
      die "returnfile does not seem to be defined - config file line $conffile_linenum:" if (! "$returnfile"); 
    }
    # handle 'sendfilter' line
    elsif ($confline =~ /^sendfilter:/i) {
      ($tag,$pattern) = split(/:/, "$confline", 2);
      $pattern =~ s!/!\\/!g; # put in escapes for all the '/'s
      $pattern = strip("$pattern");
      $sendfilter{"pattern"}{"$pattern"}{"$conffile_linenum"} = "1";

      $returnfile = ""; # initialise variable so that next time we get sendfilter its not already defined...
      while($confline !~ /^[\s\t]*$/) {
	$conffile_linenum++;
	$confline = shift(@conffile);
	next if ($confline =~ /^[\s\t]*$/);
	next if ($confline =~ /^[\s\t]#/);
	($tag, $rest) = split(/:/, "$confline", 2);
	$tag = strip("$tag");
	$rest = strip("$rest");
	# handle 'modheader' line 
	if ($tag =~ /^modheader$/i) {
	  $sendfilter{"modheader"}{"$pattern"}{"$conffile_linenum"} = "$rest";
	}
	else {
	  next if ($confline =~ /^[\s\t]*#/);
	  die "Tag $tag not defined under sendfilter - config file line $conffile_linenum:"; 
	}
      }
    }
    else {
      die "Did not understand \"$confline\" - config file line $conffile_linenum:"; 
    } # end if/elsif/else
  } # end while

  # check for essential variables... and if not defined... exit... 

  die "host_timeout not defined in config file or not greater than zero" if (! $host_timeout);
  die "content_start_timeout not defined in config file or not greater than zero" if (! $content_start_timeout);
  die "content_end_timeout not defined in config file or not greater than zero" if (! $content_end_timeout);
  die "returnfiledir not defined in config file" if (! $returnfiledir);
  die "port not defined in config file or not greater than zero" if (! $port);

} # end sub
#
#
#
########################################################################################################################


########################################################################################################################
# $str strip($string): return $string stripped of leading and trailing white spaces... 
#
#
sub strip {
  $_ = "@_";
  $_ =~ s/(^[\s\t]*)|([\s\t]*$)//g;
  return "$_";
}
#
#
#
########################################################################################################################


########################################################################################################################
# logmsg($string): prints messages to stdout
#
#
sub logmsg { 
  print "$) $$: @_ at ", scalar localtime, "\n"; 
}
#
#
#
########################################################################################################################


########################################################################################################################
# REAPER: reaps zombie processes
#
#
sub REAPER {
  my $child;
  $SIG{CHLD} = \&REAPER;
  while ($child = waitpid(-1,WNOHANG) > 0) {
    $Kid_Status{$child} = $?;
  }
  # logmsg "reaped $waitpid" . ($? ? " with exit $?" : "");
}
#
#
#
########################################################################################################################


########################################################################################################################
# setupServer: sets up server on local machine to which browsers connect 
#
#  global vars read:
#        # $port : port on which to run server 
#
#  global vars possibly created/modified:
#        # Handle: Server
#
sub setupServer { 
  my $rest;
  my $session_num = 0;
  die "port to run server not defined in config file..." if (! $port);
  $proto = getprotobyname('tcp');
  $waitpid = 0;
  socket(Server,PF_INET,SOCK_STREAM,$proto) or die "socket: $!";
  setsockopt(Server,SOL_SOCKET,SO_REUSEADDR,pack("l",1)) or die "setsockopt: $!";
  bind(Server,sockaddr_in($port,INADDR_ANY)) or die "bind: could not bind to $port: $!";
  listen(Server,SOMAXCONN) or die "listen: $!";
  logmsg "server started on port $port";

  if ($logsdir) {
    foreach $file (<$logsdir/*>) {
      ($session, $rest) = split(/_/,"$file", 2);
      $session =~ s!.*/!!g;
      $session =~ s/(\w+)(\d+)/$2/g;
      $logged{"$session"} = 1;
    }
    $session_num++;
    while ($logged{"$session_num"}) {
      $session_num++;
    }
    $session = "session$session_num";
  }
}
#
#
#
########################################################################################################################


########################################################################################################################
# startServer: listens for connections on Server
#
#  global vars read:
#
#  global vars possibly created/modified:
#        # $client_name : hostname from which client connects
#	 # $client_port : port from which client connects
#
sub startServer { 
  for ( $waitedpid = 0; ($paddr = accept(Client,Server)) || $waitedpid; $waitedpid = 0, close Client) {
    next if $waitedpid;
    my $iaddr;
    ($client_port,$iaddr) = sockaddr_in($paddr);
    $client_name = gethostbyaddr($iaddr,AF_INET);
    # logmsg "connection from $client_name [", inet_ntoa($iaddr), "] at port $client_port";
    $client_connectime = scalar localtime;
    $fileno++;
    $handlenum++;
    if ($printstats) {
      $pf_sf_num = -s "$pf_sf";
      $pf_rf_num = -s "$pf_rf";
      $untouched = $handlenum - $pf_sf_num - $pf_rf_num;
      print STDERR "\rRequests Handled : $handlenum Sendfilter_Modified: $pf_sf_num Recvfilter_Blocked: $pf_rf_num Untouched: $untouched      ";
    }
    spawn sub { 
      &handleRequest(); 
      return 1;  
    };
  }
}
#
#
#
########################################################################################################################


########################################################################################################################
# spawn: forks code
#        usage: spawn sub { code_you_want_to_spawn };
#
#
sub spawn {
  my $coderef = shift;
  unless (@_ == 0 && $coderef && ref($coderef) eq 'CODE') {
    confess "usage: spawn CODEREF";
  }
  my $pid;
  if (!defined($pid = fork)) {
    logmsg "cannot fork: $!"; return;
  }
  elsif ($pid) {
    # logmsg "begat $pid"; 
    return; # i'm the parent
  }
  # else i'm the child -- go spawn

  open(STDIN,  "<&Client")   || die "can't dup client to stdin";
  open(STDOUT, ">&Client")   || die "can't dup client to stdout";
  ## open(STDERR, ">&STDOUT") || die "can't dup stdout to stderr";
  exit &$coderef();
}
#
#
#
########################################################################################################################


########################################################################################################################
# handleRequest: handles requests sent by browsers... 
#
#
sub handleRequest {
  my $firstRequestLine = <Client>;
  my ($method,$url,$protocol) = split(/\s+/, "$firstRequestLine", 3);
  my $getTime;
  $SIG{ALRM} = \&alarmcall;

  $alarmcode = 1;
  alarm $host_timeout;

  # get the info that the browser sends... 
  if ("$method" eq "GET") {
    @header = &getGETrequest("$firstRequestLine");
  }
  elsif ("$method" eq "POST") {
    @header = &getPOSTrequest("$firstRequestLine");
  }
  else {
    @header = &getOTHERrequest("$firstRequestLine");
  }
  ###

  $getTime = scalar localtime;

  $logfile = &getLogfilename("@header[0]"); # returns the filename that we will used to log to... 
  if ($logsdir) { open(LOG, "> ${logfile}") || warn "Could not open $logfile for writing : $!"; }

  LOG->autoflush();

  &log("WebElemental: received connection from $client_name port $client_port at $client_connectime\n");
  &log("-" x 80, "\n");
  &log("WebElemental: received header below from $client_name port $client_port at $getTime\n");
  &log("-" x 80, "\n");
  &log(join('',@header));
  &log("-" x 80, "\n");
  
  $rulevar = &getRuleVar("@header[0]");

  if (&recvfilter_exclude_RuleMatch("$rulevar")) {
    if (&sendfilter_exclude_RuleMatch("$rulevar")) {
      &passon(@header);
      &passback();
    }
    elsif (&sendfilter_RuleMatch("$rulevar")) {
      @header = &hackheader_sendfilter(@header);
      &passon(@header);
      &passback();
    }
    else {
      &passon(@header);
      &passback();
    }
  }
  elsif (&recvfilter_RuleMatch("$rulevar")) {
    &recvfilter_RuleMatch_Reply("$rulevar");
  }
  else {
    if (&sendfilter_exclude_RuleMatch("$rulevar")) {
      &passon(@header);
      &passback();
    }
    elsif (&sendfilter_RuleMatch("$rulevar")) {
      @header = &hackheader_sendfilter(@header);
      &passon(@header);
      &passback();
    }
    else {
      &passon(@header); 
      &passback();
    }
  }

  if ($logsdir) { close(LOG); }

  alarm 0; # cancel alarm 

}
#
#
#
########################################################################################################################

########################################################################################################################
# passback: get reply from webserver and pass back to browser
#
#
sub passback {
  my $inheader = 1;
  my @fullreply;
  my @gotbackheader, @gotbackcontent;

  my $time = scalar localtime;
  
  while ($gotback = <WebServer>) { 
    $alarmcode = 3;
    alarm $content_end_timeout;
    if ($inheader) {
      $inheader = 0 if ($gotback =~ /^[\s\t]*$/);
      push(@gotbackheader, "$gotback");
      print Client "$gotback";
    }
    else {
      push(@gotbackcontent,"$gotback");
      print Client "$gotback";
    }
  }
  # print Client @fullreply;
  $time = scalar localtime;

  &log("WebElemental: got reply from $remotehost port $remoteport at $client_connectime at $time\n");
  &log("WebElemental: passed on header below to $client_name port $client_port at $time\n");
  &log("-" x 80, "\n");
  &log(join('',@gotbackheader));
  &log("-" x 80, "\n");

  close(Client);
  close(WebServer);
}
#
#
#
########################################################################################################################

########################################################################################################################
# passon: Pass information on to webserver... 
#
#
sub passon {
  my @header = @_;
  my ($method, $url, $protocol, $remotehost, $remoteport);
  my $firstline = @header[0];
  my $time;

  ($method, $url, $protocol) = split(/\s+/, "$firstline", 3);

  ($remotehost = $url) =~ s!^http://(.*)/(.*)?!$1!i;
  ($remotehost, $remoteport) = split(/:/, "$remotehost");
  $remoteport =~ s!/.*!!g;
  $remotehost =~ s!/.*!!g;
  $remoteport = 80 if (! $remoteport);
  # ($remotefile = $url) =~ s!^"http://$remotehost"!!;
  $remotefile = "$url";
  $remotefile =~ s!^http://!!;
  $remotefile =~ s/^$remotehost//;
  $remotefile =~ s/^:$remoteport//;
  
  # print STDERR "REMOTEHOST=$remotehost REMOTEPORT=$remoteport REMOTEFILE=$remotefile\n";

  if ($real_proxy_host) {
    $remotehost = "$real_proxy_host";
    $remoteport = "$real_proxy_port";
    setupWebServer("$remotehost", "$remoteport");
    send(WebServer,join('',@header), 0) || warn "send: $!";
    $time = scalar localtime;
  }
  else {
    setupWebServer("$remotehost", "$remoteport");
    shift(@header);
    unshift(@header, "$method $remotefile $protocol");
    $time = scalar localtime;
    send(WebServer, join('',@header), 0) || warn "send: $!";
  }
  
  # print STDERR "HOST=$remotehost PORT=$port FIRSTLINE=@header[0]";
  &log("WebElemental: passed on message below to $remotehost port $remoteport at $time\n"); 
  &log("-" x 80, "\n");
  &log(join('',@header));
  &log("-" x 80, "\n");
}
#
#
#
########################################################################################################################

########################################################################################################################
# getGETrequest: returns full header browser passes... looks till first newline on a line by itself... 
#
#
sub getGETrequest {
  my ($firstline) = @_;
  my $line;
  my @header;
  
  # print STDERR "GOT GET LINE: $firstline";

  push(@header,"$firstline");
  while (($line = <Client>) !~ /^[\s\t]*$/) {
    push(@header,"$line");
  }
  push(@header,"$line");
  return @header;
}
#
#
#
########################################################################################################################


########################################################################################################################
# getPOSTrequest: returns full header browser passes... 
# 
# # different from getGETrequest as it looks for the Content-length: header and
# # then reads in the number of bytes specified by Content-length
# 
sub getPOSTrequest {
  my ($firstline) = @_;
  my $content_length;
  my $line;
  my @header;
  
  # print STDERR "GOT POST LINE: $firstline";

  push(@header, "$firstline");
  while (($line = <Client>) !~ /^[\s\t]*$/) {
    if ($line =~ /Content-length:/i) {
      ($content_length = $line) =~ s/Content-length: (.*)/$1/i;
      chomp($content_length);
      $content_length += 2; # take account for newline char etc... 
    }
    push(@header, "$line");
    if (defined($content_length)) {
      read(Client, $line, $content_length, 0);
      # push(@header, "$line");
      last;
    }
  }
  # while (($line = <Client>) !~ /^[\s\t]*$/) {
  #   push(@header, "$line");
  # }
  push(@header, "$line");
  # print STDERR "RETURNING POST HEADER\n";
  # print STDERR join('',@header);
  return @header;
}
#
#
#
########################################################################################################################


########################################################################################################################
# getOTHERrequest: returns full header browser passes... 
#
# Same as getGETrequest at the moment... reads in data until first
# blank line... 
#
sub getOTHERrequest {
  my ($firstline) = @_;
  my $line;
  my @header;
  
  # print STDERR "GOT OTHER LINE: $firstline";

  push(@header, "$firstline");
  while (($line = <Client>) !~ /^[\s\t]*$/) {
    push(@header, "$line");
  }
  push(@header, "$line");
  return @header;
}
#
#
#
########################################################################################################################


########################################################################################################################
# recvfilter_exclude_RuleMatch: returns 1 if pattern in input matches any recvfilter_exclude rule.
#				returns 0 otherwise!
#
sub recvfilter_exclude_RuleMatch {
  my $rulevar = @_[0];
  my $pattern;
  foreach $pattern (sort keys %recvfilter_exclude) {
    if ($rulevar =~ /$pattern/i) {
      return 1;
    }
  }
  return 0;
}
#
#
#
########################################################################################################################


########################################################################################################################
# getRuleVar: returns variable with "http://" etc taken off so we can match our rules with it! 
#
# 
sub getRuleVar {
  my $headerline = @_[0];
  my $rulevar;

  my ($method, $url, $protocol) = split(/\s+/, "$headerline", 3);
  
  ($rulevar = $url) =~ s!^http://!!i;
  return $rulevar;
}
#
#
#
########################################################################################################################


########################################################################################################################
# recvfilter_RuleMatch: returns 1 if pattern in input matches any recvfilter rule.
#			returns 0 otherwise!
# 
sub recvfilter_RuleMatch {
  my $rulevar = @_[0];
  my $pattern;

  foreach $pattern (keys %{$recvfilter{"pattern"}}) {
    if ($rulevar =~ /$pattern/i) {
      return 1;
    }
  }
  return 0;
}
#
#
#
########################################################################################################################


########################################################################################################################
# setupWebServer: sets up connection to remote server 
#
#
sub setupWebServer { 
  my ($remotehost, $remoteport) = @_;
  my $proto = getprotobyname('tcp');
  my ($remote_iaddr, $remote_paddr);

  $remote_iaddr = inet_aton($remotehost);
  $remote_paddr = sockaddr_in($remoteport,$remote_iaddr);
  socket(WebServer, PF_INET, SOCK_STREAM, $proto) or die "socket: $!";
  if (! connect(WebServer, $remote_paddr)) {
    $alarmcode = 4;
    &alarmcall();
  }
  # if we get this far, we have successfully contact the remote host.. so change the timeout value... 
  $alarmcode = 2;
  alarm $content_start_timeout;
}
#
#
#
########################################################################################################################


########################################################################################################################
# log("string"): Logs "string" to filehandle LOG
#			      
#
sub log { 
  my $message = "@_";
  if ($logsdir) { 
    # my $time = scalar localtime;
    # print LOG "$time\n";
    # print LOG "-" x 24;
    # print LOG "\n";
    print LOG "$message";
    # print LOG "-" x 80;
    # print LOG "\n";
  }
}
#
#
#
########################################################################################################################


########################################################################################################################
# getLogfilename(@header[0]): returns the filename we are going to
#                             log the request to.
#			      
#
sub getLogfilename {
  my $line = "@_";
  my $logfile;

  my $host = "abc.log";

  # $logfile = "${logsdir}/${fileno}-${host}.log";
  $logfile = "${logsdir}/${session}_${fileno}.log";
}
#
#
#
########################################################################################################################

########################################################################################################################
# hackheader_sendfilter(@header): returns the header after making modifications as per sendfilter rule
#			      
#
sub hackheader_sendfilter {
  my(@header) = @_;
  my(@origheader) = @header;
  my (@newheader);
  my(%h);
  my $linenum, $pattern, $key, $value, $hdr, $i, $line;
  my $patlen, $patlonglen;

  print PS_SF "1" if ($printstats);

  foreach $pattern (keys %{$sendfilter{"modheader"}}) {
       
    $patlen = length("$pattern");

    if ($patlen <= $patlonglen) {
      next;
    }
    else {
      @header = @origheader;
      $patlonglen = $patlen;
      @newheader = ();
    }

    foreach $line (@header) {


      ($key, $value) = split(/:/, "$line", 2);


      foreach $linenum (reverse sort keys %{$sendfilter{"modheader"}{"$pattern"}}) {
        ($sfhk, $sfhv) = split(/:/, "$sendfilter{\"modheader\"}{\"$pattern\"}{\"$linenum\"}", 2);
        if ("$sfhk" eq "$key") {
          $line = "$key:$sfhv\n";
        }
      }
      push(@newheader, "$line");
    }
  }

  return @newheader;
}
#
#
#
########################################################################################################################


########################################################################################################################
# sendfilter_RuleMatch("$rulevar"): returns 1 if a sendfilter rule matches. 
#				    returns 0, otherwise.
#                                 
sub sendfilter_RuleMatch {
  my $rulevar = "@_";
  my $pattern, $linenum; 

  foreach $pattern (keys %{$sendfilter{"pattern"}}) {
    foreach $linenum (sort keys %{$sendfilter{"pattern"}{"$pattern"}}) {
      if ($rulevar =~ /$pattern/i) {
	return 1;
      }
    }
  }

  return 0;
}
#
#
#
########################################################################################################################


########################################################################################################################
# sendfilter_exclude_RuleMatch("$rulevar"): returns 1 if a sendfilter_exclude rule matches. 
#				            returns 0, otherwise.
#
sub sendfilter_exclude_RuleMatch {
  my $rulevar = @_[0];
  my $pattern;
  foreach $pattern (sort keys %sendfilter_exclude) {
    if ($rulevar =~ /$pattern/i) {
      return 1;
    }
  }
  return 0;
}
#
#
#
########################################################################################################################

########################################################################################################################
# recvfilter_RuleMatch_Reply($rulevar): A recvfilter rule matched... so reply accordingly  
#
#
sub recvfilter_RuleMatch_Reply {

  my $rulevar = "@_";
  my @header, @content, $sent_time;
  my $time = scalar localtime;
  my $linenum, $line, $filename;
  my $patlonglen, $patlen;

  print PS_RF "1" if ($printstats);

  foreach $pattern (keys %{$recvfilter{"pattern"}}) {
    if ($rulevar =~ /$pattern/i) {
      $patlen = length("$pattern");
      if ($patlen <= $patlonglen) {
	next;
      }
      else {
        # the longest pattern length is now $patlen ... 
	$patlonglen = $patlen;
        # initialise header as longer rule has matched so use that instead! 
	@header = ();
      }
      foreach $linenum (reverse sort keys %{$recvfilter{"inclheader"}{"$pattern"}}) {
	$line = "$recvfilter{\"inclheader\"}{\"$pattern\"}{\"$linenum\"}\n";
	push(@header, "$line");  
      }
      foreach $linenum (reverse sort keys %{$recvfilter{"returnfile"}{"$pattern"}}) {
	$filename = "$recvfilter{\"returnfile\"}{\"$pattern\"}{\"$linenum\"}";
	$content_length = $filesize{"$filename"};
	push(@header, "Content-length: $content_length\n\n");
	@content = @filecontents["$filename"];
      }
      $prevous_pattern = $pattern;
    }
  }
  
  unshift(@header, "HTTP/1.0 200 OK\n"); 
  

  $sent_time = scalar localtime;
  print Client join('', @header);
  print Client join('',@content);
  close(Client);

  &log("WebElemental: request intercepted by recvfilter rule $time\n");
  &log("WebElemental: sent header below to $client_name port $client_port at $sent_time\n");
  &log("-" x 80, "\n");
  &log(join('',@header));
  &log("-" x 80, "\n");

  if ($debug_printfull) { 
    &log("WebElemental: Full content follows\n");
    &log(join('',@content));
  }

}
#
#
#
########################################################################################################################


########################################################################################################################
# getFileSize($filename): returns the size of the file 
#	
#
sub getFileSize { 
  my $filename = "@_";
  my $size;

  $size = -s "${returnfiledir}/${filename}";
  return "$size";
}
#
#
#
########################################################################################################################


########################################################################################################################
# getFileContents($filename): returns contents of $filename 
#	
#
sub getFileContents {
  my $filename = "@_";
  my @contents;
  # my *F;

  open(F, "${returnfiledir}/${filename}") || warn "Could not open file $filename : $!";
  @contents=<F>;
  close(F);
  return join('',@contents);
}
#
#
#
########################################################################################################################


########################################################################################################################
# usage: prints usage... 
#
#
sub usage {
  print "\n\n@_\n";
  print << "EOUSAGE"; 

Usage: $cmd [options]
       
   # no options - assumes webelemental.conf file is in the same directory as '$cmd'

   -sampleconf 	# produces sample config file...
   -p int   	# runs local server on port 'num'
   -nolog      	# does not keep log files even if logsdir is specified in config file... 
   -c file      # file to use as config file... 
   -ps		# prints some stats on the screen as they happen... uses temporary files
   		# so might cause the program to be a slow... 
   -about	# About this program

EOUSAGE
  exit(0);
}
#
#
#
########################################################################################################################

########################################################################################################################
# sub alarmcall: # the subroutine that is called when requests take too long to get a response for or respond to... 
#
#
sub alarmcall {
  my $signame = shift;
  my $realreason;
  my $iquote = &quote();
  
  $iquote =~ s/\n/\n<br>/g;

  my $reason1 = "The remote host was not contactable within $host_timeout seconds";
  my $reason2 = "The remote host did not start responding within $content_start_timeout seconds";
  my $reason3 = "The remote host had not sent any information in the past $content_end_timeout seconds";
  my $reason4 = "The remote host could not be contacted via the 'connect' function in perl";

  $realreason = "$reason1" if ($alarmcode == 1);
  $realreason = "$reason2" if ($alarmcode == 2);
  $realreason = "$reason3" if ($alarmcode == 3);
  $realreason = "$reason4" if ($alarmcode == 4);

  print Client "HTTP/1.0 200 OK\n";
  print Client "Content-type: text/html\n\n";
  print  Client <<EO_ALRM_MSG;
<body bgcolor=#4f96cf text=#f7ff7f>
<title> Alarm Call </title>
<h1>
Your browser made a request for which either: <br>
<ul>
<li> $reason1
<li> $reason2
<li> $reason3
<li> $reason4
</ul>
<br>
<ul>
<li> The most likely cause was: <br>
<font color=#4fcf96> $realreason </font>
</ul>
</h1>
</h3>
<center>
<hr>
<pre>
<table border=8 cellpadding=6>
<th>
$iquote
<tr>
</table>
</pre>
</center>
</h3>
EO_ALRM_MSG
  close(WebServer);
  close(Client);
  exit(1);
}
#
#
#
########################################################################################################################

########################################################################################################################
# sampleconf: prints out a sample configuration file... 
#
#
sub sampleconf { 
  print <<"EO_SAMPLE_CONF";
###############################################################################
# Sample webelemental.conf file                                               #
# WebElemental version $version                                        #
###############################################################################
#
# Anything after a '#' and blank lines are ignored in the config file 
# 
# This program was written just as an interesting thing to do :-) 
# It is capable of the following:
# 
#   * Blocking content/images (mainly ads ?) (making access possibly faster)
#   * Keeping logs of all headers that are passed back and forth
#   * Hacking the headers that are sent so that people do not know
#     any information you don't want them to know (eg. Referer field)
#
# This program was basically designed for small scale 
# personal use but if there is great interest in cutting out visual
# noise because of commercialisation of the internet... i might
# learn about proper tcp/ip and design a better larger scale
# program :-) 
#
# If you have any comments/suggessitions, bug fixes/reports :-) 
# mail me at simran\@cse.unsw.edu.au
#
# Anyway, to use this program, in your browser, set up your proxy server
# to be 'filterhost' and port 'filterport' where filterhost is where
# you are running this webelemental script and filterport which port you
# are binding to as in the config file below (default 2345)
# This program is valid only as the 'http' proxy at the moment...
# 
# -- 
# 
# You can specify the following identifiers...
# (note: in the case's of sendfilter and recvfilter, if more than
#        on rule matches, the rule that is longer in length is used
#        as it is assumed to be the more exact match!)
#
# --
# The 'host_timeout' keyword specified how many seconds we should timeout after
# if we have not been able to contact the remote host... 
# It has the form
#	host_timeout: number	
#
# --
# The 'content_start_timeout' keyword specified how many seconds we should timeout after
# if we have not been able to get any content from the remote host... 
# It has the form
#	content_start_timeout: number	
#
# --
# The 'content_end_timeout' keyword specified how many seconds we should timeout after
# if we have not got any content since the previous content line ... 
# It has the form
#	content_end_timeout: number	
#
# -- 
# The 'real_proxy' keyword identifies your real proxy if you have one. 
# It has the form
#	real_proxy: proxy_name:port_number
#
# --
# The 'returnfiledir' keyword specifies where files that are returned when
# the webelemental blocks requests are stored... 
# It has the form
#	returnfiledir: /some/path
#
# --
# The 'logsdir' keyword specifies where log files are kept. 
# It has the form
#	logsdir: /some/path
#
# --
# The 'port' keyword specifies which port the local server will run 
# It has the form
#	port: port_num
#
# --
# The 'sendfilter' keyword specifies which headers will be modified when
# sending information to url's that match the 'pattern'
# It has the form
#	sendfilter: pattern
#                   modheader: Header-Tag-1: Info-To-Pass-1
#		    modheader: Header-Tag-2: Info-To-Pass-2
#		    ... 
#                   
# You can have multiple modheader lines, a sendfilter rule however, MUST
# have a blank line after it. Also, if you browser does not send a header
# that you have requested to be modified via 'modheader' it will not be
# included. ie. The request will be sent through without that header. 
# Where pattern is a valid perl pattern, except that '/'s are automatically
# 'escaped'. (ie. You should not have a '\' before a '/' it is automatically
# put in. 
# (NOTE: pattern is matched againt the URL you are sending information
#        to - ie. www.somewhere.com.au/abc/index.html 
#        there is no leading http://
#        Also, the pattern is case insensitive!
# )
#
# --
# The 'recvfilter' keyword specifies which headers will be modified when
# sending information to url's that match the 'pattern'
# It has the form
#	recvfilter: pattern
#                   inclheader: Header-Tag-1: Info-To-Pass-1
#		    inclheader: Header-Tag-2: Info-To-Pass-2
#		    ... 
#                   
# You can have multiple modheader lines, a recvfilter rule however, MUST
# have a blank line after it. 
# Where pattern is a valid perl pattern, except that '/'s are automatically
# 'escaped'. (ie. You should not have a '\' before a '/' it is automatically
# put in. 
# (NOTE: pattern is matched againt the URL you are sending information
#        to - ie. www.somewhere.com.au/abc/index.html 
#        there is no leading http://
#        Also, the pattern is case insensitive!
# )
# 
# --
# The 'sendfilter_exclude' keyword lists a pattern that should be excluded
# from the 'sendfilter' rule! ie. Any requests sent to a url matching pattern
# will _not_ be modified. 
# It has the form
#       sendfilter_exclude: pattern
# Where pattern is a valid perl pattern, except that '/'s are automatically
# 'escaped'. (ie. You should not have a '\' before a '/' it is automatically
# put in.
# (NOTE: pattern is matched againt the URL you are sending information
#        to - ie. www.somewhere.com.au/abc/index.html
#        there is no leading http://
#        Also, the pattern is case insensitive!
# )
#
# --
# The 'recvfilter_exclude' keyword lists a pattern that should be excluded
# from the 'recvfilter' rule! ie. Any requests sent to a url matching pattern
# will _not_ be intercepted.
# It has the form
#       recvfilter_exclude: pattern
# Where pattern is a valid perl pattern, except that '/'s are automatically
# 'escaped'. (ie. You should not have a '\' before a '/' it is automatically
# put in.
# (NOTE: pattern is matched againt the URL you are sending information
#        to - ie. www.somewhere.com.au/abc/index.html
#        there is no leading http://
#        Also, the pattern is case insensitive!
#

###############################################################################
# Set up Essential Tags
#
#

# real_proxy:	proxy.somewhere.net:8080

host_timeout:	7
content_start_timeout: 240  # if the remote host does not _start_ responding whthin content_start_timeout seconds
			    # close the connection for that particular request... 
content_end_timeout: 180  # if the webser has not sent anything for the last content_end_timeout seconds then assume the 
			  # the connection is lost... 

logsdir:	/home/simran/webelemental/logs
returnfiledir:	/home/simran/webelemental/returnfiles
port:		2345

#
#
###############################################################################

###############################################################################
# Block realmedia ads
#
recvfilter: /realmedia/ads/
		inclheader: Content-type: image/gif
		returnfile: 50x50black.gif

# Note the 'empty line' above... it is essential :)

# We want to see realmedia sections on www.abc.net 
recvfilter_exclude: www\\.abc\\.net/realmedia 

#
###############################################################################

###############################################################################
# Block jpg images from www.abc.de
# 

recvfilter: ^www.abc.de/.*\\.jpg\$
		inclheader: Content-type: image/jpeg
		returnfile: 1x1black.jpg

# let any requests for content under special get through... 
recvfilter_exclude: ^www.abc.de/special/
#
###############################################################################

###############################################################################
# Block www.netaddress.com ads 
#

recvfilter: netaddress.usa.net/.*/ad_banners
                inclheader: Content-type: image/gif
		returnfile: 50x50black.gif

recvfilter: ad\\d+\\.netaddress\\.
                inclheader: Content-type: image/gif
		returnfile: 1x1black.gif

recvfilter: images.netaddress\..*/ad_buttons
                inclheader: Content-type: image/gif
                returnfile: 1x1black.gif

#
###############################################################################

###############################################################################
# Block yahoo ads 
#

recvfilter: \\.yahoo.*/adv/
                inclheader: Content-type: image/gif
		returnfile: 50x50black.gif

#
###############################################################################

###############################################################################
# Block anything from doubleclick... 
#

recvfilter: \\.doubleclick\\.
                inclheader: Content-type: image/gif
		returnfile: 1x1black.gif

#
###############################################################################

###############################################################################
# Don't send any .com site (except for Yahoo) correct Browser/OS and 
# Referer info... 
#

sendfilter: \\.com.*
		modheader: User-Agent: Not Telling You
		modheader: Referer: No Referer

sendfilter_exclude: \\.yahoo\\.com

#
###############################################################################

###############################################################################
# Block any html files named blah_blah_blah.html

recvfilter: /blah_blah_blah\\.html\$
                inclheader: Content-type: text/html
		returnfile: block.html
		# returnfile: block2.html

#
###############################################################################

EO_SAMPLE_CONF

}
#
#
#
########################################################################################################################


########################################################################################################################
#
#
#
sub quote {
  srand;
  my $max = $#quotes;
  my $num = int(rand $max); 
  return $quotes[$num];
}
#
#
#
########################################################################################################################


########################################################################################################################
#
#
#
sub initialise_quotes {
  @quotes = ();
  push(@quotes, "In the world there is nothing more submissive and weak than water.\nYet for attacking that which is hard and strong nothing can surpass it.\nThis is because there is nothing that can take its place.\n						Lao Tzu, Tao Te Ching\n");
  push(@quotes, "If the laws do not serve a man,\nabolish the laws, not the man.\n");
  push(@quotes, "Most smiles are started\nby another smile.\n");
  push(@quotes, "Don't lose the peace of years\nby seeking the rapture of moments.\n");
  push(@quotes, "The weak can never forgive.\nForgiveness is the attribute\nof the strong.\n");
  push(@quotes, "Never lose the chance of\nsaying a kind word.\n");
  push(@quotes, "To be happy, do not add\nto your possessions but \nsubtract from your desires.\n");
  push(@quotes, "Find yourself,\nknow yourself,\nbe yourself.\n");
  push(@quotes, "An eye for an eye only ends\nup making the whole world blind.\n");
  push(@quotes, "This will also pass away.\n");
  push(@quotes, "When you create peace in your mind,\nyou will find it in your life.\n");
  push(@quotes, "DON'T QUIT\n\nDon't quit when the tide is lowest,\nit's just about to turn;\nDon't quit over doubts and questions,\nthere's something you may learn.\n\nDon't quit when the night is darkest,\nFor it's just a while 'til dawn;\n\nDon't quit when you've run the farthest\nFor the race is almost won.\n\nDon't quit when the hill is steepest,\nFor your goal is almost nigh;\n\nDon't quit for you're not a failure\nUntil you fail to try. \n");
  push(@quotes, "If you must doubt, try doubting your doubts\nrather than your beliefs. \n");
  push(@quotes, "Forgiveness sets you free.\n");
  push(@quotes, "Truth is one, sages call\nit by different names.\n");
  push(@quotes, "The religion in your heart should\nbe visible in your life.\n");
  push(@quotes, "You are what you make of yourself.\n");
  push(@quotes, "Patience is a quality that is most\nneeded when it is exhausted.\n");
  push(@quotes, "The happiness of your life depends\non the character of your thoughts.\n");
  push(@quotes, "Wise individuals are not always silent\nbut they know when to be.\n");
  push(@quotes, "Those who sacrifice their conscience to ambition,\nburn a picture to obtain the ashes.\n");
  push(@quotes, "In the inner Self there is infinite inspiration.\nOpen your heart and see.\n");
  push(@quotes, "In wordly life, as well as on the spiritual path,\nit is boundless love and respect that make a person\nfeel very light and happy all the time.\nLove and respect transform ordinary life into a \ngarden of paradise.\n");
  push(@quotes, "The shadows are behind you\nif you walk towards the light.\n");
  push(@quotes, "A fool always finds some greater fool to admire him.\n\n                		Nicholas Boileau (1636-1711)\n\n");
  push(@quotes, "Much knowledge of divine things is lost to us through want of faith.\n   \n	                Heraclitus (B.C. 535-475)\n");
  push(@quotes, "Everything changes, nothing remains without change.\n   \n		                Buddha (B.C. 568-488)\n");
  push(@quotes, "It is impossible to begin to learn that which one thinks one already\nknows.\n   \n                				Epictetus (c.55-c.135)\n");
  push(@quotes, "Look around the habitable world, how few Know their own good, or\nknowing it, pursue.\n   \n                				Dryden (1631-1700)\n");
  push(@quotes, "Only that in you which is me can hear what I'm saying.\n   \n                			Baba Ram Dass (b.1931)\n");
  push(@quotes, "Education is an admirable thing, but it is well to remember from time\nto time that nothing that is worth knowing can be taught.\n   \n                				Oscar Wilde (1856-1900)\n");
  push(@quotes, "A wise man makes his own decisions, an ignorant man follows the public\nopinion.\n   \n                					Chinese Proverb\n");
  push(@quotes, "What a curious phenomenon it is that you can get men to die for the\nliberty of the world who will not make the little sacrifice that is\nneeded to free themselves from their own individual bondage.\n   \n                				Bruce Barton (1886-1967)\n");
  push(@quotes, "I do not know whether I was then a man dreaming I was a butterfly, or\nwhether I am now a butterfly dreaming I am a man.\n   \n			                Chuang-tzu (c.369-c.286 BC)\n");
  push(@quotes, "Your candle loses nothing by\nlighting anothers candle.\n");
  push(@quotes, "Demand not that events should happen as you wish, but wish them to\nhappen as they do, and you will go on well.\n   \n                				Epictetus (50-138 A.D.)\n");
  push(@quotes, "Asuan jal seech seech, prem bael boe, \naab to bael phal gaie anand phal hoi.\n  				- Meera\n(I sowed the vine of love and nurtured it with\n my tears - now it had grown and has the fruits\n of bliss on it)\n\n");
  push(@quotes, "There is not enough darkness in the whole world\nto put out the light of even one little candle.\n");
  push(@quotes, "The more I see of man,\nthe more I love my dog.\n");
  push(@quotes, "They talked about and about\nI came out of the same door I went in.\n");
  push(@quotes, "It was six men of Indonisian,\nTo learning much inclined,\nWho went to see the elephant\n(Though all of them were blind),\nThat each by observation\nMight satisfy the mind.\n\nThe first approached the elephant,\nAnd, happening to fall\nAgainst his broad and sturdy side,\nAt once began to bawl;\n`God bless me! but the elephant\nIs very like a wall!'\n\nThe second, feeling of the tusk,\nCried: `Ho! what have we here\nSo very round and smooth and sharp?\nTo me 'tis mighty clear\nThis wonder of an elephant\nIs very like a spear!'\n\nThe third approached the animal,\nAnd, happening to take \nThe squirming trunk within his hands,\nThus boldly up and spoke:\n`I see', quoth he,' the elephant\nIs very like a snake!'\n\nThe fourth reached out his eager hand,\nAnd felt about the knee:\n`What most this wondrous beast is like\nIs mighty plain,' quoth he;\n`This clear enough the elephant\nIs very like a tree!'\n\nThe fifth, who chanced to touch the ear,\nSaid: `E'en the blindest man \nCan tell what this resembles most;\nDeny the fact who can,\nThis marvel of an elephant\nIs very like a fan!'\n\nThe sixth no sooner had begun\nAbout the beast to grope,\nThan, seizing on the swinging tail\nThat fell within his scope,\n`I see', quoth he, `the elephant\nIs very like a rope!'\n\nAnd so these man of Indonisian \nDisputed loud and long,\nEach in his own opinion\nExceeding stiff and strong,\nThough each was partly in the right\nAnd all were in the wrong!\n");
  push(@quotes, "For him in vain the envious seasons roll\nWho bears eternal summer in his soul.\n");
  push(@quotes, "The mountain and the squirrel\nHad a quarrel,\nAnd the former called the latter \"Little prig.\"\nBun replied,\n\"You are doubtless very big;\nBut all sorts of things and weather \nMust be taken in together\nTo make up a year\nAnd a sphere.\nAnd I think it no disgrace\nTo occupy my place.\nIf I'm not so large as you,\nYou are not so small as I,\nAnd not half so spry:\nI'll not deny you make\nA very pretty squirrel track.\nTalents differ; all is well and wisely put;\nIf I cannot carry forests on my back,\nNeither can you crack a nut\"\n");
  push(@quotes, "Laugh and the world laughs with you,\nWeep and you weep alone:\nFor this brave old earth must borrow its mirth,\nIt has sorrow enough of its own.\nSing and the hills will answer,\nSigh! it is lost in the air.\nThe echos do bound a joyful sound,\nBut shrink from voicing care.\nRejoice and men will seek you,\nGrieve and they turn and go:\nThey want full measure of all your pleasure,\nBut they do not want your woe.\nBe glad and your friends are many,\nBe sad and you lose them all.\nThere is none to decline your nectared drink,\nBut alone you must drink life's gall\nFeast, and your halls are crowded;\nFast, and the world goes by;\nSucceed and give, and it helps you live,\nBut no one can help you die.\nThere is room in the halls of pleasure\nFor a long and lordy train,\nBut one by one we must all file on\nThrough the narrow aisles of pain.\n");
  push(@quotes, "He prayeth best who loveth best,\nBoth man, and bird and beast\nHe prayeth well who loveth well\nAll things both great and small.\n");
  push(@quotes, "He who plants kindness\ngathers love.\n");
  push(@quotes, "Even This Will Pass Away\n------------------------\n\nOnce in Persia reigned a king,\nWho upon a signet ring\nCarved a maxim strange and wise,\nWhen held before his eyes,\nGave him counsel at a glance,\nFor every change and chance:\nSolemn words and these were they:\n\"EVEN THIS WILL PASS AWAY\"\n\nTrains of camel through the sand\nBrought him gems from Samarcand;\nFleets of galleys over the seas\nBrought him pearls to rival these,\nBut he counted little gain,\nTreasures of the mine or main;\n\"What is wealth?\" the king would say,\n\"EVEN THIS WILL PASS AWAY\".\n\nMid the pleasures of his court\nAt the zenith of their sport,\nWhen the palms of all his guests\nBurned with clapping at his jests,\nSeated midst the figs and wine,\nSaid the king: Ah, friends of mine,\nPleasure comes but not to stay,\n\"EVEN THIS WILL PASS AWAY\".\n\nWoman, fairest ever seen\nWas the bride he crowned as queen\nPillowed on the marriage-bed\nWhispering to his soul he said\nThough no monarch ever pressed\nFairer bosom to his breast,\nMortal flesh is only clay!\n\"EVEN THIS WILL PASS AWAY\".\n\nFighting on the furious field,\nOnce a javelin pierced his shield,\nSoldiers with a loud lament\nBore him bleeding to his tortured side,\n\"Pain is hard to bear,\" he cried,\nBut with patience, day by day,\n\"EVEN THIS WILL PASS AWAY\".\n\nTowering in a public square\nForty cubits in the air,\nAnd the king disguised, unknown,\nGazed upon his sculptured name,\nAnd he pondered, What is fame?\nFame is but a slow decay!\n\"EVEN THIS WILL PASS AWAY\".\n\nStruck with palsy, sore and old,\nWaiting at the gates of gold,\nSaid he with his dying breath\n\"Life is done, but that is Death?\"\nThen an answer to the king\nFell a sunbeam on his ring;\nShowing by a heavenly ray,\n\"EVEN THIS WILL PASS AWAY\".\n");
  push(@quotes, "So many sects so many creeds,\nSo many paths that winde and winde,\nWhile just the art of being kind\nIs all the sad world needs.\n");
  push(@quotes, "The Olive Tree\n--------------\n\nSaid and ancient hermit bending\nHalf in prayer upon his knee,\n\"Oil I need for midnight watching,\nI desire an olive tree\".\n\nThen he took a tender sapling,\nPlanted it before his cave,\nSpread his trembling hands above it,\nAs his benison he gave.\n\nBut he thought, the rain it needeth,\nThat the root may drink and swell,\n\"God! I pray thee send Thy showers\"\nSo a gently shower fell.\n\n\"Lord! I ask for beams of summer\nCherishing this little child.\"\nThen the dripping clouds divided,\nAnd the sun looked down and smiled.\n\n\"Send it frost to brace its tissues,\nO my God!\" the hermit cried,\nThe plant was bright and hoary,\nBut at evensong it died.\n\nWent the hermit to a brother \nSitting in his rocky cell;\n\"Thou an olive tree possesseth;\nHow is this, my brother tell?\"\n\n\"I have planted one and prayed,\nNow for sunshine, now for rain,\nGod hath granted each petition,\nYet my olive tree hath slain!\"\n\nSaid the other, \"I entrusted \nTo its God my little tree;\nHe who made knew what it needed\nBetter than a man like me.\n\nLaid I on Him no conditions,\nFixed no ways and means; so I \nWonder not my olive thriveth,\nWhile thy olive tree did die.\"\n");
  push(@quotes, "The Turkey and The Ant\n----------------------\n\nA turkey, tried of common food,\nForsook the barn, and sought the wood,\nBehind her ran an infant train\nCollecting here and there a grain.\n`Draw near, my birds', the mother cries,\nThis hill delicious fare supplies.\nBehold the bush negro race--\nSee, millions blacken all the place!\nFear not; like me with freedom eat;\nAn ant is most delightful meat.\nHow blest, how envied, were our life\nCould we but `scape the poulterer's knife!\nBut man, cursed man, on turkey preys\nAnd Christmas shortens all our days.\nSometimes with oysters we combine,\nSometimes assist the savoury chine,\nFrom the low peasant to the Lord,\nThe turkey smokes on every board.\nSome men for gluttony are crust,\nOf the seven deadly sins the worst.\nAn ant, who climbed beyond her reach,\nThus answered from a neighbouring beech;\n`Ere you remark another's sin,\nBud thy own conscience look within;\nControl thy more voracious bill,\nNor, for a breakfast nations kill'.\n");
  push(@quotes, "The law, in its majestic equality, forbids the rich\nas well as the poor to sleep under bridges, to beg\nin the streets, and to steal bread.\n			- Anatole France, Crainquebille\n");
  push(@quotes, "The laws of God, the laws of man,\nHe may keep that will and can;\nNot I: let God and man decree\nLaws for themselves and not for me.\n			- A.E.Housnam, Last Poems\n");
  push(@quotes, "Across the fields of yesterday\nHe sometimes comes to me,\nA little lad just back from play-\nThe lad I used to be.\n		- T.S.Jones,Jr. Sometimes\n");
  push(@quotes, "He drew a circle that shut me out-\nHeretic, rebel, a thing to flout\nBut Love and I had the wit to win.\nWe drew a circle that took him in.\n			- Edwin Markham, Outwitted\n");
  push(@quotes, "Little drops of water,\nLittle grains of sand;\nMake the mighty ocean,\nAnd the pleasant land.\n");
  push(@quotes, "As a bird flies from its cage,\nNever turning to look at the grain it is leaving behind,\nNor at the jewelled fingers that fed it,\nDiscarding them, because, though beautiful,\nThey were the cause of its bondage;\nLeaving the music which was daily played before it,\nFlying higher and higher,\nNever looking back at the grain -\nSo must the soul of man\nFly into the sky of love of God and the Guru.\n");
  push(@quotes, "Everyday holds the\npossibility of miracles.\n");
  push(@quotes, "Just like the magnificent glory of the sun is \nreflected in the serene fullness of the moon.\nSimilarly the joy and happiness in our hearts \nshould be reflected in our lives.\n");
  push(@quotes, "Life is like a mirror - \nwe get the best results\nwhen we smile at it.\n");
  push(@quotes, "The ancient Masters were profound and subtle.\nTheir wisdom was unfathomable.\nThere is no way to describe it;\nall we can describe is their appearance.\n\nThey were careful\nas someone crossing an iced-over stream.\nAlert as a warrior in enemy territory.\nCourteous as a guest.\nFluid as melting ice.\nShapable as a block of wood.\nReceptive as a valley.\nClear as a glass of water.\n\nDo you have the patience to wait\ntill your mud settles and the water is clear ?\nCan you remain unmoving\ntill the right action arises by itself ?\n\nThe Master doesn't seek fulfillment.\nNot seeking, not expecting,\nshe is present, \nand can welcome all things.\n");
  push(@quotes, "What is rooted is easy to nourish.\nWhat is recent is easy to correct.\nWhat is brittle is easy to break.\nWhat is small is easy to scatter.\n\nPrevent trouble before it arises. \nPut things in order before they exist.\nThe giant pine tree\ngrows from a tiny sprout.\nThe journey of a thousand miles\nstarts from beneath your feet.\n\nRushing into action, you fail.\nTrying to grasp things, you lose them.\nForcing a project to completion,\nyou ruin what was almost ripe.\n\nTherefore the Master takes action\nby letting things take their course.\nHe remains as calm at the end\nas at the beginning.\nHe has nothing,\nthus has nothing to lose.\nWhat he desires is non-desire;\nwhat he learns is to unlearn.\nHe simply reminds people \nof who they have always been.\nHe cares about nothing \nbut the Tao.\nThus he can care\nfor all things.\n");
  push(@quotes, "True words aren't eloquent;\neloquent words aren't true.\nWise men don't need\nto prove their point;\nmen who need to prove \ntheir point aren't wise.\n\nThe Master has no possessions.\nThe more he does for others,\nthe happier he is.\nThe more he gives to others,\nthe wealthier he is.\n\nThe Tao nourishes\nby not forcing.\nBy not dominating,\nthe Master leads.\n");
  push(@quotes, "There is enough for every man's need but not\nenough for even one man's greed.\n");
  push(@quotes, "Broken Dreams\n\nAs children bring their broken toys\nwith tears for us to mend,\nI brought my broken dreams to God\nbecause he was my friend.\nBut then instead of leaving him \nin peace to work alone,\nI hung around and tried to help\nwith ways that were my own.\nAt last I snatched them back and cried,\n\"How can you be so slow ?\"\n\"My child\" he said,\n\"What could I do, You never did let go.\"\n");
  push(@quotes, "Many a doctrine is like a window pane, I see truth through it,\nbut it divides me from the truth\n				- Kahlil Gibran\n");
  push(@quotes, "When you let me take, I'm grateful,\nWhen you let me give, I'm blessed.\n");
  push(@quotes, "Fly, fly little wing\nFly beyond imagining\nThe softest cloud, the whitest dove\nUpon the wind of heaven's love\nPast the planets and the stars\nLeave this lonely world of ours\nEscape the sorrow and the pain\nAnd fly again\n\nFly, fly precious one\nYour endless journey has begun\nTake your gently happiness\nFar too beautiful for this\nCross over to the other shore\nThere is peace forevermore\nBut hold this mem'ry bittersweet\nUntil we meet\n\nFly, fly do not fear\nDon't waste a breath, don't shed a tear\nYour heart is pure, your soul is free\nBe on your way, don't wait for me\nAbove the universe you'll climb\nOn beyond the hands of time\nThe moon will rise, the sun will set\nBut I won't forget\n\nFly, fly little wing\nFly where only angels sing\nFly away the time is right\nGo now, find the light\n\n                - \"Fly\" (sung by Celine Dion)\n");
  push(@quotes, "It is better to light a candle\nthan to curse the darkness.\n");
  push(@quotes, "Love believes all things, hopes all things, endures all things.\nLove never fails. \n		(1 Corinthians 13)\n");
  push(@quotes, "True love is knowing that even when\nyou are alone, you will never be lonely again.\n");
  push(@quotes, "To release a person from the expectations we\nhave of them is to really love them.\n");
  push(@quotes, "Peace of Mind\n-------------\n\nPeace of mind is a treasure,\nof greater worth than gold;\nMore precious than a jewel,\nand if this prize you hold;\nYou're rich beyond all telling,\nFor even if time may prove unkind,\nit cannot rob you of the treasures,\nOf a peaceful mind. \n");
  push(@quotes, "People are lonely today\nbecause they build walls\ninstead of bridges.\nReach out to someone today!\n");
  push(@quotes, "When you help someone up a steep hill\nyou get closer the top yourself.\n");
  push(@quotes, "Peace comes not from the absence\nof conflict in life but from the\nability to cope with it.\n");
  push(@quotes, "Never answer an angry word with\nan angry word. It's the second\none that makes the quarrel.\n");
  push(@quotes, "It is a big thing to do\na little thing well.\n");
  push(@quotes, "A little love, a little trust,\nA soft impulse, a sudden dream,\nAnd life as dry as desert dust\nIs sweeter than a mountain stream.\n");
  push(@quotes, "Temper takes you to trouble.\nPride keeps you there.\n");
  push(@quotes, "A successful man is one who can lay\na firm foundation with the bricks\nthat others throw at him.\n");
  push(@quotes, "Two or three minutes - two or three hours,\nWhat do they mean in this life of ours ?\nNot very much if but counted as time,\nbut minutes of gold and hours sublime,\nIf only we'll use them once in a while\nTo make somebody happy - make someone smile.\nA minute may dry a lad's tears,\nA hour sweep aside trouble of years.\nMinutes of my time may bring to an end\nHopelessness somewhere, and bring me a friend.\n");
  push(@quotes, "Every revolution was first a\nthought in one man's mind.\n");
  push(@quotes, "If the laws do not server the men,\nchange the laws, not the men.\n");
  push(@quotes, "My life is my message.\n			- Gandhi\n");
  push(@quotes, "Pleasant thoughts make\npleasant lives.\n");
  push(@quotes, "The longest journey begins\nwith a single step.\n");
  push(@quotes, "To profit from good advice requires\nmore wisdom than to give it.\n");
  push(@quotes, "To see a world in a grain of sand\nAnd a heaven in a wild flower,\nHold infinity in the palm of your hand\nAnd eternity in an hour.\n			William Blake, Auguries of Innocence\n");
  push(@quotes, "You are sowing the flowers\nof tomorrow in the seeds of today.\n");
  push(@quotes, "Happiness will never come to those\nwho fail to appreciate what they already have.\n");
  push(@quotes, "Keep your head and your heart going in the right direction\nand you'll not have to worry about your feet.\n");
  push(@quotes, "The way to gain a good reputation is to\nendeavor to be what you desire to appear.\n");
  push(@quotes, "How beautiful a day can be\nwhen kindness touches it.\n");
  push(@quotes, "Knowledge is proud that it knows so much;\nwisdom is humble that it knows no more.\n");
  push(@quotes, "Freedom is a sure possession of only\nthose who have the courage to defend it.\n");
  push(@quotes, "Joy is not in things,\nit is in us.\n");
  push(@quotes, "The miracle is this ... \nthe more we share the more we have.\n");
  push(@quotes, "Peace is never denied to the peaceful.\n");
  push(@quotes, "Great achievements begin \nwith small opportunities.\n");
  push(@quotes, "Some succeed because they are destined to,\nbut most succeed because they are determined to.\n");
  push(@quotes, "Today's preparation determines tomorrow's achievement.\n");
  push(@quotes, "We can give advice but we can't give\nthe wisdom to profit by it.\n");
  push(@quotes, "\" We must support friends even in their mistakes; however,\n  it must be the friend and not the mistake we are supporting. \"\n                           -- Mohandas Karamchand Gandhi\n");
  push(@quotes, "Faith keeps the man\nwho keeps the faith.\n");
  push(@quotes, "Temper gets people into trouble,\nbut pride keeps them there.\n");
  push(@quotes, "Never underestimate the \npower of a kind word.\n");
  push(@quotes, "This above all: to thine\nown self be true.\n");
  push(@quotes, "Individuals with clenched fists\ncannot shake hands.\n");
  push(@quotes, "The courage to speak must be matched by the wisdom to listen.\n");
  push(@quotes, "True love begins, \nwhen nothing is expected in return.\n");
  push(@quotes, "People whose main concern is \ntheir own happiness seldom find it.\n");
  push(@quotes, "Advice is like the snow;\nthe softer it falls the longer it dwells upon,\nand the deeper it sinks into the mind.\n");
  push(@quotes, "You must speak to be heard but sometimes\nyou have to be silent to be appreciated.\n");
  push(@quotes, "Truth often hurts, but it's the lie that leaves the scars.\n");
  push(@quotes, "One person with courage makes a majority.\n");
  push(@quotes, "Have patience. If you pluck the \nblossoms, you must do without the fruit.\n");
  push(@quotes, "If you cannot find happiness along the way,\nyou will not find it at the end of the road.\n");
  push(@quotes, "Forgiveness is a funny thing.\nIt warms the heart and cools the sting.\n");
  push(@quotes, "There is no one luckier than\nhe who thinks he is.\n");
  push(@quotes, "If you get up one time more \nthan you fall, you will make it through.\n");
  push(@quotes, "Those who bring sunshine to the\nlives of others cannot keep it\nfrom themselves.\n");
  push(@quotes, "The kindest people are those\nwho forgive and forget.\n");
  push(@quotes, "The best advice is only as good\nas the use we make of it.\n");
  push(@quotes, "Hope sees the invisible,\nfeels the intangible and \nachieves the impossible.\n");
  push(@quotes, "Those who remember the past with a clear\nconscience need have no fear of the future.\n");
  push(@quotes, "Anyone who angers you conquers you.\n");
  push(@quotes, "True dignity is never gained by place,\nand never lost when honors are withdrawn.\n");
  push(@quotes, "Some people speak from experience;\nothers, from experience do not speak.\n");
  push(@quotes, "The best way to say something is to say it,\nunless remaining silent will say it better.\n");
  push(@quotes, "The first great gift we can \nbestow on others is good example.\n");
  push(@quotes, "What can't be done by advice can often be done by example.\n");
  push(@quotes, "He is no fool who gives what\nhe cannot keep to gain what\nhe cannot lose.\n");
  push(@quotes, "The only way to have a friend is to be one.\n");
  push(@quotes, "The best kind of pride is that which\ncompels a person to do their best work - even when no one is looking.\n");
  push(@quotes, "What we frankly give, forever is our own.\n");
  push(@quotes, "The heart sees what is\ninvisible to the eye.\n");
  push(@quotes, "Remember the tea kettle! Though up to\nits neck in hot water, it continues to sing.\n");
  push(@quotes, "Still waters run deep.\n");
  push(@quotes, "What we see depends on what were looking for.\n");
  push(@quotes, "Laughing at yourself gives you a lot to smile about.\n");
  push(@quotes, "Faith sees the invisible,\nbelieves the incredible, \nand receives the impossible.\n");
  push(@quotes, "When it is dark enough,\nyou can see the stars.\n");
  push(@quotes, "You are rich when you are\ncontent with what you have.\n");
  push(@quotes, "The rose perfumes even the hand that crushes it.\n");
  push(@quotes, "This will also pass away.\n");
  push(@quotes, "Little drops of water,\nLittle grains of sand;\nMake the mighty ocean,\nand the pleasant land.\n");
  push(@quotes, "Peace is when time doesn't matter as it passes by.\n");
  push(@quotes, "Be great in the little things.\n");
  push(@quotes, "Be what you wish others to become.\n");
  push(@quotes, "Love doesn't try to see through others,\nbut to see others through.\n");
  push(@quotes, "FOOTPRINTS\n\nOne night a man had a dream.\nHe dreamed he was walking along\nthe beach with the Lord. Across the\nsky flashed scenes from his life. For \neach scene, he noticed two sets of \nfootprints in the sand: one belonging \nto him, and the other to the Lord.\n\nWhen the last scene of his life\nflashed before him, he looked back\nat the footprints in the sand. He\nnoticed that many times along the \npath of his life there was only one\nset of footprints. He also noticed that\nit happened at the very lowest and\nsaddest times in his life.\n\nThis really bothered him and he\nquestioned the Lord about it. \"Lord,\nYou said that once I decided to \nfollow you, You'd walk with me all\nthe way. But I have noticed that\nduring the most troublesome times\nin my life, there is only one set of\nfootprints. I don't understand why\nwhen i needed You most You would\nleave me.\"\n\nThe Lord replied, \"My son, My\nprecious child, I love you and would\nnever leave you. During your times\nof trial and suffering, when you see\nonly one set of footprints, it was\nthen that i carried you.\"\n");
  push(@quotes, "THE DIFFERENCE\n\nI got up early this morning\nAnd rushed right into the day;\nI had so much to accomplish\nThat I didn't have time to pray.\n\nProblems just tumbled about me,\nAnd heavier came each task;\n\"Why doesn't God help me?\"\n  I wondered.\nHe answered, \"You didn't ask.\"\n\nI wanted to see joy and beauty,\nBut the day toiled on gray on bleak;\nI wondered why God didn't show me.\nHe said, \"But you didn't seek.\"\n\nI tried to come into God's presence;\nI used all my keys in the lock.\nGod gently and lovingly chided,\n\"My child, you didn't knock.\"\n\nI woke up early this morning,\nAnd paused before entering this day;\nI had so much to accomplish\nThat i had to take time to pray.\n");
  push(@quotes, "Your smile is the most\nimportant thing your wear.\n");
  push(@quotes, "We can always live on less when\nwe have more to live for.\n");
  push(@quotes, "There is no future in any job.  The future lies in the\nman who holds the job.\n                              - Dr. George Crane\n");
  push(@quotes, "Joyful thoughts create a joyful world.\n");
  push(@quotes, "Courtesy costs nothing yet it\nbuys things that are priceless.\n");
  push(@quotes, "Always look for the good in people.\n");
  push(@quotes, "Every experience in your life\nis an opportunity for growth.\n");
  push(@quotes, "Make the mistakes of yesterday\nyour lessons for today.\n");
  push(@quotes, "If you use time to improve yourself\nyou will not have time to criticize others.\n");
  push(@quotes, "The most important person to \nbe honest with is yourself.\n");
  push(@quotes, "Find peace within yourself and\nyou will not have to seek it elsewhere.\n");
  push(@quotes, "Choice, not chance\ndetermines destiny.\n");
}
#
#
#
########################################################################################################################

########################################################################################################################
#
#
#
sub about {
  print <<"EOABOUT";

  WebElemental $version
  ----------------------------------

  Written to block the visual noise of ads, and to 
  modify outgoing header info so that for example
  if we don't want to give someone info on what 
  computer system or browser we are using, or 
  referer info, we don't have to :-) 
  Its useful for logging what is being sent back 
  and forth as well. See sample config file for
  more detail! 

  Please mail comments/suggestions to simran\@cse.unsw.edu.au

EOABOUT
  exit(0);
}
#
#
#
########################################################################################################################

