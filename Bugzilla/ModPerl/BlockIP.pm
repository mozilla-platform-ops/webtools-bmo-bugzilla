package Bugzilla::ModPerl::BlockIP;
use strict;
use warnings;

use Apache2::RequestRec ();
use Apache2::Connection ();

use Apache2::Const -compile => qw(OK);
use Cache::Memcached::Fast;

use constant BLOCK_TIMEOUT => 60*60;

my $MEMCACHED = Bugzilla::Memcached->_new()->{memcached};
my $STATIC_URI = qr{
    ^/
     (?: extensions/[^/]+/web
       | robots\.txt
       | __heartbeat__
       | __lbheartbeat__
       | __version__
       | images
       | skins
       | js
       | errors
     )
}xs;

sub block_ip {
    my ($class, $ip) = @_;
    $MEMCACHED->set("block_ip:$ip" => 1, BLOCK_TIMEOUT) if $MEMCACHED;
}

sub unblock_ip {
    my ($class, $ip) = @_;
    $MEMCACHED->delete("block_ip:$ip") if $MEMCACHED;
}

sub handler {
    my $r = shift;
    return Apache2::Const::OK if $r->uri =~ $STATIC_URI;

    my $ip = $r->headers_in->{'X-Forwarded-For'} // $r->connection->remote_ip;

    if ($MEMCACHED && $MEMCACHED->get("block_ip:$ip")) {
        __PACKAGE__->block_ip($ip);
        $r->status_line("429 Too Many Requests");
        $r->custom_response(500, "Too Many Requests");
        return 429;
    }
    else {
        return Apache2::Const::OK;
    }
}

1;
