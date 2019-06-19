# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::CGI;

use 5.10.1;
use strict;
use warnings;

use Bugzilla::Logging;
use CGI;
use base qw(CGI);

use Bugzilla::CGI::ContentSecurityPolicy;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Util;
use Bugzilla::Search::Recent;

use File::Basename;
use URI;

BEGIN {
  if (ON_WINDOWS) {

    # Help CGI find the correct temp directory as the default list
    # isn't Windows friendly (Bug 248988)
    $ENV{'TMPDIR'} = $ENV{'TEMP'} || $ENV{'TMP'} || "$ENV{'WINDIR'}\\TEMP";
  }
  *AUTOLOAD = \&CGI::AUTOLOAD;
}

sub _init_bz_cgi_globals {
  my $invocant = shift;

  # We need to disable output buffering - see bug 179174
  $| = 1;

  # We don't precompile any functions here, that's done specially in
  # mod_perl code.
  $invocant->_setup_symbols(
    qw(:no_xhtml :oldstyle_urls :private_tempfiles
      :unique_headers)
  );
}

BEGIN { __PACKAGE__->_init_bz_cgi_globals() if i_am_cgi(); }

sub new {
  my ($invocant, @args) = @_;
  my $class = ref($invocant) || $invocant;

  # Under mod_perl, CGI's global variables get reset on each request,
  # so we need to set them up again every time.
  $class->_init_bz_cgi_globals();

  my $self = $class->SUPER::new(@args);

  # Make sure our outgoing cookie list is empty on each invocation
  $self->{Bugzilla_cookie_list} = [];

  # Path-Info is of no use for Bugzilla and interacts badly with IIS.
  # Moreover, it causes unexpected behaviors, such as totally breaking
  # the rendering of pages.
  my $script = basename($0);
  if (my $path = $self->path_info) {
    my @whitelist = ("rest.cgi");
    Bugzilla::Hook::process('path_info_whitelist', {whitelist => \@whitelist});
    if (!grep($_ eq $script, @whitelist)) {

      # apache collapses // to / in $ENV{PATH_INFO} but not in $self->path_info.
      # url() requires the full path in ENV in order to generate the correct url.
      $ENV{PATH_INFO} = $path;
      DEBUG("redirecting because we see PATH_INFO and don't like it");
      print $self->redirect($self->url(-path => 0, -query => 1));
      exit;
    }
  }

  # Send appropriate charset
  $self->charset(Bugzilla->params->{'utf8'} ? 'UTF-8' : '');

  # Redirect to urlbase if we are not viewing an attachment.
  if (my $C = $Bugzilla::App::CGI::C) {
    if ($C->url_is_attachment_base and $script ne 'attachment.cgi') {
      DEBUG(
        "Redirecting to urlbase because the url is in the attachment base and not attachment.cgi"
      );
      $self->redirect_to_urlbase();
    }
  }

  # Check for errors
  # All of the Bugzilla code wants to do this, so do it here instead of
  # in each script

  my $err = $self->cgi_error;

  if ($err) {

    # Note that this error block is only triggered by CGI.pm for malformed
    # multipart requests, and so should never happen unless there is a
    # browser bug.

    print $self->header(-status => $err);

    # ThrowCodeError wants to print the header, so it grabs Bugzilla->cgi
    # which creates a new Bugzilla::CGI object, which fails again, which
    # ends up here, and calls ThrowCodeError, and then recurses forever.
    # So don't use it.
    # In fact, we can't use templates at all, because we need a CGI object
    # to determine the template lang as well as the current url (from the
    # template)
    # Since this is an internal error which indicates a severe browser bug,
    # just die.
    die "CGI parsing error: $err";
  }

  return $self;
}

sub target_uri {
  my ($self) = @_;

  my $base = Bugzilla->localconfig->urlbase;
  if (my $request_uri = $self->request_uri) {
    my $base_uri = URI->new($base);
    $base_uri->path('');
    $base_uri->query(undef);
    return $base_uri . $request_uri;
  }
  else {
    return $base . ($self->url(-relative => 1, -query => 1) || 'index.cgi');
  }
}

# We want this sorted plus the ability to exclude certain params
sub canonicalise_query {
  my ($self, @exclude) = @_;

  # Reconstruct the URL by concatenating the sorted param=value pairs
  my @parameters;
  foreach my $key (sort($self->param())) {

    # Leave this key out if it's in the exclude list
    next if grep { $_ eq $key } @exclude;

    # Remove the Boolean Charts for standard query.cgi fields
    # They are listed in the query URL already
    next if $key =~ /^(field|type|value)(-\d+){3}$/;

    my $esc_key = url_quote($key);

    foreach my $value ($self->param($key)) {

      # Omit params with an empty value
      if (defined($value) && $value ne '') {
        my $esc_value = url_quote($value);

        push(@parameters, "$esc_key=$esc_value");
      }
    }
  }

  return join("&", @parameters);
}

sub clean_search_url {
  my $self = shift;

  # Delete any empty URL parameter.
  my @cgi_params = $self->param;

  foreach my $param (@cgi_params) {
    if (defined $self->param($param) && $self->param($param) eq '') {
      $self->delete($param);
      $self->delete("${param}_type");
    }

    # Custom Search stuff is empty if it's "noop". We also keep around
    # the old Boolean Chart syntax for backwards-compatibility.
    if ( ($param =~ /\d-\d-\d/ || $param =~ /^[[:alpha:]]\d+$/)
      && defined $self->param($param)
      && $self->param($param) eq 'noop')
    {
      $self->delete($param);
    }

    # Any "join" for custom search that's an AND can be removed, because
    # that's the default.
    if (($param =~ /^j\d+$/ || $param eq 'j_top') && $self->param($param) eq 'AND')
    {
      $self->delete($param);
    }
  }

  # Delete leftovers from the login form
  $self->delete('Bugzilla_remember', 'GoAheadAndLogIn');

  # Delete the token if we're not performing an action which needs it
  unless (
    (
      defined $self->param('remtype')
      && ( $self->param('remtype') eq 'asdefault'
        || $self->param('remtype') eq 'asnamed')
    )
    || (defined $self->param('remaction') && $self->param('remaction') eq 'forget')
    )
  {
    $self->delete("token");
  }

  foreach my $num (1, 2, 3) {

    # If there's no value in the email field, delete the related fields.
    if (!$self->param("email$num")) {
      foreach my $field (qw(type assigned_to reporter qa_contact cc longdesc)) {
        $self->delete("email$field$num");
      }
    }
  }

  # chfieldto is set to "Now" by default in query.cgi. But if none
  # of the other chfield parameters are set, it's meaningless.
  if ( !defined $self->param('chfieldfrom')
    && !$self->param('chfield')
    && !defined $self->param('chfieldvalue')
    && $self->param('chfieldto')
    && lc($self->param('chfieldto')) eq 'now')
  {
    $self->delete('chfieldto');
  }

  # cmdtype "doit" is the default from query.cgi, but it's only meaningful
  # if there's a remtype parameter.
  if ( defined $self->param('cmdtype')
    && $self->param('cmdtype') eq 'doit'
    && !defined $self->param('remtype'))
  {
    $self->delete('cmdtype');
  }

  # "Reuse same sort as last time" is actually the default, so we don't
  # need it in the URL.
  if ( $self->param('order')
    && $self->param('order') eq 'Reuse same sort as last time')
  {
    $self->delete('order');
  }

  # list_id is added in buglist.cgi after calling clean_search_url,
  # and doesn't need to be saved in saved searches.
  $self->delete('list_id');

  # And now finally, if query_format is our only parameter, that
  # really means we have no parameters, so we should delete query_format.
  if ($self->param('query_format') && scalar($self->param()) == 1) {
    $self->delete('query_format');
  }
}

sub check_etag {
  my ($self, $valid_etag) = @_;

  # ETag support.
  my $if_none_match = $self->http('If-None-Match');
  return if !$if_none_match;

  my @if_none = split(/[\s,]+/, $if_none_match);
  foreach my $possible_etag (@if_none) {

    # remove quotes from begin and end of the string
    $possible_etag =~ s/^\"//g;
    $possible_etag =~ s/\"$//g;
    if ($possible_etag eq $valid_etag or $possible_etag eq '*') {
      return 1;
    }
  }

  return 0;
}

our $ALLOW_UNSAFE_RESPONSE = 0;

# responding to text/plain or text/html is safe
# responding to any request with a referer header is safe
# some things need to have unsafe responses (attachment.cgi)
# everything else should get a 403.
sub _prevent_unsafe_response {
  my ($self, $headers) = @_;
  state $safe_content_type_re = qr{
        ^ (*COMMIT) # COMMIT makes the regex faster
                    # by preventing back-tracking. see also perldoc pelre.
        # application/x-javascript, xml, atom+xml, rdf+xml, xml-dtd, and json
        (?: application/ (?: x(?: -javascript | ml (?: -dtd )? )
                           | (?: atom | rdf) \+ xml
                           | json )
        # text/csv, text/calendar, text/plain, and text/html
          | text/ (?: c (?: alendar | sv )
                    | plain
                    | html )
        # used for HTTP push responses
          | multipart/x-mixed-replace)
    }sx;
  state $safe_referer_re = do {

    # Note that urlbase must end with a /.
    # It almost certainly does, but let's be extra careful.
    my $urlbase = Bugzilla->localconfig->urlbase;
    $urlbase =~ s{/$}{};
    qr{
            # Begins with literal urlbase
            ^ (*COMMIT)
            \Q$urlbase\E
            # followed by a slash or end of string
            (?: /
              | $ )
        }sx
  };

  return if $ALLOW_UNSAFE_RESPONSE;

  if (Bugzilla->usage_mode == USAGE_MODE_BROWSER) {

    # Safe content types are ones that arn't images.
    # For now let's assume plain text and html are not valid images.
    my $content_type = $headers->{'-type'} // $headers->{'-content_type'}
      // 'text/html';
    my $is_safe_content_type = $content_type =~ $safe_content_type_re;

    # Safe referers are ones that begin with the urlbase.
    my $referer = $self->referer;
    my $is_safe_referer = $referer && $referer =~ $safe_referer_re;

    if (!$is_safe_referer && !$is_safe_content_type) {
      print $self->SUPER::header(-type => 'text/html', -status => '403 Forbidden');
      if ($content_type ne 'text/html') {
        print "Untrusted Referer Header\n";
      }
      exit;
    }
  }
}

sub should_block_referrer {
  my ($self) = @_;
  return length($self->self_url) > 8000;
}

# Override header so we can add the cookies in
sub header {
  my $self = shift;

  my %headers;
  my $user = Bugzilla->user;

  # If there's only one parameter, then it's a Content-Type.
  if (scalar(@_) == 1) {
    %headers = ('-type' => shift(@_));
  }
  else {
    %headers = @_;
  }

  $self->_prevent_unsafe_response(\%headers);

  if ($self->{'_content_disp'}) {
    $headers{'-content_disposition'} = $self->{'_content_disp'};
  }

  if (!$user->id
    && $user->authorizer->can_login
    && !$self->cookie('Bugzilla_login_request_cookie'))
  {
    my %args;
    $args{'-secure'} = 1 if Bugzilla->params->{ssl_redirect};

    $self->send_cookie(
      -name     => 'Bugzilla_login_request_cookie',
      -value    => generate_random_password(),
      -httponly => 1,
      %args
    );
  }

  # We generate a cookie and store it in the request cache
  # To initiate github login, a form POSTs to github.cgi with the
  # github_secret as a parameter. It must match the github_secret cookie.
  # this prevents some types of redirection attacks.
  unless ($user->id || $self->{bz_redirecting}) {
    $self->send_cookie(
      -name     => 'github_secret',
      -value    => Bugzilla->github_secret,
      -httponly => 1
    );
  }

  # Add the cookies in if we have any
  if (scalar(@{$self->{Bugzilla_cookie_list}})) {
    $headers{'-cookie'} = $self->{Bugzilla_cookie_list};
  }

  if ($self->{'_content_disp'}) {
    $headers{'-content_disposition'} = $self->{'_content_disp'};
  }

  $self->{_header_done} = 1;

  if (Bugzilla->usage_mode == USAGE_MODE_BROWSER) {
    my @fonts = (
      "skins/standard/fonts/FiraMono-Regular.woff2?v=3.202",
      "skins/standard/fonts/FiraSans-Bold.woff2?v=4.203",
      "skins/standard/fonts/FiraSans-Italic.woff2?v=4.203",
      "skins/standard/fonts/FiraSans-Regular.woff2?v=4.203",
      "skins/standard/fonts/FiraSans-SemiBold.woff2?v=4.203",
      "skins/standard/fonts/MaterialIcons-Regular.woff2",
    );
    $headers{'-link'} = join(
      ", ",
      map {
        sprintf('</static/v%s/%s>; rel="preload"; as="font"', Bugzilla->VERSION, $_)
      } @fonts
    );
    if (Bugzilla->params->{google_analytics_tracking_id}) {
      $headers{'-link'}
        .= ', <https://www.google-analytics.com>; rel="preconnect"; crossorigin';
    }
  }
  my $headers = $self->SUPER::header(%headers) || '';
  if ($self->server_software eq 'Bugzilla::App::CGI') {
    my $c = $Bugzilla::App::CGI::C;
    $c->res->headers->parse($headers);
    my $status = $c->res->headers->status;
    if ($status && $status =~ /^([0-9]+)/) {
      $c->res->code($1);
    }
    elsif ($c->res->headers->location) {
      $c->res->code(302);
    }
    else {
      $c->res->code(200);
    }
    return '';
  }
  else {
    LOGDIE(
      "Bugzilla::CGI->header() should only be called from inside Bugzilla::App::CGI!"
    );
  }
}

sub param {
  my $self = shift;

  # We don't let CGI.pm warn about list context, but we do it ourselves.
  local $CGI::LIST_CONTEXT_WARN = 0;
  if (0) {
    state $has_warned = {};

    ## no critic (Freenode::Wantarray)
    if (wantarray && @_) {
      my ($package, $filename, $line) = caller;
      if ($package ne 'CGI' && !$has_warned->{"$filename:$line"}++) {
        WARN(
          "Bugzilla::CGI::param called in list context from $package $filename:$line");
      }
    }
    ## use critic
  }

  # When we are just requesting the value of a parameter...
  if (scalar(@_) == 1) {
    my @result = $self->SUPER::param(@_);

    # Also look at the URL parameters, after we look at the POST
    # parameters. This is to allow things like login-form submissions
    # with URL parameters in the form's "target" attribute.
    if ( !scalar(@result)
      && $self->request_method
      && $self->request_method eq 'POST')
    {
      # Some servers fail to set the QUERY_STRING parameter, which
      # causes undef issues
      $ENV{'QUERY_STRING'} = '' unless exists $ENV{'QUERY_STRING'};
      @result = $self->SUPER::url_param(@_);
    }

    # Fix UTF-8-ness of input parameters.
    if (Bugzilla->params->{'utf8'}) {
      @result = map { _fix_utf8($_) } @result;
    }

    return wantarray ? @result : $result[0];
  }

  # And for various other functions in CGI.pm, we need to correctly
  # return the URL parameters in addition to the POST parameters when
  # asked for the list of parameters.
  elsif (!scalar(@_) && $self->request_method && $self->request_method eq 'POST')
  {
    my @post_params = $self->SUPER::param;
    my @url_params  = $self->url_param;
    my %params      = map { $_ => 1 } (@post_params, @url_params);
    return keys %params;
  }

  return $self->SUPER::param(@_);
}

sub _fix_utf8 {
  my $input = shift;

  # The is_utf8 is here in case CGI gets smart about utf8 someday.
  utf8::decode($input) if defined $input && !ref $input && !utf8::is_utf8($input);
  return $input;
}

sub should_set {
  my ($self, $param) = @_;
  my $set
    = (defined $self->param($param) or defined $self->param("defined_$param"))
    ? 1
    : 0;
  return $set;
}

# The various parts of Bugzilla which create cookies don't want to have to
# pass them around to all of the callers. Instead, store them locally here,
# and then output as required from |header|.
sub send_cookie {
  my ($self, %paramhash) = @_;

  # Complain if -value is not given or empty (bug 268146).
  if (!exists($paramhash{'-value'}) || !$paramhash{'-value'}) {
    ThrowCodeError('cookies_need_value');
  }

  # Add the default path and the domain in.
  state $uri = URI->new(Bugzilla->localconfig->urlbase);
  $paramhash{'-path'} = $uri->path;

  # we don't set the domain.
  $paramhash{'-secure'} = 1 if lc($uri->scheme) eq 'https';

  $paramhash{'-samesite'} = 'Lax';

  push(@{$self->{'Bugzilla_cookie_list'}}, $self->cookie(%paramhash));
}

# Cookies are removed by setting an expiry date in the past.
# This method is a send_cookie wrapper doing exactly this.
sub remove_cookie {
  my $self = shift;
  my ($cookiename) = (@_);

  # Expire the cookie, giving a non-empty dummy value (bug 268146).
  $self->send_cookie(
    '-name'    => $cookiename,
    '-expires' => 'Tue, 15-Sep-1998 21:49:00 GMT',
    '-value'   => 'X'
  );
}

# To avoid infinite redirection recursion, track when we're within a redirect
# request.
sub redirect {
  my $self = shift;
  $self->{bz_redirecting} = 1;
  return $self->SUPER::redirect(@_);
}

use Bugzilla::Logging;

# This helps implement Bugzilla::Search::Recent, and also shortens search
# URLs that get POSTed to buglist.cgi.
sub redirect_search_url {
  my $self = shift;

  # If there is no parameter, there is nothing to do.
  return unless $self->param;

  # If we're retreiving an old list, we never need to redirect or
  # do anything related to Bugzilla::Search::Recent.
  return if $self->param('regetlastlist');

  my $user = Bugzilla->user;

  if ($user->id) {

    # There are two conditions that could happen here--we could get a URL
    # with no list id, and we could get a URL with a list_id that isn't
    # ours.
    my $list_id = $self->param('list_id');
    if ($list_id) {

      # If we have a valid list_id, no need to redirect or clean.
      return if Bugzilla::Search::Recent->check_quietly({id => $list_id});
    }
  }
  elsif ($self->request_method ne 'POST') {

    # Logged-out users who do a GET don't get a list_id, don't get
    # their URLs cleaned, and don't get redirected.
    return;
  }

  $self->clean_search_url();

  # Make sure we still have params still after cleaning otherwise we
  # do not want to store a list_id for an empty search.
  if ($user->id && $self->param) {

    # Insert a placeholder Bugzilla::Search::Recent, so that we know what
    # the id of the resulting search will be. This is then pulled out
    # of the Referer header when viewing show_bug.cgi to know what
    # bug list we came from.
    my $recent_search = Bugzilla::Search::Recent->create_placeholder;
    $self->param('list_id', $recent_search->id);
  }

  # GET requests that lacked a list_id are always redirected. POST requests
  # are only redirected if they're under the CGI_URI_LIMIT though.
  my $self_url = $self->self_url();
  if ($self->request_method() ne 'POST' or length($self_url) < CGI_URI_LIMIT) {
    DEBUG("Redirecting search url");
    print $self->redirect(-url => $self_url);
    exit;
  }
}

sub redirect_to_https {
  my $self    = shift;
  my $urlbase = Bugzilla->localconfig->urlbase;

  # If this is a POST, we don't want ?POSTDATA in the query string.
  # We expect the client to re-POST, which may be a violation of
  # the HTTP spec, but the only time we're expecting it often is
  # in the WebService, and WebService clients usually handle this
  # correctly.
  $self->delete('POSTDATA');
  my $url
    = $urlbase . $self->url('-path_info' => 1, '-query' => 1, '-relative' => 1);

  # XML-RPC clients (SOAP::Lite at least) require a 301 to redirect properly
  # and do not work with 302. Our redirect really is permanent anyhow, so
  # it doesn't hurt to make it a 301.
  DEBUG("Redirecting to https");
  print $self->redirect(-location => $url, -status => 301);
  exit;
}

# Redirect to the urlbase version of the current URL.
sub redirect_to_urlbase {
  my $self = shift;
  my $path = $self->url('-path_info' => 1, '-query' => 1, '-relative' => 1);
  print $self->redirect('-location' => Bugzilla->localconfig->urlbase . $path);
  exit;
}

sub base_redirect {
  my ($self, $path, $is_perm) = @_;
  print $self->redirect(
    -location => Bugzilla->localconfig->basepath . ($path || ''),
    -status   => $is_perm ? '301 Moved Permanently' : '302 Found'
  );
  exit;
}

sub set_dated_content_disp {
  my ($self, $type, $prefix, $ext) = @_;

  my @time = localtime(time());
  my $date = sprintf "%04d-%02d-%02d", 1900 + $time[5], $time[4] + 1, $time[3];
  my $filename = "$prefix-$date.$ext";

  $filename =~ s/\s/_/g;     # Remove whitespace to avoid HTTP header tampering
  $filename =~ s/\\/_/g;     # Remove backslashes as well
  $filename =~ s/"/\\"/g;    # escape quotes

  my $disposition = "$type; filename=\"$filename\"";

  $self->{'_content_disp'} = $disposition;
}

##########################
# Vars TIEHASH Interface #
##########################

# Fix the TIEHASH interface (scalar $cgi->Vars) to return and accept
# arrayrefs.
sub STORE {
  my $self = shift;
  my ($param, $value) = @_;
  if (defined $value and ref $value eq 'ARRAY') {
    return $self->param(-name => $param, -value => $value);
  }
  return $self->SUPER::STORE(@_);
}

sub FETCH {
  my ($self, $param) = @_;
  return $self if $param eq 'CGI';    # CGI.pm did this, so we do too.
  my @result = $self->param($param);
  return undef if !scalar(@result);
  return $result[0] if scalar(@result) == 1;
  return \@result;
}

# For the Vars TIEHASH interface: the normal CGI.pm DELETE doesn't return
# the value deleted, but Perl's "delete" expects that value.
sub DELETE {
  my ($self, $param) = @_;
  my $value = $self->FETCH($param);
  $self->delete($param);
  return $value;
}

1;

__END__

=head1 NAME

Bugzilla::CGI - CGI handling for Bugzilla

=head1 SYNOPSIS

  use Bugzilla::CGI;

  my $cgi = new Bugzilla::CGI();

=head1 DESCRIPTION

This package inherits from the standard CGI module, to provide additional
Bugzilla-specific functionality. In general, see L<the CGI.pm docs|CGI> for
documention.

=head1 CHANGES FROM L<CGI.PM|CGI>

Bugzilla::CGI has some differences from L<CGI.pm|CGI>.

=over 4

=item C<cgi_error> is automatically checked

After creating the CGI object, C<Bugzilla::CGI> automatically checks
I<cgi_error>, and throws a CodeError if a problem is detected.

=back

=head1 ADDITIONAL FUNCTIONS

I<Bugzilla::CGI> also includes additional functions.

=over 4

=item C<canonicalise_query(@exclude)>

This returns a sorted string of the parameters whose values are non-empty,
suitable for use in a url.

Values in C<@exclude> are not included in the result.

=item C<send_cookie>

This routine is identical to the cookie generation part of CGI.pm's C<cookie>
routine, except that it knows about Bugzilla's cookie_path and cookie_domain
parameters and takes them into account if necessary.
This should be used by all Bugzilla code (instead of C<cookie> or the C<-cookie>
argument to C<header>), so that under mod_perl the headers can be sent
correctly, using C<print> or the mod_perl APIs as appropriate.

To remove (expire) a cookie, use C<remove_cookie>.

=item C<remove_cookie>

This is a wrapper around send_cookie, setting an expiry date in the past,
effectively removing the cookie.

As its only argument, it takes the name of the cookie to expire.

=item C<redirect_to_https>

Generally you should use L<Bugzilla::Util/do_ssl_redirect_if_required>
instead of calling this directly.

=item C<redirect_to_urlbase>

Redirects from the current URL to one prefixed by the urlbase parameter.

=item C<base_redirect>

Redirects to the given path relative to the `basepath` parameter which is
typically the root (`/`).

=item C<set_dated_content_disp>

Sets an appropriate date-dependent value for the Content Disposition header
for a downloadable resource.

=back

=head1 SEE ALSO

L<CGI|CGI>, L<CGI::Cookie|CGI::Cookie>
