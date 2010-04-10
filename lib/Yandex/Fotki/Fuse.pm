package Yandex::Fotki::Fuse;

use strict;
use warnings;

use base qw(Fuse::Class);

use Atompub::Client;
use Fuse qw(fuse_get_context);
use POSIX qw(ENOENT EISDIR EINVAL);

use Yandex::Fotki::AtompubClient;

use Data::Dumper;

my $FCACHE;
my $client = Atompub::Client->new;

my %files = ();

sub new {
    my ($class, $params) = @_;

    my $self = $class->SUPER::new;
    foreach (keys %{$params}) {
        $self->{$_} = $params->{$_};
    }
    $self->{fcache} = {};
    $self->{client} = Yandex::Fotki::AtompubClient->new;

    return $self;
}

sub getattr {
    my $self = shift;
    my $file = shift;
    $file = filename_fixup($file);

    if ($file eq '.' && !$self->{fcache}->{$file}) {
        $self->getdir($file);
    }
    my $file_info = $self->{fcache}->{$file};
    return -ENOENT() unless $file_info;
    my ($size) = 0;
    my $modes;
    if ($file_info->{filetype} eq 'dir') {
        $modes = (0040 << 9) + 755;
    } else {
        $modes = (0100 << 9) + 644;
    }
    my ($dev, $ino, $rdev, $blocks, $gid, $uid, $nlink, $blksize) = (0,0,0,1,0,0,1,1024);
    my ($atime, $ctime, $mtime);
    $atime = $ctime = $mtime = time();
    return ($dev, $ino, $modes, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks);
}

sub getdir {
    my $self = shift;
    my $dir = shift;

    $dir = filename_fixup($dir);
    my $dir_info = $self->{fcache}->{$dir};
    return -ENOENT() if ($dir ne '.' && !$dir_info);

    my $client = $self->{client};

    if (!$dir_info) {
        my $service = $client->getService($self->{service_url});
        my $workspace = ($service->workspaces)[0];
        my @collections = $workspace->collections;

        $self->{fcache}->{'.'} = { url      => $self->{service_url},
                                   filetype => 'dir',
                                   type     => 'collections' };
        my @files = ('.');

        $collections[0]->{_type} = "albums";
        $collections[1]->{_type} = "photos";
        foreach my $collection (@collections[0..1]) {
            push @files, $collection->title;
            $self->{fcache}->{'/' . $collection->title} = {
                url => $collection->href,
                filetype => 'dir',
                type => $collection->{_type}
            };
        }
        return (@files, 0);
    } else {
        if ($dir_info->{type} eq 'collections') {
            my $service = $client->getService($dir_info->{url});
            my $workspace = ($service->workspaces)[0];
            my @collections = $workspace->collections;
            my @files = ('.');
            foreach my $collection (@collections) {
                push @files, $collection->title;
            }
            return (@files, 0);
        } elsif ($dir_info->{type} eq 'albums') {
            my $feed = $client->getFeed($dir_info->{url});
            my @files = ('.');
            foreach my $entry ($feed->entries) {
                push @files, $entry->title;
                my @links = $entry->link;
                my $link;
                foreach (@links) {
                    if ($_->rel eq 'photos') {
                        $link = $_;
                        last;
                    }
                }
                $self->{fcache}->{$dir . "/" . $entry->title} = {
                    url => $link->href,
                    filetype => 'dir',
                    type => 'photos'
                };
            }
            return (@files, 0);
        } elsif ($dir_info->{type} eq 'photos') {
            my $feed = $client->getFeed($dir_info->{url});
            my @files = ('.');
            foreach my $entry ($feed->entries) {
                push @files, $entry->title;
                $self->{fcache}->{$dir . "/" . $entry->title} = {
                    url => $entry->link->href,
                    filetype => 'file',
                    type => 'image'
                };
            }
            return (@files, 0);
        }
    }
}

sub open {
    my $self = shift;
    # VFS sanity check; it keeps all the necessary state, not much to do here.
    my ($file) = filename_fixup(shift);
    print("open called\n");
    return -ENOENT() unless exists($files{$file});
    return -EISDIR() if $files{$file}{type} & 0040;
    print("open ok\n");
    return 0;
}

sub read {
    my $self = shift;
    print "read\n";
    # return an error numeric, or binary/text string.  (note: 0 means EOF, "0" will
    # give a byte (ascii "0") to the reading program)
    my ($file) = filename_fixup(shift);
    my ($buf,$off) = @_;
    return -ENOENT() unless exists($files{$file});
    if(!exists($files{$file}{cont})) {
        return -EINVAL() if $off > 0;
        my $context = fuse_get_context();
        return sprintf("pid=0x%08x uid=0x%08x gid=0x%08x\n",@$context{'pid','uid','gid'});
    }
    return -EINVAL() if $off > length($files{$file}{cont});
    return 0 if $off == length($files{$file}{cont});
    return substr($files{$file}{cont},$off,$buf);
}

sub statfs {
    my $self = shift;
    return (255, 1, 1, 1, 1, 2);
}

sub filename_fixup {
    my $file = shift;
    $file ||= '.';
    $file =~ s!/$!!;
    $file = '.' unless length($file);
    return $file;
}

1;
