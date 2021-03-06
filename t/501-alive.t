#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::PostgreSQL::SecureMonitoring;


my $result = result_ok "Alive", "test";

no_warning_ok $result;
no_critical_ok $result;
name_is $result,        "Alive";
result_is $result,      1;
row_type_is $result,    "single";
result_type_is $result, "boolean";

done_testing();



