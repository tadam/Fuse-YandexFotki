package Fuse::YandexFotki;

use strict;
use warnings;

our $VERSION = 0.0.1;

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
        $size = $file_info->{size} if defined($file_info->{size});
    }
    my ($dev, $ino, $rdev, $blocks, $gid, $uid, $nlink, $blksize) = (0, 0, 0, 1, 0, 0, 1, 1024);

    my $type = $file_info->{type};
    my $url = $file_info->{edit_url} || $file_info->{url};

    return ($dev, $ino, $modes, $nlink, $uid, $gid, $rdev, $size,
            $file_info->{atime}, $file_info->{mtime}, $file_info->{ctime}, $blksize, $blocks);
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
        my $albums_collection = ($workspace->collections)[0];
        $dir_info = { url      => $albums_collection->href,
                      type     => 'collection',
                      filetype => 'dir' };
        $self->{fcache}->{$dir} = $dir_info;
    }

    my @files = ('.');
    my $feed_url = $dir_info->{url};
    while (1) {
        my $feed = $client->getFeed($feed_url);
        my $add_files;
        if ($dir_info->{type} eq 'collection') {
            $add_files = $self->_getdir_collection($feed, $dir, $dir_info);
        } elsif ($dir_info eq 'album') {
            $add_files = $self->_getdir_album($feed, $dir, $dir_info);
        }
        if ($add_files && ref($add_files) eq 'ARRAY' && @{$add_files}) {
            push @files, @{$add_files};
        }

        my @links = $feed->links;
        $feed_url = undef;
        foreach (@links) {
            if ($_->rel eq 'next') {
                $feed_url = $_->href;
            }
        }
        redo if ($feed_url);
        last;
    }

    return (@files, 0);
}

sub _getdir_collection {
    my ($self, $feed, $dir, $dir_info) = @_;

    my @files = ();

    # setting times for root
    unless (defined($dir_info->{atime})) {
        $self->_set_filetime($dir_info, $feed);
    }
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

        my $fname = "/" . $entry->title;
        unless ($self->{fcache}->{$fname}) {
            $self->{fcache}->{$fname} = {};
        }
        my $finfo = $self->{fcache}->{$fname};

        $finfo->{url}      = $link->href;
        $finfo->{edit_url} = $edit_link->href;
        $finfo->{filetype} = 'dir';
        $finfo->{type}     = 'album';

        # setting times for concrete album
        unless (defined($finfo->{atime})) {
            $self->_set_filetime($finfo, $entry);
        }
    }

    return \@files;
}


sub _getdir_album {
    my ($self, $feed, $dir, $dir_info) = @_;

    my @files = ();
    foreach my $entry ($feed->entries) {
        my $fname = $entry->title;
        my $full_fname = $dir . "/" . $fname;
        my $finfo = $self->{fcache}->{$full_fname};
        if ($finfo && defined($finfo->{renamed})) {
            $finfo = $self->{cache}->{ $finfo->{renamed} };
        }
        unless ($finfo) {
            $finfo = {};
            $finfo->{url}      = $entry->link->href;
            $finfo->{src_url}  = $entry->content->get_attr('src');
            $finfo->{filetype} = 'file';
            $finfo->{type}     = 'photo';

            # setting times, size and extention for concrete photo
            unless (defined($finfo->{atime})) {
                $self->_set_filetime($finfo, $entry);
            }
            unless (defined($finfo->{size})) {
                $self->_set_filesize_and_ext($finfo);
            }

            if (my $ext = $finfo->{ext}) {
                if ($fname !~ /\.\Q$ext\E$/i) {
                    $self->{fcache}->{$full_fname}->{renamed} = $full_fname . ".$ext";
                    $fname .= ".$ext";
                    $full_fname .= ".$ext";
                }
            }
        }

        $self->{fcache}->{$full_fname} = $finfo;
        push @files, $fname;
    }

    return \@files;
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

sub _set_filetime {
    my ($self, $file_info, $descr) = @_;

    # setting defaults
    $file_info->{atime} = $file_info->{ctime} = $file_info->{mtime} = time();

    if (!$self->{show_filetime} || !$descr) {
        return;
    }

    my $type = $file_info->{type};
    if ($type eq 'collection') {
        my $updated = $descr->get(undef, 'updated');
        if ($updated && (my $t = str2time($updated))) {
            for (qw/atime ctime mtime/) {
                $file_info->{$_} = $t;
            }
        }
    } elsif ($type eq 'album') {
        for (['published',  'ctime'],
             ['app:edited', 'atime'],
             ['updated',    'mtime'])
        {
            my ($elem_name, $time_name) = @{$_};
            my $elem = $descr->get(undef, $elem_name);
            if ($elem && (my $t = str2time($elem))) {
                $file_info->{$time_name} = $t;
            }
        }
    } elsif ($type eq 'photo') {
        for (['f:created',  'ctime'],
             ['app:edited', 'atime'],
             ['published',  'mtime'])
        {
            my ($elem_name, $time_name) = @{$_};
            my $elem = $descr->get(undef, $elem_name);
            if ($elem && (my $t = str2time($elem))) {
                $file_info->{$time_name} = $t;
            }
        }
    }
}

sub _set_filesize_and_ext {
    my ($self, $file_info) = @_;

    unless ($self->{show_filesize}) {
        # we set max allowed size on service, because if it
        # will be 0, then you will can't read this file
        # (fuse have direct_io option for such files, but it don't supports
        # in Perl bindings)
        $file_info->{size} = 20*1024*1024;
        return;
    }

    return unless defined($file_info->{src_url});

    my $resp = $self->{content_ua}->head($file_info->{src_url});
    if ($resp->is_success) {
        if (my $header = $resp->header('Content-Length')) {
            $file_info->{size} = $header;
        }
        if (my $header = $resp->header('Content-Type')) {
            if ($header =~ /jpe?g/) {
                $file_info->{ext} = 'jpg';
            } elsif ($header =~ /gif/) {
                $file_info->{ext} = 'gif';
            } elsif ($header =~ /png/) {
                $file_info->{ext} = 'png';
            }
        }
    }
}

1;

__END__

=head1 NAME

Fuse::YandexFotki - mount photos from Yandex Fotki photohosting (http://fotki.yandex.ru) as VFS

=cut

