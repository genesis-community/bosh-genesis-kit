#!/usr/bin/env perl
use strict; use warnings; use FindBin; use Test::More; use JSON::PP; use File::Temp qw/tempdir/;
my $kit="$FindBin::Bin/.."; my $tmp=tempdir(CLEANUP=>1);
sub yaml {my($p)=@_;my $j=qx{graft json '$p' 2>&1};die $j if $?;return decode_json($j)}
sub write_json {my($p,$v)=@_;open my $f,'>',$p or die $!;print $f encode_json($v);close $f}
my %secrets=(project=>'test-project',json_key=>'{"type":"service_account","project_id":"test-project"}',zone=>'us-central1-b',name=>'test-network',cloud_name=>'test-subnet',network_tag=>'test-tag',bucket_name=>'test-bucket',password=>'test-password',certificate=>'certificate',key=>'key');
sub stub_vault {
 my($x)=@_;
 if(ref($x) eq 'HASH'){return {map {$_=>stub_vault($x->{$_})} keys %$x}}
 if(ref($x) eq 'ARRAY'){return [map {stub_vault($_)} @$x]}
 if(defined($x)&&$x =~ /^\(\( vault /){return 'host-project' if $x =~ m{/net:project};my($key)=$x =~ /:([^":]+)" \)\)$/;die "unmapped vault expression $x" unless defined($key)&&exists $secrets{$key};return $secrets{$key}}
 return $x;
}
for my $internal(0,1){
 my $base=stub_vault(yaml("$kit/ocfp/gcp/base.yml"));
 $base->{genesis}{env}='test';$base->{meta}{ocfp}{bosh}{$_}={ip=>'10.0.4.6',gateway=>'10.0.4.1',cidr=>'10.0.4.0/22',dns=>['169.254.169.254']}->{$_} for qw/ip gateway cidr dns/;
 write_json("$tmp/base.json",$base);
 write_json("$tmp/blob.json",$internal?{}:stub_vault(yaml("$kit/ocfp/gcp/blobstore.yml")));
 my $merged=qx{graft merge '$tmp/base.json' '$tmp/blob.json' 2>&1};is($?,0,"adapter variables evaluate internal=$internal") or BAIL_OUT($merged);
 open my $f,'>',"$tmp/evaluated.yml" or die $!;print $f $merged;close $f;
 my $vars=yaml("$tmp/evaluated.yml")->{'bosh-variables'};
 is(yaml("$tmp/evaluated.yml")->{meta}{ocfp}{bosh}{network_project},'host-project','host project remains separate from service project');
 is($vars->{zone},'us-central1-b','physical zone resolved');is_deeply($vars->{tags},['test-tag','test-tag'],'tags remain array');
 write_json("$tmp/vars.json",$vars);
 my $ops=$internal?'':"-o '$kit/bosh-deployment/gcp/gcs-blobstore.yml'";
 my $manifest=qx{bosh interpolate '$kit/bosh-deployment/bosh.yml' -o '$kit/bosh-deployment/gcp/cpi.yml' $ops -l '$tmp/vars.json' 2>&1};is($?,0,"native BOSH ops interpolate internal=$internal") or BAIL_OUT($manifest);
 open $f,'>',"$tmp/manifest.yml" or die $!;print $f $manifest;close $f;
 my $m=yaml("$tmp/manifest.yml");my $props=$m->{instance_groups}[0]{properties};
 is($props->{google}{project},'test-project','native google project');is($props->{google}{json_key},$secrets{json_key},'native JSON credential string');
 is(scalar(grep {$_->{name} eq 'blobstore'} @{$m->{instance_groups}[0]{jobs}}),$internal?1:0,'internal blobstore job follows selection');
 if(!$internal){is($props->{blobstore}{provider},'gcs','native GCS provider');is($props->{blobstore}{bucket_name},'test-bucket','native bucket name')}
}
# Graft overlays must merge into the existing anonymous subnet, preserving
# the addressing set by bosh-deployment before changing cloud properties.
write_json("$tmp/network.json", {networks=>[{name=>'default',subnets=>[{range=>'10.0.4.0/22',gateway=>'10.0.4.1',static=>['10.0.4.6']}]}]});
my $mgmt=qx{graft merge --skip-eval '$tmp/network.json' '$kit/ocfp/gcp/mgmt.yml' 2>&1};
is($?,0,'management overlay merges');
open my $mf,'>',"$tmp/mgmt.yml" or die $!;print $mf $mgmt;close $mf;
my $subnet=yaml("$tmp/mgmt.yml")->{networks}[0]{subnets}[0];
is($subnet->{range},'10.0.4.0/22','management preserves subnet range');
is($subnet->{cloud_properties}{xpn_host_project_id},'(( grab meta.ocfp.bosh.network_project ))','Shared VPC host project reaches create-env networking');
is($subnet->{gateway},'10.0.4.1','management preserves gateway');
done_testing;
