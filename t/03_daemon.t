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
use IO::Socket;

# When run with the single argument 'client', the test script should run
# a dummy client and exit.
my $mode = shift || '';
if ($mode eq 'client') {
    my $port = $ENV{'PODWEBSERVERPORT'} || 8020;
    my $hostname = 'localhost';
#    my $url = "http://$hostname:$port/";
    my $host = inet_aton($hostname)
      or die "Can't resolve hostname '$hostname'";
    my $sin = sockaddr_in($port, $host);

    my $proto   = getprotobyname('tcp');
    socket(SOCK, PF_INET, SOCK_STREAM, $proto)
      or die "Can't create socket: $!";
    connect(SOCK, $sin)
      or die "Couldn't connect to $hostname:$port: $!";
    send (SOCK,"GET Pod/Simple HTTP/1.0\15\12", 0x4);
    exit;
}

use Test;
BEGIN {plan tests => 7};

use Pod::Webserver;
ok 1;

my $ws = Pod::Webserver->new();
ok ($ws);
#$ws->verbose(0);
$ws->httpd_timeout(20);
$ws->httpd_port($ENV{'PODWEBSERVERPORT'}) if ($ENV{'PODWEBSERVERPORT'});
$ws->prep_for_daemon;
my $daemon = $ws->new_daemon;
ok ($daemon);

my $url = $daemon->url;
my $sock = $daemon->{__sock};
#shutdown ($sock, 2);
#exit;

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
my $conn = Mock::HTTP::Connection->new(*DUMMY);
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
#shutdown ($sock, 2);

exit;

__END__

# Test mock connection object sending errors.
open(DUMMY, ">$testfile");
$conn = Mock::HTTP::Connection->new(*DUMMY);
$conn->send_error('404');
$conn->close;

my $captured_error;
{ 
    open(COMP, $testfile);
    local $/ = '';
    $captured_error = <COMP>;
    close COMP;
    unlink $testfile;
}
$compare = "HTTP\/1.0 404 HTTP error code 404
Date: .* GMT
Content-Type: text\/plain

Something went wrong, generating code 404.";
$compare =~ s/\n/\15\12/gs;
ok ($captured_error, qr/$compare/);

# Test mock connection object retrieving requests.
open(DUMMY, "+>$testfile");
print DUMMY "GET http://www.cpan.org/index.html HTTP/1.0\15\12";
close DUMMY;
open(DUMMY, "$testfile");
$conn = Mock::HTTP::Connection->new(*DUMMY);
$req = $conn->get_request;
if ($req) {
    ok ($req->method, 'GET');
    ok ($req->url, 'http://www.cpan.org/index.html');
} else {
    ok 0;
    ok 0;
}

$conn->close;
unlink $testfile;

exit;
