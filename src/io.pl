our %io_constructors;

sub hot {
  my ($fh) = @_;
  select((select($fh), $|++)[0]);
  $fh;
}

sub defio {
  my ($name, $constructor, $methods) = @_;
  *{"ni::io::${name}::new"} = $io_constructors{$name} = sub {
    my ($class, @args) = @_;
    bless $constructor->(ni::io->new, @args), $class;
  };
  *{"::ni_$name"} = *{"ni::ni_$name"} =
    sub { ${"ni::io::${name}::"}{new}("ni::io::$name", @_) };
  *{"ni::io::$name::$_"} = $methods->{$_} for keys %$methods;
  push @{"ni::io::${name}::ISA"}, 'ni::io';
}

{
  package ni::io;
  use overload qw# +  plus_op  * bind_op  / reduce_op  % grep_op
                             >>= bind_op

                   <> next  0+ avail  "" name  ! eof  bool not_eof
                   |  pipe
                   >  into     >> copy
                   <  from_op  << enqueue #;

  sub new {
    my ($class) = @_;
    bless {eof         => 0,
           peek_buffer => [],
           listeners   => []}, $class;
  }

  sub empty {
    my $io = ni::io->new;
    $io->{eof} = 1;
    $io;
  }

  # implemented by subclasses
  sub _avail  { 0 }
  sub _next   { ... }
  sub name    { '[]' }
  sub enqueue { die "ni::io object " . $_[0]->name . " cannot be written to" }
  sub close   { die "ni::io object " . $_[0]->name . " cannot be closed" }

  sub eof     {  $_[0]->{eof} }
  sub not_eof { !$_[0]->{eof} }

  sub next {
    my ($self, $n) = @_;
    if (defined $n) {
      # Return some number of things, preferably the greater of $n or whatever
      # we have buffered.
      return () if $self->{eof};
      until (@{$self->{peek_buffer}} >= $n) {
        # Slow case: augment the peek buffer with requested elements from the
        # underlying reader.
        my $l = @{$self->{peek_buffer}};
        last if $self->{eof} =
          $l == push @{$self->{peek_buffer}},
                     $self->_next($n - @{$self->{peek_buffer}});
      }

      # Return everything we have
      my @result = @{$self->{peek_buffer}};
      @{$self->{peek_buffer}} = ();
      for my $l (@{$self->{listeners}}) {
        $l->enqueue($_) for @result;
      }
      return @result;
    } else {
      # Much slower single-read case
      return undef if $self->{eof};
      if (@{$self->{peek_buffer}}) {
        # Fast(-ish) case
        my $n = shift @{$self->{peek_buffer}};
        $_->enqueue($n) for @{$self->{listeners}};
        return $n;
      } else {
        # Quite egregiously slow case
        push @{$self->{peek_buffer}}, $self->_next
          unless @{$self->{peek_buffer}};
        my $next = shift $self->{peek_buffer};
        if (defined $next) {
          $_->enqueue($next) for @{$self->{listeners}};
          return $next;
        } else {
          $_->close for @{$self->{listeners}};
          $self->{eof} = 1;
          return undef;
        }
      }
    }
  }

  sub peek {
    my ($self, $n) = @_;
    my @xs;
    return () if $n <= 0;
    push @{$self->{peek_buffer}}, @xs
      while @{$self->{peek_buffer}} < $n
        and @xs = $self->_next($n - @{$self->{peek_buffer}});
    @{$self->{peek_buffer}}[0..($n - 1)];
  }

  sub slice {
    my ($self, $lower, $upper) = @_;
    return () if $upper <= $lower;
    @{$self->peek($upper)}[$lower .. $upper - 1];
  }

  sub avail {
    my ($self) = @_;
    $self->_avail + scalar @{$_[0]->{peek_buffer}};
  }

  sub copy {
    my ($self, $dest) = @_;
    push $self->{listeners}, ::ni $dest;
    $self;
  }

  sub into {
    # Forwards all contents into the given io, blocking until complete.
    # WARNING: this function leaves the destination open afterwards.
    my ($self, $dest) = @_;
    $dest = ::ni $dest;
    until ($self->eof) {
      $dest->enqueue($_) for $self->next(64);
    }
    $dest;
  }

  sub from {
    # Sources from the given thing(s), closing afterwards.
    my ($self, @sources) = @_;
    for (@sources) {
      unless (fork) {
        ::ni($_)->into($self);
        $self->close;
        exit;
      }
    }
    $self->close;
    $self;
  }

  sub from_op { $_[0]->from($_[1]) }

  sub pipe {
    my ($self, $command) = @_;
    my $process = ni::io::process->new($command);
    unless (fork) {
      $self->into($process);
      $process->close;
      exit;
    }
    $process->close;
    $process;
  }

  sub plus_op   { ni::io::sum   ->new(ni::io::array->new(@_[0, 1])) }
  sub bind_op   { ni::io::map   ->new(@_[0, 1]) }
  sub grep_op   { ni::io::grep  ->new(@_[0, 1]) }
  sub reduce_op { ni::io::reduce->new(@_[0, 1], {}) }

  sub plus   { ni::io::sum   ->new(ni::io::array->new(@_)) }
  sub bind   { ni::io::map   ->new(@_) }
  sub grep   { ni::io::grep  ->new(@_) }
  sub reduce { ni::io::reduce->new(@_) }
}
