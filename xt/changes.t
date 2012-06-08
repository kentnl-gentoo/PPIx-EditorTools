#!/usr/bin/env perl

use 5.014;
use strict;
use warnings;
use English;

$OUTPUT_AUTOFLUSH = 1;
use feature 'unicode_strings';

# Test that Changes has an entry for current version
my @MODULES = (
	'Test::CheckChanges 0.14',
);

# Don't run tests during end-user installs
use Test::More;
plan( skip_all => 'Author tests not required for installation' )
	unless ( $ENV{RELEASE_TESTING} or $ENV{AUTOMATED_TESTING} );

# Load the testing modules
foreach my $MODULE ( @MODULES ) {
	eval "use $MODULE";
	if ( $@ ) {
		$ENV{RELEASE_TESTING}
		? die( "Failed to load required release-testing module $MODULE" )
		: plan( skip_all => "$MODULE not available for testing" );
	}
}

ok_changes();

done_testing();

1;

__END__
