#!/usr/bin/perl

use warnings;
use strict;
use IkiWiki;
use Encode;
use open qw{:utf8 :std};

package IkiWiki;

my $sha1_pattern     = qr/[0-9a-fA-F]{40}/; # pattern to validate Git sha1sums
my $dummy_commit_msg = 'dummy commit';      # message to skip in recent changes

sub _safe_git (&@) { #{{{
	# Start a child process safely without resorting /bin/sh.
	# Return command output or success state (in scalar context).

	my ($error_handler, @cmdline) = @_;

	my $pid = open my $OUT, "-|";

	error("Cannot fork: $!") if !defined $pid;

	if (!$pid) {
		# In child.
		open STDERR, ">&STDOUT"
		    or error("Cannot dup STDOUT: $!");
		# Git commands want to be in wc.
		chdir $config{srcdir}
		    or error("Cannot chdir to $config{srcdir}: $!");
		exec @cmdline or error("Cannot exec '@cmdline': $!");
	}
	# In parent.

	my @lines;
	while (<$OUT>) {
		chomp;
		push @lines, $_;
	}

	close $OUT;

	($error_handler || sub { })->("'@cmdline' failed: $!") if $?;

	return wantarray ? @lines : ($? == 0);
}
# Convenient wrappers.
sub run_or_die ($@) { _safe_git(\&error, @_) }
sub run_or_cry ($@) { _safe_git(sub { warn @_ },  @_) }
sub run_or_non ($@) { _safe_git(undef,            @_) }
#}}}

sub _merge_past ($$$) { #{{{
	# Unlike with Subversion, Git cannot make a 'svn merge -rN:M file'.
	# Git merge commands work with the committed changes, except in the
	# implicit case of '-m' of git-checkout(1).  So we should invent a
	# kludge here.  In principle, we need to create a throw-away branch
	# in preparing for the merge itself.  Since branches are cheap (and
	# branching is fast), this shouldn't cost high.
	#
	# The main problem is the presence of _uncommitted_ local changes.  One
	# possible approach to get rid of this situation could be that we first
	# make a temporary commit in the master branch and later restore the
	# initial state (this is possible since Git has the ability to undo a
	# commit, i.e. 'git-reset --soft HEAD^').  The method can be summarized
	# as follows:
	#
	# 	- create a diff of HEAD:current-sha1
	# 	- dummy commit
	# 	- create a dummy branch and switch to it
	# 	- rewind to past (reset --hard to the current-sha1)
	# 	- apply the diff and commit
	# 	- switch to master and do the merge with the dummy branch
	# 	- make a soft reset (undo the last commit of master)
	#
	# The above method has some drawbacks: (1) it needs a redundant commit
	# just to get rid of local changes, (2) somewhat slow because of the
	# required system forks.  Until someone points a more straight method
	# (which I would be grateful) I have implemented an alternative method.
	# In this approach, we hide all the modified files from Git by renaming
	# them (using the 'rename' builtin) and later restore those files in
	# the throw-away branch (that is, we put the files themselves instead
	# of applying a patch).

	my ($sha1, $file, $message) = @_;

	my @undo;      # undo stack for cleanup in case of an error
	my $conflict;  # file content with conflict markers

	eval {
		# Hide local changes from Git by renaming the modified file.
		# Relative paths must be converted to absolute for renaming.
		my ($target, $hidden) = (
		    "$config{srcdir}/${file}", "$config{srcdir}/${file}.${sha1}"
		);
		rename($target, $hidden)
		    or error("rename '$target' to '$hidden' failed: $!");
		# Ensure to restore the renamed file on error.
		push @undo, sub {
			return if ! -e "$hidden"; # already renamed
			rename($hidden, $target)
			    or warn "rename '$hidden' to '$target' failed: $!";
		};

		my $branch = "throw_away_${sha1}"; # supposed to be unique

		# Create a throw-away branch and rewind backward.
		push @undo, sub { run_or_cry('git-branch', '-D', $branch) };
		run_or_die('git-branch', $branch, $sha1);

		# Switch to throw-away branch for the merge operation.
		push @undo, sub {
			if (!run_or_cry('git-checkout', $config{gitmaster_branch})) {
				run_or_cry('git-checkout','-f',$config{gitmaster_branch});
			}
		};
		run_or_die('git-checkout', $branch);

		# Put the modified file in _this_ branch.
		rename($hidden, $target)
		    or error("rename '$hidden' to '$target' failed: $!");

		# _Silently_ commit all modifications in the current branch.
		run_or_non('git-commit', '-m', $message, '-a');
		# ... and re-switch to master.
		run_or_die('git-checkout', $config{gitmaster_branch});

		# Attempt to merge without complaining.
		if (!run_or_non('git-pull', '--no-commit', '.', $branch)) {
			$conflict = readfile($target);
			run_or_die('git-reset', '--hard');
		}
	};
	my $failure = $@;

	# Process undo stack (in reverse order).  By policy cleanup
	# actions should normally print a warning on failure.
	while (my $handle = pop @undo) {
		$handle->();
	}

	error("Git merge failed!\n$failure\n") if $failure;

	return $conflict;
} #}}}

sub _parse_diff_tree ($@) { #{{{
	# Parse the raw diff tree chunk and return the info hash.
	# See git-diff-tree(1) for the syntax.

	my ($prefix, $dt_ref) = @_;

	# End of stream?
	return if !defined @{ $dt_ref } ||
		  !defined @{ $dt_ref }[0] || !length @{ $dt_ref }[0];

	my %ci;
	# Header line.
	while (my $line = shift @{ $dt_ref }) {
		return if $line !~ m/^(.+) ($sha1_pattern)/;

		my $sha1 = $2;
		$ci{'sha1'} = $sha1;
		last;
	}

	# Identification lines for the commit.
	while (my $line = shift @{ $dt_ref }) {
		# Regexps are semi-stolen from gitweb.cgi.
		if ($line =~ m/^tree ([0-9a-fA-F]{40})$/) {
			$ci{'tree'} = $1;
		}
		elsif ($line =~ m/^parent ([0-9a-fA-F]{40})$/) {
			# XXX: collecting in reverse order
			push @{ $ci{'parents'} }, $1;
		}
		elsif ($line =~ m/^(author|committer) (.*) ([0-9]+) (.*)$/) {
			my ($who, $name, $epoch, $tz) =
			   ($1,   $2,    $3,     $4 );

			$ci{  $who          } = $name;
			$ci{ "${who}_epoch" } = $epoch;
			$ci{ "${who}_tz"    } = $tz;

			if ($name =~ m/^([^<]+) <([^@]+)/) {
				my ($fullname, $username) = ($1, $2);
				$ci{"${who}_fullname"}    = $fullname;
				$ci{"${who}_username"}    = $username;
			}
			else {
				$ci{"${who}_fullname"} =
					$ci{"${who}_username"} = $name;
			}
		}
		elsif ($line =~ m/^$/) {
			# Trailing empty line signals next section.
			last;
		}
	}

	debug("No 'tree' or 'parents' seen in diff-tree output")
	    if !defined $ci{'tree'} || !defined $ci{'parents'};

	$ci{'parent'} = @{ $ci{'parents'} }[0] if defined $ci{'parents'};

	# Commit message.
	while (my $line = shift @{ $dt_ref }) {
		if ($line =~ m/^$/) {
			# Trailing empty line signals next section.
			last;
		};
		$line =~ s/^    //;
		push @{ $ci{'comment'} }, $line;
	}

	# Modified files.
	while (my $line = shift @{ $dt_ref }) {
		if ($line =~ m{^:
			([0-7]{6})[ ]      # from mode
			([0-7]{6})[ ]      # to mode
			($sha1_pattern)[ ] # from sha1
			($sha1_pattern)[ ] # to sha1
			(.)                # status
			([0-9]{0,3})\t     # similarity
			(.*)               # file
		$}xo) {
			my ($sha1_from, $sha1_to, $file) =
			   ($3,         $4,       $7   );

			if ($file =~ m/^"(.*)"$/) {
				($file=$1) =~ s/\\([0-7]{1,3})/chr(oct($1))/eg;
			}
			$file =~ s/^\Q$prefix\E//;
			if (length $file) {
				push @{ $ci{'details'} }, {
					'file'      => decode_utf8($file),
					'sha1_from' => $sha1_from,
					'sha1_to'   => $sha1_to,
				};
			}
			next;
		};
		last;
	}

	debug("No detail in diff-tree output") if !defined $ci{'details'};

	return \%ci;
} #}}}

sub git_commit_info ($;$) { #{{{
	# Return an array of commit info hashes of num commits (default: 1)
	# starting from the given sha1sum.

	my ($sha1, $num) = @_;

	$num ||= 1;

	my @raw_lines =
	    run_or_die('git-log', "--max-count=$num", '--pretty=raw', '--raw', '--abbrev=40', '--always', '-m', '-r', $sha1, '--', '.');
	my ($prefix) = run_or_die('git-rev-parse', '--show-prefix');

	my @ci;
	while (my $parsed = _parse_diff_tree(($prefix or ""), \@raw_lines)) {
		push @ci, $parsed;
	}

	warn "Cannot parse commit info for '$sha1' commit" if !@ci;

	return wantarray ? @ci : $ci[0];
} #}}}

sub git_sha1 (;$) { #{{{
	# Return head sha1sum (of given file).

	my $file = shift || q{--};

	# Ignore error since a non-existing file might be given.
	my ($sha1) = run_or_non('git-rev-list', '--max-count=1', 'HEAD', $file);
	if ($sha1) {
		($sha1) = $sha1 =~ m/($sha1_pattern)/; # sha1 is untainted now
	} else { debug("Empty sha1sum for '$file'.") }
	return defined $sha1 ? $sha1 : q{};
} #}}}

sub rcs_update () { #{{{
	# Update working directory.

	run_or_cry('git-pull', $config{gitorigin_branch});
} #}}}

sub rcs_prepedit ($) { #{{{
	# Return the commit sha1sum of the file when editing begins.
	# This will be later used in rcs_commit if a merge is required.

	my ($file) = @_;

	return git_sha1($file);
} #}}}

sub rcs_commit ($$$;$$) { #{{{
	# Try to commit the page; returns undef on _success_ and
	# a version of the page with the rcs's conflict markers on
	# failure.

	my ($file, $message, $rcstoken, $user, $ipaddr) = @_;

	if (defined $user) {
		$message = "web commit by $user" .
		    (length $message ? ": $message" : "");
	}
	elsif (defined $ipaddr) {
		$message = "web commit from $ipaddr" .
		    (length $message ? ": $message" : "");
	}

	# XXX: Wiki directory is in the unlocked state when starting this
	# action.  But it takes time for a Git process to finish its job
	# (especially if a merge required), so we must re-lock to prevent
	# race conditions.  Only when the time of the real commit action
	# (i.e. git-push(1)) comes, we'll unlock the directory.
	lockwiki();

	# Check to see if the page has been changed by someone else since
	# rcs_prepedit was called.
	my $cur    = git_sha1($file);
	my ($prev) = $rcstoken =~ /^($sha1_pattern)$/; # untaint

	if (defined $cur && defined $prev && $cur ne $prev) {
		my $conflict = _merge_past($prev, $file, $dummy_commit_msg);
		return $conflict if defined $conflict;
	}

	# git-commit(1) returns non-zero if file has not been really changed.
	# so we should ignore its exit status (hence run_or_non).
	$message = possibly_foolish_untaint($message);
	if (run_or_non('git-commit', '-m', $message, '-i', $file)) {
		unlockwiki();
		run_or_cry('git-push', $config{gitorigin_branch});
	}

	return undef; # success
} #}}}

sub rcs_add ($) { # {{{
	# Add file to archive.

	my ($file) = @_;

	run_or_cry('git-add', $file);
} #}}}

sub rcs_recentchanges ($) { #{{{
	# List of recent changes.

	my ($num) = @_;

	eval q{use Date::Parse};
	error($@) if $@;

	my @rets;
	foreach my $ci (git_commit_info('HEAD', $num)) {
		my $title = @{ $ci->{'comment'} }[0];

		# Skip redundant commits.
		next if ($title eq $dummy_commit_msg);

		my ($sha1, $when) = (
			$ci->{'sha1'},
			time - $ci->{'author_epoch'}
		);

		my (@pages, @messages);
		foreach my $detail (@{ $ci->{'details'} }) {
			my $diffurl = $config{'diffurl'};
			my $file    = $detail->{'file'};

			$diffurl =~ s/\[\[file\]\]/$file/go;
			$diffurl =~ s/\[\[sha1_parent\]\]/$ci->{'parent'}/go;
			$diffurl =~ s/\[\[sha1_from\]\]/$detail->{'sha1_from'}/go;
			$diffurl =~ s/\[\[sha1_to\]\]/$detail->{'sha1_to'}/go;

			push @pages, {
				page => pagename($file),
				diffurl => $diffurl,
			};
		}
		push @messages, { line => $title };

		my ($user, $type) = (q{}, "web");

		if (defined $messages[0] &&
		    $messages[0]->{line} =~ m/$config{web_commit_regexp}/) {
			$user = defined $2 ? "$2" : "$3";
			$messages[0]->{line} = $4;
		}
		else {
			$type ="git";
			$user = $ci->{'author_username'};
		}

		push @rets, {
			rev        => $sha1,
			user       => $user,
			committype => $type,
			when       => $when,
			message    => [@messages],
			pages      => [@pages],
		};

		last if @rets >= $num;
	}

	return @rets;
} #}}}

sub rcs_notify () { #{{{
	# Send notification mail to subscribed users.
	#
	# In usual Git usage, hooks/update script is presumed to send
	# notification mails (see git-receive-pack(1)).  But we prefer
	# hooks/post-update to support IkiWiki commits coming from a
	# cloned repository (through command line) because post-update
	# is called _after_ each ref in repository is updated (update
	# hook is called _before_ the repository is updated).  Since
	# post-update hook does not accept command line arguments, we
	# don't have an $ENV variable in this function.
	#
	# Here, we rely on a simple fact: we can extract all parts of the
	# notification content by parsing the "HEAD" commit (which also
	# triggers a refresh of IkiWiki pages) and we can obtain the diff
	# by comparing HEAD and HEAD^ (the previous commit).

	my $sha1 = 'HEAD'; # the commit which triggers this action

	my $ci = git_commit_info($sha1);
	return if !defined $ci;

	my @changed_pages = map { $_->{'file'} } @{ $ci->{'details'} };

	my ($user, $message);
	if (@{ $ci->{'comment'} }[0] =~ m/$config{web_commit_regexp}/) {
		$user    = defined $2 ? "$2" : "$3";
		$message = $4;
	}
	else {
		$user    = $ci->{'author_username'};
		$message = join "\n", @{ $ci->{'comment'} };
	}

	require IkiWiki::UserInfo;
	send_commit_mails(
		sub {
			$message;
		},
		sub {
			join "\n", run_or_die('git-diff', "${sha1}^", $sha1);
		}, $user, @changed_pages
	);
} #}}}

sub rcs_getctime ($) { #{{{
	# Get the ctime of file.

	my ($file) = @_;

	my $sha1  = git_sha1($file);
	my $ci    = git_commit_info($sha1);
	my $ctime = $ci->{'author_epoch'};
	debug("ctime for '$file': ". localtime($ctime) . "\n");

	return $ctime;
} #}}}

1
