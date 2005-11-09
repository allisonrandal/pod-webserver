# Time-stamp: "2004-05-25 19:06:13 ADT"
require 5;
use 5.004; # sane minimum, I think
use strict;
use warnings;

use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
 'dist'      => { COMPRESS => 'gzip -6f', SUFFIX => 'gz', },

 'NAME'	=> 'Pod::Webserver',
 'VERSION_FROM' => 'lib/Pod/Webserver.pm', # finds $VERSION
 'ABSTRACT'  => 'a miniature web server for reading Pod in web browsers',
 'EXE_FILES' => [qw( podwebserver )],

 'PREREQ_PM' => {
   'Pod::Simple' => 3.01,

   # And finally, things I don't have any particular version in mind for:
   map {; $_ => 0 } qw[
    strict vars Pod::Simple::Progress Pod::Simple::HTMLBatch
    Pod::Simple::HTML Carp IO::Socket HTTP::Date HTTP::Daemon HTTP::Response
    HTTP::Request File::Spec::Unix
   ]
 }
);

package MY;

sub libscan
{ # Determine things that should *not* be installed
    my($self, $path) = @_;
    return '' if $path =~ m/~/;
    $path;
}

__END__
