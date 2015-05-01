#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;

use Pod::Usage;
use Getopt::Long;
use Config::Tiny;
use feature qw(say);

use Bio::EnsEMBL::Funcgen::Utils::EFGUtils qw(create_Storable_clone dump_data);
use Bio::EnsEMBL::Utils::Exception qw(throw);
use Bio::EnsEMBL::Funcgen::DBSQL::TrackingAdaptor;

use Bio::EnsEMBL::Utils::SqlHelper;


use constant CONFIG  => 'migration.config.ini';
select((select(STDOUT), $|=1)[0]);

main();

sub main {

  die "Continue at line 417. Same actions in dev as in tr";

  my $cfg = Config::Tiny->new;
     $cfg = Config::Tiny->read(CONFIG);

  _get_cmd_line_options($cfg);

  _connect_to_trackingDB($cfg);

  # _lock_meta_table($cfg,'dbh_tracking',);
  _connect_to_devDB($cfg);

  # _lock_meta_table($cfg,'dbh_dev',);
  _get_trackingDB_adaptors($cfg);
  _get_devDB_adaptors($cfg);

  _get_dev_states($cfg);

  #  print dump_data($cfg->{dev_adaptors},1,1);die;
  _get_current_data_sets($cfg);
    say "Current DataSeta: " . scalar(@{$cfg->{release}->{data_set}});

  _migrate($cfg);
  #  _unlock_meta_table($cfg,'dbh_tracking',);
  #  _unlock_meta_table($cfg,'dbh_dev',);

}
#-------------------------------------------------------------------------------


################################################################################
#                           print_method
################################################################################

=head2

  Name       : print_method
  Example    : print_method()
  Description: Prints the name of the calling method, used for debuging
  Returntype : none
  Exceptions : none
  Caller     : general
  Status     : stable

=cut

#-------------------------------------------------------------------------------
sub print_method {
 my $parent_function = (caller(1))[3];
 say $parent_function; 
}
#-------------------------------------------------------------------------------


################################################################################
#                           _unlock_meta_table
################################################################################

=head2

  Name       : _unlock_meta_table
  Example    : _unlock_meta_table($cfg, $dbh_name)
  Description: Prints the name of the calling method, used for debuging
  Returntype : none
  Exceptions : none
  Caller     : general
  Status     : at risk - work in progress

=cut

#----------------------------------------------------------------------------
sub _unlock_meta_table {
  my	($cfg, $dbh_name)	= @_;

  $cfg->{$dbh_name}->do("DELETE FROM meta WHERE meta_id = $cfg->{lock_id}");
}
#-------------------------------------------------------------------------------


################################################################################
#                           _lock_meta_table
################################################################################

=head2

  Name       : _lock_meta_table
  Example    : _lock_meta_table($cfg, $dbh_name)
  Description: Locks meta table of DB to prevent multiple parallel migrations 
  Returntype : none
  Exceptions : Multiple locks, locked already, uncaught exception/state
  Caller     : general
  Status     : at risk - work in progress

=cut

#----------------------------------------------------------------------------
sub _lock_meta_table {
  my	($cfg, $dbh_name)	= @_;

  $dbh_name =~ /_(\w*)/;
  my $db = $1;
  throw("Wrong dbh name format: $dbh_name") if(!defined $db);

  # Once Nathan is finished adding pipeline status to meta table, 
  # check for those as well
  my $lock = $cfg->{$dbh_name}->selectall_arrayref(
      "SELECT meta_value FROM meta WHERE meta_key = 'migration';"
      );

  if(! defined $lock->[0]) {
    say "Locking $db";
    my $sql;
    $sql = 'LOCK TABLE meta WRITE;';
    $cfg->{$dbh_name}->do($sql);

    my $username = $ENV{LOGNAME} || $ENV{USER} || getpwuid($<);
    my $sth = $cfg->{$dbh_name}->prepare("
        INSERT INTO
          meta (
            species_id, 
            meta_key, 
            meta_value
          )
        VALUES (
          NULL,
          'migration',
          '$username'
        )"
      );
    $sth->execute;
    $sth = $cfg->{$dbh_name}->prepare("
        SELECT meta_id FROM meta WHERE meta_value = 'migration'
        ");
    $cfg->{lock_id} = $sth->execute;
    $cfg->{$dbh_name}->do("UNLOCK TABLE");
  }
  elsif(scalar(@{$lock->[0]}) > 1){
    $cfg->{$dbh_name}->do("UNLOCK TABLE");
    throw("More than one lock found: $db-DB");
  }
  elsif(scalar(@{$lock->[0]}) == 1){
    $cfg->{$dbh_name}->do("UNLOCK TABLE");
    throw("User '$lock->[0]->[0]' has locked $db-DB");
  }
  else{
    $cfg->{$dbh_name}->do("UNLOCK TABLE");
    throw("Uncaught state $db");
  }
  return ;
} ## --- end sub _lock_meta_table
#-------------------------------------------------------------------------------


################################################################################
#                           _Get_Cmd_Line_Options
################################################################################

=head2

  Arg [1]    : Config::Tiny $cfg
  Example    : _Get_cmd_line_options($cfg)
  Description: add command line options
  Returntype : none
  Exceptions : none
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _get_cmd_line_options {
  my ($cfg) = @_;
  

  GetOptions( 
      $cfg->{user_options} ||= {},
      'overwrite|o',
      );
}


################################################################################
#                           _connect_to_devDB
################################################################################

=head2

  Name       : _connect_to_devDB
  Arg [1]    : Config::Tiny
  Example    : _connect_to_devDB($cfg)
  Description: Connects to release DB server
               Release DB will be created here
  Returntype : none
  Exceptions : Throws if connection not established
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _connect_to_devDB {
  my ($cfg) = @_;

  my $db_a = Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor->new (
    -user       => $cfg->{dev_db}->{user},
    -pass       => $cfg->{dev_db}->{pass},
    -host       => $cfg->{dev_db}->{host},
    -port       => $cfg->{dev_db}->{port},
    -dbname     => $cfg->{dev_db}->{dbname},
    -dnadb_name => $cfg->{dna_db}->{dbname},
    );  
  $db_a->dbc->do("SET sql_mode='traditional'");
  say "\nConnected to devDB: " . $cfg->{dev_db}->{dbname} ."\n";
 
  return($cfg->{dba_dev} = $db_a);
}
#-------------------------------------------------------------------------------


################################################################################
#                           _connect_to_trackingDB
################################################################################

=head2

  Name       : _connect_to_trackingDB
  Arg [1]    : Config::Tiny
  Example    : _connect_to_trackingDB($cfg)
  Description: Connects to tracking DB
  Returntype : none
  Exceptions : Throws if connection not established
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _connect_to_trackingDB {
  my ($cfg) = @_; 

  # say dump_data($cfg->{efg_db},1,1);
  my $db_a = Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor->new (
    -user       => $cfg->{efg_db}->{user},
    -pass       => $cfg->{efg_db}->{pass},
    -host       => $cfg->{efg_db}->{host},
    -port       => $cfg->{efg_db}->{port},
    -dbname     => $cfg->{efg_db}->{dbname},
    -dnadb_name => $cfg->{dna_db}->{dbname},
    );  
  $db_a->dbc->do("SET sql_mode='traditional'");
  say "\nConnected to trDB: " . $cfg->{efg_db}->{dbname}  ."\n";

  return($cfg->{dba_tracking} = $db_a);
}
#-------------------------------------------------------------------------------


################################################################################
#                            _get_current_Data_Sets
################################################################################

=head2

  Name       : _get_current_data_sets
  Arg [1]    : Config::Tiny
  Example    : _get_current_data_sets($cfg)
  Description: Retrieves all DataSets for the current releases
               Stores IDs as comma separated list in config hash
  Returntype : none
  Exceptions : Throws if resulting hash already exists
  Caller     : general
  Status     : At risk - TO BE REMOVED and replaced by nj1 code
  ToDo       : Return objects

=cut

#-------------------------------------------------------------------------------
sub _get_current_data_sets {
  my ($cfg) = @_;

  if(exists $cfg->{data_set_ids}){
    throw 'Hash $cfg->{data_set_ids} must not be defined beforehand';
  }

  my $helper =
       Bio::EnsEMBL::Utils::SqlHelper->new( 
        -DB_CONNECTION => $cfg->{dba_tracking}->dbc );

  my $sql_all = "
    SELECT
      ds.data_set_id
    FROM
      data_set ds,
      status   s
    WHERE
      s.status_name_id  = 2           AND
      s.table_name      = 'data_set'  AND
      ds.data_set_id    = s.table_id;
  ";
  my $files = $helper->execute_simple(
    -SQL => $sql_all
    );

  $cfg->{release}->{data_set} =
      $cfg->{tr_adaptors}->{ds}->fetch_all_by_dbID_list($files);
}
#-------------------------------------------------------------------------------

################################################################################
#                                _migrate
################################################################################

=head2

  Name       : _migrate
  Arg [1]    : Config::Tiny
  Example    : _migrate($cfg)
  Description:  This method retrieves all DataSets marked as being part of the
                current release.
  Returntype : none
  Exceptions : none
  Caller     : general
  Status     : At risk - not tested
  Notes:     : FeatureType - Segmentation has an analysis linked. This should
                probably be compared to FeatureSet Analysis.
                Only FeatureSets be migrated


=cut

#-------------------------------------------------------------------------------
sub _migrate {
  my ($cfg) = @_;


  my $flag_rf = $cfg->{generic}->{regulatory_feature};
  
  DATASET:
  for my $tr_ds(@{$cfg->{release}->{data_set}}) {
    
    my ($tr, $dev) = ({},{});
    next if($tr_ds->feature_type eq 'RegulatoryFeature' && $flag_rf == 0);

    if($tr_ds->feature_type eq 'RegulatoryFeature'){
      _migrate_regulatory_feature($cfg, $tr_ds);
    }
    else{
      say "Migrating FeatureSet: " . $tr_ds->name;
      $tr->{ds} = $tr_ds;
      _migrate_cell_feature_type($cfg, $tr, $dev);
      _migrate_feature_set($cfg, $tr, $dev);
      _store_in_dev($cfg, $tr, $dev);
    }
  }
  return ;
}## --- end sub _migrate
#-------------------------------------------------------------------------------


################################################################################
#                                _migrate_feature_set
################################################################################

=head2

  Name       : _migrate_feature_set
  Arg [1]    :
  Example    :
  Description: 
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _migrate_feature_set {
  my ($cfg, $tr, $dev) = @_;
  print_method();

  my $dev_ds = $cfg->{dev_adaptors}->{ds}->fetch_by_name($tr->{ds}->name);

  if(defined $dev_ds){ 
    $dev->{ds} = $dev_ds;
    _compare_data_set($cfg, $tr->{ds}, $dev->{ds});

    $tr->{fs} = $tr->{ds}->product_FeatureSet;
    my $dev_fs = $dev->{ds}->product_FeatureSet;
    if (! defined $dev_ds){
      $dev_fs = $cfg->{dev_adaptors}->{fs}->fetch_by_name($tr->{fs}->name);
      if(defined ($dev_fs))
    }
    _compare_feature_set($cfg, $tr, $dev);

    #avoid $dev->{ds} = undefined
  }


  $tr->{fs} = $tr->{ds}->product_FeatureSet;
  my $dev_fs = $cfg->{dev_adaptors}->{fs}->fetch_by_name($tr->{fs}->name);
  if(defined $dev_fs){
    _compare_feature_set($cfg, $tr, $dev);
    _compare_feature_set_data_set($cfg, $dev_fs, $tr->{ds}, $tr, $dev);
  }


  $tr->{rs} = $tr->{ds}->get_supporting_sets;
  foreach my $tr_rs (@{$tr->{rs}}){
    my $dev_rs = $cfg->{dev_adaptors}->{rs}->fetch_by_name($tr_rs->name);
    if(defined $dev_rs){
      _compare_result_set($cfg, $tr_rs, $dev_rs, $tr, $dev);
      _compare_result_set_data_set($cfg, $dev_rs, $tr->{ds}, $tr, $dev);
      push(@{$dev->{rs}}, $dev_rs);
    }

    $tr->{iss} = $tr_rs->get_support;
    say "ISS: " . scalar(@{$tr->{iss}});
    say "rs name: " . $tr_rs->name;
    foreach my $tr_iss (@{$tr->{iss}}){
      my $dev_iss = $cfg->{dev_adaptors}->{iss}->fetch_by_name($tr_iss->name);
      if(defined $dev_iss){
        _compare_input_subset($cfg, $tr_iss, $dev_iss, $tr, $dev);
        _compare_input_subset_data_set($cfg, $dev_iss, $tr->{ds}, $tr, $dev);
        push(@{$dev->{iss}}, $dev_iss);
      } 
    }


    $tr->{exp} = $tr_rs->experiment;
    my $dev_exp = $cfg->{dev_adaptors}->{ex}->fetch_by_name($tr->{exp}->name);
    if(defined $dev_exp){
      $dev->{exp} = $dev_exp;
    }

    $tr->{exp_group} = $tr->{exp}->experimental_group;
    my $eg_name = $tr->{exp_group}->name;
    my $dev_exp_group = $cfg->{dev_adaptors}->{eg}->fetch_by_name($eg_name);
    if(defined $dev_exp_group){
      $dev->{exp_group} = $dev_exp_group;
      
    }
  }
}
#-------------------------------------------------------------------------------

################################################################################
#                           _migrate_cell_feature_type
################################################################################

=head2

  Name       : _migrate_cell_feature_type
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested
  ToDo       : Check store methods if reassinging is necessary. Object always updated?

=cut

#-------------------------------------------------------------------------------
sub _migrate_cell_feature_type {
  my ($cfg, $tr, $dev) = @_;
  print_method();

  $tr->{ct} = $tr->{ds}->cell_type;
  $tr->{ft} = $tr->{ds}->feature_type;

  my $ct_name = $tr->{ct}->name;
  my $dev_ct = $cfg->{dev_adaptors}->{ct}->fetch_by_name($ct_name);

  if(defined $dev_ct){
    $dev->{ct} = $dev_ct;
    _compare_cell_type($cfg, $tr, $dev);
  }
  else {
    $dev->{ct}   = create_Storable_clone ($tr->{ct});
    ($dev->{ct}) = @{$cfg->{dev_adaptors}->{ct}->store($dev->{ct})};
  }

  my $ft_name = $tr->{ft}->name;
  my $dev_ft = $cfg->{dev_adaptors}->{ft}->fetch_by_name($ft_name);

  if(defined $dev_ft){
    $dev->{ft} = $dev_ft;
    _compare_feature_type($cfg, $tr, $dev);
  }
  else {
    $dev->{ft}   = create_Storable_clone ($tr->{ft});
    ($dev->{ft}) = @{$cfg->{dev_adaptors}->{ft}->store($dev->{ft})};
  }
}
#-------------------------------------------------------------------------------


################################################################################
#                           print_cached_objects
################################################################################

=head2

  Name       : print_cached_objects
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub print_cached_objects {
  my ($cfg, $tr, $dev, $error) = @_;

  my $parent  = (caller(1))[3];
  my $gparent = (caller(2))[3];

  say "\n--- Tracking DB: ".$cfg->{efg_db}->{dbname} ."---";
  _iterate($tr);

  say "\n--- Dev DB: ".$cfg->{dev_db}->{dbname} ."---\n";
  _iterate($dev);
 
  say "x" x 90   ."\n--- Error Caller: $gparent / $parent ---\n" ;
 
  say "Error message: $error"; 
  die;
}
#-------------------------------------------------------------------------------


################################################################################
#                                 _iterate
################################################################################

=head2

  Name       : _iterate
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested
  ToDo       : Better neame, print cache objects, print_objects_by_type
                Map for ARRAY block?

=cut

#-------------------------------------------------------------------------------
sub _iterate {
  my ($cache) = @_;

  # type = ds, rs, ft
  # $tr->{rs}
    foreach my $type (sort keys %{$cache}){
      if(ref($cache->{$type}) eq 'ARRAY' ){
        for my $object (@{$cache->{$type}}){
           _print_object($object);
        }
      }
      else { 
        my $object = $cache->{$type};
        _print_object($object);
      }
    }
}
#-------------------------------------------------------------------------------


################################################################################
#                                 _iterate
################################################################################

=head2

  Name       : _print_object
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested
  ToDo       : Merge first attrib loop, 3indent rule, pass indent as parameter

=cut

#-------------------------------------------------------------------------------
sub _print_object {
  my ($object) = @_;

  my %class = (
    analysis           => 'Bio::EnsEMBL::Analysis',
    cell_type          => 'Bio::EnsEMBL::Funcgen::CellType',
    data_set           => 'Bio::EnsEMBL::Funcgen::DataSet',
    experiment         => 'Bio::EnsEMBL::Funcgen::Experiment',
    experimental_group => 'Bio::EnsEMBL::Funcgen::ExperimentalGroup',
    feature_type       => 'Bio::EnsEMBL::Funcgen::FeatureType',
    result_set         => 'Bio::EnsEMBL::Funcgen::ResultSet',
    input_subset       => 'Bio::EnsEMBL::Funcgen::InputSubset',

    );

  my @attributes = qw(name logic_name dbID);

  say "\n".ref($object);
  

  for my $attr (@attributes){
    if( $object->can($attr) ) {
      say $attr .': '. $object->$attr;
    }
  }

  foreach my $method (sort keys %class) {
    my $type = $class{$method};
    if( $object->can($method) ){
      say "\t" . $method;
      for my $attr (@attributes){
        if( $type->can($attr) ) {
          if(defined $object->$method){
            say "\t\t$attr: ".$object->$method->$attr;
          }
          else {
            say "\t\t$attr: Undefinded, ' $method ' likely optional";
          }
        }
      }
    }
  }
}

################################################################################
#                                 _migrate_regulatory_feature
################################################################################

=head2

  Name       : _migrate_regulatory_feature
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut
#-------------------------------------------------------------------------------

sub _migrate_regulatory_feature {
  throw "Not implemented yet";
}
#-------------------------------------------------------------------------------



################################################################################
#                              _add_control_experiment
################################################################################

=head2

  Name       : _add_control_experiment
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _add_control_experiment {
  my ($cfg, $diffs) = @_;

die "Needs reimplementing";

  if(exists $cfg->{add_control_exp}){
    for my $tr_exp (@{$cfg->{add_control_exp}}){
      my $name = $tr_exp->name;
      my $dev_exp = $cfg->{dev_adaptors}->{experiment}->fetch_by_name($name);

      if(!defined $dev_exp){
        $dev_exp = create_Storable_clone($tr_exp);
        ($dev_exp) = @{$cfg->{dev_adaptors}->{experiment}->store($dev_exp)};
      }
      else{
        my $tmp_tr->{experiment}  = $tr_exp;
        my $tmp_dev->{experiment} = $dev_exp;
        my $tmp = _compare_experiment($diffs, $tmp_tr, $tmp_dev);
        if(ref($tmp) eq 'HASH' and keys %{$tmp}){
          _merge_diffs($diffs, $tmp);
        }
      }
    }
  }
}

# Store in devDB if not present
# Create Storable clone and add to dev data structure

###############################################################################
#                            _store_experimental_group
###############################################################################

=head2

  Name       : _store_experimental_group
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _store_experimental_group {
  my ($cfg, $tr, $dev) = @_;

  print_method();

  $dev->{exp_group} = create_Storable_clone(
    $tr->{exp_group}  
  );
  $cfg->{dev_adaptors}->{eg}->store($dev->{exp_group});
}
#-------------------------------------------------------------------------------

###############################################################################
#                            _store_experiment
###############################################################################

=head2

  Name       : _store_experiment
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _store_experiment {
  my ($cfg, $tr, $dev) = @_;

  print_method();

  $dev->{exp}   = create_Storable_clone($tr->{exp},{
    -cell_type          => $dev->{ct},
    -experimental_group => $dev->{exp_group},
    -feature_type       => $dev->{ft},
    });
  $cfg->{dev_adaptors}->{ex}->store($dev->{exp});

  my $states = $tr->{exp}->get_all_states;
  _add_states($cfg, $states, $dev->{exp});

}
#------------------------------------------------------------------------------

###############################################################################
#                            _store_input_subset
###############################################################################

=head2

  Name       : _store_input_subset
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#------------------------------------------------------------------------------
sub _store_input_subset {
  my ($cfg, $tr_iss, $tr, $dev) = @_;

  print_method();

  my $dev_anal = _fetch_or_store_analysis($cfg, $tr_iss->analysis, $tr, $dev);
  
  my $dev_iss  = create_Storable_clone($tr_iss, {
      -analysis     => $dev_anal,
      -cell_type    => $dev->{ct},
      -experiment   => $dev->{exp},
      -feature_type => $dev->{ft},
      });
  
  $cfg->{dev_adaptors}->{iss}->store($dev_iss);

  my $states = $tr_iss->get_all_states;
  
  if(scalar (@{$states}) ){
    _add_states($cfg, $states, $dev_iss);
    $cfg->{dev_adaptors}->{iss}->store_states($dev_iss);
  }
  push(@{$dev->{iss}}, $dev_iss);
}
#------------------------------------------------------------------------------

###############################################################################
#                            _store_result_set
###############################################################################

=head2

  Name       : _store_result_set
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#------------------------------------------------------------------------------
sub _store_result_set {
  my ($cfg, $tr_rs, $tr, $dev) = @_;

  print_method();

  my $dev_anal = _fetch_or_store_analysis($cfg, $tr_rs->analysis, $tr, $dev);

  # say dump_data($tr_rs,1,1);
  # say dump_data($dev->{iss},1,1);

  my $dev_rs  = create_Storable_clone($tr_rs, {
      -analysis     => $dev_anal,
      -cell_type    => $dev->{ct},
      -experiment   => $dev->{exp},
      -feature_type => $dev->{ft},
      -support      => $dev->{iss},
      });

  $cfg->{dev_adaptors}->{rs}->store($dev_rs);

  my $states = $tr_rs->get_all_states;
  if(scalar (@{$states}) ){
    _add_states($cfg, $states, $dev_rs);
    $cfg->{dev_adaptors}->{rs}->store_states($dev_rs);
  }
  push(@{$dev->{rs}}, $dev_rs);
}
#-------------------------------------------------------------------------------

###############################################################################
#                            _store_feature_set
###############################################################################

=head2

  Name       : _store_feature_set
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _store_feature_set {
  my ($cfg, $tr, $dev) = @_;

  print_method();

  my $dev_anal = _fetch_or_store_analysis($cfg, $tr->{fs}->analysis, $tr, $dev);

  $dev->{fs} = create_Storable_clone($tr->{fs},{
        -analysis     => $dev_anal,
        -cell_type    => $dev->{ct},
        -experiment   => $dev->{exp},
        -feature_type => $dev->{ft},
        });
    $cfg->{dev_adaptors}->{fs}->store($dev->{fs});
}
#-------------------------------------------------------------------------------

################################################################################
#                            _store_data_set
################################################################################

=head2

  Name       : _store_data_set
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _store_data_set {
  my ($cfg, $tr, $dev) = @_;

  print_method();

  $dev->{ds} = create_Storable_clone($tr->{ds},{
        -feature_set      => $dev->{fs},
        -supporting_sets  => $dev->{iss},
        });
  $cfg->{dev_adaptors}->{ds}->store($dev->{ds});
}
#-------------------------------------------------------------------------------

################################################################################
#                            _fetch_or_store_analysis
################################################################################

=head2

  Name       : _fetch_or_store_analysis
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _fetch_or_store_analysis {
  my ($cfg, $tr_anal, $tr, $dev) = @_;

  print_method();

  my $name      = $tr_anal->logic_name;
  my $dev_anal  = $cfg->{dev_adaptors}->{an}->fetch_by_logic_name($name);

  if(defined $dev_anal){
    _compare_analysis($cfg, $tr_anal, $dev_anal, $tr, $dev);
  }
  else {
    $dev_anal = _create_storable_analysis($cfg, $tr_anal);
    $cfg->{dev_adaptors}->{an}->store($dev_anal);
  }
  return $dev_anal;
}




################################################################################
#                            _create_storable_analysis
################################################################################

=head2

  Name       : _create_storable_analysis
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _create_storable_analysis {
  my ($cfg, $analysis) = @_;

  print_method();

  my $dev_analysis;
  $dev_analysis = bless({%{$analysis}}, ref($analysis));
  $dev_analysis->{adaptor} = undef;
  $dev_analysis->{dbID}    = undef;
  return($dev_analysis);
}
#-------------------------------------------------------------------------------

################################################################################
#                            _store_in_dev
################################################################################

=head2

  Name       : 
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _store_in_dev {
  my ($cfg, $tr, $dev) = @_;

  print_method();

  if(defined $dev->{exp_group}){
    _compare_experimental_group($cfg, $tr, $dev);
  }
  else {
    _store_experimental_group($cfg, $tr, $dev);
  }

  if(defined $dev->{exp}){
    _compare_experiment($cfg, $tr, $dev);
    _compare_experiment_data_set($cfg, $dev->{exp}, $tr->{ds}, $tr, $dev);
  }
  else {
    _store_experiment($cfg, $tr, $dev);
  }

  for my $tr_iss(@{$tr->{iss}}){
    my $found = 0;
    if (defined $dev->{iss}){
      for my $dev_iss(@{$dev->{iss}}){
        if($dev_iss->name eq $tr_iss->name){
          _compare_input_subset($cfg, $tr_iss, $dev_iss, $tr, $dev);
          _compare_input_subset_data_set($cfg, $dev_iss, $tr->{ds}, $tr, $dev);
          $found = 1;
        }
      }
    }
    if($found == 0){
      _store_input_subset ($cfg, $tr_iss, $tr, $dev);
    }
  }
  for my $tr_rs(@{$tr->{rs}}){
    
    my $found = 0;
    if(defined $dev->{rs}){
      say 'Defined';
      for my $dev_rs(@{$dev->{rs}}){
        if($dev_rs->name eq $tr_rs->name){
          say 'In compare';
          say $dev_rs->name;
          _compare_result_set($cfg, $tr_rs, $dev_rs, $tr, $dev);
          _compare_result_set_data_set($cfg, $dev_rs, $tr->{ds}, $tr, $dev);
          $found = 1;
        }
      }
    }
    if($found == 0){
      _store_result_set($cfg, $tr_rs, $tr, $dev);
    }
  }

  if(defined $dev->{fs}){
    _compare_feature_set($cfg, $tr, $dev);
  }
  else{
    _store_feature_set($cfg, $tr, $dev);
  }

  if(defined $dev->{ds}){
    _compare_data_set($cfg, $tr, $dev);
  }
  else{
    _store_data_set($cfg, $tr, $dev);
  }
  #*    From flatfile/direct SQL, see confluence
  #    my $AR_annotated_features =
  #      $cfg->{tr_adaptors}->{af}->fetch_all_by_FeatureSets([$tr_fset]);
}
#-------------------------------------------------------------------------------

################################################################################
#                            _add_states
################################################################################

=head2

  Name       : _add_states
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _add_states {
  my ($cfg, $cached_states, $object) = @_;
  print_method();

  if(! $object->can('add_status')){
    throw("Can't add status " . $object->name. ' Type: '. ref($object));
  }
  $object->{states} = [];
  for my $state (@{$cached_states}){
    if(exists $cfg->{dev_states}->{$state}){
      $object->add_status($state);
    }
  }
}


################################################################################
#                                 _get_dev_states
################################################################################


=head2

  Name       : _get_dev_states
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested
  ToDo       : Move to TrackingAdaptor

=cut

#-------------------------------------------------------------------------------
sub _get_dev_states {
  my ($cfg) = @_;
  print_method();

  my $helper =
       Bio::EnsEMBL::Utils::SqlHelper->new( 
        -DB_CONNECTION => $cfg->{dba_tracking}->dbc );

  my $sql = '
    SELECT
      name,
      status_name_id
    FROM 
      status_name 
    WHERE 
      tracking_only = 0
  ';

  $cfg->{dev_states} = $helper->execute_into_hash(
    -SQL      => $sql,
    -CALLBACK => sub {
        my @row = @{shift @_};
        return ($row[0],$row[1]) ;
      }
    );
}





################################################################################
#                           _migrate_annotated_feature
################################################################################
# Assumption: experimental groups are consistent within one DataSet

=head2

  Name       :
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested
  ToDo       : AP code to store ResulSet will change and prevent storing a
               ResultSet without linked InputSet

=cut

#-------------------------------------------------------------------------------
sub _migrate_annotated_feature {
  my ($cfg, $feature_set) = @_;

die "Check";

  my $tr_db   = $cfg->{efg_db}->{db_name};
  my $dev_db  = $cfg->{dev_db}->{db_name};
  my $feature_set_id = $feature_set->dbID;


    my $sql_query = "
    mysql
      -h$cfg->{dev_db}->{host}
      -P$cfg->{dev_db}->{port}
      -u$cfg->{dev_db}->{user}
      -p$cfg->{dev_db}->{pass}
      $cfg->{dev_db}->{db_name}
  --execute \"
  INSERT INTO
    $dev_db.af_test (
      annotated_feature_id,
      seq_region_id,
      seq_region_start,
      seq_region_end,
      display_label,
      score,
      feature_set_id,
      summit
      )
    SELECT
      NULL,
      seq_region_id,
      seq_region_start,
      seq_region_end,
      display_label,
      score,
      $feature_set_id,
      summit
    FROM
      $tr_db.annotated_feature
    WHERE
      $feature_set_id = ?
      \"
";
}
#-------------------------------------------------------------------------------

################################################################################
#                            _compare_analysis
################################################################################

=head2

  Name       : _compare_analysis
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _compare_analysis {
  my ($cfg, $tr_anal, $dev_anal, $tr, $dev) = @_;
  print_method();
  
  my $error = undef;
  my $tmp   = undef;

  $tmp = $tr_anal->compare($dev_anal);
  if($tmp != 0){
    $error .= "Analysis differences $tmp\n";
    print_cached_objects($cfg, $tr, $dev, $error);
  }
}
#-------------------------------------------------------------------------------


#-------------------------------------------------------------------------------
#data_set_id, (product) feature_set_id, name                        ,
################################################################################
#                            _compare_cell_type
################################################################################

=head2

  Name       : _compare_cell_type
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested
  ToDo       : Check if -1 is needed for these objects,
              Change _check_tmp to return $error
              Change to compare_shallow?
=cut

#-------------------------------------------------------------------------------
sub _compare_cell_type {
  my ($cfg, $tr, $dev) = @_;
  print_method();
  
  my $error = undef;
  my $tmp   = undef;

  $tmp = $tr->{ct}->compare_to($dev->{ct},'-1');
  _check_tmp($tmp, $error);

  if(defined ($error) ){
    $error = "--- CellType ---\n" . $error;
    print_cached_objects($cfg, $tr, $dev, $error);
  }
}
#-------------------------------------------------------------------------------

################################################################################
#                           _compare_Feature_Type 
################################################################################

=head2

  Name       : _compare_Feature_Type
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _compare_feature_type {
  my ($cfg, $tr, $dev) = @_;
  
  print_method();
  my $error = undef;
  my $tmp   = undef;

  $tmp = $tr->{ft}->compare_to($dev->{ft},'-1');
  _check_tmp($tmp, $error);

  if(defined $tr->{ft}->analysis){
    $tmp = $tr->{ft}->analysis->compare($dev->{ft}->analysis);
    _check_tmp($tmp, $error);
  }
  
  if(defined ($error) ){
    $error = "--- FeatureType ---\n" . $error;
    print_cached_objects($cfg, $tr, $dev, $error);
  }
}
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
#data_set_id, (product) feature_set_id, name                        ,
################################################################################
#                            _Compare_Data_Set
################################################################################

=head2

  Name       :
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _compare_data_set {
  my ($cfg, $tr, $dev) = @_;
  print_method();
  
  my $error = undef;
  my $tmp   = undef;

  $tmp = $tr->{ds}->compare_to($dev->{ds},'-1');
  _check_tmp($tmp, $error);
  $tmp = $tr->{ds}->cell_type->compare_to($dev->{ds}->cell_type,'-1');
  _check_tmp($tmp, $error);
  $tmp = $tr->{ds}->feature_type->compare_to($dev->{ds}->feature_type,'-1');
  _check_tmp($tmp, $error);


  if(defined ($error) ){
    $error = "--- DataSet ---\n" . $error;
    print_cached_objects($cfg, $tr, $dev, $error);
  }
}
#-------------------------------------------------------------------------------

################################################################################
#                            _compare_feature_set
################################################################################

=head2

  Name       : _compare_feature_set
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _compare_feature_set {
  my ($cfg, $tr, $dev) = @_;
  print_method();
  
  my $error = undef;
  my $tmp   = undef;

  $tmp = $tr->{fs}->compare_to($dev->{fs},'-1');
  _check_tmp($tmp, $error);
  $tmp = $tr->{fs}->cell_type->compare_to($dev->{fs}->cell_type,'-1');
  _check_tmp($tmp, $error);
  $tmp = $tr->{fs}->feature_type->compare_to($dev->{fs}->feature_type,'-1');
  _check_tmp($tmp, $error);
  $tmp = $tr->{fs}->experiment->compare_to($dev->{fs}->experiment,'-1');
  _check_tmp($tmp, $error);

  if(defined ($error) ){
    $error = "--- FeatureSet ---\n" . $error;
    print_cached_objects($cfg, $tr, $dev, $error);
  }
}
#-------------------------------------------------------------------------------


################################################################################
#                           _compare_result_set
################################################################################

=head2

  Name       : _compare_result_set
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#result_set_id, analysis_id, name, cell_type_id, feature_type_id, feature_class
#-------------------------------------------------------------------------------
sub _compare_result_set {
  my ($cfg, $tr_rs, $dev_rs, $tr, $dev) = @_;
  print_method();

  my $error = undef;
  my $tmp   = undef;
  
  $tmp = $tr_rs->compare_to($dev_rs,'-1');
  _check_tmp($tmp, $error);


  $tmp = $tr_rs->analysis->compare($dev_rs->analysis);
  if($tmp != 0){
    $error .= "Analysis differences\n";
  }

  $tmp = $tr_rs->cell_type->compare_to($dev_rs->cell_type,'-1');
  _check_tmp($tmp, $error);

  $tmp = $tr_rs->feature_type->compare_to($dev_rs->feature_type,'-1');
  _check_tmp($tmp, $error);

  if( scalar(@{$tr_rs->get_support}) != scalar(@{$dev_rs->get_support}) ){
    $error .= 'Difference in support [tr/dev]: ';
    $error .= scalar(@{$tr_rs->get_support}) .'/';
    $error .= scalar(@{$dev_rs->get_support}) ."\n";
  } 

  if(defined ($error) ){
    $error = "--- ResultSet ---\n" . $error;
    print_cached_objects($cfg, $tr, $dev, $error);
  }
}
#-------------------------------------------------------------------------------


################################################################################
#                           _compare_result_set_data_set
################################################################################

=head2

  Name       : _compare_result_set_data_set
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _compare_result_set_data_set {
  my ($cfg, $rs, $ds, $tr, $dev) = @_;
  print_method();

  my $error = undef;

  if($rs->cell_type->name ne $ds->cell_type->name){
    $error .= "CellType missmatch [RS/DS] " . $rs->cell_type->name.'|';
    $error .= $ds->cell_type->name;
  }

  if($rs->feature_type->name ne $ds->feature_type->name){
    $error .= "FeatureType missmatch [RS/DS] " . $rs->feature_type->name.'|';
    $error .= $ds->feature_type->name ."\n";
  }

  if(defined ($error) ){
    print_cached_objects($cfg, $tr, $dev, $error);
  }
}
#-------------------------------------------------------------------------------


################################################################################
#                           _compare_feature_set_data_set
################################################################################

=head2

  Name       : _compare_feature_set_data_set
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------

sub _compare_feature_set_data_set {
  my ($cfg, $fs, $ds, $tr, $dev) = @_;
  print_method();

  my $error = undef;


  if($fs->cell_type->name ne $ds->cell_type->name){
    $error .= "CellType missmatch [FS/DS] " . $fs->cell_type->name.'|';
    $error .= $ds->cell_type->name;
  }

  if($fs->feature_type->name ne $ds->feature_type->name){
    $error .= "FeatureType missmatch [FS/DS] " . $fs->feature_type->name.'|';
    $error .= $ds->feature_type->name ."\n";
  }

  if($fs->experiment->name ne $ds->experiment->name){
    $error .= "Experiment missmatch [FS/DS] " . $fs->experiment->name.'|';
    $error .= $ds->experiment->name;
  }

  if(defined ($error) ){
    print_cached_objects($cfg, $tr, $dev, $error);
  }
}
#-------------------------------------------------------------------------------


################################################################################
#                        _compare_input_subset_data_set
################################################################################

=head2

  Name       : _compare_result_input_subset_data_set
  Arg [1]    :
  Example    :
  Description: Compare 
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _compare_input_subset_data_set {
  my ($cfg, $iss, $ds, $tr, $dev) = @_;
  print_method();

  my $error = undef;

  if($iss->cell_type->name ne $ds->cell_type->name){
    $error .= "CellType missmatch [ISS/DS] " . $iss->cell_type->name.'|';
    $error .= $ds->cell_type->name;
  }
  if($iss->feature_type->name ne 'WCE'){
    if($iss->feature_type->name ne $ds->feature_type->name){
      $error .= "FeatureType missmatch [ISS/DS] ".$iss->feature_type->name.'|';
      $error .= $ds->feature_type->name ."\n";
      $error .= 'dbID: ' . $iss->dbID."\n";
      $error .= 'ref: ' . ref($iss)."\n";
    }
  }
  if(defined ($error) ){
    $error = "--- _compare_input_subset_data_set ---\n" . $error;
      # say dump_data($iss,1,1);

    push(@{$dev->{iss}}, $iss);
    print_cached_objects($cfg, $tr, $dev, $error);
  }

}

################################################################################
#                           _compare_experiment_data_set
################################################################################

=head2

  Name       : _compare_experiment_data_set
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _compare_experiment_data_set {
  my ($cfg, $exp, $ds, $tr, $dev) = @_;
  print_method();

  my $error = undef;
  if($exp->cell_type->name ne $ds->cell_type->name){
    $error .= "CellType missmatch [RS/DS] " . $exp->cell_type->name.'|';
    $error .= $ds->cell_type->name;
  }

  if($exp->feature_type->name ne $ds->feature_type->name){
    $error .= "FeatureType missmatch [RS/DS] " . $exp->feature_type->name.'|';
    $error .= $ds->feature_type->name ."\n";
  }

  if(defined ($error) ){
    $error = "--- _compare_experiment_data_set ---\n" . $error;
    print_cached_objects($cfg, $tr, $dev, $error);
  }
}
#-------------------------------------------------------------------------------






################################################################################
#                           _compare_input_subset
################################################################################

=head2

  Name       : _compare_input_subset
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _compare_input_subset {
  my ($cfg, $tr_iss, $dev_iss, $tr, $dev) = @_;
  print_method();

  my $error = undef;
  my $tmp   = undef;

  $tmp = $tr_iss->compare_to($dev_iss,'-1');
  _check_tmp($tmp, $error);

  $tmp = $tr_iss->analysis->compare($dev_iss->analysis);
  if($tmp != 0){
    $error .= "Analysis differences\n";
  }

  $tmp = $tr_iss->cell_type->compare_to($dev_iss->cell_type,'-1');
  _check_tmp($tmp, $error);

  $tmp = $tr_iss->feature_type->compare_to($dev_iss->feature_type,'-1');
  _check_tmp($tmp, $error);


  if(defined ($error) ){
    $error = "--- InputSubset ---\n" . $error;
    print_cached_objects($cfg, $tr, $dev, $error);
  }
}


################################################################################
#                            _compare_experiment
################################################################################

=head2

  Name       : _compare_experiment
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
#experiment_id, name, experimental_group_id, date, primary_design_type, description, mage_xml_id

#Compare EXP linked to RS/IS
# Compare EXP Group

sub _compare_experiment {
  my ($cfg, $tr, $dev) = @_;
  print_method();

  my $error = undef;
  my $tmp   = undef;
  
  $tmp = $tr->{exp}->compare_to($dev->{exp},'-1');
  _check_tmp($tmp, $error);

  $tmp = $tr->{exp}->cell_type->compare_to($dev->{exp}->cell_type,'-1');
  _check_tmp($tmp, $error);

  $tmp = $tr->{exp}->feature_type->compare_to($dev->{exp}->feature_type,'-1');
  _check_tmp($tmp, $error);

  $tmp = $tr->{exp}->cell_type->compare_to($dev->{exp}->cell_type,'-1');
  _check_tmp($tmp, $error);

  if(defined ($error) ){
    $error = "--- Experiment ---\n" . $error;
    print_cached_objects($cfg, $tr, $dev, $error);
  }
}
#-------------------------------------------------------------------------------

################################################################################
#                         compare_experimental_group
################################################################################

=head2

  Name       : _compare_experimental_group
  Arg [1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
#experime

sub _compare_experimental_group {
  my ($cfg, $tr, $dev) = @_;
  print_method();

  my $error = undef;
  my $tmp   = undef;

  $tmp = $tr->{exp_group}->compare_to($dev->{exp_group},'-1');
  _check_tmp($tmp, $error);

  if(defined ($error) ){
    $error = "--- Experimental Group ---\n" . $error;
    print_cached_objects($cfg, $tr, $dev, $error);
  }
}
#-------------------------------------------------------------------------------
# 
# avoids creating an empty data strucutre
# flatens hash to string

sub _check_tmp {
  my ($tmp, $error) = @_;

  if (ref($tmp) eq 'HASH' and  keys %{$tmp}){
    foreach my $key (sort keys %{$tmp}){
      $error .= "$key -> $tmp->{$key}\n";
    }
  }
}

################################################################################
#                             _Get_DevDB_Adaptors
################################################################################

=head2

  Name       : _get_devDB_adaptors
  Arg [1]    : Config::Tiny
  Example    : _get_devDB_adaptors($cfg)
  Description: create all necessary adaptors to the tracking DB
  Returntype : none
  Exceptions : none
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _get_devDB_adaptors {
  my ($cfg) = @_;

# Tracking DB hidden from user, hence no get_TrackingAdaptor method.
# TrackingAdaptor->new() does not YET accept DBAdaptor object


  my $db_a = Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor->new (
      -user       => $cfg->{dev_db}->{user},
      -pass       => $cfg->{dev_db}->{pass},
      -host       => $cfg->{dev_db}->{host},
      -port       => $cfg->{dev_db}->{port},
      -dbname     => $cfg->{dev_db}->{dbname},
      -dnadb_user => $cfg->{dna_db}->{user},
      -dnadb_pass => $cfg->{dna_db}->{pass},
      -dnadb_host => $cfg->{dna_db}->{host},
      -dnadb_port => $cfg->{dna_db}->{port},
      -dnadb_name => $cfg->{dna_db}->{dbname},
    );


    $cfg->{dev_adaptors}->{ct} = $db_a->get_CellTypeAdaptor();
    $cfg->{dev_adaptors}->{ft} = $db_a->get_FeatureTypeAdaptor();
    $cfg->{dev_adaptors}->{an} = $db_a->get_AnalysisAdaptor();

    $cfg->{dev_adaptors}->{eg} = $db_a->get_ExperimentalGroupAdaptor();
  # get status_name: select all

    $cfg->{dev_adaptors}->{ex} = $db_a->get_ExperimentAdaptor();
    $cfg->{dev_adaptors}->{iss} = $db_a->get_InputSubsetAdaptor();

    $cfg->{dev_adaptors}->{rs} = $db_a->get_ResultSetAdaptor();
    $cfg->{dev_adaptors}->{rf} = $db_a->get_ResultFeatureAdaptor();

    $cfg->{dev_adaptors}->{fs} = $db_a->get_FeatureSetAdaptor();
    $cfg->{dev_adaptors}->{ds} = $db_a->get_DataSetAdaptor();
    $cfg->{dev_adaptors}->{af} = $db_a->get_AnnotatedFeatureAdaptor();

}
#-------------------------------------------------------------------------------
################################################################################
#                             _get_trackingDB_adaptors
################################################################################

=head2

  Name       : _get_trackingDB_adaptors
  Arg [1]    : Config::Tiny
  Example    : _get_trackingDB_adaptors($cfg)
  Description: create all necessary adaptors to the tracking DB
  Returntype : none
  Exceptions : none
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _get_trackingDB_adaptors {
  my ($cfg) = @_;

# Tracking DB hidden from user, hence no get_TrackingAdaptor method.
# TrackingAdaptor->new() does not YET accept DBAdaptor object

  $cfg->{tr_adaptors}->{tr} =
    Bio::EnsEMBL::Funcgen::DBSQL::TrackingAdaptor->new (
        -user       => $cfg->{efg_db}->{user},
        -pass       => $cfg->{efg_db}->{pass},
        -host       => $cfg->{efg_db}->{host},
        -port       => $cfg->{efg_db}->{port},
        -dbname     => $cfg->{efg_db}->{dbname},
        -species    => $cfg->{generic}->{species},
        -dnadb_user => $cfg->{dna_db}->{user},
        -dnadb_pass => $cfg->{dna_db}->{pass},
        -dnadb_host => $cfg->{dna_db}->{host},
        -dnadb_port => $cfg->{dna_db}->{port},
        -dnadb_name => $cfg->{dna_db}->{dbname},
        );

  my $db_a = $cfg->{tr_adaptors}->{tr}->db;

  $cfg->{tr_adaptors}->{ct} = $db_a->get_CellTypeAdaptor();
  $cfg->{tr_adaptors}->{ft} = $db_a->get_FeatureTypeAdaptor();
  $cfg->{tr_adaptors}->{an} = $db_a->get_AnalysisAdaptor();

  $cfg->{tr_adaptors}->{eg} = $db_a->get_ExperimentalGroupAdaptor();

  $cfg->{tr_adaptors}->{ex} = $db_a->get_ExperimentAdaptor();
  $cfg->{tr_adaptors}->{iss} = $db_a->get_InputSubsetAdaptor();

  $cfg->{tr_adaptors}->{rs} = $db_a->get_ResultSetAdaptor();
  $cfg->{tr_adaptors}->{rf} = $db_a->get_ResultFeatureAdaptor();

  $cfg->{tr_adaptors}->{fs} = $db_a->get_FeatureSetAdaptor();
  $cfg->{tr_adaptors}->{ds} = $db_a->get_DataSetAdaptor();
  $cfg->{tr_adaptors}->{af} = $db_a->get_AnnotatedFeatureAdaptor();
}


#################### Boulevard of broken dreams ###################
############ ( Old code marked for removal ) #####################

=cut

