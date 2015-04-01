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
use Bio::EnsEMBL::Funcgen::CellType;

use Bio::EnsEMBL::Utils::SqlHelper;


use constant CONFIG  => 'migration.config.ini';
select((select(STDOUT), $|=1)[0]);

main();

sub main {

  my $cfg = Config::Tiny->new;
     $cfg = Config::Tiny->read(CONFIG);
  # print Dumper($cfg);die;

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



sub _unlock_meta_table {
  my	($cfg, $dbh_name)	= @_;

  $cfg->{$dbh_name}->do("DELETE FROM meta WHERE meta_id = $cfg->{lock_id}");
}

sub _lock_meta_table {
  my	($cfg, $dbh_name)	= @_;

  $dbh_name =~ /_(\w*)/;
  my $db = $1;
  throw("Wrong dbh name format: $dbh_name") if(!defined $db);

  # Once Nathan is finished adding pipeline status to meta table, check for those as well
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
#                           _Connect_To_ReleaseDB
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
#                            _Get_Current_Data_Sets
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


=cut

#-------------------------------------------------------------------------------
sub _migrate {
  my ($cfg) = @_;

  my ($tr, $dev) = ({},{});
  my $flag_rf = $cfg->{generic}->{regulatory_feature};
  
  DATASET:
  for my $tr_ds(@{$cfg->{release}->{data_set}}) {
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

  my $dev_ds = $cfg->{dev_adaptors}->{ds}->fetch_by_name($tr->{ds}->name);
  if(defined $dev_ds){ 
    $dev->{ds} = $dev_ds;
    _compare_data_set($cfg, $tr->{ds}, $dev->{ds});
    #avoid $dev->{ds} = undefined
  }


  $tr->{fs} = $tr->{ds}->product_FeatureSet;
  my $dev_fs = $cfg->{dev_adaptors}->{fs}->fetch_by_name($tr->{fs}->name);
  if(defined $dev_fs){
    _compare_feature_set($cfg, $tr, $dev);
    _compare_feature_set_data_set($cfg, $dev_fs, $dev->{ds}, $tr, $dev);
  }

  $tr->{rs} = $tr->{ds}->get_supporting_sets;
  foreach my $tr_rs (@{$tr->{rs}}){

    # $cfg->{dba_tracking}->is_stored_and_valid('Bio::EnsEMBL::Funcgen::ResultSet', $tr_rs);

    my $dev_rs = $cfg->{dev_adaptors}->{rs}->fetch_by_name($tr_rs->name);
    if(defined $dev_rs){
      _compare_result_sets($cfg, $tr_rs, $dev_rs, $tr, $dev);
      _compare_result_set_data_set($cfg, $dev_rs, $dev->{ds}, $tr, $dev);
      push(@{$dev->{rs}}, $dev_rs);
    }

    $tr->{iss} = $tr_rs->get_support;
    foreach my $tr_iss (@{$tr->{iss}}){
      my $dev_iss = $cfg->{dev_adaptors}->{iss}->fetch_by_name($tr_iss->name);
      if(defined $dev_iss){
        _compare_input_subset($tr_iss, $dev_iss, $tr, $dev);
        _compare_input_subset_data_set($cfg, $dev_iss, $dev->{ds}, $tr, $dev);
        push(@{$dev->{iss}}, $dev_iss);
      }
    }

    $tr->{exp} = $tr_rs->experiment;
    my $dev_exp = $cfg->{dev_adaptors}->{ex}->fetch_by_name($tr->{exp}->name);
    if(defined $dev_exp){
      $dev->{exp} = $dev_exp;
      _compare_experiment($cfg, $tr, $dev);
      _compare_experiment_data_set($cfg, $dev->{exp}, $dev->{ds}, $tr, $dev);
    }

    $tr->{exp_group} = $tr->{exp}->experimental_group;
    my $eg_name = $tr->{exp_group}->name;
    my $dev_exp_group = $cfg->{dev_adaptors}->{eg}->fetch_by_name($eg_name);

    if(defined $dev_exp_group){
      $dev->{exp_group} = $dev_exp_group;
      _compare_experimental_group($cfg, $tr, $dev);
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

=cut

#-------------------------------------------------------------------------------
sub _migrate_cell_feature_type {
  my ($cfg, $tr, $dev) = @_;

  $tr->{ct} = $tr->{ds}->cell_type;
  $tr->{ft} = $tr->{ds}->feature_type;

  my $ct_name = $tr->{ct}->name;

  my $dev_ct = $cfg->{dev_adaptors}->{ct}->fetch_by_name($ct_name);

  if(defined $dev_ct){
    $dev->{ct} = $dev_ct;
    _compare_cell_type($cfg, $tr, $dev);
  }
  else{
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
sub print_cached_objects {
  my ($cfg, $tr, $dev, $error) = @_;

  say "--- Error --- ";
  say $error;

  say "\n--- Tracking DB: ".$cfg->{efg_db}->{dbname} ."---";
  _iterate($tr);

  say "\n--- Dev DB: ".$cfg->{dev_db}->{dbname} ."---";
  _iterate($dev);
}
#-------------------------------------------------------------------------------

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
          say "\t\t$attr: ".$object->$method->$attr;
        }
      }
    }
  }
  die;
}

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

sub _migrate_regulatory_feature {
  throw "Not implemented yet";
}
#-------------------------------------------------------------------------------



# --------------- meta data ----------------

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
sub _add_control_experiment {
  my ($cfg, $diffs) = @_;

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
sub _store_experimental_group {
  my ($cfg, $tr, $dev) = @_;

  $dev->{exp_group} = create_Storable_clone(
    $tr->{exp_group}  
  );
  $dev->{exp_group} = @{$cfg->{dev_adaptors}->{eg}->store($dev->{exp_group})};
}
#-------------------------------------------------------------------------------

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
sub _store_experiment {
  my ($cfg, $tr, $dev) = @_;

  $dev->{exp}   = create_Storable_clone($tr->{exp},{
    -cell_type          => $dev->{ct},
    -experimental_group => $dev->{exp_group},
    -feature_type       => $dev->{ft},
    });
  ($dev->{exp}) = @{$cfg->{dev_adaptors}->{ex}->store($dev->{exp})};

  my $states = $tr->{exp}->get_all_states;
  _add_states($cfg, $states, $dev->{exp});

}
#-------------------------------------------------------------------------------

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
sub _store_input_subset {
  my ($cfg, $tr_iss, $tr, $dev) = @_;

  my $analysis = _store_analysis($cfg, $tr_iss->analysis);

  my $dev_iss  = create_Storable_clone($tr_iss, {
      -analysis     => $analysis,
      -cell_type    => $dev->{ct},
      -experiment   => $dev->{exp},
      -feature_type => $dev->{ft},
      });
  
  ($dev_iss) = @{$cfg->{dev_adaptors}->{iss}->store($dev_iss)};

  my $states = $tr_iss->get_all_states;
  _add_states($cfg, $states, $dev_iss);
  $cfg->{dev_adaptors}->{iss}->store_states($dev_iss);

  push(@{$dev->{iss}}, $dev_iss);
}
#-------------------------------------------------------------------------------

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
sub _store_result_set {
  my ($cfg, $tr_rs, $tr, $dev) = @_;

  my $analysis = _store_analysis($cfg, $tr_rs->analysis);

  my $dev_rs  = create_Storable_clone($tr_rs, {
      -analysis     => $analysis,
      -cell_type    => $dev->{ct},
      -feature_type => $dev->{ft},
      -support      => $dev->{input_sets},
      });
  
  ($dev_rs) = @{$cfg->{dev_adaptors}->{rs}->store($dev_rs)};

  my $states = $tr_rs->get_all_states;
  _add_states($cfg, $states, $dev_rs);
  $cfg->{dev_adaptors}->{iss}->store_states($dev_rs);

  push(@{$dev->{rs}}, $dev_rs);
}

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
sub _store_data_set {
  my ($cfg, $tr, $dev);
  $dev->{ds} = create_Storable_clone($tr->{ds},{
        -feature_set      => $dev->{feature_set},
        -supporting_sets  => $dev->{input_sets},
        });
    ($dev->{data_set}) =  @{$cfg->{dev_adaptors}->{data_set}->store($dev->{data_set})};

}



sub _store_analysis {
  my ($cfg, $tr_anal ) = @_;

  my $logic_name   = $tr_anal->logic_name;
  my $dev_anal = $cfg->{dev_adaptors}->{an}->fetch_by_logic_name($logic_name);

  if(!defined $tr_anal){
    $dev_anal = _create_storable_analysis($cfg, $tr_anal);
  ($dev_anal) = @{$cfg->{dev_adaptors}->{an}->store($dev_anal)};
  }
  return $dev_anal;
}

#-------------------------------------------------------------------------------

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
sub _create_storable_analysis {
  my ($cfg, $analysis) = @_;

  my $dev_analysis;
  $dev_analysis = bless({%{$analysis}}, ref($analysis));
  $dev_analysis->{adaptor} = undef;
  $dev_analysis->{dbID}    = undef;
  my $dbID    = $cfg->{dev_adaptors}->{an}->store($dev_analysis);
  $dev_analysis = $cfg->{dev_adaptors}->{an}->fetch_by_dbID($dbID);
  return($dev_analysis);
}

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

  if(! defined $dev->{exp_group}){
      _compare_experiment($cfg, $tr, $dev);
      _compare_experiment_data_set($cfg, $dev->{exp}, $dev->{ds}, $tr, $dev);
    
  }

  else {
    say "Storing: " . $tr->{exp_group}->name;
    _store_experimental_group($cfg, $tr, $dev);
  }
  if(! defined $dev->{exp}){
    say "Storing: " . $tr->{exp}->name;
    _store_experiment($cfg, $tr, $dev);
  }
  if(! defined $dev->{iss}){
    for my $tr_iss(@{$tr->{iss}}){
      say "Store ISS " . $tr_iss->name;
      _store_input_subset ($cfg, $tr_iss, $tr, $dev);
    }
  }

  if( !defined $dev->{result_sets} && defined $tr->{result_sets} ){
    foreach my $tr_rs (@{$tr->{result_sets}}) {
      say "Store ResultSet";
      _store_result_set($cfg, $tr_rs, $tr, $dev);
    }
  }

  if(! defined $dev->{data_set}){
      
    }
  #*    From flatfile/direct SQL, see confluence
  #    my $AR_annotated_features =
  #      $cfg->{tr_adaptors}->{af}->fetch_all_by_FeatureSets([$tr_fset]);
}

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
sub _add_states {
  my ($cfg, $cached_states, $object) = @_;

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
sub _get_dev_states {
  my ($cfg) = @_;

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

=cut

#-------------------------------------------------------------------------------
sub _compare_cell_type {
  my ($cfg, $tr, $dev) = @_;
  
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
#                           _Compare_Feature_Type
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
sub _compare_feature_type {
  my ($cfg, $tr, $dev) = @_;
  
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

  my $error = undef;

  if($rs->cell_type->dbID != $ds->cell_type->dbID){
    $error .= "CellType missmatch [RS/DS] " . $rs->cell_type->dbID.'|';
    $error .= $ds->cell_type->dbID;
  }

  if($rs->feature_type->dbID != $ds->feature_type->dbID){
    $error .= "FeatureType missmatch [RS/DS] " . $rs->feature_type->dbID.'|';
    $error .= $ds->feature_type->dbID ."\n";
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

  my $error = undef;

  if($fs->cell_type->dbID != $ds->cell_type->dbID){
    $error .= "CellType missmatch [FS/DS] " . $fs->cell_type->dbID.'|';
    $error .= $ds->cell_type->dbID;
  }

  if($fs->feature_type->dbID != $ds->feature_type->dbID){
    $error .= "FeatureType missmatch [FS/DS] " . $fs->feature_type->dbID.'|';
    $error .= $ds->feature_type->dbID ."\n";
  }

  if($fs->experiment->dbID != $ds->experiment->dbID){
    $error .= "Experiment missmatch [FS/DS] " . $fs->cell_type->dbID.'|';
    $error .= $ds->cell_type->dbID;
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
  Description:
  Returntype :
  Exceptions :
  Caller     : general
  Status     : At risk - not tested

=cut

#-------------------------------------------------------------------------------
sub _compare_input_subset_data_set {
  my ($cfg, $iss, $ds, $tr, $dev) = @_;

  my $error = undef;

  if($iss->cell_type->dbID != $ds->cell_type->dbID){
    $error .= "CellType missmatch [ISS/DS] " . $iss->cell_type->dbID.'|';
    $error .= $ds->cell_type->dbID;
  }

  if($iss->feature_type->dbID != $ds->feature_type->dbID){
    $error .= "FeatureType missmatch [RS/DS] " . $iss->feature_type->dbID.'|';
    $error .= $ds->feature_type->dbID ."\n";
  }

  if(defined ($error) ){

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

  my $error = undef;
  if($exp->cell_type->dbID != $ds->cell_type->dbID){
    $error .= "CellType missmatch [RS/DS] " . $exp->cell_type->dbID.'|';
    $error .= $ds->cell_type->dbID;
  }

  if($exp->feature_type->dbID != $ds->feature_type->dbID){
    $error .= "FeatureType missmatch [RS/DS] " . $exp->feature_type->dbID.'|';
    $error .= $ds->feature_type->dbID ."\n";
  }

  if(defined ($error) ){
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
  my ($cfg,$ tr_iss, $dev_iss, $tr, $dev) = @_;

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

ddd
# ################################################################################
# #                            _Compare_Cell_Type
# ################################################################################

# =head2

#   Name       :
#   Arg [1]    :
#   Example    :
#   Description:
#   Returntype :
#   Exceptions :
#   Caller     : general
#   Status     : At risk - not tested

# =cut

# #-------------------------------------------------------------------------------
# #cell_type_id, name, display_label, description, gender, efo_id, tissue,
# sub _compare_cell_type {
#   my ($name, $tr_ds, $dev_ds, $tr_ct, $dev_ct) = @_;

#   my $tmp = $tr_ds->compare_to($dev_ds,'-1');
#   if(defined _check_tmp($tmp)){
#     my $msg;
#     $msg = "CellType "
#   }
  
#   return;
# }
#-------------------------------------------------------------------------------

# ################################################################################
# #                             _Compare_feature_type
# ################################################################################


# #-------------------------------------------------------------------------------
# sub _compare_feature_type {
#   my ($diffs, $tr_ds, $dev_ds, $tr_ft, $dev_ft) = @_;

#   my $tmp = $tr_ft->compare_to($dev_ft,'-1');
#   _check_tmp($diffs, $tmp, $tr_ds->name, $tr_ds->feature_type->name);

#   if(defined $tr_ft->analysis){
#     my $tr_analysis  = $tr_ft->analysis;
#     my $dev_analysis = $dev_ft->analysis;

#     $tr_ft->analysis->compare_to($dev_ft->analysis, '-1');
#     _check_tmp($diffs, $tmp, , 'analysis');
#   }
#   return $diffs;
# }
# #-------------------------------------------------------------------------------

# #-------------------------------------------------------------------------------
# #analysis_id, created, logic_name, db, db_version, db_file, program, program_version, program_file,
# # parameters, module, module_version, gff_source, gff_feature
# ################################################################################
# #                           _Compare_Analysis
# ################################################################################

# #-------------------------------------------------------------------------------
# sub _compare_analysis {
#   my ($tr_analysis, $dev_analysis) = @_;

#   unless($tr_analysis->compare($dev_analysis) == 0){
#     return('Tr: '.$tr_analysis->dbID . ' - Dev: ' . $dev_analysis->dbID);
#   }
# }
# #-------------------------------------------------------------------------------
# # creates a hash containing the differences, eg:
# # $diffs->{result_set}->{analysis} = name1 - name2
# # avoids creating an empty data strucutre
# sub _check_tmp {
#   my ($tmp) = @_;

#   if (ref($tmp) eq 'HASH' and  keys %{$tmp}){
#     return $tmp;
#   }
#   return undef;
# }

################################################################################
# #                         _Compare_Experimental_Group
# ################################################################################

# =head2

#   Name       :
#   Arg [1]    :
#   Example    :
#   Description:
#   Returntype :
#   Exceptions :
#   Caller     : general
#   Status     : At risk - not tested

# =cut

# #-------------------------------------------------------------------------------
# #experimental_group_id, name, location, contact, description, url, is_project
# #-------------------------------------------------------------------------------
# sub _compare_experimental_group {
#   my ($diffs, $tr, $dev) = @_;
#   my $tmp =$tr->{experimental_group}->compare_to($dev->{experimental_group},'-1');

#   if(keys %{$tmp}) {
#     $diffs->{experimental_group} = $tmp;
#     return $diffs;
#   }
# }
# #-------------------------------------------------------------------------------

#sub _check_and_print_diffs {
#   my ($tr, $dev, $diffs) = @_;

#   foreach my $key (sort keys %{$diffs}){
#     next if($key eq 'stored');
#     say "Mismatches detected. First array element is tracking data, second dev data";
#     print dump_data($diffs,1,1);
#     _print_info($tr, 'Tracking');
#     _print_info($dev, 'Dev');
#     say "Exiting.....";
#     die;
#   }

# }
# sub _print_info {
#   my ($db_objects, $db) = @_;

#   say "************ Currently stored in $db cache ************ ";
#   foreach my $type (sort keys %{$db_objects}){

#     my $string;
#     if ( $type =~ /_/ ){
#       my @type = split(/_/,$type);
#       for my $tmp (@type) {
#         $string .= ucfirst($tmp);
#       }
#     }
#     else{
#       $string = ucfirst($type);
#     }

#     if(defined $db_objects->{$type}){
#       # arrays
#       if($type =~ /input_sets|result_sets|input_subsets/){
#         say "::: $string";
#         for my $is(@{$db_objects->{$type}}){
#           say "name:\t". $is->name;
#           say "dbID:\t". $is->dbID;
#           if($type =~ /input_sets|result_sets/){
#             say "::: $string Analysis";
#             say "name:\t" . $is->analysis->logic_name;
#             say "dbID:\t" . $is->analysis->dbID;
#           }
#         }
#       }
#       else {
#         say "::: $string";
#         if ($type eq 'analysis'){
#           say "name:\t" . $db_objects->{$type}->logic_name;
#         }
#         else {
#           say " name:\t" . $db_objects->{$type}->name;
#         }

#         say " dbID:\t" . $db_objects->{$type}->dbID;
#       }
#     }
#     else{
#       say "::: $string";
#       say "__Undefined__";
#     }
#     say '';
#   }

#   say "***************** End of $db cache ******************\n";
# }


#linked to input set
## status_name (The status table also needs to be considered for all table which have status entries.)
##* Check where to get status_name
# ---------------------------------------------------------------------

# Tries to retrieve dev object using unique constraints
# If the object exists in dev, compare it to the tracking object
# Differences are stored in diffs hash

# sub _validate_dev {
#     my ($cfg ,$tr, $dev, $name, $diffs) = @_;

#     $dev->{experiment} =
#       $cfg->{dev_adaptors}->{experiment}->fetch_by_name($tr->{experiment}->name);
#     if(defined $dev->{experiment}){
#       _compare_experiment($diffs, $tr, $dev);
#     }
#     else{
#       $dev->{experiment}   = create_Storable_clone(
#         $tr->{experiment},
#         {-EXPERIMENTAL_GROUP => $dev->{experimental_group}});
#       ($dev->{experiment}) =  @{$cfg->{dev_adaptors}->{experiment}->store($dev->{experiment})};
#       $cfg->{stored_objects}->{experiment} = $dev->{experiment};
#     }


#     # InputSubset could be control.
#     if(defined $tr->{input_subsets}){
#       for my $tr_iss (@{$tr->{input_subsets}}){
#         my $name = $tr_iss->name;
#         my $exp  = $tr_iss->experiment;
#         my $dev_exp;

#         if($exp->name ne $dev->{experiment}->name){
#           if(!$tr_iss->is_control){
#             throw("Subset $name has a different Experiment, but is not control");
#           }
#           $dev_exp = $cfg->{dev_adaptors}->fetch_by_name($exp->name);
#           if(!defined $dev_exp){
#             throw("Experiment not available in devDB");
#           }
#         }
#         else{
#           $dev_exp = $dev->{experiment};
#         }

#         my ($dev_iss) =
#           @{$cfg->{dev_adaptors}->{input_subset}->fetch_by_name_and_experiment($name, $dev_exp)};
#           if(defined $dev_iss){


#             _compare_input_subset($diffs, $tr_iss, $dev_iss, $tr, $dev);
#             push(@{$dev->{input_subsets}}, $dev_iss);
#           }

#       }
#     }


# #UNIQUE KEY `unique_idx` (`name`,`analysis_id`,`feature_type_id`,`cell_type_id`,`feature_class`)
#     my $flag = 0;
#     if(defined $tr->{result_sets} ){
#       $flag = 1;
#       for my $tr_result_set(@{$tr->{result_sets}}){
#         my @dev_result_sets = @{$cfg->{dev_adaptors}->{result_set}->fetch_all_by_name(
#             $tr_result_set->name,
#             $dev->{feature_type},
#             $dev->{cell_type},
#             $dev->{analysis},
#             )};

#         my $count = scalar(@dev_result_sets);
#         if($count > 1){
#           throw("Only expecting 1 ResultSet here, not $count");
#         }
#         if($count == 1){
#           my $dev_result_set = $dev_result_sets[0];
#           _compare_result_set($diffs, $tr_result_set, $dev_result_set, $tr, $dev);
#           push(@{$dev->{result_sets}},$dev_result_set);
#         }
#       }

#     }
#     if(defined $tr->{input_sets}){

#       $flag = 1;
#       for my $tr_input_set( @{$tr->{input_sets}}) {
#         my $dev_input_set = $cfg->{dev_adaptors}->{input_set}->fetch_by_name($tr_input_set->name);

#         if(defined $dev_input_set){
#           _compare_input_set($diffs, $tr_input_set, $dev_input_set, $tr, $dev,'input_set');
#           push(@{$dev->{input_sets}},$dev_input_set);
#         }

#       }
#     }
#     if($flag == 0){throw("No InputSet & ResultSet for: " . $tr->{data_set}->name)}


#     if(defined $tr->{feature_set}){
#       $dev->{feature_set} = $cfg->{dev_adaptors}->{feature_set}->fetch_by_name($tr->{feature_set}->name);
#       if(defined $dev->{feature_set}){
#         _compare_feature_set($diffs, $tr, $dev);
#       }
#     }
#     else{throw ("No FeatureSet for: ".$tr->{data_set}->name)}

#     $dev->{data_set} =
#         $cfg->{dev_adaptors}->{data_set}->fetch_by_name($tr->{data_set}->name);
#     if( defined $dev->{data_set}){
#         _compare_data_set($diffs, $tr, $dev);
#     }
# }
# sub _merge_diffs {
#   my ($diffs, $tmp) = @_;
#   foreach my $key (sort keys %{$tmp} ) {
#     if( exists $diffs->{$key} ) {
#       throw("Key [$key] is already present in diffs!");
#     }
#     else {
#       $diffs->{$key} = $tmp->{$key};
#     }
#   }
# }
# sub _add_metadata {
#   my ($cfg, $tr, $dev, $diffs) = @_;

#   _metadata_migration($cfg, 'cell_type',          $tr, $dev, $diffs);
#   _metadata_migration($cfg, 'feature_type',       $tr, $dev, $diffs);
#   _metadata_migration($cfg, 'experimental_group', $tr, $dev, $diffs);

# }
# ################################################################################
# #                             _MetaData_Migration
# ################################################################################

# =head2

#   Name       :
#   Arg [1]    :
#   Example    :
#   Description:
#   Returntype :
#   Exceptions :
#   Caller     : general
#   Status     : At risk - not tested
#   ToDo       : using proper ref() instead of manual one
#                Check if all mandatory args are defined
#                Get nj1's untility for fetch_by_(logic)_name

# =cut

# #-------------------------------------------------------------------------------
# sub _metadata_migration {
#   my ($cfg, $type, $tr, $dev, $diffs) = @_;

#   my $dev_object;

#     my $name = $tr->{$type}->name();
#     $dev_object = $cfg->{dev_adaptors}->{$type}->fetch_by_name($name);

#   if(! defined $dev_object) {
#     $dev_object = create_Storable_clone($tr->{$type});
#     ($dev_object) = @{$cfg->{dev_adaptors}->{$type}->store($dev_object)};
#     $dev->{$type} = $dev_object;
#   }
#   else {
#     $dev->{$type} = $dev_object;

#     my $tmp;
#     if($type eq 'cell_type'){
#       $tmp = _compare_cell_type($diffs, $tr, $dev);
#     }
#     elsif($type eq 'experimental_group'){
#       $tmp = _compare_experimental_group($diffs, $tr, $dev);
#     }
#     elsif($type eq 'feature_type'){
#       $tmp = _compare_feature_type($diffs, $tr, $dev);
#     }
#     else{
#       throw('Type: \''.$type ."' not known. Add it above");
#     }

#     if(ref($tmp) eq 'HASH' and keys %{$tmp}){
#       _merge_diffs($diffs, $tmp);
#     }
#   }
#   return();
# }
# ################################################################################
# #                            _Get_Input_Set
# ################################################################################

# =head2

#   Name       : _get_input_set
#   Arg [1]    : Bio::EnsEMBL::Funcgen::DataSet
#   Example    : _get_input_set($data_set)
#   Description: Retrieves the supporting InputSets for this DataSet
#   Returntype :
#   Exceptions :
#   Caller     : general
#   Status     : At risk - not tested

# =cut

# #-------------------------------------------------------------------------------
# # ???? One or more supporting InputSets possible?
# sub _get_input_set {
#   my ($set) = @_;

#   my @input_sets;

#   if(ref($set) ne 'Bio::EnsEMBL::Funcgen::DataSet'){
#     throw("Must be Bio::EnsEMBL::Funcgen::DataSet, not: " . ref($set));
#   }
#   @input_sets = @{$set->get_supporting_sets('input')};

#   my $amount = scalar(@input_sets);
#   if ($amount != 1) {
#     my $msg = "Expecting only 1 InputSet, not $amount";
#     warn($msg);
#   }

#   return(\@input_sets);
# }
# #-------------------------------------------------------------------------------

# Checks if all InputSets are present in both structures

# sub _compare_data_and_result_input_sets {
#   my ($result_input_sets, $data_input_subsets) = @_;

# # Same size mandatory, otherwise for loop won't work
#   if(scalar(@{$result_input_sets}) != scalar(@{$data_input_subsets})) {
#     say "scalar";
#     say scalar(@{$result_input_sets});
#     say scalar(@{$data_input_subsets});
#     say "";
#     say dump_data($result_input_sets,1,1);
#     say "-------- ********** :::::: ********** -------";
#     say dump_data($data_input_subsets,1,1);

#     throw("Mismatch between InputSets linked to ResultSets and DataSet");
#   }
#   for my $data_is(@{$data_input_subsets}){
#     my $flag = 0;
#     for my $result_is (@{$result_input_sets}) {
#       if($result_is->dbID == $data_is->dbID){
#         $flag = 1;
#       }
#     }
#     if($flag == 0){
#       throw("InputSet " . $data_is->dbID .'[dbID] not found in ResultSets')
#     }
#   }
# }

# ################################################################################
# #                            _get_result_sets
# ################################################################################

# =head2

#   Name       : _get_result_sets
#   Arg [1]    :
#   Example    :
#   Description:
#   Returntype : ARRAY_REF
#   Exceptions :
#   Caller     : general
#   Status     : At risk - not tested

# =cut

# #-------------------------------------------------------------------------------
# sub _get_result_sets {
#   my ($data_set) = @_;
#   my $result_set;

#   my @result_sets = @{$data_set->get_supporting_sets('result',)};

#   my $iss_dbIDs = {};
#   for my $result_set(@result_sets){
#     my @input_subsets = @{$result_set->get_support};

#     # InputSets linked to a ResultSet should not be identical
#     # This should currently not happen, adjust code if it does
#     for my $input_subset (@input_subsets){
#       if(exists $iss_dbIDs->{$input_subset->dbID}){
#         throw("Found duplicate InputSubsets linked to " . $result_set->name);
#       }
#       $iss_dbIDs->{$input_subset->dbID}++;
#     }
#   }

#   # my @previous_input_sets;

#   # if(@result_sets and scalar(@result_sets) > 0){
#   #   for my $result_set (@result_sets) {

#   #     my @supporting_sets = @{$result_set->get_support};
#   #     for my $sset(@supporting_sets){
#   #       if(ref($sset) ne 'Bio::EnsEMBL::Funcgen::InputSubset'){
#   #         throw("Only Bio::EnsEMBL::Funcgen::InputSubset supported, not " . ref($sset));
#   #       }
#   #       # InputSets linked to a ResultSet should not be identical
#   #       # This should currently not happen, adjust code if it does
#   #       for my $previous_input_set (@previous_input_sets){
#   #         if($sset->dbID eq $previous_input_set->dbID){
#   #           throw("Same InputSet");
#   #         }
#   #       }
#   #       push(@previous_input_sets, $sset);
#   #     }
#   #   }
#   # }
#   # return(\@result_sets, \@previous_input_sets);
# }
# #-------------------------------------------------------------------------------
# Test if InputSet is already stored in devDB
# If it is stored, find out why
# might be worth thinking about caching
# sub _test_input_sets {
#   my ($cfg, $tr_input_sets, $tr_ds) = @_;

#   for my $tr_is(@{$tr_input_sets}){
#     my $dev_is = $cfg->{dev_adaptors}->{input_set}->fetch_by_name($tr_is->name);
#     if(defined $dev_is){
#       my $dev_dss = $cfg->{dev_adaptors}->{data_set}->fetch_all_by_supporting_set($dev_is);
#       if(scalar @{$dev_dss} != 1){
#         say dump_data($dev_dss,1,1);
#         say scalar @{$dev_dss};
#         die;
#       }
#       my $dev_ds    = $dev_dss->[0];
#       my $dev_peak_caller = _identfiy_peak_caller($dev_ds->name);
#       my $tr_peak_caller  = _identfiy_peak_caller($tr_ds->name);

#       if($dev_peak_caller ne $tr_peak_caller){
#         my $name  = $tr_is->name;
#         my $ds_names = $tr_ds->name .'/'. $dev_ds->name ;
#         my $pc = "$dev_peak_caller / $tr_peak_caller";

#         throw("InputSet '$name' linked to 2 DataSets($ds_names). Peakcallers: $pc");
#       }
#       die;
#       #DataSet->name == FeatureSet->name
#       #DataSet->fetch_all_by_FeatureSet ()?
#     }
#   }
# }

# sub _identfiy_peak_caller {
#   my ($string) = @_;

#   $string = lc($string);
#   my $peak_caller;

#   if($string =~ /_ccat_/){
#     $peak_caller = 'CCAT';
#   }
#   elsif($string =~ /swembl/ ) {
#     $peak_caller = 'SWEmbl';
#   }
#   else{
#     $peak_caller = undef;
#   };

#   return($peak_caller);
# }
# 

# sub _get_tracking_release_objects {
#   my ($cfg, $tr) = @_;

#   $tr->{feature_set}  = $tr->{data_set}->product_FeatureSet();
#   $tr->{cell_type}    = $tr->{feature_set}->cell_type;
#   $tr->{feature_type} = $tr->{feature_set}->feature_type;


#   # Check if all metadata is present
#   foreach my $object (sort keys %{$tr}){
#     if(! defined $tr->{$object}){
#       throw("Could not fetch '$object' for DataSet: ".$tr->{data_set}->name);
#     }
#   }
# # Why was this?
#   if($tr->{feature_type}->class eq 'Segmentation State'){
#     throw('FeatureType - Segmentation has an analysis linked. This '.
#         'should probably be compared to FeatureSet Analysis.');
#   }
#   # say __LINE__ ": FeatureType class: " .$tr->{feature_type}->class;

#   # Only ResultSets
#   my $supporting_result_sets = $tr->{data_set}->get_supporting_sets;

#   my $supporting_sets = [];
#   for my $srs(@$supporting_result_sets){
#     my $input_subsets = $srs->get_support;
#     for my $iss(@$input_subsets){
#      push($supporting_sets, $iss);
#     }
#   }
# for my $ss(@$supporting_sets){
#   say ref($ss);
# }
# die;

#   my $result_set_input_subsets = undef;
#   ($tr->{result_sets}, $result_set_input_subsets)  = _get_result_sets($tr); 

#   my $data_input_subsets = $tr->{data_set}->get_supporting_sets('input');
#   if(!defined $data_input_subsets->[0]){
#     say 'Line: ' . __LINE__;
#     _print_info($tr,'Tracking');
    
#   }

#   if(! defined $data_input_subsets){
#     throw('No InputSet linked to DataSet: '. $tr->{data_set}->name)
#   }

#   if( scalar( @{$result_set_input_subsets}) and scalar(@{$data_input_subsets})) {
#     _compare_data_and_result_input_sets($result_set_input_subsets, $data_input_subsets);
#   }

#   $tr->{input_sets} = $data_input_subsets;

#   $tr->{input_subsets} = _get_input_subsets($cfg, $tr->{input_sets});



#   ($tr->{experiment}, $tr->{experimental_group}) =
#    _compare_inputset_experiments($cfg, $data_input_subsets);
# }

# sub _get_input_subsets {
#   my ($cfg, $input_sets) = @_;

#   my @subsets;
#   for my $is (@{$input_sets}){
#     # !!!!!! Array !!!!!!!!!!
#     my $tmp_subsets = $cfg->{tr_adaptors}->{iss}->fetch_all_by_InputSet($is);

#     for my $tmp_subset(@{$tmp_subsets}){
#       for my $stored_subset (@subsets){
#         if($stored_subset->dbID == $tmp_subset->dbID){
#           throw("Duplicate InputSubset".$stored_subset->name. $tmp_subset->name);
#         }
#       }
#       push(@subsets, $tmp_subset);
#     }

#   }
#   return(\@subsets);
# }

=head 2
# DataSets are the starting point in the trackingDB, but the insert into dev starts
# with Experiment (API constraints)

# -- Supporting ResultSets --
# Multiple ResultSets can be linked to a DataSet.
# The InputSets linked to these ResultSets must be the same as the InputSets
# linked to the DataSet directly.
# 1. Compare all Experiments from all InputSets to each other. Throw if there is a mismatch
# 2. Compare all experiments from each Subset to the one from the InputSet it comes from.
#    If the Experiment does not exist, it is likely to be a control and should be added to
#    the devDB

# =cut

# sub _compare_inputset_experiments {
#   my  ($cfg, $input_sets )  = @_;

#   if(defined $input_sets and scalar(@{$input_sets}) > 0 ){

# # Test if all experiments are identical between InputSets
# # Having the 2 for loops creates redundant tests, including comparing the same
# # InputSet, but as we usually only test 2, max 4, the cleaner writing got
# # presedence
#     for my $input_set (@{$input_sets}){
#       my $exp = $input_set->get_Experiment;

#       for my $input_set_2 (@{$input_sets}){
#         my $exp_2 = $input_set->get_Experiment;

#         if($exp->dbID != $exp_2->dbID){
#           say '1: Name: '.$input_set->name.'dbID: '.$input_set->dbID;
#           say '2: Name: '.$input_set_2->name.'dbID: '.$input_set_2->dbID;
#           throw("InputSets belong to different Experiments");
#         }
#       }
#       my @subsets = @{$input_set->get_InputSubsets};

#       for my $subset(@subsets){
#         my $ss_exp = $subset->experiment;
#         if($ss_exp->dbID != $exp->dbID){
#           if ($ss_exp->is_control != 1){
#             say 'Subset dbID: '   . $ss_exp->dbID . 'Name: ' . $ss_exp->name;
#             say 'InputSet dbID: ' . $exp->dbID  . 'Name: ' . $exp->name;
#             throw("Experiment from InputSubset differs from Experiment in InputSet");
#           }
#           else {
#             push(@{$cfg->{add_control_exp}}, $ss_exp);
#           }
#         } # exp_id dont match
#       } # for subset
#     } # input_set
#   } # defined input_sets

# # tested that all names are the same
# #return $input_sets->[0]->name;
# if(! defined $input_sets->[0]){
#   say 'Line: ' . __LINE__;
#   print dump_data($input_sets,1,1);
  
# }
#   my $experiment  = $input_sets->[0]->get_Experiment;
#   my $exp_group   = $input_sets->[0]->get_Experiment->experimental_group;
#   return($experiment, $exp_group);
# } ## --- end sub _compare_inputset_experiments
# sub _migrate_regulatory_feature {
#   my ($cfg, $tr_ds) = @_;

#   my $dev = {};
#   my $ds_diffs = {};

#   my $ds_name = $tr_ds->name;

#   # DS in dev?
#   my $dev_ds = $cfg->{dev_adaptors}->{ds}->fetch_by_name($tr_ds->name);
#   if(defined $dev_ds){
#     _compare_data_set($ds_diffs, $tr_ds->name, 'CellType');
#     $dev->{data_set} = $dev_ds;
#   }

#   # Fetch all supporting sets
#   for my $tr_fset (@{$tr_ds->get_supporting_sets}){

#     # Make sure the supporting set is indeed a FeatureSet
#     $cfg->{dba_tracking}->is_stored_and_valid('Bio::EnsEMBL::Funcgen::FeatureSet', $tr_fset);

#     if($tr_fset->cell_type->name ne $tr_ds->cell_type->name){
#       my $msg;
#       $msg .= "[Tr] FeatureSet [" .$tr_fset->name. "] is linked to a different CellType [";
#       $msg .= $tr_fset->cell_type->name ."] than tracking DataSet object [";
#       $msg .= $tr_ds->cell_type->name."]";
#       throw($msg);
#     }
    
#     # FS in dev?
#     my $dev_fset = $cfg->{tr_adaptors}->{fs}->fetch_by_name($tr_fset->name);
#     if(defined($dev_fset)){
#       #cell_type

#       #feature_       
#       my $fs_diffs = _compare_feature_set($tr_ds, $tr_fset, $dev_fset);
#       $dev->{feature_set} = $dev_fset;

#           }
    
#     my $dev_ft= $cfg->{dev_adaptors}->{ft}->fetch_by_name($tr_ds->feature_type->name);
#     if(defined $dev_ft){
#       _compare_feature_type($tr_ds, $dev_ds, $tr_ds->feature_type, $dev_ft);
#       $dev->{feature_type} = $dev->feature_type
#     }
#   }
#   die;
# }

# as annotated features are linked
# if(! defined $dev->{feature_set}){
    
#   my $tr_input_set   = $tr->{feature_set}->get_InputSet;
#   my $dev_input_set;

# #Can have an InputSet linked or not
#   if(!defined $tr_input_set){
#     $dev_input_set = undef;
#   }
#   else{
#     my $name       = $tr_input_set->name;
#     $dev_input_set = $cfg->{dev_adaptors}->{input_set}->fetch_by_name($name);

#     if(!defined $dev_input_set){
#       _print_info($tr, 'Tracking');
#       _print_info($dev, 'Dev');
#       my $fs_name = $tr->{feature_set}->name;
#       my $msg;
#       $msg  = "FeatureSet '$name'. Linked InputSet '$name' could not be fetched from devDB. ";
#       $msg .= "InputSets stored in the DB are retrieved by running:";
#       $msg .= "DataSet->get_supporting_sets('input')";
#       $msg .= "See prinout above for all currently stored InputSets";
#       throw($msg);
#     }
#   }
#   my $dev_analysis   = _get_dev_analysis($cfg, $tr->{feature_set});

#   $dev->{feature_set} = create_Storable_clone($tr->{feature_set},{
#       -analysis     => $dev_analysis,
#       -cell_type    => $dev->{cell_type},
#       -feature_type => $dev->{feature_type},
#       -input_set    => $dev_input_set,
#       });
#   ($dev->{feature_set}) =  @{$cfg->{dev_adaptors}->{feature_set}->store($dev->{feature_set})};

# #_migrate_annotated_feature($cfg, $dev->{feature_set});
#   }

# if( !defined $dev->{result_sets} && defined $tr->{result_sets} ){
#   foreach my $tr_result_set (@{$tr->{result_sets}}) {
#     _store_result_set($cfg, $tr_rs, $tr, $dev);

#     my $dev_analysis   = _get_dev_analysis($cfg, $tr_result_set);
#     my $dev_support    = $tr_result_set->get_support;

#     my $states = $tr_result_set->get_all_states;
#     $tr_result_set->{states} = [];

#       my $dev_result_set = create_Storable_clone($tr_result_set, {
#         -analysis     => $dev_analysis,
#         -feature_type => $dev->{feature_type},
#         -cell_type    => $dev->{cell_type},
#         -support      => $dev->{input_sets},
#         });

#     ($dev_result_set) = @{$cfg->{dev_adaptors}->{result_set}->store($dev_result_set)};
#     _states($cfg, $states, $dev_result_set);
#     $cfg->{dev_adaptors}->{input_set}->store_states($dev_result_set);

#     push(@{$dev->{result_sets}}, $dev_result_set);
#   }