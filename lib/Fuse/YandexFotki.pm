package Fuse::YandexFotki;

use strict;
use warnings;

our $VERSION = 0.0.3;

use base qw(Fuse::Class);

use Date::Parse;
use Fcntl qw(:mode); # for S_I* constants
use File::Spec;
use Fuse qw(fuse_get_context);
use HTTP::Request::Common;
use LWP::UserAgent;
use POSIX qw(:errno_h :fcntl_h);
use XML::Atom::Entry;

use Fuse::YandexFotki::AtompubClient;

use Data::Dumper;

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
        $modes = S_IFDIR + 0755;
    } else {
        $modes = S_IFREG + 0644;
        $size = $file_info->{size} if defined($file_info->{size});
    }
    my ($dev, $ino, $rdev, $blocks, $gid, $uid, $nlink, $blksize) = (0, 0, 0, 1, 0, 0, 1, 1024);

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
        } elsif ($dir_info->{type} eq 'album') {
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

        my $fname = "/" . $entry->title;
        unless ($self->{fcache}->{$fname}) {
            $self->{fcache}->{$fname} = {};
        }
        my $finfo = $self->{fcache}->{$fname};


        my @links = $entry->link;
        foreach (@links) {
            if ($_->rel eq 'photos') {
                $finfo->{url} = $_->href;
            } elsif ($_->rel eq 'edit') {
                $finfo->{edit_url} = $_->href;
            }
        }
        $finfo->{id} = $entry->get(undef, 'id'); # album uniq id, needed for upload
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
            $finfo->{src_url}  = $entry->content->get_attr('src');
            $finfo->{filetype} = 'file';
            $finfo->{type}     = 'photo';

            my @links = $entry->link;
            foreach (@links) {
                if ($_->rel eq 'self') {
                    $finfo->{url} = $_->href;
                } elsif ($_->rel eq 'edit') {
                    $finfo->{edit_url} = $_->href;
                }
            }

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

sub open {
    my ($self, $file, $modes) = @_;
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
    my ($self, $fname, $buffer, $offset) = @_;

    $fname = filename_fixup($fname);
    my $content = $self->{fcache}->{$fname}->{content};
    return -EBADF() unless (defined($content));
    substr($content, $offset, length($buffer), $buffer);
    $self->{fcache}->{$fname}->{content} = $content;

    return length($buffer);
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

{
    no strict;
    no warnings;
    *unlink = \&rmdir;
}

sub release {
    my ($self, $fname, $modes) = @_;

    $fname = filename_fixup($fname);
    my $content = $self->{fcache}->{$fname}->{content};
    # FIXME: make goto for this calls
    unless ($content) {
        delete $self->{fcache}->{$fname};
        return 0;
    }

    my (undef, $parent_dir, $image_title) = File::Spec->splitpath($fname);
    $parent_dir = filename_fixup($parent_dir);
    my $parent_dir_info = $self->{fcache}->{$parent_dir};
    if (!$parent_dir_info || !defined($image_title)) {
        delete $self->{fcache}->{$fname};
        return 0;
    }

    my $album_edit_url = $parent_dir_info->{edit_url};
    unless ($album_edit_url) {
        delete $self->{fcache}->{$fname};
        return 0;
    }

    my ($album_id) = $album_edit_url =~ m!/(\d+)/$!;
    unless ($album_id) {
        delete $self->{fcache}->{$fname};
        return 0;
    }

    # TODO: We can't use here $self->{client}->createEntry,
    #         because there are many checks of XML and so on.
    #         Maybe we need accurately rewrite this in
    #         Fuse::YandexFotki::AtompubClient.
    #       Also service now incorrectly handles 'Slug' header.
    #         It ignores this header and make photo with title 'Фотка'
    #         instead. So we use alternative url for upload.
    my $req = POST 'http://api-fotki.yandex.ru/post/',
        'Content-Type' => 'form-data',
        'Content' => [
             image => [
                 undef,
                 $image_title,
                 'Content-Type' => 'image/jpeg',
                 'Content'      => $content,
             ],
             pub_channel      => 'Fuse-YandexFotki',
             # app_platform     => ?
             app_version      => $VERSION,
             title            => $image_title,
             # tags             => ?
             yaru             => 0,
             access_type      => 'public',
             album            => $album_id, # Here must be not <id>, just numeric id
                                            # of this album. Documentation bad in this place.
             disable_comments => 'false',
             xxx              => 'false',
             hide_orig        => 'false',
             storage_private  => 'false'
        ];

    # hack for adding Authorization header
    $req = $self->{client}->munge_request($req);
    my $resp = $self->{content_ua}->request($req);
    unless ($resp->is_success) {
        delete $self->{fcache}->{$fname};
        return 0;
    }

    $self->getdir($parent_dir);
    delete $self->{fcache}->{$fname}->{dirty};
    delete $self->{fcache}->{$fname}->{content};

    return 0;
}

sub flush {
    my ($self, $fname) = @_;
    return 0;
}

sub mknod {
    my ($self, $fname, $modes, $device_num) = @_;
    $fname = filename_fixup($fname);
    $self->{fcache}->{$fname} = { type => 'image',
                                  filetype => 'file',
                                  atime    => time(),
                                  ctime    => time(),
                                  mtime    => time(),
                                  content  => '',
                                  size     => 0,
                                  dirty    => 1,
                                };
    return 0;
}

sub rename {
    my ($self, $old_fname, $new_fname) = @_;
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

