# Improvements

- BOSH resource requirements have been updated for all proto-BOSH
  instances, to get near the upstream recommendation of 2 cores
  and 8 gigabytes of RAM (ish):

	- Azure moved from `Standard_D1_v2` to `Standard_D2_v2`
	- Google moved from `n1-standard-1` to `n1-standard-2`
	- vSphere moved from 2 core / 4GB RAM to 2 core / 8GB

- Added parameter to support AWS ebs volume encryption for ephemeral disk.

# Kit Breaking Changes

- Moved properties for vault job from instance-group level to job level. This
  is due to support for instance-group level properties being dropped by new
  versions of BOSH. If you are doing overrides to instance_groups, this may
  break your overrides.
