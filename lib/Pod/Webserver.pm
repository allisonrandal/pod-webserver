
require 5;
package Pod::Webserver;
use strict;
use vars qw( $VERSION @ISA );
$VERSION = '3.04';

BEGIN {
  if(defined &DEBUG) { } # no-op
  elsif( defined &Pod::Simple::DEBUG ) { *DEBUG = \&Pod::Simple::DEBUG }
  elsif( ($ENV{'PODWEBSERVERDEBUG'} || '') =~ m/^(\d+)$/ )
    { my $x = $1; *DEBUG = sub(){$x} }
  else { *DEBUG = sub () {0}; }
}

#sub Pod::Simple::HTMLBatch::DEBUG () {5}

use Pod::Simple::HTMLBatch;
use Pod::Simple::TiedOutFH;
use Pod::Simple;
use Carp ();
use IO::Socket;
use File::Spec::Unix ();
@ISA = ('Pod::Simple::HTMLBatch');

__PACKAGE__->Pod::Simple::_accessorize(
 'httpd_port',
 'httpd_host',
 'httpd_timeout',
 'skip_indexing',
);

httpd() unless caller;

# Run me as:  perl -MPod::HTTP -e Pod::Webserver::httpd
# or (assuming you have it installed), just run "podwebserver"
#==========================================================================

sub httpd {
  my $self = @_ ? shift(@_) : __PACKAGE__;
  $self = $self->new unless ref $self;
  $self->{'_batch_start_time'} = time();
  $self->_get_options;

  $self->contents_file('/');
  $self->prep_for_daemon;

  my $daemon = $self->new_daemon || return;
  my $url = $daemon->url;
  $url =~ s{//default\b}{//localhost} if $^O =~ m/Win32/; # lame hack

  DEBUG > -1 and print "You can now open your browser to $url\n";

  return $self->run_daemon($daemon);
}

#==========================================================================

sub _get_options {
  my($self) = shift;
  $self->verbose(0);
  return unless @ARGV;
  require Getopt::Std;
  my %o;
  die "Aborting" unless

  Getopt::Std::getopts( "p: H:  q v  h V" => \%o ) || die "Aborting\n";
  
  # The three switches that shortcut the run:
  $o{'h'} and exit( $self->_arg_h || 0);
  $o{'V'} and exit( $self->_arg_V || 0);

  $self->verbose(4) if $o{'v'};

  $self->skip_indexing(1) if $o{'q'};
  $self->httpd_host( $o{'H'} ) if $o{'H'};
  $self->httpd_port( $o{'p'} ) if $o{'p'};
  return;
}

sub _arg_h {
  my $class = ref($_[0]) || $_[0];
  $_[0]->_arg_V;
  print join "\n",
    "Usage:",
    "  podwebserver                   = start podwebserver on localhost:8020",
    "  podwebserver -p 1234           = start podwebserver on localhost:1234",
    "  podwebserver -p 1234 -H blorp  = start podwebserver on blorp:1234",
    "  podwebserver -q                = quick startup (but no Table of Contents)",
    "  podwebserver -v                = run with verbose output to STDOUT",
    "  podwebserver -h                = see this message",
    "  podwebserver -V                = show version information",
    "\nRun 'perldoc $class' for more information.",
  "";
  return;
}

sub _arg_V {
  my $class = ref($_[0]) || $_[0];
  #
  # Anything else particularly useful to report here?
  #
  print '', __PACKAGE__, " version $VERSION",
    # and report if we're running a subclass:
    (__PACKAGE__ eq $class) ? () : (" ($class)"),
    "\n",
  ;
  print " Running under perl version $] for $^O",
    (chr(65) eq 'A') ? "\n" : " in a non-ASCII world\n";
  print " Win32::BuildNumber ", &Win32::BuildNumber(), "\n"
    if defined(&Win32::BuildNumber) and defined &Win32::BuildNumber();
  print " MacPerl verison $MacPerl::Version\n"
    if defined $MacPerl::Version;
  return;  
}

#==========================================================================

sub _serve_pod {
  my($self, $modname, $filename, $resp) = @_;
  unless( -e $filename and -r _ and -s _ ) { # sanity
    $self->muse( "But filename $filename is no good!" );
    return;
  }
  
  my $modtime = (stat(_))[9];  # use my own modtime whynot!
  $resp->content('');
  my $contr = $resp->content_ref;

  $Pod::Simple::HTMLBatch::HTML_EXTENSION
     = $Pod::Simple::HTML::HTML_EXTENSION = '';

  $resp->header('Last-Modified' => time2str($modtime) );

  my $retval;
  if(
    # This is totally gross and hacky.  So unless your name rhymes
    #  with "Pawn Lurk", you have to cover your eyes right now.
    $retval =
    $self->_do_one_batch_conversion(
      $modname,
      { $modname => $filename },
      '/',
      Pod::Simple::TiedOutFH->handle_on($contr),
    )
  ) {
    $self->muse( "$modname < $filename" );
  } else {
    $self->muse( "Ugh, couldn't convert $modname"  );
  }

  return $retval;  
}

#==========================================================================

sub new_daemon {
  my $self = shift;
  my @opts = (
      defined($self->httpd_host) ?
             (LocalHost => $self->httpd_host) : (),
              LocalPort => $self->httpd_port || 8020,
              Timeout   =>
               defined($self->httpd_timeout) ?
                       $self->httpd_timeout : (5*3600), # exit after 5H idle
  );
  $self->muse( "Starting daemon with options {@opts}" );
  Pod::Webserver::Daemon->new(@opts) || die "Can't start a daemon: $!\nAborting";
}

#==========================================================================

sub prep_for_daemon {
  my($self) = shift;

  DEBUG > -1 and print "I am process $$ = perl ", __PACKAGE__, " v$VERSION\n";

  $self->{'__daemon_fs'} = {};  # That's where we keep the bodies!!!!
  $self->{'__expires_as_http_date'} = time2str(24*3600+time);
  $self->{  '__start_as_http_date'} = time2str(        time);

  $self->add_to_fs( 'robots.txt', 'text/plain',  join "\cm\cj",
    "User-agent: *",
    "Disallow: /",
    "", "", "# I am " . __PACKAGE__ . " v$VERSION", "", "",
  );
  
  $self->add_to_fs( '/', 'text/html', 
   # We get this only when we start up in -q mode:
   "* Perl Pod server *\n<p>Example URL: http://whatever/Getopt/Std\n\n"
  );
  $self->_spray_css(        '/' );
  $self->_spray_javascript( '/' );
  DEBUG > 5 and print "In FS: ",
    join(' ', map qq{"$_"}, sort grep !m/^\e/, keys %{ $self->{'__daemon_fs'} }),
    "\n";

  $self->prep_lookup_table();

  return;
}

#==========================================================================

sub prep_lookup_table {
  my $self = shift;
    
  my $m2p;
  
  if( $self->skip_indexing ) {
    $self->muse("Skipping \@INC indexing.");
  } else {

    if($self->progress) {
      DEBUG and print "Using existing progress object\n";
    } elsif( DEBUG or ($self->verbose() >= 1 and $self->verbose() <= 5) ) {
      require Pod::Simple::Progress;
      $self->progress( Pod::Simple::Progress->new(4) );
    }

    my $search = $Pod::Simple::HTMLBatch::SEARCH_CLASS->new;
    if(DEBUG > -1) {
      print " Indexing all of \@INC -- this might take a minute.\n", 
        "\@INC = [ @INC ]\n";
      $self->{'httpd_has_noted_inc_already'} ++;
    }
    $m2p = $self->modnames2paths();
    $self->progress(0);
    
    die "What, no name2path?!" unless $m2p and keys %$m2p;
    DEBUG > -1 and print " Done scanning \@INC\n";

    foreach my $modname (sort keys %$m2p) {
      my @namelets = split '::', $modname;
      $self->note_for_contents_file( \@namelets, 'crunkIn', 'crunkOut' );
    }
    $self->write_contents_file('crunkBase');
  }
  $self->{'__modname2path'} = $m2p || {};
  return;
}

sub write_contents_file {
  my $self = shift;
  $Pod::Simple::HTMLBatch::HTML_EXTENSION
     = $Pod::Simple::HTML::HTML_EXTENSION = '';
  return $self->SUPER::write_contents_file(@_);
}

#==========================================================================

sub add_to_fs {  # add an item to my virtual in-memory filesystem
  my($self,$file,$type,$content) = @_;

  Carp::croak "What filespec?" unless defined $file and length $file;
  $file = "/$file";
  $file =~ s{/+}{/}s;
  $type ||=
     $file eq '/'        ? 'text/html' # special case
   : $file =~ m/\.dat?/  ? 'application/octet-stream'
   : $file =~ m/\.html?/ ? 'text/html'
   : $file =~ m/\.txt/   ? 'text/plain'
   : $file =~ m/\.gif/   ? 'image/gif'
   : $file =~ m/\.jpe?g/ ? 'image/jpeg'
   : $file =~ m/\.png/   ? 'image/png'
   : 'text/plain'
  ;
  $content = '' unless defined '';
     $self->{'__daemon_fs'}{"\e$file"} = $type;
  \( $self->{'__daemon_fs'}{$file} = $content );
}

sub _wopen {             # overriding the superclass's
  my($self, $outpath) = @_;
  return Pod::Simple::TiedOutFH->handle_on( $self->add_to_fs($outpath) );
}

# All of these are hacky to varying degrees
sub makepath { return }               # overriding the superclass's
sub _contents_filespec { return '/' } # overriding the superclass's
sub url_up_to_contents { return '/' } # overriding the superclass's
#sub muse { return 1 }
sub filespecsys { $_[0]{'_filespecsys'} || 'File::Spec::Unix' }

#==========================================================================

sub run_daemon {
  my($self, $daemon) = @_;

  while( my $conn = $daemon->accept ) {
    if( my $req = $conn->get_request ) {
      #^^ That used to be a while(... instead of an if( ..., but the
      # keepalive wasn't working so great, so let's just leave it for now.
      # It's not like our server here is streaming GIFs or anything.

      DEBUG and print "Answering connection at ", localtime()."\n";
      $self->_serve_thing($conn, $req);
    }
    $conn->close;
    undef($conn);
  }
  $self->muse("HTTP Server terminated");
  return;
}

#==========================================================================

sub _serve_thing {
  my($self, $conn, $req) = @_;
  return $conn->send_error(405) unless $req->method eq 'GET';  # sanity

  my $path = $req->url;
  $path .= substr( ($ENV{PATH} ||''), 0, 0);  # to force-taint it.
  
  my $fs   = $self->{'__daemon_fs'};
  my $pods = $self->{'__modname2path'};
  my $resp = Pod::Webserver::Response->new(200);
  $resp->content_type( $fs->{"\e$path"} || 'text/html' );
  
  $path =~ s{:+}{/}g;
  my $modname = $path;
  $modname =~ s{/+}{::}g;   $modname =~ s{^:+}{};
  $modname =~ s{:+$}{};     $modname =~ s{:+$}{::}g;
  if( $modname =~ m{^([a-zA-Z0-9_]+(?:::[a-zA-Z0-9_]+)*)$}s ) {
    $modname = $1;  # thus untainting
  } else {
    $modname = '';
  }
  DEBUG > 1 and print "Modname $modname ($path)\n";
  
  if( $fs->{$path} ) {   # Is it in our mini-filesystem?
    $resp->content( $fs->{$path} );
    $resp->header( 'Last-Modified' => $self->{  '__start_as_http_date'} );
    $resp->header( 'Expires'       => $self->{'__expires_as_http_date'} );
    $self->muse("Serving pre-cooked $path");
  } elsif( $modname eq '' ) {
    $resp = '';
  
  # After here, it's only untainted module names
  } elsif( $pods->{$modname} ) {   # Is it known pod?
    #$self->muse("I know $modname as ", $pods->{$modname});
    $self->_serve_pod( $modname, $pods->{$modname}, $resp )  or  $resp = '';
    
  } else {
    # If it's not known, look for it.
    #  This is necessary for indexless mode, and also useful just incase
    #  the user has just installed a new module (after the index was generated)
    my $fspath = $Pod::Simple::HTMLBatch::SEARCH_CLASS->new->find($modname);
    
    if( defined($fspath) ) {
      #$self->muse("Found $modname as $fspath");
      $self->_serve_pod( $modname, $fspath, $resp );
    } else {
      $resp = '';
      $self->muse("Can't find $modname in \@INC");
      unless( $self->{'httpd_has_noted_inc_already'} ++ ) {
        $self->muse("  \@INC = [ @INC ]");
      }
    }
  }
  
  
  $resp ? $conn->send_response( $resp ) : $conn->send_error(404);

  return;
}

#==========================================================================

# Inlined from HTTP::Date to avoid a dependency

{
  my @DoW = qw(Sun Mon Tue Wed Thu Fri Sat);
  my @MoY = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

  sub time2str (;$) {
    my $time = shift;
    my ($sec, $min, $hour, $mday, $mon, $year, $wday) = gmtime($time);
    sprintf("%s, %02d %s %04d %02d:%02d:%02d GMT",
	    $DoW[$wday],
	    $mday, $MoY[$mon], $year+1900,
	    $hour, $min, $sec);
  }
}

#==========================================================================

package Pod::Webserver::Response;

sub new {
  my ($class, $status_code) = @_;
  bless {code=>$status_code}, $class;
}

sub DESTROY {};

# The real methods are setter/getters. We only need the setters.
sub AUTOLOAD {
  my ($attrib) = $Pod::Webserver::Response::AUTOLOAD =~ /([^:]+)$/;
  $_[0]->{$attrib} = $_[1];
}

sub header {
  my $self = shift;
  push @{$self->{header}}, @_;
}

# The real method is a setter/getter. We only need the getter.
sub content_ref {
  my $self = shift;
  \$self->{content};
}

#==========================================================================

package Pod::Webserver::Daemon;
use Socket qw(PF_INET SOCK_STREAM SOMAXCONN inet_aton sockaddr_in);

sub new {
  my $class = shift;
  my $self = {@_};
  $self->{LocalHost} ||= 'localhost';

  # Anonymous file handles the 5.004 way:
  my $sock = do {local *SOCK; \*SOCK};

  my $proto = getprotobyname('tcp') or die "getprotobyname: $!";
  socket($sock, PF_INET, SOCK_STREAM, $proto) or die "Can't create socket: $!";
  my $host = inet_aton($self->{LocalHost})
    or die "Can't resolve hostname '$self->{LocalHost}'";
  my $sin = sockaddr_in($self->{LocalPort}, $host);
  bind $sock, $sin
    or die "Couldn't bind to $self->{LocalHost}:$self->{LocalPort}: $!";
  listen $sock, SOMAXCONN or die "Couldn't listen: $!";

  $self->{__sock} = $sock;

  bless $self, $class;
}

sub url {
  my $self = shift;
  "http://$self->{LocalHost}:$self->{LocalPort}/";
}

sub accept {
  my $self = shift;
  my $sock = $self->{__sock};

  my $rin = '';
  vec($rin, fileno($sock), 1) = 1;

  # Sadly getting a valid returned time from select is not portable

  my $end = $self->{Timeout} + time;

  do {
    if (select ($rin, undef, undef, $self->{Timeout})) {
      # Ready for reading;

      my $got = do {local *GOT; \*GOT};
      #$! = "";
      accept $got, $sock or die "accept failed: $!";
      return Pod::Webserver::Connection->new($got);
    }
  } while (time < $end);

  return undef;
}

#==========================================================================

package Pod::Webserver::Request;

sub new {
  my $class = shift;
  bless {@_}, $class
}

sub url {
  return $_[0]->{url};
}

sub method {
  return $_[0]->{method};
}

#==========================================================================
package Pod::Webserver::Connection;

sub new {
  my ($class, $fh) = @_;
  bless {__fh => $fh}, $class
}

sub get_request {
  my $self = shift;

  my $fh = $self->{__fh};

  my $line = <$fh>;
  if (!defined $line or !($line =~ m!^([A-Z]+)\s+(\S+)\s+HTTP/1\.\d+!)) {
    $self->send_error(400);
    return;
  }

  return Pod::Webserver::Request->new(method=>$1, url=>$2);
}

sub send_error {
  my ($self, $status_code) = @_;

  my $message = "HTTP/1.0 $status_code HTTP error code $status_code\n" .
    "Date: " . Pod::Webserver::time2str(time) . "\n" . <<"EOM";
Content-Type: text/plain

Something went wrong, generating code $status_code.
EOM

  $message =~ s/\n/\15\12/gs;

  print {$self->{__fh}} $message;
}

sub send_response {
  my ($self, $response) = @_;

  my $message = "HTTP/1.0 200 OK\n"
    . "Date: " . Pod::Webserver::time2str(time) . "\n"
    . "Content-Type: $response->{content_type}\n";

  # This is destructive, but for our local purposes it doesn't matter
  while (my ($name, $value) = splice @{$response->{header}}, 0, 2) {
    $message .= "$name: $value\n";
  }

  $message .= "\n$response->{content}";

  $message =~ s/\n/\15\12/gs;

  print {$self->{__fh}} $message;
}

sub close {
  close $_[0]->{__fh};
}

#==========================================================================

1;

__END__

=head1 NAME

Pod::Webserver -- minimal web server to serve local Perl documentation

=head1 SYNOPSIS

  % podwebserver
  You can now point your browser at http://localhost:8020/

=head1 DESCRIPTION

This module can be run as an application that works as a
minimal web server to serve local Perl documentation.  It's like
L<perldoc> except it works through your browser.

Run F<podwebserver -h> for a list of runtime options.




=head1 SECURITY (AND @INC)

Pod::Webserver is not what you'd call a gaping security hole --
after all, all it does and could possibly do is serve HTML
versions of anything you could get by typing "perldoc
SomeModuleName".  Pod::Webserver won't serve files at
arbitrary paths or anything.

But do consider whether you're revealing anything by 
basically showing off what versions of modules you've got
installed; and also consider whether you could be revealing
any proprietary or in-house module documentation.

And also consider that this exposes the documentation
of modules (i.e., any Perl files that at all look like
modules) in your @INC dirs -- and your @INC probably
contains "."!  If your current working directory could
contain modules I<whose Pod> you don't
want anyone to see, then you could do two things:
The cheap and easy way is to just chdir to an
uninteresting directory:

  mkdir ~/.empty; cd ~/.empty; podwebserver

The more careful approach is to run podwebserver
under perl in -T (taint) mode (as explained in
L<perlsec>), and to explicitly specify what extra
directories you want in @INC, like so:

  perl -T -Isomepath -Imaybesomeotherpath -S podwebserver

You can also use the -I trick (that's a capital "igh", 
not a lowercase "ell") to add dirs to @INC even
if you're not using -T.  For example:

  perl -I/that/thar/Module-Stuff-0.12/lib -S podwebserver

An alternate approach is to use your shell's
environment-setting commands to alter PERL5LIB or
PERLLIB before starting podwebserver.

These -T and -I switches are explained in L<perlrun>. But I'll note in
passing that you'll likely need to do this to get your PERLLIB
environment variable to be in @INC...

  perl -T -I$PERLLIB -S podwebserver

(Or replacing that with PERL5LIB, if that's what you use.)


=head2 ON INDEXING '.' IN @INC

Pod::Webserver uses the module Pod::Simple::Search to build the index
page you see at http://yourservername:8020/ (or whatever port you
choose instead of 8020). That module's indexer has one notable DWIM
feature: it reads over @INC, except that it skips the "." in @INC.  But
you can work around this by expressing the current directory in some
other way than as just the single literal period -- either as some
more roundabout way, like so:

  perl -I./. -S podwebserver

Or by just expressing the current directory absolutely:

  perl -I`pwd` -S podwebserver

Note that even when "." isn't indexed, the Pod in files under it are
still accessible -- just as if you'd typed "perldoc whatever" and got
the Pod in F<./whatever.pl>



=head1 SEE ALSO

This module is implemented using many CPAN modules,
including: L<Pod::Simple::HTMLBatch> L<Pod::Simple::HTML>
L<Pod::Simple::Search> L<Pod::Simple>

See also L<Pod::Perldoc> and L<http://search.cpan.org/>


=head1 COPYRIGHT AND DISCLAIMERS

Copyright (c) 2004-2006 Sean M. Burke.  All rights reserved.

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

This program is distributed in the hope that it will be useful, but
without any warranty; without even the implied warranty of
merchantability or fitness for a particular purpose.

=head1 AUTHOR

Original author: Sean M. Burke C<sburke@cpan.org>

Maintained by: Allison Randal C<allison@perl.org>

=cut


