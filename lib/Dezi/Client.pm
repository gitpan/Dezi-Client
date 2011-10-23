package Dezi::Client;

use warnings;
use strict;

our $VERSION = '0.001001';

use Carp;
use LWP::UserAgent;
use HTTP::Request;
use URI::Query;
use SWISH::Prog::Utils;    # for MIME types
use JSON;
use File::Slurp;
use Dezi::Response;

# default is to treat everything like html,
# but we want to treat everything like text unless
# it has an explicit extension.
# TODO use libmagic or something better than
# SWISH::Prog::Utils + MIME::Types
$SWISH::Prog::Utils::DefaultExtension = 'txt';

=head1 NAME

Dezi::Client - interact with a Dezi server

=head1 SYNOPSIS

 use Dezi::Client;
 
 # open a connection
 my $client = Dezi::Client->new(
    server  => 'http://localhost:5000',
 );
 
 # add/update a filesystem document to the index
 $client->index( 'path/to/file.html' );
 
 # add/update an in-memory document to the index
 $client->index( \$html_doc, 'foo/bar.html' );
 
 # add/update a Dezi::Doc to the index
 $client->index( $dezi_doc );
 
 # remove a document from the index
 $client->delete( '/doc/uri/relative/to/index' );
 
 # search the index
 my $response = $client->search( q => 'foo' );
 
 # iterate over results
 for my $result (@{ $response->results }) {
     printf("--\n uri: %s\n title: %s\n score: %s\n",
        $result->uri, $result->title, $result->score);
 }
 
 # print stats
 printf("       hits: %d\n", $response->total);
 printf("search time: %s\n", $response->search_time);
 printf(" build time: %s\n", $response->build_time);
 printf("      query: %s\n", $response->query);
 
 
=head1 DESCRIPTION

Dezi::Client is a client for the Dezi search platform.

=head1 METHODS

=head2 new( I<params> )

Instantiate a Client instance. Expects the following params:

=over

=item server I<url>

The I<url> of the Dezi server. If the B<search> or B<index>
params are not passed to new(), then the server will be
interrogated at initial connect for the correct paths
for searching and indexing.

=item search I<path>

The URI path for searching. Dezi defaults to B</search>.

=item index I<path>

The URI path for indexing. Dezi defaults to B</index>.

=back

=cut

sub new {
    my $class = shift;
    my %args  = @_;
    if ( !%args or !exists $args{server} ) {
        croak "server param required";
    }
    my $self = bless { server => delete $args{server} }, $class;

    $self->{debug} = delete $args{debug} || 0;
    if ( $self->{debug} ) {
        require Data::Dump;
    }

    $self->{ua} = LWP::UserAgent->new();
    if ( $args{search} and $args{index} ) {
        $self->{search_uri} = $self->{server} . delete $args{search};
        $self->{index_uri}  = $self->{server} . delete $args{index};
    }
    else {
        my $resp = $self->{ua}->get( $self->{server} );
        if ( !$resp->is_success ) {
            croak $resp->status_line;
        }
        my $paths = from_json( $resp->decoded_content );
        if (   !$resp->is_success
            or !$paths
            or !$paths->{search}
            or !$paths->{index} )
        {
            croak "Bad response from server $self->{server}: "
                . $resp->status_line . " "
                . $resp->decoded_content;
        }
        $self->{search_uri} = $paths->{search};
        $self->{index_uri}  = $paths->{index};
        $self->{fields}     = $paths->{fields};
        $self->{facets}     = $paths->{facets};
    }

    if (%args) {
        croak "Invalid params to new(): " . join( ", ", keys %args );
    }

    return $self;
}

=head2 index( I<doc> [, I<uri>, I<content-type>] )

Add or update a document. I<doc> should be one of:

=over

=item I<path>

I<path> should be a readable file on an accessible filesystem.
I<path> will be read with File::Slurp.

=item I<scalar_ref>

I<scalar_ref> should be a reference to a string representing
the document to be indexed. If this is the case, then I<uri>
must be passed as the second argument.

=item I<dezi_doc>

A Dezi::Doc object.

=back

I<uri> and I<content-type> are optional, except in the
I<scalar_ref> case, where I<uri> is required. If specified,
the values are passed explicitly in the HTTP headers to the Dezi
server. If not specified, they are (hopefully intelligently) guessed at.

Returns a HTTP::Response object which can be interrogated to
determine the result. Example:

 my $resp = $client->index( file => 'path/to/foo.html' );
 if (!$resp->is_success) {
    die "Failed to add path/to/foo.html to the Dezi index!";
 }

=cut

sub index {
    my $self         = shift;
    my $doc          = shift or croak "doc required";
    my $uri          = shift;                           # optional
    my $content_type = shift;                           # optional

    my $body_ref;

    if ( !ref $doc ) {
        my $buf = read_file($doc);
        if ( !defined $buf ) {
            croak "unable to read $doc: $!";
        }
        $body_ref = \$buf;
        $uri ||= $doc;
    }
    elsif ( ref $doc eq 'SCALAR' ) {
        if ( !defined $uri and !length $uri ) {
            croak "uri required when passing scalar ref";
        }
        $body_ref = $doc;
    }
    elsif ( ref $doc and $doc->isa('Dezi::Doc') ) {
        $body_ref = $doc->as_string_ref;
        $uri          ||= $doc->uri;
        $content_type ||= $doc->mime_type;
    }
    else {
        croak "doc must be a scalar string, scalar ref or Dezi::Doc object";
    }

    my $server_uri = $self->{index_uri} . '/' . $uri;
    my $req = HTTP::Request->new( 'POST', $server_uri );
    $content_type ||= SWISH::Prog::Utils->mime_type($uri);
    $req->header( 'Content-Type' => $content_type );
    $req->content($$body_ref);    # TODO decode into bytes

    $self->{debug} and Data::Dump::dump $req;

    return $self->{ua}->request($req);

}

=head2 search( I<params> )

Fetch search results from a Dezi server. I<params> can be
any key/value pair as described in Search::OpenSearch. The only
required key is B<q> for the query string.

Returns a Dezi::Response object on success, or 0 on failure. Check
the last_response() accessor for the raw HTTP::Response object.

 my $resp = $client->search('q' => 'foo')
    or die "search failed: " . $client->last_response->status_line;

=cut

sub search {
    my $self = shift;
    my %args = @_;
    if ( !exists $args{q} ) {
        croak "q required";
    }
    my $search_uri = $self->{search_uri};
    my $query      = URI::Query->new(%args);
    $query->replace( t => 'json' );    # force json response
    $query->strip('format');           # old-style name
    my $resp = $self->{ua}->get( $search_uri . '?' . $query );
    if ( !$resp->is_success ) {
        $self->{last_response} = $resp;
        return 0;
    }
    $self->{debug} and Data::Dump::dump $resp;
    return Dezi::Response->new($resp);
}

=head2 last_response

Returns the last HTTP::Response object that the Client object
interacted with. Useful when search() returns false (HTTP failure).
Example:

 my $resp = $client->search( q => 'foo' );
 if (!$resp) {
     die "Dezi search failed: " . $client->last_response->status_line;
 }

=cut

sub last_response {
    return shift->{last_response};
}

=head2 delete( I<uri> )

Remove a document from the server. I<uri> must be the document's URI.

=cut

sub delete {
    my $self = shift;
    my $uri = shift or croak "uri required";

    my $server_uri = $self->{index_uri} . '/' . $uri;
    my $req = HTTP::Request->new( 'DELETE', $server_uri );
    $self->{debug} and Data::Dump::dump $req;
    return $self->{ua}->request($req);
}

1;

__END__

=head1 AUTHOR

Peter Karman, C<< <karman at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-dezi-client at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Dezi-Client>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Dezi::Client


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Dezi-Client>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Dezi-Client>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Dezi-Client>

=item * Search CPAN

L<http://search.cpan.org/dist/Dezi-Client/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 COPYRIGHT & LICENSE

Copyright 2011 Peter Karman.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut
