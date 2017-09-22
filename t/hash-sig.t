# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.
use strict;
use warnings;
use 5.10.1;
use lib qw( . lib local/lib/perl5 );
use Bugzilla::Util qw(generate_random_password);
use Bugzilla::Token qw(issue_hash_sig check_hash_sig);
use Test::More;

use Class::Struct qw(struct);
struct('Fake::Bugzilla::User' => ['id' => '$']);
my $user = Fake::Bugzilla::User->new(id => 0);
my $localconfig = { site_wide_secret => generate_random_password(256) };
{
    package Bugzilla;
    sub localconfig { $localconfig }
    sub user { $user }
}

my $sig = issue_hash_sig("batman");
ok(check_hash_sig($sig, "batman"), "sig for batman checks out");



done_testing;