package PostgreSQL::SecureMonitoring::Checks::Activity;

=head1 NAME

 PostgreSQL::SecureMonitoring::Checks::Activity -- statistics about backend activity (active, idle, ...)

=head1 SYNOPSIS

=head1 DESCRIPTION

This check returns a matrix list of all active sessions on all databases


=head2 SQL/Result

The SQL generates a result like this:

    database    | total | active | idle | idle in transaction | idle in transaction (aborted) | fastpath function call | disabled 
 ---------------+-------+--------+------+---------------------+-------------------------------+------------------------+----------
  $TOTAL        |     1 |      1 |    0 |                   0 |                             0 |                      0 |        0
  _posemo_tests |     1 |      1 |    0 |                   0 |                             0 |                      0 |        0
  postgres      |     0 |      0 |    0 |                   0 |                             0 |                      0 |        0
 (3 rows)


For each existing database all connections are counted grouped by type, and a summary of all databases is given too.

=head3 Filter by database name

Results may be filtered with parameter C<skip_db_re>, which is a regular expression filtering the databases. 
Default Filter is C<^template[01]$>, which excludes <template0> and <template1> databases.


=cut

use PostgreSQL::SecureMonitoring::ChecksHelper;
extends "PostgreSQL::SecureMonitoring::Checks";

has skip_db_re => ( is => "ro", isa => "Str", );


check_has
   description          => 'Counts running and idling connections.',
   has_multiline_result => 1,
   result_type          => "integer",
   parameters           => [ [ skip_db_re => 'TEXT', '^template[01]$' ], ],

   # complex return type
   return_type => q{
      database                        VARCHAR(64), 
      total                           INTEGER, 
      active                          INTEGER, 
      idle                            INTEGER, 
      "idle in transaction"           INTEGER, 
      "idle in transaction (aborted)" INTEGER, 
      "fastpath function call"        INTEGER, 
      disabled                        INTEGER },

   code => q{
      WITH states AS 
         (
            SELECT db.datname::VARCHAR(64)                                                         AS database, 
                   COUNT(CASE WHEN state IS NOT NULL                       THEN true END)::INTEGER AS total, 
                   COUNT(CASE WHEN state = 'active'                        THEN true END)::INTEGER AS active,
                   COUNT(CASE WHEN state = 'idle'                          THEN true END)::INTEGER AS idle,
                   COUNT(CASE WHEN state = 'idle in transaction'           THEN true END)::INTEGER AS "idle in transaction",
                   COUNT(CASE WHEN state = 'idle in transaction (aborted)' THEN true END)::INTEGER AS "idle in transaction (aborted)",
                   COUNT(CASE WHEN state = 'fastpath function call'        THEN true END)::INTEGER AS "fastpath function call",
                   COUNT(CASE WHEN state = 'disabled'                      THEN true END)::INTEGER AS disabled
              FROM pg_stat_activity AS stat
        RIGHT JOIN pg_database AS db ON stat.datname = db.datname 
          WHERE ( CASE WHEN length(skip_db_re) > 0 THEN db.datname !~ skip_db_re ELSE true END )
          GROUP BY database
          ORDER BY database
         )
       SELECT '$TOTAL', sum(total)::INTEGER, 
                        sum(active)::INTEGER, 
                        sum(idle)::INTEGER, 
                        sum("idle in transaction")::INTEGER, 
                        sum("idle in transaction (aborted)")::INTEGER, 
                        sum("fastpath function call")::INTEGER, 
                        sum(disabled)::INTEGER 
         FROM states
       UNION ALL
       SELECT database, total, 
                        active, 
                        idle, 
                        "idle in transaction", 
                        "idle in transaction (aborted)", 
                        "fastpath function call", 
                        disabled 
         FROM states;
      };


1;
