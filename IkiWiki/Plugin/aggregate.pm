#!/usr/bin/perl
# Blog aggregation plugin.
package IkiWiki::Plugin::aggregate;

use warnings;
use strict;
use IkiWiki;
use HTML::Entities;
use HTML::Parser;
use HTML::Tagset;
use URI;

my %feeds;
my %guids;

sub import { #{{{
	IkiWiki::hook(type => "getopt", id => "aggregate", 
		call => \&getopt);
	IkiWiki::hook(type => "checkconfig", id => "aggregate",
		call => \&checkconfig);
	IkiWiki::hook(type => "filter", id => "aggregate", 
		call => \&filter);
	IkiWiki::hook(type => "preprocess", id => "aggregate",
		call => \&preprocess);
        IkiWiki::hook(type => "delete", id => "aggregate",
                call => \&delete);
	IkiWiki::hook(type => "savestate", id => "aggregate",
		call => \&savestate);
} # }}}

sub getopt () { #{{{
        eval q{use Getopt::Long};
        Getopt::Long::Configure('pass_through');
        GetOptions("aggregate" => \$IkiWiki::config{aggregate});
} #}}}

sub checkconfig () { #{{{
	loadstate();
	if ($IkiWiki::config{aggregate}) {
		IkiWiki::loadindex();
		aggregate();
		savestate();
	}
} #}}}

sub filter (@) { #{{{
	my %params=@_;
	my $page=$params{page};

	# Mark all feeds originating on this page as removable;
	# preprocess will unmark those that still exist.
	remove_feeds($page);

	return $params{content};
} # }}}

sub preprocess (@) { #{{{
	my %params=@_;

	foreach my $required (qw{name url}) {
		if (! exists $params{$required}) {
			return "[[aggregate plugin missing $required parameter]]";
		}
	}

	my $feed={};
	my $name=$params{name};
	if (exists $feeds{$name}) {
		$feed=$feeds{$name};
	}
	else {
		$feeds{$name}=$feed;
	}
	$feed->{name}=$name;
	$feed->{sourcepage}=$params{page};
	$feed->{url}=$params{url};
	my $dir=exists $params{dir} ? $params{dir} : $params{page}."/".IkiWiki::titlepage($params{name});
	$dir=~s/^\/+//;
	($dir)=$dir=~/$IkiWiki::config{wiki_file_regexp}/;
	$feed->{dir}=$dir;
	$feed->{feedurl}=defined $params{feedurl} ? $params{feedurl} : "";
	$feed->{updateinterval}=defined $params{updateinterval} ? $params{updateinterval} * 60 : 15 * 60;
	$feed->{expireage}=defined $params{expireage} ? $params{expireage} : 0;
	$feed->{expirecount}=defined $params{expirecount} ? $params{expirecount} : 0;
	delete $feed->{remove};
	$feed->{lastupdate}=0 unless defined $feed->{lastupdate};
	$feed->{numposts}=0 unless defined $feed->{numposts};
	$feed->{newposts}=0 unless defined $feed->{newposts};
	$feed->{message}="new feed" unless defined $feed->{message};
	$feed->{tags}=[];
	while (@_) {
		my $key=shift;
		my $value=shift;
		if ($key eq 'tag') {
			push @{$feed->{tags}}, $value;
		}
	}

	return "<a href=\"".$feed->{url}."\">".$feed->{name}."</a>: ".
	       "<i>".$feed->{message}."</i> (".$feed->{numposts}.
	       " stored posts; ".$feed->{newposts}." new)";
} # }}}

sub delete (@) { #{{{
	my @files=@_;

	# Remove feed data for removed pages.
	foreach my $file (@files) {
		my $page=IkiWiki::pagename($file);
		remove_feeds($page);
	}
} #}}}

sub loadstate () { #{{{
	if (-e "$IkiWiki::config{wikistatedir}/aggregate") {
		open (IN, "$IkiWiki::config{wikistatedir}/aggregate" ||
			die "$IkiWiki::config{wikistatedir}/aggregate: $!");
		while (<IN>) {
			$_=IkiWiki::possibly_foolish_untaint($_);
			chomp;
			my $data={};
			foreach my $i (split(/ /, $_)) {
				my ($field, $val)=split(/=/, $i, 2);
				if ($field eq "name" || $field eq "feed" ||
				    $field eq "guid" || $field eq "message") {
					$data->{$field}=decode_entities($val, " \t\n");
				}
				elsif ($field eq "tag") {
					push @{$data->{tags}}, $val;
				}
				else {
					$data->{$field}=$val;
				}
			}
			
			if (exists $data->{name}) {
				$feeds{$data->{name}}=$data;
			}
			elsif (exists $data->{guid}) {
				$guids{$data->{guid}}=$data;
			}
		}

		close IN;
	}
} #}}}

sub savestate () { #{{{
	eval q{use HTML::Entities};
	die $@ if $@;
	open (OUT, ">$IkiWiki::config{wikistatedir}/aggregate" ||
		die "$IkiWiki::config{wikistatedir}/aggregate: $!");
	foreach my $data (values %feeds, values %guids) {
		if ($data->{remove}) {
			if ($data->{name}) {
				foreach my $guid (values %guids) {
					if ($guid->{feed} eq $data->{name}) {
						$guid->{remove}=1;
					}
				}
			}
			else {
				unlink pagefile($data->{page});
			}
			next;
		}

		my @line;
		foreach my $field (keys %$data) {
			if ($field eq "name" || $field eq "feed" ||
			    $field eq "guid" || $field eq "message") {
				push @line, "$field=".encode_entities($data->{$field}, " \t\n");
			}
			elsif ($field eq "tags") {
				push @line, "tag=$_" foreach @{$data->{tags}};
			}
			else {
				push @line, "$field=".$data->{$field};
			}
		}
		print OUT join(" ", @line)."\n";
	}
	close OUT;
} #}}}

sub aggregate () { #{{{
	eval q{use XML::Feed};
	die $@ if $@;
	eval q{use HTML::Entities};
	die $@ if $@;

	foreach my $feed (values %feeds) {
		next unless $IkiWiki::config{rebuild} || 
			time - $feed->{lastupdate} >= $feed->{updateinterval};
		$feed->{lastupdate}=time;
		$feed->{newposts}=0;
		$IkiWiki::forcerebuild{$feed->{sourcepage}}=1;

		IkiWiki::debug("checking feed ".$feed->{name}." ...");

		if (! length $feed->{feedurl}) {
			my @urls=XML::Feed->find_feeds($feed->{url});
			if (! @urls) {
				$feed->{message}="could not find feed at ".$feed->{feedurl};
				IkiWiki::debug($feed->{message});
				next;
			}
			$feed->{feedurl}=pop @urls;
		}
		my $f=eval{XML::Feed->parse(URI->new($feed->{feedurl}))};
		if ($@) {
			$feed->{message}="feed crashed XML::Feed! $@";
			IkiWiki::debug($feed->{message});
			next;
		}
		if (! $f) {
			$feed->{message}=XML::Feed->errstr;
			IkiWiki::debug($feed->{message});
			next;
		}

		foreach my $entry ($f->entries) {
			add_page(
				feed => $feed,
				title => defined $entry->title ? decode_entities($entry->title) : "untitled",
				link => $entry->link,
				content => $entry->content->body,
				guid => defined $entry->id ? $entry->id : time."_".$feed->name,
				ctime => $entry->issued ? ($entry->issued->epoch || time) : time,
			);
		}

		$feed->{message}="processed ok";
	}

	# TODO: expiry
} #}}}

sub add_page (@) { #{{{
	my %params=@_;
	
	my $feed=$params{feed};
	my $guid={};
	my $mtime;
	if (exists $guids{$params{guid}}) {
		# updating an existing post
		$guid=$guids{$params{guid}};
	}
	else {
		# new post
		$guid->{guid}=$params{guid};
		$guids{$params{guid}}=$guid;
		$mtime=$params{ctime};
		$feed->{numposts}++;
		$feed->{newposts}++;

		# assign it an unused page
		my $page=IkiWiki::titlepage($params{title});
		# escape slashes and periods in title so it doesn't specify
		# directory name or trigger ".." disallowing code.
		$page=~s!([/.])!"__".ord($1)."__"!eg;
		$page=$feed->{dir}."/".$page;
		$page=lc($page);
		($page)=$page=~/$IkiWiki::config{wiki_file_regexp}/;
		if (! defined $page || ! length $page) {
			$page=$feed->{dir}."/item";
		}
		my $c="";
		while (exists $IkiWiki::pagesources{$page.$c} ||
		       -e pagefile($page.$c)) {
			$c++
		}
		$guid->{page}=$page;
		IkiWiki::debug("creating new page $page");
	}
	$guid->{feed}=$feed->{name};
	
	# To write or not to write? Need to avoid writing unchanged pages
	# to avoid unneccessary rebuilding. The mtime from rss cannot be
	# trusted; let's use a digest.
	eval q{use Digest::MD5 'md5_hex'};
	require Encode;
	my $digest=md5_hex(Encode::encode_utf8($params{content}));
	return unless ! exists $guid->{md5} || $guid->{md5} ne $digest || $IkiWiki::config{rebuild};
	$guid->{md5}=$digest;

	# Create the page.
	my $template=IkiWiki::template("aggregatepost.tmpl", blind_cache => 1);
	$template->param(title => $params{title})
		if defined $params{title} && length($params{title});
	$template->param(content => htmlescape(htmlabs($params{content}, $feed->{feedurl})));
	$template->param(name => $feed->{name});
	$template->param(url => $feed->{url});
	$template->param(permalink => urlabs($params{link}, $feed->{feedurl}))
		if defined $params{link};
	if (ref $feed->{tags}) {
		$template->param(tags => [map { tag => $_ }, @{$feed->{tags}}]);
	}
	IkiWiki::writefile(IkiWiki::htmlpage($guid->{page}), $IkiWiki::config{srcdir},
		$template->output);

	# Set the mtime, this lets the build process get the right creation
	# time on record for the new page.
	utime $mtime, $mtime, pagefile($guid->{page}) if defined $mtime;
} #}}}

sub htmlescape ($) { #{{{
	# escape accidental wikilinks and preprocessor stuff
	my $html=shift;
	$html=~s/(?<!\\)\[\[/\\\[\[/g;
	return $html;
} #}}}

sub urlabs ($$) { #{{{
	my $url=shift;
	my $urlbase=shift;

	URI->new_abs($url, $urlbase)->as_string;
} #}}}

sub htmlabs ($$) { #{{{
	# Convert links in html from relative to absolute.
	# Note that this is a heuristic, which is not specified by the rss
	# spec and may not be right for all feeds. Also, see Debian
	# bug #XXXX TODO: get bug.
	my $html=shift;
	my $urlbase=shift;

	my $ret="";
	my $p = HTML::Parser->new(api_version => 3);
	$p->handler(default => sub { $ret.=join("", @_) }, "text");
	$p->handler(start => sub {
		my ($tagname, $pos, $text) = @_;
		if (ref $HTML::Tagset::linkElements{$tagname}) {
			while (4 <= @$pos) {
				# use attribute sets from right to left
				# to avoid invalidating the offsets
				# when replacing the values
				my($k_offset, $k_len, $v_offset, $v_len) =
					splice(@$pos, -4);
				my $attrname = lc(substr($text, $k_offset, $k_len));
				next unless grep { $_ eq $attrname } @{$HTML::Tagset::linkElements{$tagname}};
				next unless $v_offset; # 0 v_offset means no value
				my $v = substr($text, $v_offset, $v_len);
				$v =~ s/^([\'\"])(.*)\1$/$2/;
				my $new_v=urlabs($v, $urlbase);
				$new_v =~ s/\"/&quot;/g; # since we quote with ""
				substr($text, $v_offset, $v_len) = qq("$new_v");
			}
		}
		$ret.=$text;
	}, "tagname, tokenpos, text");
	$p->parse($html);
	$p->eof;

	return $ret;
} #}}}

sub remove_feeds () { #{{{
	my $page=shift;

	my %removed;
	foreach my $id (keys %feeds) {
		if ($feeds{$id}->{sourcepage} eq $page) {
			$feeds{$id}->{remove}=1;
			$removed{$id}=1;
		}
	}
} #}}}

sub pagefile ($) { #{{{
	my $page=shift;

	return "$IkiWiki::config{srcdir}/".IkiWiki::htmlpage($page);
} #}}}

1
