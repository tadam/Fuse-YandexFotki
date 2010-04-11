package Fuse::YandexFotki;

use strict;
use warnings;

use base qw(Fuse::Class);

use Date::Parse;
use Fcntl qw(:mode); # for S_I* constants
use File::Spec;
use Fuse qw(fuse_get_context);
use LWP::UserAgent;
use POSIX qw(:errno_h :fcntl_h);

use Fuse::YandexFotki::AtompubClient;

use Data::Dumper;

my %files = ();

sub new {
    my ($class, $params) = @_;

    my $self = $class->SUPER::new;
    foreach (keys %{$params}) {
        $self->{$_} = $params->{$_};
    }
    $self->{fcache} = {};
    $self->{client} = Fuse::YandexFotki::AtompubClient->new(
        timeout        => 10,
        auth_rsa_url   => $self->{auth_rsa_url},
        auth_token_url => $self->{auth_token_url},
    );
    $self->{content_ua} = LWP::UserAgent->new(timeout => 100);
    $self->{client}->username($self->{username});
    $self->{client}->password($self->{password});
    $self->{service_url} = $self->{base_service_url} . $self->{mount_username} . "/";

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
        $modes = S_IFDIR + 0777;
    } else {
        $modes = S_IFREG + 0666;
        if (!defined($file_info->{size}) && defined($file_info->{src_url})) {
            my $resp = $self->{content_ua}->head($file_info->{src_url});
            if ($resp->is_success && $resp->header('Content-Length')) {
                $file_info->{size} = $resp->header('Content-Length');
            }
        }
        $size = $file_info->{size} || 0;
    }
    my ($dev, $ino, $rdev, $blocks, $gid, $uid, $nlink, $blksize) = (0, 0, 0, 1, 0, 0, 1, 1024);

    my $times = {};
    foreach (qw/atime ctime mtime/) {
        $times->{$_} = time();
    }
    my $type = $file_info->{type};
    my $url = $file_info->{edit_url} || $file_info->{url};
    # FIXME: in albums must be an 'all_photos' but now
    #        we haven't this type, now it is a 'photos'
    if ($type eq 'albums') {
        my $feed = $self->{client}->getFeed($url);
        if ($feed) {
            my $updated = $feed->get(undef, 'updated');
            if ($updated) {
                my $time = str2time($updated);
                if ($time) {
                    for (qw/atime ctime mtime/) {
                        $times->{$_} = $time;
                    }
                }
            }
        }
    } elsif ($type eq 'photos') {
        my $entry = $self->{client}->getEntry($url);
        if ($entry) {
            for (['published',  'ctime'],
                 ['app:edited', 'atime'],
                 ['updated',    'mtime'])
            {
                my ($elem_name, $time_name) = @{$_};
                my $elem = $entry->get(undef, $elem_name);
                if ($elem) {
                    my $t = str2time($elem);
                    if ($t) {
                        $times->{$time_name} = $t;
                    }
                }
            }
        }
    } elsif ($type eq 'image') {
        my $entry = $self->{client}->getEntry($url);
        if ($entry) {
            for (['f:created',  'ctime'],
                 ['app:edited', 'atime'],
                 ['published',  'mtime'])
            {
                my ($elem_name, $time_name) = @{$_};
                my $elem = $entry->get(undef, $elem_name);
                if ($elem) {
                    my $t = str2time($elem);
                    if ($t) {
                        $times->{$time_name} = $t;
                    }
                }
           }
        }
    }

    my @a = ($dev, $ino, $modes, $nlink, $uid, $gid, $rdev, $size,
             $times->{atime}, $times->{mtime}, $times->{ctime}, $blksize, $blocks);
    return ($dev, $ino, $modes, $nlink, $uid, $gid, $rdev, $size,
            $times->{atime}, $times->{mtime}, $times->{ctime}, $blksize, $blocks);
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
            push @files, $collection->{_type};
            $self->{fcache}->{'/' . $collection->{_type}} = {
                url => $collection->href,
                filetype => 'dir',
                type => $collection->{_type}
            };
        }
        return (@files, 0);
    } else {
        if ($dir_info->{type} eq 'collections') {
            return ('.', 'albums', 'photos', 0);
        } elsif ($dir_info->{type} eq 'albums') {
            my $feed = $client->getFeed($dir_info->{url});
            my @files = ('.');
            foreach my $entry ($feed->entries) {
                push @files, $entry->title;
                my @links = $entry->link;
                my ($link, $edit_link);
                foreach (@links) {
                    if ($_->rel eq 'photos') {
                        $link = $_;
                    } elsif ($_->rel eq 'edit') {
                        $edit_link = $_;
                    }
                }
                $self->{fcache}->{$dir . "/" . $entry->title} = {
                    url => $link->href,
                    edit_url => $edit_link->href,
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
                    src_url => $entry->content->get_attr('src'),
                    filetype => 'file',
                    type => 'image'
                };
            }
            return (@files, 0);
        }
    }
}

sub e_open {
    my $self = shift;
    # VFS sanity check; it keeps all the necessary state, not much to do here.
    my ($file) = filename_fixup(shift);
    print("open called\n");
    return -ENOENT() unless exists($files{$file});
    return -EISDIR() if $files{$file}{type} & 0040;
    print("open ok\n");
    return 0;
}

sub open {
    my ($self, $file, $modes) = @_;
    print "open file $file\n";
    return 0;
}

sub read {
    my ($self, $file, $size, $offset) = @_;

    $file = filename_fixup($file);
    my $file_info = $self->{fcache}->{$file};
    unless (defined($file_info->{content})) {
        return -EINVAL() unless $file_info->{src_url};
        my $resp = $self->{content_ua}->get($file_info->{src_url});
        return -EINVAL() unless $resp->is_success;
        $file_info->{content} = $resp->content;

        # FIXME: do we need to do this?
        $file_info->{size} = $resp->header('Content-Length');
    }
    return -EINVAL() if $offset > $file_info->{size};

    # 'normal' EOF situation
    if ($offset == $file_info->{size}) {
        delete $file_info->{content};
        return 0;
    }

    my $rv = substr($file_info->{content}, $offset, $size);

    # depending on the file size OS can return EOF to reader process
    # without you intervention
    if ($offset + $size >= $file_info->{size}) {
        delete $file_info->{content};
    }

    return $rv;
}

sub write {
    my ($self, $file, $buffer, $offset) = @_;
    print "write file $file\n";
    for (split('', $buffer)) {
        print ord($_), "\n";
    }
    return -1;
}

sub mkdir {
    my ($self, $dir) = @_;

    $dir = filename_fixup($dir);
    my $dir_info = $self->{fcache}->{$dir};
    my (undef, $parent_dir, $new_dir_title) = File::Spec->splitpath($dir);
    $parent_dir = filename_fixup($parent_dir);
    my $parent_dir_info = $self->{fcache}->{$parent_dir};

    my $entry = XML::Atom::Entry->new;
    $entry->title($new_dir_title);
    my $r = $self->{client}->createEntry($parent_dir_info->{url}, $entry);
    if ($r) {
        return ($self->getdir($parent_dir))[-1];
    } else {
        return -EACCES();
    }
}

sub rmdir {
    my ($self, $dir) = @_;

    $dir = filename_fixup($dir);
    my $dir_info = $self->{fcache}->{$dir};

    if ($self->{client}->deleteEntry($dir_info->{edit_url})) {
        delete $self->{fcache}->{$dir};
        return 0;
    } else {
        return -EACCES();
    }
}

sub release {
    return 0;
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
