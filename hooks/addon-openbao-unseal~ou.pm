package Genesis::Hook::Addon::BOSH::OpenbaoUnseal v4.1.0;

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
		"Unseal the colocated OpenBao server, making it available for use.\n".
		"Seal keys backed up in the deploying vault are used automatically; ".
		"otherwise you will be prompted for the unseal keys.";
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
	my $target = $env->name . '-openbao';

	info("");
	{
		local $ENV{SAFE_TARGET} = "";
		my ($out, $rc) = run(
			'safe', 'target', '--no-strongbox', $url, '-k', $target
		);
		bail("Failed to target OpenBao at %s:\n%s", $url, $out) if $rc;
	}

	# Already unsealed?  ("unsealed" contains "sealed", so match the whole
	# word - safe status prints "<url> is unsealed" / "<url> is sealed")
	my ($status_out, $status_rc) = run(
		{stderr => 0}, 'safe', '-T', $target, 'status'
	);
	if ($status_rc == 0 && $status_out =~ /\bunsealed\b/i) {
		info("#G{OpenBao at %s is already unsealed.}", $url);
		return $self->done(1);
	}

	# Try seal keys from the deploying vault (stored by openbao-init).
	my $keys = $self->_stored_seal_keys;
	if ($keys && @$keys) {
		info("Unsealing with %d stored seal key(s) from the deploying vault...", scalar(@$keys));
		my ($out, $rc) = run(
			{stdin => join("\n", @$keys)."\n"},
			'safe', '-T', $target, 'unseal'
		);
		if ($rc == 0) {
			info("#G{OpenBao unsealed successfully.}");
			run({interactive => 1}, 'safe', '-T', $target, 'status');
			return $self->done(1);
		}
		info("#R{Automatic unseal failed:} %s", $out);
		info("Falling back to manual unseal...");
	} else {
		info("No stored seal keys found in the deploying vault - manual unseal.");
	}

	info("Enter the unseal keys when prompted:");
	run({interactive => 1}, 'safe', '-T', $target, 'unseal');
	return $self->done();
}

# }}}
# _stored_seal_keys - fetch the custody copy from the deploying vault {{{
sub _stored_seal_keys {
	my ($self) = @_;
	my $vault = eval { $self->vault } or return undef;
	my $path  = $self->env->secrets_base . 'openbao/seal/keys';
	my $data  = eval { $vault->get($path) } or return undef;
	return undef unless ref($data) eq 'HASH';
	my @keys =
		map  { $data->{$_} }
		sort { ($a =~ /(\d+)/)[0] <=> ($b =~ /(\d+)/)[0] }
		grep { /^key\d+$/ } keys %$data;
	return @keys ? \@keys : undef;
}

# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
