#!/usr/bin/perl -T
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use 5.10.1;
use strict;
use warnings;

# This sets up our libpath without having to specify it in the mod_perl
# configuration.
use File::Basename;
use File::Spec;
BEGIN {
    require lib;
    my $dir = dirname(__FILE__);
    lib->import($dir, File::Spec->catdir($dir, "lib"), File::Spec->catdir($dir, qw(local lib perl5)));
}

use Bugzilla::ModPerl::StartupFix;
use Bugzilla::ModPerl;

Bugzilla::ModPerl->startup();


1;
