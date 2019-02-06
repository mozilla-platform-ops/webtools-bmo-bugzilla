# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Cannon::Ping;
use 5.10.1;
use Moo::Role;

use Type::Utils qw(class_type);
use Bugzilla::Types qw(URL);
use Types::Standard qw(Str Num);
use Scalar::Util qw(blessed);
use JSON::Validator;
use Mojo::Promise;

has 'model' => (is => 'ro', isa => class_type({class => 'Bugzilla::Model'}));

has '_base_url' => (
  is       => 'ro',
  init_arg => 'base_url',
  required => 1,
  isa      => URL,
  coerce   => 1,
  handles  => {base_url => 'clone'}
);

has 'user_agent' => (
  is       => 'lazy',
  init_arg => undef,
  isa      => class_type({class => 'Mojo::UserAgent'})
);

sub _build_user_agent {
  return Mojo::UserAgent->new;
}

has 'validator' => (
  is       => 'lazy',
  init_arg => undef,
  isa      => class_type({class => 'JSON::Validator'}),
  handles  => ['validate'],
);

requires '_build_validator';

has 'resultset' => (
  is       => 'lazy',
  init_arg => undef,
  isa      => class_type({class => 'DBIx::Class::ResultSet'})
);

requires '_build_resultset';

has 'namespace' => (is => 'lazy', init_arg => undef, isa => Str);

sub _build_namespace {
  return 'bugzilla';
}


has 'doctype' => (is => 'lazy', init_arg => undef, isa => Str);

sub _build_doctype {
  my ($self) = @_;
  my @class_parts = split(/::/, blessed $self);
  return lc $class_parts[-1];
}

has 'docversion' => (is => 'lazy', init_arg => undef, isa => Num);

sub _build_docversion {
  my ($self) = @_;
  return $self->VERSION;
}

sub send {
  my ($self, $id, $payload) = @_;
  my $url = $self->base_url;
  push @{$url->path}, $self->namespace, $self->doctype, $self->docversion, $id;
  return $self->user_agent->put_p($url, json => $payload);
}

1;
