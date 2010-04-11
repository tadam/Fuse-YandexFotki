use Module::Build;

my $mb = Module::Build->new(
    module_name => 'Fuse::YandexFotki',
    license => 'perl',
    dist_author => 'Yury Zavarin <yury.zavarin@gmail.com>',
    requires => {
        'Module::Build'      => 0.2805,
        'Atompub'            => '0.3.2',
        'Date::Parse'        => 0,
        'Fcntl'              => 0,
        'File::Spec'         => 0,
        'Fuse'               => 0.09,
        'Getopt::Long'       => 2.33,
        'LWP::UserAgent'     => 0,
        'Math::BigInt'       => 0,
        'MIME::Base64'       => 0,
        'Pod::Usage'         => 0,
        'POSIX'              => 0,
        'Term::ReadPassword' => 0,
        'XML::LibXML'        => 0,
    },
    build_requires => {
    }
);

$mb->create_build_script;
