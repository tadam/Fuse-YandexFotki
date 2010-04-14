package Fuse::YandexFotki;

use strict;
use warnings;

our $VERSION = 0.0.3;

=head1 NAME

Fuse::YandexFotki - mount photos from Yandex Fotki photohosting as VFS

=head1 SYNOPSIS

  use Fuse::YandexFotki;
  my $yf_fuse = Fuse::YandexFotki->new($many_params);
  $yf_fuse->main(mountpoint => "/my/mnt/path",
                 mountopts  => "allow_other",
                 threaded   => 0);

=head1 DESCRIPTION

This module mount photos from Yandex Fotki (L<http://fotki.yandex.ru>) as virtual
file system using for this purpose FUSE. You can create/delete albums as directory in mounted FS, upload and download photos from Yandex Fotki as plain files.

For using this module just as typical user see L<mount_yandex_fotki> program.

=cut

use base qw(Fuse::Class);

use Carp qw(croak);
use Date::Parse;
use Fcntl qw(:mode); # for S_I* constants
use File::Spec;
use HTTP::Request::Common;
use LWP::UserAgent;
use POSIX qw(:errno_h :fcntl_h);
use XML::Atom::Entry;

use Fuse::YandexFotki::AtompubClient;

use Data::Dumper;

=head1 METHODS

=over 4

=item new($params)

Creates new instance of Fuse::YandexFotki and returns it.
It takes a hashref of params, you can see an example of using this
params in L<mount_yandex_fotki> program.

=over 4

=item base_service_url

It is a base url for constructing a service document url from which starts
all work with Yandex Fotki. Now it have a value C<http://api-fotki.yandex.ru/api/users/>.
To this base url adds a C<mount_username> for getting service document by url C<http://api-fotki.yandex.ru/api/<mount_username_here>/>.

=item mount_username

Username of Yandex Fotki user, which photos you want to mount.

=item atompub_client_params

Hashref of params that will be passed to Atompub client.
See L<Fuse::YandexFotki::AtompubClient> for getting detailed description of this params.
Here you pass some options for Atompub UserAgent and urls for authorization.

=item image_upload_url

Here you set a special url for uploading photos.

Now it is ''http://api-fotki.yandex.ru/post/'.

You can also set special C<image_upload> params.

=item username (optional)

Username by which you want to have access to photos. It is a login on Yandex.

=item password (optional)

Password for C<username>.

=item content_ua_params (optional)

Hashref of params similar to LWP::UserAgent.

Module uses two UserAgents for work. One is a UserAgent for atompub client (see
C<atompub_client_params> for this). It makes all work for getting metadata about photos.
And second is a UserAgent for uploading/fetching photos.

You can set different timeouts for these UserAgents, for example.

=item show_filetime (optional)

This flag indicates that module must set proper access, change and modification times
for files. Theses values will be extracted one time and placed in memory.

If flag not setted (by default), then these values will be setted to current time.

=item show_filesize (optional)

This flag indicates, that you want to see the size of your photos.
For this purpose module makes HEAD request to files one time and saves getted values
('Content-Length' header) in memory.

By default this flag is diabled and size of all you files will be 20 Mb (max size on the
service). Module sets this size because if it will be a zero, you will can't read
such files (it controls by direct_io flag in the Fuse, but Perl bindings haven't
this flag).

=item add_file_ext (optional)

Your photos on the service can have a names like 'I and my brother on the mountain'.
In this case you lose information about file extention for these photos.
This flag indicates that module must add file extentions to photos if then haven't.

Module get this information by doing HEAD request to file and extracting value from
'Content-Type' header. It is known problem that service sends 'image/jpeg' for *.bmp
files, so if you have such files (it is unlikely), they will be renamed inproperly.

By default this flag is disabled.

=item default_image_size (optional)

Service stores your images in different sizes. You can specify what concrete size
of images you want to mount. Value of param can be one of 'orig', 'XL', 'L', 'M',
'S', 'XS', 'XXS', 'XXXS'. See L<http://api.yandex.ru/fotki/doc/appendices/photo-storage.xml> for detailed description.

If not specified module mount images with that sizes that comes from API (typically it is
'orig' or 'XS' if original was too big).

=item image_upload (optional)

Arrayref of different key-values that wiil be used in the time of image uploading.
For example you can set default values for access type of your new uploaded image.
You can't set here C<album> and C<title>, this work makes module.

See http://api.yandex.ru/fotki/doc/operations-ref/photo-create-via-post.xml for detailed description.

=back

=back

=cut

sub new {
    my ($class, $params) = @_;

    my $self = $class->SUPER::new;

    for (qw/base_service_url mount_username atompub_client_params image_upload_url/) {
        if (!defined($params->{$_})) {
            croak "Not defined param $_";
        }
    }

    foreach (keys %{$params}) {
        $self->{$_} = $params->{$_};
    }
    $self->{fcache} = {};

    my $atompub_client_params = $params->{atompub_client_params} || {};
    $self->{client} = Fuse::YandexFotki::AtompubClient->new(%{$atompub_client_params});
    $self->{client}->username($self->{username});
    $self->{client}->password($self->{password});

    my $content_ua_params = $params->{content_ua_params} || {};
    $self->{content_ua} = LWP::UserAgent->new(%{$content_ua_params});

    $self->{base_service_url} =~ s!/$!!;
    $self->{service_url} = $self->{base_service_url} . "/" . $self->{mount_username} . "/";

    $self->{image_upload} = [] unless ($self->{image_upload});

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
            my $src_url = $entry->content->get_attr('src');
            if ($self->{default_image_size}) {
                $src_url =~ s/_[^_]+$/_$self->{default_image_size}/;
            }
            $finfo->{src_url} = $src_url;
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
    my $req = POST $self->{image_upload_url},
        'Content-Type' => 'form-data',
        'Content' => [
             image => [
                 undef,
                 $image_title,
                 'Content-Type' => 'image/jpeg',
                 'Content'      => $content,
             ],
             title            => $image_title,
             album            => $album_id, # Here must be not <id>, just numeric id
                                            # of this album. Documentation bad in this place.
             @{$self->{image_upload}}
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
    my ($self, $old_full_fname, $new_full_fname) = @_;
    my (undef, $old_parent_dir, $old_fname) = File::Spec->splitpath($old_full_fname);
    my (undef, $new_parent_dir, $new_fname) = File::Spec->splitpath($new_full_fname);
    $old_parent_dir = filename_fixup($old_parent_dir);
    $new_parent_dir = filename_fixup($new_parent_dir);

    my $finfo = $self->{fcache}->{$old_full_fname};
    my $edit_url = $finfo->{edit_url};
    my $entry = $self->{client}->getEntry($edit_url);
    if ($old_fname ne $new_fname) {
        $entry->title($new_fname);
    }
    if ($old_parent_dir ne $new_parent_dir) {
        if ($finfo->{filetype} eq 'dir') {
            return -EACCES(); # moving albums from one to another isn't supports now
        }
        my $new_parent_finfo = $self->{fcache}->{$new_parent_dir};
        my $new_album_url = $new_parent_finfo->{edit_url};
        my @links = $entry->link;
        foreach (@links) {
            if ($_->rel eq 'album') {
                print "setting href";
                $_->set_attr('href', $new_album_url);
            }
        }
    }

    if ($self->{client}->updateEntry($edit_url, $entry)) {
        return 0;
    }
    return -EACCES();
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

=head1 OS SUPPORT

It must works on any OS that supports FUSE and where Fuse.pm works correctly.
I tested this only on Debian Lenny. I tried to install this on Mac OS, but
Fuse.pm tests crashes with MacFUSE.

=head1 AUTHORS

Yury Zavarin C<yury.zavarin@gmail.com>.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

L<Fuse::YandexFotki::Atompub::Client>
L<Fuse>
L<Fuse::Class>
L<http://api.yandex.ru/fotki/>

=cut

