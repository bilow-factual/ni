# Data source/sink implementations

defdata 'globfile', sub { ref $_[0] eq 'GLOB' },
                    sub { ni_file($_[0], $_[0]) };

defdata 'file', sub { -e $_[0] || $_[0] =~ s/^file:// },
                sub { ni_file("< $_[0]", "> $_[0]") };

sub deffilter {
  my ($extension, $read, $write) = @_;
  $extension = qr/\.$extension$/;
  defdata $extension,
    sub { $_[0] =~ /$extension/ },
    sub { ni_filter(ni_file("< $_[0]", "> $_[0]"), $read, $write) };
}

deffilter 'gz',  'gzip -d',  'gzip';
deffilter 'lzo', 'lzop -d',  'lzop';
deffilter 'xz',  'xz -d',    'xz';
deffilter 'bz2', 'bzip2 -d', 'bzip2';

defdata 'ssh',
  sub { $_[0] =~ /^\w*@[^:\/]+:/ },
  sub { $_[0] =~ /^([^:@]+)@([^:]+):(.*)$/;
        my ($user, $host, $file) = ($1, $2, $3);

        };
