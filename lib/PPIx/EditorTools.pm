package PPIx::EditorTools;

use 5.008;
use strict;
use warnings;
use Carp;
use Class::XSAccessor 1.02 constructor => 'new', accessors => {
	'code' => 'code',
	'ppi'  => 'ppi',
};

use PPI 1.203;
use PPIx::EditorTools::ReturnObject;

our $VERSION = '0.15_02';

=pod

=head1 NAME

PPIx::EditorTools - Utility methods and base class for manipulating Perl via PPI

=head1 SYNOPSIS

    See PPIx::EditorTools::*

=head1 DESCRIPTION

Base class and utility methods for manipulating Perl via PPI. Pulled out from
the C<Padre::Task::PPI> code.

=head1 METHODS

=over 4

=item new()

Constructor. Generally shouldn't be called with any arguments.

=back

=cut

# Used by all the PPIx::EditorTools::* modules
# Checks for either PPI::Document or take the code as a string and
# creates the ppi document

sub process_doc {
	my ( $self, %args ) = @_;

	$self->ppi( $args{ppi} ) if defined $args{ppi};
	return 1 if $self->ppi && $self->ppi->isa('PPI::Document');

	# TODO: inefficient to pass around full code/ppi
	$self->code( $args{code} ) if $args{code};
	my $code = $self->code;
	$self->ppi( PPI::Document->new( \$code ) );
	return 1 if $self->ppi && $self->ppi->isa('PPI::Document');

	croak "arguments ppi or code required";
	return;
}





#####################################################################
# Assorted Search Functions

sub find_unmatched_brace {
	$_[1]->isa('PPI::Statement::UnmatchedBrace') and return 1;
	$_[1]->isa('PPI::Structure') or return '';
	$_[1]->start and $_[1]->finish and return '';
	return 1;
}

# scans a document for variable declarations and
# sorts them into three categories:
# lexical (my)
# our (our, doh)
# dynamic (local)
# package (use vars)
# Returns a hash reference containing the three category names
# each pointing at a hash which contains '$variablename' => locations.
# locations is an array reference containing one or more PPI-style
# locations. Example:
# {
#   lexical => {
#     '$foo' => [ [ 2, 3, 3], [ 6, 7, 7 ] ],
#   },
#   ...
# }
# Thus, there are two places where a "my $foo" was declared. On line 2 col 3
# and line 6 col 7.
sub get_all_variable_declarations {
	my $document = shift;
	my %vars;

	my $declarations = $document->find(
		sub {
			return 0
				unless $_[1]->isa('PPI::Statement::Variable')
					or $_[1]->isa('PPI::Statement::Include')
					or $_[1]->isa('PPI::Statement::Compound');
			return 1;
		},
	);

	my %our;
	my %lexical;
	my %dynamic;
	my %package;
	foreach my $decl (@$declarations) {
		if ( $decl->isa('PPI::Statement::Variable') ) {
			my $type     = $decl->type();
			my @vars     = $decl->variables;
			my $location = $decl->location;

			my $target_type;

			if ( $type eq 'my' ) {
				$target_type = \%lexical;
			} elsif ( $type eq 'our' ) {
				$target_type = \%our;
			} elsif ( $type eq 'local' ) {
				$target_type = \%dynamic;
			}

			foreach my $var (@vars) {
				$target_type->{$var} ||= [];
				push @{ $target_type->{$var} }, $location;
			}
		}

		# find use vars...
		elsif ( $decl->isa('PPI::Statement::Include')
			and $decl->module eq 'vars'
			and $decl->type   eq 'use' )
		{

			# do it the low-tech way
			my $string   = $decl->content();
			my $location = $decl->location;

			my @vars = $string =~ /([\%\@\$][\w_:]+)/g;
			foreach my $var (@vars) {
				$package{$var} ||= [];
				push @{ $package{$var} }, $location;
			}

		}

		# find for/foreach loop variables
		elsif ( $decl->isa('PPI::Statement::Compound')
			&& ( $decl->type eq 'for' or $decl->type eq 'foreach' ) )
		{
			my @elems = $decl->elements;

			next if scalar(@elems) < 5;
			my $location = $decl->location;
			my $type     = $elems[2]->content();
			if ( $elems[4]->isa('PPI::Token::Symbol')
				&& ( $type eq 'my' || $type eq 'our' ) )
			{
				my $target_type;

				# Only my and our are valid for loop variable
				if ( $type eq 'my' ) {
					$target_type = \%lexical;
				} elsif ( $type eq 'our' ) {
					$target_type = \%our;
				}

				my $var = $elems[4]->content();
				$target_type->{$var} ||= [];
				push @{ $target_type->{$var} }, $location;
			}
		}
	} # end foreach declaration

	return (
		{   our     => \%our,
			lexical => \%lexical,
			dynamic => \%dynamic,
			package => \%package
		}
	);
}





#####################################################################
# Stuff that should be in PPI itself

sub element_depth {
	my $cursor = shift;
	my $depth  = 0;
	while ( $cursor = $cursor->parent ) {
		$depth += 1;
	}
	return $depth;
}

# TODO: PPIx::IndexOffsets or something similar might help.
# TODO: See the 71... tests. If we don#t flush locations there, this breaks.
sub find_token_at_location {
	my $document = shift;
	my $location = shift;

	if (   not defined $document
		or not $document->isa('PPI::Document')
		or not defined $location
		or not ref($location) eq 'ARRAY' )
	{
		require Carp;
		Carp::croak("find_token_at_location() requires a PPI::Document and a PPI-style location as arguments");
	}

	$document->index_locations();

	foreach my $token ( $document->tokens ) {
		my $loc = $token->location;
		if ( $loc->[0] > $location->[0]
			or ( $loc->[0] == $location->[0] and $loc->[1] > $location->[1] ) )
		{
			$document->flush_locations();
			return $token->previous_token();
		}
	}
	$document->flush_locations();
	return ();
}

# given either a PPI::Token::Symbol (i.e. a variable)
# or a PPI::Token which contains something that looks like
# a variable (quoted vars, interpolated vars in regexes...)
# find where that variable has been declared lexically.
# Doesn't find stuff like "use vars...".
sub find_variable_declaration {
	my $cursor = shift;
	return ()
		if not $cursor
			or not $cursor->isa("PPI::Token");
	my ( $varname, $token_str );
	if ( $cursor->isa("PPI::Token::Symbol") ) {
		$varname   = $cursor->symbol;
		$token_str = $cursor->content;
	} else {
		my $content = $cursor->content;
		if ( $content =~ /((?:\$#?|[@%*])[\w:\']+)/ ) {
			$varname   = $1;
			$token_str = $1;
		}
	}
	return ()
		if not defined $varname;

	$varname =~ s/^\$\#/@/;

	my $document = $cursor->top();
	my $declaration;
	my $prev_cursor;

	# This finds variable declarations if you're above it
	if ( $cursor->parent->isa('PPI::Statement::Variable') ) {
		return $cursor->parent;
	}

	# This finds variable declarations if you're above it and it has the form my ($foo , $bar);
	if (   $cursor->parent->isa('PPI::Statement::Expression')
		&& $cursor->parent->parent->parent->isa('PPI::Statement::Variable') )
	{
		return $cursor->parent->parent->parent;
	}

	while (1) {
		$prev_cursor = $cursor;
		$cursor      = $cursor->parent;
		if ( $cursor->isa("PPI::Structure::Block") or $cursor == $document ) {
			my @elems = $cursor->elements;
			foreach my $elem (@elems) {

				# Stop scanning this scope if we're at the branch we're coming
				# from. This is to ignore declarations later in the block.
				last if $elem == $prev_cursor;

				if ( $elem->isa("PPI::Statement::Variable")
					and grep { $_ eq $varname } $elem->variables )
				{
					$declaration = $elem;
					last;
				}

				# find use vars ...
				elsif ( $elem->isa("PPI::Statement::Include")
					and $elem->module eq 'vars'
					and $elem->type   eq 'use' )
				{

					# do it the low-tech way
					my $string = $elem->content();
					my @vars = $string =~ /([\%\@\$][\w_:]+)/g;
					if ( grep { $varname eq $_ } @vars ) {
						$declaration = $elem;
						last;
					}
				}

			}
			last if $declaration or $cursor == $document;
		}

		# this is for "foreach my $i ..."
		elsif ( $cursor->isa("PPI::Statement::Compound")
			and $cursor->type() =~ /^for/ )
		{
			my @elems = $cursor->elements;
			foreach my $elem (@elems) {

				# Stop scanning this scope if we're at the branch we're coming
				# from. This is to ignore declarations later in the block.
				last if $elem == $prev_cursor;

				if (    $elem->isa("PPI::Token::Word")
					and $elem->content() =~ /^(?:my|our)$/ )
				{
					my $nelem = $elem->snext_sibling();
					if (    defined $nelem
						and $nelem->isa("PPI::Token::Symbol")
						and $nelem->symbol() eq $varname || $nelem->content() eq $token_str )
					{
						$declaration = $nelem;
						last;
					}
				}
			}
			last if $declaration or $cursor == $document;
		}
	} # end while not top level

	return $declaration;
}

1;

__END__

=pod

=head1 AUTHORS

Gabor Szabo E<lt>gabor@szabgab.comE<gt>

=head2 CONTRIBUTORS

ADAMK

AZAWAWI

BOWTIE

buff3r

MGRIMES

PATRICKAS

SMUELLER

=head1 SEE ALSO

C<PPIx::EditorTools::*>, L<Padre>, L<App::EditorTools>, L<Padre>, and L<PPI>.

=cut

# Copyright 2008-2009 The Padre development team as listed in Padre.pm.
# LICENSE
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl 5 itself.
