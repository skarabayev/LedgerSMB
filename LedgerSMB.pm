
=head1 NAME

LedgerSMB - The Base class for many LedgerSMB objects, including DBObject.

=head1 SYNOPSIS

This module creates a basic request handler with utility functions available
in database objects (LedgerSMB::DBObject)

=head1 METHODS

=over

=item new ()

This method creates a new base request instance. It also validates the 
session/user credentials, as appropriate for the run mode.  Finally, it sets up 
the database connections for the user.

=item unescape($var)

Unescapes the var, i.e. converts html entities back to their characters.

=item open_form()

This sets a $self->{form_id} to be used in later form validation (anti-XSRF 
measure).

=item check_form()

This returns true if the form_id was associated with the session, and false if 
not.  Use this if the form may be re-used (back-button actions are valid).

=item close_form()

Identical with check_form() above, but also removes the form_id from the 
session.  This should be used when back-button actions are not valid.

=item format_amount (user => $LedgerSMB::User::hash, amount => $string, precision => $integer, neg_format => (-|DRCR));

The function takes a monetary amount and formats it according to the user 
preferences, the negative format (- or DR/CR).  Note that it may move to
LedgerSMB::User at some point in the future.

=item parse_amount (user => $LedgerSMB::User::hash, amount => $variable);

If $amount is a Bigfloat, it is returned as is.  If it is a string, it is 
parsed according to the user preferences stored in the LedgerSMB::User object.

=item is_run_mode ('(cli|cgi|mod_perl)')

This function returns 1 if the run mode is what is specified.  Otherwise
returns 0.

=item is_allowed_role({allowed_roles => @role_names})

This function returns 1 if the user's roles include any of the roles in
@role_names.  

=item merge ($hashref, keys => @list, index => $number);

This command merges the $hashref into the current object.  If keys are 
specified, only those keys are used.  Otherwise all keys are merged.

If an index is specified, the merged keys are given a form of 
"$key" . "_$index", otherwise the key is used on both sides.

=item set (@attrs)

Copies the given key=>vars to $self. Allows for finer control of 
merging hashes into self.

=item remove_cgi_globals()

Removes all elements starting with a . because these elements conflict with the
ability to hide the entire structure for things like CSV lookups.

=item call_procedure( procname => $procname, args => $args )

Function that allows you to call a stored procedure by name and map the appropriate argument to the function values.

Args is an arrayref.  The members of args can be scalars or arrayrefs in which 
case they are just bound to the placeholders (arrayref to Pg array conversion
occurs automatically in DBD::Pg 2.x), or they can be hashrefs of the following
syntax: {value => $data, type=> $db_type}.  The type field is any SQL type 
DBD::Pg supports (such as 'PG_BYTEA').

=item dberror()

Localizes and returns database errors and error codes within LedgerSMB

=item error()

Returns HTML errors in LedgerSMB. Needs refactored into a general Error class.

=item get_user_info()

Loads user configuration info from LedgerSMB::User

=item round_amount() 

Uses Math::Float with an amount and a set number of decimal places to round the amount and return it.

Defaults to the default decimal places setting in the LedgerSMB configuration if there is no places argument passed in.

They should be changed to allow different rules for different accounts.

=item sanitize_for_display()

Expands a hash into human-readable key => value pairs, and formats and rounds amounts, recursively expanding hashes until there are no hash members present.

=item take_top_level()

Removes blank keys and non-reference keys from a hash and returns a hash with only non-blank and referenced keys.

=item type()

Ensures that the $ENV{REQUEST_METHOD} is defined and either "HEAD", "GET", "POST".

=item finalize_request()

This zeroes out the App_State.

=cut


=back



=head1 Copyright (C) 2006, The LedgerSMB core team.

 # This work contains copyrighted information from a number of sources 
 # all used with permission.
 #
 # This file contains source code included with or based on SQL-Ledger
 # which is Copyright Dieter Simader and DWS Systems Inc. 2000-2005
 # and licensed under the GNU General Public License version 2 or, at
 # your option, any later version.  For a full list including contact
 # information of contributors, maintainers, and copyright holders, 
 # see the CONTRIBUTORS file.
 #
 # Original Copyright Notice from SQL-Ledger 2.6.17 (before the fork):
 # Copyright (C) 2000
 #
 #  Author: DWS Systems Inc.
 #     Web: http://www.sql-ledger.org
 #
 # Contributors: Thomas Bayen <bayen@gmx.de>
 #               Antti Kaihola <akaihola@siba.fi>
 #               Moritz Bunkus (tex)
 #               Jim Rawlings <jim@your-dba.com> (DB2)
 #====================================================================
=cut

use CGI::Simple;
$CGI::Simple::DISABLE_UPLOADS = 0;
use LedgerSMB::PGNumber;
use LedgerSMB::PGDate;
use LedgerSMB::Sysconfig;
use LedgerSMB::App_State;
use LedgerSMB::Auth;
use LedgerSMB::Session;
use LedgerSMB::Template;
use LedgerSMB::Locale;
use LedgerSMB::User;
use LedgerSMB::Setting;
use LedgerSMB::Company_Config;
use LedgerSMB::DBH;
use Carp;
use strict;
use utf8;

$CGI::Simple::POST_MAX = -1;

package LedgerSMB;
use Try::Tiny;
use DBI;

use base qw(LedgerSMB::Request);
our $VERSION = '1.4.5';

my $logger = Log::Log4perl->get_logger('LedgerSMB');

sub new {
    #my $type   = "" unless defined shift @_;
    #my $argstr = "" unless defined shift @_;
    (my $package,my $filename,my $line)=caller;

    my $type   = shift @_;
    my $argstr = shift @_;
    my %cookie;
    my $self = {};

    $type = "" unless defined $type;
    $argstr = "" unless defined $argstr;

    $logger->debug("Begin called from \$filename=$filename \$line=$line \$type=$type \$argstr=$argstr ref argstr=".ref $argstr);

    $self->{version} = $VERSION;
    $self->{dbversion} = $VERSION;
    my $creds =  LedgerSMB::Auth::get_credentials;
    $self->{login} = $creds->{login};
    
    bless $self, $type;

    my $query;
    my %params=();
    if(ref($argstr) eq 'DBI::db')
    {
     $self->{dbh}=$argstr;
     $logger->info("setting dbh from argstr \$self->{dbh}=$self->{dbh}");
    }
    else
    {
     $query = ($argstr) ? new CGI::Simple($argstr) : new CGI::Simple;
     # my $params = $query->Vars; returns a tied hash with keys that
     # are not parameters of the CGI query.
     %params = $query->Vars;
     for my $p(keys %params){
         if (($params{$p} eq undef) or ($params{$p} eq '')){
             delete $params{$p};
             next;
         }
         utf8::decode($params{$p});
         utf8::upgrade($params{$p});
     }
     $logger->debug("params=", Data::Dumper::Dumper(\%params));
    }
    $self->{VERSION} = $VERSION;
    $self->{_request} = $query;

    $self->merge(\%params);
    $self->{have_latex} = $LedgerSMB::Sysconfig::latex;

    # Adding this so that empty values are stored in the db as NULL's.  If
    # stored procedures want to handle them differently, they must opt to do so.
    # -- CT
    for (keys %$self){
        if ($self->{$_} eq ''){
            $self->{$_} = undef;
        }
    }

    if ($self->is_run_mode('cgi', 'mod_perl')) {
        $ENV{HTTP_COOKIE} =~ s/;\s*/;/g;
        my @cookies = split /;/, $ENV{HTTP_COOKIE};
        foreach (@cookies) {
            my ( $name, $value ) = split /=/, $_, 2;
            $cookie{$name} = $value;
        }
    }
    #HV set _locale already to default here,so routines lower in stack can use it;e.g. login.pl
    #$self->{_locale}=LedgerSMB::Locale->get_handle('en');
    $self->{_locale}=LedgerSMB::Locale->get_handle($LedgerSMB::Sysconfig::language);
    $self->error( __FILE__ . ':' . __LINE__ .": Locale ($LedgerSMB::Sysconfig::language) not loaded: $!\n" ) unless $self->{_locale};

    $self->{action} = "" unless defined $self->{action};
    $self->{action} =~ s/\W/_/g;
    $self->{action} = lc $self->{action};

    $self->{path} = "" unless defined $self->{path};

    if ( $self->{path} eq "bin/lynx" ) {
        $self->{menubar} = 1;

        # Applying the path is deprecated.  Use menubar instead.  CT.
        $self->{lynx} = 1;
        $self->{path} = "bin/lynx";
    }
    else {
        $self->{path} = "bin/mozilla";

    }

    $ENV{SCRIPT_NAME} = "" unless defined $ENV{SCRIPT_NAME};

    $ENV{SCRIPT_NAME} =~ m/([^\/\\]*.pl)\?*.*$/;
    $self->{script} = $1 unless !defined $1;
    $self->{script} = "" unless defined $self->{script};

    if ( ( $self->{script} =~ m#(\.\.|\\|/)# ) ) {
        $self->error("Access Denied");
    }
    if (!$self->{script}) {
        $self->{script} = 'login.pl';
    }
    $logger->debug("\$self->{script} = $self->{script} \$self->{action} = $self->{action}");
#    if ($self->{action} eq 'migrate_user'){
#        return $self;
#    }

    # This is suboptimal.  We need to have a better way for 1.4
    #HV we should try to have DBI->connect in one place?
    #HV  why not trying _db_init also in case of login authenticate? quid logout-function?
    if ($self->{script} eq 'login.pl' &&
        ($self->{action} eq 'authenticate'  || $self->{action} eq '__default' 
		|| !$self->{action} || ($self->{action} eq 'logout_js'))){
        return $self;
    }
    if ($self->{script} eq 'setup.pl'){
        return $self;
    }
    my $ccookie;
    if (!$self->{company} && $self->is_run_mode('cgi', 'mod_perl')){
         $ccookie = $cookie{${LedgerSMB::Sysconfig::cookie_name}};
         $ccookie =~ s/.*:([^:]*)$/$1/;
         if($ccookie ne 'Login') { $self->{company} = $ccookie; } 
    }
    $logger->debug("\$ccookie=$ccookie cookie.LedgerSMB::Sysconfig::cookie_name=".$cookie{${LedgerSMB::Sysconfig::cookie_name}}." \$self->{company}=$self->{company}");

    if(! $cookie{${LedgerSMB::Sysconfig::cookie_name}} && $self->{action} eq 'logout')
    {
     $logger->debug("quitting because of logout and no cookie,avoid _db_init");
     return $self;
    }

    #dbh may have been set elsewhere,by DBObject.pm?
    if(!$self->{dbh})
    {
     $self->_db_init;
    }
    LedgerSMB::Company_Config::initialize($self);

    #TODO move before _db_init to avoid _db_init with invalid session?
    #  Can't do that:  Company_Config has to pull company data from the db --CT
    if ($self->is_run_mode('cgi', 'mod_perl') and !$ENV{LSMB_NOHEAD}) {
       #check for valid session unless this is an inital authentication
       #request -- CT
       if (!LedgerSMB::Session::check( $cookie{${LedgerSMB::Sysconfig::cookie_name}}, $self) ) {
            $logger->error("Session did not check");
            $self->_get_password("Session Expired");
            die;
       }
       $logger->debug("session_check completed OK \$self->{session_id}=$self->{session_id} caller=\$filename=$filename \$line=$line");
    }
    $self->get_user_info;

    my %date_setting = (
        'mm/dd/yy' => "ISO, MDY",
        'mm-dd-yy' => "ISO, MDY",
        'dd/mm/yy' => "ISO, DMY",
        'dd-mm-yy' => "ISO, DMY",
        'dd.mm.yy' => "ISO, DMY",
    );

    $self->{dbh}->do("set DateStyle to '".$date_setting{$self->{_user}->{dateformat}}."'");
    $self->{_locale}=LedgerSMB::Locale->get_handle($self->{_user}->{language})
     or $self->error(__FILE__.':'.__LINE__.": Locale not loaded: $!\n");

    $self->{stylesheet} = $self->{_user}->{stylesheet} unless $self->{stylesheet};

    $logger->debug("End");

    return $self;

}

sub unescape {
    my ($self, $var) = @_;
    return $self->{_request}->unescapeHTML($var);
}

sub open_form {
    my ($self, $args) = @_;
    if (!$ENV{GATEWAY_INTERFACE}){
        return 1;
    }
    my @vars = $self->call_procedure(procname => 'form_open', 
                              args => [$self->{session_id}],
                              continue_on_error => 1
    );
    if ($args->{commit}){
       $self->{dbh}->commit;
    }
    $self->{form_id} = $vars[0]->{form_open};
}

sub check_form {
    my ($self) = @_;
    if (!$ENV{GATEWAY_INTERFACE}){
        return 1;
    }
    my @vars = $self->call_procedure(procname => 'form_check', 
                              args => [$self->{session_id}, $self->{form_id}]
    );
    return $vars[0]->{form_check};
}

sub close_form {
    my ($self) = @_;
    if (!$ENV{GATEWAY_INTERFACE}){
        return 1;
    }
    my @vars = $self->call_procedure(procname => 'form_close', 
                              args => [$self->{session_id}, $self->{form_id}]
    );
    delete $self->{form_id};
    return $vars[0]->{form_close};
}

sub get_user_info {
    my ($self) = @_;
    $LedgerSMB::App_State::User =
        $self->{_user} =
        LedgerSMB::User->fetch_config($self);
    $self->{_user}->{language} ||= 'en';
}
#This function needs to be moved into the session handler.
sub _get_password {
    my ($self) = shift @_;
    $self->{sessionexpired} = shift @_;
    if ($self->{sessionexpired}){
        my $q = new CGI::Simple;
        print $q->redirect('login.pl?action=logout&reason=timeout');
    } else {
        LedgerSMB::Auth::credential_prompt();
    }
    die;
}


sub is_run_mode {
    my $self = shift @_;
    #avoid 'uninitialized' warnings in tests
    my $mode = shift @_;
    my $rc   = 0;
    if(! $mode){return $rc;}
    $mode=lc $mode;
    if ( $mode eq 'cgi' && $ENV{GATEWAY_INTERFACE} ) {
        $rc = 1;
    }
    elsif ( $mode eq 'cli' && !( $ENV{GATEWAY_INTERFACE} || $ENV{MOD_PERL} ) ) {
        $rc = 1;
    }
    elsif ( $mode eq 'mod_perl' && $ENV{MOD_PERL} ) {
        $rc = 1;
    }
    $rc;
}

# TODO:  Either we should have an amount class with formats and such attached
# Or maybe we should move this into the user class...
sub format_amount {

    # Based on SQL-Ledger's Form::format_amount
    my $self     = shift @_;
    my %args  = (ref($_[0]) eq 'HASH')? %{$_[0]}: @_;
    my $myconfig = $args{user} || $self->{_user};
    my $amount   = $args{amount};
    my $places   = $args{precision};
    my $dash     = $args{neg_format};
    my $format   = $args{format};

    if (defined $amount and ! UNIVERSAL::isa($amount, 'LedgerSMB::PGNumber' )) {
        $amount = $self->parse_amount('user' => $myconfig, 'amount' => $amount);
    }
    $dash = undef unless defined $dash;

    if (!defined $format){
       $format = $myconfig->{numberformat}
    }
    if (!defined $amount){
        return undef;
    }
    if (!defined $args{precision} and defined $args{money}){
       $places = LedgerSMB::Setting->get('decimal_places');
    }

    return $amount->to_output({format => $format, 
                           neg_format => $args{neg_format}, 
                               places => $places,
                                money => $args{money},
           });
}

# For backwards compatibility only
sub parse_amount {
    my $self     = shift @_;
    my %args     = @_;
    my $amount   = $args{amount};
    my $user     = ($args{user})? ($args{user}) : $self->{_user};
    if (UNIVERSAL::isa($amount, 'LedgerSMB::PGNumber')){
        return $amount;
    } 
    return LedgerSMB::PGNumber->from_input($amount, 
                                     {format => $user->{numberformat}}
    ); 
}

sub round_amount {

    my ( $self, $amount, $places ) = @_;
    
    #
    # We will grab the default value, if it isnt defined
    #
    if (!defined $places){
       $places = LedgerSMB::Setting->get('decimal_places');
    }
    
    # These rounding rules follow from the previous implementation.
    # They should be changed to allow different rules for different accounts.
    if ($amount >= 0) {
        Math::BigFloat->round_mode('+inf');
    } 
    else {
        Math::BigFloat->round_mode('-inf');
    } 

    if ($places >= 0) {
        $amount = Math::BigFloat->new($amount)->ffround( -$places );
    } 
    else {
        $amount = Math::BigFloat->new($amount)->ffround( -( $places - 1 ) );
    } 
    $amount->precision(undef);

    return $amount;
}

sub call_procedure {
    my $self     = shift @_;
    my %args     = @_;
    my $procname = $args{procname};
    my $schema   = $args{schema};
    my @call_args;
    @call_args = @{ $args{args} } if defined $args{args};
    my $order_by = $args{order_by};
    my $query_rc;
    my $argstr   = "";
    my @results;
    my $dbh = $LedgerSMB::App_State::DBH;
    die "Database handle not found! procname=$procname" if !$dbh;

    if (!defined $procname){
        $self->error('Undefined function in call_procedure.');
    }
    $procname = $dbh->quote_identifier($procname);
    # Add the test for whether the schema is something useful.
    $logger->trace("\$procname=$procname");
    
    $schema = $schema || $LedgerSMB::Sysconfig::db_namespace;
    
    $schema = $dbh->quote_identifier($schema);
    
    for my $arg ( @call_args ) {
        if (eval { $arg->can('to_db') }){
           $arg = $arg->to_db;
        }
        $argstr .= "?, ";
    }
    $argstr =~ s/\, $//;
    my $query = "SELECT * FROM $schema.$procname()";
    if ($order_by){
        $query .= " ORDER BY $order_by";
    }
    $query =~ s/\(\)/($argstr)/;
    my $sth = $dbh->prepare($query);
    my $place = 1;
    # API Change here to support byteas:  
    # If the argument is a hashref, allow it to define it's SQL type
    # for example PG_BYTEA, and use that to bind.  The API supports the old
    # syntax (array of scalars and arrayrefs) but extends this so that hashrefs
    # now have special meaning. I expect this to be somewhat recursive in the
    # future if hashrefs to complex types are added, but we will have to put 
    # that off for another day. --CT
    foreach my $carg (@call_args){
        if (ref($carg) eq 'HASH'){
            $sth->bind_param($place, $carg->{value}, 
                       { pg_type => $carg->{type} });
        } else {
            if (ref($carg) eq 'ARRAY'){
               if (eval{$carg->[0]->can('to_db')}){
                  for my $ref(@$carg){
                       $ref = $ref->to_db;
                  }
               }
            }
            $sth->bind_param($place, $carg);
        }
        ++$place;
    }
    $query_rc = $sth->execute();
    if (!$query_rc){
          if ($args{continue_on_error} and  #  only for plpgsql exceptions
                          ($dbh->state =~ /^P/)){
                $@ = $dbh->errstr;
          } else {
                $self->dberror($dbh->errstr . ": " . $query);
          }
    }
   
    my @types = @{$sth->{TYPE}};
    my @names = @{$sth->{NAME_lc}};
    while ( my $ref = $sth->fetchrow_hashref('NAME_lc') ) {
	for (0 .. $#names){
            #   numeric            float4/real
            if ($types[$_] == 3 or $types[$_] == 2) {
                $ref->{$names[$_]} ||=0;
                $ref->{$names[$_]} = LedgerSMB::PGNumber->from_db($ref->{$names[$_]}, 'datetime') if defined $ref->{$names[$_]};
            }
            #    DATE                TIMESTAMP
            if ($types[$_] == 91 or $types[$_] == 11){
                $ref->{$names[$_]} = LedgerSMB::PGDate->from_db($ref->{$names[$_]}, 'date') if defined $ref->{$names[$_]};
            }
            delete $ref->{$names[$_]} unless defined $ref->{$names[$_]};
        }
        push @results, $ref;
    }
    return @results;
}

# Keeping this here due to common requirements
sub is_allowed_role {
    my ($self, $args) = @_;
    my @roles = @{$args->{allowed_roles}};
    for my $role (@roles){
        $self->{_role_prefix} = "lsmb_$self->{company}__" unless defined $self->{_role_prefix};
        my @roleset = grep m/^$self->{_role_prefix}$role$/, @{$self->{_roles}};
        if (scalar @roleset){
            return 1;
        }
    }
    return 0; 
}

sub finalize_request {
    LedgerSMB::App_State->cleanup();
    die 'exit'; # return to error handling and cleanup
                # Without dying, we tend to continue with a bad dbh. --CT
}

# To be replaced with a generic interface to an Error class
sub error {
    my ($self, $msg) = @_;
    Carp::croak $msg;
}

sub _error {

    my ( $self, $msg ) = @_;
    #Carp::confess();
    if ( $ENV{GATEWAY_INTERFACE} ) {

        $self->{msg}    = $msg;
        $self->{format} = "html";
        $logger->error($msg);
        $logger->error("dbversion: $self->{dbversion}, company: $self->{company}");

        delete $self->{pre};

        
        print qq|Content-Type: text/html; charset=utf-8\n\n|;
        print "<head><link rel='stylesheet' href='css/$self->{_user}->{stylesheet}' type='text/css'></head>";
        $self->{msg} =~ s/\n/<br \/>\n/;
        print
          qq|<body><h2 class="error">Error!</h2> <p><b>$self->{msg}</b></p>
             <p>dbversion: $self->{dbversion}, company: $self->{company}</p>
             </body>|;

        die;

    }
    else {

        if ( $ENV{error_function} ) {
            &{ $ENV{error_function} }($msg);
        }
        die "Error: $msg\n";
    }
}
# Database routines used throughout

sub _db_init {
    my $self     = shift @_;
    my %args     = @_;
    (my $package,my $filename,my $line)=caller;
    if (!$self->{company}){ 
        $self->{company} = $LedgerSMB::Sysconfig::default_db;
    }
    if (!($self->{dbh} = LedgerSMB::App_State::DBH)){
        $self->{dbh} = LedgerSMB::DBH->connect($self->{company})
            || LedgerSMB::Auth::credential_prompt;
    }
    LedgerSMB::App_State::set_DBH($self->{dbh});
    LedgerSMB::App_State::set_DBName($self->{company});

    try {
        LedgerSMB::DBH->require_version($VERSION);
    } catch {
        $self->_error($_);
    };
    
    my $sth = $self->{dbh}->prepare("
            SELECT value FROM defaults 
             WHERE setting_key = 'role_prefix'");
    $sth->execute;


    ($self->{_role_prefix}) = $sth->fetchrow_array;

    $sth = $self->{dbh}->prepare('SELECT check_expiration()');
    $sth->execute;
    ($self->{warn_expire}) = $sth->fetchrow_array;
   
    if ($self->{warn_expire}){
        $sth = $self->{dbh}->prepare('SELECT user__check_my_expiration()');
        $sth->execute;
        ($self->{pw_expires})  = $sth->fetchrow_array;
    }


    my $query = "SELECT t.extends, 
			coalesce (t.table_name, 'custom_' || extends) 
			|| ':' || f.field_name as field_def
		FROM custom_table_catalog t
		JOIN custom_field_catalog f USING (table_id)";
    $sth = $self->{dbh}->prepare($query);
    $sth->execute;
    my $ref;
    $self->{custom_db_fields} = {};
    while ( $ref = $sth->fetchrow_hashref('NAME_lc') ) {
        push @{ $self->{custom_db_fields}->{ $ref->{extends} } },
          $ref->{field_def};
    }

    # Adding role list to self 
    $self->{_roles} = [];
    $query = "select rolname from pg_roles 
               where pg_has_role(SESSION_USER, 'USAGE')";
    $sth = $self->{dbh}->prepare($query);
    $sth->execute();
    while (my @roles = $sth->fetchrow_array){
        push @{$self->{_roles}}, $roles[0];
    }

    $LedgerSMB::App_State::Roles = @{$self->{_roles}};
    $LedgerSMB::App_State::Role_Prefix = $self->{_role_prefix};
    # @{$self->{_roles}} will eventually go away. --CT

    $sth->finish();
    $logger->debug("end");
}

#private, for db connection errors
sub _on_connection_error {
    for (@_){
        $logger->error("$_");
    }
}

sub dberror{
   my $self = shift @_;
   my $state_error = {};
   my $locale = $LedgerSMB::App_State::Locale;
   if(! $locale){$locale=$self->{_locale};}#tshvr4
   my $dbh = $LedgerSMB::App_State::DBH;
   $state_error = {
            '42883' => $locale->text('Internal Database Error'),
            '42501' => $locale->text('Access Denied'),
            '42401' => $locale->text('Access Denied'),
            '22008' => $locale->text('Invalid date/time entered'),
            '22012' => $locale->text('Division by 0 error'),
            '22004' => $locale->text('Required input not provided'),
            '23502' => $locale->text('Required input not provided'),
            '23505' => $locale->text('Conflict with Existing Data.  Perhaps you already entered this?'),
            'P0001' => $locale->text('Error from Function:') . "\n" .
                    $dbh->errstr,
   };
   $logger->error("Logging SQL State ".$dbh->state.", error ".
           $dbh->err . ", string " .$dbh->errstr);
   if (defined $state_error->{$dbh->state}){
       die $state_error->{$dbh->state}
           . "\n" . 
          $locale->text('More information has been reported in the error logs');
       $dbh->rollback;
       die;
   }
   die $dbh->state . ":" . $dbh->errstr;
}

sub merge {
    (my $package,my $filename,my $line)=caller;
    my ( $self, $src ) = @_;
    $logger->debug("begin caller \$filename=$filename \$line=$line");
       # Removed dbh from logging string since not used on this api call and
       # not initialized in test cases -CT
    for my $arg ( $self, $src ) {
        shift;
    }
    my %args  = @_;
    my @keys;
    if (defined $args{keys}){
         @keys  = @{ $args{keys} };
    }
    my $index = $args{index};
    if ( !scalar @keys ) {
        @keys = keys %{$src};
    }
    for my $arg ( @keys ) {
        my $dst_arg;
        if ($index) {
            $dst_arg = $arg . "_$index";
        }
        else {
            $dst_arg = $arg;
        }
        if ( defined $dst_arg && defined $src->{$arg} )
        {
            $logger->trace("LedgerSMB.pm: merge setting $dst_arg to $src->{$arg}");
        }
        elsif ( !defined $dst_arg && defined $src->{$arg} )
        {
            $logger->trace("LedgerSMB.pm: merge setting \$dst_arg is undefined \$src->{\$arg} is defined $src->{$arg}");
        }
        elsif ( defined $dst_arg && !defined $src->{$arg} )
        {
            $logger->trace("LedgerSMB.pm: merge setting \$dst_arg is defined $dst_arg \$src->{\$arg} is undefined");
        }
        elsif ( !defined $dst_arg && !defined $src->{$arg} )
        {
            $logger->trace("LedgerSMB.pm: merge setting \$dst_arg is undefined \$src->{\$arg} is undefined");
        }
        $self->{$dst_arg} = $src->{$arg};
    }
    $logger->debug("end caller \$filename=$filename \$line=$line");
}

sub type {
    
    my $self = shift @_;
    
    if (!$ENV{REQUEST_METHOD} or 
        ( !grep {$ENV{REQUEST_METHOD} eq $_} ("HEAD", "GET", "POST") ) ) {
        
        $self->error("Request method unset or set to unknown value");
    }
    
    return $ENV{REQUEST_METHOD};
}

sub DESTROY {}

sub set {
    
    my $self = shift @_;
    my %args = @_;
    
    for my $arg (keys(%args)) {
        $self->{$arg} = $args{$arg};
    }
    return 1;    

}

sub remove_cgi_globals {
    my ($self) = @_;
    for my $key (keys %$self){
        if ($key =~ /^\./){
            delete $self->{key}
        }
    }
}

sub take_top_level {
   my ($self) = @_;
   my $return_hash = {};
   for my $key (keys %$self){
       if (!ref($self->{$key}) && $key !~ /^\./){
          $return_hash->{$key} = $self->{$key}
       }
   }
   return $return_hash;
}

1;


