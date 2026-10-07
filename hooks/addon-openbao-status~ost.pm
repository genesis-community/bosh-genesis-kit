package Genesis::Hook::Addon::BOSH::OpenbaoStatus v4.1.0;

use v5.20; # Genesis min perl version is 5.20
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);

use Genesis qw/bail info run/;

# init - Initialize the hook {{{
sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0-rc.9');
	return $obj;
}

# }}}
# cmd_details - Documentation that is shown when running with --help {{{
sub cmd_details {
	return
		"Report the colocated OpenBao server status: health, availability, ".
		"sealed/unsealed state, the seal type and recovery seal, and any ".
		"pending seal migration.  With a static seal, a sealed server is ".
		"reported as a fault.";
}

# }}}
# perform - Main hook execution {{{
sub perform {
	my ($self) = @_;
	my $env = $self->env;

	bail("#R{[ERROR]} Requires feature openbao")
		unless $env->has_feature('openbao');

	my $ip     = $env->lookup('params.static_ip')
		or bail("params.static_ip is not set for this environment");
	my $port   = $env->lookup('params.openbao_port', 8200);
	my $url    = "https://$ip:$port";
	# Target name must be exactly the env name: genesis (one target per URL)
	# and `ocfp vault migrate` (looks up target "<env>") both key on it.
	my $target = $env->name;

	info("");
	{
		local $ENV{SAFE_TARGET} = "";
		my ($out, $rc) = run(
			'safe', 'target', '--no-strongbox', $url, '-k', $target
		);
		bail("Failed to target OpenBao at %s:\n%s", $url, $out) if $rc;
	}

	$self->_report_seal_status($url);

	run({interactive => 1}, 'safe', '-T', $target, 'status');
	return $self->done();
}

# }}}
# _report_seal_status - summarize sys/seal-status, judged against the mode {{{
sub _report_seal_status {
	my ($self, $url) = @_;
	my $env     = $self->env;
	my $helpers = $self->openbao_seal_helpers;
	my $mode    = $helpers->openbao_seal_state($env)->{mode};
	my $ca_file = $helpers->openbao_ca_file($env, eval { $self->vault });
	my $s = $helpers->openbao_seal_status($env, ca_file => $ca_file);
	unless ($s) {
		info("#Y{Could not read sys/seal-status from %s.}\n", $url);
		return 0;
	}
	my $yn = sub { $_[0] ? 'yes' : 'no' };
	my $type = $s->{type} // 'unknown';
	info("OpenBao seal status at #C{%s}:", $url);
	info("  seal type:      #C{%s} (this environment selects #C{%s})", $type, $mode);
	info("  initialized:    %s", $yn->($s->{initialized}));
	info("  sealed:         %s", $s->{sealed} ? '#R{yes}' : '#G{no}');
	info("  recovery seal:  %s", $yn->($s->{recovery_seal}));
	info("  key threshold:  %s of %s %s", $s->{t} // '-', $s->{n} // '-',
		$s->{recovery_seal} ? 'recovery keys' : 'unseal keys');
	info("  migration:      %s", $s->{migration} ? '#Y{pending}' : 'no');
	info("  version:        %s", $s->{version} // 'unknown');

	if ($s->{migration}) {
		info(
			"\n#Y{A seal migration is pending.}  OpenBao stays sealed until three ".
			"keys are submitted with #c{migrate} set, or the migration is backed ".
			"out; see the seal migration runbook in #C{docs/openbao-operations.md}."
		);
	} elsif ($type ne 'shamir' && $s->{sealed}) {
		info(
			"\n#R{FAULT:} a static-sealed server unseals itself when its job starts, ".
			"so being sealed is not normal.  Restart the openbao job; see ".
			"#C{genesis %s do openbao-unseal} for details.", $env->name
		);
	} elsif ($s->{initialized} && $type ne $mode) {
		info(
			"\n#R{MISMATCH:} the server runs a #c{%s} seal, but this environment ".
			"selects #c{%s}.  The deployed openbao release may predate static seal ".
			"support, or the environment has not been deployed since the change.",
			$type, $mode
		);
	}
	info("");
	return 1;
}

# }}}
# openbao_seal_helpers - the package holding the OpenBao seal helpers {{{
sub openbao_seal_helpers {
	my ($self) = @_;
	my $pkg = 'Genesis::Hook::Features::BOSH';
	require( $self->env->kit->path('hooks/features.pm') )
		unless $pkg->can('openbao_seal_state');
	return $pkg;
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
