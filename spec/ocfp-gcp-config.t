#!/usr/bin/env perl
use strict; use warnings; use FindBin; use Test::More;
BEGIN {
 $INC{'Genesis.pm'}=1; $INC{'Genesis/Hook/CpiConfig.pm'}=1; $INC{'Genesis/Hook/CloudConfig.pm'}=1; $INC{'Genesis/Hook/CloudConfig/Helpers.pm'}=1;
 package Genesis; sub import {my $c=caller; no strict 'refs'; for my $n(qw/bail info uniq/){*{"${c}::$n"}=\&{$n}}} sub bail {die sprintf(shift,@_)} sub info {} sub uniq {@_}
 package Genesis::Hook::CpiConfig; sub iaas {$_[0]{iaas}} sub _resolve {return ({type=>'service_account',project_id=>'p'},1)}
 package Genesis::Hook::CloudConfig;
 package Genesis::Hook::CloudConfig::Helpers; sub import {my $c=caller;no strict 'refs';*{"${c}::gigabytes"}=sub {$_[0]*1024};*{"${c}::megabytes"}=sub {$_[0]}}
}
require "$FindBin::Bin/../hooks/cpi-config.pm";
require "$FindBin::Bin/../hooks/cloud-config.pm";
{
 package ConfigEnv; sub is_ocfp {1} sub lookup {$_[2]} sub ocfp_config_lookup {$_[2]}
 package CpiFixture; our @ISA=('Genesis::Hook::CpiConfig::BOSH');
 sub completed {0} sub env {bless {},'ConfigEnv'} sub done {$_[1]}
 sub build_cpi_config_for_iaas {my($s,%m)=@_;my $type=$s->iaas;die "unsupported $type" unless $m{$type}; return {cpis=>[{type=>$type,properties=>$m{$type}->()}]}}
 sub gather_properties {my $s=shift;return [@_]}
 package CloudFixture; our @ISA=('Genesis::Hook::CloudConfig::BOSH');
 sub completed {0} sub env {bless {},'ConfigEnv'} sub done {$_[1]} sub TRUE {1} sub FALSE {0}
 sub build_cloud_config {$_[1]} sub build_cpi_azs {()}
 sub network_reference {"network.$_[1]"} sub subnet_reference {"subnet.$_[1]"}
 sub get_network_security_groups {['tag-a','tag-b']}
 sub for_scale {$_[2]} sub network_definition {my($s,$n,%a)=@_;return \%a}
 sub vm_type_definition {my($s,$n,%a)=@_;return \%a} sub disk_type_definition {my($s,$n,%a)=@_;return \%a}
}
for my $alias(qw/gcp google/){
 my $c=eval {(bless {iaas=>$alias},'CpiFixture')->perform};ok(!$@,"$alias CPI dispatch: $@");
 if($c){is($c->{cpis}[0]{type},'google','native CPI type');is_deeply($c->{cpis}[0]{properties},['project','!json_key'],'native CPI properties')}
}
my ($key,$found)=(bless {iaas=>'gcp'},'CpiFixture')->_resolve({key=>'json_key'});
ok(!ref($key) && $key =~ /service_account/, 'JSON credentials stay a string before entombment');
my $cloud=(bless {},'CloudFixture')->perform;
for my $alias(qw/gcp google/){
 my $net=$cloud->{networks}[0]{dynamic_subnets}{cloud_properties_for_iaas}{$alias};
 is_deeply($net,{network_name=>'network.name',xpn_host_project_id=>'network.project',subnetwork_name=>'subnet.cloud_name',tags=>['tag-a','tag-b'],ephemeral_external_ip=>0},"$alias native network properties");
 is($cloud->{vm_types}[0]{cloud_properties_for_iaas}{$alias}{machine_type},'e2-standard-2',"$alias native VM type");
 is($cloud->{disk_types}[0]{cloud_properties_for_iaas}{$alias}{type},'pd-balanced',"$alias native disk type");
}
done_testing;
