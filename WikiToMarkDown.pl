#!/usr/bin/perl
# Convert PukiWiki contents to Gollum contents.

use strict;
use warnings;
use utf8;
use Encode;
use FindBin::libs;
use YAML::Syck qw(LoadFile DumpFile Dump);
use Path::Class qw(file dir);
use Term::Encoding qw(term_encoding);
my $charsetConsole = term_encoding;
use open ':std' => ':locale';

$|                           = 1;
$YAML::Syck::ImplicitUnicode = 1;

@ARGV = map { decode( $charsetConsole, $_ ); } @ARGV;

#my $start = shift or usage();

my $fileConfig = 'config.yml';
my $config = LoadFile( encode( $charsetConsole, "${FindBin::RealBin}/${fileConfig}" ) )
    or die("${fileConfig}: $!");
my $refHex           = qr/^[0-9A-Fa-f]+$/;
my $regCharEscape    = join( "|", map { quotemeta($_); } split( //, $config->{'CharEscape'} ) );
my $regTableStart    = qr/^(\|.*)\|([hfc]?)$/;
my $regTableItem     = qr/\|\s*~?([^\|]*)\s*/;
my $regTableModifier = qr/^(LEFT|CENTER|RIGHT|BGCOLOR\([^\)]+\)|COLOR\([^\)]+\)|SIZE\([^\)]+\)):~?/;
my $regInterWikiName = qr/\[\[(?:([^>\[]+)>)?(\S+?):([^\]]+)\]\]/;
my $regRef           = qr/&ref\(([^\),]+)(\.[^\.\),]+)[^\)]*\);/;
my $indent           = 0
    ? '    '    # PanDoc
    : '  ';     # CommonMark

my %interWikiNames = loadInterWikiName();
my $paths          = [ sort( glob( $config->{'FolderIn'} . "*" ) ) ];
convertPaths($paths);

sub usage {
    die("usage: PukiwikiToGollum.pl\n");
}

sub loadInterWikiName {
    my $path = $config->{'FolderIn'} . '496E74657257696B694E616D65.txt';    # InterWikiName.txt
    if ( !( -f $path ) ) {
        return;
    }
    my $body  = slurp( file_local($path) );
    my %names = map {
        if (/\[(https?:\S+)\s(\S+)\]\s*(\S*)/) {
            $2 => { URI => $1, Replace => index( $1, '$1' ) >= 0, Encoding => $3 || 'std' };
        } else {
            '.' => {};
        }
    } split( /\r?\n/, $body );
    delete $names{'.'};
    return %names;
}

sub convertPaths {
    my $paths = shift or return;
    my $total = scalar( @{$paths} );
    my $index = 0;
    foreach my $path ( @{$paths} ) {
        ++$index;
        my $fileIn = file_local($path);
        my $nameIn = $fileIn->basename;
        $nameIn =~ s/\.txt$//;
        if ( length($nameIn) % 2 != 0 || !( $nameIn =~ $refHex ) ) {
            print "${index}/${total}\tInvalid Filename: ${nameIn}\n";
            next;
        }
        my $nameDecoded = decode( 'UTF-8', pack( "H*", $nameIn ) );
        $nameDecoded =~ s/($regCharEscape)/'%' . unpack("H2", $1)/ge;
        my @dirs = split( /\\|\//, $nameDecoded );
        my $nameOut = pop(@dirs);
        if ( !!@dirs ) {
            my $dir = dir_local( join( "/", ( $config->{'FolderOut'}, @dirs ) ) );
            $dir->mkpath();
        }
        $nameOut = join( "/", ( @dirs, $nameOut . '.md' ) );
        if ( $index % 100 == 1 || $index >= $total ) {
            print "${index}/${total}\t${nameOut} \r";
        }
        my $fileOut = file_local( $config->{'FolderOut'} . $nameOut );
        spew( $fileOut, convertStyle( slurp($fileIn) ) );
    }
    print "\n";
}

sub file_local {
    my $path = shift or return;
    return file( encode( $charsetConsole, $path ) );
}

sub dir_local {
    my $path = shift or return;
    return dir( encode( $charsetConsole, $path ) );
}

sub slurp {
    my $file = shift or return;
    my $charset = shift || 'UTF-8';
    return decode( $charset, join( "", $file->slurp( { iomode => '<:raw', } ) ) );
}

sub spew {
    my $file    = shift or return;
    my $content = shift or return;
    my $charset = shift || 'UTF-8';
    $file->spew( iomode => '>:raw', encode( $charset, $content ) );
}

sub convertStyle {
    my $body      = shift or return;
    my $modeCode  = undef;
    my $modeBlock = 0;
    my $modeTable = 0;
    my @lines     = ();
    foreach my $line ( split( /\r?\n/, $body ) ) {
        if ( !!$modeCode ) {    # in Code
            if ( $line =~ /$modeCode/ ) {    # Code end
                $modeCode = undef;
                push( @lines, '```' );
            } else {
                push( @lines, $line );
            }
        } elsif ($modeBlock) {    # in Block
            if ( substr( $line, 0, 1 ) ne ' ' ) {    # Block end
                $modeBlock = 0;
                push( @lines, '```' );
                redo;
            } else {
                push( @lines, substr( $line, 1 ) );
            }
        } elsif ($modeTable) {    # in Table
            if ( $line !~ $regTableStart ) {    # Table end
                $modeTable = 0;
                redo;
            } else {
                if ( $2 eq 'c' ) {              # Table format
                    next;
                }
                my @values = removeTableModifier($1);
                push( @lines, "| " . join( " | ", @values ) . " |" );
            }
        } elsif ( $line =~ /^#code\((?<lang>[^\)]+)\)(?<bracket>\{+)/ ) {    # Code start
            $modeCode = '\\}' x length( $+{'bracket'} );
            push( @lines, '```' . $+{'lang'} );
        } elsif ( substr( $line, 0, 1 ) eq ' ' ) {                           # Block start
            $modeBlock = 1;
            push( @lines, '```' );
            push( @lines, substr( $line, 1 ) );
        } elsif ( $line =~ $regTableStart ) {                                # Table start
            if ( $2 eq 'c' ) {                                               # Table format
                next;
            }
            $modeTable = 1;
            my @header = removeTableModifier($1);
            push( @lines, "| " . join( " | ", @header ) . " |" );
            push( @lines, "|" . ( " --- |" x scalar(@header) ) );
        } elsif ( $line =~ s/^\/\/(.*)$/<!---$1-->/ ) {    # Comment
            push( @lines, $line );
        } elsif ( $line eq '#contents' ) {                 # Table-of-contents (TOC)
            push( @lines, '[[_TOC_]]' );
        } elsif ( $line eq '#br' ) {                       # Line Break (Block)
            push( @lines, '<br />' );
        } elsif ( $line =~ s/^(#[_A-Za-z].*)$/~~$1~~/ )
        {    # Block Plugin, TODO: convert to Custom Macro.
            push( @lines, $line );
        } elsif ( $line =~ /^(\*+)(.*?)\s*\[#[^\]]+\]\s*$/ ) {    # Header
            push( @lines, ( "#" x length($1) ) . $2 );
        } elsif ( $line =~ /^-{4,}/ ) {                           # Horizontal Line
            push( @lines, $line );
        } elsif ( $line =~ s/^(-{1,3})[~\s]?\s*/makeList($1, '-')/e ) {    # Unordered List
            $line = convertInline($line);
            push( @lines, $line );
        } elsif ( $line =~ s/^(\+{1,3})[~\s]?\s*/makeList($1, '1.')/e ) {    # Ordered List
            $line = convertInline($line);
            push( @lines, $line );
        } else {
            $line = convertInline($line);
            push( @lines, $line );
        }
    }
    return join( "\n", @lines );
}

sub removeTableModifier {
    my $row = shift or return;
    my @items = ();
    foreach my $item ( $row =~ /$regTableItem/g ) {
        while ( $item =~ s/$regTableModifier// ) { }
        $item = convertInline($item);
        push( @items, $item );
    }
    return @items;
}

sub makeList {
    my $identifierIn  = shift or return;
    my $identifierOut = shift or return;
    return ( $indent x ( length($identifierIn) - 1 ) ) . "${identifierOut} ";
}

sub convertInline {
    my $line = shift or return '';
    $line =~ s/\[\[(.+?)(:|>)(https?:[^\]]+)\]\]/[$1]($3)/g;           # Link
    $line =~ s/$regInterWikiName/replaceInterWikiName($1,$2,$3)/ge;    # InterWikiName
    $line =~ s/$regRef/replaceRef($1,$2)/ge;                           # Reference
    $line =~ s/&br;/<br \/>/g;                                         # Line Break (Inline)
    $line =~ s/(\s*)(''')(.*?)\2(\s*)/$1*$3*$4/g;                      # Italic
    $line =~ s/(\s*)('')(.*?)\2(\s*)/$1**$3**$4/g;                     # Strong
    $line =~ s/(\s*)(%%)(.*?)\2(\s*)/$1~~$3~~$4/g;                     # Strikethrough
    return $line;
}

sub replaceInterWikiName {
    my ( $alias, $name, $param ) = @_;
    if ( !exists( $interWikiNames{$name} ) ) {
        return !$alias
            ? "[[$name:$param]]"
            : "[[$alias>$name:$param]]";
    } else {
        my $interWiki = $interWikiNames{$name};
        my $uri       = $interWiki->{'URI'};
        my $enc       = $interWiki->{'Encoding'};
        if ( exists( $config->{'InterWikiEncodings'}{$enc} ) ) {
            $enc = $config->{'InterWikiEncodings'}{$enc};
        }
        my $paramEnc
            = $enc eq 'raw' || $enc eq 'yw' || $enc eq 'moin'
            ? $param
            : join( "", map { '%' . unpack( 'H2', $_ ) } split( //, encode( $enc, $param ) ) );
        if ( $interWiki->{'Replace'} ) {
            $uri =~ s/\$1/$paramEnc/;
        } else {
            $uri .= $paramEnc;
        }
        return !$alias
            ? "[$name:$param]($uri)"
            : "[$alias]($uri)";
    }
}

sub replaceRef {
    my $name = shift or return;
    my $ext  = shift or return;
    $name .= $ext;
    $ext = lc($ext);
    my $image = ( grep { $_ eq $ext } @{ $config->{'ImageExtensions'} } ) ? '!' : '';
    return "${image}[${name}](${name})";
}

# EOF
