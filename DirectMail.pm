package Koha::Plugin::Com::RBitTechnology::DirectMail;

use List::MoreUtils qw/uniq/;

use Modern::Perl;
use base qw(Koha::Plugins::Base);
use Encode qw( decode );
use Text::CSV::Encoded;
use File::Temp;
use File::Basename qw( dirname );
use utf8;
use C4::Context;
use C4::Letters;
use C4::Members::AttributeTypes;
use Koha::Patrons;

use Data::Dumper;

our $VERSION = "1.0.1";

our $extAttrIsOn = C4::Context->preference('ExtendedPatronAttributes') ne '0';

our $metadata = {
    name            => 'Přímé oslovování čtenářů',
    author          => 'Radek Šiman',
    description     => 'Využitím tohoto nástroje lze vytvářet cílové skupiny čtenářů podle zadaných kritérií a těmto skupinám rozesílat hromadně zprávy formou e-mailu. '
                         . ($extAttrIsOn ? '' : 'Modul nebude fungovat, není nastaven parametr <a href="/cgi-bin/koha/admin/preferences.pl?op=search&amp;searchfield=ExtendedPatronAttributes"><strong>ExtendedPatronAttributes</strong></a>.'),
    date_authored   => '2017-11-23',
    date_updated    => '2017-12-09',
    minimum_version => '16.11',
    maximum_version => undef,
    version         => $VERSION
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub install() {
    my ( $self, $args ) = @_;

    my $table_predefs = $self->get_qualified_table_name('predefs');
    my $table = $self->get_qualified_table_name('predef_options');

    return  C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS $table_predefs (
            `predef_id` INT( 11 ) NOT NULL AUTO_INCREMENT,
            `name` VARCHAR(80) NOT NULL,
            `description` TEXT DEFAULT NULL,
            `date_created` DATETIME NOT NULL,
            `last_modified` DATETIME NOT NULL,
            PRIMARY KEY(`predef_id`)
        ) ENGINE = INNODB DEFAULT CHARACTER SET = utf8 COLLATE = utf8_czech_ci;
        " ) && C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS $table (
            `predef_option_id` INT( 11 ) NOT NULL AUTO_INCREMENT,
            `predef_id` INT( 11 ) NOT NULL,
            `variable` VARCHAR(50) NOT NULL,
            `value` TEXT NOT NULL,
            PRIMARY KEY(`predef_option_id`),
            INDEX `fk_predef_options_idx` (`predef_id` ASC),
            CONSTRAINT `fk_directmail_predef_options`
            FOREIGN KEY (`predef_id`)
            REFERENCES `$table_predefs` (`predef_id`)
            ON DELETE CASCADE
            ON UPDATE CASCADE
        ) ENGINE = INNODB DEFAULT CHARACTER SET = utf8 COLLATE = utf8_czech_ci;
    " );
}

sub uninstall() {
    my ( $self, $args ) = @_;

    my $table_predefs = $self->get_qualified_table_name('predefs');
    my $table_options = $self->get_qualified_table_name('predef_options');

    return C4::Context->dbh->do("DROP TABLE $table_options") && C4::Context->dbh->do("DROP TABLE $table_predefs");
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });

        ## Grab the values we already have for our settings, if any exist

        patron_attribute_type_list($template);

        $template->param(
            extended_attr => $extAttrIsOn,
            extattr_agree => $self->retrieve_data('extattr_agree'),
        );

        print $cgi->header(-type => 'text/html',
                           -charset => 'utf-8');
        print $template->output();
    }
    else {
        $self->store_data(
            {
                extattr_agree => $cgi->param('extattr_agree'),
                last_configured_by => C4::Context->userenv->{'number'},
            }
        );

        $self->go_home();
    }
}

sub patron_attribute_type_list {
    my $template = shift;

    my @attr_types = C4::Members::AttributeTypes::GetAttributeTypes( 1, 1 );

    my @classes = uniq( map { $_->{class} } @attr_types );
    @classes = sort @classes;

    my @attributes_loop;
    for my $class (@classes) {
        my ( @items, $branches );
        for my $attr (@attr_types) {
            next if $attr->{class} ne $class;
            my $attr_type = C4::Members::AttributeTypes->fetch($attr->{code});
            $attr->{branches} = $attr_type->branches;
            push @items, $attr;
        }
        my $av = Koha::AuthorisedValues->search({ category => 'PA_CLASS', authorised_value => $class });
        my $lib = $av->count ? $av->next->lib : $class;
        push @attributes_loop, {
            class => $class,
            items => \@items,
            lib   => $lib,
            branches => $branches,
        };
    }
    $template->param(available_attribute_types => \@attributes_loop);
}


sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('phase') ) {;
        $self->tool_list_predefs();
    }
    elsif ( $cgi->param('phase') eq 'edit' ) {
        $self->tool_edit_predef();
    }
    elsif ( $cgi->param('phase') eq 'run' ) {
        $self->tool_get_results();
    }
    elsif ( $cgi->param('phase') eq 'delete' ) {
        $self->tool_delete_predef();
    }
    elsif ( $cgi->param('phase') eq 'duplicate' ) {
        $self->tool_duplicate_predef();
    }
    elsif ( $cgi->param('phase') eq 'mail' ) {
        $self->tool_send_mail();
    }
}

sub tool_list_predefs {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'tool-list.tt' });

    print $cgi->header(-type => 'text/html',
                       -charset => 'utf-8');

    my $dbh = C4::Context->dbh;
    my $table_predefs = $self->get_qualified_table_name('predefs');

    my $query = "SELECT predef_id, name, description, date_created, last_modified FROM $table_predefs;";

    my $sth = $dbh->prepare($query);
    $sth->execute();

    my @results;
    while ( my $row = $sth->fetchrow_hashref() ) {
        push( @results, $row );
    }

    $template->param(
        predefs => \@results,
    );

    print $template->output();
}

sub tool_edit_predef {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'tool-edit.tt' });

    print $cgi->header(-type => 'text/html',
                       -charset => 'utf-8');

    my $options = {};
    my $predef = undef;
    my $dbh = C4::Context->dbh;
    my $query;
    my $sth;

    if ( defined $cgi->param('predef') ) {
        my $table_options = $self->get_qualified_table_name('predef_options');
        my $table_predefs = $self->get_qualified_table_name('predefs');

        $query = "SELECT predef_id, name, description FROM $table_predefs WHERE predef_id = ?;";
        $sth = $dbh->prepare($query);
        $sth->execute( scalar $cgi->param('predef') );
        $predef = $sth->fetchrow_hashref();

        $query = "SELECT variable, value FROM $table_options WHERE predef_id = ?;";
        $sth = $dbh->prepare($query);
        $sth->execute( scalar $cgi->param('predef') );

        my %multi = map { $_ => 1 } qw(
            itemtypes
            services
            branches
        );

        while ( my $row = $sth->fetchrow_hashref() ) {
            if ( exists( $multi{$row->{variable}} ) ) {
                my @arr = split /,/, $row->{value};
                $options->{$row->{variable}} = \@arr;
            }
            else {
                $options->{$row->{variable}} = $row->{value};
            }
        }
    }

    $query = "SHOW TABLES LIKE 'account_debit_types';";
    $sth = $dbh->prepare($query);
    $sth->execute();
    my @acct_table = $sth->fetchall_arrayref();
    my @debit_types;
    if (@acct_table) {
        $query = "SELECT type_code, description FROM account_debit_types WHERE can_be_added_manually = 1 ORDER BY description;";
        $sth = $dbh->prepare($query);
        $sth->execute();
        while ( my $row = $sth->fetchrow_hashref() ) {
            push( @debit_types, $row );
        }
    }

    # prepare data for the form
    my @itemtypes = Koha::ItemTypes->search({}, { order_by => ['description'], columns => [qw/itemtype description/] } );
    my @branches  = Koha::Libraries->search({}, { order_by => ['branchname'], columns => [qw/branchcode branchname/] } );
    my @invoice_types = Koha::AuthorisedValues->search({ category => 'MANUAL_INV'},  { order_by => ['lib'], columns  => [ {type_code => 'authorised_value'}, {description => 'lib'} ] } );

    $template->param(
        itemtypes => \@itemtypes,
        branches => \@branches,
        invoice_types => @acct_table ? \@debit_types : \@invoice_types,
        options => $options,
        predef => $predef,
    );

    print $template->output();
}

sub execute_sql {
    my ( $self, $predefId ) = @_;

        # retrieve column list
        my $dbh = C4::Context->dbh;
        my $table_options = $self->get_qualified_table_name('predef_options');

        # detect enabled subconditions
        my $enabled = {};
        my $query = "SELECT SUBSTRING(variable, 5) as subcond FROM $table_options WHERE variable LIKE 'chk_%' AND value = '1' AND predef_id = ?;";
        my $sth = $dbh->prepare($query);
        $sth->execute($predefId);
        while ( my $row = $sth->fetchrow_hashref() ) {
            $enabled->{$row->{subcond}} = 1;
        }

        # prepare subconditions
        my $subcond = {};
        $query = "SELECT variable, value FROM $table_options WHERE  variable NOT LIKE 'chk_%' AND predef_id = ?;";
        $sth = $dbh->prepare($query);
        $sth->execute($predefId);
        while ( my $row = $sth->fetchrow_hashref() ) {
            $subcond->{$row->{variable}} = $row->{value};
        }

        # find items referencing given genre/form
        my @itemsByGenre;
        if ( $enabled->{genre_form} ) {
            # find biblio adepts - contains the authority in xpath_expr result, but it can be a false positive, because partial results are space-concatenated
            $query = "SELECT biblionumber , ExtractValue( metadata , \"count(//datafield[\@tag='655']/subfield[\@code='a'])\") cnt655 FROM biblio_metadata WHERE biblionumber IN( SELECT biblionumber FROM biblio_metadata WHERE ExtractValue( metadata , \"//datafield[\@tag='655']/subfield[\@code='a']\") LIKE ?);";
            $sth = $dbh->prepare($query);
            $sth->execute( '%' . $subcond->{genre_form} . '%' );
            while ( my $row = $sth->fetchrow_hashref() ) {

                # we know count of genre/forms in this biblio, so iterate over them to be sure we really found the authority - there is "=" in HAVING so it must match exactly
                for my $i (1..$row->{cnt655}) {
                    $query = "SELECT itemnumber FROM items WHERE biblionumber IN (SELECT biblionumber FROM biblio_metadata WHERE biblionumber = ? AND ExtractValue( metadata , \"//datafield[\@tag='655']/subfield[\@code='a'][$i]\") = ?);";
                    my $sthBib = $dbh->prepare($query);
                    $sthBib->execute( $row->{biblionumber}, $subcond->{genre_form} );
                    if ( my $item = $sthBib->fetchrow_hashref() ) {
                        push( @itemsByGenre, $item->{itemnumber} );
                        last;
                    }
                }
            }
        }

        # find items referencing given genre/form
        my @itemsByAuthor;
        if ( $enabled->{author} ) {
            # find biblio adepts - contains the authority in xpath_expr result, but it can be a false positive, because partial results are space-concatenated
            $query = "SELECT biblionumber , ExtractValue( metadata , \"count(//datafield[\@tag='100']/subfield[\@code='a'])\") cnt100 FROM biblio_metadata WHERE biblionumber IN( SELECT biblionumber FROM biblio_metadata WHERE ExtractValue( metadata , \"//datafield[\@tag='100']/subfield[\@code='a']\") LIKE ?);";
            $sth = $dbh->prepare($query);
            $sth->execute( '%' . $subcond->{author} . '%' );
            while ( my $row = $sth->fetchrow_hashref() ) {

                # we know count of authors in this biblio, so iterate over them to be sure we really found the authority - there is "=" in HAVING so it must match exactly
                for my $i (1..$row->{cnt100}) {
                    $query = "SELECT itemnumber FROM items WHERE biblionumber IN (SELECT biblionumber FROM biblio_metadata WHERE biblionumber = ? AND ExtractValue( metadata , \"//datafield[\@tag='100']/subfield[\@code='a'][$i]\") = ?);";
                    my $sthBib = $dbh->prepare($query);
                    $sthBib->execute( $row->{biblionumber}, $subcond->{author} );
                    if ( my $item = $sthBib->fetchrow_hashref() ) {
                        push( @itemsByAuthor, $item->{itemnumber} );
                        last;
                    }
                }
            }
        }

        my @where;
        my @bindParams;
        my @havingParts;
        my @queryCols = qw( borrowers.borrowernumber cardnumber );
        my $period = {
            day => 1,
            month => 30,
            year => 365
        };
        my $operator = {
            avg => '=',
            min => '>=',
            max => '<='
        };

        my $regValidDate = 'IF(borrowers.date_renewed IS NOT NULL, borrowers.date_renewed, IF(date(borrowers.dateexpiry) > NOW(), borrowers.dateenrolled, NOW()))';

        # SELECT parts must be processed before any WHERE params to keep the right order of bindParams
        if ( $enabled->{last_visit} ) {
            push( @queryCols, '(SELECT max(statistics.`datetime`) FROM statistics WHERE statistics.borrowernumber = borrowers.borrowernumber AND type IN( "payment" , "writeoff" , "renew" , "issue" , "return")) as last_visit' );
            push( @havingParts, 'DATEDIFF(now(), last_visit) / ? <= ?' );
            push( @bindParams, $period->{$subcond->{last_visit_period_type}} );
            push( @bindParams, $subcond->{last_visit_period_length} );
        }
        if ( $enabled->{issues} ) {
            my $selectCount = 'SELECT count(*) FROM statistics WHERE statistics.borrowernumber = borrowers.borrowernumber AND type = "issue"';
            if ( $subcond->{issues_period_type} eq 'year' || $subcond->{issues_period_type} eq 'month' ) {
                push( @queryCols, "($selectCount AND DATEDIFF(now(), statistics.`datetime`) / ? <= ?) as issues" );
                push( @bindParams, $period->{$subcond->{issues_period_type}} );
                push( @bindParams, $subcond->{issues_period_length} );
            }
            elsif ( $subcond->{issues_period_type} eq 'this-year' ) {
                push( @queryCols, "($selectCount AND YEAR(statistics.`datetime`) = YEAR(now())) as issues" );
            }
            elsif ( $subcond->{issues_period_type} eq 'last-reg' ) {
                push( @queryCols, "($selectCount AND date(statistics.DATETIME) > $regValidDate) as issues" );
            }
            my $op = $subcond->{issues_op};
            push( @havingParts, "issues $op ?" );
            push( @bindParams, $subcond->{issues} );
        }
        if ( $enabled->{bbox} ) {
            my $selectCount = 'SELECT count(*) FROM old_issues WHERE old_issues.borrowernumber = borrowers.borrowernumber AND returndate < `timestamp`';
            if ( $subcond->{bbox_period_type} eq 'year' || $subcond->{bbox_period_type} eq 'month' ) {
                push( @queryCols, "($selectCount AND DATEDIFF(now(), returndate) / ? <= ?) as bbox" );
                push( @bindParams, $period->{$subcond->{bbox_period_type}} );
                push( @bindParams, $subcond->{bbox_period_length} );
            }
            elsif ( $subcond->{bbox_period_type} eq 'this-year' ) {
                push( @queryCols, "($selectCount AND YEAR(returndate) = YEAR(now())) as bbox" );
            }
            elsif ( $subcond->{issues_period_type} eq 'last-reg' ) {
                push( @queryCols, "($selectCount AND date(returndate) > $regValidDate) as bbox" );
            }
            my $op = $subcond->{bbox_op};
            push( @havingParts, "bbox $op ?" );
            push( @bindParams, $subcond->{bbox} );
        }
        if ( $enabled->{prolongs} ) {
            my $selectCount = 'SELECT count(*) FROM statistics WHERE statistics.borrowernumber = borrowers.borrowernumber AND type = "renew"';
            if ( $subcond->{prolongs_period_type} eq 'year' || $subcond->{prolongs_period_type} eq 'month' ) {
                push( @queryCols, "($selectCount AND DATEDIFF(now(), statistics.`datetime`) / ? <= ?) as prolongs" );
                push( @bindParams, $period->{$subcond->{prolongs_period_type}} );
                push( @bindParams, $subcond->{prolongs_period_length} );
            }
            elsif ( $subcond->{prolongs_period_type} eq 'this-year' ) {
                push( @queryCols, "($selectCount AND YEAR(statistics.`datetime`) = YEAR(now())) as prolongs" );
            }
            elsif ( $subcond->{prolongs_period_type} eq 'last-reg' ) {
                push( @queryCols, "($selectCount AND date(statistics.DATETIME) > $regValidDate) as prolongs" );
            }
            my $op = $subcond->{prolongs_op};
            push( @havingParts, "prolongs $op ?" );
            push( @bindParams, $subcond->{prolongs} );
        }
        if ( $enabled->{issue_length} ) {
            my $fn = $subcond->{issue_length_type};
            my $issueLength = "$fn(datediff(returndate, issuedate))";
            $issueLength = "ROUND($issueLength)" if ( $fn eq 'avg' );
            my $selectInner = "SELECT $issueLength FROM old_issues WHERE old_issues.borrowernumber = borrowers.borrowernumber AND DATE(returndate) != DATE(issuedate)";
            if ( $subcond->{issue_length_period_type} eq 'year' || $subcond->{issue_length_period_type} eq 'month' ) {
                push( @queryCols, "($selectInner AND DATEDIFF(now(), returndate) / ? <= ?) as issue_length" );
                push( @bindParams, $period->{$subcond->{issue_length_period_type}} );
                push( @bindParams, $subcond->{issue_length_period_length} );
            }
            elsif ( $subcond->{issue_length_period_type} eq 'this-year' ) {
                push( @queryCols, "($selectInner AND YEAR(returndate) = YEAR(now())) as issue_length" );
            }
            elsif ( $subcond->{issue_length_period_type} eq 'last-reg' ) {
                push( @queryCols, "($selectInner AND date(returndate) > $regValidDate) as issue_length" );
            }
            my $op = $operator->{$subcond->{issue_length_type}};
            push( @havingParts, "issue_length $op ?" );
            push( @bindParams, $subcond->{issue_length} );
        }
        if ( $enabled->{reserves} ) {
            my $selectCountOld = 'SELECT count(*) FROM old_reserves WHERE old_reserves.borrowernumber = borrowers.borrowernumber';
            my $selectCount = 'SELECT count(*) FROM reserves WHERE reserves.borrowernumber = borrowers.borrowernumber';
            if ( $subcond->{reserves_period_type} eq 'year' || $subcond->{reserves_period_type} eq 'month' ) {
                push( @queryCols, "($selectCount AND DATEDIFF(now(), reservedate) / ? <= ?) as reserves" );
                push( @bindParams, $period->{$subcond->{reserves_period_type}} );
                push( @bindParams, $subcond->{reserves_period_length} );

                push( @queryCols, "($selectCountOld AND DATEDIFF(now(), reservedate) / ? <= ?) as old_reserves" );
                push( @bindParams, $period->{$subcond->{reserves_period_type}} );
                push( @bindParams, $subcond->{reserves_period_length} );
            }
            elsif ( $subcond->{reserves_period_type} eq 'this-year' ) {
                push( @queryCols, "($selectCount AND YEAR(reservedate) = YEAR(now())) as reserves" );
                push( @queryCols, "($selectCountOld AND YEAR(reservedate) = YEAR(now())) as old_reserves" );
            }
            elsif ( $subcond->{reserves_period_type} eq 'last-reg' ) {
                push( @queryCols, "($selectCount AND date(reservedate) > $regValidDate) as reserves" );
                push( @queryCols, "($selectCountOld AND date(reservedate) > $regValidDate) as old_reserves" );
            }
            my $op = $subcond->{reserves_op};
            push( @havingParts, "reserves+old_reserves $op ?" );
            push( @bindParams, $subcond->{reserves} );
        }
        if ( $enabled->{fines} ) {
            my $selectCount = "SELECT count(*) FROM accountlines WHERE accountlines.borrowernumber = borrowers.borrowernumber AND accounttype IN ('F')";
            if ( $subcond->{fines_period_type} eq 'year' || $subcond->{fines_period_type} eq 'month' ) {
                push( @queryCols, "($selectCount AND DATEDIFF(now(), accountlines.date) / ? <= ?) as fines" );
                push( @bindParams, $period->{$subcond->{fines_period_type}} );
                push( @bindParams, $subcond->{fines_period_length} );
            }
            elsif ( $subcond->{fines_period_type} eq 'this-year' ) {
                push( @queryCols, "($selectCount AND YEAR(accountlines.date) = YEAR(now())) as fines" );
            }
            elsif ( $subcond->{fines_period_type} eq 'last-reg' ) {
                push( @queryCols, "($selectCount AND date(accountlines.date) > $regValidDate) as fines" );
            }
            my $op = $subcond->{fines_op};
            push( @havingParts, "fines $op ?" );
            push( @bindParams, $subcond->{fines} );
        }
        if ( $enabled->{services} ) {
            my @paymentTypes = split(',', $subcond->{services});
            my @qMarks;
            foreach my $pay ( @paymentTypes ) {
                push( @bindParams, $pay );
                push( @qMarks, '?' );
            }
            my $selectCount = "SELECT count(*) FROM accountlines WHERE accountlines.borrowernumber = borrowers.borrowernumber AND accounttype IN (" . join(',', @qMarks) . ")";
            if ( $subcond->{services_count_period_type} eq 'year' || $subcond->{services_count_period_type} eq 'month' ) {
                push( @queryCols, "($selectCount AND DATEDIFF(now(), accountlines.date) / ? <= ?) as services" );
                push( @bindParams, $period->{$subcond->{services_count_period_type}} );
                push( @bindParams, $subcond->{services_count_period_length} );
            }
            elsif ( $subcond->{services_count_period_type} eq 'this-year' ) {
                push( @queryCols, "($selectCount AND YEAR(accountlines.date) = YEAR(now())) as services" );
            }
            elsif ( $subcond->{services_count_period_type} eq 'last-reg' ) {
                push( @queryCols, "($selectCount AND date(accountlines.date) > $regValidDate) as services" );
            }
            my $op = $subcond->{services_op};
            push( @havingParts, "services $op ?" );
            push( @bindParams, $subcond->{services_count} );
        }
        if ( $enabled->{itemtypes} ) {
            my @itypes = split(',', $subcond->{itemtypes});
            my @qMarks;
            foreach my $itype ( @itypes ) {
                push( @bindParams, $itype );
                push( @bindParams, $itype );    # must be twice because of issues, old_issues
                push( @qMarks, '?' );
            }
            push( @queryCols, "(SELECT count(*) FROM( SELECT issue_id FROM     issues LEFT JOIN items USING(itemnumber) WHERE itype IN(" . join(',', @qMarks) . ") LIMIT 1) AS T1) as itypes" );
            push( @queryCols, "(SELECT count(*) FROM( SELECT issue_id FROM old_issues LEFT JOIN items USING(itemnumber) WHERE itype IN(" . join(',', @qMarks) . ") LIMIT 1) AS T2) as old_itypes" );
            push( @havingParts, "itypes+old_itypes > 0" );
        }
        if ( $enabled->{genre_form} ) {
            push( @queryCols, "(SELECT issue_id FROM old_issues WHERE old_issues.borrowernumber = borrowers.borrowernumber AND itemnumber IN(". join(",", @itemsByGenre) . ") LIMIT 1) as genre" );
            push( @queryCols, "(SELECT issue_id FROM     issues WHERE     issues.borrowernumber = borrowers.borrowernumber AND itemnumber IN(". join(",", @itemsByGenre) . ") LIMIT 1) as old_genre" );
            push( @havingParts, "(genre IS NOT NULL OR old_genre IS NOT NULL)" );
        }
        if ( $enabled->{author} ) {
            push( @queryCols, "(SELECT issue_id FROM old_issues WHERE old_issues.borrowernumber = borrowers.borrowernumber AND itemnumber IN(". join(",", @itemsByAuthor) . ") LIMIT 1) as author" );
            push( @queryCols, "(SELECT issue_id FROM     issues WHERE     issues.borrowernumber = borrowers.borrowernumber AND itemnumber IN(". join(",", @itemsByAuthor) . ") LIMIT 1) as old_author" );
            push( @havingParts, "(author IS NOT NULL OR old_author IS NOT NULL)" );
        }

        # WHERE must be processed after SELECT parts to keep the right order of bindParams
        if ( $enabled->{sex} ) {
            unless ( $subcond->{sex} eq 'N' ) {
                push( @where, "borrowers.sex = ?" );
                push( @bindParams, $subcond->{sex} );
            }
            else {
                push( @where, "borrowers.sex NOT IN ('M', 'F')" );
            }
        }
        if ( $enabled->{age} ) {
            push( @where, "YEAR(CURRENT_DATE) - YEAR(dateofbirth) - (RIGHT(CURRENT_DATE, 5) < RIGHT(dateofbirth, 5)) BETWEEN ? AND ?" );
            push( @bindParams, $subcond->{age_from} );
            push( @bindParams, $subcond->{age_to} );
        }
        if ( $enabled->{branches} ) {
            my @branches = split(',', $subcond->{branches});
            my @qMarks;
            foreach my $branch ( @branches ) {
                push( @bindParams, $branch );
                push( @qMarks, '?' );
            }
            push( @where, "borrowers.branchcode IN (" . join(',', @qMarks) . ")" );
        }
        if ( $enabled->{renew} ) {
            push( @where, "DATEDIFF(now(), borrowers.date_renewed) / ? <= ?" );
            push( @bindParams, $period->{$subcond->{renew_period_type}} );
            push( @bindParams, $subcond->{renew_period_length} );
        }

        # retrieve results to display
        my $dbColumns = join(',', @queryCols);
        my $having = (scalar @havingParts > 0) ? "HAVING " . join(' AND ', @havingParts) : '';
        my $subconditions = join(' AND ', @where);
        my $attrAcceptMails = $self->retrieve_data('extattr_agree');

        $query = "SELECT $dbColumns "
            . " FROM borrowers "
            . " LEFT JOIN borrower_attributes ON borrower_attributes.borrowernumber = borrowers.borrowernumber AND code = \"$attrAcceptMails\""
            . " WHERE TRIM(email) != \"\" AND email IS NOT NULL AND attribute = 1 AND $subconditions "
            . "$having;";
        $sth = $dbh->prepare( $query );
        for my $i (0 .. $#bindParams) {
            $sth->bind_param($i + 1, $bindParams[$i]);
        }
        $sth->execute();

    return ($sth);
}

sub tool_get_results {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my $predefId;

    if ( defined $cgi->param('save') || defined $cgi->param('save_run') ) {
        $predefId = $self->tool_save_predef();
    }

    if ( defined $cgi->param('save') ) {
        $self->tool_list_predefs();
    }
    else {
        my $template = $self->get_template({ file => 'tool-results.tt' });

        print $cgi->header(-type => 'text/html',
                           -charset => 'utf-8');

        if ( !defined $predefId && defined $cgi->param('predef') ) {
            $predefId = $cgi->param('predef');
        }

        my ($sth) = $self->execute_sql($predefId);

        my @results;
        while ( my $row = $sth->fetchrow_hashref() ) {
            push( @results, $row->{borrowernumber} );
        }

        my $letters = C4::Letters::GetLettersAvailableForALibrary(
            {
                branchcode => C4::Context->userenv->{'branch'},
                module     => 'members',
            }
        );

        $template->param(
            borrowers => join(',', @results),
            rows => scalar @results,
            letters => $letters,
            predef => $predefId
        );

        print $template->output();
    }

}

sub tool_save_predef {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $dbh = C4::Context->dbh;
    my $table_predefs = $self->get_qualified_table_name('predefs');
    my $table_options = $self->get_qualified_table_name('predef_options');

    my $predef_id;
    my $query;
    my $sth;

    if ( defined $cgi->param('predef') ) {
        $query = "UPDATE $table_predefs SET name = ?, description = ?, last_modified = now() WHERE predef_id = ?;";

        $predef_id = scalar $cgi->param('predef');

        $sth = $dbh->prepare($query);
        $sth->execute(
            defined $cgi->param('predef-name') ? scalar $cgi->param('predef-name') : '(nepojmenováno)',
            defined $cgi->param('predef-descr') ? scalar $cgi->param('predef-descr') : undef,
            $predef_id
        );

        $query = "DELETE FROM $table_options WHERE predef_id = ?;";
        $sth = $dbh->prepare($query);
        $sth->execute($predef_id);
    }
    else {
        $query = "INSERT INTO $table_predefs (name, description, date_created, last_modified) VALUES(?, ?, now(), now());";

        $sth = $dbh->prepare($query);
        $sth->execute(
            defined $cgi->param('predef-name') ? scalar $cgi->param('predef-name') : '(nepojmenováno)',
            defined $cgi->param('predef-descr') ? scalar $cgi->param('predef-descr') : undef
        );

        $predef_id = $dbh->last_insert_id(undef, undef, $table_predefs, 'predef_id');
    }


    my @fields = qw(
        chk_sex sex
        chk_age age_from age_to
        chk_branches branches
        chk_last_visit last_visit_period_length last_visit_period_type
        chk_renew renew_period_length renew_period_type
        chk_issues issues_op issues issues_period_length issues_period_type
        chk_reserves reserves_op reserves reserves_period_length reserves_period_type
        chk_bbox bbox_op bbox bbox_period_length bbox_period_type
        chk_itemtypes itemtypes
        chk_genre_form genre_form
        chk_author author
        chk_issue_length issue_length issue_length_type issue_length_period_length issue_length_period_type
        chk_prolongs prolongs prolongs_op prolongs_period_length prolongs_period_type
        chk_fines fines fines_op fines_period_length fines_period_type
        chk_services services services_count services_op services_count_period_length services_count_period_type
    );
    my %multi = map { $_ => 1 } qw(
        itemtypes
        services
        branches
    );

    my @data;
    for my $f (@fields) {
        if ( defined $cgi->param($f) ) {
            my $value;
            if ( exists( $multi{$f} ) ) {
                my @options = $cgi->multi_param($f);
                $value = join(',', @options);
            }
            else {
                $value = scalar $cgi->param($f);
            }
            push( @data, ($predef_id, $f, $value) );
        }
    }

    $query = "INSERT INTO $table_options (predef_id, variable, value) VALUES ";
    $query .= "(?, ?, ?)," x (scalar @data / 3);
    $query =~ s/,$/;/g;

    $sth = $dbh->prepare($query);
    $sth->execute( @data );

    return $predef_id;
}

sub tool_delete_predef {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    if ( defined $cgi->param('predef') ) {
        my $dbh = C4::Context->dbh;
        my $table_predefs = $self->get_qualified_table_name('predefs');

        my $query = "DELETE FROM $table_predefs WHERE predef_id = ?;";

        my $sth = $dbh->prepare($query);
        $sth->execute( scalar $cgi->param('predef') );
    }

    $self->tool_list_predefs();
}

sub tool_duplicate_predef {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    if ( defined $cgi->param('predef') ) {
        my $dbh = C4::Context->dbh;
        my $table_predefs = $self->get_qualified_table_name('predefs');
        my $table_options = $self->get_qualified_table_name('predef_options');

        my $query = "INSERT INTO $table_predefs (name, description, date_created, last_modified) SELECT CONCAT('(kopie ', ? ') ', name), description, now(), now() FROM $table_predefs WHERE predef_id = ?;";
        my $sth = $dbh->prepare($query);
        $sth->execute( $cgi->param('predef'), $cgi->param('predef') );
        my $new_predef_id = $dbh->last_insert_id(undef, undef, $table_predefs, 'predef_id');

        $query = "INSERT INTO $table_options (predef_id, variable, value) SELECT ?, variable, value FROM $table_options WHERE predef_id = ?;";
        $sth = $dbh->prepare($query);
        $sth->execute( $new_predef_id, $cgi->param('predef') );
    }

    $self->tool_list_predefs();
}

sub tool_send_mail {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'tool-send-mail.tt' });
    print $cgi->header(-type => 'text/html',
                       -charset => 'utf-8');

    if ( defined $cgi->param('recipients') ) {
        my @idList = split(/,/, $cgi->param('recipients'));
        my @borrowers = Koha::Patrons->search({borrowernumber => { -in => \@idList }});

        foreach my $borrower (@borrowers) {
            if ( !$borrower->email ) {
                next;
            }

            my $library = Koha::Libraries->find($borrower->branchcode)->unblessed;
            if ( my $letter =  C4::Letters::GetPreparedLetter (
                module => 'members',
                letter_code => $cgi->param('letter'),
                branchcode => $borrower->branchcode,,
                tables => {
                    'branches'    => $library,
                    'borrowers'   => $borrower->unblessed,
                },
            ) ) {

                my $admin_email_address = $library->{'branchemail'} || C4::Context->preference('KohaAdminEmailAddress');

                C4::Letters::EnqueueLetter(
                    {   letter                 => $letter,
                        borrowernumber         => $borrower->borrowernumber,
                        message_transport_type => 'email',
                        from_address           => $admin_email_address,
                        to_address             => $borrower->email,
                    }
                );
            }

        }

        $template->param(
            sent_letters => scalar @borrowers,
            status => 'ok'
        );

    }
    else {
        $template->param(
            status => 'error'
        );
    }

    print $template->output();
}


1;
