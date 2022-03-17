# Copyright © (2011) Institut national de l'information
#                    géographique et forestière 
# 
# Géoportail SAV <contact.geoservices@ign.fr>
# 
# This software is a computer program whose purpose is to publish geographic
# data using OGC WMS and WMTS protocol.
# 
# This software is governed by the CeCILL-C license under French law and
# abiding by the rules of distribution of free software.  You can  use, 
# modify and/ or redistribute the software under the terms of the CeCILL-C
# license as circulated by CEA, CNRS and INRIA at the following URL
# "http://www.cecill.info". 
# 
# As a counterpart to the access to the source code and  rights to copy,
# modify and redistribute granted by the license, users are provided only
# with a limited warranty  and the software's author,  the holder of the
# economic rights,  and the successive licensors  have only  limited
# liability. 
# 
# In this respect, the user's attention is drawn to the risks associated
# with loading,  using,  modifying and/or developing or reproducing the
# software by the user in light of its specific status of free software,
# that may mean  that it is complicated to manipulate,  and  that  also
# therefore means  that it is reserved for developers  and  experienced
# professionals having in-depth computer knowledge. Users are therefore
# encouraged to load and test the software's suitability as regards their
# requirements in conditions enabling the security of their systems and/or 
# data to be ensured and,  more generally, to use and operate it in the 
# same conditions as regards security. 
# 
# The fact that you are presently reading this means that you have had
# 
# knowledge of the CeCILL-C license and that you accept its terms.

################################################################################

=begin nd
File: LevelRaster.pm

Class: ROK4::Core::LevelRaster

(see libperlauto/Core_LevelRaster.png)

Describe a level in a raster pyramid.

Using:
    (start code)
    use ROK4::Core::LevelRaster;

    # From values
    my $valuesLevel = ROK4::Core::LevelRaster->new("VALUES",{
        id => "12",
        tm => $tms->getTileMatrix("12"),
        size => [16, 16],

        prefix => "TOTO_",
        bucket_name => "MyBucket"
    });

    # From XML element
    my $level = ROK4::Core::LevelRaster->new("XML", $xmlElement);
    $level->bindTileMatrix($tms)

    # From JSON object
    my $level = ROK4::Core::LevelRaster->new("JSON", $jsonObject);
    $level->bindTileMatrix($tms)

    (end code)

Attributes:
    id - string - Level identifiant.
    order - integer - Level order (ascending resolution)
    tm - <ROK4::Core::TileMatrix> - Binding Tile Matrix to this level
    type - string - Storage type of data : FILE, S3 or CEPH

    size - integer array - Number of tile in one image for this level, widthwise and heightwise : [width, height].
    limits - integer array - Extrems columns and rows for the level (Extrems tiles which contains data) : [rowMin,rowMax,colMin,colMax]

    desc_path - string - Directory path of the pyramid's descriptor containing this level (not defined for object storage)
    dir_depth - integer - Number of subdirectories from the level root to the image if FILE storage type : depth = 2 => /.../LevelID/SUB1/SUB2/DATA.tif
    dir_image - string - Directory in which we write the pyramid's images if FILE storage type
    dir_mask - string - Directory in which we write the pyramid's masks if FILE storage type

    prefix_image - string - Prefix used to name the image objects, in CEPH or S3 storage (contains the pyramid's name and the level's id)
    prefix_mask - string - Prefix used to name the mask objects, in CEPH or S3 storage (contains the pyramid's name and the level's id)

    bucket_name - string - Name of the (existing) S3 bucket, where to store data if S3 storage type

    container_name - string - Name of the (existing) SWIFT container, where to store data if SWIFT storage type

    pool_name - string - Name of the (existing) CEPH pool, where to store data if CEPH storage type
=cut

################################################################################

package ROK4::Core::LevelRaster;

use strict;
use warnings;

use Log::Log4perl qw(:easy);
use XML::LibXML;
use File::Spec;
use Cwd;
use Data::Dumper;


use ROK4::Core::TileMatrix;
use ROK4::Core::TileMatrixSet;
use ROK4::Core::Base36;

################################################################################
# Constantes
use constant TRUE  => 1;
use constant FALSE => 0;

################################################################################

BEGIN {}
INIT {}
END {}

####################################################################################################
#                                        Group: Constructors                                       #
####################################################################################################

=begin nd
Constructor: new

Level constructor. Bless an instance.

Parameters (hash):
    type - string - XML
    params - <XML::LibXML::Element> - XML node of the level (from the pyramid's descriptor)
        or
    type - string - JSON
    params - hash - JSON object of the level (from the pyramid's descriptor)
        or
    type - string - VALUES
    params - string hash - Hash containg all needed level informations

    descDirectory - string - Directory path of the pyramid's descriptor containing this level (not defined for object storage)

See also:
    <_loadXML>, <_loadJSON>, <_loadValues>
=cut
sub new {
    my $class = shift;
    my $type = shift;
    my $params = shift;
    my $descDirectory = shift;

    $class= ref($class) || $class;
    # IMPORTANT : if modification, think to update natural documentation (just above)
    my $this = {
        id => undef,
        order => undef,
        tm => undef,
        type => undef,

        size => [],
        limits => undef, # rowMin,rowMax,colMin,colMax

        # ABOUT PYRAMID

        # CAS FICHIER
        desc_path => undef,
        dir_depth => undef,
        dir_image => undef,
        dir_mask => undef,

        # CAS OBJET
        prefix_image => undef,
        prefix_mask => undef,
        #    - S3
        bucket_name => undef,
        #    - SWIFT
        container_name => undef,
        #    - CEPH
        pool_name => undef
    };
    
    bless($this, $class);

    $this->{desc_path} = $descDirectory;

    if ($type eq "XML") {
        if ( ! $this->_loadXML($params) ) {
            ERROR("Cannot load Level XML");
            return undef;
        }
    }
    elsif ($type eq "JSON") {
        if ( ! $this->_loadJSON($params) ) {
            ERROR("Cannot load Level JSON");
            return undef;
        }
    } else {
        if (! $this->_loadValues($params)) {
            ERROR ("One parameter is missing !");
            return undef;
        }
    }
    
    # STOCKAGE TYPE AND ENVIRONMENT VARIABLES CONTROLS
    if ( defined $this->{dir_depth} ) {
        $this->{type} = "FILE";
    }
    elsif ( defined $this->{bucket_name} ) {
        $this->{type} = "S3";

        if (! ROK4::Core::ProxyStorage::checkEnvironmentVariables("S3")) {
            ERROR("Environment variable is missing for a S3 storage");
            return FALSE;
        }
    }
    elsif ( defined $this->{pool_name} ) {
        $this->{type} = "CEPH";

        if (! ROK4::Core::ProxyStorage::checkEnvironmentVariables("CEPH")) {
            ERROR("Environment variable is missing for a CEPH storage");
            return FALSE;
        }
    }
    elsif ( defined $this->{container_name} ) {
        $this->{type} = "SWIFT";

        if (! ROK4::Core::ProxyStorage::checkEnvironmentVariables("SWIFT")) {
            ERROR("Environment variable is missing for a SWIFT storage");
            return FALSE;
        }
    } else {
        ERROR ("Cannot identify the storage type for the ROK4::Core::LevelRaster");
        return undef;
    }

    return $this;
}

=begin nd
Function: _initValues

Check and store level's attributes values.

Parameter:
    params - hash - Hash containg all needed level informations
=cut
sub _loadValues {
    my $this   = shift;
    my $params = shift;
  
    return FALSE if (! defined $params);
    
    # PARTIE COMMUNE
    if (! exists($params->{id})) {
        ERROR ("The parameter 'id' is required");
        return FALSE;
    }
    $this->{id} = $params->{id};

    if (! exists($params->{tm})) {
        ERROR ("The parameter 'tm' is required");
        return FALSE;
    }
    if (ref ($params->{tm}) ne "ROK4::Core::TileMatrix") {
        ERROR ("The parameter 'tm' is not a COMMON:TileMatrix");
        return FALSE;
    }
    $this->{tm} = $params->{tm};
    $this->{order} = $params->{tm}->getOrder();

    if (! exists($params->{size})) {
        ERROR ("The parameter 'size' is required");
        return FALSE;
    }
    # check values
    if (! scalar ($params->{size})){
        ERROR("List empty to 'size' !");
        return FALSE;
    }
    $this->{size} = $params->{size};
    
    if (! exists($params->{limits}) || ! defined($params->{limits})) {
        $params->{limits} = [undef, undef, undef, undef];
    }
    $this->{limits} = $params->{limits};

    # STOCKAGE    
    if ( exists $params->{dir_depth} ) {
        # CAS FICHIER
        if (! exists($params->{dir_depth})) {
            ERROR ("The parameter 'dir_depth' is required");
            return FALSE;
        }
        if (! $params->{dir_depth}){
            ERROR("Value not valid for 'dir_depth' (0 or undef) !");
            return FALSE;
        }
        $this->{dir_depth} = $params->{dir_depth};

        if (! exists($params->{dir_data})) {
            ERROR ("The parameter 'dir_data' is required");
            return FALSE;
        }


        $this->{dir_image} = File::Spec->catdir($params->{dir_data}, "DATA", $this->{id});

        if (exists $params->{hasMask} && defined $params->{hasMask}) {
            $this->{dir_mask} = File::Spec->catdir($params->{dir_data}, "MASK", $this->{id});
        }
    }
    elsif ( exists $params->{prefix} ) {
        # CAS OBJET
        $this->{prefix_image} = sprintf "%s/DATA_%s", $params->{prefix}, $this->{id};

        if (exists $params->{hasMask} && defined $params->{hasMask} && $params->{hasMask} ) {
            $this->{prefix_mask} = sprintf "%s/MASK_%s", $params->{prefix}, $this->{id};
        }

        if ( exists $params->{bucket_name} ) {
            # CAS S3
            $this->{bucket_name} = $params->{bucket_name};
        }
        elsif ( exists $params->{pool_name} ) {
            # CAS CEPH
            $this->{pool_name} = $params->{pool_name};
        }
        elsif ( exists $params->{container_name} ) {
            # CAS SWIFT
            $this->{container_name} = $params->{container_name};
        }
        else {
            ERROR("No container name (bucket or pool or container) for object storage for the level");
            return FALSE;        
        }
    }
    else {
        ERROR("No storage (neither file nor object) for the level");
        return FALSE;        
    }

    return TRUE;
}

=begin nd
Function: _loadXML

Extract level's information from the XML element

Parameter:
    levelRoot - <XML::LibXML::Element> - XML node of the level (from the pyramid's descriptor)
=cut
sub _loadXML {
    my $this   = shift;
    my $levelRoot = shift;

    $this->{id} = $levelRoot->findvalue('tileMatrix');
    if (! defined $this->{id} || $this->{id} eq "" ) {
        ERROR ("Cannot extract 'tileMatrix' from the XML level");
        return FALSE;
    }

    $this->{size} = [ $levelRoot->findvalue('tilesPerWidth'), $levelRoot->findvalue('tilesPerHeight') ];
    if (! defined $this->{size}->[0] || $this->{size}->[0] eq "" ) {
        ERROR ("Cannot extract image's tilesize from the XML level");
        return FALSE;
    }

    $this->{limits} = [
        $levelRoot->findvalue('TMSLimits/minTileRow'),
        $levelRoot->findvalue('TMSLimits/maxTileRow'),
        $levelRoot->findvalue('TMSLimits/minTileCol'),
        $levelRoot->findvalue('TMSLimits/maxTileCol')
    ];
    if (! defined $this->{limits}->[0] || $this->{limits}->[0] eq "") {
        ERROR ("Cannot extract extrem tiles from the XML level");
        return FALSE;
    }

    # CAS FICHIER
    my $dirimg = $levelRoot->findvalue('baseDir');
    my $imgprefix = $levelRoot->findvalue('imagePrefix');
    
    if (defined $dirimg && $dirimg ne "" ) {
        $this->{dir_image} = File::Spec->rel2abs(File::Spec->rel2abs( $dirimg , $this->{desc_path} ) );
        
        my $dirmsk = $levelRoot->findvalue('mask/baseDir');
        if (defined $dirmsk && $dirmsk ne "" ) {
            $this->{dir_mask} = File::Spec->rel2abs(File::Spec->rel2abs( $dirmsk , $this->{desc_path} ) );
        }

        $this->{dir_depth} = $levelRoot->findvalue('pathDepth');
        if (! defined $this->{dir_depth} || $this->{dir_depth} eq "" ) {
            ERROR ("Cannot extract 'pathDepth' from the XML level");
            return FALSE;
        }
    }
    elsif (defined $imgprefix && $imgprefix ne "" ) {
        $this->{prefix_image} = $imgprefix;

        my $mskprefix = $levelRoot->findvalue('mask/maskPrefix');
        if (defined $mskprefix && $mskprefix ne "" ) {
            $this->{prefix_mask} = $mskprefix;
        }

        my $pool = $levelRoot->findvalue('cephContext/poolName');
        my $bucket = $levelRoot->findvalue('s3Context/bucketName');
        my $container = $levelRoot->findvalue('swiftContext/containerName');

        if ( defined $bucket && $bucket ne "" ) {
            # CAS S3
            $this->{bucket_name} = $bucket;
        }
        elsif ( defined $pool && $pool ne "" ) {
            # CAS CEPH
            $this->{pool_name} = $pool;
        }
        elsif ( defined $container && $container ne "" ) {
            # CAS SWIFT
            $this->{container_name} = $container;
        }
        else {
            ERROR("No container name (bucket or pool) for object storage for the level");
            return FALSE;        
        }
    }

    return TRUE;
}


=begin nd
Function: _loadJSON

Extract level's information from the JSON element

Parameter:
    levelRoot - hash - JSON object of the level (from the pyramid's descriptor)
=cut
sub _loadJSON {
    my $this   = shift;
    my $level_json_object = shift;

    if (! exists $level_json_object->{id}) {
        ERROR (sprintf "Can not extract 'id' from the JSON Level");
        return FALSE;
    }
    $this->{id} = $level_json_object->{id};

    if (! exists $level_json_object->{tiles_per_width} || ! exists $level_json_object->{tiles_per_height} ) {
        ERROR ("Cannot extract image's tile size from the JSON level");
        return FALSE;
    }
    $this->{size} = [ $level_json_object->{tiles_per_width}, $level_json_object->{tiles_per_height} ];

    if (! exists $level_json_object->{tile_limits}) {
        ERROR ("Cannot extract extrem tiles from the JSON level");
        return FALSE;
    }
    $this->{limits} = [
        $level_json_object->{min_row},
        $level_json_object->{max_row},
        $level_json_object->{min_col},
        $level_json_object->{max_col}
    ];

    # STOCKAGE

    if (! exists $level_json_object->{storage}->{type}) {
        ERROR ("Cannot extract storage type from the JSON level");
        return FALSE;
    }

    if ($level_json_object->{storage}->{type} eq "FILE") {
        # CAS FICHIER
        if (! exists $level_json_object->{storage}->{image_directory}) {
            ERROR ("Cannot extract image directory from the JSON level");
            return FALSE;
        }
        $this->{dir_image} = File::Spec->rel2abs(File::Spec->rel2abs( $level_json_object->{storage}->{image_directory} , $this->{desc_path} ) );
        
        if ( exists $level_json_object->{storage}->{mask_directory} ) {
            $this->{dir_mask} = File::Spec->rel2abs(File::Spec->rel2abs( $level_json_object->{storage}->{mask_directory} , $this->{desc_path} ) );
        }

        if (! exists $level_json_object->{storage}->{path_depth}) {
            ERROR ("Cannot extract path depth from the JSON level");
            return FALSE;
        }
        $this->{dir_depth} = $level_json_object->{storage}->{path_depth};
    } else {
        # CAS OBJET
        if (! exists $level_json_object->{storage}->{image_prefix}) {
            ERROR ("Cannot extract image prefix from the JSON level");
            return FALSE;
        }
        $this->{prefix_image} = $level_json_object->{storage}->{image_prefix};

        if ( exists $level_json_object->{storage}->{mask_prefix} ) {
            $this->{prefix_mask} = $level_json_object->{storage}->{mask_prefix};
        }

        if ($level_json_object->{storage}->{type} eq "S3") {
            # CAS S3
            if (! exists $level_json_object->{storage}->{bucket_name}) {
                ERROR ("Cannot extract bucket name from the JSON level");
                return FALSE;
            }
            $this->{bucket_name} = $level_json_object->{storage}->{bucket_name};
        }
        elsif ($level_json_object->{storage}->{type} eq "CEPH") {
            # CAS CEPH
            if (! exists $level_json_object->{storage}->{pool_name}) {
                ERROR ("Cannot extract pool name from the JSON level");
                return FALSE;
            }
            $this->{pool_name} = $level_json_object->{storage}->{pool_name};
        }
        elsif ($level_json_object->{storage}->{type} eq "SWIFT") {
            # CAS SWIFT
            if (! exists $level_json_object->{storage}->{container_name}) {
                ERROR ("Cannot extract container name from the JSON level");
                return FALSE;
            }
            $this->{container_name} = $level_json_object->{storage}->{container_name};
        }
        else {
            ERROR("Unknown object storage type for the level");
            return FALSE;        
        }
    }

    return TRUE;
}

####################################################################################################
#                                Group: Getters - Setters                                          #
####################################################################################################


# Function: getID
sub getID {
    my $this = shift;
    return $this->{id};
}

# Function: getDirDepth
sub getDirDepth {
    my $this = shift;
    return $this->{dir_depth};
}

# Function: getDirImage
sub getDirImage {
    my $this = shift;
    return $this->{dir_image};
}

# Function: getDirMask
sub getDirMask {
    my $this = shift;
    return $this->{dir_mask};
}

# Function: getDirsInfo
sub getDirsInfo {
    my $this = shift;

    if ($this->{type} ne "FILE") {
        return (undef, undef);
    }

    my @dirs = File::Spec->splitdir($this->{dir_image});
    # On enlève de la fin le dossier du niveau, le dossier du type de données et celui du nom de la pyramide
    pop(@dirs);pop(@dirs);pop(@dirs);
    my $dir_data = File::Spec->catdir(@dirs);

    return ($this->{dir_depth}, $dir_data);
}
# Function: getS3Info
sub getS3Info {
    my $this = shift;

    if ($this->{type} ne "S3") {
        return undef;
    }

    return $this->{bucket_name};
}
# Function: getSwiftInfo
sub getSwiftInfo {
    my $this = shift;

    if ($this->{type} ne "SWIFT") {
        return undef;
    }

    return $this->{container_name};
}
# Function: getCephInfo
sub getCephInfo {
    my $this = shift;

    if ($this->{type} ne "CEPH") {
        return undef;
    }

    return $this->{pool_name};
}

# Function: getStorageType
sub getStorageType {
    my $this = shift;
    return $this->{type};
}

# Function: getImageWidth
sub getImageWidth {
    my $this = shift;
    return $this->{size}->[0];
}

# Function: getImageHeight
sub getImageHeight {
    my $this = shift;
    return $this->{size}->[1];
}

=begin nd
Function: getLimits

Return extrem tiles as an array: rowMin,rowMax,colMin,colMax
=cut
sub getLimits {
    my $this = shift;
    return ($this->{limits}->[0], $this->{limits}->[1], $this->{limits}->[2], $this->{limits}->[3]);
}

# Function: getOrder
sub getOrder {
    my $this = shift;
    return $this->{order};
}

# Function: getTileMatrix
sub getTileMatrix {
    my $this = shift;
    return $this->{tm};
}

=begin nd
Function: bboxToSlabIndices

Returns the extrem slab's indices from a bbox in a list : ($rowMin, $rowMax, $colMin, $colMax).

Parameters (list):
    xMin,yMin,xMax,yMax - bounding box
=cut
sub bboxToSlabIndices {
    my $this = shift;
    my @bbox = @_;

    return $this->{tm}->bboxToIndices(@bbox, $this->{size}->[0], $this->{size}->[1]);
}

=begin nd
Function: slabIndicesToBbox

Returns the bounding box from the slab's column and row.

Parameters (list):
    col,row - Slab's column and row
=cut
sub slabIndicesToBbox {
    my $this = shift;
    my $col = shift;
    my $row = shift;

    return $this->{tm}->indicesToBbox($col, $row, $this->{size}->[0], $this->{size}->[1]);
}

# Function: ownMasks
sub ownMasks {
    my $this = shift;
    return (defined $this->{dir_mask} || defined $this->{prefix_mask});
}

=begin nd
Function: getSlabPath

Returns the theoric slab path (file path or object name)

Parameters (list):
    type - string - "DATA" ou "MASK"
    col - integer - Slab column
    row - integer - Slab row
    full - boolean - Precise if we want full path or juste the end (without root)
=cut
sub getSlabPath {
    my $this = shift;
    my $type = shift;
    my $col = shift;
    my $row = shift;
    my $full = shift;

    if ($type eq "MASK" && ! $this->ownMasks()) {
        return undef;
    }

    if ($this->{type} eq "FILE") {
        my $b36 = ROK4::Core::Base36::indicesToB36Path($col, $row, $this->{dir_depth} + 1);
        if (defined $full && ! $full) {
            return File::Spec->catdir($type, $this->{id}, "$b36.tif");
        }
        return File::Spec->catdir($this->{dir_image}, "$b36.tif");
    }
    elsif ($this->{type} eq "S3") {
        if (defined $full && ! $full) {
            return sprintf "%s_%s_%s_%s", $type, $this->{id}, $col, $row;
        }
        return sprintf "%s/%s_%s_%s", $this->{bucket_name}, $this->{prefix_image}, $col, $row;
    }    
    elsif ($this->{type} eq "SWIFT") {
        if (defined $full && ! $full) {
            return sprintf "%s_%s_%s_%s", $type, $this->{id}, $col, $row;
        }
        return sprintf "%s/%s_%s_%s", $this->{container_name}, $this->{prefix_image}, $col, $row;
    }
    elsif ($this->{type} eq "CEPH") {
        if (defined $full && ! $full) {
            return sprintf "%s_%s_%s_%s", $type, $this->{id}, $col, $row;
        }
        return sprintf "%s/%s_%s_%s", $this->{pool_name}, $this->{prefix_image}, $col, $row;
    } else {
        return undef;
    }

}

=begin nd
Function: getFromSlabPath

Extract column and row from a slab path

Parameter (list):
    path - string - Path to decode, to obtain slab's column and row

Returns:
    Integers' list, (col, row)
=cut
sub getFromSlabPath {
    my $this = shift;
    my $path = shift;

    if ($this->{type} eq "FILE") {
        # 1 on ne garde que la partie finale propre à l'indexation de la dalle
        my @parts = split("/", $path);

        my @finalParts;
        for (my $i = -1 - $this->{dir_depth}; $i < 0; $i++) {
            push(@finalParts, $parts[$i]);
        }
        # 2 on enlève l'extension
        $path = join("/", @finalParts);
        $path =~ s/(\.tif|\.tiff|\.TIF|\.TIFF)//;
        return ROK4::Core::Base36::b36PathToIndices($path);

    } else {
        my @parts = split("_", $path);
        return ($parts[-2], $parts[-1]);
    }

}


=begin nd
Function: updateStorageInfos
=cut
sub updateStorageInfos {
    my $this = shift;
    my $params = shift;

    if (exists $params->{dir_depth}) {
        $this->{type} = "FILE";
        $this->{dir_depth} = $params->{dir_depth};
        $this->{desc_path} = $params->{desc_path};

        $this->{dir_image} = File::Spec->catdir($params->{dir_data}, "DATA", $this->{id});

        if ($this->ownMasks()) {
            $this->{dir_mask} = File::Spec->catdir($params->{dir_data}, "MASK", $this->{id});            
        } else {
            $this->{dir_mask} = undef;
        }
        $this->{prefix_image} = undef;
        $this->{prefix_mask} = undef;
        $this->{bucket_name} = undef;
        $this->{container_name} = undef;
        $this->{pool_name} = undef;
    } elsif ( exists $params->{pool_name} ) {
        $this->{type} = "CEPH";
        $this->{pool_name} = $params->{pool_name};
        $this->{prefix_image} = sprintf "%s/DATA_%s", $params->{prefix}, $this->{id};
        if ($this->ownMasks()) {
            $this->{prefix_mask} = sprintf "%s/MASK_%s", $params->{prefix}, $this->{id};
        } else {
            $this->{prefix_mask} = undef;
        }
        $this->{dir_depth} = undef;
        $this->{dir_image} = undef;
        $this->{dir_mask} = undef;
        $this->{bucket_name} = undef;
        $this->{container_name} = undef;
    } elsif ( exists $params->{bucket_name} ) {
        $this->{type} = "S3";
        $this->{bucket_name} = $params->{bucket_name};
        $this->{prefix_image} = sprintf "%s/DATA_%s", $params->{prefix}, $this->{id};
        if ($this->ownMasks()) {
            $this->{prefix_mask} = sprintf "%s/MASK_%s", $params->{prefix}, $this->{id};
        } else {
            $this->{prefix_mask} = undef;
        }
        $this->{dir_depth} = undef;
        $this->{dir_image} = undef;
        $this->{dir_mask} = undef;
        $this->{container_name} = undef;
        $this->{pool_name} = undef;
    } elsif ( exists $params->{container_name} ) {
        $this->{type} = "SWIFT";
        $this->{container_name} = $params->{container_name};
        $this->{prefix_image} = sprintf "%s/DATA_%s", $params->{prefix}, $this->{id};
        if ($this->ownMasks()) {
            $this->{prefix_mask} = sprintf "%s/MASK_%s", $params->{prefix}, $this->{id};
        } else {
            $this->{prefix_mask} = undef;
        }
        $this->{dir_depth} = undef;
        $this->{dir_image} = undef;
        $this->{dir_mask} = undef;
        $this->{bucket_name} = undef;
        $this->{pool_name} = undef;
    }

    return TRUE;
}

=begin nd
method: updateLimits

Compare old extrems rows/columns with the news and update values.

Parameters (list):
    rowMin, rowMax, colMin, colMax - integer list - Tiles indices to compare with current extrems
=cut
sub updateLimits {
    my $this = shift;
    my ($rowMin,$rowMax,$colMin,$colMax) = @_;

    if (! defined $this->{limits}->[0] || $rowMin < $this->{limits}->[0]) {$this->{limits}->[0] = $rowMin;}
    if (! defined $this->{limits}->[1] || $rowMax > $this->{limits}->[1]) {$this->{limits}->[1] = $rowMax;}
    if (! defined $this->{limits}->[2] || $colMin < $this->{limits}->[2]) {$this->{limits}->[2] = $colMin;}
    if (! defined $this->{limits}->[3] || $colMax > $this->{limits}->[3]) {$this->{limits}->[3] = $colMax;}
}

=begin nd
method: updateLimitsFromSlab
=cut
sub updateLimitsFromSlab {
    my $this = shift;
    my ($col,$row) = @_;

    $this->updateLimits(
        $row * $this->{size}->[1], $row * $this->{size}->[1] + ($this->{size}->[1] - 1),
        $col * $this->{size}->[0], $col * $this->{size}->[0] + ($this->{size}->[0] - 1)
    );
}


=begin nd
method: updateLimitsFromBbox
=cut
sub updateLimitsFromBbox {
    my $this = shift;
    my ($xmin, $ymin, $xmax, $ymax) = @_;

    my $colMin = $this->{tm}->xToColumn($xmin);
    my $colMax = $this->{tm}->xToColumn($xmax);
    my $rowMin = $this->{tm}->yToRow($ymax);
    my $rowMax = $this->{tm}->yToRow($ymin);

    $this->updateLimits($rowMin,$rowMax,$colMin,$colMax);
}

=begin nd
method: bindTileMatrix

For levels loaded from an XML or JSON element, we have to link the Tile Matrix (we only have the level ID).

We control if level exists in the provided TMS, and we calculate the level's order in this TMS.

Parameter:
    tms - <ROK4::Core::TileMatrixSet> - TMS containg the Tile Matrix to link to this level.
=cut
sub bindTileMatrix {
    my $this = shift;
    my $tms = shift;

    if (defined $this->{tm} ) {
        # le tm est déjà présent pour le niveau
        return TRUE;
    }

    $this->{tm} = $tms->getTileMatrix($this->{id});
    if (! defined $this->{tm}) {
        ERROR(sprintf "Cannot find a level with the id %s in the TMS", $this->{id});
        return FALSE;
    }

    $this->{order} = $tms->getOrderfromID($this->{id});

    return TRUE;
}


####################################################################################################
#                                Group: Export methods                                             #
####################################################################################################

=begin nd
Function: exportToJsonObject

Export Level's attributes in JSON object format.

=cut
sub exportToJsonObject {
    my $this = shift;

    my $level_json_object = {
        id => $this->{id},
        tiles_per_width => 0 + $this->{size}->[0],
        tiles_per_height => 0 + $this->{size}->[1]
    };

    if (defined $this->{limits}->[0]) {
        $level_json_object->{tile_limits} = {
            min_row => 0 + $this->{limits}->[0],
            max_row => 0 + $this->{limits}->[1],
            min_col => 0 + $this->{limits}->[2],
            max_col => 0 + $this->{limits}->[3]
        }
    } else {
        $level_json_object->{tile_limits} = {
            min_row => 0,
            max_row => 0,
            min_col => 0,
            max_col => 0
        }
    }

    if ($this->{type} eq "FILE") {
        $level_json_object->{storage} = {
            type => "FILE",
            image_directory => File::Spec->abs2rel($this->{dir_image}, $this->{desc_path}),
            path_depth => 0 + $this->{dir_depth}
        }
    }
    elsif ($this->{type} eq "S3") {
        $level_json_object->{storage} = {
            type => "S3",
            image_prefix => $this->{prefix_image},
            bucket_name => $this->{bucket_name}
        }
    }
    elsif ($this->{type} eq "SWIFT") {
        $level_json_object->{storage} = {
            type => "SWIFT",
            image_prefix => $this->{prefix_image},
            container_name => $this->{container_name}
        }
    }
    elsif ($this->{type} eq "CEPH") {
        $level_json_object->{storage} = {
            type => "CEPH",
            image_prefix => $this->{prefix_image},
            pool_name => $this->{pool_name}
        }
    }

    if ($this->ownMasks()) {
        if ($this->{type} eq "FILE") {
            $level_json_object->{storage}->{mask_directory} = File::Spec->abs2rel($this->{dir_mask}, $this->{desc_path});
        } else {
            $level_json_object->{storage}->{mask_prefix} = $this->{prefix_mask};
        }
    }

    return $level_json_object;
}


####################################################################################################
#                                   Group: Clone function                                          #
####################################################################################################

=begin nd
Function: clone

Clone object.
=cut
sub clone {
    my $this = shift;
    my $clone_name = shift;
    my $clone_root = shift;

    my $clone = { %{ $this } };
    bless($clone, 'ROK4::Core::LevelRaster');

    if (defined $clone_root) {
        # On est dans le cas d'un stockage fichier, et il faut modifier l'emplacement du descripteur et les dossiers image et masque
        $clone->{dir_image} = File::Spec->catdir($clone_root, $clone_name, "DATA", $this->{id});
        if (defined $clone->{dir_mask}) {
            $clone->{dir_mask} = File::Spec->catdir($clone_root, $clone_name, "MASK", $this->{id});
        }
        $clone->{desc_path} = $clone_root;
    } else {
        # On est dans le cas d'un stockage objet, et il faut modifier les préfixes des images et des fichiers
        $clone->{prefix_image} = sprintf "%s/DATA_%s", $clone_name, $this->{id};
        if (defined $clone->{prefix_mask}) {
            $clone->{prefix_image} = sprintf "%s/MASK_%s", $clone_name, $this->{id};
        }
    }

    return $clone;
}

1;
__END__
