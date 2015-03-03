#!/usr/bin/env perl
$ni::selfcode = '';
$ni::selfcode .= ($_ = <DATA>) until /^__END__$/;
$ni::data_fh = \*DATA;
eval $ni::selfcode;
die $@ if $@;
__DATA__
{
use v5.14;
no strict 'refs';
package ni;
sub ni;
sub ::ni;
sub self {
join "\n", "#!/usr/bin/env perl",
q{$ni::selfcode = '';},
q{$ni::selfcode .= ($_ = <DATA>) until /^__END__$/;},
q{$ni::data_fh = \*DATA;},
q{eval $ni::selfcode;},
q{die $@ if $@;},
"__DATA__",
$ni::selfcode,
map "NI_MODULE $$_[0]\n$$_[1]\nNI_MODULE_END", @ni::modules;
}
use POSIX qw/:sys_wait_h/;
$SIG{CHLD} = sub {
local ($!, $?);
waitpid -1, WNOHANG;
};
BEGIN {
sub ni::gen::new;
sub gen { local $_; ni::gen->new(@_) }
sub gen_empty { gen('empty', {}, '') }
sub gen_seq {
my ($name, @statements) = @_;
my $code_template = join "\n", map "%\@x$_;", 0 .. $#statements;
my %subst;
$subst{"x$_"} = $statements[$_] for 0 .. $#statements;
gen $name, {%subst}, $code_template;
}
{
package ni::gen;
use overload qw# % subst * map @{} inserted_code_keys "" compile
eq compile_equals #;
our $gensym_id = 0;
sub gensym { '$_' . ($_[0] // '') . '_' . $gensym_id++ . '__gensym' }
sub parse_signature {
return $_[0] if ref $_[0];
my ($first, @stuff) = split /\s*;\s*/, $_[0];
my ($desc, $type) = split /\s*:\s*/, $first;
my $result = {description => $desc,
type => $type};
/^(\S+)\s*=\s*(.*)$/ and $$result{$1} = $2 for @stuff;
$result;
}
sub parse_code;
sub new {
my ($class, $sig, $refs, $code) = @_;
my ($fragments, $gensym_indexes, $insertions) =
parse_code($code =~ s/^\s*|\s*$//gr);
my %subst;
for (keys %$refs) {
if (exists $$insertions{$_}) {
$subst{$_} = $$refs{$_};
delete $$refs{$_};
}
}
bless({ sig => parse_signature($sig),
fragments => $fragments,
gensym_names => {map {$_, undef} keys %$gensym_indexes},
gensym_indexes => $gensym_indexes,
insertion_indexes => $insertions,
refs => $refs // {} },
$class) % {%subst};
}
sub copy {
my ($self) = @_;
my %new = %$self;
$new{sig} = {%{$new{sig}}};
$new{fragments} = [@{$new{fragments}}];
$new{gensym_names} = {%{$new{gensym_names}}};
bless(\%new, ref $self)->replace_gensyms(
{map {$_, gensym $_} keys %{$new{gensym_names}}});
}
sub replace_gensyms {
my ($self, $replacements) = @_;
for (keys %$replacements) {
if (exists $$self{gensym_names}{$_}) {
my $is = $$self{gensym_indexes}{$_};
my $g = $$self{gensym_names}{$_} = $$replacements{$_};
$$self{fragments}[$_] = $g for @$is;
}
}
$self;
}
sub genify {
return $_[0] if ref $_[0] && $_[0]->isa('ni::gen');
return ni::gen('genified', {}, $_[0]);
}
sub compile_equals {
my ($self, $x) = @_;
$x = $x->compile if ref $x;
$self->compile eq $x;
}
sub share_gensyms_with {
my ($self, $g) = @_;
$g->replace_gensyms($$self{gensym_names});
$self;
}
sub inherit_gensyms_from {
$_[1]->share_gensyms_with($_[0]);
$_[0];
}
sub build_ref_hash {
my ($self, $refs) = @_;
$refs //= {};
$$refs{$$self{gensym_names}{$_}} = $$self{refs}{$_} for keys %{$$self{refs}};
$$self{fragments}[$$self{insertion_indexes}{$_}[0]]->build_ref_hash($refs)
for @$self;
$refs;
}
sub inserted_code_keys {
my ($self) = @_;
[sort keys %{$$self{insertion_indexes}}];
}
sub subst_in_place {
my ($self, $vars) = @_;
for my $k (keys %$vars) {
my $is = $$self{insertion_indexes}{$k};
my $f = genify $$vars{$k};
$$self{fragments}[$_] = $f for @$is;
}
$self;
}
sub subst {
my ($self, $vars) = @_;
$self->copy->subst_in_place($vars);
}
sub map {
my ($self, $f) = @_;
$f = ni::compile $f;
my $y = &$f($self);
return $y unless $y eq $self;
my $new = bless {}, ref $self;
$$new{$_} = $$self{$_} for keys %$self;
$$new{fragments} = [@{$$new{fragments}}];
$new % {map {$_, $$new{fragments}[$$new{insertion_indexes}{$_}] * $f} @$new};
}
sub compile {
my ($self) = @_;
join '', @{$$self{fragments}};
}
sub lexical_definitions {
my ($self, $refs) = @_;
$refs //= $self->build_ref_hash;
ni::gen "lexicals", {},
join "\n", map sprintf("my %s = \$_[0]->{'%s'};", $_, $_), keys %$refs;
}
sub compile_to_sub {
my ($self) = @_;
my $code = $self->compile;
my $refs = $self->build_ref_hash;
my $bindings = $self->lexical_definitions($refs);
my $f = eval($code = "package main; sub {\n$bindings\n$code\n}");
die "$@ compiling\n$code" if $@;
($f, $refs);
}
sub run {
my ($self) = @_;
my ($f, $refs) = $self->compile_to_sub;
my @result = &$f($refs);
delete $$refs{$_} for keys %$refs; # we create circular refs sometimes
@result;
}
our %parsed_code_cache;
sub parse_code {
my ($code) = @_;
my $cached;
unless (defined($cached = $parsed_code_cache{$code})) {
my @pieces = grep length, split /(\%:\w+|\%\@\w+)/,
$code =~ s/(\%\@\w+)/\n$1\n/gr;
my @fragments;
my %gensym_indexes;
my %insertion_indexes;
for (0 .. $#pieces) {
if ($pieces[$_] =~ /^\%:(\w+)$/) {
push @{$gensym_indexes{$1} //= []}, $_;
push @fragments, undef;
} elsif ($pieces[$_] =~ /^\%\@(\w+)$/) {
push @{$insertion_indexes{$1} //= []}, $_;
push @fragments, [$1];
} else {
push @fragments, $pieces[$_];
}
}
$cached = $parsed_code_cache{$code} = [[@fragments],
{%gensym_indexes},
{%insertion_indexes}];
}
@$cached;
}
}
}
our %type_conversions = (
'F:L' => q{ $_ = join("\t", @_) . "\n"; %@body },
'F:O' => q{ $_ = join("\t", @_); %@body },
'L:O' => q{ chomp; %@body },
'L:F' => q{ chomp; @_ = split /\t/; %@body },
'O:F' => q{ @_ = ($_); %@body },
'O:L' => q{ $_ .= "\n"; %@body });
$type_conversions{$_} = gen "conversion:$_", {}, $type_conversions{$_}
for keys %type_conversions;
sub with_type {
my ($type, $gen) = @_;
return $gen if $$gen{sig}{type} eq $type;
my $k = "$type:$$gen{sig}{type}";
$type_conversions{$k} % {body => $gen};
}
sub typed_save_recover {
my ($type) = @_;
if ($type eq 'F') {
my $xs = [];
(gen('s:F', {xs => $xs}, q{ @{%:xs} = @_ }),
gen('r:F', {xs => $xs}, q{ @_ = @{%:xs} }));
} else {
my $x = '';
(gen("s:$type", {x => \$x}, q{ ${%:x} = $_ }),
gen("r:$type", {x => \$x}, q{ $_ = ${%:x} }));
}
}
use List::Util qw/max/;
use List::MoreUtils qw/any none firstidx/;
our %fn_namespaces;
our @perl_source_filters;
sub compile_perl_lambda;
sub fn {
my ($code, $type) = @_;
return with_type $type, gen('fn:F', {f => $code}, q{ %:f->(@_) })
if ref $code eq 'CODE';
my $prefix = substr $code, 0, 1;
return $fn_namespaces{$prefix}->($code, $type)
if exists $fn_namespaces{$prefix};
compile_perl_lambda @_;
}
sub deffnns {
my ($prefix, $compiler) = @_;
die "deffnns: prefix must be exactly one character (got '$prefix')"
unless length $prefix == 1;
die "deffnns: cannot redefine existing function namespace '$prefix'"
if exists $fn_namespaces{$prefix};
die "deffnns: declining to usurp '$prefix', which is useful in code"
if $prefix =~ /^[-\s+~\/'"_\.0-9a-z\$\@\%(\[{]/;
$fn_namespaces{$prefix} = $compiler;
}
sub defperlfilter {
my ($name, $filter, $after) = @_;
die "defperlfilter: a filter called $name already exists"
if any {$$_[0] eq $name} @perl_source_filters;
die "defperlfilter: $after is not a defined filter"
if defined $after and none {$$_[0] eq $name} @perl_source_filters;
if (defined $after) {
splice @perl_source_filters,
1 + (firstidx {$$_[0] eq $name} @perl_source_filters),
0,
[$name, $filter];
} else {
push @perl_source_filters, [$name, $filter];
}
}
sub compile_perl_lambda {
my ($code, $type) = @_;
my ($original_code, $original_type) = ($code, $type);
if (defined $type) {
($code, $type) = $$_[1]->($code, $type) for @perl_source_filters;
(gen({description => $original_code}, {}, $code), $type);
} else {
$type = 'F';
($code, $type) = $$_[1]->($code, $type) for @perl_source_filters;
my $f = eval "sub {\n$code\n}";
die "fn: failed to compile '$original_code' -> '$code': $@"
if $@;
$f;
}
}
defperlfilter 'expand_json_dot_notation', sub {
my ($code, $type) = @_;
1 while $code =~ s/([a-zA-Z\)\}\]])
\.
([\$_a-zA-Z](?:-?[0-9\w\?\$])*)
/$1\->{'$2'}/x;
($code, $type);
};
defperlfilter 'expand_field_references_typefully', sub {
my ($code, $type) = @_;
$type = 'F' if $code =~ /\@_/ || $code =~ /\$_\[/ || $code =~ /%\d+/;
($code =~ s/%(\d+)/\$_[$1]/gr, $type);
};
our %io_constructors;
sub is_io { ref $_[0] && $_[0]->isa('ni::io') }
sub defio {
my ($name, $constructor, $methods) = @_;
*{"ni::io::${name}::new"} = $io_constructors{$name} = sub {
my ($class, @args) = @_;
bless $constructor->(@args), $class;
};
*{"::ni_$name"} = *{"ni::ni_$name"} =
sub { ${"ni::io::${name}::"}{new}("ni::io::$name", @_) };
*{"ni::io::${name}::$_"} = $methods->{$_} for keys %$methods;
push @{"ni::io::${name}::ISA"}, 'ni::io';
}
sub defioproxy {
my ($name, $f) = @_;
*{"::ni_$name"} = *{"ni::ni_$name"} = $f;
}
sub mapone_binding;
sub flatmap_binding;
sub reduce_binding;
sub grep_binding;
sub pipe_binding;
{
package ni::io;
use overload qw# + plus_op * mapone_op / reduce_op % grep_op | pipe_op
eq compare_refs
"" explain
>> bind_op
> into >= into_bg
< from <= from_bg #;
use Scalar::Util qw/refaddr/;
BEGIN { *gen = \&ni::gen }
use POSIX qw/dup2/;
sub source_gen { ... } # gen to source from this thing
sub sink_gen { ... } # gen to sink into this thing
sub explain { ... }
sub transform {
my ($self, $f) = @_;
$f->($self);
}
sub reader_fh { (::ni_pipe() <= $_[0])->reader_fh }
sub writer_fh { (::ni_pipe() >= $_[0])->writer_fh }
sub has_reader_fh { 0 }
sub has_writer_fh { 0 }
sub process_local { 0 }
sub supports_reads { 1 }
sub supports_writes { 0 }
sub flatten { ($_[0]) }
sub close { $_[0]->close_reader; $_[0]->close_writer }
sub close_reader { $_[0] }
sub close_writer { $_[0] }
sub plus_op { $_[0]->plus($_[1]) }
sub bind_op { $_[0]->bind($_[1]) }
sub mapone_op { $_[0]->mapone($_[1]) }
sub reduce_op { $_[0]->reduce($_[1], {}) }
sub grep_op { $_[0]->grep($_[1]) }
sub pipe_op { $_[0]->pipe($_[1]) }
sub plus { ::ni_sum(@_) }
sub bind { ::ni_bind(@_) }
sub mapone { $_[0] >> ni::mapone_binding @_[1..$#_] }
sub flatmap { $_[0] >> ni::flatmap_binding @_[1..$#_] }
sub reduce { $_[0] >> ni::reduce_binding @_[1..$#_] }
sub grep { $_[0] >> ni::grep_binding @_[1..$#_] }
sub pipe { ::ni_process($_[1], $_[0], undef) }
sub compare_refs { refaddr($_[0]) eq refaddr($_[1]) }
sub no_op { $_[0] }
sub from {
my ($self, $source, $leave_open) = @_;
::ni($source)->source_gen($self)->run;
$self->close_writer unless $leave_open;
$self;
}
sub from_bg {
my ($self, $source, $leave_open) = @_;
$self->from($source, $leave_open), exit unless fork;
$self->close_writer unless $leave_open;
$self;
}
sub into {
my ($self, $dest) = @_;
::ni($dest)->from($self);
$self;
}
sub into_bg {
my ($self, $dest) = @_;
::ni($dest)->from_bg($self);
$self;
}
}
{
package ni::lisp;
sub list { bless \@_, "ni::lisp::list" }
sub array { bless \@_, "ni::lisp::array" }
sub hash { bless \@_, "ni::lisp::hash" }
sub qstr { bless \$_[0], "ni::lisp::qstr" }
sub str { bless \$_[0], "ni::lisp::str" }
sub symbol { bless \$_[0], "ni::lisp::symbol" }
sub number { bless \$_[0], "ni::lisp::number" }
our @parse_types = qw/ list array hash qstr str symbol number /;
our %overloads = qw/ "" str /;
for (@parse_types) {
eval "package ni::lisp::$_; use overload qw#" . join(' ', %overloads) . "#;";
}
push @{"ni::lisp::${_}::ISA"}, "ni::lisp::val" for @parse_types;
sub deftypemethod {
my ($name, %alternatives) = @_;
*{"ni::lisp::${_}::$name"} = $alternatives{$_} for keys %alternatives;
}
deftypemethod 'str',
list => sub { '(' . join(' ', @{$_[0]}) . ')' },
array => sub { '[' . join(' ', @{$_[0]}) . ']' },
hash => sub { '{' . join(' ', @{$_[0]}) . '}' },
qstr => sub { "'" . ${$_[0]} . "'" },
str => sub { '"' . ${$_[0]} . '"' },
symbol => sub { ${$_[0]} },
number => sub { ${$_[0]} };
our %bracket_types = (
')' => \&ni::lisp::list,
']' => \&ni::lisp::array,
'}' => \&ni::lisp::hash,
);
sub parse {
local $_;
my @stack = [];
while ($_[0] =~ / \G (?: (?<comment> \#.*)
| (?<ws> [\s,]+)
| '(?<qstr> (?:[^\\']|\\.)*)'
| "(?<str> (?:[^\\"]|\\.)*)"
| (?<number> (?: [-+]?[0-9]*\.[0-9]+([eE][0-9]+)?
| 0x[0-9a-fA-F]+
| 0[0-7]+
| [1-9][0-9]*))
| (?<symbol> [^"()\[\]{}\s,]+)
| (?<opener> [(\[{])
| (?<closer> [)\]}])) /gx) {
next if exists $+{comment} || exists $+{ws};
if ($+{opener}) {
push @stack, [];
} elsif ($+{closer}) {
my $last = pop @stack;
die "too many closing brackets" unless @stack;
push @{$stack[-1]}, $bracket_types{$+{closer}}->(@$last);
} else {
my @types = keys %+;
my $v = $+{$types[0]};
push @{$stack[-1]}, &{"ni::lisp::$types[0]"}($v);
}
}
die "unbalanced brackets: " . scalar(@stack) . " != 1"
unless @stack == 1;
@{$stack[0]};
}
}
{
package ni::lisp;
sub fn_node { ni::lisp::fn->new(@_) }
sub co_node { ni::lisp::co->new(@_) }
sub if_node { ni::lisp::if->new(@_) }
sub apply_node { ni::lisp::apply->new(@_) }
sub global_node { ni::lisp::global->new(@_) }
sub value_node { ni::lisp::value->new(@_) }
sub bless_node { ni::lisp::value->new(@_[1..$#_])->type($_[0]) }
sub literal_node { ni::lisp::value->new->constant(@_) }
}
{
package ni::lisp::node;
sub then {
my ($self, $x) = @_;
push @{$$x{wait_for} //= []}, $self;
$self;
}
sub is_constant { 0 }
our $gensym_id = 0;
sub gensym { '__' . ($_[0] // 'gensym') . '_' . ++$gensym_id }
sub defnodetype {
my ($t, $ctor, %methods) = @_;
@{"ni::lisp::${t}::ISA"} = qw/ ni::lisp::node /;
*{"ni::lisp::${t}::new"} = sub {
local $_;
my ($class, @args) = @_;
bless $ctor->(@args), $class;
};
*{"ni::lisp::${t}::$_"} = $methods{$_} for keys %methods;
}
defnodetype 'fn',
sub { +{formal => value->new, body => undef} },
{
compile => sub {
my ($self, $language) = @_;
my $gensym = gensym 'fn';
my $v_gensym = gensym 'x';
$language->defn($gensym, $v_gensym, $$self{body});
},
};
defnodetype 'co',
sub { [@_] },
{
compile => sub {
my ($self, $language) = @_;
my $gensym = gensym 'co';
$language->array($gensym, map $_->compile($language), @$self);
},
};
defnodetype 'if',
sub { +{cond => $_[0], then => $_[1], else => $_[2]} },
{
compile => sub {
my ($self, $language) = @_;
my $cond = $$self{cond}->compile($language);
$language->choose($cond, $$self{then}, $$self{else});
},
};
defnodetype 'apply',
sub { +{f => $_[0], args => [@_[1..$#_]]} },
{
compile => sub {
my ($self, $language) = @_;
my $f = $$self{f};
my $compiled_args = co->new(@{$$self{args}})->compile($language);
if ($f->is_constant) {
$f = $$f{value};
die "cannot call a non-function $f" unless ref $f eq 'ni::lisp::fn';
my $inlined_body = $$f{body}->to_graph({'' => $$f{scope},
$$f{formal} => $compiled_args,
$$f{self_ref} => $f});
$inlined_body->compile($language);
} else {
$language->apply($f->compile($language), $compiled_args);
}
},
};
defnodetype 'value',
sub { +{value => $_[1], type => $_[0], constant => 0} },
{
constant => sub {
my ($self, $type, $x) = @_;
$$self{constant} = 1;
$$self{type} = $type;
$$self{value} = $x;
$self;
},
type => sub {
my ($self, $t) = @_;
$$self{type} = $t;
$self;
},
value => sub {
my ($self) = @_;
$$self{value};
},
is_constant => sub {
my ($self) = @_;
$$self{constant};
},
compile => sub {
my ($self, $language) = @_;
$self->is_constant
? $language->typed_constant($$self{type}, $$self{value})
: $$self{value}->compile($language);
},
};
}
{
package ni::lisp;
sub resolve_scope {
my ($scope, $x) = @_;
return undef unless ref $scope eq 'HASH';
$$scope{$x} // resolve_scope($$scope{''}, $x);
}
deftypemethod 'is_special_operator',
list => sub { 0 },
array => sub { 0 },
hash => sub { 0 },
qstr => sub { 0 },
str => sub {
my ($self) = @_;
$$self if $$self eq 'fn*' || $$self eq 'let*'
|| $$self eq 'do*' || $$self eq 'co*' || $$self eq 'if*';
},
number => sub { 0 },
var => sub { 0 };
our %special_to_graph = (
'fn*' => sub {
my ($scope, $self_ref, $formal, $body) = @_;
die "fn* self ref must be a symbol (got $self_ref instead)"
unless ref $self_ref eq 'ni::lisp::str';
die "fn* formal must be a symbol (got $formal instead)"
unless ref $formal eq 'ni::lisp::str';
fn_node $self_ref, $formal, $body;
},
'let*' => sub {
my ($scope, $name, $value, $body) = @_;
die "let* formal must be a symbol (got $name instead)"
unless ref $name eq 'ni::lisp::str';
my $v = $value->to_graph($scope);
$v->then($body->to_graph({'' => $scope, $$name => $v}));
},
'do*' => sub {
my ($scope, $first, @others) = @_;
$first = $first->then($_) for @others;
$first;
},
'co*' => sub {
my ($scope, @nodes) = @_;
co_node map $_->to_graph($scope), @nodes;
},
'if*' => sub {
my ($scope, $cond, $then, $else) = @_;
if_node $cond->to_graph($scope),
$then->to_graph($scope),
$else->to_graph($scope);
},
'apply*' => sub {
my ($scope, @args) = @_;
apply_node map $_->to_graph($scope), @args;
},
);
deftypemethod 'to_graph',
list => sub {
my ($self, $scope) = @_;
my ($head, @rest) = @$self;
my $special = $head->is_special_operator;
$special ? $special_to_graph{$special}->($scope, @rest)
: $special_to_graph{'apply*'}->($scope, $head, @rest);
},
array => sub {
my ($self, $scope) = @_;
bless_node 'array', co_node map $_->to_graph($scope), @$self;
},
hash => sub {
my ($self, $scope) = @_;
bless_node 'hash', co_node map $_->to_graph($scope), @$self;
},
str => sub {
literal_node 'string', ${$_[0]};
},
qstr => sub {
literal_node 'string', ${$_[0]};
},
number => sub {
literal_node 'number', ${$_[0]};
},
symbol => sub {
my ($self, $scope) = @_;
resolve($scope, $$self) // global_node($$self);
};
}
BEGIN {
our @data_names;
our %data_matchers;
our %data_transformers;
sub defdata {
my ($name, $matcher, $transfomer) = @_;
die "data type $name is already defined" if exists $data_matchers{$name};
unshift @data_names, $name;
$data_matchers{$name} = $matcher;
$data_transformers{$name} = $transfomer;
}
sub ni_io_for {
my ($f, @args) = @_;
for my $n (@data_names) {
return $data_transformers{$n}->($f, @args)
if $data_matchers{$n}->($f, @args);
}
die "$f does not match any known ni::io constructor";
}
sub ::ni {
my ($f, @args) = @_;
return undef unless defined $f;
return $f if ref $f && $f->isa('ni::io');
return ni_io_for($f, @args);
}
*{"ni::ni"} = *{"::ni"};
}
BEGIN {
use File::Temp qw/tmpnam/;
use List::Util qw/min max/;
use POSIX qw/dup2 mkfifo/;
sub to_fh {
return undef unless defined $_[0];
return $_[0]->() if ref $_[0] eq 'CODE';
return $_[0] if ref $_[0] eq 'GLOB';
open my $fh, $_[0] or die "failed to open $_[0]: $!";
$fh;
}
defio 'sink_as',
sub { +{description => $_[0], f => $_[1], on_close => $_[2]} },
{
explain => sub { "[sink as: " . ${$_[0]}{description} . "]" },
supports_reads => sub { 0 },
supports_writes => sub { 1 },
sink_gen => sub { ${$_[0]}{f}->(@_[1..$#_]) },
close_writer => sub {
my $f = ${$_[0]}{on_close};
$f->(@_) if defined $f;
$_[0];
},
};
defio 'source_as',
sub { +{description => $_[0], f => $_[1], on_close => $_[2]} },
{
explain => sub { "[source as: " . ${$_[0]}{description} . "]" },
source_gen => sub { ${$_[0]}{f}->(@_[1..$#_]) },
close_reader => sub {
my $f = ${$_[0]}{on_close};
$f->(@_) if defined $f;
$_[0];
},
};
sub sink_as(&) { ni_sink_as("[anonymous sink]", @_) }
sub source_as(&) { ni_source_as("[anonymous source]", @_) }
defio 'file',
sub {
die "ni_file() requires three constructor arguments (got @_)" unless @_ >= 3;
+{description => $_[0], reader => $_[1], writer => $_[2], on_close => $_[3]}
},
{
explain => sub { ${$_[0]}{description} },
reader_fh => sub {
my ($self) = @_;
die "io $self not configured for reading" unless $self->supports_reads;
$$self{reader} = to_fh $$self{reader};
},
writer_fh => sub {
my ($self) = @_;
die "io $self not configured for writing" unless $self->supports_writes;
$$self{writer} = to_fh $$self{writer};
},
supports_reads => sub { defined ${$_[0]}{reader} },
supports_writes => sub { defined ${$_[0]}{writer} },
has_reader_fh => sub { ${$_[0]}->supports_reads },
has_writer_fh => sub { ${$_[0]}->supports_writes },
source_gen => sub {
my ($self, $destination) = @_;
gen 'file_source', {fh => $self->reader_fh,
body => $destination->sink_gen('L')},
q{ while (<%:fh>) {
%@body
} };
},
sink_gen => sub {
my ($self, $type) = @_;
with_type $type,
gen 'file_sink:L', {fh => $self->writer_fh},
q{ print %:fh $_; };
},
close_reader => sub {
my ($self) = @_;
if (ref $$self{reader} eq 'GLOB') {
$$self{on_close}->($self, 0) if defined $$self{on_close};
close $$self{reader};
undef $$self{reader};
}
$self;
},
close_writer => sub {
my ($self) = @_;
if (ref $$self{writer} eq 'GLOB') {
$$self{on_close}->($self, 1) if defined $$self{on_close};
close $$self{writer};
undef $$self{writer};
}
$self;
},
};
defio 'memory',
sub { [@_] },
{
explain => sub {
"[memory io of " . scalar(@{$_[0]}) . " element(s): "
. "[" . join(', ', @{$_[0]}[0 .. min(3, $#{$_[0]})],
@{$_[0]} > 4 ? ("...") : ()) . "]]";
},
supports_writes => sub { 1 },
process_local => sub { 1 },
source_gen => sub {
my ($self, $destination) = @_;
gen 'memory_source', {xs => $self,
body => $destination->sink_gen('O')},
q{ for (@{%:xs}) {
%@body
} };
},
sink_gen => sub {
my ($self, $type) = @_;
$type eq 'F'
? gen 'memory_sink:F', {xs => $self}, q{ push @{%:xs}, [@_]; }
: with_type $type,
gen 'memory_sink:O', {xs => $self}, q{ push @{%:xs}, $_; };
},
};
defio 'ring',
sub { die "ring must contain at least one element" unless $_[0] > 0;
my $n = 0;
+{xs => [map undef, 1..$_[0]],
overflow => $_[1],
n => \$n} },
{
explain => sub {
my ($self) = @_;
"[ring io of " . min(${$$self{n}}, scalar @{$$self{xs}})
. " element(s)"
. ($$self{overflow} ? ", > $$self{overflow}]"
: "]");
},
supports_writes => sub { 1 },
process_local => sub { 1 },
source_gen => sub {
my ($self, $destination) = @_;
my $i = ${$$self{n}};
my $size = @{$$self{xs}};
my $start = max 0, $i - $size;
gen 'ring_source', {xs => $$self{xs},
n => $size,
end => $i % $size,
i => $start % $size,
body => $destination->sink_gen('O')},
q{ %:i = %@i;
while (%:i < %@n) {
$_ = ${%:xs}[%:i++];
%@body
}
%:i = 0;
while (%:i < %@end) {
$_ = ${%:xs}[%:i++];
%@body
} };
},
sink_gen => sub {
my ($self, $type) = @_;
if (defined $$self{overflow}) {
with_type $type,
gen "ring_sink:O", {xs => $$self{xs},
size => scalar(@{$$self{xs}}),
body => $$self{overflow}->sink_gen('O'),
n => $$self{n},
v => 0,
i => 0},
q{ %:v = $_;
%:i = ${%:n} % %@size;
if (${%:n}++ >= %@size) {
$_ = ${%:xs}[%:i];
%@body
}
${%:xs}[%:i] = %:v; };
} else {
gen "ring_sink:O", {xs => $$self{xs},
size => scalar(@{$$self{xs}}),
n => $$self{n}},
q{ ${%:xs}[${%:n}++ % %@size] = $_; };
}
},
};
defio 'iterate', sub { +{x => $_[0], f => $_[1]} },
{
explain => sub {
my ($self) = @_;
"[iterate $$self{x} $$self{f}]";
},
source_gen => sub {
my ($self, $destination) = @_;
gen 'iterate_source', {f => fn($$self{f}),
x => \$$self{x},
y => 0,
body => $destination->sink_gen('O')},
q{ while (1) {
%:y = ${%:x};
${%:x} = %:f->(${%:x});
$_ = %:y;
%@body
} };
},
};
defio 'null', sub { +{} },
{
explain => sub { '[null io]' },
supports_writes => sub { 1 },
source_gen => sub { gen 'empty', {}, '' },
sink_gen => sub { gen "null_sink:$_[1]V", {}, '' },
};
defio 'sum',
sub { [map $_->flatten, @_] },
{
explain => sub {
"[sum: " . join(' + ', @{$_[0]}) . "]";
},
transform => sub {
my ($self, $f) = @_;
my $x = $f->($self);
$x eq $self ? ni_sum(map $_->transform($f), @$self)
: $x;
},
flatten => sub { @{$_[0]} },
source_gen => sub {
my ($self, $destination) = @_;
return gen 'empty', {}, '' unless @$self;
gen_seq 'sum_source', map $_->source_gen($destination), @$self;
},
};
defio 'cat',
sub { \$_[0] },
{
explain => sub { "[cat ${$_[0]}]" },
source_gen => sub {
my ($self, $destination) = @_;
$$self->source_gen(sink_as {
my ($type) = @_;
with_type $type,
gen 'cat_source:F',
{dest => $destination},
q{ $_[0]->into(%:dest, 1); }});
},
};
defio 'bind',
sub {
die "code transform must be [description, f, on_close]"
unless ref $_[1] eq 'ARRAY';
+{ base => $_[0], code_transform => $_[1], on_close => $_[2] }
},
{
explain => sub {
my ($self) = @_;
"$$self{base} >> $$self{code_transform}[0]";
},
supports_reads => sub { ${$_[0]}{base}->supports_reads },
supports_writes => sub { ${$_[0]}{base}->supports_writes },
transform => sub {
my ($self, $f) = @_;
my $x = $f->($self);
$x eq $self ? ni_bind($$self{base}->transform($f), $$self{code_transform})
: $x;
},
sink_gen => sub {
my ($self, $type) = @_;
$$self{code_transform}[1]->($$self{base}, $type);
},
source_gen => sub {
my ($self, $destination) = @_;
$$self{base}->source_gen(sink_as {
my ($type) = @_;
$$self{code_transform}[1]->($destination, $type);
});
},
close_reader => sub {
my ($self) = @_;
$$self{base}->close_reader;
$$self{on_close}->($self, 0) if defined $$self{on_close};
$self;
},
close_writer => sub {
my ($self) = @_;
$$self{base}->close_writer;
$$self{on_close}->($self, 1) if defined $$self{on_close};
$self;
},
};
defioproxy 'pipe', sub {
pipe my $out, my $in or die "pipe failed: $!";
select((select($out), $|++)[0]);
select((select($in), $|++)[0]);
ni_file("[pipe in = " . fileno($in) . ", out = " . fileno($out). "]",
$out, $in);
};
defioproxy 'fifo', sub {
my ($name) = @_;
mkfifo $name //= tmpnam, 0700 or die "mkfifo failed: $!";
ni_file($name, "< $name", "> $name", sub {
unlink $name or warn "failed to unlink fifo $name: $!";
});
};
defioproxy 'filename', sub {
my ($name) = @_;
$name //= tmpnam;
ni_file($name, "< $name", "> $name");
};
defioproxy 'process', sub {
my ($command, $stdin_fh, $stdout_fh) = @_;
my $stdin = undef;
my $stdout = undef;
$stdin = $stdin_fh, $stdin_fh = $stdin_fh->reader_fh if is_io $stdin_fh;
$stdout = $stdout_fh, $stdout_fh = $stdout_fh->writer_fh if is_io $stdout_fh;
unless (defined $stdin_fh) {
$stdin = ni_pipe();
$stdin_fh = $stdin->reader_fh;
}
unless (defined $stdout_fh) {
$stdout = ni_pipe();
$stdout_fh = $stdout->writer_fh;
}
my $pid = undef;
my $create_process = sub {
return if defined $pid;
unless ($pid = fork) {
close STDIN; $stdin->close_writer if defined $stdin;
close STDOUT; $stdout->close_reader if defined $stdout;
dup2 fileno $stdin_fh, 0 or die "dup2 0 failed: $!";
dup2 fileno $stdout_fh, 1 or die "dup2 1 failed: $!";
exec $command or die "exec $command failed: $!";
}
close $stdin_fh;
close $stdout_fh;
};
ni_file(
"[process $command, stdin = $stdin, stdout = $stdout]",
sub { $create_process->(); defined $stdout ? $stdout->reader_fh : undef },
sub { $create_process->(); defined $stdin ? $stdin->writer_fh : undef });
};
defioproxy 'filter', sub {
my ($base, $read_filter, $write_filter) = @_;
ni_file(
"[filter $base, read = $read_filter, write = $write_filter]",
$base->supports_reads && defined $read_filter
? sub {ni_process($read_filter, $base->reader_fh, undef)->reader_fh}
: undef,
$base->supports_writes && defined $write_filter
? sub {ni_process($write_filter, undef, $base->writer_fh)->writer_fh}
: undef);
};
}
sub deffnbinding {
my ($name, $bodytype, $body) = @_;
*{"ni::${name}_binding"} = sub {
my ($f) = @_;
["$name $f", sub {
my ($into, $type) = @_;
my ($fc, $required_type) = fn($f, $type);
my ($each, $end) = $into->sink_gen($bodytype || $required_type);
with_type($type,
gen "$name:$required_type",
{f => $fc,
body => $each},
$body), $end;
}];
};
}
BEGIN {
sub ::row;
deffnbinding 'flatmap', 'F', q{ *{"::row"} = sub { %@body }; %@f };
deffnbinding 'mapone', 'F', q{ if (@_ = (%@f)) { %@body } };
deffnbinding 'grep', '', q{ if (%@f) { %@body } };
}
sub reduce_binding {
my ($f, $init) = @_;
["reduce $f $init", sub {
my ($into, $type) = @_;
my ($each, $end) = $into->sink_gen('O');
with_type($type,
gen 'reduce:F', {f => fn($f),
init => $init,
body => $each},
q{ (%:init, @_) = %:f->(%:init, @_);
for (@_) {
%@body
} }), $end;
}];
}
sub tee_binding {
my ($tee) = @_;
["tee $tee", sub {
my ($into, $type) = @_;
my ($save, $recover) = typed_save_recover $type;
my ($tee_each, $tee_end) = $tee->sink_gen($type);
my ($into_each, $into_end) = $into->sink_gen($type);
gen_seq("tee:$type", $save, $tee->sink_gen($type),
$recover, $into->sink_gen($type)),
gen_seq("tee_end:$type", $tee_end, $into_end);
}, sub { $tee->close_writer }];
}
sub take_binding {
my ($n) = @_;
die "must take a positive number of elements" unless $n > 0;
["take $n", sub {
my ($into, $type) = @_;
my ($each, $end) = $into->sink_gen($type);
gen("take:${type}", {body => $each,
end => $end,
remaining => $n},
q{ %@body;
if (--%:remaining <= 0) {
%@end
die 'DONE';
} }), $end;
}];
}
sub drop_binding {
my ($n) = @_;
["drop $n", sub {
my ($into, $type) = @_;
my ($each, $end) = $into->sink_gen($type);
gen("take:${type}", {body => $each,
remaining => $n},
q{ if (--%:remaining < 0) {
%@body
} }), $end;
}];
}
sub uniq_binding {
my ($count, @fields) = @_;
["uniq $count @fields", sub {
}];
}
sub zip_binding {
my ($other) = @_;
["zip $other", sub {
my ($into, $type) = @_;
my ($each, $end) = $into->sink_gen('F');
my $other_source = $other->reader_fh;
with_type($type,
gen 'zip:F', {body => $each,
live => 1,
other => $other_source,
l => ''},
q{ %:live &&= defined(%:l = <%:other>);
chomp %:l;
@_ = (@_, split /\t/, %:l);
%@body }), $end;
}, sub { $other->close_reader }];
}
sub ni::io::peek {
my ($self, $n) = @_;
my $buffer = ni_memory() < $self >> take_binding($n);
($buffer, $self);
}
our %op_shorthand_lookups; # keyed by short
our %op_shorthands; # keyed by long
our %op_formats; # ditto
our %op_usage; # ditto
our %op_fns; # ditto
sub long_op_method { "--$_[0]" =~ s/-/_/gr }
sub short_op_method { "_$_[0]" }
sub shell_quote { join ' ', map /[^-\/\w]/ ? "'" . s/(['\\])/'\\$1'/gr . "'"
: length $_ ? $_
: "''", @_ }
sub self_pipe { ni_process(shell_quote('perl', '-', @_),
ni_memory(self)->reader_fh,
undef) }
sub defop {
my ($long, $short, $format, $usage, $fn) = @_;
if (defined $short) {
$op_shorthands{$long} = $short;
$op_shorthand_lookups{$short} = "--$long";
}
$op_formats{$long} = $format;
$op_usage{$long} = $usage;
$op_fns{$long} = $fn;
my $long_method_name = long_op_method $long;
my $short_method_name =
defined $short ? short_op_method $short : undef;
die "operator $long already exists (possibly as a method rather than an op)"
if exists $ni::io::{$long_method_name}
or defined $short_method_name && exists $ni::io::{$short_method_name};
*{"ni::io::$short_method_name"} = $fn if defined $short_method_name;
*{"ni::io::$long_method_name"} = $fn;
}
our %format_matchers = (
a => sub { $_[0] =~ /^[a-zA-Z]+$/ },
d => sub { $_[0] =~ /^[-+\.0-9]+$/ },
s => sub { ref $_[0] || $_[0] =~ /^.*$/ },
v => sub { $_[0] =~ /^[^-].*$/ },
);
sub apply_format {
my ($format, @args) = @_;
my @format = split //, $format;
my @parsed;
for (@format) {
die "too few arguments for format $format" if !@args && !/[A-Z]/;
my $a = shift @args;
if ($format_matchers{lc $_}->($a)) {
push @parsed, $a;
} else {
die "failed to match format $format" unless /[A-Z]/;
push @parsed, undef;
unshift @args, $a if defined $a;
}
}
\@parsed, @args;
}
sub file_opt { ['plus', ni $_[0]] }
sub parse_commands {
my @parsed;
for (my $o; defined($o = shift @_);) {
return @parsed, map file_opt($_), @_ if $o eq '--';
if (ref($o) eq '[') {
push @parsed, ['plus', self_pipe @$o];
} elsif (ref $o) {
die "ni: unknown bracket group type " . ref($o) . " to use as a command";
} elsif ($o =~ /^--/) {
my $c = $o =~ s/^--//r;
die "unknown long command: $o" unless exists $op_fns{$c};
my ($args, @rest) = apply_format $op_formats{$c}, @_;
push @parsed, [$c, @$args];
@_ = @rest;
} elsif ($o =~ s/^-//) {
my ($op, @stuff) = grep length,
split /([:+^=%\/]?[a-zA-Z]|[-+\.0-9]+)/, $o;
die "undefined short op: $op" unless exists $op_shorthand_lookups{$op};
$op = $op_shorthand_lookups{$op} =~ s/^--//r;
my ($args, @rest) = apply_format $op_formats{$op}, @stuff, @_;
push @parsed, [$op, @$args];
if (@rest > @_) {
my @to_repack = @rest[0 .. $#rest - @_];
@_ = ('-' . join('', @to_repack), @rest[@rest - @_ .. $#rest]);
} else {
@_ = @rest;
}
} else {
push @parsed, file_opt $o;
}
}
@parsed;
}
our %read_filters;
our %write_filters;
defdata 'file',
sub { -e $_[0] || $_[0] =~ s/^file:// },
sub {
my ($f) = @_;
my $extension = ($f =~ /\.(\w+)$/)[0];
my $file = ni_file("[file $f]", "< $f", "> $f");
exists $read_filters{$extension}
? ni_filter $file, $read_filters{$extension}, $write_filters{$extension}
: $file;
};
sub deffilter {
my ($extension, $read, $write) = @_;
$read_filters{$extension} = $read;
$write_filters{$extension} = $write;
my $prefix_detector = qr/^$extension:/;
defdata $extension,
sub { $_[0] =~ s/$prefix_detector// },
sub { ni_filter ni($_[0]), $read, $write };
}
deffilter 'gz', 'gzip -d', 'gzip';
deffilter 'lzo', 'lzop -d', 'lzop';
deffilter 'xz', 'xz -d', 'xz';
deffilter 'bz2', 'bzip2 -d', 'bzip2';
defdata 'sh',
sub { $_[0] =~ s/^sh:// },
sub { ni_process $_[0], undef, undef };
our @ssh_options = exists $ENV{NI_SSH_OPTIONS}
? split /:/, $ENV{NI_SSH_OPTIONS}
: '-CX';
defdata 'ssh',
sub { $_[0] =~ /^\w*\@[^:\/]+:/ },
sub {
die "ssh: invalid syntax: $_[0]" unless $_[0] =~ /^([^:@]*)\@([^:]+):(.*)$/;
my ($user, $host, $file) = ($1, $2, $3);
my $login = length $user ? "$user\@$host" : $host;
ni_process shell_quote('ssh', @ssh_options, $login, 'perl', '-', $file),
ni_memory(self),
undef;
};
defdata 'globfile', sub { ref $_[0] eq 'GLOB' },
sub { ni_file("[fh = " . fileno($_[0]) . "]",
$_[0], $_[0]) };
defdata 'quoted', sub { ref $_[0] eq '[' },
sub { self_pipe @{$_[0]} };
our %short_functions;
our %short_function_modules;
sub defshortfn {
my ($name, $f) = @_;
if (exists $short_functions{$name}) {
my $new_name = "${name}_";
my $i = 0;
while (exists $short_functions{$new_name}
&& $i < length $ni::current_module) {
$new_name .= substr $ni::current_module, $i, 1;
++$i;
}
$i = 0;
$new_name = ($new_name =~ s/\d+$//r) . $i++
while exists $short_functions{$new_name};
print STDERR "defshortfn: $name from module $ni::current_module is "
. "already defined by module '$short_function_modules{$name}', "
. "so defining it as $new_name instead\n";
$name = $new_name;
}
$short_functions{$name} = $f;
$short_function_modules{$name} = $ni::current_module;
*{"::$name"} = $f;
}
sub parse_modules {
my ($fh) = @_;
my @modules;
my $module_name;
my @module_code;
while (!/^NI_END_OF_MODULES$/ && defined($_ = <$fh>)) {
if (/^\s*NI_MODULE (\w+)\s*$/) {
$module_name = $1;
@module_code = ();
} elsif (/^\s*NI_MODULE_END\s*$/ || /^\s*NI_END_MODULE\s*$/) {
push @modules, [$module_name, join '', @module_code];
$module_name = undef;
} elsif (defined $module_name) {
push @module_code, $_;
} elsif (/^\s*$/) {
} else {
die "ni: found this stray line not inside a NI_MODULE:\n$_";
}
}
die "ni: missing NI_MODULE_END for module $module_name"
if defined $module_name;
@modules;
}
sub run_module {
my ($name, $code) = @{$_[0]};
$ni::current_module = $name;
my @result = eval qq{
package ni::$name;
BEGIN {
*{"ni::${name}::\$_"} = *{"ni::\$_"} for keys %{ni::};
}
$code};
undef $ni::current_module;
die "ni: failed to execute module $name: $@" if $@;
@result;
}
BEGIN {
@ni::modules = parse_modules $ni::data_fh;
run_module $_ for @ni::modules;
}
use POSIX qw/dup2/;
sub preprocess_cli {
my @preprocessed;
for (my $o; defined($o = shift @_);) {
if ($o =~ /\[$/) {
my @xs;
my $depth = 1;
while (@_) {
$_ = shift @_;
last unless $depth -= /^\]$/;
$depth += /\[$/;
push @xs, $_;
}
push @preprocessed, bless [@xs], $o;
} elsif ($o =~ /\{$/) {
my @xs;
my $depth = 1;
while (@_) {
$_ = shift @_;
last unless $depth -= /^\}$/;
$depth += /\{$/;
push @xs, $_;
}
push @preprocessed, bless {@xs}, $o;
} else {
push @preprocessed, $o;
}
}
@preprocessed;
}
sub stream_for {
my ($stream, @options) = @_;
$stream //= -t STDIN ? ni_sum() : ni_file('[stdin]', \*STDIN, undef);
for (parse_commands @options) {
my ($command, @args) = @$_;
eval {$stream = $ni::io::{long_op_method $command}($stream, @args)};
die "failed to apply stream command $command [@args] "
. "(method: " . long_op_method($command) . "): $@" if $@;
}
$stream;
}
sub stream_to_process {
my ($stream, @process_alternatives) = @_;
my $fh = $stream->reader_fh;
if (fileno $fh) {
close STDIN;
dup2 fileno $fh, 0 or die "dup2 failed: $!";
}
exec $_ for @process_alternatives;
}
sub main {
$|++;
my $data = stream_for undef, preprocess_cli @_;
if (-t STDOUT && !exists $ENV{NI_NO_PAGER}) {
stream_to_process $data, $ENV{NI_PAGER} // $ENV{PAGER} // 'less',
'more';
print STDERR "ni: couldn't exec any pagers, writing to the terminal\n";
print STDERR "ni: (sorry about this; if you set \$PAGER it should work)\n";
print STDERR "\n";
print while <>;
} else {
$data > \*STDOUT;
}
}
END { main @ARGV }
use File::Temp qw/tmpnam/;
defop 'map', 'm', 's',
'transforms each record using the specified function',
sub { $_[0] * $_[1] };
defop 'flatmap', '+m', 's',
'produces multiple output records per input',
sub { $_[0]->flatmap($_[1]) };
defop 'keep', 'k', 's',
'keeps records for which the function returns true',
sub { $_[0] % $_[1] };
defop 'transform', 'M', 's',
'transforms the stream as an object using the specified function',
sub { fn($_[1])->($_[0]) };
defop 'read', 'r', '',
'interprets each record as a data source and emits it',
sub { ni_cat($_[0] * 'ni %0') };
defop 'into', 'R', 'V',
'collects data into a file and emits the filename',
sub { my ($self, $f) = @_;
$self > ni($f //= "file:" . tmpnam);
ni_memory($f) };
defop 'iterate', undef, 'ss',
'(x, f): generates x, f(x), f(f(x)), f(f(f(x))), ...',
sub { $_[0] + ni_iterate($_[1], $_[2]) };
defop 'iota', 'i', 'D',
'generates numbers from 0 to n-1',
sub {
my $source = ni_iterate 0, '%0 + 1';
$_[0] + (defined $_[1] ? $source >> take_binding $_[1] : $source);
};
use B::Deparse;
use List::MoreUtils qw/firstidx/;
defop 'self', undef, '',
'adds the source code of ni',
sub { $_[0] + ni_memory(self) };
defop 'modules', undef, '',
'lists names of defined modules',
sub { $_[0] + ni_memory(map $$_[0], @ni::modules) };
defop 'module', undef, 's',
'lists the source code of the specified module',
sub {
my ($self, $name) = @_;
my $index = firstidx {$$_[0] eq $name} @ni::modules;
$_[0] + ni_memory($index >= 0 ? $ni::modules[$index][1] : '');
};
defop 'ops', undef, '',
'lists short and long stream operations',
sub {
$_[0] + ni_memory(map sprintf("%s\t--%s\t%s", exists $op_shorthands{$_}
? "-$op_shorthands{$_}"
: '',
$_,
$op_usage{$_}),
sort keys %op_usage);
};
defop 'explain-stream', undef, '',
'explains the current stream',
sub { ni_memory($_[0]->explain) };
defop 'explain-compilation', undef, '',
'shows the compiled output for the current stream',
sub {
my $gen = $_[0]->source_gen(sink_as {
with_type $_[0], gen 'print:L', {}, "print \$_;"});
my $deparser = B::Deparse->new;
my ($f, $refs) = $gen->compile_to_sub;
delete $$refs{$_} for keys %$refs;
ni_memory($deparser->coderef2text($f));
};
defop 'defined-methods', undef, '',
'lists defined long and short methods on IO objects',
sub { ni_memory(map "$_\n", grep /^_/, sort keys %{ni::io::}) };
our $sort_buffer_size = $ENV{NI_SORT_BUFFER} // '256M';
our $sort_parallel = $ENV{NI_SORT_PARALLEL} // 4;
our $sort_compress = $ENV{NI_SORT_COMPRESS} // '';
sub sort_invocation {
my ($fields, $use_byte_ordering, @options) = @_;
my @fields = split //, $fields // '';
my $b = $use_byte_ordering ? 'b' : '';
shell_quote 'sort', '-S', $sort_buffer_size,
"--parallel=$sort_parallel",
@fields
? ('-t', "\t", map {('-k', "$_$b,$_")} map {$_ + 1} @fields)
: (),
length $sort_compress
? ("--compress-program=$sort_compress")
: (),
@options;
}
sub expand_sort_flags {
my ($flags) = @_;
return () unless defined $flags;
map "-$_", split //, $flags =~ s/([A-Z])/"r" . lc $1/gre;
}
defop 'sort', 's', 'AD',
'[flags] [fields], flags = [bnNgGr][u] with their default meaning',
sub {
my ($self, $flags, $fields) = @_;
my $byte = ($fields //= '') =~ s/b//;
$self | sort_invocation $fields, $byte, expand_sort_flags $flags;
};
defop 'merge', undef, 'ADs',
'[flags] [fields] merge-data: see "sort" for flags',
sub {
my ($self, $flags, $fields, $data) = @_;
my $byte = $fields =~ s/b//;
$self | sort_invocation $fields, $byte, expand_sort_flags($flags), '-m',
'-',
ni_fifo->from_bg($data);
};
defop 'join', 'j', 'aDs',
'[flags] [field] join-data, flags = one of lrbnLRBN',
sub {
my ($self, $flag, $field, $data) = @_;
$flag //= 'n';
$field //= 0;
my $outer_join = $flag =~ y/[A-Z]/[a-z]/;
my $sort_left = $flag =~ /[rn]/;
my $sort_right = $flag =~ /[ln]/;
my $left = $sort_left ? $self->__sort('b', $field) : $self;
my $right = $sort_right ? ni($data)->__sort('b', $field)
: ni($data);
$left | shell_quote('join', '-1', $field ? $field + 1 : '1',
'-2', 1,
'-t', "\t",
$outer_join ? ('-a', 1) : (),
'-',
ni_fifo->from_bg($right));
};
defop 'uniq', 'u', 'D',
'unique lines (or fields); count if prefixed with +',
sub {
my ($self, $fields) = @_;
my $count = ($fields //= '') =~ s/^\+//;
$self->uniq($count, split //, $fields);
};
use List::Util qw/max/;
defop 'fields', 'f', 'd',
'selects the specified fields in the given order',
sub {
my ($self, $fields) = @_;
my $select_all = $fields =~ s/\.$//;
my @fields = grep length, split /(-?\d)/, $fields;
if ($select_all) {
my $max = max @fields;
$self->mapone('@_[' . join(', ', @fields) .
", " . ($max + 1) . " .. \$#_]");
} else {
$self->mapone('@_[' . join(', ', @fields) . ']');
}
};
defop 'plus', undef, '',
'adds two streams together (implied for files)',
sub { $_[0] + $_[1] };
defop 'tee', undef, 's',
'tees current output into the specified io',
sub { $_[0] >> tee_binding(ni $_[1]) };
defop 'take', undef, 'd',
'takes the first or last N records from the specified io',
sub { $_[1] > 0 ? $_[0] >> take_binding($_[1])
: ni_ring(-$_[1]) < $_[0] };
defop 'drop', undef, 'd',
'drops the first or last N records from the specified io',
sub {
my ($self, $n) = @_;
$n >= 0
? $self->bind(drop_binding($n))
: ni_source_as("$self >> drop " . -$n . "]", sub {
my ($destination) = @_;
$self->source_gen(ni_ring(-$n, $destination));
});
};
defop 'zip', 'z', 's',
'zips lines together with those from the specified IO',
sub { $_[0] >> zip_binding(ni $_[1]) };
}
__END__

NI_MODULE geohash
no warnings 'portable';
our @gh_alphabet = split //, '0123456789bcdefghjkmnpqrstuvwxyz';
our %gh_decode = map(($gh_alphabet[$_], $_), 0..$#gh_alphabet);
sub gap_bits {
my ($x) = @_;
$x |= $x << 16; $x &= 0x0000ffff0000ffff;
$x |= $x << 8; $x &= 0x00ff00ff00ff00ff;
$x |= $x << 4; $x &= 0x0f0f0f0f0f0f0f0f;
$x |= $x << 2; $x &= 0x3333333333333333;
return ($x | $x << 1) & 0x5555555555555555;
}
sub ungap_bits {
my ($x) = @_; $x &= 0x5555555555555555;
$x ^= $x >> 1; $x &= 0x3333333333333333;
$x ^= $x >> 2; $x &= 0x0f0f0f0f0f0f0f0f;
$x ^= $x >> 4; $x &= 0x00ff00ff00ff00ff;
$x ^= $x >> 8; $x &= 0x0000ffff0000ffff;
return ($x ^ $x >> 16) & 0x00000000ffffffff;
}
sub ::geohash_encode {
my ($lat, $lng, $precision) = @_;
$precision //= 12;
my $bits = $precision > 0 ? $precision * 5 : -$precision;
my $gh = (gap_bits(int(($lat + 90) / 180 * 0x40000000)) |
gap_bits(int(($lng + 180) / 360 * 0x40000000)) << 1)
>> 60 - $bits;
$precision > 0 ? join '', reverse map $gh_alphabet[$gh >> $_ * 5 & 31],
0 .. $precision - 1
: $gh;
}
sub ::geohash_decode {
my ($gh, $bits) = @_;
unless (defined $bits) {
$bits = length($gh) * 5;
my $n = 0;
$n = $n << 5 | $gh_decode{lc $_} for split //, $gh;
$gh = $n;
}
$gh <<= 60 - $bits;
return (ungap_bits($gh) / 0x40000000 * 180 - 90,
ungap_bits($gh >> 1) / 0x40000000 * 360 - 180);
}
defshortfn 'ghe', \&::geohash_encode;
defshortfn 'ghd', \&::geohash_decode;

NI_MODULE_END
NI_MODULE sql
our %sql_databases;
sub defsqldb {
my ($name, $prefix, $io_fn) = @_;
$sql_databases{$prefix} = {name => $name, io => $io_fn};
}
our %sql_shorthands = (
'%\*' => 'select * from',
'%c' => 'select count(1) from',
'%d' => 'select distinct',
'%g' => 'group by',
'%j' => 'inner join',
'%l' => 'outer left join',
'%r' => 'outer right join',
'%w' => 'where',
);
sub expand_sql_shorthands {
my ($sql) = @_;
$sql =~ s/$_/" $sql_shorthands{$_} "/eg for keys %sql_shorthands;
$sql;
}
defdata 'sql',
sub { $_[0] =~ s/^sql:// },
sub {
my ($prefix, $db, $x) = $_[0] =~ /^(.)([^\/]*)\/(.*)$/;
die "invalid sql: syntax: sql:$_[0]"
if grep !defined, $prefix, $db, $x;
die "unknown sql db prefix: $prefix" unless exists $sql_databases{$prefix};
$sql_databases{$prefix}{io}->($db, $x);
};
sub transpose_tsv_lines {
my $n = max map scalar(split /\t/), @_;
my @columns = map [], 1 .. $n;
for (@_) {
my @vs = split /\t/;
push $columns[$_], $vs[$_] for 0 .. $#vs;
}
@columns;
}
sub infer_column_type {
return 'integer' unless grep length && !/^-?[0-9]+$/, @_;
return 'real' unless grep length &&
!/^-?[0-9]+$
| ^-?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?$
| ^-?[0-9]* \.[0-9]+ (?:[eE][-+]?[0-9]+)?$/x,
@_;
return 'text';
}
sub inferred_table_schema {
my @types = map infer_column_type(@$_), transpose_tsv_lines @_;
join ', ', map sprintf("f%d %s", $_, $types[$_]), 0 .. $#types;
}
sub sqlite_table_reader_io {
my ($db, $table) = @_;
ni_process shell_quote('sqlite3', $db),
ni_memory qq{.mode tabs\nselect * from $table;};
}
sub create_index_statement {
my ($should_index, $table, $schema) = @_;
return '' unless $should_index;
my $column = $schema =~ s/\s.*$//r;
"CREATE INDEX $table$column ON $table($column);\n";
}
sub sqlite_table_writer_io {
my ($db, $table, $schema) = @_;
my $index_first_field = $table =~ s/^\+//;
my $result = ni_pipe();
unless (fork) {
$result->close_writer;
unless (defined $schema) {
my ($first_rows, $rest) = $result->peek(20);
$schema = inferred_table_schema @$first_rows;
$result = ni_fifo() <= $first_rows + $rest;
}
my $index_statement = create_index_statement($index_first_field,
$table,
$schema);
ni_process(shell_quote('sqlite3', $db),
ni_memory(qq{.mode tabs
DROP TABLE IF EXISTS $table;
CREATE TABLE $table ($schema);
.import $result $table
$index_statement})) > \*STDERR;
exit;
}
$result;
}
defsqldb 'sqlite3', 's',
sub {
my ($db, $x) = @_;
$db = "/tmp/ni-$ENV{USER}-sqlite.db" unless length $db;
if ($x =~ /^\S+$/) {
ni_file "sql:s$db/$x",
sub {sqlite_table_reader_io($db, $x)->close_writer->reader_fh},
sub {sqlite_table_writer_io($db, $x)->close_reader->writer_fh};
} else {
my $query = expand_sql_shorthands $x;
ni_process shell_quote('sqlite3', $db),
ni_memory(qq{.mode tabs\n$query;\n});
}
};

NI_MODULE_END
NI_MODULE gnuplot
use POSIX qw/setsid/;
our %gnuplot_shorthands = (
'%l' => ' with lines',
'%d' => ' with dots',
'%i' => ' with impulses',
'%u' => ' using ',
'%t' => ' title ',
);
sub expand_gnuplot_shorthands {
my ($s) = @_;
$s =~ s/$_/$gnuplot_shorthands{$_}/g for keys %gnuplot_shorthands;
$s;
}
sub gnuplot_writer_io {
my ($script, @options) = @_;
$script = expand_gnuplot_shorthands $script;
my $into = ni_filename;
ni_file "[gnuplot @options]",
undef,
sub {
my $in = ni_pipe;
unless (fork) {
$in->close_writer;
$in > $into;
system 'gnuplot', '-persist', '-e',
$script =~ s/DATA/"$into"/gr, @options;
setsid;
close STDIN;
close STDOUT;
unless (fork) {
sleep 3600;
unlink "$into";
}
exit;
}
$in->close_reader;
$in->writer_fh;
};
}
defdata 'gnuplot', sub { $_[0] =~ s/^gnuplot:// },
sub {
my ($stuff) = @_;
$stuff = "plot DATA $stuff" unless $stuff =~ /DATA/;
gnuplot_writer_io $stuff;
};

NI_MODULE_END
NI_MODULE R
use File::Temp qw/tmpnam/;
our $r_device_init = $ENV{NI_R_DEVICE} // 'pdf("FILE")';
our $display_program = $ENV{NI_IMAGE_DISPLAY} // 'xdg-open';
our %r_shorthands = (
'%i' => 'data <- read.table(file("stdin"), sep="\t"); ',
);
sub expand_r_shorthands {
my ($s) = @_;
$s =~ s/$_/$r_shorthands{$_}/g for keys %r_shorthands;
$s;
}
sub r_reader_io {
my ($r_eval_code) = @_;
$r_eval_code = expand_r_shorthands $r_eval_code;
$r_eval_code = "write.table((function () {$r_eval_code})(), '', "
. "quote=FALSE, sep='\\t', col.names=NA)";
ni_process shell_quote('R', '--slave', '-e', $r_eval_code),
undef,
undef;
}
sub r_writer_io {
my ($r_eval_code, $no_automatic_import) = @_;
my $tempimage = tmpnam . '.pdf';
$r_eval_code = expand_r_shorthands $r_eval_code;
$r_eval_code = "$r_device_init; $r_eval_code" =~ s/FILE/$tempimage/gr;
$r_eval_code = 'data <- read.table(file("stdin"), sep="\t"); ' . $r_eval_code
unless $no_automatic_import;
ni_process(shell_quote('R', '--slave', '-e', $r_eval_code)
. " && $display_program $tempimage"
. " && rm $tempimage",
undef,
\*STDERR);
}
defdata 'R', sub { $_[0] =~ s/^R:// },
sub {
my ($r_code) = @_;
ni_file "[R $r_code]", sub { r_reader_io($r_code)->reader_fh },
sub { r_writer_io($r_code)->writer_fh };
};

NI_MODULE_END
NI_MODULE json
our $json;
if (eval {require JSON}) {
JSON->import;
no warnings qw/uninitialized/;
$json = JSON->new->allow_nonref->utf8(1);
} elsif (eval {require JSON::PP}) {
JSON::PP->import;
no warnings qw/uninitialized/;
$json = JSON::PP->new->allow_nonref->utf8(1);
} else {
print STDERR
"ni: no JSON support detected (cpan install JSON should fix it)\n";
}
sub ::json_encode { $json->encode(@_) }
sub ::json_decode { $json->decode(@_) }
defshortfn 'je', \&::json_encode;
defshortfn 'jd', \&::json_decode;

NI_MODULE_END
NI_MODULE curl
defdata 'http', sub { $_[0] =~ /^https?:\/\// },
sub {
my ($url) = @_;
ni_file "[curl $url]",
sub { ni_process(shell_quote 'curl', $url)->reader_fh },
sub { ni_process(shell_quote('curl', '--data-binary', '@-', $url),
undef,
\*STDERR)->writer_fh };
};

NI_MODULE_END
