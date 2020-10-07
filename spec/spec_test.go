package spec_test

import (
	"path/filepath"
	"runtime"

	. "github.com/genesis-community/testkit/testing"
	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
)

var _ = Describe("BOSH Kit", func() {
	BeforeSuite(func() {
		_, filename, _, _ := runtime.Caller(0)
		KitDir, _ = filepath.Abs(filepath.Join(filepath.Dir(filename), "../"))
	})

	Describe("addons", func() {
		Test(Environment{
			Name:        "external-db",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "external-db-no-tls",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "skip-op-users",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "vault-credhub-proxy",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "node-exporter",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "blacksmith-integration",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "all-addons",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "all-addons-source",
			CloudConfig: "aws",
		})
	})

	Describe("cpis", func() {
		Test(Environment{
			Name: "proto-aws",
		})
		Test(Environment{
			Name: "proto-all-params-aws",
		})
		Test(Environment{
			Name:        "aws",
			CloudConfig: "aws",
		})
		Test(Environment{
			Name:        "aws-iam-profile-s3-blobstore-iam-profile",
			CloudConfig: "aws",
		})
		Test(Environment{
			Name:        "aws-iam-profile-s3-blobstore",
			CloudConfig: "aws",
		})
		Test(Environment{
			Name:        "aws-iam-profile",
			CloudConfig: "aws",
		})
		Test(Environment{
			Name:        "aws-s3-blobstore-iam-profile",
			CloudConfig: "aws",
		})
		Test(Environment{
			Name:        "aws-s3-blobstore",
			CloudConfig: "aws",
		})
		Test(Environment{
			Name:        "proto-aws-iam-profile",
			CloudConfig: "aws",
		})
		Test(Environment{
			Name:        "proto-aws-iam-profile-s3-blobstore-iam-profile",
			CloudConfig: "aws",
		})
		Test(Environment{
			Name:        "proto-aws-iam-profile-s3-blobstore",
			CloudConfig: "aws",
		})
		Test(Environment{
			Name:        "proto-aws-s3-blobstore-iam-profile",
			CloudConfig: "aws",
		})
		Test(Environment{
			Name:        "proto-aws-s3-blobstore",
			CloudConfig: "aws",
		})

		Test(Environment{
			Name: "proto-azure",
		})
		Test(Environment{
			Name: "proto-all-params-azure",
		})
		Test(Environment{
			Name:        "azure",
			CloudConfig: "azure",
		})

		Test(Environment{
			Name: "proto-google",
		})
		Test(Environment{
			Name: "proto-all-params-google",
		})
		Test(Environment{
			Name:        "google",
			CloudConfig: "google",
		})

		Test(Environment{
			Name: "proto-openstack",
		})
		Test(Environment{
			Name:        "openstack",
			CloudConfig: "openstack",
		})

		Test(Environment{
			Name: "proto-vsphere",
		})
		Test(Environment{
			Name: "proto-all-params-vsphere",
		})
		Test(Environment{
			Name:        "vsphere",
			CloudConfig: "vsphere",
		})
		Test(Environment{
			Name:        "vsphere-s3-blobstore",
			CloudConfig: "vsphere",
		})

		Test(Environment{
			Name:        "warden-vsphere",
			CloudConfig: "vsphere",
		})

		Test(Environment{
			Name:        "ops-override",
			CloudConfig: "vsphere",
			Ops: []string{
				"test-ops-override",
			},
		})
	})

	Test(Environment{
		Name: "all-params",
	})
	Test(Environment{
		Name: "proto-all-params-source-vsphere",
	})

	Test(Environment{
		Name:   "upgrade",
		Exodus: "old-version",
	})
	Test(Environment{
		Name:   "to-old-to-upgrade",
		Exodus: "to-old-version",
		OutputMatchers: OutputMatchers{
			GenesisAddSecrets: ContainSubstring("please upgrade to bosh kit 1.15.2"),
			GenesisCheck:      ContainSubstring("please upgrade to bosh kit 1.15.2"),
			GenesisManifest:   ContainSubstring("please upgrade to bosh kit 1.15.2"),
		},
	})

})
