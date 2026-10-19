#!/usr/bin/env perl
use strict; use warnings; use FindBin; use JSON::PP; use Test::More;
BEGIN {
 $INC{'Genesis.pm'}=1; $INC{'Genesis/Hook/Blueprint.pm'}=1;
 package Genesis;
 sub import {my $c=caller; no strict 'refs'; for my $n(qw/bail info warning error in_array new_enough/){*{"${c}::$n"}=\&{$n}}}
 sub bail {die sprintf(shift,@_)} sub error {die sprintf(shift,@_)} sub info{} sub warning{}
 sub in_array {my($x,@a)=@_;return scalar grep {defined($_)&&!ref($_)&&$_ eq $x}@a}
 sub new_enough {1}
 package Genesis::Hook::Blueprint;
}
my $kit="$FindBin::Bin/..";
require "$kit/hooks/blueprint.pm";
{
 package LocalEnv;
 sub ocfp_type {$_[0]{type}} sub use_create_env {$_[0]{type} eq 'mgmt'}
 sub lookup {$_[2]} sub exodus_lookup {''} sub path {'/nonexistent/ops'}
 sub vault {bless {},'LocalVault'}
 sub secrets_mount {'secret/'} sub secrets_base {'secret/test/'} sub exodus_mount {'secret/exodus/'} sub name {'test'}
 package LocalVault; sub has {0}
 package LocalBlueprint;
 our @ISA=('Genesis::Hook::Blueprint::BOSH');
 sub iaas {$_[0]{iaas}} sub is_ocfp {1}
 sub env {bless {type=>$_[0]{type}},'LocalEnv'}
 sub features {@{$_[0]{features}}}
 sub want_feature {my($s,$f)=@_;return scalar grep {$_ eq $f}@{$s->{features}}}
 sub set_features {my $s=shift;$s->{features}=[@_]}
 sub kit_has_file {-f "$kit/$_[1]"}
 sub add_files {my $s=shift;push @{$s->{files}},@_}
 sub remove_files {my($s,@remove)=@_;$s->{files}=[grep {my $x=$_;!grep {$_ eq $x}@remove}@{$s->{files}}]}
 sub add_files_if_wants {my($s,$f,@a)=@_;$s->add_files(@a) if $s->want_feature($f)}
 sub add_files_if_exists {my($s,@a)=@_;$s->add_files(grep {$s->kit_has_file($_)} @a)}
 sub kit_bug {die $_[1]}
 sub relative_env_path {'test.yml'} sub done {$_[0]{files}}
}
for my $iaas(qw/gcp google/){for my $type(qw/mgmt ocf/){for my $internal(0,1){
 my $hook=bless {iaas=>$iaas,type=>$type,features=>['ocfp',($internal?'+internal-blobstore':())],files=>[]},'LocalBlueprint';
 my $files=eval {$hook->perform};ok(!$@,"$iaas/$type/internal=$internal blueprint: $@");next unless $files;
 ok((grep {$_ eq 'ocfp/gcp/base.yml'}@$files),'select canonical GCP base');
 ok((grep {$_ eq 'bosh-deployment/gcp/cpi.yml'}@$files),'select native GCP CPI');
 for my $file(@$files){ok(-f "$kit/$file","selected file exists: $file")}
 is(scalar(grep {$_ eq 'bosh-deployment/gcp/gcs-blobstore.yml'}@$files),$internal?0:1,'GCS selected only for external blobstore');
 ok(!(grep {$_ eq 'ocfp/meta-blobstore.yml'}@$files),'no S3 variable adapter for GCS');
}}}
for my $path(qw(ocfp/gcp/base.yml ocfp/gcp/mgmt.yml ocfp/gcp/ocf.yml ocfp/gcp/blobstore.yml)){
 ok(-f "$kit/$path","contract file $path exists");next unless -f "$kit/$path";
 open my $fh,'<',"$kit/$path" or die $!;local $/;my $text=<$fh>;
 unlike($text,qr{/bosh/iam|/bosh/iaas|/bosh/net|access_key|secret_key},'no fabricated AWS or legacy GCP paths');
}
done_testing;
