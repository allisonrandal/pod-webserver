BEGIN {
    chdir "t" if -e "t";
    if($ENV{PERL_CORE}) {
        @INC = '../lib';
    } else {
        push @INC, '../lib';
    }
}
require 5;
use strict;
use warnings;
use IO::Socket;

# When run with the single argument 'client', the test script should run
# a dummy client and exit.
my $mode = shift || '';
if ($mode eq 'client') {
    my $port = $ENV{'PODWEBSERVERPORT'} || 8020;
    my $sock = IO::Socket::INET->new("localhost:$port")
      or die "Couldn't connect to localhost:$port: $!";
    send ($sock,"GET Pod/Simple HTTP/1.0\15\12", 0x4);
    exit;
}

use Test;
BEGIN {plan tests => 8};

use Pod::Webserver;
ok 1;

my $ws = Pod::Webserver->new();
ok ($ws);
$ws->verbose(0);
$ws->httpd_timeout(10);
$ws->httpd_port($ENV{'PODWEBSERVERPORT'}) if ($ENV{'PODWEBSERVERPORT'});
$ws->prep_for_daemon;
my $daemon;
eval { $daemon = $ws->new_daemon; };
if ($@) {
    die $@ . "Try setting the PODWEBSERVERPORT environment variable to
              another port"; }

ok ($daemon);
my $sock = $daemon->{__sock};
#shutdown ($sock, 2);

# Create a dummy client in another process.
use Config;
my $perl = $Config{'perlpath'};
open(CLIENT, "$perl 03_daemon.t client |") or die "Can't exec client: $!";

# Accept a request from the dummy client.
my $conn = $daemon->accept;
ok ($conn);
my $req = $conn->get_request;
ok ($req);
ok ($req->url, 'Pod/Simple');
ok ($req->method, 'GET');
$conn->close;
close CLIENT;

# Test the response from the daemon.
my $testfile = 'dummysocket.txt';
open(DUMMY, ">$testfile");
$conn = Pod::Webserver::Connection->new(*DUMMY);
$ws->_serve_thing($conn, $req);
$conn->close;

my $captured_response;
{ 
    open(COMP, $testfile);
    local $/ = '';
    $captured_response = <COMP>;
    close COMP;
    unlink $testfile;
}
ok ($captured_response, qr/Pod::Simple/);

shutdown ($sock, 2);
exit;
