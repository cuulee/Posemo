package PostgreSQL::SecureMonitoring::Run;

=head1 NAME

 PostgreSQL::SecureMonitoring::Run - Application/Execution class for PostgreSQL Secure Monitoring


=head1 SYNOPSIS

=encoding utf8


   use PostgreSQL::SecureMonitoring::Run;
   
   # or:
   use PostgreSQL::SecureMonitoring::Run output => "JSON";

   my $posemo = PostgreSQL::SecureMonitoring::Run->new_with_options();
   $posemo->run;

   # or:
   PostgreSQL::SecureMonitoring::Run->new_with_options->run;
   


=head1 DESCRIPTION



=head2 Configuration

The config file is parsed via L<Config::Any|Config::Any> and therefore understands each supported config file format.
The following examples are writtem in the apache style format, parsed via L<Config::General|Config::General>.


  #
  # Example config file
  #

  # Default values, can be overwritten by Hostgroups (see below)
  # Definition of Hosts to monitor
  # eihter name ONE host:

  host = database.internal.project.tld

  # user      = monitoring                      # Monitoring user (unprivileged)
  # passwd    =                                 # Password for this user; default: empty
  # schema    = public                          # SQL schema name for our
  # database  = monitoring                      # Name of monitoring DB"
  # port      =                                 # Port number for server to monitor



  # or more complex definition with host groups
  <HostGroup Elephant>
    Order = 10                                  # Sort order for this group
    Hosts = loc1_db1 loc1_db2 loc2_db1 loc2_db2 # Short version for hosts, all with default parameters from above
  </HostGroup>

  <HostGroup Mammut>
    Order = 20
    <Hosts>
      host = loc1_db3
      port = 5433
      # ...
    </Hosts>
    <Hosts>
      host = loc1_db3
      port = 5434
      # ....
    </Hosts>

  </HostGroup>


  <HostGroup


The following options of Gonfig::General are enabled:

  -LowerCaseNames     => 1,
  -AutoTrue           => 1,
  -UseApacheInclude   => 1,
  -IncludeRelative    => 1,
  -IncludeDirectories => 1,
  -IncludeGlob        => 1,

So all options may be written in lower/upper case mixed. If you use another config file format
(YAML, JSON, ...), then you should write all attribute names in lowercase.






=cut

use Moose;

use English qw( -no_match_vars );
use FindBin qw($Bin);
use Carp qw(croak);
use Storable qw(dclone);
use Time::HiRes qw(time);
use Sys::Hostname;
use Module::Loaded;
use Data::Dumper;

use Config::Any;

use Config::FindFile qw(search_conf);
use Log::Log4perl::EasyCatch ( log_config => search_conf("posemo-logging.properties") );

use PostgreSQL::SecureMonitoring;

use IO::All -utf8;

#<<<

# conf must be lazy, because in the builder must be called after initialization of all other attributes!

has configfile => ( is => "ro", isa => "Str",          default => search_conf("posemo.conf"),            documentation => "Configuration file", );
has log_config => ( is => "rw", isa => "Str",                                                            documentation => "Alternative logging config", );
has outfile    => ( is => "ro", isa => "Str",          default => q{-},                                  documentation => "Output file name; - for STDOUT (default)" );

#>>>

has _conf => (
               reader        => "conf",
               is            => "ro",
               isa           => "HashRef[Any]",
               builder       => "_build_conf",
               lazy          => 1,
               documentation => "Complete configuration (usually don't use at CLI)",
             );

has _results => (
                  reader  => "results",
                  traits  => ['Array'],
                  is      => 'ro',
                  isa     => 'ArrayRef[Any]',
                  default => sub { [] },
                  handles => {
                               all_results => 'elements',
                               add_result  => 'push',
                             },
                );

has _errcount => (
                   reader  => "errcount",
                   traits  => ['Counter'],
                   is      => 'ro',
                   isa     => 'Num',
                   default => 0,
                   handles => {
                                inc_error => 'inc',
                              },
                 );



with "MooseX::Getopt";
with 'MooseX::ListAttributes';


# Option constants
#   Public: listed in the result at host level
#   Host Options: may be set per host
#   other: options not passed to new check etc.
#
# TODO:
# warning_level etc. is not really useful at host level, only at check-level!
# add a new "level_options" ...

my @public_options        = qw( port user database schema );
my @host_options          = ( @public_options, qw( passwd enabled warning_level critical_level min_value max_value ) );
my @other_options         = qw( hosts hostgroup check order name );
my %allowed_host_options  = map { $ARG => 1 } @host_options;
my %allowed_other_options = map { $ARG => 1 } @other_options;
my %allowed_options       = ( global_id => 1, %allowed_host_options, %allowed_other_options );


=head2 import

Simple import method for importing "output => 'SomeOutput'"

Default outoput type is JSON.


=cut

sub import
   {
   my $class  = shift;
   my %params = @ARG;

   my $output = $params{output} // "JSON";

   with "PostgreSQL::SecureMonitoring::Output::$output";

   # TODO: more with with "with" parameter?

   # There is an error with t/00-load.t, so don't immutable if Test::More loaded
   __PACKAGE__->meta->make_immutable unless is_loaded("Test::More");

   return;
   }



sub BUILD
   {
   my $self = shift;

   # Log config logic:
   #
   # When log_config set (via CLI or ->new parameter): take this!
   # When not: take from config file, if this exists.
   # When not: take nothing, and don't re-initialise below
   # never set an empty log_config!

   if ( not $self->log_config )
      {
      if ( $self->conf->{log_config} )
         {
         $self->log_config( $self->conf->{log_config} );
         TRACE "Use log config from main config file: " . $self->log_config;
         }
      }
   else
      {
      TRACE "Use log config from (CLI) parameter: " . $self->log_config;
      }

   # re-initialise logging, when log config is set and is not the default one
   if ( $self->log_config and $self->log_config ne $DEFAULT_LOG_CONFIG )
      {
      die "Given log-config ${ \$self->log_config } does not exist\n" unless -f $self->log_config;
      Log::Log4perl->init( $self->log_config );
      DEBUG "Logging initialised with non-default config " . $self->log_config;
      }
   else
      {
      DEBUG "Logging still initialised with default config: $DEFAULT_LOG_CONFIG.";
      }

   return $self;
   } ## end sub BUILD


#  _build_conf
# reads / initializes the config file

sub _build_conf
   {
   my $self = shift;

   DEBUG "load config file: ${ \$self->configfile }";
   my $conf = Config::Any->load_files(
                                       {
                                         files           => [ $self->configfile ],
                                         use_ext         => 1,
                                         flatten_to_hash => 1,
                                         driver_args     => {
                                                          General => {
                                                                       -LowerCaseNames     => 1,
                                                                       -AutoTrue           => 1,
                                                                       -UseApacheInclude   => 1,
                                                                       -IncludeRelative    => 1,
                                                                       -IncludeDirectories => 1,
                                                                       -IncludeGlob        => 1,
                                                                     }
                                                        }
                                       }
                                     );

   $conf = $conf->{ $self->configfile } or die "No config loaded, tried with ${ \$self->configfile }!\n";

   TRACE "Conf: ", Dumper($conf);

   # TODO: validate!
   return $conf;
   } ## end sub _build_conf



=head2 run

Runs everything: calls run_checks, measures time and writes output to file or STDOUT ...

=cut

sub run
   {
   my $self = shift;

   return $self->list_attributes if $self->show_options;

   my $posemo_version = $PostgreSQL::SecureMonitoring::VERSION;
   my $hostname       = hostname;
   my $starttime      = time;
   my $message = "PostgreSQL Secure Monitoring version $posemo_version, running on host $hostname at " . localtime($starttime);

   DEBUG $message;

   $self->run_checks;
   my $runtime = time - $starttime;

   DEBUG "All Checks Done. Runtime: $runtime seconds.";

   my $output = $self->generate_output(
      {
        message        => $message,
        posemo_version => $posemo_version . "",   # convert to string!
        runtime        => $runtime,
        hostname       => $hostname,
        result         => $self->results,
        error_count    => $self->errcount,
        configfile     => $self->configfile,
        global_id      => $self->conf->{global_id},
      }
   );

   $self->write_result($output);

   return;
   } ## end sub run



=head2 run_checks

Runs all tests! Takes them including parameters from config file.

Everything will be executed in order and single threaded.
It might be possible to override this method and run one process for every host.

=cut


sub run_checks
   {
   my $self = shift;

   foreach my $host ( @{ $self->all_hosts } )
      {
      DEBUG "Prepare running all checks for host $host->{host} in hostgroup $host->{_hostgroup}";
      my %host_params = map { $ARG => $host->{$ARG} } grep { not m{^_} } keys %$host;
      my $posemo = PostgreSQL::SecureMonitoring->new(%host_params);

      TRACE "Host Params: " . Dumper( \%host_params );

      my @host_results;

      # run all checks
      foreach my $check_name ( $posemo->get_all_checks_ordered )
         {
         DEBUG "Prepare and run check $check_name";

         my $result;
         eval {
            my $check_params = { %host_params, %{ $host->{_check_params}{$check_name} // {} } };
            TRACE "Check Params: " . Dumper($check_params);

            my $check = $posemo->new_check( $check_name, $check_params );

            if ( $check->enabled ) { $result = $check->run_check; }
            else                   { DEBUG "SKIP Check ${ \$check->name } for host ${ \$check->host_desc }: not enabled"; }

            return 1;
            }
            or
            do { $self->inc_error; $result->{error} = "FATAL error in check $check_name for host $host->{host}: $EVAL_ERROR"; };

         push @host_results, $result if $result;

         } ## end foreach my $check_name ( $posemo...)

      # add (defined) host options
      my %this_host_params = map { $ARG => $host_params{$ARG} } grep { defined $host_params{$ARG} } @public_options;
      $this_host_params{results}   = \@host_results;
      $this_host_params{hostgroup} = $host->{_hostgroup};
      $this_host_params{host}      = $host->{host};
      $this_host_params{name}      = $host->{_name} if defined $host->{_name};
      $self->add_result( \%this_host_params );

      } ## end foreach my $host ( @{ $self...})

   return $self;
   } ## end sub run_checks


=head2 write_result()

Writes the final result.

May be overridden by output modules, e.g. don't write file, instead write it to a database ...

=cut

sub write_result
   {
   my $self   = shift;
   my $output = shift;

   io( $self->outfile )->print($output);

   return;
   }


=head2 all_host_groups

Returns a list of all host groups in the config file, ordered by the "order" config option.
The array contains only the names of the groups

=cut

sub all_host_groups
   {
   my $self = shift;

   my $grp = $self->conf->{hostgroup};
   my @all_host_groups = sort { ( $grp->{$a}{order} // 0 ) <=> ( $grp->{$b}{order} // 0 ) } keys %$grp;

   return @all_host_groups;
   }


=head2 all_hosts

Returns a list of hashrefs with informations of all hosts in all host groups.

Each hashref contains everything for calling the ->new constructor. Keys beginning
with underscore are internals, e.g. special parameters for specific tests via
C<_check_params>.

It is a flat, "denormalised" list.
So it's easy to loop over all hosts and all checks and setup the constructor.


=cut

sub all_hosts
   {
   my $self = shift;

   TRACE "get all hosts";
   my $conf = $self->conf;

   # Default parameters for all hosts
   my %defaults = _parameter_for_one_host($conf);
   my @hosts;

   # main section of conf
   push @hosts, _create_hosts_conf( $conf->{hosts}, \%defaults ) if $conf->{hosts};

   # host group sections
   foreach my $group ( $self->all_host_groups )
      {
      TRACE "Next group: '$group'";
      my %group_defaults = _parameter_for_one_host( $conf->{hostgroup}{$group}, \%defaults, $group );
      push @hosts, _create_hosts_conf( $conf->{hostgroup}{$group}{hosts}, \%group_defaults, $group );
      }

   TRACE "All Hosts: " . Dumper( \@hosts );

   return \@hosts;
   } ## end sub all_hosts


# TODO: Cleanup!
#  * variable and sub names
#  * logical structure and call tree

sub _parameter_for_one_host
   {
   my $conf        = shift;
   my $defaults    = shift // {};
   my $hostgroup   = shift // "_GLOBAL";
   my $hostmessage = shift // "";

   $hostmessage = " and host '$hostmessage'" if $hostmessage;

   my %params = ( %{ dclone($defaults) }, _hostgroup => $hostgroup );

   foreach my $option ( keys %$conf )
      {
      TRACE "Config option '$option' for hostgroup '$hostgroup'$hostmessage";
      die "Unknown or not allowed option '$option' in hostgroup '$hostgroup'$hostmessage\n"
         unless $allowed_options{$option};
      $params{$option} = $conf->{$option} if $allowed_host_options{$option};
      }

   # set all check options without test if they are allowed here.
   @{ $params{_check_params} }{ keys %{ $conf->{check} } } = @{ $conf->{check} }{ keys %{ $conf->{check} } };

   # Set host and name of the target machine.
   #
   if ( defined $conf->{name} )
      {
      TRACE "And set config option  Host $conf->{hosts} and name $conf->{name}";
      $params{_name} = $conf->{name};
      $params{host}  = $conf->{hosts};
      }
   else
      {
      _split_host_and_name( $conf->{hosts}, \%params );
      }

   return %params;
   } ## end sub _parameter_for_one_host


sub _split_host_and_name
   {
   my $in_host    = shift;
   my $out_params = shift;

   TRACE "Set config option for unsplitted Host $in_host";
   my ( $host, $name ) = split( qr{=}, $in_host );
   if ($name)
      {
      TRACE "Splitted: Host: $host; name: $name";
      $out_params->{host}  = $host;
      $out_params->{_name} = $name;
      }
   else
      {
      TRACE "nothing to split for $in_host ";
      $out_params->{host} = $in_host;
      }

   return;

   } ## end sub _split_host_and_name



#
# _create_hosts_conf( $host_conf_entry, $defaults [, $group] )
#
# $host_conf_entry may be a string (space delimetered) or a arrayref
#

sub _create_hosts_conf
   {
   my $host_conf_entry = shift;
   my $defaults        = shift;
   my $group           = shift;

   # handle something like: host = host1 host2 host3
   return _split_hosts( $host_conf_entry, $defaults ) unless ref $host_conf_entry;

   my @hosts;
   foreach my $single_entry (@$host_conf_entry)
      {
      die "Don't separate host names via comma! (at '$single_entry->{hosts}')\n" if $single_entry->{hosts} =~ m{,};
      foreach my $single_host ( split( qr{\s+}, $single_entry->{hosts} ) )
         {
         my %conf = %$single_entry;
         $conf{hosts} = $single_host;
         TRACE "Handling $single_host";
         push @hosts, { _parameter_for_one_host( \%conf, $defaults, $group, $single_host ), };
         }
      }

   return @hosts;

   } ## end sub _create_hosts_conf


#
# simple variant: split a single host config line
# with one or more hosts, separated by whitespace
#

sub _split_hosts
   {
   my $host_conf_entry = shift;
   my $defaults        = shift;

   die "Don't separate host names via comma! (at '$host_conf_entry')\n" if $host_conf_entry =~ m{,};

   my @hosts;

   foreach my $single_host ( split( qr{\s+}, $host_conf_entry ) )
      {
      my %conf = %$defaults;
      _split_host_and_name( $single_host, \%conf );
      push @hosts, \%conf;
      }

   return @hosts;

   }

1;
