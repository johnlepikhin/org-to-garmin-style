#!/usr/bin/perl

use 5.010;
use warnings;
use strict;
use Org::Parser;
use Path::Tiny;
use File::Slurp;
use Carp;
use Pod::Usage;
use Getopt::Long;

my ( $org_file, $output_directory );

GetOptions(
    q{org-file=s}         => \$org_file,
    q{output-directory=s} => \$output_directory
);

if ( !defined $org_file || !defined $output_directory ) {
    pod2usage( -verbose => 2 );
}

my $codepage = 1251;

binmode STDOUT, ':utf8';

my $orgp = Org::Parser->new();

# parse a file
my $doc = $orgp->parse_file($org_file);

my %props = %{ $doc->properties() };

my $family_id = $props{FAMILY_ID}
  // croak "Cannot get FAMILY_ID from file header";
my $product_id    = $props{PRODUCT_ID}    // 1;
my $style_name    = $props{STYLE_NAME}    // 'generated';
my $style_version = $props{STYLE_VERSION} // 1;
my $style_summary = $props{STYLE_SUMMARY} // 'Automatically generated style';
my $style_description = $props{STYLE_DESCRIPTION} // q{};
my $style_directory = "$output_directory/styles/$style_name";
foreach ( $output_directory, "$output_directory/styles", $style_directory ) {
    mkdir $_;
}

my ($org_basedir) = $org_file =~ m{(.*)/};
$org_basedir //= './';

my ( %out, %used_ids );

sub getfh ($) {
    if ( exists $out{ $_[0] } ) {
        return $out{ $_[0] };
    }

    my $fname;
    if ( $_[0] eq 'polygon' ) {
        $fname = 'polygons';
    }
    elsif ( $_[0] eq 'line' ) {
        $fname = 'lines';
    }
    elsif ( $_[0] eq 'point' ) {
        $fname = 'points';
    }
    else {
        croak "Uknown type: $_[0]";
    }
    open my $fh, '>:utf8', "$style_directory/$fname";
    $out{ $_[0] } = $fh;
    return $fh;
}

my $heading;

$doc->walk(
    sub {
        my ($el) = @_;
        if ( $el->isa('Org::Element::Headline') ) {
            $heading = $el;
            my $garmin_id = $el->get_property( 'GARMIN_ID', 1 );
            if ( defined $garmin_id ) {
                $used_ids{$garmin_id} = 1;
                $heading->{id} = $garmin_id;
            }
            return;
        }

        if ( !defined $heading ) {
            return;
        }

        if ( $el->isa('Org::Element::Link') ) {
            my $link = $el->link();
            if ( $link =~ m{\.xpm$} ) {
                if ( exists $heading->{xpm} ) {
                    croak "XPM already defined for "
                      . $heading->title->as_string();
                }
                if ( my ($file) = $link =~ m{^file:(.*)} ) {
                    $file = "$org_basedir/$file";
                    $heading->{xpm} = path($file)->slurp
                      // croak "Cannot read file: $file";
                }
                else {
                    carp "Only file:/ links are supported for XPMs: $link";
                }
            }
            return;
        }

        if ( $el->isa('Org::Element::Block') ) {
            if (   $el->name() eq 'SRC'
                && defined $el->args()->[1]
                && $el->args()->[1] eq 'xpm.c' )
            {
                if ( exists $heading->{xpm} ) {
                    croak "XPM already defined for "
                      . $heading->title->as_string();
                }
                $heading->{xpm} = $el->raw_content(), "\n";
            }
        }
    }
);

my $last_used_id = 10;
my ( $type, $fh );
$doc->walk(
    sub {
        my ($el) = @_;
        if ( $el->isa('Org::Element::Headline') ) {
            $type = $el->get_property( 'TYPE', 1 ) // return;
            $fh = getfh($type);
            my $osm_select = $el->get_property( 'OSM_SELECT', 1 ) // return;
            my $resolution = $el->get_property( 'RESOLUTION', 1 ) // return;

            my $id = $el->{id};
            if ( !defined $id ) {
                while ( exists $used_ids{ sprintf "0x%x", $last_used_id } ) {
                    $last_used_id++;
                }
                $el->{id} = sprintf "0x%x", $last_used_id;
                $used_ids{ $el->{id} } = 1;
            }

            if ( ref $osm_select eq 'ARRAY' ) {
                $osm_select = ( join q{ }, @{$osm_select} );
            }
            print $fh "$osm_select [$el->{id} resolution $resolution]\n";
        }
        elsif ( $el->isa('Org::Element::Block') ) {
            if ( $el->name() eq 'SRC' && $el->args()->[0] eq 'typ.txt' ) {
                print $fh $el->raw_content(), "\n";
            }
        }
    }
);

foreach ( values %out ) {
    close $_;
}

write_file( "$style_directory/version", "1\n" );
write_file(
    "$style_directory/info", <<"END"
version=$style_version
summary=$style_summary
description=$style_description
END
);

open $fh, ">:encoding(cp$codepage)", "$output_directory/style.txt";
print $fh <<"END"
[_id]
FID=$family_id
ProductCode=$product_id
CodePage=$codepage
[end]

[_drawOrder]
END
  ;

$doc->walk(
    sub {
        my ($el) = @_;
        if ( !$el->isa('Org::Element::Headline') ) {
            return;
        }
        my $order = $el->get_property( 'DRAW_ORDER', 1 ) // return;
        my $type  = $el->get_property( 'TYPE',       1 ) // return;
        my $id = $el->{id} // return;
        if ( $type ne 'polygon' ) {
            return;
        }

        print $fh "Type=$id,$order\n";
    }
);

print $fh "[end]\n\n";

$doc->walk(
    sub {
        my ($el) = @_;
        if ( $el->isa('Org::Element::Headline') ) {
            my $title    = $el->title->as_string();
            my $language = $el->get_property( 'LANGUAGE', 1 );
            my $type     = $el->get_property( 'TYPE', 1 );

            if ( defined $type && defined $language && defined $el->{xpm} ) {
                my $id = $el->{id} // return;

                my $xpm_processed;
                foreach ( split m{\n}, $el->{xpm} ) {
                    if (m{^"([^"]+)}) {
                        $xpm_processed .= "\"$1\"\n";
                    }
                }
                print $fh <<"END"
[_$type]
Type=$id
String1=$language,$title
Xpm=$xpm_processed
[end]

END
            }
        }
    }
);

close $fh;

if ( !chdir $output_directory ) {
    croak "Cannot chdir() to $output_directory";
}
my $rc = system 'zip', '-qr9', "$output_directory/style.zip", 'styles';
if ($rc) {
    print "ERROR: zip failed\n";
}

open $fh, ">", "$output_directory/mkgmap-args.txt";
print $fh <<"END"
generate-sea: land-tag=natural=background
location-autofill: is_in,nearest
housenumbers
tdbfile
show-profiles: 1
ignore-maxspeeds
add-pois-to-areas
add-pois-to-lines
link-pois-to-ways
make-opposite-cycleways
process-destination
process-exits
preserve-element-order
net
route
index
nsis
gmapsupp
unicode
family-id: $family_id
code-page: $codepage
style-file: $output_directory/style.zip
style: $style_name
END
  ;

close $fh;

print <<"END"
DONE. Typical next steps:

 1. mkdir /tmp/temp-dir && cd /tmp/temp-dir
 2. splitter.jar --num-tiles=4 --mapid=12345678 --keep-complete=false /path/to/map.osm
 3. mkgmap -c $output_directory/mkgmap-args.txt --description='my map' *.pbf $output_directory/style.txt

Or without splitting:

 1. mkdir /tmp/temp-dir && cd /tmp/temp-dir
 2. mkgmap -c $output_directory/mkgmap-args.txt -n 12345678 --description='my map' /path/to/map.osm
END

__END__

=head1 NAME
=encoding utf-8

org-to-style - Emacs orgmode to mkgmap style file converter

=head1 SYNOPSIS

org-to-style --org-file=my-style.org --output-directory=/tmp/mkgmap-style

=head1 DESCRIPTION

This is an attempt to simplify developement of mkgmap style files. All
manual workflow is done using Emacs org-mode and any graphical editor
which support XPM (I use Gimp).

For details see:

https://johnlepikhin.github.io/blog/2017/11/04/создание-своих-карт-для-gps
